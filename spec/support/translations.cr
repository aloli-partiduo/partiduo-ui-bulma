# SPDX-License-Identifier: AGPL-3.0-or-later

require "html"
require "yaml"

module PartiduoUi
  # Contrôle des traductions (ADR-005 D7 : langues livrées, `Partiduo::LOCALES`), partagé par
  # l'interface, les extensions et la distribution, qui le requièrent par
  # `lib/partiduo-ui-bulma/spec/support/translations`.
  #
  # Deux contrôles :
  #
  # . *statique* (`Translations.parity_failures`, `unknown_keys`) : les
  #   fichiers de locales d'un répertoire ont les mêmes clés et les mêmes
  #   interpolations dans chaque langue, et chaque clé citée par le code ou
  #   les gabarits (`I18n.t("…")`, `{% translate "…" %}`, littéraux
  #   `"ui.…"`, `"<extension>_ui.…"`) existe dans chaque langue ;
  # . *dynamique* (`Translations::Explorer`) : toutes les routes du routeur
  #   de Marten (montages des extensions compris), pages à paramètres
  #   atteintes par les liens des pages du jeu de données, chaque page
  #   obtenue dans chaque langue ; le HTML rendu ne doit contenir ni
  #   marqueur de traduction absente, ni clé brute, ni interpolation non
  #   résolue (`Translations.problems`). Une route qui sert `GET` et qu'aucun
  #   lien n'atteint fait échouer le contrôle, sauf exclusion motivée : une
  #   nouvelle page est ainsi couverte d'office.
  module Translations
    LOCALES = Partiduo::LOCALES.map(&.to_s)

    # Marqueur rendu par crystal-i18n pour une clé absente
    # (`missing translation: en.ui.menu.x`).
    MISSING = /(?:missing translation|translation missing):\s*([\w.\-]+)/i

    # Interpolation laissée telle quelle (`%{count}`).
    INTERPOLATION = /%\{[^}]*\}/

    # Attributs lus par une personne (les autres, techniques ou `data-*`,
    # ne sont pas contrôlés).
    HUMAN_ATTRIBUTES = %w[title placeholder aria-label aria-description aria-placeholder alt label data-pd-confirm]

    # --- Catalogue chargé ---------------------------------------------------------

    @@catalog : Hash(String, Set(String))? = nil
    @@texts : Hash(String, Hash(String, I18n::TranslationsHashValues))? = nil
    @@namespaces : Set(String)? = nil

    # Clés de toutes les traductions chargées (cœur, interface, extensions
    # composées), par langue : feuilles et nœuds (`ui.menu` comme
    # `ui.menu.dashboard`), pour admettre une clé de pluriel ou de sous-arbre.
    def self.catalog : Hash(String, Set(String))
      @@catalog ||= texts.transform_values(&.keys.to_set)
    end

    # Valeur de chaque clé (feuille ou nœud), par langue, dans l'ordre de
    # chargement de Marten (la dernière l'emporte).
    def self.texts : Hash(String, Hash(String, I18n::TranslationsHashValues))
      @@texts ||= begin
        values = Hash(String, Hash(String, I18n::TranslationsHashValues)).new do |hash, locale|
          hash[locale] = {} of String => I18n::TranslationsHashValues
        end
        LOCALES.each { |locale| values[locale] }
        I18n.config.loaders.each do |loader|
          loader.load.each do |locale, data|
            flatten(data, "", values[locale]) if data.is_a?(Hash)
          end
        end
        values
      end
    end

    # Premiers segments des clés (`ui`, `core`, `sepa_ui`…).
    def self.namespaces : Set(String)
      @@namespaces ||= catalog.values.flat_map(&.map(&.split('.').first)).to_set
    end

    # Permissions déclarées par les pièces actives (cœur et extensions),
    # lues par le contrat.
    def self.permission_names : Set(String)
      Partiduo::Api::Modules.permissions(Partiduo::Api::Actor.system).map(&.name).to_set
    end

    def self.known?(locale : String, key : String) : Bool
      catalog[locale].includes?(key)
    end

    private def self.flatten(data : I18n::TranslationsHash, prefix : String,
                             into : Hash(String, I18n::TranslationsHashValues)) : Nil
      data.each do |name, value|
        key = prefix.empty? ? name : "#{prefix}.#{name}"
        into[key] = value
        flatten(value, key, into) if value.is_a?(Hash)
      end
    end

    # Défaut d'une recherche de traduction dans une langue : clé absente,
    # sous-arbre demandé sans compte, ou interpolation à laquelle aucun
    # paramètre ne répond (`names`, `count` compris ; non contrôlé si `nil`).
    # `nil` si rien.
    def self.lookup_problem(locale : String, key : String, names : Set(String)?, plural : Bool) : String?
      value = texts[locale][key]?
      return "#{locale}.#{key} absente" if value.nil? && !texts[locale].has_key?(key)
      return "#{locale}.#{key} recherchée avec un compte, sans formes du pluriel" if plural && !value.is_a?(Hash)
      strings = case value
                when Hash
                  return "#{locale}.#{key} est un sous-arbre, demandé sans compte" unless plural
                  plurals = [] of String
                  value.each_value { |form| plurals << form if form.is_a?(String) }
                  plurals
                when Array then [value.join("\n")]
                else            [value.to_s]
                end
      return if names.nil?
      unresolved = strings.flat_map(&.scan(/%\{(\w+)\}/).map(&.[1])).uniq!.reject { |name| names.includes?(name) }
      "#{locale}.#{key} : #{unresolved.map { |name| "%{#{name}}" }.join(" ")} sans paramètre" unless unresolved.empty?
    end

    # --- Sonde des recherches de traduction --------------------------------------
    #
    # Toute recherche faite pendant la suite de specs (`I18n.t` du code,
    # `{% translate %}` des gabarits, message d'une erreur du contrat,
    # courriel, PDF, réponse à un envoi…), quelle que soit la langue active :
    # la clé doit exister en fr, en et nl (pluriel compris). Une recherche
    # avec `default:` est volontairement tolérante et n'est pas contrôlée,
    # comme celle d'une spec elle-même. Les défauts sont rapportés en fin de
    # suite, qui échoue alors (`Probe.report`).
    module Probe
      @@failures = {} of String => String
      @@lookups = 0

      def self.failures : Hash(String, String)
        @@failures
      end

      def self.lookups : Int32
        @@lookups
      end

      # Recherche faite par crystal-i18n (`I18n::Catalog#fetch_translation!`,
      # clé complète, portée appliquée). Les paramètres n'y sont plus connus :
      # l'existence de la clé dans chaque langue est contrôlée ici ; les
      # interpolations, par la parité des locales et le texte rendu.
      def self.lookup(key : String, count, default) : Nil
        return unless default.nil? && @@quiet == 0
        @@lookups += 1
        check(key, nil, !count.nil?)
      end

      private def self.check(key : String, names : Set(String)?, plural : Bool) : Nil
        LOCALES.each do |locale|
          problem = Translations.lookup_problem(locale, key, names, plural)
          next if problem.nil? || @@failures.has_key?(problem)
          where = origin
          @@failures[problem] = where unless spec?(where)
        end
      end

      @@quiet = 0

      # Recherche tolérante de crystal-i18n (`fetch_translation`, sans point
      # d'exclamation : formats des nombres de `I18n.localize`), absence admise.
      def self.quietly(&)
        @@quiet += 1
        yield
      ensure
        @@quiet -= 1
      end

      # Recherche faite par une spec elle-même (contrôle de conventions qui
      # sonde les clés, erreur factice), et non par le code : pas un défaut.
      private def self.spec?(where : String) : Bool
        (where.starts_with?("spec/") || where.includes?("/spec/")) && !where.includes?("spec/support/")
      end

      # Chemin relatif : la pile cite le fichier par `lib/…` ou par le dépôt.
      PROBE_FILE = "spec/support/translations.cr"

      # Premier appelant du code de Partiduo (handler, service, gabarit
      # compilé, spec), hors de crystal-i18n, du contrat d'erreurs et de cette
      # sonde.
      private def self.origin : String
        caller.each do |frame|
          place = place(frame)
          return place unless place.nil?
        end
        "?"
      rescue
        # Pile illisible (programme de specs remplacé par une autre suite).
        "?"
      end

      # Ligne de pile située : `fichier:ligne:colonne in 'méthode'`.
      LOCATED = /\A(\S+:\d+(?::\d+)?)\s+in\s/

      # Symbole d'une ligne de pile sans informations de débogage
      # (`crystal spec --no-debug`, comme en CI) : `binaire in 'symbole'`.
      SYMBOL = /\sin\s+'(.+)'\s*\z/

      # Emplacement que garde le symbole d'un bloc compilé sans informations
      # de débogage (`~procProc(Nil)@spec/…_spec.cr:44`) ; le symbole d'une
      # méthode n'en a aucun.
      BLOCK_LOCATION = /@(\S+:\d+)\z/

      # Symboles de la mécanique de recherche, jamais l'origine d'une
      # recherche : pile elle-même, crystal-i18n, cette sonde, contrat
      # d'erreurs (`Api::Result.failure`, `Api::FieldError`).
      MACHINERY = {"caller", "Exception::CallStack", "I18n::", "PartiduoUi::Translations::Probe",
                   "Partiduo::Api::Result", "Partiduo::Api::FieldError"}

      # Origine que désigne une ligne de pile, ou `nil` si elle appartient à
      # la mécanique de recherche (ou à la bibliothèque standard).
      #
      # Avec les informations de débogage, la ligne cite son fichier : elle
      # est rendue telle quelle. Sans elles, seul le symbole est connu : il
      # est rendu, ou, pour un bloc, l'emplacement qu'il garde ; une
      # recherche faite par le corps d'une spec (`it do … end`, un bloc)
      # reste ainsi reconnue (`spec?`), et celle du code reste rapportée,
      # désignée par sa méthode, au lieu de `?`.
      def self.place(frame : String) : String?
        frame = frame.strip
        if located = frame.match(LOCATED)
          file = located[1]
          return if file.starts_with?('/') && !file.includes?("partiduo")
          return if file.includes?("/i18n/") || file.includes?(PROBE_FILE) ||
                    file.includes?("api/result.cr") || file.includes?("api/field_error.cr")
          frame
        elsif symbol = frame.match(SYMBOL).try(&.[1])
          return if MACHINERY.any? { |prefix| symbol.starts_with?(prefix) }
          symbol.match(BLOCK_LOCATION).try(&.[1]) || symbol
        end
      end

      # Défauts relevés, un par ligne, avec leur premier appelant.
      def self.report : Array(String)
        @@failures.map { |problem, where| "#{problem} (#{where})" }.sort!
      end
    end

    # --- Contrôle statique ----------------------------------------------------------

    # Fichiers `fr.yml`, `en.yml`, `nl.yml` d'un répertoire : mêmes clés,
    # mêmes interpolations. Rend les écarts, un par ligne.
    def self.parity_failures(dir : String) : Array(String)
      values = LOCALES.to_h do |locale|
        path = File.join(dir, "#{locale}.yml")
        tree = File.exists?(path) ? YAML.parse(File.read(path))[locale]? : nil
        {locale, tree ? leaves(tree, "") : {} of String => String}
      end
      failures = [] of String
      reference = values["fr"]
      LOCALES.skip(1).each do |locale|
        other = values[locale]
        (reference.keys - other.keys).sort!.each { |key| failures << "#{dir} : #{locale} n'a pas la clé #{key}" }
        (other.keys - reference.keys).sort!.each { |key| failures << "#{dir} : #{locale} a la clé #{key}, absente en fr" }
        (reference.keys & other.keys).sort!.each do |key|
          expected = reference[key].scan(INTERPOLATION).map(&.[0]).to_set
          found = other[key].scan(INTERPOLATION).map(&.[0]).to_set
          next if expected == found
          failures << "#{dir} : #{locale}.#{key} interpole #{found.to_a.sort.join(" ")}, fr #{expected.to_a.sort.join(" ")}"
        end
      end
      failures
    end

    private def self.leaves(node : YAML::Any, prefix : String, into = {} of String => String) : Hash(String, String)
      if hash = node.as_h?
        hash.each { |key, value| leaves(value, prefix.empty? ? key.to_s : "#{prefix}.#{key}", into) }
      elsif array = node.as_a?
        into[prefix] = array.map(&.to_s).join("\n")
      else
        into[prefix] = node.to_s
      end
      into
    end

    # Clé citée par le code ou un gabarit.
    record Usage, key : String, file : String, line : Int32

    USAGES = [
      /I18n\.t(?:ranslate)?!?\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"/,
      /\{%-?\s*(?:translate|t)\s+["']([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)["']/,
      # Clé d'écran passée à une aide (`crumb("ui.…")`, `Entry.new(…, "ui.…")`).
      /["']((?:[a-z][a-z0-9]*_)?ui(?:\.[a-z0-9_]+)+)["']/,
    ]

    # Clés citées par les fichiers `globs` (relatifs à `root`), lignes de
    # commentaire écartées.
    def self.usages(root : String, globs : Array(String)) : Array(Usage)
      found = [] of Usage
      Dir.glob(globs.map { |glob| File.join(root, glob) }).sort!.each do |path|
        relative = Path[path].relative_to(root).to_s
        File.read_lines(path).each_with_index(1) do |text, number|
          next if text.lstrip.starts_with?('#') || text.lstrip.starts_with?("{#")
          USAGES.each do |pattern|
            text.scan(pattern) { |match| found << Usage.new(match[1], relative, number) }
          end
        end
      end
      found
    end

    # Recherche avec un compte (`I18n.t("…", count: n)`, `{% translate "…"
    # count: n %}`) : crystal-i18n cherche alors une forme du pluriel
    # (`….one`, `….other`), et une clé simple s'affiche « missing
    # translation: fr.….other ».
    COUNTED = [
      /I18n\.t(?:ranslate)?!?\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"[^)]*?\bcount:/,
      /\{%-?\s*(?:translate|t)\s+["']([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)["'][^%]*?\bcount:/,
    ]

    # Clés citées absentes du catalogue chargé, dans une langue au moins, et
    # clés recherchées avec un compte sans formes du pluriel.
    def self.unknown_keys(root : String, globs : Array(String)) : Array(String)
      absent = usages(root, globs).compact_map do |usage|
        missing = LOCALES.reject { |locale| known?(locale, usage.key) }
        "#{usage.file}:#{usage.line} : #{usage.key} absente en #{missing.join(", ")}" unless missing.empty?
      end
      (absent + singular_counts(root, globs)).uniq!
    end

    # Clés recherchées avec un compte qui ne sont pas, dans une langue au
    # moins, un sous-arbre de formes du pluriel.
    def self.singular_counts(root : String, globs : Array(String)) : Array(String)
      found = [] of String
      Dir.glob(globs.map { |glob| File.join(root, glob) }).sort!.each do |path|
        relative = Path[path].relative_to(root).to_s
        File.read_lines(path).each_with_index(1) do |text, number|
          next if text.lstrip.starts_with?('#') || text.lstrip.starts_with?("{#")
          COUNTED.each do |pattern|
            text.scan(pattern) do |match|
              singular = LOCALES.select { |locale| known?(locale, match[1]) && !texts[locale][match[1]].is_a?(Hash) }
              next if singular.empty?
              found << "#{relative}:#{number} : #{match[1]} recherchée avec un compte, sans pluriel en #{singular.join(", ")}"
            end
          end
        end
      end
      found
    end

    # --- Contrôle du HTML rendu ------------------------------------------------------

    # Défauts de traduction d'une page : marqueurs de clé absente, clés
    # brutes et interpolations non résolues dans le texte et les attributs
    # lus par une personne.
    #
    # `literals` : textes affichés tels quels à dessein (variables d'un
    # modèle de relance citées dans l'aide), retirés avant le contrôle.
    def self.problems(html : String, literals : Array(String) = [] of String) : Array(String)
      found = [] of String
      html.scan(MISSING) { |match| found << "traduction absente : #{match[1]}" }
      readable(html).each do |text|
        literals.each { |literal| text = text.gsub(literal, " ") }
        text.scan(INTERPOLATION) { |match| found << "interpolation non résolue : #{match[0]}" }
        text.scan(/(?<![\w.\/@:-])([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)(?![\w\/@-])/) do |match|
          found << "clé brute : #{match[1]}" if raw_key?(match[1])
        end
      end
      found.uniq
    end

    # Texte visible et attributs lus, entités décodées. Écartés : scripts,
    # styles, commentaires, zones de saisie (`textarea` : modèles de
    # relance aux variables `%{…}`) et codes affichés tels quels (`code`,
    # `kbd`, `samp`, `pre`, classe `pd-mono` : codes de permission, numéros).
    def self.readable(html : String) : Array(String)
      source = html.gsub(/<!--.*?-->/m, " ")
        .gsub(/<(script|style|textarea|code|kbd|samp|pre)\b[^>]*>.*?<\/\1>/mi, " ")
        .gsub(/<(\w+)\b[^>]*\bclass="[^"]*\bpd-mono\b[^"]*"[^>]*>.*?<\/\1>/mi, " ")
      parts = [] of String
      source.scan(/<[a-zA-Z][^>]*>/) do |tag|
        tag[0].scan(/\s([a-zA-Z\-]+)\s*=\s*("([^"]*)"|'([^']*)')/) do |attribute|
          next unless HUMAN_ATTRIBUTES.includes?(attribute[1].downcase)
          parts << HTML.unescape(attribute[3]? || attribute[4]? || "")
        end
      end
      parts << HTML.unescape(source.gsub(/<[^>]*>/, " "))
      parts
    end

    # Mot pointé qui est une clé de traduction : premier segment d'un
    # espace de clés connu, et clé (ou début de clé) du catalogue. Les
    # codes de permission des manifestes (`core.settings.manage`), affichés
    # à dessein, n'en sont pas.
    def self.raw_key?(word : String) : Bool
      segments = word.split('.')
      return false unless namespaces.includes?(segments.first)
      key = catalog.values.any?(&.includes?(word)) ||
            (segments.size > 2 && catalog.values.any?(&.includes?(segments.first(2).join('.'))))
      key && !permission_names.includes?(word)
    end

    # --- Routes ------------------------------------------------------------------

    # Route du routeur de Marten : nom complet (`core:dashboard`,
    # `sepa:batch`), chemin complet, handler.
    class Route
      getter name : String
      getter pattern : String
      getter handler : Marten::Handlers::Base.class
      getter regex : Regex

      def initialize(@name, @pattern, @handler)
        @regex = Marten::Routing::Rule::Base.path_to_regex(@pattern, "$")[0]
      end

      def parameters? : Bool
        pattern.includes?('<')
      end

      # Adresse avec des valeurs qui ne désignent rien (pages d'erreur,
      # pages d'accès à jeton invalide).
      def placeholder_url : String
        pattern.gsub(/<(\w+)(?::(\w+))?>/) do
          case $~[2]?
          when "int"  then "999999999"
          when "uuid" then "00000000-0000-0000-0000-000000000000"
          else             "inconnu"
          end
        end
      end

      # Sert `GET` : le handler (ou une classe dont il hérite) définit `get`
      # (ou `dispatch`) et ne restreint pas ses méthodes sans `GET`.
      def serves_get? : Bool
        handler.http_method_names.includes?("GET") && Translations.handlers_serving_get.includes?(handler.name)
      end
    end

    @@handlers_serving_get : Set(String)? = nil

    # Noms des handlers qui définissent `get` ou `dispatch`, eux ou une de
    # leurs classes parentes (hors `Marten::Handlers::Base`, dont le `get`
    # rend 405).
    def self.handlers_serving_get : Set(String)
      @@handlers_serving_get ||= begin
        names = Set(String).new
        {% for klass in Marten::Handlers::Base.all_subclasses %}
          {% chain = [klass] + klass.ancestors.select { |ancestor| ancestor < Marten::Handlers::Base } %}
          {% if chain.any? { |type| type.methods.any? { |method| method.name == "get" || method.name == "dispatch" } } %}
            names << {{ klass.name.stringify }}
          {% end %}
        {% end %}
        names
      end
    end

    # Toutes les routes d'une carte, cartes imbriquées comprises.
    def self.routes(map : Marten::Routing::Map = Marten.routes, prefix : String = "", namespace : String = "") : Array(Route)
      map.rules.flat_map do |rule|
        case rule
        when Marten::Routing::Rule::Path
          path = rule.path
          path.is_a?(String) ? [Route.new(qualified(namespace, rule.name), prefix + path, rule.handler)] : [] of Route
        when Marten::Routing::Rule::Map
          path = rule.path
          path.is_a?(String) ? routes(rule.map, prefix + path, qualified(namespace, rule.name)) : [] of Route
        else
          [] of Route
        end
      end
    end

    private def self.qualified(namespace : String, name : String) : String
      [namespace, name].reject(&.empty?).join(':')
    end

    # Règles d'aiguillage de l'interface, qui ne sont pas des pages : accès
    # aux extensions (`/ext/<code>/…`, `/p/<code>/…`, les cartes des
    # extensions nommant seulement leurs routes) et fichiers statiques.
    GLUE = %w[PartiduoUi::ExtensionHandler PartiduoUi::PublicExtensionHandler Marten::Handlers::Defaults::Development::ServeAsset]

    # --- Exploration -------------------------------------------------------------

    # Explore les pages d'un jeu de données dans chaque langue. `scope` : les
    # routes contrôlées et dont la couverture est exigée ; `exclusions` :
    # nom de route → motif (route servie en `GET` qui n'est pas une page à
    # explorer).
    class Explorer
      # Adresses sans requête gardées par route (objets différents) ; une
      # adresse avec requête (`?tab=…`, `?sort=…`) par forme de requête.
      PER_ROUTE = 4

      getter routes : Array(Route)
      getter exclusions : Hash(String, String)
      getter failures = [] of String
      # Routes obtenues (statut < 400) au moins une fois.
      getter reached = Set(String).new
      # Pages contrôlées : adresse × langue.
      getter checked = 0
      getter checked_routes = Set(String).new

      # Textes affichés tels quels à dessein (voir `Translations.problems`).
      getter literals : Array(String)

      # `unsent` : nom de route → motif (formulaire jamais envoyé : appel
      # d'un service externe que la spec ne simule pas…).
      def initialize(@exclusions : Hash(String, String) = {} of String => String, glue : Array(String) = GLUE,
                     @routes : Array(Route) = Translations.routes, @literals = [] of String,
                     @unsent = {} of String => String, &@scope : Route -> Bool)
        @routes = @routes.reject { |route| glue.includes?(route.handler.name) }
        unknown = (@exclusions.keys + @unsent.keys) - @routes.map(&.name)
        raise ArgumentError.new("exclusions sans route : #{unknown.join(", ")}") unless unknown.empty?
      end

      def in_scope?(route : Route) : Bool
        @scope.call(route)
      end

      def explorable?(route : Route) : Bool
        in_scope?(route) && route.serves_get? && !exclusions.has_key?(route.name)
      end

      def route_for(path : String) : Route?
        routes.find(&.regex.matches?(path))
      end

      # Parcourt les pages d'un utilisateur connecté (`browser`) : routes sans
      # paramètre, `seeds`, puis les liens de chaque page obtenue, dans la
      # portée. `variant` nomme le jeu de données dans les messages.
      def crawl(browser : Browser, variant : String, seeds : Array(String) = [] of String) : Nil
        queue = Deque(String).new
        routes.each { |route| queue << route.pattern if explorable?(route) && !route.parameters? }
        seeds.each { |seed| queue << seed }
        plain = Hash(String, Int32).new(0)
        seen = Set(String).new
        while url = queue.shift?
          path, _, query = url.partition('?')
          route = route_for(path)
          next unless route && explorable?(route)
          key = query.empty? ? url : "#{route.name}?#{URI::Params.parse(query).map { |name, _| name }.uniq!.sort!.join('&')}"
          next if seen.includes?(key) || (query.empty? && plain[route.name] >= PER_ROUTE)
          seen << key
          plain[route.name] += 1 if query.empty?
          html = check_all(browser, route, url, variant)
          next unless html
          links(html).each { |link| queue << link }
          collect_forms(html, url)
        end
      end

      # Chaque route de la portée, paramètres remplacés par des valeurs qui
      # ne désignent rien : pages d'accès, de jeton invalide et d'erreur.
      def visit_placeholders(browser : Browser, variant : String) : Nil
        routes.each do |route|
          next unless explorable?(route)
          check_all(browser, route, route.placeholder_url, variant)
        end
      end

      # Adresses données, sans suivre leurs liens (pages d'accès à jeton
      # valide, pages qu'aucun lien n'atteint dans le jeu de données).
      def visit(browser : Browser, variant : String, urls : Array(String)) : Nil
        urls.each do |url|
          route = route_for(url.partition('?')[0]) || raise ArgumentError.new("adresse sans route : #{url}")
          check_all(browser, route, url, variant) if explorable?(route)
        end
      end

      # Une adresse, dans chaque langue ; rend le HTML en français s'il y en a.
      # La langue active du processus est rétablie ensuite (chaque requête
      # l'a changée).
      def check_all(browser : Browser, route : Route, url : String, variant : String) : String?
        previous = I18n.locale
        check_locales(browser, route, url, variant)
      ensure
        I18n.activate(previous) if previous
      end

      private def check_locales(browser : Browser, route : Route, url : String, variant : String) : String?
        first = nil
        LOCALES.each_with_index do |locale, index|
          response = fetch(browser, url, locale)
          if response.nil?
            failures << "#{variant} #{route.name} #{url} [#{locale}] : exception"
            return
          end
          status = response.status
          reached << route.name if status < 400
          failures << "#{variant} #{route.name} #{url} [#{locale}] : erreur #{status}" if status >= 500
          return unless html?(response)
          @checked += 1
          checked_routes << route.name
          Translations.problems(response.content, literals).each do |problem|
            failures << "#{variant} #{route.name} #{url} [#{locale}] : #{problem}"
          end
          first = response.content if index == 0
        end
        first
      end

      # Routes de la portée servies en `GET`, non exclues, jamais obtenues.
      def unreached : Array(String)
        routes.select { |route| explorable?(route) && !reached.includes?(route.name) }.map do |route|
          "#{route.name} (#{route.pattern})"
        end
      end

      def report : String
        "#{checked_routes.size} routes, #{checked} pages contrôlées (adresse × langue), " \
        "#{submitted} envois de formulaires (formulaire × variante × langue), " \
        "#{Probe.lookups} recherches de traduction sondées"
      end

      private def fetch(browser : Browser, url : String, locale : String) : Marten::HTTP::Response?
        browser.jar[Marten.settings.i18n.locale_cookie_name] = locale
        browser.headers["Accept-Language"] = locale
        browser.get(url)
      rescue ex
        failures << "#{url} [#{locale}] : #{ex.class} #{ex.message}"
        nil
      end

      private def html?(response : Marten::HTTP::Response) : Bool
        response.content_type.to_s.includes?("text/html") && !response.headers.has_key?("Content-Disposition")
      end

      # Liens internes d'une page : `href`, `hx-get`, `src`, `action`, sans
      # ancre ni export (`format=`).
      # --- Envois de formulaires ---------------------------------------------------

      # Champ d'un formulaire relevé dans une page : nom, type (`select`,
      # `textarea`, type d'un `input`), valeur initiale.
      record Field, name : String, type : String, value : String do
        # Champ rempli par une personne (ni caché, ni bouton, ni fichier).
        def editable? : Bool
          !%w[hidden submit button reset image file].includes?(type)
        end
      end

      # Formulaire `POST` relevé dans une page : adresse d'envoi, champs,
      # envoi par HTMX (`hx-post`), page d'origine.
      record PostForm, action : String, fields : Array(Field), htmx : Bool, page : String do
        def editable? : Bool
          fields.any?(&.editable?)
        end
      end

      # Formulaires gardés par route d'envoi (formes de champs différentes).
      FORMS_PER_ROUTE = 2

      # Routes jamais envoyées : la session de l'exploration y prendrait fin.
      UNSENT = %w[logout]

      # Formulaires relevés, pas encore envoyés ; tous les formulaires relevés.
      getter forms = [] of PostForm
      getter all_forms = [] of PostForm
      @form_keys = Set(String).new
      @form_count = Hash(String, Int32).new(0)
      # Envois contrôlés : formulaire × variante × langue.
      getter submitted = 0

      # Formulaires `POST` d'une page, dans la portée.
      def collect_forms(html : String, page : String) : Nil
        html.scan(/<form\b([^>]*)>(.*?)<\/form>/mi) do |match|
          attributes = match[1]
          htmx_action = attribute(attributes, "hx-post")
          next unless htmx_action || attribute(attributes, "method").try(&.downcase) == "post"
          action = htmx_action || attribute(attributes, "action").presence || page
          next unless internal?(action)
          route = route_for(action.partition('?')[0])
          next if route.nil? || !in_scope?(route) || UNSENT.includes?(route.name) || @unsent.has_key?(route.name)
          fields = form_fields(match[2])
          key = "#{route.name} #{fields.map(&.name).uniq!.sort!.join(',')}"
          next if @form_keys.includes?(key) || @form_count[route.name] >= FORMS_PER_ROUTE
          @form_keys << key
          @form_count[route.name] += 1
          form = PostForm.new(action, fields, !htmx_action.nil?, page)
          @forms << form
          @all_forms << form
        end
      end

      # Envoie chaque formulaire relevé depuis le dernier envoi, dans chaque
      # langue : vide, puis avec des valeurs fausses (texte trop long, nombre
      # et date invalides, choix inexistant) ; un formulaire sans champ à
      # remplir (bouton d'action : émettre, supprimer, approuver…) tel quel,
      # après tous les autres. Contrôlés : la réponse (erreurs du
      # formulaire, refus), la page où elle redirige (message flash), la
      # réponse partielle à une requête HTMX et sa redirection
      # (`HX-Redirect`) ; une erreur 500 est un échec.
      #
      # `forms` : par défaut, ceux qui n'ont pas encore été envoyés ;
      # `all_forms` pour les renvoyer avec un autre compte (refus de droits).
      def submit_forms(browser : Browser, variant : String, forms : Array(PostForm)? = nil) : Nil
        pending = (forms || @forms).sort_by { |form| form.editable? ? 0 : 1 }
        @forms = [] of PostForm if forms.nil?
        pending.each do |form|
          route = route_for(form.action.partition('?')[0]) || next
          if form.editable?
            submit_all(browser, route, form, "vide", blank(form), variant)
            submit_all(browser, route, form, "valeurs fausses", wrong(form), variant)
          else
            submit_all(browser, route, form, "tel quel", form.fields.map { |field| {field.name, field.value} }, variant)
          end
        end
      end

      private def submit_all(browser : Browser, route : Route, form : PostForm, kind : String,
                             values : Array(Tuple(String, String)), variant : String) : Nil
        previous = I18n.locale
        body = URI::Params.build { |params| values.each { |name, value| params.add(name, value) } }
        LOCALES.each do |locale|
          where = "#{variant} #{route.name} POST #{form.action} (#{kind}, depuis #{form.page}) [#{locale}]"
          send(browser, where, form.action, body, locale, htmx: false)
          send(browser, where + " HTMX", form.action, body, locale, htmx: true) if form.htmx
        end
      ensure
        I18n.activate(previous) if previous
      end

      private def send(browser : Browser, where : String, action : String, body : String, locale : String,
                       htmx : Bool) : Nil
        browser.jar[Marten.settings.i18n.locale_cookie_name] = locale
        browser.headers["Accept-Language"] = locale
        headers = htmx ? {"HX-Request" => "true"} : {} of String => String
        response = browser.perform_raw(action, body, headers)
        @submitted += 1
        inspect_response(response, where)
        target = response.headers["HX-Redirect"]? || (response.status.in?(300..399) ? response.headers["Location"]? : nil)
        return unless target && internal?(target)
        browser.jar[Marten.settings.i18n.locale_cookie_name] = locale
        inspect_response(browser.get(target), "#{where} → #{target}")
      rescue ex
        failures << "#{where} : #{ex.class} #{ex.message}"
      end

      private def inspect_response(response : Marten::HTTP::Response, where : String) : Nil
        failures << "#{where} : erreur #{response.status}" if response.status >= 500
        return unless html?(response)
        Translations.problems(response.content, literals).each { |problem| failures << "#{where} : #{problem}" }
      end

      # Champs à remplir vidés ; champs cachés gardés (identifiants), cases
      # décochées.
      private def blank(form : PostForm) : Array(Tuple(String, String))
        form.fields.compact_map do |field|
          next if field.type.in?("checkbox", "radio", "submit", "button", "reset", "image", "file")
          {field.name, field.editable? ? "" : field.value}
        end
      end

      # Valeurs refusées par les contrôles : texte trop long, nombre, date,
      # mois et courriel invalides, choix qui n'existe pas.
      private def wrong(form : PostForm) : Array(Tuple(String, String))
        form.fields.compact_map do |field|
          next if field.type.in?("submit", "button", "reset", "image", "file")
          value = case field.type
                  when "hidden"            then field.value
                  when "checkbox", "radio" then field.value.presence || "on"
                  else                          WRONG.fetch(field.type, "x" * 600)
                  end
          {field.name, value}
        end
      end

      # Valeur fausse par type de champ ; texte trop long pour les autres.
      WRONG = {
        "number" => "abc", "range" => "abc", "date" => "2026-13-45", "datetime-local" => "2026-13-45",
        "month" => "2026-13", "time" => "25:99", "email" => "pas-un-courriel", "url" => "pas une adresse",
        "select" => "999999999",
      }

      private def form_fields(html : String) : Array(Field)
        fields = [] of Field
        html.scan(/<(input|select|textarea)\b([^>]*)>/mi) do |match|
          name = attribute(match[2], "name")
          next if name.nil? || name.empty?
          type = match[1].downcase == "input" ? (attribute(match[2], "type").try(&.downcase) || "text") : match[1].downcase
          fields << Field.new(name, type, attribute(match[2], "value") || "")
        end
        fields
      end

      # Adresse du site (chemin absolu, sans hôte).
      private def internal?(url : String) : Bool
        url.starts_with?('/') && !url.starts_with?("//")
      end

      private def attribute(attributes : String, name : String) : String?
        attributes.match(/(?:^|\s)#{name}\s*=\s*(?:"([^"]*)"|'([^']*)')/i).try do |match|
          HTML.unescape(match[1]? || match[2]? || "")
        end
      end

      private def links(html : String) : Array(String)
        found = [] of String
        html.scan(/\s(?:href|hx-get|src|action)\s*=\s*"([^"]*)"/) do |match|
          link = HTML.unescape(match[1]).split('#').first
          next if !link.starts_with?('/') || link.starts_with?("//")
          next if link.includes?("format=")
          found << link
        end
        found
      end
    end
  end
end

# Sonde des traductions (`PartiduoUi::Translations::Probe`) : chaque
# recherche passe par `I18n::Catalog#translate`.
class I18n::Catalog
  private def fetch_translation(locale, key, count = nil, default = nil, ongoing_fallback = false)
    PartiduoUi::Translations::Probe.quietly { previous_def }
  end

  private def fetch_translation!(locale, key, count = nil, default = nil, ongoing_fallback = false)
    PartiduoUi::Translations::Probe.lookup(key.to_s, count, default) unless ongoing_fallback
    previous_def
  end
end

# Rapport après le résumé des specs (crochet de sortie posé en fin de
# suite), pour ne pas le masquer.
Spec.after_suite do
  at_exit do
    failures = PartiduoUi::Translations::Probe.report
    next if failures.empty?
    STDERR.puts "\nTraductions absentes ou incomplètes relevées pendant la suite " \
                "(#{failures.size}, sonde de PartiduoUi::Translations) :"
    failures.each { |failure| STDERR.puts "  #{failure}" }
    exit 1
  end
end
