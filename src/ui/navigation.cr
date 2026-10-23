# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Redirections de l'interface, compatibles HTMX : une requête HTMX reçoit
  # `HX-Redirect` (le navigateur change de page) au lieu d'un 302 que HTMX
  # suivrait en silence.
  module Navigation
    def self.htmx?(request : Marten::HTTP::Request) : Bool
      request.headers["HX-Request"]? == "true"
    end

    def self.redirect(request : Marten::HTTP::Request, url : String) : Marten::HTTP::Response
      if htmx?(request)
        response = Marten::HTTP::Response.new(content: "", content_type: "text/html", status: 200)
        response["HX-Redirect"] = url
        response
      else
        Marten::HTTP::Response::Found.new(url)
      end
    end

    # Vers la connexion, avec retour à la page demandée (GET seulement).
    def self.to_login(request : Marten::HTTP::Request) : Marten::HTTP::Response
      login = Marten.routes.reverse("login")
      target = request.get? ? request.full_path : nil
      url = target && safe_path(target) && target != "/" ? "#{login}?#{URI::Params.encode({"next" => target})}" : login
      redirect(request, url)
    end

    # Chemin de retour admis : relatif au site, jamais vers un autre hôte.
    def self.safe_path(value : String?) : String?
      return if value.nil? || value.empty?
      return unless value.starts_with?('/')
      return if value.starts_with?("//") || value.starts_with?("/\\") || value.includes?('\n') || value.includes?('\r')
      value
    end

    def self.next_path(request : Marten::HTTP::Request, fallback : String = Marten.routes.reverse("core:dashboard")) : String
      safe_path(request.data.fetch("next", nil).try(&.to_s)) ||
        safe_path(request.query_params.fetch("next", nil).try(&.to_s)) || fallback
    end
  end

  # Langue de l'interface.
  #
  # . Session ouverte par connect (D-UI-082) : la langue du compte connect,
  #   reprise à chaque connexion ; si le compte n'en a pas, la première
  #   langue livrée que demande le navigateur, puis la langue du dossier,
  #   puis le français. Ni le cookie ni la langue enregistrée dans le dossier
  #   ne la contredisent.
  # . Autre session, ou visiteur : le cookie de langue (choix explicite,
  #   valable pour la visite), la langue de l'utilisateur connecté, la
  #   première langue livrée que demande le navigateur (middleware I18n de
  #   Marten), puis la langue configurée du dossier (`default_locale`,
  #   D-UI-080) au lieu du français de Marten.
  module Locale
    def self.activate_for(request : Marten::HTTP::Request, current : Current) : Nil
      cookie = request.cookies[Marten.settings.i18n.locale_cookie_name]?
      header = request.headers["Accept-Language"]?.to_s
      chosen = resolve(current.session, cookie, header) { Partiduo::Api::Core.default_locale }
      I18n.activate(chosen) if chosen
      nil
    end

    # Langue à activer, `nil` pour garder celle du middleware de Marten
    # (cookie de langue livrée, ou langue livrée du navigateur). Le bloc donne
    # la langue configurée du dossier ; il n'est appelé que si elle sert.
    def self.resolve(session : Partiduo::Api::Auth::SessionView?, cookie : String?, header : String,
                     & : -> String) : String?
      if session && session.locale_from_connect
        return session.locale if available.includes?(session.locale)
        return browser_locale(header) || yield
      end
      return if available.includes?(cookie.to_s)
      locale = session.try(&.locale)
      return locale if locale && available.includes?(locale)
      return if browser_locale(header)
      yield
    end

    def self.available : Array(String)
      Partiduo::LOCALES.map(&.to_s)
    end

    # Première langue livrée que demande le navigateur, `nil` sinon. Mêmes
    # règles que le middleware de Marten : étiquettes par priorité
    # décroissante, langue de base (`de-DE` → `de`), arrêt au joker `*`.
    def self.browser_locale(header : String) : String?
      tags = header.downcase.split(',').each_with_index.to_a.compact_map do |(part, index)|
        tag, _, parameters = part.partition(';')
        tag = tag.strip
        next if tag.empty?
        priority = parameters.match(/q\s*=\s*([0-9.]+)/).try(&.[1].to_f?) || 1.0
        {tag, priority, index}
      end
      tags.sort_by! { |(_, priority, index)| {-priority, index} }
      tags.each do |(tag, _, _)|
        return if tag == "*"
        base = tag.split('-').first
        return base if available.includes?(base)
      end
      nil
    end
  end

  # Page d'erreur des routes publiques d'extension (404, 413, 429 ;
  # A-FRM-1) : ni script, ni menu, ni lien vers le dossier.
  module PublicErrorPage
    def self.render(request : Marten::HTTP::Request, status : Int32) : Marten::HTTP::Response
      context = Marten::Template::Context.from({"status" => status, "locale" => I18n.locale}, request)
      content = Marten.templates.get_template("ui/errors/public.html").render(context)
      Marten::HTTP::Response.new(content: content, content_type: "text/html; charset=utf-8", status: status)
    end
  end

  # Page d'erreur (403, 404) rendue hors d'un handler (middleware).
  module ErrorPage
    # Formulaire refusé par la protection CSRF de Marten (jeton absent ou
    # périmé, origine refusée) : page traduite « formulaire expiré » au lieu
    # du texte brut en anglais de Marten. `public` : page d'une route
    # publique d'extension, sans lien vers le dossier (A-FRM-1).
    def self.expired(request : Marten::HTTP::Request, public : Bool = false) : Marten::HTTP::Response
      values = {"status" => 403, "expired" => true, "public" => public, "locale" => I18n.locale}
      context = Marten::Template::Context.from(values, request)
      content = Marten.templates.get_template("ui/errors/http.html").render(context)
      Marten::HTTP::Response.new(content: content, content_type: "text/html; charset=utf-8", status: 403)
    end

    def self.render(request : Marten::HTTP::Request, status : Int32) : Marten::HTTP::Response
      context = Marten::Template::Context.from({"status" => status, "locale" => I18n.locale}, request)
      Licences.footer.each { |key, value| context[key] = value }
      content = Marten.templates.get_template("ui/errors/error.html").render(context)
      Marten::HTTP::Response.new(content: content, content_type: "text/html; charset=utf-8", status: status)
    end
  end
end
