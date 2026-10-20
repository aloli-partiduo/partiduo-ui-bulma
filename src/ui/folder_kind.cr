# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Type de dossier vu de l'interface (ADR-011 A3) : `company` (entreprise,
  # micro-entreprise, profession libérale) ou `household` (foyer), choisi au
  # provisionnement et lu dans la configuration du dossier
  # (`Partiduo::Api::Core::SettingsView#kind`).
  #
  # Le type règle la présentation par défaut, avec ou sans variante du mode
  # simplifié (`SimpleMode`) : menus écartés (`SimpleMode::KIND_HIDDEN_MENUS`),
  # tableau de bord (`Dashboard#build_household`), vocabulaire des rôles
  # (« Membre du foyer ») et libellés des menus, titres et fils d'Ariane
  # (« Contacts », « Foyer », `LABEL_KEYS`), champs de la société
  # (`BUSINESS_FIELDS`, écartés d'un foyer). Une variante d'extension
  # déclarée par `Extensions.simple_mode` s'y ajoute : ses menus écartés
  # s'unissent à ceux du type, ses tuiles remplacent celles du foyer dans
  # l'interface simplifiée, et ses paramètres rejoignent l'entrée « Foyer »
  # (`household_settings`, deux onglets, D-FOY-009).
  module FolderKind
    COMPANY   = Partiduo::Api::InitialData::COMPANY
    HOUSEHOLD = Partiduo::Api::InitialData::HOUSEHOLD

    # Libellés des rôles propres à un type de dossier ; les autres rôles
    # gardent celui du cœur (`auth.roles.<rôle>`).
    ROLE_KEYS = {
      HOUSEHOLD => {"member" => "ui.household.roles.member"},
    }

    # Libellés propres à un type de dossier : clé du cœur ou de l'interface
    # remplacée par celle du type, dans le menu (`relabel`), les fils
    # d'Ariane (`Handler#crumb`) et les titres (`Handler#kind_key`). Un
    # foyer dit « Contacts » pour « Tiers et articles » et pour « Tiers »,
    # « Comptes et contacts » pour « Comptes et tiers », « Foyer » pour
    # « Société » et « Nom du foyer » pour la raison sociale. Les autres
    # types gardent les clés d'origine.
    LABEL_KEYS = {
      HOUSEHOLD => {
        "cards.menu.cards_list"             => "ui.household.menu.cards_list",
        "core.menu.core_company"            => "ui.household.menu.core_company",
        "accounting.menu.acc_accounts"      => "ui.household.menu.acc_accounts",
        "ui.company.edit"                   => "ui.household.company.edit",
        "ui.company.intro"                  => "ui.household.company.intro",
        "ui.company.updated"                => "ui.household.company.updated",
        "ui.company.identity"               => "ui.household.company.identity",
        "core.settings.fields.company_name" => "ui.household.company.name",
        "ui.cards.parties"                  => "ui.household.cards.parties",
        "ui.cards.new_party"                => "ui.household.cards.new_party",
        "ui.cards.empty"                    => "ui.household.cards.empty",
        "ui.cards.csv_name"                 => "ui.household.cards.csv_name",
        "ui.cards.search_placeholder"       => "ui.household.cards.search_placeholder",
        "ui.accounts.selection"             => "ui.household.accounts.selection",
        "ui.accounts.pick"                  => "ui.household.accounts.pick",
        "ui.accounts.intro"                 => "ui.household.accounts.intro",
        "ui.accounts.not_found"             => "ui.household.accounts.not_found",
      },
    }

    # Champs de la société propres à une entreprise, que l'écran « Foyer »
    # ne montre ni ne propose (forme juridique, capital, RCS, SIREN, TVA
    # intracommunautaire, identifiant créancier SEPA) : le formulaire garde
    # leurs valeurs enregistrées.
    BUSINESS_FIELDS = %w[legal_form share_capital rcs siren vat_number creditor_identifier]

    # Écran de la société, « Foyer » d'un dossier foyer.
    COMPANY_ROUTE = "core:company"

    # Paramètres d'une variante d'extension réunis à l'écran « Foyer »
    # (D-FOY-009) : route et adresse de l'écran de l'extension, clé de son
    # libellé (`SimpleMode::Flavor#settings`).
    record Settings, route : String, url : String, label_key : String

    # Type du dossier de la requête ; `company` sans session ou avant le
    # provisionnement. Lu une seule fois par requête.
    def self.of(request : Marten::HTTP::Request) : String
      request.partiduo_folder_kind ||= of(Current.for(request).actor)
    end

    def self.of(actor : Partiduo::Api::Actor) : String
      return COMPANY unless actor.authenticated?
      Partiduo::Api::Core.settings(actor).kind
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      COMPANY
    end

    def self.household?(request : Marten::HTTP::Request) : Bool
      of(request) == HOUSEHOLD
    end

    # Clé i18n du libellé d'un rôle dans ce type de dossier (`member` :
    # « Membre du foyer » pour un foyer, « Utilisateur de la société »
    # ailleurs).
    def self.role_key(kind : String, role : String) : String
      ROLE_KEYS[kind]?.try(&.[role]?) || "auth.roles.#{role}"
    end

    def self.role_key(request : Marten::HTTP::Request, role : String) : String
      role_key(of(request), role)
    end

    # Clé i18n d'un libellé dans ce type de dossier : celle du type
    # (`LABEL_KEYS`), sinon `key` elle-même.
    def self.label_key(kind : String, key : String) : String
      LABEL_KEYS[kind]?.try(&.[key]?) || key
    end

    def self.label_key(request : Marten::HTTP::Request, key : String) : String
      label_key(of(request), key)
    end

    # Champ de la société montré dans ce type de dossier.
    def self.company_field?(kind : String, name : String) : Bool
      kind != HOUSEHOLD || !BUSINESS_FIELDS.includes?(name)
    end

    # Paramètres de la variante d'extension du dossier foyer de la requête,
    # que l'entrée « Foyer » réunit à l'identité du foyer (une seule entrée
    # au menu, deux onglets) ; `nil` hors d'un foyer, sans variante qui
    # déclare ses paramètres, ou sans le droit de les ouvrir.
    def self.household_settings(request : Marten::HTTP::Request) : Settings?
      return unless household?(request)
      household_settings(Current.for(request).actor)
    end

    def self.household_settings(actor : Partiduo::Api::Actor) : Settings?
      flavor = SimpleMode.flavor(actor) || return
      route, permission, label = flavor.settings || return
      return unless actor.can?(permission)
      url = Shell.resolve(route) || return
      Settings.new(route, url, label)
    end

    # Menu sans l'entrée des paramètres réunis à « Foyer », quand le menu a
    # cette entrée ; une rubrique dont il ne reste rien disparaît.
    def self.merge_settings(menu : Array(Partiduo::Api::Modules::MenuView), settings : Settings?) : Array(Partiduo::Api::Modules::MenuView)
      return menu unless settings && routes(menu).includes?(COMPANY_ROUTE)
      without_route(menu, settings.route)
    end

    # Chemin qui désigne l'entrée active du menu : sur l'écran des
    # paramètres réunis, c'est « Foyer ».
    def self.menu_path(path : String, settings : Settings?) : String
      return path unless settings && Shell.active?(settings.url, path)
      Shell.resolve(COMPANY_ROUTE) || path
    end

    # Onglets de l'écran « Foyer » (identité du foyer, paramètres de
    # l'extension), sur l'un ou l'autre de ces écrans seulement.
    def self.tabs(path : String, settings : Settings?) : Array(Screen::Tab)?
      settings || return
      company = Shell.resolve(COMPANY_ROUTE) || return
      on_company = Shell.active?(company, path)
      on_settings = Shell.active?(settings.url, path)
      return unless on_company || on_settings
      [Screen::Tab.new(I18n.t("ui.household.tabs.identity"), company, on_company),
       Screen::Tab.new(I18n.t(settings.label_key), settings.url, on_settings)]
    end

    private def self.routes(menu : Array(Partiduo::Api::Modules::MenuView)) : Array(String)
      menu.flat_map { |entry| [entry.route].compact + routes(entry.children) }
    end

    private def self.without_route(menu : Array(Partiduo::Api::Modules::MenuView), route : String) : Array(Partiduo::Api::Modules::MenuView)
      menu.compact_map do |entry|
        next if entry.route == route
        next entry if entry.children.empty?
        children = without_route(entry.children, route)
        next if children.empty? && entry.route.nil?
        entry.copy_with(children: children)
      end
    end

    # Menu de l'utilisateur dans le vocabulaire du type de dossier : chaque
    # entrée et chaque rubrique prend le libellé du type (`LABEL_KEYS`).
    # Présentation seulement : codes et routes ne changent pas.
    def self.relabel(menu : Array(Partiduo::Api::Modules::MenuView), kind : String) : Array(Partiduo::Api::Modules::MenuView)
      keys = LABEL_KEYS[kind]? || return menu
      menu.map do |entry|
        entry.copy_with(label_key: keys[entry.label_key]? || entry.label_key,
          children: entry.children.empty? ? entry.children : relabel(entry.children, kind))
      end
    end
  end
end
