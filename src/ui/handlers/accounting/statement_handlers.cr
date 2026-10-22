# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # « Comptes et tiers » (ADR-005 D9, maquette « Consultation d'un compte ou
  # d'un tiers ») : sélection par nom, code de fiche ou numéro de compte, avec
  # complétion ; période ; « non lettrées seulement » ; synthèse (solde, reste
  # dû, échu, balance âgée) ; mouvements ; fiche du tiers ; lettrer,
  # relancer, exporter. Tout vient de `Api::Accounting.account_statement`.
  class StatementView
    include Marten::Template::Object::Auto

    class Move
      include Marten::Template::Object::Auto

      getter date : String
      getter ledger : String
      getter receipt : String
      getter label : String
      getter entry_url : String
      getter due_date : String
      getter overdue : Bool
      getter debit : String
      getter credit : String
      getter amount : String
      getter balance : String
      getter letter : String

      def initialize(@date, @ledger, @receipt, @label, @entry_url, @due_date, @overdue, @debit, @credit, @amount, @balance, @letter)
      end
    end

    # Tranche de la balance âgée : montant, part de la barre (en %).
    class Bucket
      include Marten::Template::Object::Auto

      getter key : String
      getter amount : String
      getter share : Int32
      getter color : String

      def initialize(@key, @amount, @share, @color)
      end

      def label_key : String
        "ui.accounts.buckets.#{key}"
      end
    end

    getter title : String
    getter subtitle : String
    getter balance : String
    getter remaining : String
    getter remaining_key : String
    getter overdue : String
    getter has_overdue : Bool
    getter buckets : Array(Bucket)
    getter moves : Array(Move)?
    getter count : String
    getter opening : String
    getter card_items : Array(Screen::Item)?

    def initialize(@title, @subtitle, @balance, @remaining, @remaining_key, @overdue, @has_overdue, @buckets, @moves,
                   @count, @opening, @card_items)
    end
  end

  class StatementHandler < AccountingScreen
    def get
      text = selection
      # Vocabulaire du type de dossier : « Comptes et contacts » d'un foyer.
      context["title"] = I18n.t(kind_key("accounting.menu.acc_accounts"))
      %w[selection pick intro].each { |name| context["#{name}_key"] = kind_key("ui.accounts.#{name}") }
      context["crumbs"] = [crumb("core.menu.consult"), crumb("accounting.menu.acc_accounts", reverse("accounting:accounts"))]
      context["q"] = text
      from = query_day("from") || (query("from").empty? ? fiscal_year_start : nil)
      to = query_day("to")
      context["from"] = query("from").presence || fmt.date(from)
      context["to"] = query("to")
      context["open_only"] = query("open") == "1"
      context["statement"] = nil
      context["not_found"] = nil
      context["actions"] = [] of Screen::Action
      return page("ui/accounting/statement.html") if text.empty?

      card = card_code?(text)
      criteria = Acc::StatementQuery.new(account: card ? nil : text, card: card, date_from: from, date_to: to,
        unmatched_only: query("open") == "1")
      statement = begin
        Acc.account_statement(current.actor, criteria)
      rescue Partiduo::Api::NotFound
        context["not_found"] = I18n.t(kind_key("ui.accounts.not_found"), q: text)
        return page("ui/accounting/statement.html", status: 404)
      end
      return export_response(csv_table(statement), I18n.t("ui.accounts.csv_name")) if export?
      context["statement"] = view(statement)
      context["actions"] = actions(statement, text)
      page("ui/accounting/statement.html")
    end

    # Compte ou tiers demandé : `q`, ou `account` / `card` (liens du plan
    # comptable, des écritures, du tableau de bord).
    private def selection : String
      query("q").presence || query("card").presence || query("account").presence || ""
    end

    private def view(statement : Acc::AccountStatementView) : StatementView
      title, subtitle = heading(statement)
      remaining = statement.remaining
      remaining_key = if remaining.positive?
                        "ui.accounts.to_collect"
                      elsif remaining.negative?
                        "ui.accounts.to_pay"
                      else
                        "ui.accounts.remaining"
                      end
      ageing = statement.ageing
      parts = {"not_due" => ageing.not_due, "days_1_30" => ageing.days_1_30, "days_31_60" => ageing.days_31_60, "over_60" => ageing.over_60}
      total = parts.values.sum(BigDecimal.new(0), &.abs)
      colors = {"not_due" => "var(--pd-ok)", "days_1_30" => "var(--pd-warn)", "days_31_60" => "var(--pd-gap)", "over_60" => "var(--pd-sidebar)"}
      buckets = parts.map do |key, amount|
        share = total.zero? ? 0 : (amount.abs * 100 / total).round(0, mode: :ties_away).to_i
        StatementView::Bucket.new(key, fmt.amount(amount), share, colors[key])
      end
      moves = statement.lines.map do |line|
        signed = line.debit - line.credit
        StatementView::Move.new(fmt.date(line.date), line.ledger_code, line.receipt || "", line.label,
          reverse("accounting:entry", id: line.entry_id), fmt.date(line.due_date), line.overdue,
          line.debit.zero? ? "" : fmt.amount(line.debit), line.credit.zero? ? "" : fmt.amount(line.credit),
          fmt.amount(signed), fmt.amount(line.balance), line.matching_code || "")
      end
      StatementView.new(title, subtitle, fmt.amount(statement.balance), fmt.amount(remaining.abs), remaining_key,
        fmt.amount(statement.overdue), !statement.overdue.zero?, buckets, moves.empty? ? nil : moves,
        I18n.t("ui.accounts.moves_count", count: moves.size), fmt.amount(statement.opening_balance), card_items(statement))
    end

    private def heading(statement : Acc::AccountStatementView) : {String, String}
      if name = statement.card_name
        {name, "#{statement.card_code} · #{statement.account.try(&.number) || ""}".rstrip(" ·")}
      elsif account = statement.account
        {"#{account.number} · #{account.label}", I18n.t("accounting.account_kinds.#{account.kind.code}")}
      else
        {"", ""}
      end
    end

    # Fiche du tiers : code, compte collectif, SIREN, TVA, courriel.
    private def card_items(statement : Acc::AccountStatementView) : Array(Screen::Item)?
      account = statement.account
      items = [] of Screen::Item
      if id = statement.card_id
        card = begin
          Partiduo::Api::Cards.card(current.actor, id)
        rescue Partiduo::Api::AccessDenied
          nil
        end
        items << Screen::Item.new(I18n.t("ui.cards.code"), statement.card_code || "", reverse("cards:show", id: id), mono: true)
        if card
          items << Screen::Item.new(I18n.t("ui.cards.category"), category_label(card.category_code, card.category_name))
          items << Screen::Item.new(I18n.t("ui.cards.siren"), card.siren, mono: true)
          items << Screen::Item.new(I18n.t("ui.cards.vat_number"), card.vat_number, mono: true)
          items << Screen::Item.new(I18n.t("ui.cards.email"), card.email)
          items << Screen::Item.new(I18n.t("ui.cards.phone"), card.phone)
        end
      end
      if account
        items << Screen::Item.new(I18n.t("ui.accounts.account"), "#{account.number} · #{account.label}",
          reverse("accounting:account", id: account.id), mono: true)
      end
      items << Screen::Item.new(I18n.t("ui.accounts.opening"), fmt.amount(statement.opening_balance), mono: true)
      items << Screen::Item.new(I18n.t("ui.accounts.total_debit"), fmt.amount(statement.total_debit), mono: true)
      items << Screen::Item.new(I18n.t("ui.accounts.total_credit"), fmt.amount(statement.total_credit), mono: true)
      items = items.reject(&.value.empty?)
      items.empty? ? nil : items
    end

    private def actions(statement : Acc::AccountStatementView, text : String) : Array(Screen::Action)
      actions = [] of Screen::Action
      if can?("accounting.matching.write")
        actions << link_action("ui.accounts.match", "#{reverse("accounting:matching")}?#{URI::Params.encode({"q" => text})}", icon: "check")
      end
      if (id = statement.card_id) && statement.remaining.positive? && module_active?("INVOICING") && can?("invoicing.reminder.send")
        actions << link_action("ui.accounts.remind", "#{reverse("invoicing:reminders")}?#{URI::Params.encode({"customer" => id.to_s})}", icon: "clock")
      end
      params = {"q" => text, "format" => "csv"}
      {"from", "to", "open"}.each { |name| params[name] = query(name) unless query(name).empty? }
      actions << link_action("ui.table.export_csv", "#{reverse("accounting:accounts")}?#{URI::Params.encode(params)}", icon: "download")
      params["format"] = "pdf"
      actions << link_action("ui.reports.export_pdf", "#{reverse("accounting:accounts")}?#{URI::Params.encode(params)}", icon: "printer")
      actions
    end

    private def csv_table(statement : Acc::AccountStatementView) : Table
      columns = %w[date ledger receipt label due_date debit credit balance letter].map do |key|
        Table::Column.new(key, I18n.t("ui.accounts.columns.#{key}"))
      end
      rows = statement.lines.map do |line|
        Table::Row.new([
          Table::Cell.new(date_key(line.date)), Table::Cell.new(line.ledger_code), Table::Cell.new(line.receipt || ""),
          Table::Cell.new(line.label), Table::Cell.new(date_key(line.due_date)),
          Table::Cell.new(fmt.csv_amount(line.debit)), Table::Cell.new(fmt.csv_amount(line.credit)),
          Table::Cell.new(fmt.csv_amount(line.balance)), Table::Cell.new(line.matching_code || ""),
        ])
      end
      Table.new(I18n.t(kind_key("accounting.menu.acc_accounts")), columns, rows, reverse("accounting:accounts"))
    end
  end
end
