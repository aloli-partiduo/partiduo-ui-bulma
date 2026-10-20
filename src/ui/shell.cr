# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Coquille de l'écran (maquette de référence, ADR-005 D5) : barre supérieure
  # (dossier, exercice et période, recherche, langue, utilisateur) et menu
  # latéral par domaine. Tout vient de `Partiduo::Api` : le menu de
  # l'utilisateur (`Api::Modules.menu`, modules actifs et permissions), la
  # société (`Api::Core.settings`), la session (`Api::Auth.session`).
  class Shell
    include Marten::Template::Object::Auto

    # Une entrée du menu latéral. `url` nil : écran pas encore livré par
    # l'interface (entrée affichée, désactivée). `badge` : code d'extension ;
    # `count` : compteur d'une extension (`Extensions.counter`), affiché s'il
    # est positif.
    class Item
      include Marten::Template::Object::Auto

      getter code : String
      getter label_key : String
      getter url : String?
      getter active : Bool # ameba:disable Naming/QueryBoolMethods
      getter badge : String?
      getter count : Int64?

      def initialize(@code, @label_key, @url, @active, @badge, count : Int64? = nil)
        @count = count.try { |value| value > 0 ? value : nil }
      end

      def disabled : Bool
        url.nil?
      end
    end

    # Une rubrique : libellé (`nil` pour une entrée de premier niveau sans
    # rubrique, comme le tableau de bord) et ses entrées.
    class Section
      include Marten::Template::Object::Auto

      getter code : String
      getter label_key : String?
      getter items : Array(Item)

      def initialize(@code, @label_key, @items)
      end
    end

    getter sections : Array(Section)
    getter company_name : String?
    getter company_detail : String?
    getter user_name : String
    getter user_email : String
    getter user_initials : String
    getter user_role_key : String
    getter locale : String
    getter locales : Array(String)
    getter current_path : String
    getter fiscal_year : String?
    getter period : String?
    getter period_groups : Array(PeriodGroup)?
    # Mode simplifié de la micro-entreprise (`SimpleMode`, ADR-007 D3) ;
    # `mode_target` : interface vers laquelle bascule le raccourci du menu
    # de l'utilisateur (`simple` ou `full`, préférence enregistrée, D-UI-077) ;
    # `settings_url` : paramètres du module du mode simplifié (micro-entreprise
    # ou profession libérale), dans le menu de l'utilisateur ;
    # `settings_label` : leur libellé.
    property simple : Bool = false
    property mode_target : String? = nil
    # Clé du libellé du raccourci de bascule.
    property mode_label : String? = nil
    property settings_url : String? = nil
    property settings_label : String = "ui.micro.settings.title"
    # Onglets de l'écran « Foyer » d'un dossier foyer, au-dessus du contenu
    # (`FolderKind.tabs`, D-FOY-009) : identité du foyer et paramètres de
    # l'extension, réunis sous une seule entrée du menu.
    property tabs : Array(Screen::Tab)? = nil

    # Une période proposée dans la barre supérieure.
    class PeriodOption
      include Marten::Template::Object::Auto

      getter id : Int64
      getter label : String
      getter selected : Bool

      def initialize(@id, @label, @selected)
      end
    end

    # Les périodes d'un exercice (`<optgroup>`).
    class PeriodGroup
      include Marten::Template::Object::Auto

      getter label : String
      getter options : Array(PeriodOption)

      def initialize(@label, @options)
      end
    end

    # Cookie de la période choisie dans la barre supérieure.
    PERIOD_COOKIE = "partiduo_period"

    def initialize(@sections, @company_name, @company_detail, @user_name, @user_email, @user_role_key,
                   @locale, @locales, @current_path, @fiscal_year = nil, @period = nil, @period_groups = nil)
      @user_initials = initials(@user_name.presence || @user_email)
    end

    # Période de travail : celle choisie dans la barre supérieure (cookie),
    # sinon la période courante du socle (`Api::Core.current_period`).
    def self.working_period(request : Marten::HTTP::Request, actor : Partiduo::Api::Actor) : Partiduo::Api::Core::PeriodView?
      if chosen = request.cookies[PERIOD_COOKIE]?.try(&.to_i64?)
        begin
          return Partiduo::Api::Core.period(actor, chosen)
        rescue Partiduo::Api::NotFound
        end
      end
      Partiduo::Api::Core.current_period(actor)
    end

    def self.build(request : Marten::HTTP::Request, current : Current, format : Format = Format.new(I18n.locale)) : Shell
      actor = current.actor
      session = current.session!
      settings = begin
        Partiduo::Api::Core.settings(actor)
      rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied # session sous le niveau exigé
        nil
      end
      detail = settings.try do |values|
        parts = [] of String
        parts << "SIREN #{values.siren}" unless values.siren.empty?
        parts << values.vat_number if values.siren.empty? && !values.vat_number.empty?
        parts << I18n.t("ui.shell.regime", regime: values.tax_regime.upcase) unless values.tax_regime.empty?
        parts.join(" · ").presence
      end

      period = period_values(request, actor, format)
      simple_module = SimpleMode.mode(request)
      simple = !simple_module.nil?
      # Menus écartés par la variante et le type du dossier, dans les deux
      # interfaces (ADR-011 A2 et A3 : ni achats, ni ventes, ni TVA, ni FEC,
      # ni clôture, ni balances des tiers pour un foyer), dans le vocabulaire
      # du type (« Contacts », « Foyer »).
      # Dossier foyer : les paramètres de l'extension (« Paramètres du
      # foyer ») rejoignent l'entrée « Foyer », qui reste allumée sur leur
      # écran (D-FOY-009).
      household = FolderKind.household_settings(request)
      menu = FolderKind.relabel(
        FolderKind.merge_settings(SimpleMode.without(Partiduo::Api::Modules.menu(actor), SimpleMode.hidden_menus(request)),
          household), FolderKind.of(request))
      counts = Extensions.counts(actor)
      path = FolderKind.menu_path(request.path, household)
      menu_sections = simple_module ? SimpleMode.sections(menu, path, counts, simple_module) : sections(menu, extension_codes(actor), path, counts)
      approvals_section(actor, request.path).try { |section| menu_sections << section }
      shell = new(
        sections: menu_sections,
        company_name: settings.try(&.company_name.presence),
        company_detail: detail,
        user_name: session.full_name,
        user_email: session.email,
        user_role_key: FolderKind.role_key(request, session.role),
        locale: I18n.locale,
        locales: Locale.available,
        current_path: request.full_path,
        fiscal_year: period[:fiscal_year],
        period: period[:period],
        period_groups: period[:period_groups],
      )
      shell.simple = simple
      shell.mode_target = SimpleMode.switch_target(request)
      shell.mode_target.try { |target| shell.mode_label = SimpleMode.switch_label(request, target) }
      if link = simple_module.try { |code| SimpleMode.settings_link(code, actor) }
        shell.settings_url, shell.settings_label = link
        # Le lien du menu de l'utilisateur mène lui aussi à « Foyer ».
        if household && (company = resolve(FolderKind::COMPANY_ROUTE))
          shell.settings_url, shell.settings_label = company, "ui.household.menu.core_company"
        end
      end
      shell.tabs = FolderKind.tabs(request.path, household)
      shell
    end

    # Exercice et période de travail, et les périodes des exercices
    # ouverts pour le choix dans la barre supérieure (ADR-005 D5).
    private def self.period_values(request : Marten::HTTP::Request, actor : Partiduo::Api::Actor, format : Format)
      working = begin
        working_period(request, actor)
      rescue Partiduo::Api::AccessDenied
        return {fiscal_year: nil.as(String?), period: nil.as(String?), period_groups: nil.as(Array(PeriodGroup)?)}
      end
      groups = Partiduo::Api::Core.fiscal_years(actor).reject(&.closed?).compact_map do |year|
        next if year.periods.empty?
        PeriodGroup.new(year.label, year.periods.map do |item|
          label = format.period(item.starts_on, item.ends_on)
          label = I18n.t("ui.shell.period_closed", period: label) if item.closed?
          PeriodOption.new(item.id, label, item.id == working.try(&.id))
        end)
      end
      if working && groups.none?(&.options.any?(&.selected))
        groups.unshift(PeriodGroup.new(working.fiscal_year_label, [PeriodOption.new(working.id, format.period(working.starts_on, working.ends_on), true)]))
      end
      {
        fiscal_year:   working.try(&.fiscal_year_label).as(String?),
        period:        working.try { |item| format.period(item.starts_on, item.ends_on) }.as(String?),
        period_groups: (groups.empty? ? nil : groups).as(Array(PeriodGroup)?),
      }
    end

    # Rubriques du menu : d'abord les domaines, puis les extensions (ADR-005 D5).
    def self.sections(menu : Array(Partiduo::Api::Modules::MenuView), extensions : Set(String), path : String,
                      counts : Hash(String, Int64) = {} of String => Int64) : Array(Section)
      menu.compact_map do |entry|
        if entry.children.empty?
          url = resolve(entry.route)
          Section.new(entry.code, nil, [Item.new(entry.code, entry.label_key, url, active?(url, path),
            badge(entry, extensions), counts[entry.code]?)])
        else
          items = entry.children.map do |child|
            url = resolve(child.route)
            Item.new(child.code, child.label_key, url, active?(url, path), badge(child, extensions), counts[child.code]?)
          end
          Section.new(entry.code, entry.label_key, items)
        end
      end
    end

    # Entrée « Approbations » (A-SEPA-3), propre à l'interface : présente
    # quand l'utilisateur a des demandes en attente à décider ou qu'il a
    # soumises, avec le nombre de celles qu'il peut approuver. Elle ne
    # s'ajoute pas au menu des manifestes : rien n'y paraît dans un dossier
    # dont aucune extension ne soumet d'opération.
    def self.approvals_section(actor : Partiduo::Api::Actor, path : String) : Section?
      pending = Partiduo::Api::Approvals.pending(actor)
      return if pending.empty?
      url = Marten.routes.reverse("core:approvals")
      count = Partiduo::Api::Approvals.pending_count(actor)
      Section.new("APPROVALS", nil, [Item.new("APPROVALS", "ui.approvals.title", url, active?(url, path), nil, count)])
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # URL d'un nom de route du manifeste ; `nil` si l'interface ne le
    # fournit pas encore (ou s'il attend des paramètres).
    def self.resolve(route : String?) : String?
      return if route.nil?
      Marten.routes.reverse(route)
    rescue Marten::Routing::Errors::NoReverseMatch
      nil
    end

    def self.active?(url : String?, path : String) : Bool
      return false if url.nil?
      url == "/" ? path == "/" : (path == url || path.starts_with?(url.rstrip('/') + "/"))
    end

    private def self.badge(entry : Partiduo::Api::Modules::MenuView, extensions : Set(String)) : String?
      extensions.includes?(entry.module_code) ? entry.module_code : nil
    end

    private def self.extension_codes(actor : Partiduo::Api::Actor) : Set(String)
      Partiduo::Api::Modules.list(actor).select(&.kind.==("extension")).map(&.code).to_set
    end

    private def initials(name : String) : String
      words = name.split(/[\s@._-]+/).reject(&.empty?)
      letters = words.size > 1 ? [words.first, words.last] : words.first(1)
      letters.map(&.[0].upcase).join
    end
  end
end
