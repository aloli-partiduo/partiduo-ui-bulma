# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"
require "uri"

module PartiduoUi
  # Tableau d'un écran de liste : colonnes triables, filtre texte, pages,
  # export CSV (DECISIONS D-UI-016). Les cellules sont préparées par le
  # handler (texte déjà formaté selon la langue et le pays, clé de tri,
  # valeur CSV) ; le gabarit `ui/_table.html` ne fait que les afficher.
  #
  # Le tri et le filtre portent sur les lignes que le handler a lues par le
  # contrat : le contrat n'offre pas (encore) de tri côté base.
  class Table
    include Marten::Template::Object::Auto

    alias SortKey = String | BigDecimal

    PER_PAGE = 100

    # Colonne : `kind` `text`, `mono` (codes, numéros), `amount` (aligné à
    # droite), `actions` (boutons, ni triée ni exportée) ; `secondary` :
    # masquée sur téléphone.
    class Column
      include Marten::Template::Object::Auto

      getter key : String
      getter label : String
      getter kind : String
      getter secondary : Bool
      getter sortable : Bool

      def initialize(@key, @label, @kind = "text", @secondary = false, sortable : Bool = true)
        @sortable = sortable && kind != "actions"
      end

      def css : String
        classes = [] of String
        classes << "amount" if kind == "amount"
        classes << "pd-hide-s" if secondary
        classes.join(" ")
      end
    end

    class Cell
      include Marten::Template::Object::Auto

      getter text : String
      getter url : String?
      getter sort : SortKey
      getter csv : String
      getter tag : String?
      getter actions : Array(Screen::Action)?
      property css : String = ""
      # Texte lu par les technologies d'assistance seulement, avant le
      # contenu (profondeur d'un compte dans l'arbre).
      property hidden_text : String? = nil
      # Icône décorative affichée avant le texte (cadenas d'une ligne
      # intangible) ; son sens est donné par `hidden_text`.
      property icon : String? = nil

      # `tag` : texte affiché comme étiquette (« désactivé », « clos ») ;
      # `actions` : boutons de la ligne (colonne sans tri ni export).
      def initialize(@text, @url = nil, sort : SortKey? = nil, csv : String? = nil, @tag = nil,
                     actions : Array(Screen::Action)? = nil)
        @actions = actions.try { |list| Screen.listed(list) }
        @sort = sort || @text.downcase
        @csv = csv || @text
      end
    end

    class Row
      include Marten::Template::Object::Auto

      getter cells : Array(Cell)
      getter css : String
      # Groupe de la ligne (clé de `Table#groups`) ; en-tête du groupe à
      # afficher avant elle, posé par `Table#visible_rows`.
      property group : String? = nil
      property group_header : Group? = nil

      def initialize(@cells, @css = "", @group = nil)
      end
    end

    # En-tête d'un groupe de lignes (période de déclaration d'un registre) :
    # libellé, état, icône décorative facultative.
    class Group
      include Marten::Template::Object::Auto

      getter label : String
      getter status : String
      getter icon : String?

      def initialize(@label, @status = "", @icon = nil)
      end
    end

    # En-tête préparé pour le gabarit : lien de tri et état `aria-sort`.
    class Header
      include Marten::Template::Object::Auto

      getter label : String
      getter css : String
      getter url : String?
      getter aria_sort : String?
      getter sort_hint : String
      # Clé de la colonne : identifiant stable du lien de tri, auquel HTMX
      # rend le focus après le remplacement du tableau (WCAG 2.4.3).
      getter key : String

      def initialize(@label, @css, @url, @aria_sort, @sort_hint, @key = "")
      end
    end

    class PageLink
      include Marten::Template::Object::Auto

      getter number : Int32
      getter url : String
      getter current : Bool

      def initialize(@number, @url, @current)
      end
    end

    getter id : String
    getter caption : String
    getter columns : Array(Column)
    getter rows : Array(Row)
    getter path : String
    getter params : Hash(String, String)
    getter sort_key : String?
    getter descending : Bool
    getter page : Int32 = 1
    getter page_count : Int32 = 1
    getter total : Int32 = 0
    getter empty_message : String
    # Lignes de pied (totaux) : ni filtrées, ni triées, ni paginées.
    getter footer_rows : Array(Row)?
    # Liens d'export du pied de tableau : CSV (`?format=csv`), et PDF
    # (`?format=pdf`) quand l'écran le produit (éditions, lot 3) ; aucun
    # pour un tableau dont l'écran exporte autrement.
    property exportable : Bool = true
    property pdf : Bool = false
    # En-têtes des groupes de lignes, par clé (`Row#group`) : affichés
    # avant la première ligne de chaque suite de lignes du même groupe,
    # dans l'ordre du handler ou trié par `group_sort` (sinon le tri
    # disperserait les groupes).
    property groups : Hash(String, Group)? = nil
    property group_sort : String = "date"

    def initialize(@caption : String, @columns : Array(Column), @rows : Array(Row), @path : String,
                   @params : Hash(String, String) = {} of String => String, @empty_message : String = "",
                   @id : String = "pd-table", footer_rows : Array(Row)? = nil)
      @sort_key = nil
      @descending = false
      @total = @rows.size
      @footer_rows = footer_rows.try { |list| Screen.listed(list) }
      (@rows + (@footer_rows || [] of Row)).each do |row|
        row.cells.each_with_index do |cell, index|
          column = @columns[index]?
          next unless column
          classes = [column.css]
          classes << "pd-mono" if column.kind == "mono"
          classes << cell.css unless cell.css.empty?
          cell.css = classes.reject(&.empty?).join(" ")
        end
      end
    end

    # Paramètre de tri courant, repris par le formulaire de filtre.
    def sort_param : String
      @params["sort"]? || ""
    end

    # Filtre texte : lignes dont une cellule contient `query` (casse et
    # accents ignorés).
    def filter!(query : String) : self
      wanted = self.class.fold(query.strip)
      unless wanted.empty?
        @params["q"] = query.strip
        @rows.select! { |row| row.cells.any? { |cell| self.class.fold(cell.text).includes?(wanted) || self.class.fold(cell.csv).includes?(wanted) } }
      end
      @total = @rows.size
      self
    end

    # Tri par la colonne `key` (`-key` : décroissant) ; clé inconnue : ordre
    # du handler (celui du contrat).
    def sort!(requested : String) : self
      descending = requested.starts_with?('-')
      key = requested.lchop('-')
      index = @columns.index { |column| column.key == key && column.sortable }
      return self unless index
      @sort_key = key
      @descending = descending
      @params["sort"] = requested
      @rows = @rows.sort { |left, right| compare(left.cells[index].sort, right.cells[index].sort) }
      @rows.reverse! if descending
      self
    end

    def paginate!(requested : Int32, per_page : Int32 = PER_PAGE) : self
      @total = @rows.size
      @page_count = Math.max(1, (@total + per_page - 1) // per_page)
      @page = requested.clamp(1, @page_count)
      @rows = @rows[((@page - 1) * per_page), per_page]? || [] of Row
      self
    end

    # Rangées d'un paquet (liste vide : `nil`, pour le `{% if %}` de Marten),
    # en-têtes de groupe posés.
    def visible_rows : Array(Row)?
      return if @rows.empty?
      mark_groups
      @rows
    end

    private def mark_groups : Nil
      headers = @groups
      grouped = headers && (@sort_key.nil? || @sort_key == @group_sort)
      previous = nil
      @rows.each do |row|
        key = row.group
        row.group_header = grouped && key && key != previous ? headers.try(&.[key]?) : nil
        previous = key
      end
    end

    def headers : Array(Header)
      @columns.map do |column|
        unless column.sortable
          next Header.new(column.label, column.css, nil, nil, "", column.key)
        end
        current = @sort_key == column.key
        next_sort = current && !@descending ? "-#{column.key}" : column.key
        aria = current ? (@descending ? "descending" : "ascending") : nil
        hint = I18n.t(current && !@descending ? "ui.table.sort_descending" : "ui.table.sort_ascending")
        Header.new(column.label, column.css, url(sort: next_sort, page: nil), aria, hint, column.key)
      end
    end

    def pages : Array(PageLink)?
      return if @page_count <= 1
      (1..@page_count).map { |number| PageLink.new(number, url(page: number > 1 ? number.to_s : nil), number == @page) }
    end

    def summary : String
      I18n.t("ui.table.count", count: @total)
    end

    def csv_url : String
      url(format: "csv", page: nil)
    end

    def pdf_url : String
      url(format: "pdf", page: nil)
    end

    def query : String
      @params["q"]? || ""
    end

    # Adresse du tableau avec des paramètres changés (`nil` : retiré).
    def url(sort : String? = @params["sort"]?, page : String? = @page > 1 ? @page.to_s : nil, format : String? = nil) : String
      values = @params.dup
      {"sort" => sort, "page" => page, "format" => format}.each do |name, value|
        value ? (values[name] = value) : values.delete(name)
      end
      values.reject! { |_, value| value.empty? }
      values.empty? ? @path : "#{@path}?#{URI::Params.encode(values)}"
    end

    # Export CSV de toutes les lignes filtrées et triées (pas seulement la
    # page), avec l'en-tête traduit ; BOM UTF-8 pour les tableurs. Chaque
    # cellule est protégée contre l'injection de formules (A-FRM-5,
    # `csv_safe`) : une valeur reçue du public peut entrer dans une fiche
    # et ressortir ici.
    def to_csv(format : Format) : String
      "﻿" + CSV.build(separator: format.csv_separator) do |csv|
        exported = @columns.each_index.select { |index| @columns[index].kind != "actions" }.to_a
        csv.row(exported.map { |index| Table.csv_safe(@columns[index].label) })
        @rows.each { |row| csv.row(exported.map { |index| Table.csv_safe(row.cells[index].csv) }) }
      end
    end

    # Début de cellule qu'un tableur lit comme une formule ou une commande :
    # `=`, `+`, `-`, `@`, tabulation, retour chariot ou saut de ligne.
    FORMULA_START = /\A[=+\-@\t\r\n]/
    # Nombre écrit tel quel (montant, quantité : `-12.50`, `-3,2`), que le
    # tableur lit comme un nombre et jamais comme une formule.
    PLAIN_NUMBER = /\A-?\d+(?:[.,]\d+)?\z/

    # Cellule d'un export CSV neutralisée (A-FRM-5) : une valeur qui
    # commence par un caractère de formule est préfixée d'une apostrophe,
    # sauf un nombre écrit tel quel ; même règle que les éditions du cœur
    # (`Partiduo::Core::TableOutput.csv_text`, D-2F-009).
    def self.csv_safe(value : String) : String
      value.matches?(FORMULA_START) && !value.matches?(PLAIN_NUMBER) ? "'#{value}" : value
    end

    # Texte replié pour la comparaison : minuscules, sans accents.
    def self.fold(text : String) : String
      text.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
    end

    private def compare(left : SortKey, right : SortKey) : Int32
      case {left, right}
      when {BigDecimal, BigDecimal} then left.as(BigDecimal) <=> right.as(BigDecimal)
      when {String, String}         then self.class.fold(left.as(String)) <=> self.class.fold(right.as(String))
      else                               left.is_a?(BigDecimal) ? -1 : 1
      end
    end
  end
end
