# SPDX-License-Identifier: AGPL-3.0-or-later

require "html"
require "yaml"

module PartiduoUi
  # Contrôle des traductions (ADR-005 D7 : fr, en, nl), partagé par
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
    LOCALES = %w[fr en nl]

    # Marqueur rendu par crystal-i18n pour une clé absente
    # (`missing translation: en.ui.menu.x`).
    MISSING = /(?:missing translation|translation missing):\s*([\w.\-]+)/i

    # Interpolation laissée telle quelle (`%{count}`).
    INTERPOLATION = /%\{[^}]*\}/

    # Attributs lus par une personne (les autres, techniques ou `data-*`,
    # ne sont pas contrôlés).
    HUMAN_ATTRIBUTES = %w[title placeholder aria-label aria-description aria-placeholder alt label]

    # --- Catalogue chargé ---------------------------------------------------------

    @@catalog : Hash(String, Set(String))? = nil
    @@namespaces : Set(String)? = nil

    # Clés de toutes les traductions chargées (cœur, interface, extensions
    # composées), par langue : feuilles et nœuds (`ui.menu` comme
    # `ui.menu.dashboard`), pour admettre une clé de pluriel ou de sous-arbre.
    def self.catalog : Hash(String, Set(String))
      @@catalog ||= begin
        keys = Hash(String, Set(String)).new { |hash, locale| hash[locale] = Set(String).new }
        I18n.config.loaders.each do |loader|
          loader.load.each do |locale, data|
            flatten(data, "", keys[locale]) if data.is_a?(Hash)
          end
        end
        keys
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

    private def self.flatten(data : I18n::TranslationsHash, prefix : String, into : Set(String)) : Nil
      data.each do |name, value|
        key = prefix.empty? ? name : "#{prefix}.#{name}"
        into << key
        flatten(value, key, into) if value.is_a?(Hash)
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

    # Clés citées absentes du catalogue chargé, dans une langue au moins.
    def self.unknown_keys(root : String, globs : Array(String)) : Array(String)
      usages(root, globs).compact_map do |usage|
        missing = LOCALES.reject { |locale| known?(locale, usage.key) }
        "#{usage.file}:#{usage.line} : #{usage.key} absente en #{missing.join(", ")}" unless missing.empty?
      end.uniq!
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

      def initialize(@exclusions : Hash(String, String) = {} of String => String, glue : Array(String) = GLUE,
                     @routes : Array(Route) = Translations.routes, @literals = [] of String, &@scope : Route -> Bool)
        @routes = @routes.reject { |route| glue.includes?(route.handler.name) }
        unknown = @exclusions.keys - @routes.map(&.name)
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
          links(html).each { |link| queue << link } if html
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
        "#{checked_routes.size} routes, #{checked} pages contrôlées (adresse × langue)"
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
