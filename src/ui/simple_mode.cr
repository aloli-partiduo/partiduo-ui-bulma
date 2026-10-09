# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Mode simplifié (ADR-007 D3, DECISIONS D-UI-061, D-UI-069) : quand le
  # module `MICRO` (micro-entreprise) ou `LIBERAL` (profession libérale,
  # ADR-007 D6) est actif et que l'utilisateur peut lire ses registres,
  # l'interface présente un menu réduit, un tableau de bord centré sur
  # l'essentiel de l'activité et un vocabulaire courant (« encaissé »,
  # « dépensé »). Les deux modules actifs à la fois : la micro-entreprise
  # l'emporte (ordre de `FLAVORS`).
  #
  # L'interface appliquée suit la *préférence de chaque utilisateur*,
  # enregistrée par le cœur avec son compte (`Partiduo::Api::Auth.preferences`,
  # DECISIONS D-UI-077, D-AUTH-016) : « Recettes et dépenses » ou mode
  # simplifié (`simple`), « Comptabilité » ou mode complet (`full`). Tant
  # que la personne n'a rien choisi, défaut de son rôle : `simple` pour un
  # utilisateur de la société, `full` pour le comptable (rôle `accountant`,
  # ADR-002 D4). Elle la règle dans ses préférences (`/account/preferences`)
  # ou par le raccourci de son menu, qui l'enregistre de même.
  #
  # Interfaces offertes (`interfaces`) : pour la profession libérale, la
  # comptabilité seulement si le module Comptabilité est actif ; pour la
  # micro-entreprise, le mode complet au seul comptable (ses utilisateurs de
  # la société restent en mode simplifié, ADR-007 D3). Une préférence qui
  # n'est pas offerte laisse l'interface simplifiée, sans être effacée : elle
  # revient avec le module. Le mode ne change que la présentation : les
  # droits restent ceux du contrat (`Partiduo::Api`), toute route permise
  # reste joignable.
  #
  # Variantes (`Flavor`) : celles de la micro-entreprise et de la profession
  # libérale (`FLAVORS`), puis celles que déclarent les extensions par
  # `PartiduoUi::Extensions.simple_mode` (ADR-011 A2), dans l'ordre de leur
  # déclaration. Une variante porte son menu réduit, son vocabulaire
  # (`Labels`), les interfaces qu'elle offre, ses tuiles et les menus de la
  # Comptabilité qu'elle écarte, dans les deux interfaces.
  module SimpleMode
    MODULE     = "MICRO"
    READ       = "micro.register.read"
    ROLE       = "accountant"
    LIBERAL    = "LIBERAL"
    ACCOUNTING = "ACCOUNTING"
    SIMPLE     = Partiduo::Api::Auth::INTERFACE_SIMPLE
    FULL       = Partiduo::Api::Auth::INTERFACE_FULL

    # Entrée du menu réduit : code de menu d'un manifeste (présent dans le
    # menu de l'utilisateur, donc module actif et permission accordée),
    # libellé du mode simplifié, route servie par l'interface à la place de
    # celle du manifeste (`nil` : celle du manifeste).
    record Entry, code : String, label_key : String, route : String? = nil

    # Menu réduit de la micro-entreprise, dans l'ordre d'ADR-007 D3.
    MENU = [
      Entry.new("DASHBOARD", "ui.micro.menu.dashboard"),
      Entry.new("MICRO_RECEIPTS", "ui.micro.menu.receipts"),
      Entry.new("MICRO_PURCHASES", "ui.micro.menu.purchases"),
      Entry.new("INV_DOCUMENTS", "ui.micro.menu.invoices"),
      Entry.new("MICRO_URSSAF", "ui.micro.menu.urssaf"),
      Entry.new("DOCUMENT_INBOX", "ui.micro.menu.documents"),
    ]

    # Menu réduit de la profession libérale (ADR-007 D6) : le livre-journal
    # unique du manifeste se présente en deux entrées, recettes et dépenses.
    LIBERAL_MENU = [
      Entry.new("DASHBOARD", "ui.liberal.menu.dashboard"),
      Entry.new("LIBERAL_JOURNAL", "ui.liberal.menu.receipts", "liberal:receipts"),
      Entry.new("LIBERAL_JOURNAL", "ui.liberal.menu.expenses", "liberal:expenses"),
      Entry.new("LIBERAL_ASSETS", "ui.liberal.menu.assets"),
      Entry.new("INV_DOCUMENTS", "ui.liberal.menu.invoices"),
      Entry.new("LIBERAL_TAX_RETURN", "ui.liberal.menu.tax_return"),
      Entry.new("DOCUMENT_INBOX", "ui.liberal.menu.documents"),
    ]

    # Menus de la Comptabilité propres aux entreprises (déclaration de TVA,
    # FEC, clôture) : ce qu'écarte une variante qui n'en a pas l'usage
    # (dossier foyer, ADR-011 D2).
    BUSINESS_ACCOUNTING_MENUS = %w[ACC_VAT_RETURN ACC_VAT_RETURNS ACC_VAT_SETTINGS ACC_FEC ACC_CLOSING]

    # Vocabulaire d'une variante, en clés i18n : nom des deux interfaces
    # (`simple`, `full`), raccourcis du menu de l'utilisateur (`to_simple`,
    # `to_full`), aide du choix dans les préférences (`help`), phrase dite
    # quand une seule interface est offerte (`restricted`) et, facultative,
    # celle qui dit que la préférence non offerte est conservée (`kept`,
    # paramètre `interface`).
    record Labels, simple : String, full : String, to_simple : String, to_full : String, help : String,
      restricted : String, kept : String? = nil do
      # Clés rangées sous un même préfixe : `<scope>.simple`, `<scope>.full`,
      # `<scope>.to_simple`, `<scope>.to_full`, `<scope>.help`,
      # `<scope>.restricted`, et `<scope>.kept` si `kept` est vrai.
      def self.under(scope : String, kept : Bool = false) : Labels
        new("#{scope}.simple", "#{scope}.full", "#{scope}.to_simple", "#{scope}.to_full", "#{scope}.help",
          "#{scope}.restricted", kept ? "#{scope}.kept" : nil)
      end

      def interface(interface : String) : String
        interface == SIMPLE ? simple : full
      end

      def switch(target : String) : String
        target == SIMPLE ? to_simple : to_full
      end
    end

    # Interfaces qu'une variante offre, selon le rôle de la session
    # (`accountant`, `member`…) et les pièces actives.
    alias Offer = Proc(String?, Set(String), Array(String))

    # Tuiles du tableau de bord simplifié d'une variante d'extension.
    alias Tiles = Proc(Partiduo::Api::Actor, Format, Array(Dashboard::Tile))

    # Variante du mode simplifié, attachée à une pièce du registre :
    #
    # * `module_code` : pièce qui l'offre, quand elle est active ;
    # * `read` : permission sans laquelle l'utilisateur n'a pas la variante ;
    # * `menu` : menu réduit, sur le modèle de `MENU` et `LIBERAL_MENU` ;
    # * `settings_route`, `settings_permission`, `settings_label` : lien vers
    #   les paramètres de la pièce dans le menu de l'utilisateur (facultatif) ;
    # * `labels` : vocabulaire ;
    # * `offer` : interfaces offertes (`simple` toujours en tête) ;
    # * `hidden_menus` : codes de menu écartés du menu, dans les deux
    #   interfaces (présentation seulement : les routes restent joignables) ;
    # * `tiles` : tuiles du tableau de bord simplifié ; `nil` pour les
    #   tableaux de bord propres à `MICRO` et `LIBERAL`.
    record Flavor, module_code : String, read : String, menu : Array(Entry),
      settings_route : String? = nil, settings_permission : String? = nil, settings_label : String? = nil,
      labels : Labels = Labels.under("ui.simple_mode"),
      offer : Offer = ->(_role : String?, _active : Set(String)) { [SIMPLE, FULL] },
      hidden_menus : Array(String) = [] of String,
      tiles : Tiles? = nil do
      # Lien vers les paramètres de la pièce, s'il est déclaré en entier.
      def settings : {String, String, String}?
        route = settings_route || return
        permission = settings_permission || return
        label = settings_label || return
        {route, permission, label}
      end
    end

    # Variantes des modules officiels : la micro-entreprise d'abord (elle
    # l'emporte quand les deux modules sont actifs).
    FLAVORS = [
      Flavor.new("MICRO", READ, MENU, "micro:settings", "micro.settings.write", "ui.micro.settings.title",
        labels: Labels.new("ui.preferences.micro_simple", "ui.preferences.micro_full", "ui.micro.mode.to_simple",
          "ui.micro.mode.to_full", "ui.preferences.micro_help", "ui.preferences.micro_member"),
        # Le mode complet au seul comptable (ADR-007 D3).
        offer: ->(role : String?, _active : Set(String)) { role == ROLE ? [SIMPLE, FULL] : [SIMPLE] }),
      Flavor.new("LIBERAL", "liberal.register.read", LIBERAL_MENU, "liberal:settings", "liberal.settings.write",
        "ui.liberal.settings.title",
        labels: Labels.new("ui.preferences.liberal_simple", "ui.preferences.liberal_full",
          "ui.liberal.mode.to_simple", "ui.liberal.mode.to_full", "ui.preferences.liberal_help",
          "ui.preferences.liberal_inactive", "ui.preferences.kept"),
        # La comptabilité seulement si le module Comptabilité est actif (ADR-007 D6).
        offer: ->(_role : String?, active : Set(String)) { active.includes?(ACCOUNTING) ? [SIMPLE, FULL] : [SIMPLE] }),
    ]

    @@registered = [] of Flavor

    # Déclare la variante d'une extension. Préférer
    # `PartiduoUi::Extensions.simple_mode`, qui contrôle le code.
    def self.register(flavor : Flavor) : Flavor
      if flavors.any?(&.module_code.==(flavor.module_code))
        raise ArgumentError.new("variante du mode simplifié déjà déclarée : #{flavor.module_code}")
      end
      raise ArgumentError.new("menu réduit vide : #{flavor.module_code}") if flavor.menu.empty?
      @@registered << flavor
      flavor
    end

    # Specs : retire la variante d'une extension.
    def self.unregister(module_code : String) : Nil
      @@registered.reject!(&.module_code.==(module_code))
    end

    # Toutes les variantes, dans l'ordre de préférence : modules officiels,
    # puis extensions dans l'ordre de leur déclaration.
    def self.flavors : Array(Flavor)
      FLAVORS + @@registered
    end

    # Choix d'interface de l'utilisateur de la requête : module du mode
    # simplifié (`flavor`), interfaces offertes, préférence en vigueur
    # (celle qu'il a choisie ou le défaut de son rôle).
    record Choice, flavor : Flavor, interfaces : Array(String), preferences : Partiduo::Api::Auth::PreferencesView do
      # Interface appliquée : la préférence si elle est offerte, sinon
      # l'interface simplifiée.
      def applied : String
        SimpleMode.choose(preferences.interface, interfaces)
      end

      # Plus d'une interface offerte : la personne peut passer de l'une à
      # l'autre.
      def switchable? : Bool
        interfaces.size > 1
      end

      # Libellé d'une interface, dans le vocabulaire de la variante.
      def label_key(interface : String) : String
        flavor.labels.interface(interface)
      end
    end

    # Module du mode simplifié offert à cet acteur (module actif, lecture
    # des registres), `nil` s'il n'y en a pas.
    def self.flavor(actor : Partiduo::Api::Actor) : Flavor?
      flavor(actor, active_modules(actor))
    end

    private def self.flavor(actor : Partiduo::Api::Actor, active : Set(String)) : Flavor?
      return unless actor.authenticated?
      flavors.find { |item| active.includes?(item.module_code) && actor.can?(item.read) }
    end

    private def self.active_modules(actor : Partiduo::Api::Actor) : Set(String)
      return Set(String).new unless actor.authenticated?
      Partiduo::Api::Modules.list(actor).select(&.active).map(&.code).to_set
    rescue Partiduo::Api::AccessDenied
      Set(String).new
    end

    # Le mode simplifié s'offre-t-il à cet acteur ?
    def self.available?(actor : Partiduo::Api::Actor) : Bool
      !flavor(actor).nil?
    end

    # Choix d'interface de la requête, `nil` sans mode simplifié offert
    # (aucune pièce active et lisible qui ait une variante) ; calculé une
    # seule fois.
    def self.choice(request : Marten::HTTP::Request) : Choice?
      cached = request.partiduo_interface_choice
      return cached.as?(Choice) unless cached.nil?
      value = compute_choice(Current.for(request))
      request.partiduo_interface_choice = value || false
      value
    end

    private def self.compute_choice(current : Current) : Choice?
      return unless current.authenticated?
      actor = current.actor
      active = active_modules(actor)
      chosen = flavor(actor, active) || return
      Choice.new(chosen, offered(chosen, current.session.try(&.role), active), Partiduo::Api::Auth.preferences(actor))
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Pièce du mode simplifié de la requête (`MICRO`, `LIBERAL`, ou celle
    # d'une extension), `nil` en mode complet.
    def self.mode(request : Marten::HTTP::Request) : String?
      choice(request).try { |item| item.flavor.module_code if item.applied == SIMPLE }
    end

    def self.enabled?(request : Marten::HTTP::Request) : Bool
      !mode(request).nil?
    end

    # Interfaces offertes, à part pour les specs : profession libérale, la
    # comptabilité avec le module Comptabilité actif ; micro-entreprise, le
    # mode complet au seul comptable ; extension, selon sa déclaration.
    def self.interfaces(module_code : String, role : String?, accounting_active : Bool) : Array(String)
      flavor = flavors.find(&.module_code.==(module_code)) || return [SIMPLE]
      offered(flavor, role, accounting_active ? Set{ACCOUNTING} : Set(String).new)
    end

    # Interfaces offertes par une variante : `simple` toujours, en tête.
    private def self.offered(flavor : Flavor, role : String?, active : Set(String)) : Array(String)
      offered = flavor.offer.call(role, active)
      offered.includes?(FULL) ? [SIMPLE, FULL] : [SIMPLE]
    end

    # Menus écartés par la variante de la requête, dans les deux interfaces
    # (`hidden_menus`) ; vide sans variante.
    def self.hidden_menus(request : Marten::HTTP::Request) : Set(String)
      choice(request).try(&.flavor.hidden_menus.to_set) || Set(String).new
    end

    # Menu de l'utilisateur sans les entrées écartées ; une rubrique dont il
    # ne reste aucune entrée disparaît.
    def self.without(menu : Array(Partiduo::Api::Modules::MenuView), hidden : Set(String)) : Array(Partiduo::Api::Modules::MenuView)
      return menu if hidden.empty?
      menu.compact_map do |entry|
        next if hidden.includes?(entry.code)
        next entry if entry.children.empty?
        children = without(entry.children, hidden)
        next if children.empty? && entry.route.nil?
        entry.copy_with(children: children)
      end
    end

    # Variante appliquée à la requête (mode simplifié en vigueur), `nil` en
    # mode complet.
    def self.applied_flavor(request : Marten::HTTP::Request) : Flavor?
      choice(request).try { |item| item.flavor if item.applied == SIMPLE }
    end

    # Interface appliquée, à part pour les specs : la préférence si elle est
    # offerte, sinon l'interface simplifiée (la préférence n'est pas effacée).
    def self.choose(preference : String, interfaces : Array(String)) : String
      interfaces.includes?(preference) ? preference : SIMPLE
    end

    # Raccourci du menu de l'utilisateur : interface vers laquelle il bascule
    # (`simple` ou `full`), `nil` s'il n'a pas le choix.
    def self.switch_target(request : Marten::HTTP::Request) : String?
      item = choice(request) || return
      return unless item.switchable?
      item.applied == SIMPLE ? FULL : SIMPLE
    end

    # Clé du libellé du raccourci vers `target` : vocabulaire de la variante
    # (« Passer à la comptabilité » pour la profession libérale).
    def self.switch_label(request : Marten::HTTP::Request, target : String) : String
      (choice(request).try(&.flavor) || FLAVORS.first).labels.switch(target)
    end

    # Paramètres du module du mode simplifié (menu de l'utilisateur) : URL
    # et libellé, si l'acteur peut les modifier.
    def self.settings_link(module_code : String, actor : Partiduo::Api::Actor) : {String, String}?
      item = flavors.find(&.module_code.==(module_code)) || return
      route, permission, label = item.settings || return
      return unless actor.can?(permission)
      url = Shell.resolve(route) || return
      {url, label}
    end

    # Menu réduit : entrées du menu de l'utilisateur retenues par le menu
    # de la variante (`MENU`, `LIBERAL_MENU`, menu d'une extension), dans
    # son ordre, sans rubrique.
    def self.sections(menu : Array(Partiduo::Api::Modules::MenuView), path : String,
                      counts : Hash(String, Int64) = {} of String => Int64,
                      module_code : String = MODULE) : Array(Shell::Section)
      entries = flatten(menu).to_h { |entry| {entry.code, entry} }
      reduced = flavors.find(&.module_code.==(module_code)).try(&.menu) || MENU
      items = reduced.compact_map do |wanted|
        entry = entries[wanted.code]? || next
        url = Shell.resolve(wanted.route || entry.route)
        next if url.nil?
        Shell::Item.new(wanted.code, wanted.label_key, url,
          Shell.active?(url, path), nil, counts[wanted.code]?)
      end
      [Shell::Section.new("SIMPLE", nil, items)]
    end

    private def self.flatten(menu : Array(Partiduo::Api::Modules::MenuView)) : Array(Partiduo::Api::Modules::MenuView)
      menu.flat_map { |entry| [entry] + flatten(entry.children) }
    end
  end
end
