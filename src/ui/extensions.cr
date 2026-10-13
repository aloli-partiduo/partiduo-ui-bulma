# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Montage des interfaces d'extension sous `/ext/<CODE>/` et contrôle d'accès
  # *avant* le handler, à partir du manifeste (ADR-003 D3, ADR-005 D4).
  #
  # Le dossier `ui/bulma/` d'une extension déclare ses routes Marten et les
  # confie à l'interface :
  #
  # ```
  # module Skel::Ui
  #   ROUTES = Marten::Routing::Map.draw do
  #     path "/", Skel::Ui::IndexHandler, name: "index"
  #     path "/edit", Skel::Ui::EditHandler, name: "edit"
  #   end
  # end
  #
  # PartiduoUi::Extensions.mount "SKEL", Skel::Ui::ROUTES,
  #   permissions: {"edit" => "skel.page.edit"}
  # ```
  #
  # Les routes sont nommées `<code en minuscules>:<nom>` (`skel:index`) : ce
  # sont les noms que citent les menus du manifeste. Toute requête sous
  # `/ext/` passe par `PartiduoUi::ExtensionHandler`, qui décide avant
  # d'appeler le handler de l'extension :
  #
  # . utilisateur non connecté : redirection vers la connexion ;
  # . extension inconnue du registre, inactive, ou pièce qui n'est pas une
  #   extension : 404 (ADR-006 D2 : une pièce inactive n'existe pas pour
  #   l'utilisateur) ;
  # . session d'enrôlement ou sous le niveau exigé : redirection vers la page
  #   d'enrôlement ou de sécurité du compte (ADR-002 D6) ;
  # . permission de la route : celle donnée au montage (`permissions` par
  #   route, sinon `permission` pour toutes), qui doit être déclarée par le
  #   manifeste de l'extension ; à défaut, celle de l'entrée de menu du
  #   manifeste qui porte cette route (la route est permise si elle figure
  #   dans le menu de l'utilisateur, `Partiduo::Api::Modules.menu`) ;
  # . sinon : refus (403). Une route que ni le montage ni le manifeste ne
  #   couvrent n'est jamais ouverte par défaut.
  module Extensions
    PREFIX = "/ext/"

    # Interface d'une extension, montée sous `/ext/<code>/`.
    record Mount, code : String, routes : Marten::Routing::Map, permission : String?,
      permissions : Hash(String, String) do
      # Préfixe des noms de route : `skel` pour `SKEL`.
      def namespace : String
        code.downcase
      end

      def path : String
        "#{PREFIX}#{code}"
      end

      # Permission donnée au montage pour une route (nom complet `skel:edit`).
      def permission_for(route_name : String?) : String?
        route_name.try { |name| permissions[name]? } || permission
      end
    end

    # Issue du contrôle d'accès.
    enum Decision
      Allowed
      Login
      NotFound
      Forbidden
      Enrollment
      Elevation
    end

    @@mounts = {} of String => Mount
    @@drawn = Set(String).new

    # Déclare l'interface d'une extension. `permission` : permission exigée
    # pour toutes ses routes ; `permissions` : par nom de route (court,
    # `"edit"`, ou complet, `"skel:edit"`).
    def self.mount(code : String, routes : Marten::Routing::Map, permission : String? = nil,
                   permissions : Hash(String, String) = {} of String => String) : Mount
      check_code!(code)
      raise ArgumentError.new("interface d'extension déjà montée : #{code}") if @@mounts.has_key?(code)

      namespace = code.downcase
      qualified = permissions.to_h do |route, name|
        {route.includes?(':') ? route : "#{namespace}:#{route}", name}
      end
      @@mounts[code] = Mount.new(code, routes, permission, qualified)
    end

    def self.mounts : Array(Mount)
      @@mounts.values
    end

    def self.[]?(code : String) : Mount?
      @@mounts[code]?
    end

    # --- Routes publiques (A-FRM-1) ------------------------------------------

    # Préfixe réservé des routes publiques d'extension : `/p/<code>/`, code
    # en minuscules (adresse donnée au public).
    PUBLIC_PREFIX = "/p/"

    # En-têtes stricts posés sur toute réponse publique d'extension, sauf si
    # le handler de l'extension en a posé un de même nom : aucun script ni
    # ressource tierce, pas de cadre, pas de cache, pas d'indexation, pas de
    # référent vers un autre site (l'adresse peut porter un jeton). Le
    # référent reste `same-origin` : `no-referrer` ferait envoyer
    # `Origin: null` avec un formulaire, que la protection CSRF refuse.
    PUBLIC_HEADERS = {
      "Content-Security-Policy" => "default-src 'none'; style-src 'self'; font-src 'self'; img-src 'self' data:; " \
                                   "form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "Referrer-Policy"              => "same-origin",
      "Cache-Control"                => "no-store",
      "Pragma"                       => "no-cache",
      "X-Robots-Tag"                 => "noindex, nofollow, noarchive",
      "X-Frame-Options"              => "DENY",
      "X-Content-Type-Options"       => "nosniff",
      "Permissions-Policy"           => "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
      "Cross-Origin-Resource-Policy" => "same-origin",
      "Cross-Origin-Opener-Policy"   => "same-origin",
    }

    # Interface publique d'une extension, montée sous `/p/<code>/` :
    # `rate_limit` vaut pour toutes ses routes, `rate_limits` par route (nom
    # court ou complet) ; `max_body_bytes` : taille annoncée au-delà de
    # laquelle un envoi est refusé (413) avant toute lecture.
    record PublicMount, code : String, routes : Marten::Routing::Map, rate_limit : RateLimit::Rule,
      rate_limits : Hash(String, RateLimit::Rule), max_body_bytes : Int64? do
      # Préfixe des noms de route : `form_public` pour `FORM`.
      def namespace : String
        "#{code.downcase}_public"
      end

      def path : String
        "#{PUBLIC_PREFIX}#{code.downcase}"
      end

      def rule_for(route_name : String?) : RateLimit::Rule
        route_name.try { |name| rate_limits[name]? } || rate_limit
      end
    end

    # Limite par défaut d'une route publique : 60 requêtes par adresse en
    # 10 minutes.
    DEFAULT_PUBLIC_LIMIT = RateLimit::Rule.new(60, 10.minutes)

    @@public_mounts = {} of String => PublicMount
    @@public_drawn = Set(String).new

    # Déclare des routes *publiques* d'une extension (A-FRM-1) : sans
    # session, sous `/p/<code en minuscules>/`. Toute requête passe par
    # `PartiduoUi::PublicExtensionHandler`, qui, avant le handler de
    # l'extension, rend 404 si l'extension est inconnue ou inactive,
    # applique la limitation de débit de la route (429, `Retry-After`) et
    # la limite de taille (413) ; la réponse reçoit `PUBLIC_HEADERS`. La
    # protection CSRF de Marten s'applique comme ailleurs. Le contrat de
    # l'extension reste seul juge du jeton qu'une adresse publique porte.
    #
    # ```
    # Forms::Ui::PUBLIC_ROUTES = Marten::Routing::Map.draw do
    #   path "/<token:str>", Forms::Ui::PublicHandler, name: "form"
    # end
    # PartiduoUi::Extensions.public_mount "FORM", Forms::Ui::PUBLIC_ROUTES,
    #   rate_limits: {"form" => PartiduoUi::RateLimit::Rule.new(60, 10.minutes)},
    #   max_body_bytes: 2_400_000_i64
    # # adresse : reverse("form_public:form", token: jeton) → /p/form/<jeton>
    # ```
    def self.public_mount(code : String, routes : Marten::Routing::Map,
                          rate_limit : RateLimit::Rule = DEFAULT_PUBLIC_LIMIT,
                          rate_limits : Hash(String, RateLimit::Rule) = {} of String => RateLimit::Rule,
                          max_body_bytes : Int64? = nil) : PublicMount
      check_code!(code)
      raise ArgumentError.new("routes publiques d'extension déjà montées : #{code}") if @@public_mounts.has_key?(code)
      namespace = "#{code.downcase}_public"
      qualified = rate_limits.to_h do |route, rule|
        {route.includes?(':') ? route : "#{namespace}:#{route}", rule}
      end
      @@public_mounts[code] = PublicMount.new(code, routes, rate_limit, qualified, max_body_bytes)
    end

    def self.public_mounts : Array(PublicMount)
      @@public_mounts.values
    end

    # Montage public d'un code d'adresse (`form`, casse indifférente).
    def self.public_mount?(code : String) : PublicMount?
      @@public_mounts[code.upcase]?
    end

    # Specs : retire un montage public déclaré par un exemple.
    def self.unmount_public(code : String) : Nil
      @@public_mounts.delete(code)
    end

    # L'extension d'un montage public est-elle installée et active ?
    def self.public_active?(mount : PublicMount) : Bool
      view = Partiduo::Api::Modules.get(Partiduo::Api::Actor.system, mount.code)
      view.kind == "extension" && view.active
    rescue Partiduo::Api::NotFound
      false
    end

    # Compteur d'une entrée de menu d'extension (ADR-005 D8 : nombre de
    # justificatifs à traiter) : affiché à côté de l'entrée du menu et, s'il
    # est positif, repris dans « À traiter » du tableau de bord
    # (`todo` : clé i18n à pluriel, paramètre `count` ; `route` : écran
    # ouvert par la ligne). Le bloc lit le contrat de l'extension et rend
    # `nil` quand l'acteur ne doit rien voir (extension inactive, sans droit).
    record Counter, menu_code : String, route : String, todo : String?, tone : String,
      block : Proc(Partiduo::Api::Actor, Int64?)

    @@counters = {} of String => Counter

    def self.counter(menu_code : String, route : String, todo : String? = nil, tone : String = "primary",
                     &block : Partiduo::Api::Actor -> Int64?) : Counter
      @@counters[menu_code] = Counter.new(menu_code, route, todo, tone, block)
    end

    def self.counters : Array(Counter)
      @@counters.values
    end

    # Valeurs des compteurs pour l'acteur, par code d'entrée de menu ; un
    # compteur refusé (droit, module inactif) est omis.
    def self.counts(actor : Partiduo::Api::Actor) : Hash(String, Int64)
      @@counters.each_value.with_object({} of String => Int64) do |counter, counts|
        value = begin
          counter.block.call(actor)
        rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
          nil
        end
        counts[counter.menu_code] = value if value
      end
    end

    # Tuiles d'une extension sur les tableaux de bord du dossier
    # (`Dashboard`, `MicroDashboard`, `LiberalDashboard` ; ADR-005 D5,
    # ADR-009 D6), après celles des modules officiels :
    #
    # ```
    # PartiduoUi::Extensions.tile "CRM" do |actor, fmt|
    #   view = Crm::Api.tile(actor)
    #   [PartiduoUi::Dashboard::Tile.new("CRM", I18n.t("crm_ui.tile.label"), fmt.amount(view.amount))]
    # end
    # ```
    #
    # Le bloc n'est appelé que si l'extension `code` est active ; il lit le
    # contrat de l'extension et rend une liste vide quand l'acteur ne doit
    # rien voir. `AccessDenied` et `NotFound` sont ignorés, comme pour les
    # compteurs.
    record TileHook, code : String, block : Proc(Partiduo::Api::Actor, Format, Array(Dashboard::Tile))

    @@tile_hooks = [] of TileHook

    def self.tile(code : String, &block : Partiduo::Api::Actor, Format -> Array(Dashboard::Tile)) : TileHook
      check_code!(code)
      hook = TileHook.new(code, block)
      @@tile_hooks << hook
      hook
    end

    def self.tile_hooks : Array(TileHook)
      @@tile_hooks
    end

    # Tuiles des extensions actives (`active` : codes des pièces actives).
    def self.tiles(actor : Partiduo::Api::Actor, fmt : Format, active : Set(String)) : Array(Dashboard::Tile)
      @@tile_hooks.each_with_object([] of Dashboard::Tile) do |hook, tiles|
        next unless active.includes?(hook.code)
        begin
          tiles.concat(hook.block.call(actor, fmt))
        rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
          nil
        end
      end
    end

    # Variante du mode simplifié d'une extension (ADR-011 A2, ADR-007 D3) :
    # menu réduit, vocabulaire, interfaces offertes, tuiles et menus de la
    # Comptabilité écartés, sur le modèle de `SimpleMode::MENU` et
    # `SimpleMode::LIBERAL_MENU`.
    #
    # ```
    # PartiduoUi::Extensions.simple_mode "PERSO",
    #   read: "perso.read",
    #   menu: [
    #     PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "perso_ui.menu.dashboard"),
    #     PartiduoUi::SimpleMode::Entry.new("PERSO_OPERATIONS", "perso_ui.menu.operations"),
    #   ],
    #   labels: PartiduoUi::SimpleMode::Labels.under("perso_ui.mode"),
    #   hidden_menus: PartiduoUi::SimpleMode::BUSINESS_ACCOUNTING_MENUS,
    #   tiles: ->(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) { Perso::Ui.tiles(actor, fmt) }
    # ```
    #
    # La variante s'applique quand l'extension est active et que
    # l'utilisateur a la permission `read` ; celles de `MICRO` et `LIBERAL`
    # passent avant. L'interface appliquée suit toujours la préférence de
    # l'utilisateur enregistrée par le cœur (D-UI-077) ; `offer` dit quelles
    # interfaces sont offertes (par défaut les deux). `labels` : par défaut
    # le vocabulaire commun « Recettes et dépenses » / « Comptabilité »
    # (`ui.simple_mode.*`).
    def self.simple_mode(code : String, read : String, menu : Array(SimpleMode::Entry),
                         labels : SimpleMode::Labels = SimpleMode::Labels.under("ui.simple_mode"),
                         offer : SimpleMode::Offer = ->(_role : String?, _active : Set(String)) { [SimpleMode::SIMPLE, SimpleMode::FULL] },
                         hidden_menus : Array(String) = [] of String,
                         tiles : SimpleMode::Tiles? = nil,
                         settings_route : String? = nil, settings_permission : String? = nil,
                         settings_label : String? = nil) : SimpleMode::Flavor
      check_code!(code)
      SimpleMode.register(SimpleMode::Flavor.new(code, read, menu, settings_route, settings_permission,
        settings_label, labels: labels, offer: offer, hidden_menus: hidden_menus, tiles: tiles))
    end

    # Action ou fichier qu'une extension ajoute à la fiche d'un document de
    # la Facturation (ADR-010 D4) : `kind` vaut `action` (bouton qui ouvre
    # un écran de l'extension) ou `file` (fichier produit par l'extension,
    # à télécharger).
    record DocumentLink, label : String, url : String, kind : String = "action" do
      include Marten::Template::Object::Auto

      KINDS = %w[action file]

      def file? : Bool
        kind == "file"
      end
    end

    # Panneau d'une extension sur la fiche d'un document : titre (nom de
    # l'extension), liens.
    class DocumentPanel
      include Marten::Template::Object::Auto

      getter code : String
      getter title : String
      getter actions : Array(DocumentLink)
      getter files : Array(DocumentLink)

      def initialize(@code, @title, links : Array(DocumentLink))
        @actions = links.reject(&.file?)
        @files = links.select(&.file?)
      end

      # Identifiant du titre du panneau (`aria-labelledby`).
      def heading_id : String
        "pd-ext-#{code.downcase}-title"
      end

      def listed_actions : Array(DocumentLink)?
        actions.empty? ? nil : actions
      end

      def listed_files : Array(DocumentLink)?
        files.empty? ? nil : files
      end
    end

    # Actions et fichiers d'une extension sur la fiche d'un document de la
    # Facturation (DECISIONS D-HOOK-002) :
    #
    # ```
    # PartiduoUi::Extensions.document_links "MODELES" do |actor, document|
    #   [PartiduoUi::Extensions::DocumentLink.new(I18n.t("…"), "/ext/MODELES/documents/#{document.id}")]
    # end
    # ```
    #
    # Le bloc n'est appelé que si l'extension est active ; liste vide : pas
    # de panneau. `AccessDenied` et `NotFound` sont ignorés.
    record DocumentLinksHook, code : String,
      block : Proc(Partiduo::Api::Actor, Partiduo::Api::Invoicing::DocumentView, Array(DocumentLink))

    @@document_hooks = [] of DocumentLinksHook

    def self.document_links(code : String, &block : Partiduo::Api::Actor, Partiduo::Api::Invoicing::DocumentView -> Array(DocumentLink)) : DocumentLinksHook
      check_code!(code)
      hook = DocumentLinksHook.new(code, block)
      @@document_hooks << hook
      hook
    end

    def self.document_hooks : Array(DocumentLinksHook)
      @@document_hooks
    end

    # Panneaux des extensions actives pour un document, dans l'ordre des
    # déclarations ; une extension sans lien n'a pas de panneau.
    def self.document_panels(actor : Partiduo::Api::Actor, document : Partiduo::Api::Invoicing::DocumentView) : Array(DocumentPanel)
      return [] of DocumentPanel if @@document_hooks.empty?
      extensions = Partiduo::Api::Modules.list(actor).select { |item| item.active && item.kind == "extension" }
        .to_h { |item| {item.code, item.name_key} }
      @@document_hooks.each_with_object([] of DocumentPanel) do |hook, panels|
        name_key = extensions[hook.code]? || next
        links = begin
          hook.block.call(actor, document)
        rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
          [] of DocumentLink
        end
        links.each do |link|
          raise ArgumentError.new("lien d'extension de nature inconnue : #{link.kind}") unless DocumentLink::KINDS.includes?(link.kind)
        end
        panels << DocumentPanel.new(hook.code, I18n.t(name_key), links) unless links.empty?
      end
    end

    private def self.check_code!(code : String) : Nil
      return if code.matches?(/\A[A-Z][A-Z0-9_]*\z/)
      raise ArgumentError.new("code d'extension invalide (majuscules, chiffres, _) : #{code}")
    end

    # Ajoute aux routes de l'interface celles des extensions montées (appelé
    # par `PartiduoUi::App#setup`, avant la préparation des routes par Marten).
    def self.draw(map : Marten::Routing::Map = Marten.routes) : Nil
      @@mounts.each_value do |mount|
        next if @@drawn.includes?(mount.code)
        map.path mount.path, mount.routes, name: mount.namespace
        @@drawn << mount.code
      end
      # Routes publiques (A-FRM-1) : ajoutées après la règle générale
      # `/p/<code>/<chemin>`, pour le nommage seulement.
      @@public_mounts.each_value do |mount|
        next if @@public_drawn.includes?(mount.code)
        map.path mount.path, mount.routes, name: mount.namespace
        @@public_drawn << mount.code
      end
    end

    # Interface d'extension visée par un chemin, et nom complet de la route
    # (`nil` si aucune route de l'extension ne correspond).
    def self.match(path : String) : {Mount, String?}?
      return unless path.starts_with?(PREFIX)
      code = path[PREFIX.size..].split('/', 2).first
      mount = @@mounts[code]?
      return if mount.nil?
      {mount, route_name(mount.routes, path[mount.path.size..], mount.namespace)}
    end

    # Nom complet de la route d'une carte qui correspond au chemin.
    def self.route_name(map : Marten::Routing::Map, path : String, prefix : String) : String?
      map.rules.each do |rule|
        case rule
        when Marten::Routing::Rule::Path
          return "#{prefix}:#{rule.name}" if rule.resolve(path)
        when Marten::Routing::Rule::Map
          nested = rule.path
          if nested.is_a?(String) && !nested.includes?('<') && path.starts_with?(nested)
            if found = route_name(rule.map, path[nested.size..], rule.name.empty? ? prefix : "#{prefix}:#{rule.name}")
              return found
            end
          end
        end
      end
      nil
    end

    # Contrôle d'accès à une route d'extension (voir l'en-tête du module).
    def self.authorize(current : Current, mount : Mount, route_name : String?) : Decision
      return Decision::Login unless current.authenticated?
      actor = current.actor

      view = begin
        Partiduo::Api::Modules.get(actor, mount.code)
      rescue Partiduo::Api::NotFound
        return Decision::NotFound
      end
      return Decision::NotFound unless view.kind == "extension" && view.active
      return Decision::Enrollment if current.enrollment?
      return Decision::Elevation if current.elevation_required?

      if permission = mount.permission_for(route_name)
        # Une permission que le manifeste ne déclare pas ne donne aucun accès.
        return Decision::Forbidden unless view.permissions.includes?(permission)
        return actor.can?(permission) ? Decision::Allowed : Decision::Forbidden
      end

      return Decision::Forbidden if route_name.nil?
      menu_routes(Partiduo::Api::Modules.menu(actor)).includes?(route_name) ? Decision::Allowed : Decision::Forbidden
    end

    # Routes des entrées de menu visibles, à tout niveau de l'arbre.
    def self.menu_routes(entries : Array(Partiduo::Api::Modules::MenuView), into = Set(String).new) : Set(String)
      entries.each do |entry|
        entry.route.try { |route| into << route }
        menu_routes(entry.children, into)
      end
      into
    end
  end
end
