# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Rapprochement bancaire (menu `accounting:reconciliation`, héritier de
  # `compta_fin_rec.inc.php`, D-UI-054) : opérations d'un journal financier
  # sans relevé, cochées puis rattachées au relevé de la banque ; l'écart
  # entre les soldes de début et de fin du relevé, le montant coché et le
  # reste sont recalculés à chaque case (HTMX) ; relevés rapprochés,
  # consultés ou annulés. Utilisable sans JavaScript.
  class ReconciliationView
    include Marten::Template::Object::Auto

    class Line
      include Marten::Template::Object::Auto

      getter id : Int64
      getter date : String
      getter receipt : String
      getter label : String
      getter amount : String
      getter entry_url : String
      getter checked : Bool

      def initialize(@id, @date, @receipt, @label, @amount, @entry_url, @checked)
      end
    end

    getter ledger_id : Int64
    getter title : String
    getter account : String
    getter balance : String
    getter reconciled : String
    getter unreconciled : String
    getter lines : Array(Line)?

    def initialize(@ledger_id, @title, @account, @balance, @reconciled, @unreconciled, @lines)
    end
  end

  # Contrôle de la sélection : écart du relevé, montant coché, reste.
  class ReconciliationCheck
    include Marten::Template::Object::Auto

    getter count : Int32
    getter delta : String
    getter selected : String
    getter remaining : String
    getter balanced : Bool

    def initialize(@count, @delta, @selected, @remaining, @balanced)
    end
  end

  abstract class ReconciliationScreen < AccountingScreen
    PERMISSION = "accounting.matching.write"

    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.consult"), crumb("accounting.menu.acc_reconciliation", reverse("accounting:reconciliation"))]
    end

    def ledger_param : Int64?
      (query("ledger").presence || field("ledger")).to_i64?
    end

    def checked_ids : Array(Int64)
      values = request.data.fetch_all("entry", [] of String) || [] of String
      values.compact_map(&.to_s.to_i64?).uniq!
    end

    def amount_field(name : String) : BigDecimal?
      text = field(name)
      text.empty? ? nil : fmt.parse_decimal(text)
    end

    # Totaux de la sélection, d'après les montants du contrat.
    def check(view : Acc::ReconciliationView, ids : Array(Int64)) : ReconciliationCheck
      selected = view.unreconciled.select { |line| ids.includes?(line.entry_id) }
      total = selected.sum(BigDecimal.new(0), &.amount)
      start, finish = amount_field("start_balance"), amount_field("end_balance")
      delta = start && finish ? finish - start : nil
      remaining = delta ? delta - total : nil
      ReconciliationCheck.new(selected.size, delta.try { |value| fmt.amount(value) } || "—", fmt.amount(total),
        remaining.try { |value| fmt.amount(value) } || "—", remaining.nil? || remaining.zero? || delta.try(&.zero?) || false)
    end

    # Exercice de la période de travail : bornes des soldes.
    def bounds : {Time?, Time?}
      period = working_period || return {nil, nil}
      year = Partiduo::Api::Core.fiscal_year(current.actor, period.fiscal_year_id)
      {year.starts_on, year.ends_on}
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      {nil, nil}
    end
  end

  class ReconciliationHandler < ReconciliationScreen
    def get
      require!("ACCOUNTING", "accounting.entry.read")
      show(ledger_param)
    end

    def post
      require!("ACCOUNTING", PERMISSION)
      ledger_id = ledger_param || raise Partiduo::Api::NotFound.new("ledger", 0)
      form_errors = [] of String
      start = amount_field("start_balance")
      finish = amount_field("end_balance")
      form_errors << I18n.t("ui.forms.invalid_number") if (!field("start_balance").empty? && start.nil?) ||
                                                          (!field("end_balance").empty? && finish.nil?)
      if form_errors.empty?
        input = Acc::ReconcileInput.new(ledger_id: ledger_id, reference: field("reference"), entry_ids: checked_ids,
          start_balance: start, end_balance: finish)
        result = Acc.reconcile(current.actor, input)
        if statement = result.value?
          flash["success"] = I18n.t("ui.reconciliation.done", reference: statement.reference, number: statement.entry_count.to_s,
            amount: fmt.amount(statement.amount))
          return go("#{reverse("accounting:reconciliation")}?#{URI::Params.encode({"ledger" => ledger_id.to_s})}")
        end
        form_errors.concat(result.errors.map { |error| fmt.message(error) })
      end
      show(ledger_id, form_errors, 422)
    end

    private def show(ledger_id : Int64?, refused = [] of String, status : Int32 = 200)
      ledgers = Acc.ledgers(current.actor, Acc::LedgerKind::Financial)
      ledger_id ||= ledgers.first?.try(&.id) if ledgers.size == 1
      context["title"] = I18n.t("accounting.menu.acc_reconciliation")
      context["crumbs"] = crumbs
      context["ledgers"] = ledgers.map { |ledger| Form::Option.new(ledger.id.to_s, "#{ledger.code} — #{ledger.name}", ledger.id == ledger_id) }
      context["no_ledger"] = ledgers.empty?
      context["refused"] = listed(refused)
      context["can_write"] = can?(PERMISSION)
      if ledger_id
        from, to = bounds
        view = Acc.reconciliation(current.actor, ledger_id, from, to)
        ids = checked_ids
        lines = view.unreconciled.map do |line|
          ReconciliationView::Line.new(line.entry_id, fmt.date(line.date), line.receipt || line.internal_code, line.label,
            fmt.amount(line.amount), reverse("accounting:entry", id: line.entry_id), ids.includes?(line.entry_id))
        end
        context["reconciliation"] = ReconciliationView.new(view.ledger_id, "#{view.ledger_code} — #{view.ledger_name}",
          view.account_number || "", fmt.amount(view.balance), fmt.amount(view.reconciled_balance),
          fmt.amount(view.unreconciled_balance), listed(lines))
        context["check"] = check(view, ids)
        context["reference"] = field("reference")
        context["start_balance"] = field("start_balance")
        context["end_balance"] = field("end_balance")
        context["statements"] = statements_table(view)
        context["period_note"] = from && to ? I18n.t("ui.reconciliation.period", from: fmt.date(from), to: fmt.date(to)) : nil
      end
      page("ui/accounting/reconciliation.html", status: status)
    end

    private def statements_table(view : Acc::ReconciliationView) : Table
      columns = [
        Table::Column.new("reference", I18n.t("ui.reconciliation.reference"), "mono"),
        Table::Column.new("created_at", I18n.t("ui.reconciliation.created_at"), secondary: true),
        Table::Column.new("count", I18n.t("ui.reconciliation.count"), "amount"),
        Table::Column.new("start", I18n.t("ui.reconciliation.start_balance"), "amount", secondary: true),
        Table::Column.new("end", I18n.t("ui.reconciliation.end_balance"), "amount", secondary: true),
        Table::Column.new("amount", I18n.t("ui.reconciliation.amount"), "amount"),
      ]
      rows = view.statements.map do |statement|
        Table::Row.new([
          Table::Cell.new(statement.reference, reverse("accounting:bank_statement", id: statement.id)),
          Table::Cell.new(fmt.timestamp_date(statement.created_at), sort: statement.created_at.to_s("%Y-%m-%dT%H:%M:%S")),
          Table::Cell.new(statement.entry_count.to_s, sort: BigDecimal.new(statement.entry_count)),
          Table::Cell.new(statement.start_balance.try { |value| fmt.amount(value) } || "", sort: statement.start_balance || BigDecimal.new(0)),
          Table::Cell.new(statement.end_balance.try { |value| fmt.amount(value) } || "", sort: statement.end_balance || BigDecimal.new(0)),
          Table::Cell.new(fmt.amount(statement.amount), sort: statement.amount),
        ])
      end
      table = Table.new(I18n.t("ui.reconciliation.statements"), columns, rows,
        "#{reverse("accounting:reconciliation")}?#{URI::Params.encode({"ledger" => view.ledger_id.to_s})}",
        empty_message: I18n.t("ui.reconciliation.no_statement"), id: "pd-statements")
      table.exportable = false
      table
    end
  end

  # Contrôle HTMX de la sélection.
  class ReconciliationCheckHandler < ReconciliationScreen
    def post
      require!("ACCOUNTING", "accounting.entry.read")
      ledger_id = ledger_param || raise Partiduo::Api::NotFound.new("ledger", 0)
      view = Acc.reconciliation(current.actor, ledger_id)
      render("ui/accounting/_reconciliation_check.html", {"check" => check(view, checked_ids)})
    end
  end

  class BankStatementHandler < ReconciliationScreen
    def get
      require!("ACCOUNTING", "accounting.entry.read")
      detail = Acc.bank_statement(current.actor, id_param)
      statement = detail.statement
      items = [
        Screen::Item.new(I18n.t("ui.reconciliation.ledger"), statement.ledger_code, mono: true),
        Screen::Item.new(I18n.t("ui.reconciliation.reference"), statement.reference, mono: true),
        Screen::Item.new(I18n.t("ui.reconciliation.start_balance"), statement.start_balance.try { |value| fmt.amount(value) } || ""),
        Screen::Item.new(I18n.t("ui.reconciliation.end_balance"), statement.end_balance.try { |value| fmt.amount(value) } || ""),
        Screen::Item.new(I18n.t("ui.reconciliation.amount"), fmt.amount(statement.amount)),
        Screen::Item.new(I18n.t("ui.reconciliation.created_at"), fmt.datetime(statement.created_at)),
      ]
      columns = [
        Table::Column.new("date", I18n.t("ui.accounts.columns.date")),
        Table::Column.new("receipt", I18n.t("ui.accounts.columns.receipt"), "mono"),
        Table::Column.new("label", I18n.t("ui.accounts.columns.label")),
        Table::Column.new("amount", I18n.t("ui.reconciliation.amount"), "amount"),
      ]
      rows = detail.lines.map do |line|
        Table::Row.new([
          Table::Cell.new(fmt.date(line.date), sort: date_key(line.date)),
          Table::Cell.new(line.receipt || line.internal_code, reverse("accounting:entry", id: line.entry_id)),
          Table::Cell.new(line.label),
          Table::Cell.new(fmt.amount(line.amount), sort: line.amount),
        ])
      end
      table = Table.new(I18n.t("ui.reconciliation.operations"), columns, rows, reverse("accounting:bank_statement", id: statement.id))
      table.exportable = false
      actions = [link_action("ui.reconciliation.back", "#{reverse("accounting:reconciliation")}?#{URI::Params.encode({"ledger" => statement.ledger_id.to_s})}")]
      if can?(PERMISSION)
        actions << post_action("ui.reconciliation.cancel", reverse("accounting:bank_statement_delete", id: statement.id),
          "ui.reconciliation.cancel_confirm", "danger")
      end
      detail_page(I18n.t("ui.reconciliation.statement_title", reference: statement.reference), crumbs,
        [Screen::Section.new(statement.reference, items), Screen::Section.new(I18n.t("ui.reconciliation.operations"), table: table)],
        actions)
    end
  end

  class BankStatementDeleteHandler < ReconciliationScreen
    def post
      require!("ACCOUNTING", PERMISSION)
      detail = Acc.bank_statement(current.actor, id_param)
      flash_result(Acc.unreconcile(current.actor, detail.statement.id), "ui.reconciliation.cancelled",
        {"reference" => detail.statement.reference})
      go("#{reverse("accounting:reconciliation")}?#{URI::Params.encode({"ledger" => detail.statement.ledger_id.to_s})}")
    end
  end
end
