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

  # Langue de l'interface : le cookie de langue (choix explicite) prime, puis
  # la langue de l'utilisateur connecté, puis celle du navigateur (middleware
  # I18n de Marten).
  module Locale
    def self.activate_for(request : Marten::HTTP::Request, current : Current) : Nil
      return if request.cookies[Marten.settings.i18n.locale_cookie_name]?
      locale = current.session.try(&.locale)
      I18n.activate(locale) if locale && Partiduo::LOCALES.includes?(locale)
    end

    def self.available : Array(String)
      Partiduo::LOCALES.map(&.to_s)
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
