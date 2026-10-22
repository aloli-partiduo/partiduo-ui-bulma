# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Bons à facturer (menu `invoicing:to_invoice`, DECISIONS D-INV2-010) :
  # bons de livraison émis et non facturés, filtrés par client et par
  # période ; « Facturer ces bons » (sélection : facture d'un bon ou facture
  # récapitulative) ; « Facturer le mois » (tous les clients mensuels, ou un
  # client) ; factures de fin de mois proposées, émises et envoyées d'un clic,
  # une par une ou toutes. Encours HT et plafond de chaque client listé. Tout
  # passe par `Api::Invoicing`.
  #
  # Retours de marchandises (D-INV3-012) : les bons de retour émis et non
  # repris y figurent aussi, nature écrite en toutes lettres, montants
  # négatifs, document d'origine ; cochés avec des bons de livraison, ils en
  # sont déduits (avoir récapitulatif si les retours l'emportent) ; « Faire
  # l'avoir des retours cochés » (`ReturnNotesCreditHandler`).
  class ToInvoiceHandler < InvoicingScreen
    # Ligne de la liste (gabarit `ui/invoicing/to_invoice.html`).
    class NoteRow
      include Marten::Template::Object::Auto

      getter id : Int64
      getter number : String
      getter url : String
      getter delivery_date : String
      getter customer : String
      getter customer_url : String?
      getter rhythm : String
      getter net : String
      getter gross : String
      getter exposure : String
      getter exposure_status : String?
      getter draft_url : String?
      getter checked : Bool # ameba:disable Naming/QueryBoolMethods
      getter kind_label : String
      getter returned : Bool # ameba:disable Naming/QueryBoolMethods
      getter origin : String?
      getter origin_url : String?

      def initialize(@id, @number, @url, @delivery_date, @customer, @customer_url, @rhythm, @net, @gross, @exposure,
                     @exposure_status, @draft_url, @checked, @kind_label, @returned, @origin, @origin_url)
      end

      def selectable : Bool
        draft_url.nil?
      end
    end

    # Facture de fin de mois proposée.
    class ProposalRow
      include Marten::Template::Object::Auto

      getter customer : String
      getter number : String
      getter url : String
      getter month : String
      getter gross : String
      getter error : String?
      getter send_url : String
      getter kind_label : String

      def initialize(@customer, @number, @url, @month, @gross, @error, @send_url, @kind_label)
      end
    end

    def get
      require!(MODULE, READ)
      show
    end

    # « Facturer ces bons » : brouillon de facture des bons cochés ; avoir
    # récapitulatif quand les retours cochés l'emportent (D-INV3-004).
    def post
      require!(MODULE, WRITE)
      ids = note_ids
      result = Inv.invoice_delivery_notes(current.actor, ids)
      if document = result.value?
        key = document.kind == "credit_note" ? "ui.invoicing.to_invoice.created_credit" : "ui.invoicing.to_invoice.created"
        flash["success"] = I18n.t(key, count: ids.size)
        return go(reverse("invoicing:document", id: document.id))
      end
      show(ids, result.errors.map { |error| fmt.message(error) }, 422)
    end

    # Bons cochés (champs `note`, ou paramètre `note` de l'adresse).
    private def note_ids : Array(Int64)
      values = request.data.fetch_all("note", [] of String) || [] of String
      values += request.query_params.fetch_all("note", [] of String) || [] of String
      field("notes").split(',').each { |text| values << text }
      values.compact_map(&.to_s.strip.to_i64?).uniq!
    end

    private def show(checked = [] of Int64, refused : Array(String)? = nil, status : Int32 = 200) : Marten::HTTP::Response
      actor = current.actor
      customer = query("customer").to_i64?
      from = fmt.parse_short_date(query("from"), Partiduo::Api::Core.today)
      upto = fmt.parse_short_date(query("to"), Partiduo::Api::Core.today)
      all = Inv.delivery_notes_to_invoice(actor)
      notes = Inv.delivery_notes_to_invoice(actor, Inv::ToInvoiceQuery.new(customer_card_id: customer, from: from, to: upto))
      billing = notes.map(&.customer_card_id).uniq!.to_h { |id| {id, Inv.customer_billing(actor, id)} }
      context["title"] = I18n.t("invoicing.menu.inv_to_invoice")
      context["crumbs"] = [crumb("core.menu.billing"), crumb("invoicing.menu.inv_to_invoice", reverse("invoicing:to_invoice"))]
      context["actions"] = [link_action("ui.invoicing.to_invoice.all_returns", "#{reverse("invoicing:documents")}?kind=return_note",
        icon: "file-text")]
      context["customers"] = customer_options(all, customer)
      context["from"] = query("from")
      context["to"] = query("to")
      context["refused"] = refused
      context["rows"] = listed(notes.map { |note| note_row(note, billing[note.customer_card_id], checked) })
      context["can_write"] = can?(WRITE)
      context["month"] = Partiduo::Api::Core.today.to_s("%Y-%m")
      context["customer_id"] = customer.try(&.to_s) || ""
      context["customer_filtered"] = !customer.nil?
      context["proposals"] = listed(proposals)
      context["can_issue"] = can?("invoicing.invoice.issue")
      context["total_net"] = fmt.amount(notes.sum(BigDecimal.new(0), &.total_net))
      context["total_gross"] = fmt.amount(notes.sum(BigDecimal.new(0), &.total_gross))
      context["has_returns"] = notes.any?(&.return_note?)
      page("ui/invoicing/to_invoice.html", status: status)
    end

    private def customer_options(all : Array(Inv::ToInvoiceView), selected : Int64?) : Array(Form::Option)
      customers = all.map { |note| {note.customer_card_id, note.customer_name} }.uniq!.sort_by!(&.[1])
      [Form::Option.new("", I18n.t("ui.invoicing.to_invoice.all_customers"), selected.nil?)] +
        customers.map { |(id, name)| Form::Option.new(id.to_s, name, id == selected) }
    end

    private def note_row(note : Inv::ToInvoiceView, billing : Inv::CustomerBillingView, checked : Array(Int64)) : NoteRow
      NoteRow.new(note.id, note.number, reverse("invoicing:document", id: note.id), fmt.date(note.delivery_date),
        note.customer_name, reverse("cards:show", id: note.customer_card_id),
        I18n.t("invoicing.billing_rhythms.#{note.billing_rhythm}"), fmt.amount(note.total_net), fmt.amount(note.total_gross),
        CustomerBillingDisplay.exposure_text(billing, fmt), CustomerBillingDisplay.status_text(billing),
        note.draft_invoice_id.try { |id| reverse("invoicing:document", id: id) }, checked.includes?(note.id),
        kind_label(note.kind), note.return_note?,
        note.origin.try { |link| I18n.t("ui.invoicing.to_invoice.origin", kind: kind_label(link.kind), number: link.number || I18n.t("ui.invoicing.draft")) },
        note.origin.try { |link| reverse("invoicing:document", id: link.id) })
    end

    private def proposals : Array(ProposalRow)
      Inv.monthly_proposals(current.actor).compact_map do |proposal|
        invoice_id = proposal.invoice_id || next
        error = proposal.error.presence.try do |keys|
          keys.split(", ").map { |key| key.includes?('.') ? I18n.t(key, default: key) : key }.join(" ")
        end
        ProposalRow.new(proposal.customer_name, I18n.t("ui.invoicing.draft"), reverse("invoicing:document", id: invoice_id),
          fmt.month(proposal.month), "#{fmt.amount(proposal.total_gross)} #{proposal.currency_code}", error,
          reverse("invoicing:document_issue_send", id: invoice_id), kind_label(proposal.invoice_kind))
      end
    end
  end

  # « Faire l'avoir » d'un ou de plusieurs bons de retour (D-INV3-012) :
  # depuis la fiche d'un bon (`?note=…&from=document`) ou les retours cochés
  # des « Bons à facturer ». Brouillon d'avoir sur la facture d'origine ;
  # sans facture à créditer (`return_notes.no_invoice_to_credit`), choix de
  # la facture parmi les factures émises du client (`credited_document_id`).
  class ReturnNotesCreditHandler < ToInvoiceHandler
    NO_INVOICE = "return_notes.no_invoice_to_credit"

    def get
      go(reverse("invoicing:to_invoice"))
    end

    def post
      require!(MODULE, WRITE)
      ids = note_ids
      from_document = field("from") == "document" || query("from") == "document"
      credited = field("credited_document_id").to_i64?
      result = Inv.credit_return_notes(current.actor, ids, credited)
      if document = result.value?
        flash["success"] = I18n.t("ui.invoicing.credit_returns.created", count: ids.size)
        return go(reverse("invoicing:document", id: document.id))
      end
      if !ids.empty? && (credited || result.errors.any?(&.key.ends_with?(NO_INVOICE)))
        return choose(ids, result.errors, from_document)
      end
      messages = result.errors.map { |error| fmt.message(error) }
      if from_document && ids.size == 1
        flash["danger"] = messages.join(" ")
        return go(reverse("invoicing:document", id: ids.first))
      end
      show(ids, messages, 422)
    end

    # Choix de la facture à créditer : factures émises, non annulées, du
    # client des bons, de la plus récente à la plus ancienne.
    private def choose(ids : Array(Int64), errors : Array(Partiduo::Api::FieldError), from_document : Bool) : Marten::HTTP::Response
      notes = ids.map { |id| Inv.document(current.actor, id) }
      customer = notes.first.customer_card_id
      invoices = Inv.documents(current.actor, Inv::DocumentQuery.new(kind: "invoice", customer_card_id: customer, limit: 500))
        .reject { |doc| doc.draft? || doc.effective_status == "cancelled" }
        .sort_by! { |doc| {doc.issue_date || doc.created_at, doc.id} }.reverse!
      numbers = notes.map { |note| note.number || I18n.t("ui.invoicing.draft") }.join(", ")
      back = from_document && ids.size == 1 ? reverse("invoicing:document", id: ids.first) : reverse("invoicing:to_invoice")
      form = nil
      unless invoices.empty?
        options = invoices.map do |doc|
          option(doc.id.to_s, I18n.t("ui.invoicing.credit_returns.invoice_option", number: doc.number.to_s,
            date: fmt.date(doc.issue_date), gross: fmt.amount(doc.totals.total_gross), currency: doc.currency_code))
        end
        selected = field("credited_document_id").presence || invoices.first.id.to_s
        form = Form.new([Form::Group.new(nil, [
          Form::Field.new("notes", "", "hidden", ids.join(",")),
          Form::Field.new("from", "", "hidden", from_document ? "document" : ""),
          Form::Field.new("credited_document_id", I18n.t("ui.invoicing.credit_returns.invoice"), "select", selected,
            options: options, required: true, help: I18n.t("ui.invoicing.credit_returns.invoice_help")),
        ])])
        form.add_errors(errors.reject(&.key.ends_with?(NO_INVOICE)), fmt)
      end
      intro = invoices.empty? ? I18n.t("ui.invoicing.credit_returns.no_invoice") : I18n.t("ui.invoicing.credit_returns.intro")
      form_page(I18n.t("ui.invoicing.credit_returns.title", numbers: numbers, customer: notes.first.customer.name),
        [crumb("core.menu.billing"), crumb("invoicing.menu.inv_to_invoice", reverse("invoicing:to_invoice"))], form,
        reverse("invoicing:credit_returns"), I18n.t("ui.invoicing.credit_return"), back, intro: intro, status: 422)
    end
  end

  # « Facturer le mois » : factures récapitulatives du mois (champ `month`,
  # `AAAA-MM`, défaut : mois en cours) pour tous les clients mensuels, ou
  # pour le client `customer` (champ, ou paramètre de l'action de la fiche
  # client, qui y revient).
  class MonthPrepareHandler < InvoicingScreen
    def post
      require!(MODULE, WRITE)
      today = Partiduo::Api::Core.today
      month = begin
        Time.parse_utc("#{field("month")}-01", "%Y-%m-%d")
      rescue Time::Format::Error | ArgumentError
        today
      end
      from_card = query("customer").to_i64?
      customer = field("customer").to_i64? || from_card
      run = Inv.prepare_monthly_invoices(current.actor, Inv::MonthlyInput.new(month: month, customer_card_id: customer))
      failed = run.prepared.count(&.status.==("failed"))
      prepared = run.prepared.size - failed
      flash["success"] = I18n.t("ui.invoicing.to_invoice.month_prepared", count: prepared, month: fmt.month(month))
      flash["warning"] = I18n.t("ui.invoicing.to_invoice.month_failed", count: failed) if failed > 0
      go(from_card ? reverse("cards:show", id: from_card) : reverse("invoicing:to_invoice"))
    end
  end

  # Émettre et envoyer d'un clic une facture (proposée ou brouillon), selon
  # son canal : message de la suite donnée.
  class DocumentIssueSendHandler < InvoicingScreen
    def post
      result = Inv.issue_and_send(current.actor, id_param)
      if outcome = result.value?
        message = I18n.t("invoicing.dispatch.#{outcome.action}", to: outcome.detail)
        flash[outcome.action.in?("email_missing", "email_failed", "send_denied") ? "warning" : "success"] =
          "#{document_title(outcome.document)} : #{message}"
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(reverse("invoicing:to_invoice"))
    end
  end

  # Émettre et envoyer toutes les factures de fin de mois proposées.
  class ProposalsIssueSendHandler < InvoicingScreen
    def post
      results = Inv.issue_and_send_proposals(current.actor)
      done = results.count(&.success?)
      flash["success"] = I18n.t("ui.invoicing.to_invoice.all_sent", count: done)
      refused = results.select(&.failure?).flat_map(&.errors).map { |error| fmt.message(error) }.uniq!
      flash["danger"] = refused.join(" ") unless refused.empty?
      go(reverse("invoicing:to_invoice"))
    end
  end

  # Réglage client de la Facturation : rythme de facturation et encours
  # maximum HT (DECISIONS D-INV2-004, D-INV2-005).
  class CustomerBillingHandler < InvoicingScreen
    PERMISSION = "invoicing.settings.manage"

    def get
      require!(MODULE, PERMISSION)
      view = Inv.customer_billing(current.actor, id_param)
      show(view, billing_form(view.billing_rhythm, view.credit_limit.try { |limit| fmt.input_number(limit) } || ""))
    end

    def post
      require!(MODULE, PERMISSION)
      view = Inv.customer_billing(current.actor, id_param)
      errors = [] of {String, String}
      limit = decimal("credit_limit", errors)
      form = billing_form(field("billing_rhythm"), field("credit_limit"))
      if errors.empty?
        result = Inv.update_customer_billing(current.actor, view.customer_card_id,
          Inv::CustomerBillingInput.new(field("billing_rhythm"), limit))
        if result.success?
          flash["success"] = I18n.t("ui.invoicing.customer_billing.saved", name: view.customer_name)
          return go(reverse("cards:show", id: view.customer_card_id))
        end
        form.add_errors(result.errors, fmt)
      end
      errors.each { |(name, message)| form.add_error(name, message) }
      show(view, form)
    end

    private def billing_form(rhythm : String, limit : String) : Form
      rhythms = Inv::BILLING_RHYTHMS.map { |code| option(code, I18n.t("invoicing.billing_rhythms.#{code}")) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("billing_rhythm", I18n.t("ui.invoicing.customer_billing.rhythm"), "select", rhythm, options: rhythms,
          help: I18n.t("ui.invoicing.customer_billing.rhythm_help")),
        Form::Field.new("credit_limit", I18n.t("ui.invoicing.customer_billing.credit_limit"), "number", limit, mono: true,
          help: I18n.t("ui.invoicing.customer_billing.credit_limit_help")),
      ])])
    end

    private def show(view : Inv::CustomerBillingView, form : Form) : Marten::HTTP::Response
      card_url = reverse("cards:show", id: view.customer_card_id)
      form_page(I18n.t("ui.invoicing.customer_billing.title", name: view.customer_name),
        [crumb("core.menu.reference"), Screen::Crumb.new(view.customer_name, card_url)], form,
        reverse("invoicing:customer_billing", id: view.customer_card_id), I18n.t("ui.forms.save"), card_url,
        intro: I18n.t("ui.invoicing.customer_billing.intro"))
    end
  end

  # Rubrique « Facturation » de la fiche d'un client : rythme, encours HT et
  # plafond (jauge), bons non facturés, retours à reprendre (D-INV3-012) ;
  # actions selon les droits.
  module CustomerBillingDisplay
    alias Inv = Partiduo::Api::Invoicing

    # « 1 234,00 / 5 000,00 EUR » (plafond) ou « 1 234,00 EUR ».
    def self.exposure_text(view : Inv::CustomerBillingView, fmt : Format) : String
      if limit = view.credit_limit
        "#{fmt.amount(view.exposure)} / #{fmt.amount(limit)} #{view.currency_code}"
      else
        "#{fmt.amount(view.exposure)} #{view.currency_code}"
      end
    end

    # État en toutes lettres (jamais la seule couleur) : dépassé, proche.
    def self.status_text(view : Inv::CustomerBillingView) : String?
      if view.exceeded?
        I18n.t("ui.invoicing.customer_billing.exceeded")
      elsif view.near_limit?
        I18n.t("ui.invoicing.customer_billing.near_limit", percent: view.percent_used || 0)
      end
    end

    def self.gauge(view : Inv::CustomerBillingView, fmt : Format) : Screen::Gauge?
      limit = view.credit_limit || return
      percent = view.percent_used || (view.exposure > 0 ? 100 : 0)
      tone = view.exceeded? ? "gap" : (view.near_limit? ? "warn" : "ok")
      status = status_text(view) || I18n.t("ui.invoicing.customer_billing.within_limit")
      detail = I18n.t("ui.invoicing.customer_billing.gauge_detail", exposure: fmt.amount(view.exposure),
        limit: fmt.amount(limit), currency: view.currency_code)
      Screen::Gauge.new(I18n.t("ui.invoicing.customer_billing.exposure"), detail, status, fmt.percent(BigDecimal.new(percent)),
        percent.clamp(0, 100), tone)
    end

    def self.section(handler : ReferenceHandler, card : Partiduo::Api::Cards::CardView, fmt : Format) : Screen::Section
      view = Inv.customer_billing(handler.current.actor, card.id)
      items = [
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.rhythm"), I18n.t("invoicing.billing_rhythms.#{view.billing_rhythm}")),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.credit_limit"),
          view.credit_limit.try { |limit| "#{fmt.amount(limit)} #{view.currency_code}" } || I18n.t("ui.invoicing.customer_billing.no_limit"), mono: true),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.exposure"), "#{fmt.amount(view.exposure)} #{view.currency_code}", mono: true),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.unbilled"),
          I18n.t("ui.invoicing.customer_billing.unbilled_value", count: view.unbilled_count, net: fmt.amount(view.unbilled_net),
            gross: fmt.amount(view.unbilled_gross), currency: view.currency_code),
          "#{handler.reverse("invoicing:to_invoice")}?customer=#{card.id}"),
        # Bons de retour émis non repris, déduits de l'encours (D-INV3-006).
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.returns"),
          I18n.t("ui.invoicing.customer_billing.returns_value", count: view.returns_count, net: fmt.amount(view.returns_net),
            currency: view.currency_code),
          "#{handler.reverse("invoicing:to_invoice")}?customer=#{card.id}"),
        Screen::Item.new(I18n.t("ui.invoicing.customer_billing.receivable"), "#{fmt.amount(view.receivable_net)} #{view.currency_code}", mono: true),
      ]
      if view.unconverted > 0
        items << Screen::Item.new(I18n.t("ui.invoicing.customer_billing.unconverted_label"),
          I18n.t("ui.invoicing.customer_billing.unconverted", count: view.unconverted))
      end
      actions = [] of Screen::Action
      if handler.can?("invoicing.settings.manage")
        actions << Screen::Action.new(I18n.t("ui.forms.edit"), handler.reverse("invoicing:customer_billing", id: card.id), style: "small")
      end
      if handler.can?("invoicing.invoice.write") && view.unbilled_count > 0
        actions << Screen::Action.new(I18n.t("ui.invoicing.to_invoice.month_customer"),
          "#{handler.reverse("invoicing:month_prepare")}?customer=#{card.id}", "post", "small")
      end
      section = Screen::Section.new(I18n.t("ui.invoicing.customer_billing.section"), items, actions: actions)
      section.gauge = gauge(view, fmt)
      section
    end
  end
end
