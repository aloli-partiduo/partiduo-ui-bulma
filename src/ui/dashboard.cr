# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Tableau de bord (ADR-005 D5, maquette « Tableau de bord ») : tuiles de
  # chaque module actif et des extensions actives (`Extensions.tile`), dernières factures et écritures, « À traiter ».
  # Chaque module ne contribue que s'il est actif et que l'acteur a le droit
  # de lire ses données (DECISIONS D-UI-031) ; tout vient de `Partiduo::Api`.
  class Dashboard
    include Marten::Template::Object::Auto

    alias Acc = Partiduo::Api::Accounting
    alias Inv = Partiduo::Api::Invoicing

    class Tile
      include Marten::Template::Object::Auto

      getter label : String
      getter value : String
      getter sub : String?
      getter alert : String?
      getter url : String?
      getter module_code : String

      def initialize(@module_code, @label, @value, @sub = nil, @alert = nil, @url = nil)
      end
    end

    class Todo
      include Marten::Template::Object::Auto

      getter text : String
      getter detail : String?
      getter url : String?
      getter tone : String

      def initialize(@text, @detail = nil, @url = nil, @tone = "primary")
      end
    end

    class Row
      include Marten::Template::Object::Auto

      getter cells : Array(String)
      getter url : String

      def initialize(@cells, @url)
      end

      # Cellules par rang, lues par le gabarit.
      {% for index in 0..4 %}
        def c{{ index }} : String
          cells[{{ index }}]? || ""
        end
      {% end %}
    end

    getter tiles = [] of Tile
    getter todos = [] of Todo
    getter invoices : Array(Row)? = nil
    getter entries : Array(Row)? = nil
    getter new_entry_url : String? = nil
    getter new_invoice_url : String? = nil

    def initialize(@actor : Partiduo::Api::Actor, @fmt : Format, @active : Set(String), @today : Time = Partiduo::Api::Core.today)
    end

    def build : self
      accounting if @active.includes?("ACCOUNTING") && @actor.can?("accounting.entry.read")
      invoicing if @active.includes?("INVOICING") && @actor.can?("invoicing.invoice.read")
      followup if @active.includes?("FOLLOWUP") && @actor.can?("followup.action.read")
      # Tuiles des extensions actives (DECISIONS D-HOOK-001).
      @tiles.concat(Extensions.tiles(@actor, @fmt, @active))
      if @active.includes?("ACCOUNTING") && @actor.can?("accounting.entry.post")
        @new_entry_url = Marten.routes.reverse("accounting:entry_purchase")
      end
      if @active.includes?("INVOICING") && @actor.can?("invoicing.invoice.write")
        @new_invoice_url = Marten.routes.reverse("invoicing:invoice_new")
      end
      self
    end

    # Tableau de bord simplifié de la variante d'une extension (ADR-011 A2) :
    # ses tuiles seulement, sans dernières factures ni écritures ; « À
    # traiter » reçoit, comme ailleurs, les compteurs et la sécurité.
    def build_simple(tiles : Array(Tile)) : self
      @tiles.concat(tiles)
      self
    end

    def listed_tiles : Array(Tile)?
      @tiles.empty? ? nil : @tiles
    end

    def listed_todos : Array(Todo)?
      @todos.empty? ? nil : @todos
    end

    def add_todo(todo : Todo) : Nil
      @todos << todo
    end

    private def reverse(name : String, **params) : String
      Marten.routes.reverse(name, **params)
    end

    private def accounts_url(query : String) : String
      "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => query})}"
    end

    # --- Suivi ------------------------------------------------------------------------

    # Rappels du jour et en retard du Suivi (lot 6), dans « À traiter ».
    private def followup : Nil
      reminders = Partiduo::Api::Followup.reminders(@actor, @today)
      due = reminders.late + reminders.today
      return if due.empty?
      detail = due.first(3).map { |action| "#{action.reference} · #{action.title}" }.join(" · ")
      @todos << Todo.new(I18n.t("ui.dashboard.todo.followup_reminders", count: due.size), detail,
        reverse("followup:reminders"), reminders.late.empty? ? "primary" : "gap")
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # --- Comptabilité -------------------------------------------------------------

    private def accounting : Nil
      bank_tile
      receivables = Acc.party_balances(@actor, "customer", @today)
      payables = Acc.party_balances(@actor, "supplier", @today)
      overdue_customers = receivables.overdue
      @tiles << Tile.new("ACCOUNTING", I18n.t("ui.dashboard.tiles.receivables"), @fmt.amount(receivables.remaining),
        alert: overdue_customers.zero? ? nil : I18n.t("ui.dashboard.tiles.late", amount: @fmt.amount(overdue_customers)),
        url: receivables.worst_card_code.try { |code| accounts_url(code) })
      @tiles << Tile.new("ACCOUNTING", I18n.t("ui.dashboard.tiles.payables"), @fmt.amount(-payables.remaining),
        sub: payables.overdue.zero? ? nil : I18n.t("ui.dashboard.tiles.payables_late", amount: @fmt.amount(-payables.overdue)),
        url: payables.worst_card_code.try { |code| accounts_url(code) })
      vat_tile
      unless overdue_customers.zero?
        @todos << Todo.new(I18n.t("ui.dashboard.todo.overdue_customers", amount: @fmt.amount(overdue_customers)),
          receivables.worst_card_name.try { |name| I18n.t("ui.dashboard.todo.overdue_customers_detail", name: name) },
          receivables.worst_card_code.try { |code| "#{reverse("accounting:matching")}?#{URI::Params.encode({"q" => code})}" }, "gap")
      end
      invoicing_history_todo
      latest_entries
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Factures, avoirs et règlements de la Facturation sans écriture
    # (activation tardive de la Comptabilité, écriture impossible) : ADR-006
    # D2 veut que la Comptabilité *propose* de les comptabiliser.
    private def invoicing_history_todo : Nil
      return unless @actor.can?("accounting.entry.post")
      count = Acc.invoicing_history_count(@actor)
      return if count.zero?
      @todos << Todo.new(I18n.t("ui.dashboard.todo.invoicing_history", count: count), nil,
        reverse("accounting:invoicing_history"), "warn")
    end

    # TVA due du mois (maquette « TVA due · septembre ») : déclaration
    # périodique du régime (CA3, grille belge) calculée depuis les écritures,
    # sans l'enregistrer ; case 28 (TVA nette due) ou grille 71.
    private def vat_tile : Nil
      return unless @actor.can?(Acc::VAT_PERMISSION)
      form = Acc.vat_forms(@actor).find(&.form.in?("fr_ca3", "be_periodic"))
      return unless form
      from = Time.utc(@today.year, @today.month, 1)
      input = Acc::VatReturnInput.new(form: form.form, year: @today.year, periodicity: "month", number: @today.month,
        date_from: from, date_to: from.shift(months: 1) - 1.day)
      view = Acc.preview_vat_return(@actor, input).value?
      return unless view
      due = view.amount(form.regime == "be" ? "71" : "28")
      @tiles << Tile.new("ACCOUNTING", I18n.t("ui.dashboard.tiles.vat_due", month: @fmt.month(@today)), @fmt.amount(due),
        sub: I18n.t("ui.dashboard.tiles.vat_due_sub", form: I18n.t(view.name_key)), url: reverse("accounting:vat_return"))
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      nil
    end

    private def bank_tile : Nil
      ledgers = Acc.ledgers(@actor, Acc::LedgerKind::Financial).reject(&.access.none?)
      codes = ledgers.compact_map(&.bank_card_code).uniq!
      return if codes.empty?
      total = codes.sum(BigDecimal.new(0)) do |code|
        Acc.account_statement(@actor, Acc::StatementQuery.new(card: code)).balance
      rescue Partiduo::Api::NotFound
        BigDecimal.new(0)
      end
      @tiles << Tile.new("ACCOUNTING", I18n.t("ui.dashboard.tiles.cash"), @fmt.amount(total),
        sub: I18n.t("ui.dashboard.tiles.cash_sub", count: codes.size), url: codes.size == 1 ? accounts_url(codes.first) : nil)
    end

    private def latest_entries : Nil
      total = Acc.count_entries(@actor)
      return if total.zero?
      offset = Math.max(0_i64, total - 6).to_i
      rows = Acc.entries(@actor, Acc::EntryQuery.new(offset: offset, limit: 6)).reverse.map do |entry|
        Row.new([@fmt.date(entry.date), entry.ledger_code, entry.receipt || entry.internal_code, entry.label, @fmt.amount(entry.amount)],
          reverse("accounting:entry", id: entry.id))
      end
      @entries = rows.empty? ? nil : rows
    end

    # --- Facturation --------------------------------------------------------------

    # Une synthèse agrégée par le contrat (`Inv.summary`, D-2F-005) : aucune
    # vue de document n'est reconstruite, les chiffres ne dépendent d'aucun
    # plafond.
    private def invoicing : Nil
      summary = Inv.summary(@actor, @today)
      open_tile(summary) unless @active.includes?("ACCOUNTING")
      @tiles << Tile.new("INVOICING", I18n.t("ui.dashboard.tiles.billed", month: @fmt.month(@today)), @fmt.amount(summary.billed_net),
        sub: I18n.t("ui.dashboard.tiles.billed_sub", invoices: summary.billed_invoices, credits: summary.billed_credit_notes),
        url: "#{reverse("invoicing:documents")}?kind=invoice")
      @tiles << Tile.new("INVOICING", I18n.t("ui.dashboard.tiles.quotes"), @fmt.amount(summary.quotes_waiting_net),
        sub: I18n.t("ui.dashboard.tiles.quotes_sub", count: summary.quotes_waiting_count), url: "#{reverse("invoicing:documents")}?kind=quote&status=sent")
      recent_invoices(summary)
      invoicing_todos(summary)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Factures à encaisser (Facturation seule : la Comptabilité a sa tuile
    # « clients »).
    private def open_tile(summary : Inv::SummaryView) : Nil
      late_amount = summary.overdue_amount
      @tiles << Tile.new("INVOICING", I18n.t("ui.dashboard.tiles.invoices_open"), @fmt.amount(summary.open_amount),
        alert: late_amount.zero? ? nil : I18n.t("ui.dashboard.tiles.late", amount: @fmt.amount(late_amount)),
        url: "#{reverse("invoicing:documents")}?kind=invoice")
    end

    private def recent_invoices(summary : Inv::SummaryView) : Nil
      rows = summary.recent_invoices.map do |doc|
        Row.new([doc.number || I18n.t("ui.invoicing.draft"), doc.customer_name, @fmt.amount(doc.total_gross),
                 I18n.t("invoicing.statuses.#{doc.effective_status}")], reverse("invoicing:document", id: doc.id))
      end
      @invoices = rows.empty? ? nil : rows
    end

    private def invoicing_todos(summary : Inv::SummaryView) : Nil
      if @actor.can?("invoicing.reminder.send")
        proposed = Inv.reminders(@actor)
        if !proposed.empty?
          detail = proposed.first(3).map { |reminder| I18n.t("ui.dashboard.todo.late_detail", name: reminder.customer_name, days: reminder.days_late) }.join(" · ")
          @todos << Todo.new(I18n.t("ui.dashboard.todo.reminders", count: proposed.size), detail, reverse("invoicing:reminders"), "gap")
        elsif summary.overdue_count > 0
          @todos << Todo.new(I18n.t("ui.dashboard.todo.late_invoices", count: summary.overdue_count),
            summary.overdue_customers.join(" · "), reverse("invoicing:reminders"), "gap")
        end
      end
      rejection_todos
      monthly_todos
      if summary.drafts > 0 && (@actor.can?("invoicing.invoice.issue") || @actor.can?("invoicing.invoice.write"))
        @todos << Todo.new(I18n.t("ui.dashboard.todo.drafts", count: summary.drafts), nil,
          "#{reverse("invoicing:documents")}?status=draft", "warn")
      end
      if summary.quotes_expired > 0
        @todos << Todo.new(I18n.t("ui.dashboard.todo.expired_quotes", count: summary.quotes_expired), nil,
          "#{reverse("invoicing:documents")}?kind=quote&status=expired", "warn")
      end
    end

    # Paiements rejetés dont la facture reste due (D-INV3-012) : client,
    # facture, montant ; pour un client mensuel ou une facture payable en
    # fin de mois, encours HT et plafond du client.
    private def rejection_todos : Nil
      rejections = Inv.payment_rejections(@actor, open_only: true)
      return if rejections.empty?
      detail = rejections.first(3).map { |rejection| rejection_detail(rejection) }.join(" · ")
      url = rejections.size == 1 ? reverse("invoicing:document", id: rejections.first.document_id) : "#{reverse("invoicing:payments")}?view=received"
      @todos << Todo.new(I18n.t("ui.dashboard.todo.payment_rejections", count: rejections.size), detail, url, "gap")
    end

    private def rejection_detail(rejection : Inv::PaymentRejectionView) : String
      text = I18n.t("ui.dashboard.todo.rejection_detail", name: rejection.customer_name, number: rejection.document_number,
        amount: @fmt.amount(rejection.amount), currency: rejection.currency_code)
      return text unless rejection.end_of_month
      billing = Inv.customer_billing(@actor, rejection.customer_card_id)
      exposure = if limit = billing.credit_limit
                   I18n.t("ui.dashboard.todo.rejection_exposure_limit", exposure: @fmt.amount(billing.exposure),
                     limit: @fmt.amount(limit), currency: billing.currency_code)
                 else
                   I18n.t("ui.dashboard.todo.rejection_exposure", exposure: @fmt.amount(billing.exposure), currency: billing.currency_code)
                 end
      "#{text} (#{exposure})"
    end

    # Factures récapitulatives de fin de mois proposées (émettre et envoyer
    # d'un clic, « Bons à facturer ») et clients au-delà de 90 % de leur
    # encours maximum HT (D-INV2-007, D-INV2-009).
    private def monthly_todos : Nil
      proposals = Inv.monthly_proposals(@actor)
      unless proposals.empty?
        detail = proposals.first(3).map(&.customer_name).join(" · ")
        @todos << Todo.new(I18n.t("ui.dashboard.todo.monthly_invoices", count: proposals.size), detail,
          reverse("invoicing:to_invoice"), "primary")
      end
      alerts = Inv.credit_alerts(@actor)
      unless alerts.empty?
        detail = alerts.first(3).map do |view|
          I18n.t("ui.dashboard.todo.credit_detail", name: view.customer_name, percent: view.percent_used || 100)
        end.join(" · ")
        @todos << Todo.new(I18n.t("ui.dashboard.todo.credit_limits", count: alerts.size), detail,
          reverse("invoicing:to_invoice"), alerts.any?(&.exceeded?) ? "gap" : "warn")
      end
    end
  end
end
