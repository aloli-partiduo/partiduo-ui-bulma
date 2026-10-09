# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Consultation de la Comptabilité : écritures (menu `accounting:entries`),
  # une écriture et son extourne, « Comptes et tiers » (menu
  # `accounting:accounts`, ADR-005 D9). Tout passe par `Partiduo::Api`.
  abstract class AccountingScreen < ReferenceHandler
    alias Acc = Partiduo::Api::Accounting

    @working_period : Partiduo::Api::Core::PeriodView?
    @working_period_read = false

    def working_period : Partiduo::Api::Core::PeriodView?
      return @working_period if @working_period_read
      @working_period_read = true
      @working_period = begin
        Shell.working_period(request, current.actor)
      rescue Partiduo::Api::AccessDenied
        nil
      end
    end

    def reference_day : Time
      today = Partiduo::Api::Core.today
      period = working_period
      return today unless period
      period.includes?(today) ? today : period.starts_on
    end

    # Début de l'exercice de la période de travail (bornes par défaut).
    def fiscal_year_start : Time?
      period = working_period || return
      Partiduo::Api::Core.fiscal_year(current.actor, period.fiscal_year_id).starts_on
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      nil
    end

    # Date d'un filtre (saisie abrégée admise) ; texte illisible : `nil`.
    def query_day(name : String) : Time?
      text = query(name)
      return if text.empty?
      fmt.parse_short_date(text, reference_day)
    end

    # Code de fiche s'il en existe une de ce nom (sinon un numéro de compte).
    def card_code?(text : String) : String?
      return if text.empty? || text.matches?(/\A[0-9]+\z/)
      Partiduo::Api::Cards.card_by_code(current.actor, text).try(&.code)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    def signed(value : BigDecimal) : String
      fmt.amount(value)
    end

    def ledger_label(code : String, kind : Acc::LedgerKind) : String
      "#{code} · #{I18n.t("accounting.ledger_kinds.#{kind.code}")}"
    end

    # Consultation d'un compte ou d'un tiers (navigation transverse, D9).
    def account_url(number : String) : String
      "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => number})}"
    end

    def card_url(code : String) : String
      "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => code})}"
    end
  end

  # Écritures : recherche par journal, dates et texte (`Api::Accounting.entries`).
  class EntriesHandler < AccountingScreen
    LIMIT   = 500
    FILTERS = %w[ledger from to q]

    def get
      # Critères gardés d'une visite à l'autre (D-UI-035).
      if redirect = PersistentFilters.apply(request, "entries", FILTERS)
        return redirect
      end
      context["persistent_filters"] = true
      actor = current.actor
      from, to = bounds
      criteria = Acc::EntryQuery.new(ledger_id: query("ledger").to_i64?, date_from: from, date_to: to, text: query("q").presence, limit: LIMIT)
      total = Acc.count_entries(actor, criteria)
      params = {} of String => String
      FILTERS.each { |name| params[name] = query(name) unless query(name).empty? }
      table = Table.new(I18n.t("accounting.menu.acc_entries"), columns, Acc.entries(actor, criteria).map { |entry| row(entry) },
        reverse("accounting:entries"), params, empty_message: I18n.t("ui.entries.list_empty"))
      actions = [] of Screen::Action
      actions << link_action("ui.entries.titles.misc", reverse("accounting:entry_misc"), "primary", "plus") if can?("accounting.entry.post")
      actions << link_action("ui.receipts_archive.title", reverse("accounting:receipts_archive"), icon: "paperclip") if can?("core.attachment.read")
      intro = total > LIMIT ? I18n.t("ui.entries.truncated", count: LIMIT, total: total) : nil
      list_page(I18n.t("accounting.menu.acc_entries"), table, [crumb("core.menu.consult")], "ui.entries.csv_name", actions,
        filters: filters(from, to), intro: intro, filter: false)
    end

    # Bornes demandées ; sans critère, celles de la période de travail.
    private def bounds : {Time?, Time?}
      period = working_period
      searching = !query("q").empty?
      from = query_day("from") || (query("from").empty? && !searching ? period.try(&.starts_on) : nil)
      to = query_day("to") || (query("to").empty? && !searching ? period.try(&.ends_on) : nil)
      {from, to}
    end

    private def columns : Array(Table::Column)
      [
        Table::Column.new("date", I18n.t("ui.entries.date"), "mono"),
        Table::Column.new("ledger", I18n.t("ui.entries.ledger"), "mono", secondary: true),
        Table::Column.new("receipt", I18n.t("ui.entries.receipt"), "mono"),
        Table::Column.new("label", I18n.t("ui.entries.label")),
        Table::Column.new("amount", I18n.t("ui.entries.amount"), "amount"),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status"), secondary: true),
      ]
    end

    private def row(entry : Acc::EntryView) : Table::Row
      Table::Row.new([
        Table::Cell.new(fmt.date(entry.date), sort: date_key(entry.date), csv: date_key(entry.date)),
        Table::Cell.new(entry.ledger_code),
        Table::Cell.new(entry.receipt || entry.internal_code, reverse("accounting:entry", id: entry.id)),
        Table::Cell.new(entry.label),
        Table::Cell.new(fmt.amount(entry.amount), sort: entry.amount, csv: fmt.csv_amount(entry.amount)),
        Table::Cell.new(status_label(entry)),
      ], entry.cancelled? ? "pd-row-closed" : "")
    end

    private def filters(from : Time?, to : Time?) : Form
      ledgers = Acc.ledgers(current.actor).reject(&.access.none?)
      options = [option("", I18n.t("ui.ledgers.all_kinds"))] + ledgers.map { |ledger| option(ledger.id.to_s, "#{ledger.code} · #{ledger.name}") }
      search_filters([
        Form::Field.new("ledger", I18n.t("ui.entries.ledger"), "select", query("ledger"), options: options),
        Form::Field.new("from", I18n.t("ui.accounts.from"), value: query("from").presence || fmt.date(from), mono: true),
        Form::Field.new("to", I18n.t("ui.accounts.to"), value: query("to").presence || fmt.date(to), mono: true),
      ])
    end

    private def status_label(entry : Acc::EntryView) : String
      if entry.cancelled?
        I18n.t("ui.entries.cancelled")
      elsif entry.reversal?
        I18n.t("ui.entries.reversal")
      else
        ""
      end
    end
  end

  # Une écriture : en-tête, lignes (comptes et tiers cliquables), extourne.
  class EntryShowHandler < AccountingScreen
    def get
      entry = Acc.entry(current.actor, id_param)
      actions = [] of Screen::Action
      if can?("accounting.entry.cancel") && !entry.cancelled? && !entry.reversal?
        actions << post_action("ui.entries.cancel", reverse("accounting:entry_cancel", id: entry.id), "ui.entries.cancel_confirm", "danger")
      end
      title = I18n.t("ui.entries.entry_title", receipt: entry.receipt || entry.internal_code)
      sections = [Screen::Section.new(I18n.t("ui.entries.summary"), items(entry)), Screen::Section.new(I18n.t("ui.entries.lines"), table: lines(entry))]
      # Facture d'achat reçue derrière l'écriture (ADR-004 D9).
      received_section(entry).try { |section| sections.insert(1, section) }
      # Ventilation analytique (lot 5), si le module est actif.
      AnalyticEntrySection.build(self, entry).try { |section| sections << section }
      # Actions de suivi qui citent l'écriture (lot 6), si le Suivi est actif.
      FollowupLinkedSection.build(self, "entry:#{entry.id}").try { |section| sections << section }
      detail_page(title, [crumb("core.menu.consult"), crumb("accounting.menu.acc_entries", reverse("accounting:entries"))],
        sections, actions, status_tag: status(entry))
    end

    private def received_section(entry : Acc::EntryView) : Screen::Section?
      invoice = Acc.received_invoice_for_entry(current.actor, entry.id)
      return unless invoice
      attachment_url = invoice.attachment_id.try { |id| can?("core.attachment.read") ? reverse("core:attachment", id: id) : nil }
      Screen::Section.new(I18n.t("ui.received_invoice.section"), [
        Screen::Item.new(I18n.t("ui.entries.origin"), I18n.t(invoice.origin_key)),
        Screen::Item.new(I18n.t("ui.received_invoice.number"), invoice.number, mono: true),
        Screen::Item.new(I18n.t("ui.received_invoice.invoice_date"), fmt.date(invoice.invoice_date), mono: true),
        Screen::Item.new(I18n.t("ui.received_invoice.amount"), "#{fmt.amount(invoice.total_amount)} #{invoice.currency_code}", mono: true),
        Screen::Item.new(I18n.t("ui.received_invoice.file"), attachment_url ? I18n.t("ui.received_invoice.open_file") : "", attachment_url),
      ])
    end

    private def status(entry : Acc::EntryView) : String?
      if entry.cancelled?
        I18n.t("ui.entries.cancelled")
      elsif entry.reversal?
        I18n.t("ui.entries.reversal")
      end
    end

    private def items(entry : Acc::EntryView) : Array(Screen::Item)
      [
        Screen::Item.new(I18n.t("ui.entries.ledger"), entry.ledger_code, mono: true),
        Screen::Item.new(I18n.t("ui.entries.date"), fmt.date(entry.date), mono: true),
        Screen::Item.new(I18n.t("ui.entries.due_date"), fmt.date(entry.due_date), mono: true),
        Screen::Item.new(I18n.t("ui.entries.receipt"), entry.receipt || "", mono: true),
        Screen::Item.new(I18n.t("ui.entries.internal_code"), entry.internal_code, mono: true),
        Screen::Item.new(I18n.t("ui.entries.label"), entry.label),
        Screen::Item.new(I18n.t("ui.entries.amount"), "#{fmt.amount(entry.amount)} #{entry.currency_code}", mono: true),
        Screen::Item.new(I18n.t("ui.entries.source"), entry.source, mono: true),
        Screen::Item.new(I18n.t("ui.entries.reversal_of"), entry.reversal_of_id.try(&.to_s) || "",
          entry.reversal_of_id.try { |id| reverse("accounting:entry", id: id) }),
        Screen::Item.new(I18n.t("ui.entries.reversed_by"), entry.reversed_by_id.try(&.to_s) || "",
          entry.reversed_by_id.try { |id| reverse("accounting:entry", id: id) }),
      ]
    end

    private def lines(entry : Acc::EntryView) : Table
      columns = [
        Table::Column.new("account", I18n.t("ui.entries.account"), "mono"),
        Table::Column.new("card", I18n.t("ui.entries.card"), "mono", secondary: true),
        Table::Column.new("label", I18n.t("ui.entries.label")),
        Table::Column.new("vat", I18n.t("ui.entries.vat"), "mono", secondary: true),
        Table::Column.new("debit", I18n.t("ui.entries.debit"), "amount"),
        Table::Column.new("credit", I18n.t("ui.entries.credit"), "amount"),
        Table::Column.new("matching", I18n.t("ui.accounts.letter"), "mono"),
      ]
      rows = entry.lines.map do |line|
        Table::Row.new([
          Table::Cell.new("#{line.account_number} · #{line.account_label}", account_url(line.account_number), sort: line.account_number),
          Table::Cell.new(line.card_code || "", line.card_code.try { |code| card_url(code) }),
          Table::Cell.new(line.label),
          Table::Cell.new(line.vat_rate_code || ""),
          Table::Cell.new(line.side.debit? ? fmt.amount(line.amount) : "", sort: line.debit),
          Table::Cell.new(line.side.credit? ? fmt.amount(line.amount) : "", sort: line.credit),
          Table::Cell.new(line.matching_code || ""),
        ])
      end
      Table.new(I18n.t("ui.entries.lines"), columns, rows, reverse("accounting:entry", id: entry.id), id: "pd-entry-lines")
    end
  end

  # Annulation par extourne (`cancel_entry`), à la date de l'écriture.
  class EntryCancelHandler < AccountingScreen
    def post
      entry = Acc.entry(current.actor, id_param)
      result = Acc.cancel_entry(current.actor, Acc::CancelEntryInput.new(entry.id))
      if reversal = result.value?
        flash["success"] = I18n.t("ui.entries.cancelled_by", receipt: reversal.receipt || reversal.internal_code)
        go(reverse("accounting:entry", id: reversal.id))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(reverse("accounting:entry", id: entry.id))
      end
    end
  end
end
