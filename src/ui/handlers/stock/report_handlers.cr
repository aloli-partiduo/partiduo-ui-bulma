# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Éditions du Stock (menus `stock:state`, `stock:history`,
  # `stock:valuation`, successeurs de `stock_state.inc.php`,
  # `stock_histo.inc.php` et de `Stock::summary` / `Stock::history`) : tout
  # vient de `Partiduo::Api::Stock` (quantités, coût moyen, valeurs) ; les
  # exports CSV sont produits par le cœur. Onglets entre les trois éditions,
  # critères gardés par écran (D-UI-035) ; un code stock mène à son
  # historique, un mouvement à sa pièce d'origine.
  abstract class StockReportScreen < ReportScreen
    include StockSources

    alias Stk = Partiduo::Api::Stock

    TABS = {
      "state"     => "stock.menu.stock_state",
      "history"   => "stock.menu.stock_history",
      "valuation" => "stock.menu.stock_valuation",
    }

    @repositories : Array(Stk::RepositoryView)?

    # Nom de route de l'écran (onglet courant).
    abstract def route : String

    def screen_code : String
      "stock_#{route}"
    end

    def title : String
      I18n.t(TABS[route])
    end

    def reports_crumbs : Array(Screen::Crumb)
      [crumb(route == "valuation" ? "core.menu.reports" : "core.menu.consult")]
    end

    def tabs : Array(Screen::Tab)
      TABS.map { |name, key| Screen::Tab.new(I18n.t(key), reverse("stock:#{name}"), name == route) }
    end

    def repositories : Array(Stk::RepositoryView)
      @repositories ||= Stk.repositories(current.actor)
    end

    def repository_filter : Int64?
      query("repository").to_i64?.try { |id| repositories.any?(&.id.==(id)) ? id : nil }
    end

    def repository_field : Form::Field
      options = [option("", I18n.t("ui.stock.all_repositories"))] + repositories.map { |repository| option(repository.id.to_s, repository.name) }
      Form::Field.new("repository", I18n.t("ui.stock.repository"), "select", query("repository"), options: options)
    end

    def export_actions : Array(Screen::Action)
      [link_action("ui.table.export_csv", export_url("csv"), icon: "download"),
       link_action("ui.reports.export_pdf", export_url("pdf"), icon: "printer")]
    end

    def stock_file_response(file : Stk::FileView) : Marten::HTTP::Response
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end

    def stock_page(filters : Form, sections : Array(Screen::Section), summary : Array(Screen::Item)? = nil,
                   intro : String? = nil) : Marten::HTTP::Response
      context["tabs"] = tabs
      context["tabs_label"] = I18n.t("ui.stock.reports")
      report_page(title, filters, sections, summary, intro: intro)
    end

    def quantity_cell(value : BigDecimal, url : String? = nil, blank_zero : Bool = false) : Table::Cell
      text = blank_zero && value.zero? ? "" : fmt.number(value)
      Table::Cell.new(text, text.empty? ? nil : url, sort: value, csv: fmt.number(value, group: false))
    end

    def history_url(stock_code : String, repository_id : Int64?, from : Time? = nil, to : Time? = nil) : String
      params = {"stock_code" => stock_code, "f" => "1"}
      repository_id.try { |id| params["repository"] = id.to_s }
      iso(from).try { |text| params["from"] = text }
      iso(to).try { |text| params["to"] = text }
      "#{reverse("stock:history")}?#{URI::Params.encode(params)}"
    end

    def names_cell(names : Array(String)) : Table::Cell
      Table::Cell.new(names.join(", "))
    end
  end

  # État des stocks (`Stock::summary`) : par dépôt et code stock, quantité
  # à l'ouverture, entrées, sorties, quantité à la clôture.
  class StockStateHandler < StockReportScreen
    def route : String
      "state"
    end

    def filter_names : Array(String)
      %w[from to repository]
    end

    def report : Marten::HTTP::Response
      from, to = bounds
      from ||= Partiduo::Api::Core.today.at_beginning_of_year
      to ||= Partiduo::Api::Core.today
      criteria = Stk::StateQuery.new(date_from: from, date_to: to, repository_id: repository_filter)
      return stock_file_response(Stk.export_state(current.actor, criteria)) if csv?
      view = Stk.state(current.actor, criteria)
      columns = [
        column("repository", "ui.stock.repository"), column("stock_code", "ui.stock.stock_code", "mono"),
        column("cards", "ui.stock.cards", secondary: true), column("opening", "ui.stock.opening", "amount"),
        column("in", "ui.stock.quantity_in", "amount"), column("out", "ui.stock.quantity_out", "amount"),
        column("closing", "ui.stock.closing", "amount"),
      ]
      rows = view.rows.map do |row|
        url = history_url(row.stock_code, row.repository_id, view.date_from, view.date_to)
        Table::Row.new([
          Table::Cell.new(row.repository_name), Table::Cell.new(row.stock_code, url), names_cell(row.card_names),
          quantity_cell(row.opening), quantity_cell(row.quantity_in, url, true), quantity_cell(row.quantity_out, url, true),
          quantity_cell(row.closing),
        ], row.closing < 0 ? "pd-row-warning" : "")
      end
      table = report_table(title, columns, rows, "pd-stock-state")
      sections = [Screen::Section.new(period_label(view.date_from, view.date_to), table: table)]
      negative = view.rows.count(&.closing.<(0))
      summary = [Screen::Item.new(I18n.t("ui.stock.rows_count"), view.rows.size.to_s, mono: true)]
      summary << Screen::Item.new(I18n.t("ui.stock.negative_count"), negative.to_s, mono: true) if negative > 0
      stock_page(filters_form([date_field("from", "ui.accounts.from", from), date_field("to", "ui.accounts.to", to),
                               repository_field] of Form::Field?), sections, summary)
    end
  end

  # Historique des mouvements (`Stock::history`) : critères du cœur
  # (`MovementQuery`), pages de 500 ; chaque mouvement mène à son opération
  # manuelle ou à sa pièce d'origine.
  class StockHistoryHandler < StockReportScreen
    PER_PAGE = 500

    def route : String
      "history"
    end

    def filter_names : Array(String)
      %w[from to repository stock_code direction source]
    end

    def report : Marten::HTTP::Response
      from = filter_day("from")
      to = filter_day("to")
      direction = Stk::DIRECTIONS.find(&.==(query("direction")))
      source = query("source").presence
      page_number = {query("page").to_i? || 1, 1}.max
      criteria = Stk::MovementQuery.new(repository_id: repository_filter, stock_code: query("stock_code").presence.try(&.upcase),
        direction: direction, date_from: from, date_to: to, source: source,
        # PDF : tous les mouvements (limite du contrat), pas la seule page.
        limit: pdf? ? 10_000 : PER_PAGE, offset: pdf? ? 0 : (page_number - 1) * PER_PAGE)
      return stock_file_response(Stk.export_movements(current.actor, criteria)) if csv?
      movements = Stk.movements(current.actor, criteria)
      count = Stk.count_movements(current.actor, criteria)
      columns = [
        column("date", "ui.stock.date", "mono"), column("repository", "ui.stock.repository"),
        column("stock_code", "ui.stock.stock_code", "mono"), column("card", "ui.stock.card", "mono", secondary: true),
        column("name", "ui.stock.card_name"), column("in", "ui.stock.quantity_in", "amount"),
        column("out", "ui.stock.quantity_out", "amount"), column("unit_cost", "ui.stock.unit_cost", "amount", secondary: true),
        column("origin", "ui.stock.origin"), column("comment", "ui.stock.comment", secondary: true),
      ]
      rows = movements.map do |movement|
        Table::Row.new([
          date_cell(movement.date),
          Table::Cell.new(movement.repository_name),
          Table::Cell.new(movement.stock_code, history_url(movement.stock_code, movement.repository_id, from, to)),
          Table::Cell.new(movement.card_code, reverse("cards:show", id: movement.card_id)),
          Table::Cell.new(movement.card_name),
          quantity_cell(movement.in? ? movement.quantity : BigDecimal.new(0), blank_zero: true),
          quantity_cell(movement.out? ? movement.quantity : BigDecimal.new(0), blank_zero: true),
          Table::Cell.new(movement.unit_cost.try { |cost| fmt.number(cost) } || "", sort: movement.unit_cost || BigDecimal.new(0)),
          origin_cell(movement),
          Table::Cell.new(movement.comment),
        ])
      end
      table = report_table(title, columns, rows, "pd-stock-history")
      sections = [Screen::Section.new(title, table: table)]
      pages = ((count + PER_PAGE - 1) // PER_PAGE).to_i
      if pages > 1
        links = (1..pages).map do |number|
          params = current_params.merge({"page" => number.to_s})
          Screen::Action.new(number.to_s, "#{request.path}?#{URI::Params.encode(params)}", "get", number == page_number ? "primary" : "small")
        end
        sections << Screen::Section.new(I18n.t("ui.stock.pages"), note: I18n.t("ui.stock.page_of", page: page_number, pages: pages), actions: links)
      end
      summary = [Screen::Item.new(I18n.t("ui.stock.movements_count"), count.to_s, mono: true)]
      stock_page(filters, sections, summary)
    end

    private def origin_cell(movement : Stk::MovementView) : Table::Cell
      if change_id = movement.change_id
        Table::Cell.new(I18n.t("ui.stock.sources.change"), reverse("stock:change", id: change_id))
      elsif movement.source.empty?
        Table::Cell.new("")
      else
        Table::Cell.new(source_label(movement.source), source_url(movement.source))
      end
    end

    private def filters : Form
      directions = [option("", I18n.t("ui.stock.all_directions")), option("in", I18n.t("ui.stock.direction_in")),
                    option("out", I18n.t("ui.stock.direction_out"))]
      sources = [option("", I18n.t("ui.stock.all_origins"))] +
                SOURCES.map { |kind| option("#{kind}:", I18n.t("ui.stock.origins.#{kind}")) }
      filters_form([
        date_field("from", "ui.accounts.from", nil), date_field("to", "ui.accounts.to", nil), repository_field,
        text_field("stock_code", "ui.stock.stock_code"),
        Form::Field.new("direction", I18n.t("ui.stock.direction"), "select", query("direction"), options: directions),
        Form::Field.new("source", I18n.t("ui.stock.origin"), "select", query("source"), options: sources),
      ] of Form::Field?)
    end
  end

  # Valorisation au coût moyen pondéré (D-STK-005) à une date.
  class StockValuationHandler < StockReportScreen
    def route : String
      "valuation"
    end

    def filter_names : Array(String)
      %w[date repository]
    end

    def report : Marten::HTTP::Response
      day = filter_day("date") || Partiduo::Api::Core.today
      repository = repository_filter
      return stock_file_response(Stk.export_valuation(current.actor, day, repository)) if csv?
      view = Stk.valuation(current.actor, day, repository)
      columns = [
        column("repository", "ui.stock.repository"), column("stock_code", "ui.stock.stock_code", "mono"),
        column("cards", "ui.stock.cards", secondary: true), column("quantity", "ui.stock.quantity", "amount"),
        column("unit_cost", "ui.stock.average_cost", "amount"), column("value", "ui.stock.value", "amount"),
      ]
      rows = view.rows.map do |row|
        Table::Row.new([
          Table::Cell.new(row.repository_name),
          Table::Cell.new(row.stock_code, history_url(row.stock_code, row.repository_id, nil, view.date)),
          names_cell(row.card_names),
          quantity_cell(row.quantity),
          Table::Cell.new(row.unit_cost.try { |cost| fmt.number(cost) } || I18n.t("ui.stock.no_cost"), sort: row.unit_cost || BigDecimal.new(0)),
          row.value.try { |value| total_cell(value) } || Table::Cell.new(""),
        ])
      end
      blanks = Array.new(5) { Table::Cell.new("") }
      blanks[0] = Table::Cell.new(I18n.t("ui.reports.total"))
      total = Table::Row.new(blanks + [total_cell(view.total)], "pd-row-total")
      table = report_table(title, columns, rows, "pd-stock-valuation", footer: [total])
      missing = view.rows.count { |row| row.value.nil? && !row.quantity.zero? }
      summary = [Screen::Item.new(I18n.t("ui.stock.total_value"), fmt.amount(view.total), mono: true)]
      intro = missing > 0 ? I18n.t("ui.stock.missing_cost", {"count" => missing.to_s}) : I18n.t("ui.stock.valuation_intro")
      stock_page(filters_form([date_field("date", "ui.stock.date", day), repository_field] of Form::Field?),
        [Screen::Section.new(I18n.t("ui.stock.valuation_on", date: fmt.date(view.date)), table: table)], summary, intro)
    end
  end
end
