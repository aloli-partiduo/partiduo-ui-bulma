# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des pages du compte : ouvertes à une session sous le niveau exigé,
  # c'est par elles qu'elle s'élève (ADR-002 D6).
  abstract class AccountHandler < ScreenHandler
    private def screen_access : Symbol
      :account
    end

    # Fragment de gabarit rendu en chaîne (réponses JSON de `passkey.js`).
    def fragment(template : String, values : Hash(String, _)) : String
      context = Marten::Template::Context.from(values, request)
      Marten.templates.get_template(template).render(context)
    end

    def codes_page(codes : Array(String), continue_url : String, status : Int32 = 200)
      page("ui/account/recovery_codes.html", codes_values(codes, continue_url), status)
    end

    # Les codes valent pour le compte de l'utilisateur dans CE dossier (chaque
    # instance a ses comptes) : le nom du fichier et sa première ligne disent
    # lequel, pour qui gère plusieurs dossiers.
    def codes_values(codes : Array(String), continue_url : String) : Hash(String, String | Array(String))
      host = request.host
      text = "#{I18n.t("ui.codes.file_header", host: host)}\r\n\r\n#{codes.join("\r\n")}\r\n"
      {
        "codes"          => codes,
        "codes_href"     => "data:text/plain;charset=utf-8,#{URI.encode_path_segment(text)}",
        "codes_filename" => I18n.t("ui.codes.filename", host: host),
        "continue_url"   => continue_url,
      }
    end
  end

  # Page « sécurité du compte » : niveau atteint, niveau exigé, ce qu'il
  # manque pour monter, méthodes enrôlées, élévation de la session.
  class SecurityHandler < AccountHandler
    # Clé i18n du libellé de chaque niveau (1 à 3), définie par le cœur.
    LEVEL_KEYS = {1 => "auth.levels.password", 2 => "auth.levels.two_factor", 3 => "auth.levels.passkey"}

    def get
      security_page
    end

    def security_page(errors = {} of String => Array(String), status : Int32 = 200)
      overview = Partiduo::Api::Auth.security_overview(current.actor)
      session = current.session!
      passkeys = overview.passkeys.map do |passkey|
        {
          "id"           => passkey.id,
          "name"         => passkey.name.presence || I18n.t("ui.security.passkey_unnamed"),
          "created_at"   => passkey.created_at.try { |time| fmt.timestamp_date(time) } || "",
          "last_used_at" => passkey.last_used_at.try { |time| fmt.timestamp_date(time) },
          "synced"       => passkey.backup_state,
        }
      end
      levels = (1..3).map do |level|
        {
          "level"    => level,
          "key"      => LEVEL_KEYS[level],
          "reached"  => session.level >= level,
          "possible" => overview.achievable_level >= level,
          "required" => overview.required_level == level,
        }
      end
      # Variables à plat : Marten ne retrouve pas les clés d'un dictionnaire de
      # plus de huit entrées (DECISIONS D-UI-010).
      page("ui/account/security.html", {
        "security_session_level"    => session.level.to_s,
        "security_required_level"   => overview.required_level.to_s,
        "security_achievable_level" => overview.achievable_level.to_s,
        "security_elevation"        => session.level < overview.required_level,
        "security_connect_url"      => connect_elevation_url(overview.required_level, reverse("account_security")),
        "security_has_password"     => overview.has_password,
        "security_has_totp"         => overview.methods.includes?("totp"),
        "security_has_passkey"      => overview.methods.includes?("passkey"),
        "security_codes_remaining"  => overview.recovery_codes_remaining,
        "security_sensitive"        => session.level >= 2,
        "levels"                    => levels,
        "missing"                   => listed(overview.missing.map { |item| "auth.missing.#{item}" }),
        "passkeys"                  => listed(passkeys),
        "errors"                    => errors,
        "policy"                    => PasswordPolicy.hints,
      }, status)
    end
  end

  # Changement (ou première saisie) du mot de passe.
  class PasswordChangeHandler < SecurityHandler
    def post
      password = field("new_password", strip: false)
      unless password == field("confirmation", strip: false)
        return security_page(field_error("confirmation", "ui.password.mismatch"), 422)
      end
      save_password(password)
    end

    private def save_password(password : String)
      input = Partiduo::Api::Auth::ChangePasswordInput.new(password, field("current_password", strip: false).presence)
      result = Partiduo::Api::Auth.change_password(current.actor, input)
      if result.failure?
        security_page(errors_of(result), 422)
      else
        flash["success"] = I18n.t("ui.password.changed")
        go(reverse("account_security"))
      end
    end
  end

  # Élévation de la session par un code de l'application d'authentification.
  class ElevateTotpHandler < SecurityHandler
    def post
      result = Partiduo::Api::Auth.elevate_with_totp(current.actor, current.token || "", field("code").delete(' '))
      if result.failure?
        security_page(errors_of(result), 422)
      else
        flash["success"] = I18n.t("ui.security.elevated")
        go(Navigation.next_path(request, reverse("account_security")))
      end
    end
  end

  # Élévation par passkey : options, puis vérification (JSON, `passkey.js`).
  class ElevatePasskeyOptionsHandler < AccountHandler
    def post
      json(PasskeyJson.request(Partiduo::Api::Auth.begin_passkey_login(Partiduo::Api::Actor.anonymous)))
    end
  end

  class ElevatePasskeyHandler < AccountHandler
    def post
      input = PasskeyJson.assertion(request.data, Current.login_context(request))
      result = Partiduo::Api::Auth.elevate_with_passkey(current.actor, current.token || "", input)
      if result.failure?
        return json(PasskeyJson.outcome(false, error: result.errors.map(&.message).join(' ')), 422)
      end
      flash["success"] = I18n.t("ui.security.elevated")
      json(PasskeyJson.outcome(true, redirect: Navigation.next_path(request, reverse("account_security"))))
    end
  end

  # Nouveaux codes de récupération (niveau 2), affichés une seule fois.
  class RecoveryCodesHandler < AccountHandler
    def post
      result = Partiduo::Api::Auth.regenerate_recovery_codes(current.actor)
      if result.failure?
        flash["danger"] = result.errors.map(&.message).join(' ')
        return go(reverse("account_security"))
      end
      codes_page(result.value!.codes, reverse("account_security"))
    end
  end
end
