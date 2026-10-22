# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Devis et factures (module Facturation, ADR-006 D4 à D6 ; maquette
  # « Devis et factures », « Édition », « Aperçu ») : liste, édition d'un
  # brouillon avec totaux instantanés (`check_document`), consultation,
  # aperçu, validation (émission), transformation, avoir, règlement,
  # téléchargement du PDF Factur-X. Tout passe par `Api::Invoicing`.
  abstract class InvoicingScreen < ReferenceHandler
    alias Inv = Partiduo::Api::Invoicing

    MODULE = "INVOICING"
    READ   = "invoicing.invoice.read"
    WRITE  = "invoicing.invoice.write"

    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.billing"), crumb("invoicing.menu.inv_documents", reverse("invoicing:documents"))]
    end

    def kind_label(kind : String) : String
      I18n.t("invoicing.kinds.#{kind}")
    end

    def status_label(status : String) : String
      I18n.t("invoicing.statuses.#{status}")
    end

    # État d'un document lié : un bon de retour repris se dit « Repris »
    # (`DocumentView#status_key`).
    def link_status_label(link : Inv::LinkView) : String
      return I18n.t("invoicing.statuses.returned") if link.kind == "return_note" && link.status == "invoiced"
      status_label(link.status)
    end

    def document_title(document : Inv::DocumentView) : String
      number = document.number || I18n.t("ui.invoicing.draft")
      "#{kind_label(document.kind)} #{number}"
    end

    def document_url(document : Inv::DocumentView) : String
      reverse("invoicing:document", id: document.id)
    end

    def money(value : BigDecimal, currency : String = "") : String
      currency.empty? ? fmt.amount(value) : "#{fmt.amount(value)} #{currency}"
    end

    def form_values : Hash(String, String)
      request.data.to_h { |(name, values)| {name, values.last?.to_s} }
    end

    def vat_rates : Array(Partiduo::Api::Vat::RateView)
      @vat_rates ||= Partiduo::Api::Vat.rates(current.actor)
    end

    @vat_rates : Array(Partiduo::Api::Vat::RateView)?

    def decorate(form : DocumentForm) : DocumentForm
      form.category_options = Inv::OPERATION_CATEGORIES.map do |code|
        Form::Option.new(code, I18n.t("ui.invoicing.categories.#{code}"), code == form.operation_category)
      end
      decorate_channel(form) if form.fiscal
      form.terms_options = terms_options(form.payment_terms) if form.payable
      form.delivery_options = delivery_options(form.customer, form.delivery)
      form.reason_options = reason_options(form.return_reason) if form.returning
      form.each_row do |line|
        line.vat_options = [Form::Option.new("", I18n.t("ui.invoicing.vat_default"), line.vat_rate_id.empty?)] +
                           vat_rates.map { |rate| Form::Option.new(rate.id.to_s, "#{rate.code} · #{fmt.percent(rate.rate)}", rate.id.to_s == line.vat_rate_id) }
      end
      form
    end

    # Motifs d'un bon de retour (D-INV3-012) : choix vide tant qu'il n'est
    # pas donné (obligatoire à l'émission).
    def reason_options(value : String) : Array(Form::Option)
      [Form::Option.new("", I18n.t("ui.invoicing.return_reason_choose"), value.empty?)] +
        Inv::RETURN_REASONS.map { |code| Form::Option.new(code, I18n.t("invoicing.return_reasons.#{code}"), code == value) }
    end

    # Conditions de paiement proposées (maquette : 30 jours, 45 jours fin de
    # mois, à réception), plus celles du document si elles n'y sont pas.
    TERMS_PRESETS = %w[on_receipt net:15 net:30 net:45 net:60 end_of_month:30 end_of_month:45]

    def terms_options(value : String) : Array(Form::Option)
      default_days = Inv.settings(current.actor).payment_terms_days
      values = TERMS_PRESETS.dup
      values << value unless value.empty? || values.includes?(value)
      [Form::Option.new("", I18n.t("ui.invoicing.terms.default", days: default_days), value.empty?)] +
        values.map { |code| Form::Option.new(code, terms_label(code), code == value) }
    end

    def terms_label(code : String) : String
      terms, _, days = code.partition(':')
      terms == "on_receipt" ? I18n.t("ui.invoicing.terms.on_receipt") : I18n.t("ui.invoicing.terms.#{terms}", days: days, default: code)
    end

    # Adresses de livraison proposées : celle de la fiche par défaut, aucune,
    # chacune des adresses de livraison de la fiche, une autre saisie.
    def delivery_options(customer : String, value : String) : Array(Form::Option)
      options = [Form::Option.new("", I18n.t("ui.invoicing.delivery.default"), value.empty?),
                 Form::Option.new("none", I18n.t("ui.invoicing.delivery.none"), value == "none")]
      customer_card(customer).try(&.delivery_addresses.each_with_index do |address, index|
        options << Form::Option.new("card:#{index}", delivery_text(address), value == "card:#{index}")
      end)
      options << Form::Option.new("other", I18n.t("ui.invoicing.delivery.other"), value == "other")
    end

    def delivery_text(address : Partiduo::Api::Cards::AddressView) : String
      locality = [address.postcode, address.city].reject(&.empty?).join(" ")
      [address.label, address.line1, address.line2, locality, address.country_code].reject(&.empty?).join(", ")
    end

    def customer_card(code : String) : Partiduo::Api::Cards::CardView?
      return if code.empty?
      Partiduo::Api::Cards.card_by_code(current.actor, code)
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Canal d'émission et marquage B2C (ADR-004 D9) : choix vide = proposition
    # du cœur selon le client, rappelée sous le champ.
    def decorate_channel(form : DocumentForm) : Nil
      form.channel_options = [Form::Option.new("", I18n.t("ui.invoicing.channel_proposed"), form.issue_channel.empty?)] +
                             Inv::ISSUE_CHANNELS.map { |code| Form::Option.new(code, I18n.t("invoicing.channels.#{code}"), code == form.issue_channel) }
      form.b2c_options = [
        Form::Option.new("", I18n.t("ui.invoicing.b2c_proposed"), form.b2c.empty?),
        Form::Option.new("1", I18n.t("ui.forms.answer_yes"), form.b2c == "1"),
        Form::Option.new("0", I18n.t("ui.forms.answer_no"), form.b2c == "0"),
      ]
      form.channel_hint = channel_hint(form.customer)
    end

    # « Proposé : Plateforme agréée · B2C — raison » pour un client connu.
    def channel_hint(code : String) : String?
      customer = card_id(code)
      return unless customer
      proposal = Inv.propose_channel(current.actor, customer)
      label = I18n.t("invoicing.channels.#{proposal.channel}")
      label = "#{label} · B2C" if proposal.b2c
      I18n.t("ui.invoicing.channel_hint", channel: label, reason: I18n.t(proposal.reason_key))
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      nil
    end

    # --- Lecture de la saisie ----------------------------------------------------

    def card_id(code : String) : Int64?
      return if code.empty?
      Partiduo::Api::Cards.card_by_code(current.actor, code).try(&.id)
    end

    def parse_number(text : String, line : DocumentForm::Line) : BigDecimal?
      return if text.empty?
      value = fmt.parse_decimal(text)
      line.add_error(I18n.t("ui.forms.invalid_number")) unless value
      value
    end

    def parse_day(form : DocumentForm, name : String, text : String) : Time?
      return if text.empty?
      value = fmt.parse_short_date(text, Partiduo::Api::Core.today)
      form.add_error(name, I18n.t("ui.forms.invalid_date")) unless value
      value
    end

    def line_inputs(form : DocumentForm) : Array(Inv::LineInput)
      form.filled_lines.map { |line| layout_input(line) || priced_input(line) }
    end

    # Ligne de titre ou de sous-total (D-UI-055) ; `nil` pour une autre.
    private def layout_input(line : DocumentForm::Line) : Inv::LineInput?
      return unless line.title || line.subtotal
      Inv::LineInput.new(kind: line.layout, description: line.title ? line.description.presence : nil,
        delivery_note_id: line.delivery_note.to_i64?, return_note_id: line.return_note.to_i64?)
    end

    private def priced_input(line : DocumentForm::Line) : Inv::LineInput
      item_id = nil
      unless line.item.empty?
        item_id = card_id(line.item)
        line.add_error(I18n.t("ui.invoicing.unknown_item", code: line.item)) unless item_id
      end
      quantity = parse_number(line.quantity, line)
      price = parse_number(line.unit_price, line)
      discount = parse_number(line.discount, line)
      kind = if item_id
               "item"
             elsif price || quantity
               "free"
             else
               "note"
             end
      Inv::LineInput.new(kind: kind, item_card_id: item_id, description: line.description.presence,
        quantity: quantity || BigDecimal.new(1), unit_code: line.unit.presence, unit_price: price,
        discount_kind: discount && !discount.zero? ? "percent" : "none", discount_value: discount || BigDecimal.new(0),
        vat_rate_id: line.vat_rate_id.to_i64?, delivery_note_id: line.delivery_note.to_i64?,
        return_note_id: line.return_note.to_i64?)
    end

    # Document saisi ; `existing` : brouillon modifié (liens d'avoir et
    # acomptes conservés). `nil` si un champ est illisible.
    def document_input(form : DocumentForm, existing : Inv::DocumentView? = nil) : Inv::DocumentInput?
      customer = customer_of(form)
      dates = dates_of(form)
      discount = discount_of(form)
      terms = terms_of(form)
      delivery = delivery_of(form)
      lines = line_inputs(form)
      return if form.invalid || customer.nil?
      Inv::DocumentInput.new(
        kind: form.kind, customer_card_id: customer, lines: lines,
        issue_date: dates["issue_date"], delivery_date: dates["delivery_date"], due_date: dates["due_date"],
        validity_date: dates["validity_date"], operation_category: form.operation_category.presence,
        buyer_reference: form.buyer_reference.presence, order_reference: form.order_reference.presence,
        notes: form.notes.presence,
        global_discount_kind: discount ? "percent" : "none", global_discount_value: discount || BigDecimal.new(0),
        currency_code: existing.try(&.currency_code), locale: existing.try(&.locale), layout_id: existing.try(&.layout_id),
        deposit_ids: existing.try(&.deductions.map(&.deposit_id)) || [] of Int64,
        credited_document_id: existing.try(&.credited.try(&.id)),
        issue_channel: form.fiscal ? form.issue_channel.presence : nil,
        b2c: form.fiscal ? {"1" => true, "0" => false}[form.b2c]? : nil,
        delivery_address: delivery, payment_terms: terms.try(&.[0]), payment_terms_days: terms.try(&.[1]),
        return_reason: form.returning ? form.return_reason.presence : nil,
      )
    end

    # Conditions saisies : `{conditions, jours}` ; `nil` sans condition.
    private def terms_of(form : DocumentForm) : {String, Int32?}?
      return if form.payment_terms.empty? || !form.payable
      terms, separator, days = form.payment_terms.partition(':')
      count = days.to_i?
      if !Inv::PAYMENT_TERMS.includes?(terms) || (separator.empty? != (terms == "on_receipt")) || (!separator.empty? && count.nil?)
        form.add_error("payment_terms", I18n.t("ui.invoicing.terms.invalid"))
        return
      end
      {terms, count}
    end

    # Adresse de livraison choisie : `nil` (celle de la fiche par défaut),
    # adresse vide (aucune), adresse de la fiche ou autre adresse saisie.
    private def delivery_of(form : DocumentForm) : Partiduo::Api::Cards::AddressInput?
      case choice = form.delivery
      when "none"
        Partiduo::Api::Cards::AddressInput.new
      when "other"
        if form.delivery_line1.empty? || form.delivery_city.empty?
          form.add_error("delivery", I18n.t("ui.invoicing.delivery.incomplete"))
          return
        end
        Partiduo::Api::Cards::AddressInput.new(line1: form.delivery_line1, postcode: form.delivery_postcode,
          city: form.delivery_city, country_code: form.delivery_country.upcase.presence)
      when .starts_with?("card:")
        customer_card(form.customer).try(&.delivery_addresses[choice.lchop("card:").to_i? || -1]?.try(&.to_input))
      end
    end

    private def customer_of(form : DocumentForm) : Int64?
      customer = card_id(form.customer)
      if form.customer.empty?
        form.add_error("customer", I18n.t("ui.forms.required"))
      elsif customer.nil?
        form.add_error("customer", I18n.t("ui.invoicing.unknown_customer", code: form.customer))
      end
      customer
    end

    private def dates_of(form : DocumentForm) : Hash(String, Time?)
      {
        "issue_date"    => parse_day(form, "issue_date", form.issue_date),
        "delivery_date" => parse_day(form, "delivery_date", form.delivery_date),
        "due_date"      => parse_day(form, "due_date", form.due_date),
        "validity_date" => parse_day(form, "validity_date", form.validity_date),
      }
    end

    # Remise globale en pourcentage ; `nil` si absente ou nulle.
    private def discount_of(form : DocumentForm) : BigDecimal?
      return if form.global_discount.empty?
      discount = fmt.parse_decimal(form.global_discount)
      form.add_error("global_discount", I18n.t("ui.forms.invalid_number")) unless discount
      discount.try { |value| value.zero? ? nil : value }
    end

    def add_errors(form : DocumentForm, errors : Array(Partiduo::Api::FieldError)) : Nil
      errors.each { |error| form.add_error(error.field, fmt.message(error)) }
    end

    # Formulaire d'un brouillon existant.
    def form_of(document : Inv::DocumentView) : DocumentForm
      form = DocumentForm.new(document.kind)
      form.customer = document.customer.code.presence || card_code(document.customer_card_id)
      form.customer_name = document.customer.name
      form.issue_date = fmt.date(document.issue_date)
      form.delivery_date = fmt.date(document.delivery_date)
      form.due_date = fmt.date(document.due_date)
      form.validity_date = fmt.date(document.validity_date)
      form.operation_category = document.operation_category
      form.buyer_reference = document.buyer_reference
      form.order_reference = document.order_reference
      form.notes = document.notes
      form.global_discount = document.global_discount_kind == "percent" ? fmt.input_number(document.global_discount_value) : ""
      if document.fiscal?
        form.issue_channel = document.issue_channel
        form.b2c = document.b2c ? "1" : "0"
      end
      form.payment_terms = terms_value(document)
      form.return_reason = document.return_reason
      delivery_form(form, document)
      document.lines.each_with_index { |line, index| form.lines << form_line(line, index) }
      form.add_line if form.lines.empty?
      form
    end

    private def terms_value(document : Inv::DocumentView) : String
      case document.payment_terms
      when ""           then ""
      when "on_receipt" then "on_receipt"
      else                   "#{document.payment_terms}:#{document.payment_terms_days || Inv.settings(current.actor).payment_terms_days}"
      end
    end

    # Adresse enregistrée : aucune, l'une de celles de la fiche, ou autre.
    private def delivery_form(form : DocumentForm, document : Inv::DocumentView) : Nil
      address = document.delivery_address
      return form.delivery = "none" unless address
      card = Partiduo::Api::Cards.card(current.actor, document.customer_card_id)
      index = card.delivery_addresses.index do |item|
        {item.line1, item.line2, item.postcode, item.city, item.country_code} ==
          {address.line1, address.line2, address.postcode, address.city, address.country_code}
      end
      if index
        form.delivery = "card:#{index}"
      else
        form.delivery = "other"
        form.delivery_line1 = address.line1
        form.delivery_postcode = address.postcode
        form.delivery_city = address.city
        form.delivery_country = address.country_code
      end
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      form.delivery = "other"
    end

    private def form_line(line : Inv::LineView, index : Int32) : DocumentForm::Line
      if line.kind.in?("title", "subtotal")
        layout = DocumentForm::Line.new(index, description: line.kind == "title" ? line.description : "")
        layout.layout = line.kind
        layout.total = line.kind == "subtotal" ? fmt.amount(line.net_amount) : ""
        return cite(layout, line)
      end
      item = line.item_card_id.try { |id| card_code(id) } || ""
      priced = line.priced?
      DocumentForm::Line.new(index, item, line.description,
        priced ? fmt.input_number(line.quantity) : "", priced ? line.unit_code : "",
        priced ? fmt.input_number(line.unit_price) : "",
        line.discount_kind == "percent" ? fmt.input_number(line.discount_value) : "",
        line.vat_rate_id.try(&.to_s) || "").tap do |copy|
        copy.total = priced ? fmt.amount(line.net_amount) : ""
        cite(copy, line)
      end
    end

    # Bon de livraison et bon de retour cités par une ligne (champs cachés),
    # vides sinon.
    private def cite(form_line : DocumentForm::Line, line : Inv::LineView) : DocumentForm::Line
      form_line.delivery_note = line.delivery_note_id.try(&.to_s) || ""
      form_line.return_note = line.return_note_id.try(&.to_s) || ""
      form_line
    end

    def card_code(id : Int64) : String
      Partiduo::Api::Cards.card(current.actor, id).code
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      ""
    end

    def edit_page(form : DocumentForm, action : String, title : String, document : Inv::DocumentView? = nil,
                  status : Int32 = 200) : Marten::HTTP::Response
      context["title"] = title
      context["crumbs"] = crumbs
      context["form"] = decorate(form)
      context["form_action"] = action
      context["document"] = document.try { |view| DocumentDisplay.new(view, fmt, self) }
      context["check_url"] = reverse("invoicing:document_check")
      context["document_id"] = document.try(&.id.to_s) || ""
      context["totals"] = nil
      context["express_url"] = can?("cards.card.write") ? reverse("invoicing:express_customer") : nil
      page("ui/invoicing/edit.html", status: status)
    end
  end

  # Présentation d'un document pour les gabarits (montants formatés, liens).
  class DocumentDisplay
    include Marten::Template::Object::Auto

    class Row
      include Marten::Template::Object::Auto

      getter kind : String
      getter description : String
      getter quantity : String
      getter unit : String
      getter unit_price : String
      getter discount : String
      getter vat : String
      getter total : String

      def initialize(@kind, @description, @quantity, @unit, @unit_price, @discount, @vat, @total)
      end

      def priced : Bool
        kind.in?("item", "free")
      end

      def heading : Bool
        kind.in?("title", "subtotal")
      end
    end

    class Link
      include Marten::Template::Object::Auto

      getter label : String
      getter url : String

      def initialize(@label, @url)
      end
    end

    class Amount
      include Marten::Template::Object::Auto

      getter label : String
      getter value : String
      getter grand : Bool

      def initialize(@label, @value, @grand = false)
      end
    end

    getter id : Int64
    getter title : String
    getter kind : String
    getter kind_label : String
    getter number : String
    getter draft : Bool
    getter status_label : String
    getter status : String
    getter customer_name : String
    getter customer_lines : Array(String)
    getter customer_ids : String
    getter seller_name : String
    getter seller_lines : Array(String)
    getter seller_ids : String
    getter issue_date : String
    # Dates facultatives : `nil` si absentes (une chaîne vide est vraie dans
    # un gabarit Marten).
    getter due_date : String?
    getter delivery_date : String?
    getter validity_date : String?
    getter rows : Array(Row)
    getter amounts : Array(Amount)
    getter vat_rows : Array(Amount)?
    getter mentions : Array(String)?
    getter links : Array(Link)?
    getter origin : String?
    getter currency : String
    getter amount_due : String
    getter structured_reference : String
    getter notes : String
    # Bon de retour (D-INV3-012) : motif en toutes lettres, document qui le
    # reprend (facture ou avoir), libellé de la date (« Date du retour »).
    getter return_reason : String?
    getter returned_by : Link?
    getter delivery_date_label : String

    # Texte d'une mention, paramètres présentés dans la langue de l'écran :
    # dates ISO, montants et taux décimaux canoniques du cœur (comme le PDF,
    # `Invoicing::Output.mention_text`).
    def self.mention_text(mention : Partiduo::Api::Invoicing::MentionView, fmt : Format) : String
      params = mention.params.to_h do |key, value|
        formatted = if key.in?("date", "from", "to") && value.matches?(/\A\d{4}-\d{2}-\d{2}\z/)
                      fmt.date(Time.parse_utc(value, "%Y-%m-%d"))
                    elsif key.in?("amount", "capital")
                      BigDecimal.new(value) rescue nil
                    elsif key == "rate"
                      (BigDecimal.new(value) rescue nil).try { |rate| fmt.number(rate) }
                    elsif key == "currency" && value == "EUR"
                      "€"
                    end
        formatted = fmt.amount(formatted) if formatted.is_a?(BigDecimal)
        {key, formatted.is_a?(String) ? formatted : value}
      end
      I18n.t(mention.key, params)
    end

    def initialize(view : Partiduo::Api::Invoicing::DocumentView, fmt : Format, handler : InvoicingScreen)
      @id = view.id
      @kind = view.kind
      @kind_label = handler.kind_label(view.kind)
      @number = view.number || ""
      @draft = view.draft?
      @title = handler.document_title(view)
      @status = view.effective_status
      @status_label = I18n.t(view.status_key)
      @currency = view.currency_code
      @customer_name = view.customer.name
      @customer_lines = view.customer.address_lines
      @customer_ids = [view.customer.siren, view.customer.vat_number].reject(&.empty?).join(" · ")
      @seller_name = view.seller.name
      @seller_lines = view.seller.address_lines
      @seller_ids = [view.seller.siren, view.seller.vat_number].reject(&.empty?).join(" · ")
      @issue_date = fmt.date(view.issue_date)
      @due_date = view.due_date.try { |day| fmt.date(day) }
      @delivery_date = view.delivery_date.try { |day| fmt.date(day) }
      @validity_date = view.validity_date.try { |day| fmt.date(day) }
      returning = view.kind == "return_note"
      @delivery_date_label = I18n.t(returning ? "ui.invoicing.return_date" : "ui.invoicing.delivery_date")
      @return_reason = view.return_reason.presence.try { |code| I18n.t("invoicing.return_reasons.#{code}") }
      @returned_by = returning ? view.billed_in.try { |link| Link.new(link_label(handler, link), handler.reverse("invoicing:document", id: link.id)) } : nil
      @notes = view.notes
      @structured_reference = view.structured_reference
      @rows = view.lines.map { |line| row(line, fmt) }
      @amounts = amounts(view, fmt)
      @amount_due = fmt.amount(view.totals.amount_due)
      vat = view.vat_breakdown.map do |group|
        label = "#{I18n.t("ui.invoicing.totals.vat")} #{fmt.percent(group.percent)} · #{I18n.t("ui.invoicing.totals.base")} #{fmt.amount(group.base)}"
        Amount.new(label, fmt.amount(group.vat))
      end
      @vat_rows = vat.empty? ? nil : vat
      mentions = view.mentions.map { |mention| DocumentDisplay.mention_text(mention, fmt) }
      @mentions = mentions.empty? ? nil : mentions
      @origin = view.origin_mention.try(&.message)
      links = ([view.source] + view.derived + [view.credited] + view.credit_notes + [view.billed_in]).compact.uniq!(&.id).map do |link|
        Link.new(link_label(handler, link), handler.reverse("invoicing:document", id: link.id))
      end
      # Facture récapitulative : chaque bon repris, avec sa date de livraison.
      view.delivery_notes.each do |note|
        next if view.source.try(&.id) == note.id
        label = I18n.t("ui.invoicing.delivery_note_link", number: note.number, date: fmt.date(note.delivery_date))
        links << Link.new(label, handler.reverse("invoicing:document", id: note.id))
      end
      # Bons de retour repris par une facture ou un avoir (D-INV3-003).
      view.return_notes.each do |note|
        next if view.source.try(&.id) == note.id
        label = I18n.t("ui.invoicing.return_note_link", number: note.number, date: fmt.date(note.delivery_date))
        links << Link.new(label, handler.reverse("invoicing:document", id: note.id))
      end
      @links = links.empty? ? nil : links
    end

    private def row(line : Partiduo::Api::Invoicing::LineView, fmt : Format) : Row
      priced = line.priced?
      discount = case line.discount_kind
                 when "percent" then fmt.percent(line.discount_value)
                 when "amount"  then fmt.amount(line.discount_value)
                 else                ""
                 end
      Row.new(line.kind, line.description, priced ? fmt.number(line.quantity) : "", priced ? line.unit_code : "",
        priced ? fmt.amount(line.unit_price) : "", discount, priced ? fmt.percent(line.vat_percent) : "",
        priced || line.kind == "subtotal" ? fmt.amount(line.net_amount) : "")
    end

    # Totaux imprimés : lignes, remise, HT, TVA, TTC, acomptes, reste.
    private def amounts(view : Partiduo::Api::Invoicing::DocumentView, fmt : Format) : Array(Amount)
      totals = view.totals
      list = [Amount.new(I18n.t("ui.invoicing.totals.lines"), fmt.amount(totals.lines_total))]
      list << Amount.new(I18n.t("ui.invoicing.totals.discount"), "-#{fmt.amount(totals.discount_total)}") unless totals.discount_total.zero?
      list << Amount.new(I18n.t("ui.invoicing.totals.net"), fmt.amount(totals.total_net))
      list << Amount.new(I18n.t("ui.invoicing.totals.vat"), fmt.amount(totals.total_vat))
      list << Amount.new(I18n.t("ui.invoicing.totals.gross"), "#{fmt.amount(totals.total_gross)} #{view.currency_code}", true)
      view.deductions.each do |deduction|
        list << Amount.new(I18n.t("ui.invoicing.totals.deposit", number: deduction.deposit_number), "-#{fmt.amount(deduction.amount)}")
      end
      list << Amount.new(I18n.t("ui.invoicing.totals.payable"), fmt.amount(totals.payable), true) unless totals.prepaid.zero?
      list << Amount.new(I18n.t("ui.invoicing.totals.paid"), "-#{fmt.amount(totals.paid)}") unless totals.paid.zero?
      list << Amount.new(I18n.t("ui.invoicing.totals.credited"), "-#{fmt.amount(totals.credited)}") unless totals.credited.zero?
      list
    end

    private def link_label(handler : InvoicingScreen, link : Partiduo::Api::Invoicing::LinkView) : String
      "#{handler.kind_label(link.kind)} #{link.number || I18n.t("ui.invoicing.draft")} · #{handler.link_status_label(link)}"
    end
  end

  # Liste des documents : onglets par nature, filtre de statut et de texte,
  # export CSV.
  class DocumentsHandler < InvoicingScreen
    LIMIT = 500

    STATUSES = %w[draft sent accepted refused expired confirmed issued invoiced partially_paid paid overdue cancelled]

    def get
      kind = Inv::KINDS.includes?(query("kind")) ? query("kind") : nil
      status = query("status").presence
      documents = Inv.documents(current.actor, Inv::DocumentQuery.new(kind: kind, limit: LIMIT))
      documents = documents.select { |document| document.effective_status == status } if status
      documents = documents.sort_by! { |document| {document.issue_date || document.created_at, document.id} }.reverse!
      params = {"kind" => kind || "", "status" => status || ""}.reject { |_, value| value.empty? }
      table = Table.new(I18n.t("invoicing.menu.inv_documents"), columns, documents.map { |document| row(document) },
        reverse("invoicing:documents"), params, empty_message: I18n.t("ui.invoicing.empty"))
      tabs = [Screen::Tab.new(I18n.t("ui.invoicing.all_kinds"), reverse("invoicing:documents"), kind.nil?)] +
             Inv::KINDS.map { |code| Screen::Tab.new(kind_label(code), "#{reverse("invoicing:documents")}?kind=#{code}", code == kind) }
      statuses = [option("", I18n.t("ui.invoicing.all_statuses"))] + STATUSES.map { |code| option(code, status_label(code)) }
      filters = search_filters([
        Form::Field.new("kind", "", "hidden", kind || ""),
        Form::Field.new("status", I18n.t("ui.invoicing.status"), "select", status || "", options: statuses),
      ])
      actions = [] of Screen::Action
      if can?(WRITE)
        actions << link_action("ui.invoicing.new_quote", "#{reverse("invoicing:document_new")}?kind=quote", icon: "plus")
        # Mode simplifié de la micro-entreprise (ADR-007 D3) : facture
        # allégée, mêmes commandes ; profession libérale : formulaire habituel.
        invoice_url = SimpleMode.mode(request) == "MICRO" ? reverse("micro:invoice_new") : reverse("invoicing:invoice_new")
        actions << link_action("ui.invoicing.new_invoice", invoice_url, "primary", "plus")
        # Bons de retour (D-INV3-012) : saisie libre depuis leur onglet.
        if kind == "return_note"
          actions << link_action("ui.invoicing.new_return_note", "#{reverse("invoicing:document_new")}?kind=return_note", icon: "plus")
        end
      end
      list_page(I18n.t("invoicing.menu.inv_documents"), table, [crumb("core.menu.billing")], "ui.invoicing.csv_name", actions,
        tabs: tabs, tabs_label: I18n.t("ui.invoicing.kind"), filters: filters)
    end

    private def columns : Array(Table::Column)
      [
        Table::Column.new("number", I18n.t("ui.invoicing.number"), "mono"),
        Table::Column.new("kind", I18n.t("ui.invoicing.kind"), secondary: true),
        Table::Column.new("date", I18n.t("ui.invoicing.issue_date"), "mono", secondary: true),
        Table::Column.new("customer", I18n.t("ui.invoicing.customer")),
        Table::Column.new("due", I18n.t("ui.invoicing.due_date"), "mono", secondary: true),
        Table::Column.new("net", I18n.t("ui.invoicing.net"), "amount", secondary: true),
        Table::Column.new("gross", I18n.t("ui.invoicing.gross"), "amount"),
        Table::Column.new("left", I18n.t("ui.invoicing.left"), "amount", secondary: true),
        Table::Column.new("status", I18n.t("ui.invoicing.status")),
      ]
    end

    private def row(document : Inv::DocumentView) : Table::Row
      totals = document.totals
      due = document.fiscal? && document.kind != "credit_note" ? totals.amount_due : nil
      Table::Row.new([
        Table::Cell.new(document.number || I18n.t("ui.invoicing.draft"), document_url(document), sort: document.number || ""),
        Table::Cell.new(kind_label(document.kind)),
        Table::Cell.new(fmt.date(document.issue_date), sort: date_key(document.issue_date), csv: date_key(document.issue_date)),
        Table::Cell.new(document.customer.name),
        Table::Cell.new(fmt.date(document.due_date), sort: date_key(document.due_date), csv: date_key(document.due_date)),
        Table::Cell.new(fmt.amount(totals.total_net), sort: totals.total_net, csv: fmt.csv_amount(totals.total_net)),
        Table::Cell.new(fmt.amount(totals.total_gross), sort: totals.total_gross, csv: fmt.csv_amount(totals.total_gross)),
        Table::Cell.new(due ? fmt.amount(due) : "", sort: due || BigDecimal.new(0), csv: due ? fmt.csv_amount(due) : ""),
        Table::Cell.new(I18n.t(document.status_key)),
      ], document.effective_status == "overdue" ? "pd-row-late" : "")
    end
  end

  # Nouveau document (brouillon) : `?kind=quote` (défaut : facture).
  class DocumentNewHandler < InvoicingScreen
    def default_kind : String
      Inv::KINDS.includes?(query("kind")) && query("kind") != "credit_note" ? query("kind") : "invoice"
    end

    def get
      require!(MODULE, WRITE)
      kind = default_kind
      form = DocumentForm.blank(kind)
      form.customer = query("customer")
      show(form)
    end

    def post
      require!(MODULE, WRITE)
      kind = Inv::KINDS.includes?(field("kind")) ? field("kind") : "invoice"
      form = DocumentForm.read(kind, form_values)
      if field("add_line") == "1"
        form.add_line
        return show(form)
      end
      if index = field("remove_line").to_i?
        form.remove_line(index)
        return show(form.renumber!)
      end
      input = document_input(form)
      return show(form, 422) unless input
      result = Inv.create_document(current.actor, input)
      if document = result.value?
        flash["success"] = I18n.t("ui.invoicing.created", kind: kind_label(document.kind))
        return go(document_url(document))
      end
      add_errors(form, result.errors)
      show(form, 422)
    end

    private def show(form : DocumentForm, status : Int32 = 200) : Marten::HTTP::Response
      edit_page(form, reverse("invoicing:document_new"), I18n.t("ui.invoicing.new_title", kind: kind_label(form.kind)), status: status)
    end
  end

  # Entrée de menu « Nouvelle facture » (`invoicing:invoice_new`).
  class InvoiceNewHandler < DocumentNewHandler
    def default_kind : String
      "invoice"
    end
  end

  # Modification d'un brouillon.
  class DocumentEditHandler < InvoicingScreen
    def get
      require!(MODULE, WRITE)
      document = Inv.document(current.actor, id_param)
      return go(document_url(document)) unless document.draft?
      show(form_of(document), document)
    end

    def post
      require!(MODULE, WRITE)
      document = Inv.document(current.actor, id_param)
      form = DocumentForm.read(document.kind, form_values)
      if field("add_line") == "1"
        form.add_line
        return show(form, document)
      end
      if index = field("remove_line").to_i?
        form.remove_line(index)
        return show(form.renumber!, document)
      end
      input = document_input(form, document)
      return show(form, document, 422) unless input
      result = Inv.update_document(current.actor, document.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.invoicing.updated")
        return go(document_url(updated))
      end
      add_errors(form, result.errors)
      show(form, document, 422)
    end

    private def show(form : DocumentForm, document : Inv::DocumentView, status : Int32 = 200) : Marten::HTTP::Response
      edit_page(form, reverse("invoicing:document_edit", id: document.id), document_title(document), document, status)
    end
  end

  # Totaux instantanés du brouillon (HTMX) : `check_document`.
  class DocumentCheckHandler < InvoicingScreen
    def post
      require!(MODULE, WRITE)
      kind = Inv::KINDS.includes?(field("kind")) ? field("kind") : "invoice"
      existing = field("document_id").to_i64?.try { |id| Inv.document(current.actor, id) }
      form = DocumentForm.read(kind, form_values)
      totals = nil
      errors = [] of String
      if input = document_input(form, existing)
        result = Inv.check_document(current.actor, input, existing.try(&.id))
        if value = result.value?
          totals = TotalsDisplay.new(value, fmt, existing.try(&.currency_code) || "")
        else
          errors = result.errors.map { |error| fmt.message(error) }
        end
      else
        errors = collect(form)
      end
      render("ui/invoicing/_totals.html", {"totals" => totals, "errors" => errors.empty? ? nil : errors})
    end

    private def collect(form : DocumentForm) : Array(String)
      messages = [] of String
      form.base_errors.try { |list| messages.concat(list) }
      form.customer_errors.try { |list| messages.concat(list) }
      form.filled_lines.each_with_index do |line, position|
        line.errors.try(&.each { |message| messages << I18n.t("ui.entries.line_error", line: position + 1, message: message) })
      end
      messages
    end
  end

  class TotalsDisplay
    include Marten::Template::Object::Auto

    getter lines_total : String
    getter discount : String?
    getter net : String
    getter vat : String
    getter gross : String
    getter prepaid : String?
    getter payable : String?

    def initialize(totals : Partiduo::Api::Invoicing::TotalsView, fmt : Format, currency : String)
      @lines_total = fmt.amount(totals.lines_total)
      @discount = totals.discount_total.zero? ? nil : fmt.amount(totals.discount_total)
      @net = fmt.amount(totals.total_net)
      @vat = fmt.amount(totals.total_vat)
      @gross = [fmt.amount(totals.total_gross), currency].reject(&.empty?).join(" ")
      @prepaid = totals.prepaid.zero? ? nil : fmt.amount(totals.prepaid)
      @payable = totals.prepaid.zero? ? nil : fmt.amount(totals.payable)
    end
  end

  # Choix de l'adresse de livraison parmi celles du client saisi (HTMX, au
  # changement du champ « Client »). DECISIONS D-R5-004.
  class DocumentDeliveryHandler < InvoicingScreen
    def get
      require!(MODULE, WRITE)
      form = DocumentForm.new("invoice")
      form.customer = query("customer").strip
      form.delivery = query("delivery").strip
      form.delivery = "" if form.delivery.starts_with?("card:")
      form.delivery_line1 = query("delivery_line1").strip
      form.delivery_postcode = query("delivery_postcode").strip
      form.delivery_city = query("delivery_city").strip
      form.delivery_country = query("delivery_country").strip
      form.delivery_options = delivery_options(form.customer, form.delivery)
      render("ui/invoicing/_delivery.html", {"form" => form})
    end
  end

  # Nouvelle ligne de document (HTMX, Alt+↓ ou « Ajouter une ligne »).
  class DocumentLineHandler < InvoicingScreen
    def get
      require!(MODULE, WRITE)
      index = query("line_next").to_i? || 0
      form = decorate(DocumentForm.new("invoice", [DocumentForm::Line.new(index)]))
      render("ui/invoicing/_new_line.html", {"line" => form.lines.first, "next_index" => index + 1})
    end
  end

  # Consultation d'un document : lignes, totaux, mentions, liens, règlements,
  # actions selon son état, panneaux des extensions actives.
  class DocumentHandler < InvoicingScreen
    def get
      actor = current.actor
      document = Inv.document(actor, id_param)
      context["title"] = document_title(document)
      context["crumbs"] = crumbs
      context["document"] = DocumentDisplay.new(document, fmt, self)
      context["actions"] = actions(document)
      context["transforms"] = transforms(document)
      context["deposit_url"] = deposit_url(document)
      context["decide_url"] = decide_url(document)
      context["payments"] = payments(document)
      context["events"] = events(document)
      context["payment_note"] = payment_note(document)
      context["customer_url"] = customer_url(document)
      context["channel"] = document.fiscal? ? ChannelDisplay.new(document, fmt, self) : nil
      # Encours maximum HT du client (D-INV2-009) : avertissement sur un
      # brouillon ; dérogation motivée pour qui en a la permission.
      context["credit"] = document.draft? ? CreditDisplay.build(document, fmt, self) : nil
      # Actions et fichiers des extensions actives (DECISIONS D-HOOK-002).
      context["extension_panels"] = listed(Extensions.document_panels(actor, document))
      page("ui/invoicing/show.html")
    end

    private def actions(document : Inv::DocumentView) : Array(Screen::Action)
      actions = [] of Screen::Action
      if document.draft?
        if can?(WRITE)
          actions << link_action("ui.forms.edit", reverse("invoicing:document_edit", id: document.id), icon: "notebook-pen")
          actions << post_action("ui.forms.delete", reverse("invoicing:document_delete", id: document.id), "ui.invoicing.delete_confirm", "danger")
        end
        issue_permission = document.kind == "credit_note" ? "invoicing.credit_note.issue" : "invoicing.invoice.issue"
        if can?(issue_permission)
          actions << post_action("ui.invoicing.issue", reverse("invoicing:document_issue", id: document.id), "ui.invoicing.issue_confirm", "primary", "check")
        end
      end
      actions << link_action("ui.invoicing.preview", reverse("invoicing:document_preview", id: document.id), icon: "file-text")
      if original_is_electronic?(document)
        # Facture remise par la plateforme : l'original est la facture
        # électronique ; le PDF proposé par défaut est la copie, l'original
        # PDF/A-3 (XML Factur-X embarqué) reste téléchargeable comme archive,
        # à ne pas transmettre (jamais de second original, D-CPY-010).
        actions << link_action("ui.invoicing.pdf_copy_download", reverse("invoicing:document_pdf_copy", id: document.id), icon: "download")
        actions << link_action("ui.invoicing.download_original_archived", reverse("invoicing:document_pdf", id: document.id), icon: "lock")
      else
        actions << link_action("ui.invoicing.download_pdf", reverse("invoicing:document_pdf", id: document.id), icon: "download")
      end
      if !document.draft? && can?("invoicing.invoice.send")
        actions << link_action("ui.invoicing.send", reverse("invoicing:document_send", id: document.id), icon: "file-text")
      end
      actions.concat(follow_up_actions(document))
      actions
    end

    # Document fiscal émis au canal plateforme et déjà déposé : son original
    # est la facture électronique.
    private def original_is_electronic?(document : Inv::DocumentView) : Bool
      return false if document.draft? || !document.fiscal? || document.issue_channel != "platform"
      !Inv.pdf_copy_status(current.actor, document.id).deposited_at.nil?
    end

    # Règlement (Comptabilité inactive) et relance d'une facture non soldée.
    private def follow_up_actions(document : Inv::DocumentView) : Array(Screen::Action)
      actions = [] of Screen::Action
      return actions if document.draft? || !document.fiscal? || document.kind == "credit_note" || !document.totals.amount_due.positive?
      if !module_active?("ACCOUNTING") && can?("invoicing.payment.record")
        actions << link_action("ui.invoicing.record_payment", reverse("invoicing:document_payment", id: document.id), icon: "plus")
      end
      if document.effective_status == "overdue" && can?("invoicing.reminder.send")
        actions << link_action("ui.invoicing.remind", "#{reverse("invoicing:reminders")}?customer=#{document.customer_card_id}", icon: "clock")
      end
      actions
    end

    # Transformations admises (sauf l'acompte, qui demande un pourcentage) ;
    # « Faire l'avoir » d'un bon de retour émis et non repris (D-INV3-012).
    private def transforms(document : Inv::DocumentView) : Array(Screen::Action)?
      return if document.draft? || !can?(WRITE) || document.effective_status == "cancelled"
      kinds = Inv::TRANSFORMATIONS[document.kind]? || [] of String
      # Bon déjà repris par une facture (D-INV2-002) : plus de facture à en tirer.
      kinds = kinds.reject(&.==("invoice")) if document.billed_in
      list = kinds.reject(&.==("deposit_invoice")).map do |kind|
        label = case kind
                when "credit_note" then I18n.t("ui.invoicing.make_credit_note")
                when "return_note" then I18n.t("ui.invoicing.make_return_note")
                else                    I18n.t("ui.invoicing.transform_to", kind: kind_label(kind).downcase)
                end
        Screen::Action.new(label, "#{reverse("invoicing:document_transform", id: document.id)}?kind=#{kind}", "post", "", "file-text")
      end
      if document.kind == "return_note" && document.effective_status == "issued" && document.billed_in.nil?
        list << Screen::Action.new(I18n.t("ui.invoicing.credit_return"),
          "#{reverse("invoicing:credit_returns")}?note=#{document.id}&from=document", "post", "", "file-text")
      end
      list.empty? ? nil : list
    end

    private def deposit_url(document : Inv::DocumentView) : String?
      return if document.draft? || !can?(WRITE)
      return unless (Inv::TRANSFORMATIONS[document.kind]? || [] of String).includes?("deposit_invoice")
      reverse("invoicing:document_transform", id: document.id)
    end

    private def decide_url(document : Inv::DocumentView) : String?
      return unless document.kind == "quote" && document.status == "sent" && can?(WRITE)
      reverse("invoicing:document_decide", id: document.id)
    end

    # Règlements, rejet compris (D-INV3-012) : « Enregistrer un rejet » sur
    # chaque règlement non rejeté, Comptabilité active ou non.
    private def payments(document : Inv::DocumentView) : Array(PaymentDisplay)?
      return if document.draft? || !document.fiscal?
      can_reject = can?("invoicing.payment.record")
      list = Inv.payments(current.actor, document.id).map do |payment|
        PaymentDisplay.new(payment, fmt, self, can_reject)
      end
      list.empty? ? nil : list
    end

    private def events(document : Inv::DocumentView) : Array(DocumentDisplay::Amount)?
      list = Inv.document_events(current.actor, document.id).map do |event|
        DocumentDisplay::Amount.new(fmt.datetime(event.created_at), I18n.t("ui.invoicing.events.#{event.action}", default: event.action))
      end
      list.empty? ? nil : list
    end

    private def payment_note(document : Inv::DocumentView) : String?
      if !document.draft? && document.fiscal? && document.kind != "credit_note" && module_active?("ACCOUNTING")
        I18n.t("ui.invoicing.payment_by_matching")
      end
    end

    private def customer_url(document : Inv::DocumentView) : String?
      if module_active?("ACCOUNTING") && can?("accounting.entry.read") && !document.customer.code.empty?
        "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => document.customer.code})}"
      end
    end
  end

  # Règlement d'une facture (consultation) : date, mode, référence, montant ;
  # règlement rejeté barré avec « Rejeté le … — motif » en toutes lettres,
  # relance proposée et facture de frais ; bouton « Enregistrer un rejet »
  # (nom accessible qui désigne le règlement) s'il ne l'est pas (D-INV3-012).
  class PaymentDisplay
    include Marten::Template::Object::Auto

    getter label : String
    getter amount : String
    getter rejected : Bool
    getter rejection : String?
    getter reject_url : String?
    getter reject_label : String
    getter reminder_url : String?
    getter fees_url : String?

    def initialize(payment : Partiduo::Api::Invoicing::PaymentView, fmt : Format, handler : InvoicingScreen, can_reject : Bool)
      method = I18n.t("ui.invoicing.methods.#{payment.method}")
      @label = "#{fmt.date(payment.paid_on)} · #{method} #{payment.reference}".strip
      @amount = fmt.amount(payment.amount)
      rejection = payment.rejection
      @rejected = !rejection.nil?
      @rejection = rejection.try { |view| PaymentDisplay.rejection_text(view, fmt) }
      @reject_url = can_reject && rejection.nil? ? handler.reverse("invoicing:payment_reject", id: payment.document_id, payment_id: payment.id) : nil
      @reject_label = I18n.t("ui.invoicing.rejection.record_aria", date: fmt.date(payment.paid_on), amount: @amount)
      @reminder_url = rejection.try(&.reminder_id) ? handler.reverse("invoicing:reminders") : nil
      @fees_url = rejection.try(&.fees_invoice_id).try { |id| handler.reverse("invoicing:document", id: id) }
    end

    # « Rejeté le 12/09/2026 — Provision insuffisante (précision) ».
    def self.rejection_text(view : Partiduo::Api::Invoicing::PaymentRejectionView, fmt : Format) : String
      reason = I18n.t(view.reason_key)
      reason = "#{reason} (#{view.reason_text})" unless view.reason_text.empty?
      I18n.t("ui.invoicing.rejection.rejected_text", date: fmt.date(view.rejected_on), reason: reason)
    end
  end

  # Canal d'émission d'un document fiscal (ADR-004 D9) : canal, marquage B2C,
  # date d'envoi ; changement tant que le document n'est pas envoyé, « Marquer
  # comme envoyé » pour un envoi hors courriel (papier, plateforme).
  class ChannelDisplay
    include Marten::Template::Object::Auto

    getter label : String
    getter b2c : Bool
    getter sent_at : String?
    getter change_url : String?
    getter mark_sent_url : String?
    getter options : Array(Form::Option)
    getter platform_note : Bool
    getter copy_pdf_url : String?
    getter copy_send_url : String?
    getter copy_due : Bool
    getter copy_sent : String?
    getter copy_failed : String?
    getter copy_deposited : String?

    def initialize(view : Partiduo::Api::Invoicing::DocumentView, fmt : Format, handler : InvoicingScreen)
      @label = I18n.t(view.channel_key)
      @b2c = view.b2c
      @sent_at = view.sent_at.try { |time| fmt.datetime(time) }
      @change_url = view.channel_editable? && handler.can?(InvoicingScreen::WRITE) ? handler.reverse("invoicing:document_channel", id: view.id) : nil
      @mark_sent_url = !view.draft? && view.sent_at.nil? && handler.can?("invoicing.invoice.send") ? handler.reverse("invoicing:document_mark_sent", id: view.id) : nil
      @options = Partiduo::Api::Invoicing::ISSUE_CHANNELS.map do |code|
        Form::Option.new(code, I18n.t("invoicing.channels.#{code}"), code == view.issue_channel)
      end
      # Plateforme choisie : la transmission revient à une extension ; sans
      # elle, le document reste à remettre et à marquer envoyé.
      @platform_note = view.issue_channel == "platform" && view.sent_at.nil?
      # Copie PDF doublant la plateforme (ADR-004 D9) : téléchargement et
      # envoi (ou renvoi) par courriel d'un document émis au canal plateforme.
      platform = !view.draft? && view.issue_channel == "platform"
      @copy_pdf_url = platform ? handler.reverse("invoicing:document_pdf_copy", id: view.id) : nil
      @copy_send_url = platform && handler.can?("invoicing.invoice.send") ? handler.reverse("invoicing:document_send_pdf_copy", id: view.id) : nil
      @copy_due = false
      @copy_sent = nil
      @copy_failed = nil
      @copy_deposited = nil
      return unless platform
      status = Partiduo::Api::Invoicing.pdf_copy_status(handler.current.actor, view.id)
      @copy_due = status.due
      # « Copie PDF envoyée le… » : dernier envoi, destinataires ; dernier
      # échec s'il est postérieur ; dépôt sur la plateforme.
      @copy_deposited = status.deposited_at.try { |time| I18n.t("ui.invoicing.pdf_copy_deposited", date: fmt.datetime(time)) }
      @copy_sent = status.sent_at.try do |time|
        I18n.t("ui.invoicing.pdf_copy_sent_on", date: fmt.datetime(time), to: status.sent_to.join(", "))
      end
      @copy_failed = status.failed_at.try do |time|
        I18n.t("ui.invoicing.pdf_copy_failed_on", date: fmt.datetime(time), error: copy_error(status.error, status.error_detail))
      end
    end

    # Motif de l'échec : clés de traduction du contrat (`invoicing.errors.…`,
    # séparées par des virgules), traduites avec le détail technique en
    # paramètre (`%{error}`, `%{detail}`) ; une partie qui n'a pas la forme
    # d'une clé (trace antérieure : message du serveur) reste telle quelle.
    # DECISIONS D-CPY-006, D-CPY-007.
    def self.copy_error(error : String, detail : String = "") : String
      params = {"error" => detail, "detail" => detail}
      error.split(", ").map { |part| part.matches?(/\A[a-z_]+(\.[a-z0-9_]+)+\z/) ? I18n.t(part, params) : part }.join(" ")
    end

    private def copy_error(error : String, detail : String) : String
      self.class.copy_error(error, detail)
    end
  end

  # Changement du canal d'émission (champ `issue_channel`, case `b2c`).
  class DocumentChannelHandler < InvoicingScreen
    def post
      require!(MODULE, WRITE)
      document = Inv.document(current.actor, id_param)
      input = Inv::ChannelInput.new(field("issue_channel"), b2c: field("b2c") == "1")
      flash_result(Inv.set_issue_channel(current.actor, document.id, input), "ui.invoicing.channel_saved")
      go(document_url(document))
    end
  end

  # Document remis hors du courriel de la Facturation : marqué envoyé.
  class DocumentMarkSentHandler < InvoicingScreen
    def post
      require!(MODULE, "invoicing.invoice.send")
      document = Inv.document(current.actor, id_param)
      flash_result(Inv.mark_sent(current.actor, document.id), "ui.invoicing.marked_sent")
      go(document_url(document))
    end
  end

  # Copie PDF d'une facture transmise par la plateforme (ADR-004 D9) :
  # bandeau « Copie », sans XML Factur-X.
  class DocumentPdfCopyHandler < InvoicingScreen
    def get
      file = Inv.document_pdf_copy(current.actor, id_param)
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end
  end

  # Envoi (ou renvoi) de la copie PDF par courriel, tracé.
  class DocumentSendPdfCopyHandler < InvoicingScreen
    def post
      require!(MODULE, "invoicing.invoice.send")
      document = Inv.document(current.actor, id_param)
      flash_result(Inv.send_pdf_copy(current.actor, document.id), "ui.invoicing.pdf_copy_sent")
      go(document_url(document))
    end
  end

  # Saisie express d'un particulier depuis la facture (ADR-004 D9) : fiche
  # de client de nature « particulier », créée par la commande du contrat
  # `Cards.create_individual_customer` ; le
  # champ « Client » reçoit son quick code (HTMX, hors cible).
  class ExpressCustomerHandler < InvoicingScreen
    def post
      require!(MODULE, WRITE)
      require!("CARDS", "cards.card.write")
      cards = Partiduo::Api::Cards
      address = Partiduo::Api::Cards::AddressInput.new(line1: field("express_line1"), postcode: field("express_postcode"),
        city: field("express_city"))
      input = Partiduo::Api::Cards::IndividualCustomerInput.new(name: field("express_name"), address: address,
        email: field("express_email"))
      result = cards.create_individual_customer(current.actor, input)
      if card = result.value?
        render("ui/invoicing/_express_result.html", {
          "created" => I18n.t("ui.invoicing.express.created", name: card.name, code: card.code), "code" => card.code,
        })
      else
        render("ui/invoicing/_express_result.html", {"errors" => result.errors.map { |error| I18n.t(error.key, error.params) }})
      end
    end
  end

  # Aperçu du document tel qu'il sera imprimé (maquette « Aperçu »).
  class DocumentPreviewHandler < InvoicingScreen
    def get
      document = Inv.document(current.actor, id_param)
      context["title"] = document_title(document)
      context["crumbs"] = crumbs + [Screen::Crumb.new(document_title(document), document_url(document))]
      context["document"] = DocumentDisplay.new(document, fmt, self)
      page("ui/invoicing/preview.html")
    end
  end

  # PDF/A-3 (Factur-X pour une facture, un acompte, un avoir) : celui
  # conservé à l'émission ; aperçu calculé pour un brouillon.
  class DocumentPdfHandler < InvoicingScreen
    def get
      file = Inv.document_pdf(current.actor, id_param)
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end
  end

  # Avertissement d'encours d'un brouillon (D-INV2-009) : encours actuel HT,
  # montant du document, plafond, dépassement ; formulaire de dérogation
  # (motif obligatoire) pour qui a `invoicing.credit_limit.override`.
  class CreditDisplay
    include Marten::Template::Object::Auto

    getter message : String
    getter blocking : Bool
    getter override_url : String?

    def initialize(@message, @blocking, @override_url)
    end

    def self.build(document : Partiduo::Api::Invoicing::DocumentView, fmt : Format, handler : InvoicingScreen) : self?
      check = Partiduo::Api::Invoicing.credit_check(handler.current.actor, document.id) || return
      return unless check.exceeded?
      params = check.params.to_h do |key, value|
        {key, key.in?("customer", "currency") ? value : fmt.amount(BigDecimal.new(value))}
      end
      key = check.controlled ? "ui.invoicing.credit.blocking" : "ui.invoicing.credit.warning"
      can_override = check.controlled && handler.can?(Partiduo::Api::Invoicing::CREDIT_OVERRIDE) &&
                     handler.can?("invoicing.invoice.issue")
      new(I18n.t(key, params), check.controlled, can_override ? handler.reverse("invoicing:document_issue", id: document.id) : nil)
    end
  end

  # Validation : émission (numéro, mentions figées, PDF Factur-X) ; motif de
  # dérogation à l'encours maximum (`credit_override_reason`) s'il est donné.
  class DocumentIssueHandler < InvoicingScreen
    def post
      document = Inv.document(current.actor, id_param)
      reason = field("credit_override_reason").presence
      result = Inv.issue(current.actor, document.id, Inv::IssueInput.new(credit_override_reason: reason))
      if issued = result.value?
        flash["success"] = I18n.t("ui.invoicing.issued", title: document_title(issued))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(document_url(document))
    end
  end

  # Transformation en document suivant, avoir compris (`?kind=` ou champ
  # `kind`, `deposit_percent` pour une facture d'acompte).
  class DocumentTransformHandler < InvoicingScreen
    def post
      document = Inv.document(current.actor, id_param)
      kind = field("kind").presence || query("kind")
      percent = field("deposit_percent").presence.try { |text| fmt.parse_decimal(text) }
      if kind == "deposit_invoice" && percent.nil?
        flash["danger"] = I18n.t("ui.invoicing.deposit_percent_required")
        return go(document_url(document))
      end
      result = Inv.transform(current.actor, document.id, Inv::TransformInput.new(kind, percent))
      if created = result.value?
        flash["success"] = I18n.t("ui.invoicing.transformed", kind: kind_label(created.kind))
        go(reverse("invoicing:document_edit", id: created.id))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(document_url(document))
      end
    end
  end

  class DocumentDecideHandler < InvoicingScreen
    def post
      document = Inv.document(current.actor, id_param)
      decision = field("decision")
      result = Inv.decide_quote(current.actor, document.id, decision)
      if result.success?
        flash["success"] = I18n.t("ui.invoicing.decided.#{decision == "accepted" ? "accepted" : "refused"}")
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(document_url(document))
    end
  end

  class DocumentDeleteHandler < InvoicingScreen
    def post
      document = Inv.document(current.actor, id_param)
      if flash_result(Inv.delete_draft(current.actor, document.id), "ui.invoicing.deleted")
        go(reverse("invoicing:documents"))
      else
        go(document_url(document))
      end
    end
  end
end
