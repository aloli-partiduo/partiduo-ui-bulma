# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des handlers de l'interface : utilisateur courant, lecture des
  # formulaires, erreurs du contrat traduites, redirections compatibles HTMX.
  abstract class Handler < Marten::Handlers::Base
    before_dispatch :activate_user_locale

    rescue_from Partiduo::Api::AccessDenied do
      if error.is_a?(Partiduo::Api::ModuleDisabled)
        # Module inactif : l'écran n'existe pas sur cette instance (ADR-006).
        ErrorPage.render(request, 404)
      elsif error.is_a?(Partiduo::Api::Auth::ElevationRequired)
        flash["warning"] = I18n.t(error.as(Partiduo::Api::AccessDenied).key)
        Navigation.redirect(request, reverse("account_security"))
      else
        ErrorPage.render(request, current.authenticated? ? 403 : 401)
      end
    end

    rescue_from Partiduo::Api::NotFound do
      ErrorPage.render(request, 404)
    end

    def current : Current
      Current.for(request)
    end

    # Valeur d'un champ de formulaire, sans espaces autour pour les champs
    # qui n'en admettent pas (codes, adresses).
    def field(name : String, strip : Bool = true) : String
      value = request.data.fetch(name, nil).try(&.to_s) || ""
      strip ? value.strip : value
    end

    def query(name : String) : String
      request.query_params.fetch(name, nil).try(&.to_s) || ""
    end

    def htmx? : Bool
      Navigation.htmx?(request)
    end

    def go(url : String) : Marten::HTTP::Response
      Navigation.redirect(request, url)
    end

    # Erreurs d'un résultat du contrat, traduites, rangées par champ
    # (`base` pour l'ensemble) : `{"email" => ["…"], "base" => ["…"]}`.
    def errors_of(result) : Hash(String, Array(String))
      errors = {} of String => Array(String)
      format = Format.new(I18n.locale)
      result.errors.each { |error| (errors[error.field] ||= [] of String) << format.message(error) }
      errors
    end

    def field_error(field : String, key : String, params = {} of String => String) : Hash(String, Array(String))
      {field => [I18n.t(key, params)]}
    end

    # Liste pour un gabarit : `nil` si elle est vide (pour Marten, une liste
    # vide est vraie dans un `{% if %}`).
    def listed(items : Array(T)) : Array(T)? forall T
      items.empty? ? nil : items
    end

    # Page complète ; `status` 422 pour un formulaire refusé.
    def page(template : String, values = {} of String => String, status : Int32 = 200) : Marten::HTTP::Response
      context["ui_path"] = request.full_path
      # Provenance du code (AGPL-3.0, art. 13) : pied des pages d'accès.
      Licences.footer.each { |key, value| context[key] = value }
      render(template, values, status: status)
    end

    # Refus de la protection CSRF de Marten : page traduite, motif au journal.
    private def reject(message)
      Marten::Log.info { "refus CSRF : #{message}" }
      ErrorPage.expired(request)
    end

    private def activate_user_locale
      Locale.activate_for(request, current)
      nil
    end
  end

  # Écran de l'application, derrière la connexion : coquille (barre
  # supérieure, menu des modules actifs), contrôle du niveau de session.
  #
  # `screen_access` : `:full` (défaut, droits requis), `:account` (pages de
  # sécurité, ouvertes à une session sous le niveau exigé pour qu'elle
  # s'élève), `:enrollment` (ouvertes aussi à la session d'enrôlement).
  abstract class ScreenHandler < Handler
    before_dispatch :require_screen_access
    before_render :add_shell

    private def screen_access : Symbol
      :full
    end

    private def require_screen_access
      current = self.current
      return Navigation.to_login(request) unless current.authenticated?

      if current.enrollment?
        return go(reverse("account_enrollment")) unless screen_access == :enrollment
      elsif current.elevation_required? && screen_access == :full
        flash["warning"] = I18n.t("ui.security.elevation_needed")
        return go(reverse("account_security"))
      end
      nil
    end

    private def add_shell
      current = self.current
      return if current.enrollment? || !current.authenticated?
      context["shell"] = Shell.build(request, current, fmt)
      nil
    end

    @fmt : Format?
    @settings_country : String?
    @active_modules : Set(String)?

    # Présentation des nombres et des dates : langue de l'utilisateur, pays
    # de la société.
    def fmt : Format
      @fmt ||= Format.new(I18n.locale, company_country)
    end

    def company_country : String
      @settings_country ||= begin
        Partiduo::Api::Core.settings(current.actor).country_code
      rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
        ""
      end
    end

    def can?(permission : String) : Bool
      current.actor.can?(permission)
    end

    # Module ou extension actif sur l'instance (`Api::Modules.list`).
    def module_active?(code : String) : Bool
      (@active_modules ||= Partiduo::Api::Modules.list(current.actor).select(&.active).map(&.code).to_set).includes?(code)
    end

    def id_param(name : String = "id") : Int64
      params[name].to_s.to_i64
    end

    # Liste préparée : filtre `q`, tri `sort`, puis export CSV ou PDF
    # (`format=csv`, `format=pdf`) ou page `page`. Le tableau offre alors
    # les deux exports (B-CRIT-001).
    def prepare(table : Table, filter : Bool = true) : Table
      table.filter!(query("q")) if filter
      table.sort!(query("sort")) unless query("sort").empty?
      table.paginate!(query("page").to_i? || 1) unless export?
      table.pdf = true if table.exportable
      table
    end

    def csv? : Bool
      query("format") == "csv"
    end

    def pdf? : Bool
      query("format") == "pdf"
    end

    def export? : Bool
      csv? || pdf?
    end

    # Export d'une liste dans le format demandé.
    def export_response(table : Table, name : String) : Marten::HTTP::Response
      pdf? ? pdf_response([{nil, table}], table.caption, name) : csv_response(table, name)
    end

    # PDF/A-2b de tableaux déjà préparés (toutes les lignes filtrées et
    # triées), par le service neutre du cœur (`Api::Core.table_pdf`) :
    # plusieurs tableaux se suivent sous leur titre de section. `summary` :
    # sous-titres (période, critères).
    def pdf_response(tables : Array({String?, Table}), title : String, name : String,
                     summary : Array(String) = [] of String) : Marten::HTTP::Response
      input = TablePdf.input(tables, title, "#{name}-#{file_day}", summary)
      result = Partiduo::Api::Core.table_pdf(current.actor, input)
      if file = result.value?
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
        return response
      end
      Marten::HTTP::Response.new(content: result.errors.map { |error| fmt.message(error) }.join("\n"),
        content_type: "text/plain; charset=utf-8", status: 422)
    end

    # PDF des tableaux des sections d'un écran (éditions, rapports).
    def sections_pdf_response(title : String, sections : Array(Screen::Section), name : String,
                              summary : Array(Screen::Item)? = nil) : Marten::HTTP::Response
      tables = sections.compact_map { |section| section.table.try { |table| {section.title.as(String?), table} } }
      lines = (summary || [] of Screen::Item).compact_map do |item|
        I18n.t("ui.table.pdf_criterion", label: item.label, value: item.value) unless item.value.empty?
      end
      pdf_response(tables, title, name, lines)
    end

    def csv_response(table : Table, name : String) : Marten::HTTP::Response
      response = Marten::HTTP::Response.new(content: table.to_csv(fmt), content_type: "text/csv; charset=utf-8")
      response["Content-Disposition"] = %(attachment; filename="#{name}-#{file_day}.csv")
      response
    end

    # Jour d'un export, dans son nom de fichier : la date du jour du dossier
    # (`Core.today`, son fuseau), pas celle du serveur.
    def file_day : String
      Partiduo::Api::Core.today.to_s("%Y%m%d")
    end

    # Élément du fil d'Ariane, dans le vocabulaire du type de dossier
    # (« Foyer » pour « Société », `FolderKind::LABEL_KEYS`).
    def crumb(label_key : String, url : String? = nil) : Screen::Crumb
      Screen::Crumb.new(I18n.t(kind_key(label_key)), url)
    end

    # Clé i18n d'un libellé dans le vocabulaire du type de dossier de la
    # requête (`FolderKind.label_key`).
    def kind_key(label_key : String) : String
      FolderKind.label_key(request, label_key)
    end

    # Nature d'une fiche (`cards.kinds.*`) dans le vocabulaire du type de
    # dossier de la requête (« Payeur » dans un foyer).
    def card_kind_label(kind : String) : String
      I18n.t(FolderKind.card_kind_key(FolderKind.of(request), kind))
    end

    # Nom d'une catégorie de fiches dans le vocabulaire du type de dossier
    # (`FolderKind.category_name`).
    def category_label(code : String, name : String) : String
      FolderKind.category_name(FolderKind.of(request), code, name)
    end
  end
end

module PartiduoUi
  abstract class Handler
    # Élévation ou ré-authentification par connect (ADR-012) pour une
    # session qu'il a ouverte : connect fait monter au niveau demandé
    # (`acr`) — passkey pour le niveau 3 — et, avec `fresh`, redemande
    # l'authentification. `nil` si la session n'est pas une session connect.
    def connect_elevation_url(level : Int32, next_path : String, fresh : Bool = false) : String?
      session = Current.for(request).session
      return unless session && session.method == "federated" && Partiduo::Api::Auth.connect_configured?
      values = {"acr" => level.to_s, "next" => next_path}
      values["fresh"] = "1" if fresh
      "#{reverse("login_federated", code: Partiduo::Api::Auth::CONNECT_PROVIDER)}?#{URI::Params.encode(values)}"
    end
  end
end
