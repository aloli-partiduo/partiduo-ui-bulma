# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Connexion (ADR-002) : la passkey d'abord, puis le mot de passe (suivi du
  # TOTP ou d'un code de récupération si l'utilisateur a un second facteur).
  # Refus, temporisation et blocage sont affichés tels que le cœur les décide.
  class LoginHandler < Handler
    def get
      if current.authenticated? && !current.enrollment?
        return go(Navigation.next_path(request))
      end
      login_page
    end

    # Étape 1 du mot de passe.
    def post
      email = field("email")
      input = Partiduo::Api::Auth::PasswordLoginInput.new(email, field("password", strip: false), Current.login_context(request))
      result = Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous, input)
      return login_page(email, errors_of(result), LoginFlow.throttling(result), 422) if result.failure?

      view = result.value!
      next_path = Navigation.next_path(request)
      if view.authenticated?
        return go(LoginFlow.destination(request, view, next_path))
      end

      request.cookies.set(Current::PENDING_COOKIE, view.pending_token!, expires: 10.minutes.from_now,
        http_only: true, secure: Current.secure_cookies?(request), same_site: "Lax")
      params = {"factors" => view.second_factors.join(',')}
      params["next"] = next_path unless next_path == reverse("core:dashboard")
      go("#{reverse("login_second_factor")}?#{URI::Params.encode(params)}")
    end

    private def login_page(email : String = "", errors = {} of String => Array(String),
                           throttling = {} of String => String | Bool, status : Int32 = 200)
      next_path = Navigation.safe_path(query("next").presence || field("next").presence) || ""
      page("ui/auth/login.html", {
        "email"      => email,
        "errors"     => errors,
        "throttling" => throttling,
        "next"       => next_path,
        "company"    => company_name,
        "providers"  => federated_links(next_path),
      }, status)
    end

    # Boutons de connexion fédérée (ADR-002 D3) : fournisseurs actifs, si la
    # politique de l'instance admet la méthode ; `nil` sinon.
    private def federated_links(next_path : String) : Array(Screen::Action)?
      links = Partiduo::Api::Auth.login_providers(Partiduo::Api::Actor.anonymous).map do |provider|
        url = reverse("login_federated", code: provider.code)
        url = "#{url}?#{URI::Params.encode({"next" => next_path})}" unless next_path.empty?
        Screen::Action.new(I18n.t("ui.login.federated_button", name: provider.name), url, icon: "log-in")
      end
      links.empty? ? nil : links
    end

    # Nom du dossier sur l'écran de connexion : le contrat ne l'expose qu'à un
    # utilisateur authentifié ; l'écran affiche donc le nom de l'hôte.
    private def company_name : String
      request.host
    end
  end

  # Étape 2 : code de l'application d'authentification, ou code de récupération.
  class LoginSecondFactorHandler < Handler
    def get
      return go(reverse("login")) if pending_token.nil?
      form_page
    end

    def post
      token = pending_token
      if token.nil?
        flash["warning"] = I18n.t("auth.errors.login.expired")
        return go(reverse("login"))
      end

      kind = field("kind") == "recovery_code" ? "recovery_code" : "totp"
      input = Partiduo::Api::Auth::SecondFactorInput.new(token, field("code").delete(' '), kind, Current.login_context(request))
      result = Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous, input)
      if result.failure?
        if result.error_keys.includes?("auth.errors.login.expired")
          request.cookies.delete(Current::PENDING_COOKIE, same_site: "Lax")
          flash["warning"] = I18n.t("auth.errors.login.expired")
          return go(reverse("login"))
        end
        return form_page(errors_of(result), LoginFlow.throttling(result), kind, 422)
      end

      request.cookies.delete(Current::PENDING_COOKIE, same_site: "Lax")
      go(LoginFlow.destination(request, result.value!, Navigation.next_path(request)))
    end

    private def pending_token : String?
      request.cookies[Current::PENDING_COOKIE]?.presence
    end

    private def form_page(errors = {} of String => Array(String), throttling = {} of String => String | Bool,
                          kind : String = "totp", status : Int32 = 200)
      factors = (query("factors").presence || field("factors").presence || "totp,recovery_code").split(',')
      page("ui/auth/second_factor.html", {
        "errors"     => errors,
        "throttling" => throttling,
        "kind"       => kind,
        "totp"       => factors.includes?("totp"),
        "recovery"   => factors.includes?("recovery_code"),
        "factors"    => factors.join(','),
        "next"       => Navigation.safe_path(query("next").presence || field("next").presence) || "",
      }, status)
    end
  end

  # Connexion par passkey (credential découvrable, sans identifiant saisi) :
  # options pour `navigator.credentials.get()`, puis vérification.
  class LoginPasskeyOptionsHandler < Handler
    def post
      unless RateLimit.allow?(request, "passkey_options")
        return json(PasskeyJson.outcome(false, error: I18n.t("ui.errors.too_many_requests")), 429)
      end
      json(PasskeyJson.request(Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)))
    end
  end

  class LoginPasskeyHandler < Handler
    def post
      input = PasskeyJson.assertion(request.data, Current.login_context(request))
      result = Partiduo::Api::Auth.login_passkey(Partiduo::Api::Actor.anonymous, input)
      if result.failure?
        return json(PasskeyJson.outcome(false, error: result.errors.map(&.message).join(' ')), 422)
      end
      json(PasskeyJson.outcome(true, redirect: LoginFlow.destination(request, result.value!, Navigation.next_path(request))))
    end
  end

  # Déconnexion. Une session ouverte par connect (ADR-012 D8) se ferme
  # aussi chez connect, qui ferme celles des autres dossiers : la
  # déconnexion est unique.
  class LogoutHandler < Handler
    def post
      connect = Partiduo::Api::Auth.federated_logout_url(request.cookies[Current::COOKIE]?.presence, request.host.to_s)
      Current.close(request)
      return go(connect) if connect
      flash["success"] = I18n.t("ui.login.logged_out")
      go(reverse("login"))
    end
  end

  # Invitation (ADR-002 D6, D7) : le lien reçu par courriel ouvre une session
  # d'enrôlement. Un GET ne consomme rien (aperçus de liens, antivirus) : il
  # affiche un bouton qui confirme.
  #
  # Avec connect (ADR-012 D6), l'invitation lie un compte connect : la page
  # propose de le créer (lien de connect, qui exige le code transmis par un
  # autre canal) ou de se connecter à celui qu'on a déjà.
  class InvitationHandler < Handler
    def get
      token = params["token"].to_s
      invitation = Partiduo::Api::Auth.invitation_view(Partiduo::Api::Actor.anonymous, token)
      # Valeurs à plat : les gabarits de Marten ne lisent pas les vues du
      # contrat.
      page("ui/auth/invitation.html", {
        "errors"                => {} of String => Array(String),
        "invitation_valid"      => !invitation.nil?,
        "invitation_connect"    => invitation.try(&.connect) || false,
        "invitation_email"      => invitation.try(&.email) || "",
        "invitation_signup_url" => invitation.try(&.signup_url).presence,
        "connect_path"          => reverse("invitation_connect", token: token),
      })
    end

    def post
      invitation = Partiduo::Api::Auth.invitation_view(Partiduo::Api::Actor.anonymous, params["token"].to_s)
      return go(reverse("invitation_connect", token: params["token"].to_s)) if invitation.try(&.connect)
      result = Partiduo::Api::Auth.accept_invitation(Partiduo::Api::Actor.anonymous, params["token"].to_s,
        Current.login_context(request))
      return page("ui/auth/invitation.html", {"errors" => errors_of(result)}, 422) if result.failure?
      Current.open(request, result.value!.session_token!)
      go(reverse("account_enrollment"))
    end
  end

  # Langue de l'interface, choisie dans la barre supérieure : cookie de
  # langue de Marten, prioritaire sur la langue du navigateur.
  class LanguageHandler < Handler
    def post
      locale = field("locale")
      if Locale.available.includes?(locale)
        request.cookies.set(Marten.settings.i18n.locale_cookie_name, locale, expires: 1.year.from_now,
          same_site: "Lax", secure: Current.secure_cookies?(request))
      end
      go(Navigation.next_path(request, reverse("login")))
    end
  end

  # Connexion fédérée (ADR-002 D3, D-UI-011 révisée, DECISIONS D-R5-010) :
  # départ vers le fournisseur. L'identifiant de requête du cœur est gardé
  # dans un cookie `HttpOnly` ; pour SAML, dont la réponse arrive par un POST
  # intersite, `SameSite=None; Secure` (en HTTPS), sinon `Lax`.
  class LoginFederatedHandler < Handler
    def get
      code = params["code"].to_s
      provider = Partiduo::Api::Auth.login_providers(Partiduo::Api::Actor.anonymous).find(&.code.==(code))
      raise Partiduo::Api::NotFound.new("identity_provider", code) unless provider
      # Élévation (`acr`), ré-authentification d'une approbation (`fresh`),
      # invitation (`login_hint`) : connect, ADR-012.
      options = Partiduo::Api::Auth::FederatedOptions.new(acr: query("acr").to_i? || 0, fresh: query("fresh") == "1",
        login_hint: query("login_hint"))
      start = Partiduo::Api::Auth.begin_federated_login(Partiduo::Api::Actor.anonymous, code, options)
      secure = Current.secure_cookies?(request)
      same_site = provider.kind == "saml" && secure ? "None" : "Lax"
      request.cookies.set(Current::FEDERATED_COOKIE, start.request_id, expires: 10.minutes.from_now, http_only: true,
        secure: secure, same_site: same_site)
      if next_path = Navigation.safe_path(query("next").presence)
        request.cookies.set(Current::FEDERATED_NEXT_COOKIE, next_path, expires: 10.minutes.from_now, http_only: true,
          secure: secure, same_site: same_site)
      end
      Marten::HTTP::Response::Found.new(start.redirect_url)
    end
  end

  # Retour du fournisseur : réponse SAML (POST intersite, sans jeton CSRF —
  # contrôlée par le cœur : signature, `InResponseTo`, usage unique) ou
  # rappel OpenID Connect (GET, `code` et `state`).
  class LoginFederatedReturnHandler < Handler
    protect_from_forgery false

    def get
      complete({"code" => query("code"), "state" => query("state"), "error" => query("error")})
    end

    def post
      complete({"SAMLResponse" => field("SAMLResponse", strip: false), "RelayState" => field("RelayState")})
    end

    private def complete(payload : Hash(String, String)) : Marten::HTTP::Response
      code = params["code"].to_s
      handle = request.cookies[Current::FEDERATED_COOKIE]?.presence || ""
      next_path = Navigation.safe_path(request.cookies[Current::FEDERATED_NEXT_COOKIE]?.presence) || reverse("core:dashboard")
      request.cookies.delete(Current::FEDERATED_COOKIE)
      request.cookies.delete(Current::FEDERATED_NEXT_COOKIE)
      invitation = request.cookies[Current::INVITATION_COOKIE]?.presence
      request.cookies.delete(Current::INVITATION_COOKIE) if invitation
      result = Partiduo::Api::Auth.login_federated(Partiduo::Api::Actor.anonymous, code, handle,
        payload.reject { |_, value| value.empty? }, Current.login_context(request), invitation_token: invitation)
      if view = result.value?
        return go(LoginFlow.destination(request, view, next_path))
      end
      flash["danger"] = result.errors.map { |error| I18n.t(error.key, error.params) }.join(" ")
      go(reverse("login"))
    end
  end

  # Invitation acceptée par connect (ADR-012 D6) : l'invitation est gardée
  # dans un cookie le temps de la connexion ; au retour, le cœur lie le
  # compte connect à l'invité si l'adresse vérifiée par connect est la
  # sienne. Sert aussi de retour après la création du compte chez connect.
  class InvitationConnectHandler < Handler
    def get
      token = params["token"].to_s
      invitation = Partiduo::Api::Auth.invitation_view(Partiduo::Api::Actor.anonymous, token)
      unless invitation && invitation.connect
        flash["danger"] = I18n.t("auth.errors.token.invalid")
        return go(reverse("login"))
      end
      request.cookies.set(Current::INVITATION_COOKIE, token, expires: 15.minutes.from_now, http_only: true,
        secure: Current.secure_cookies?(request), same_site: "Lax")
      go("#{reverse("login_federated", code: Partiduo::Api::Auth::CONNECT_PROVIDER)}?login_hint=#{URI.encode_www_form(invitation.email)}")
    end
  end

  # Déconnexion par canal arrière (OpenID Connect Back-Channel Logout,
  # ADR-012 D8) : connect annonce la fin d'une session ; le cœur vérifie le
  # jeton et ferme les sessions du dossier qu'elle avait ouvertes. Sans
  # cookie ni jeton CSRF : le jeton signé fait foi.
  class LoginFederatedLogoutHandler < Handler
    protect_from_forgery false

    def post
      closed = Partiduo::Api::Auth.federated_backchannel_logout(params["code"].to_s, field("logout_token"))
      response = Marten::HTTP::Response.new(content: "", status: closed.nil? ? 400 : 200)
      response.headers["Cache-Control"] = "no-store"
      response
    end
  end
end
