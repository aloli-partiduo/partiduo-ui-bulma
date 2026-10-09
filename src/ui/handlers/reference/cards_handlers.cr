# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module PartiduoUi
  # Fiches du socle (`Partiduo::Api::Cards`, successeur de `fiche`) : tiers
  # d'un côté, articles et services de l'autre (fiches de nature `item`),
  # création, consultation, modification, activation, suppression. Le compte
  # comptable d'une fiche n'est affiché que si la Comptabilité est active.
  abstract class CardScreen < ReferenceHandler
    # Nombre de fiches lues par le contrat pour une liste (tri et pages dans
    # l'interface, D-UI-016).
    LIST_LIMIT = 1000

    def crumbs(items : Bool = false) : Array(Screen::Crumb)
      list = items ? crumb("ui.cards.items", reverse("cards:items")) : crumb("ui.cards.parties", reverse("cards:index"))
      [crumb("core.menu.reference"), list]
    end

    def tabs(items : Bool) : Array(Screen::Tab)
      [
        Screen::Tab.new(I18n.t("ui.cards.parties"), reverse("cards:index"), !items),
        Screen::Tab.new(I18n.t("ui.cards.items"), reverse("cards:items"), items),
      ]
    end

    # Catégories d'un côté : articles (`item`) ou tiers (toutes les autres).
    def categories_for(items : Bool) : Array(Partiduo::Api::Cards::CategoryView)
      Partiduo::Api::Cards.categories(current.actor).select { |category| category.item? == items }
    end

    def kind_label(kind : String) : String
      I18n.t("cards.kinds.#{kind}")
    end

    def status_label(enabled : Bool) : String
      I18n.t(enabled ? "ui.forms.active" : "ui.forms.inactive")
    end

    # Prix : deux décimales, jusqu'à quatre si la saisie en porte plus.
    # Prix dans un champ de saisie : sans séparateur de milliers (relu par
    # `Format#parse_decimal`).
    def input_price(value : BigDecimal?) : String
      return "" if value.nil?
      fmt.amount(value, value.round(2) == value ? 2 : 4, group: false)
    end

    def price(value : BigDecimal?) : String
      return "" if value.nil?
      value.round(2) == value ? fmt.amount(value) : fmt.amount(value, 4)
    end

    def unit_label(code : String) : String
      code.empty? ? "" : I18n.t("cards.units.#{code.downcase}")
    end

    def address_text(address : Partiduo::Api::Cards::AddressView?) : String
      return "" if address.nil?
      locality = [address.postcode, address.city].reject(&.empty?).join(" ")
      [address.label, address.line1, address.line2, locality, address.country_code].reject(&.empty?).join(", ")
    end

    # --- Formulaire -----------------------------------------------------------

    def card_form(category : Partiduo::Api::Cards::CategoryView, input : Partiduo::Api::Cards::CardInput,
                  categories : Array(Partiduo::Api::Cards::CategoryView)) : Form
      category_options = categories.map { |item| option(item.id.to_s, "#{item.name} (#{kind_label(item.kind)})") }
      groups = [Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.cards.name"), value: input.name, required: true, maxlength: 255, wide: true),
        Form::Field.new("code", I18n.t("ui.cards.code"), value: input.code || "", mono: true, maxlength: 40,
          help: I18n.t("ui.cards.code_help")),
        Form::Field.new("category_id", I18n.t("ui.cards.category"), "select", category.id.to_s, options: category_options, required: true),
        Form::Field.new("description", I18n.t("ui.cards.description"), "textarea", input.description || "", wide: true),
        Form::Field.new("enabled", I18n.t("ui.forms.enabled"), "checkbox", input.enabled ? "1" : ""),
      ])]
      if category.item?
        groups << item_group(input)
      else
        groups.concat(party_groups(input))
        groups << customer_group(input) if category.kind == "customer"
        groups << supplier_group(input) if category.kind == "supplier"
      end
      unless category.attributes.empty?
        groups << Form::Group.new(I18n.t("ui.cards.attributes"), category.attributes.map { |attribute| extra_field(attribute, input.extra[attribute.key]?) })
      end
      Form.new(groups)
    end

    private def item_group(input) : Form::Group
      units = Partiduo::Api::Cards::UNITS.map { |code| option(code, "#{unit_label(code)} (#{code})") }
      rates = [option("", I18n.t("ui.cards.no_vat_rate"))] +
              Partiduo::Api::Vat.rates(current.actor).map { |rate| option(rate.id.to_s, "#{rate.code} — #{rate.label}") }
      Form::Group.new(I18n.t("ui.cards.item_group"), [
        Form::Field.new("unit_code", I18n.t("ui.cards.unit"), "select", input.unit_code || "C62", options: units),
        Form::Field.new("sale_price", I18n.t("ui.cards.sale_price"), "number", input_price(input.sale_price), mono: true),
        Form::Field.new("purchase_price", I18n.t("ui.cards.purchase_price"), "number", input_price(input.purchase_price), mono: true),
        Form::Field.new("vat_rate_id", I18n.t("ui.cards.vat_rate"), "select", input.vat_rate_id.try(&.to_s) || "", options: rates),
      ])
    end

    private def party_groups(input) : Array(Form::Group)
      address = input.address || Partiduo::Api::Cards::AddressInput.new
      delivery = input.delivery_addresses.first? || Partiduo::Api::Cards::AddressInput.new
      [
        Form::Group.new(I18n.t("ui.cards.contact_group"), [
          Form::Field.new("contact_name", I18n.t("ui.cards.contact_name"), value: input.contact_name || ""),
          Form::Field.new("email", I18n.t("ui.cards.email"), "email", input.email || ""),
          Form::Field.new("phone", I18n.t("ui.cards.phone"), value: input.phone || ""),
        ]),
        Form::Group.new(I18n.t("ui.cards.ids_group"), [
          Form::Field.new("vat_number", I18n.t("ui.cards.vat_number"), value: input.vat_number || "", mono: true),
          Form::Field.new("siren", I18n.t("ui.cards.siren"), value: input.siren || "", mono: true),
          Form::Field.new("siret", I18n.t("ui.cards.siret"), value: input.siret || "", mono: true),
          Form::Field.new("routing_id", I18n.t("ui.cards.routing_id"), value: input.routing_id || "", mono: true,
            help: I18n.t("ui.cards.routing_help")),
          Form::Field.new("iban", I18n.t("ui.cards.iban"), value: input.iban || "", mono: true),
          Form::Field.new("bic", I18n.t("ui.cards.bic"), value: input.bic || "", mono: true),
        ]),
        Form::Group.new(I18n.t("ui.cards.address"), address_fields("address", address)),
        Form::Group.new(I18n.t("ui.cards.delivery_address"), address_fields("delivery", delivery)),
      ]
    end

    # Nature du client et copie PDF (ADR-004 D9) : la nature se *choisit* ;
    # la proposition du cœur (SIREN, numéro de TVA) n'est qu'un rappel.
    private def customer_group(input) : Form::Group
      natures = [option("", I18n.t("ui.cards.nature_unset"))] +
                Partiduo::Api::Cards::CUSTOMER_NATURES.map { |nature| option(nature, I18n.t("cards.natures.#{nature}")) }
      proposed = Partiduo::Api::Cards.propose_nature(input.siren || "", input.vat_number || "")
      Form::Group.new(I18n.t("ui.cards.customer_group"), [
        Form::Field.new("customer_nature", I18n.t("ui.cards.nature"), "select", input.customer_nature || "",
          options: natures, help: I18n.t("ui.cards.nature_help", {"nature" => I18n.t("cards.natures.#{proposed}")})),
        Form::Field.new("pdf_copy", I18n.t("ui.cards.pdf_copy"), "checkbox", input.pdf_copy == false ? "" : "1",
          help: I18n.t("ui.cards.pdf_copy_help")),
      ])
    end

    # Fournisseur personne physique (DAS2) : nature, puis nom, prénoms et
    # date de naissance, déclarés à la place de la raison sociale.
    private def supplier_group(input) : Form::Group
      natures = [option("", I18n.t("ui.cards.nature_unset"))] +
                Partiduo::Api::Cards::SUPPLIER_NATURES.map { |nature| option(nature, I18n.t("cards.supplier_natures.#{nature}")) }
      Form::Group.new(I18n.t("ui.cards.supplier_group"), [
        Form::Field.new("supplier_nature", I18n.t("ui.cards.supplier_nature"), "select", input.supplier_nature || "",
          options: natures, help: I18n.t("ui.cards.supplier_nature_help")),
        Form::Field.new("last_name", I18n.t("ui.cards.last_name"), value: input.last_name || "", maxlength: 128,
          help: I18n.t("ui.cards.person_help")),
        Form::Field.new("first_names", I18n.t("ui.cards.first_names"), value: input.first_names || "", maxlength: 128),
        Form::Field.new("birth_date", I18n.t("ui.cards.birth_date"), "date", input.birth_date.try(&.to_s("%F")) || ""),
      ])
    end

    private def address_fields(prefix : String, address : Partiduo::Api::Cards::AddressInput) : Array(Form::Field)
      [
        Form::Field.new("#{prefix}.line1", I18n.t("ui.cards.line1"), value: address.line1 || "", wide: true),
        Form::Field.new("#{prefix}.line2", I18n.t("ui.cards.line2"), value: address.line2 || "", wide: true),
        Form::Field.new("#{prefix}.postcode", I18n.t("ui.cards.postcode"), value: address.postcode || "", mono: true),
        Form::Field.new("#{prefix}.city", I18n.t("ui.cards.city"), value: address.city || ""),
        Form::Field.new("#{prefix}.country_code", I18n.t("ui.cards.country"), value: address.country_code || "", mono: true,
          maxlength: 2, help: I18n.t("ui.cards.country_help")),
      ]
    end

    private def extra_field(attribute : Partiduo::Api::Cards::AttributeView, value : JSON::Any?) : Form::Field
      name = "extra.#{attribute.key}"
      text = json_text(value)
      case attribute.value_type
      when "boolean"
        Form::Field.new(name, attribute.label, "checkbox", value.try(&.as_bool?) ? "1" : "")
      when "number"
        Form::Field.new(name, attribute.label, "number", text.empty? ? "" : fmt.input_number(Format.canonical_decimal(text)),
          required: attribute.required, mono: true)
      when "date"
        Form::Field.new(name, attribute.label, "date", text, required: attribute.required)
      else
        Form::Field.new(name, attribute.label, value: text, required: attribute.required, maxlength: attribute.max_length)
      end
    end

    # Valeur d'un attribut propre en texte (chaîne, nombre, identifiant).
    def json_text(value : JSON::Any?) : String
      return "" if value.nil?
      value.as_s? || value.raw.to_s
    end

    # Saisie envoyée ; `keep` : fiche modifiée (adresses de livraison au-delà
    # de la première conservées).
    def read_input(category : Partiduo::Api::Cards::CategoryView, form_errors : Array({String, String}),
                   keep : Partiduo::Api::Cards::CardView? = nil) : Partiduo::Api::Cards::CardInput
      extra = read_extra(category, form_errors)
      return read_item(category, extra, form_errors) if category.item?
      deliveries = [address_input("delivery")].compact
      deliveries.concat(keep.delivery_addresses[1..].map(&.to_input)) if keep && keep.delivery_addresses.size > 1
      Partiduo::Api::Cards::CardInput.new(
        category_id: category.id, name: field("name"), code: field("code").presence,
        description: field("description", strip: false).strip, enabled: checkbox("enabled"),
        vat_number: field("vat_number"), siren: field("siren"), siret: field("siret"), routing_id: field("routing_id"),
        iban: field("iban"), bic: field("bic"), email: field("email"), phone: field("phone"),
        contact_name: field("contact_name"), address: address_input("address"), delivery_addresses: deliveries, extra: extra,
        customer_nature: category.kind == "customer" ? field("customer_nature") : nil,
        pdf_copy: category.kind == "customer" ? checkbox("pdf_copy") : nil,
      ).copy_with(**person_input(category, form_errors))
    end

    # Nature et identité d'un fournisseur ; hors fournisseur, rien (la
    # nature enregistrée est effacée par le cœur).
    private def person_input(category, form_errors)
      supplier = category.kind == "supplier"
      born = nil.as(Time?)
      if supplier && !(text = field("birth_date")).empty?
        born = fmt.parse_date(text)
        form_errors << {"birth_date", I18n.t("ui.forms.invalid_date")} unless born
      end
      {supplier_nature: supplier ? field("supplier_nature") : nil, last_name: supplier ? field("last_name") : nil,
       first_names: supplier ? field("first_names") : nil, birth_date: born}
    end

    private def read_item(category, extra, form_errors) : Partiduo::Api::Cards::CardInput
      Partiduo::Api::Cards::CardInput.new(
        category_id: category.id, name: field("name"), code: field("code").presence,
        description: field("description", strip: false).strip, enabled: checkbox("enabled"),
        unit_code: field("unit_code").presence, sale_price: decimal("sale_price", form_errors),
        purchase_price: decimal("purchase_price", form_errors), vat_rate_id: field("vat_rate_id").to_i64?, extra: extra,
      )
    end

    # Attributs propres de la catégorie : nombre en chaîne décimale,
    # booléen, identifiant de fiche ; un champ vide est omis.
    private def read_extra(category, form_errors) : Hash(String, JSON::Any)
      extra = {} of String => JSON::Any
      category.attributes.each do |attribute|
        name = "extra.#{attribute.key}"
        if attribute.value_type == "boolean"
          extra[attribute.key] = JSON::Any.new(checkbox(name))
          next
        end
        text = field(name)
        next if text.empty?
        extra[attribute.key] = extra_value(attribute.value_type, name, text, form_errors)
      end
      extra
    end

    private def extra_value(value_type : String, name : String, text : String, form_errors) : JSON::Any
      case value_type
      when "number"
        parsed = fmt.parse_decimal(text)
        form_errors << {name, I18n.t("ui.forms.invalid_number")} unless parsed
        JSON::Any.new(parsed.try(&.to_s) || text)
      when "card"
        text.to_i64?.try { |id| JSON::Any.new(id) } || JSON::Any.new(text)
      else
        JSON::Any.new(text)
      end
    end

    private def address_input(prefix : String) : Partiduo::Api::Cards::AddressInput?
      values = %w[line1 line2 postcode city country_code].map { |name| field("#{prefix}.#{name}") }
      return if values.all?(&.empty?)
      Partiduo::Api::Cards::AddressInput.new(line1: values[0], line2: values[1], postcode: values[2], city: values[3],
        country_code: values[4].upcase)
    end

    # Formulaire refusé : champs tels que saisis, erreurs rangées.
    def refused(category, input, categories, form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = card_form(category, input, categories)
      form.fields.each do |item|
        next if item.type == "checkbox" || item.type == "select"
        item.value = field(item.name, strip: item.type != "textarea")
      end
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end

    def category_param(name : String) : Partiduo::Api::Cards::CategoryView?
      id = (field(name).presence || query(name)).to_i64?
      return unless id
      Partiduo::Api::Cards.category(current.actor, id)
    rescue Partiduo::Api::NotFound
      nil
    end
  end

  # Liste des tiers (clients, fournisseurs, banques, salariés, contacts…).
  class CardsHandler < CardScreen
    def get
      list(items: false)
    end

    def list(items : Bool)
      actor = current.actor
      categories = categories_for(items)
      category_id = categories.find(&.id.==(query("category").to_i64?)).try(&.id)
      kinds = categories.map(&.kind).uniq!
      kind = items ? "item" : kinds.find(&.==(query("kind")))
      search = query("q").presence
      card_query = Partiduo::Api::Cards::CardQuery.new(category_id: category_id, kind: kind, search: search,
        enabled: enabled_filter, limit: LIST_LIMIT)
      cards = Partiduo::Api::Cards.cards(actor, card_query).select { |card| card.item? == items }

      params = {"q" => search.to_s, "category" => category_id.to_s, "kind" => items ? "" : kind.to_s, "status" => query("status")}
      params.reject! { |_, value| value.empty? }
      path = reverse(items ? "cards:items" : "cards:index")
      table = items ? items_table(cards, path, params) : parties_table(cards, path, params)

      actions = [] of Screen::Action
      if can?("cards.card.write")
        new_url = "#{reverse("cards:new")}?#{URI::Params.encode({"for" => items ? "items" : "parties"})}"
        actions << link_action(items ? "ui.cards.new_item" : "ui.cards.new_party", new_url, "primary", "plus")
      end
      import_action(category_id).try { |action| actions << action }
      intro = Partiduo::Api::Cards.count_cards(actor, card_query) > LIST_LIMIT ? I18n.t("ui.cards.truncated", count: LIST_LIMIT) : nil
      title = I18n.t(items ? "ui.cards.items" : "ui.cards.parties")
      list_page(title, table, [crumb("core.menu.reference")], items ? "ui.cards.csv_name_items" : "ui.cards.csv_name", actions, tabs(items),
        I18n.t("cards.menu.cards_list"), list_filters(items, categories, category_id, kinds, kind), intro, filter: false)
    end

    # Import CSV (D-OUT-007), dans la catégorie filtrée s'il y en a une.
    private def import_action(category_id : Int64?) : Screen::Action?
      return unless can?(Partiduo::Api::Cards::IMPORT_PERMISSION) && can?("cards.card.write")
      url = reverse("cards:import")
      url = "#{url}?#{URI::Params.encode({"category" => category_id.to_s})}" if category_id
      link_action("ui.imports.import_cards", url, icon: "upload")
    end

    # `status` : actives (défaut), inactives, toutes.
    private def enabled_filter : Bool?
      case query("status")
      when "inactive" then false
      when "all"      then nil
      else                 true
      end
    end

    private def list_filters(items, categories, category_id, kinds, kind) : Form
      filters = [Form::Field.new("q", I18n.t("ui.table.search"), value: query("q"), placeholder: I18n.t("ui.cards.search_placeholder"))]
      filters << Form::Field.new("category", I18n.t("ui.cards.category"), "select", category_id.try(&.to_s) || "",
        options: [option("", I18n.t("ui.cards.all_categories"))] + categories.map { |item| option(item.id.to_s, item.name) })
      unless items
        filters << Form::Field.new("kind", I18n.t("ui.cards.kind"), "select", kind || "",
          options: [option("", I18n.t("ui.cards.all_kinds"))] + kinds.map { |item| option(item, kind_label(item)) })
      end
      filters << Form::Field.new("status", I18n.t("ui.fiscal_years.status"), "select", query("status"), options: [
        option("", I18n.t("ui.cards.active_only")), option("inactive", I18n.t("ui.cards.inactive_only")),
        option("all", I18n.t("ui.cards.all_statuses")),
      ])
      Form.new([Form::Group.new(nil, filters)])
    end

    private def parties_table(cards, path, params) : Table
      columns = [
        Table::Column.new("code", I18n.t("ui.cards.code"), "mono"),
        Table::Column.new("name", I18n.t("ui.cards.name")),
        Table::Column.new("category", I18n.t("ui.cards.category"), secondary: true),
        Table::Column.new("vat_number", I18n.t("ui.cards.vat_number"), "mono", secondary: true),
        Table::Column.new("city", I18n.t("ui.cards.city"), secondary: true),
        Table::Column.new("email", I18n.t("ui.cards.email"), secondary: true),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status")),
      ]
      rows = cards.map do |card|
        Table::Row.new([
          Table::Cell.new(card.code, reverse("cards:show", id: card.id)),
          Table::Cell.new(card.name),
          Table::Cell.new(card.category_name),
          Table::Cell.new(card.vat_number.presence || card.siren),
          Table::Cell.new(card.address.try(&.city) || ""),
          Table::Cell.new(card.email),
          Table::Cell.new(status_label(card.enabled)),
        ], card.enabled ? "" : "pd-row-closed")
      end
      Table.new(I18n.t("ui.cards.parties"), columns, rows, path, params, empty_message: I18n.t("ui.cards.empty"))
    end

    private def items_table(cards, path, params) : Table
      columns = [
        Table::Column.new("code", I18n.t("ui.cards.code"), "mono"),
        Table::Column.new("name", I18n.t("ui.cards.name")),
        Table::Column.new("category", I18n.t("ui.cards.category"), secondary: true),
        Table::Column.new("unit", I18n.t("ui.cards.unit"), secondary: true),
        Table::Column.new("sale_price", I18n.t("ui.cards.sale_price"), "amount"),
        Table::Column.new("purchase_price", I18n.t("ui.cards.purchase_price"), "amount", secondary: true),
        Table::Column.new("vat_rate", I18n.t("ui.cards.vat_rate"), "mono", secondary: true),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status")),
      ]
      rows = cards.map do |card|
        Table::Row.new([
          Table::Cell.new(card.code, reverse("cards:show", id: card.id)),
          Table::Cell.new(card.name),
          Table::Cell.new(card.category_name),
          Table::Cell.new(unit_label(card.unit_code)),
          Table::Cell.new(price(card.sale_price), sort: card.sale_price || BigDecimal.new(-1), csv: fmt.csv_amount(card.sale_price, 4)),
          Table::Cell.new(price(card.purchase_price), sort: card.purchase_price || BigDecimal.new(-1), csv: fmt.csv_amount(card.purchase_price, 4)),
          Table::Cell.new(card.vat_rate_code || ""),
          Table::Cell.new(status_label(card.enabled)),
        ], card.enabled ? "" : "pd-row-closed")
      end
      Table.new(I18n.t("ui.cards.items"), columns, rows, path, params, empty_message: I18n.t("ui.cards.empty_items"))
    end
  end

  # Liste des articles et services (fiches de nature `item`).
  class ItemsHandler < CardsHandler
    def get
      list(items: true)
    end
  end

  # Création : choix de la catégorie (tiers ou articles), puis la fiche.
  class CardNewHandler < CardScreen
    def get
      require!("CARDS", "cards.card.write")
      items = query("for") == "items"
      if category = category_param("category")
        categories = categories_for(category.item?)
        input = Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: "")
        return show(category, card_form(category, input, categories), category.item?)
      end
      show(nil, nil, items)
    end

    def post
      category = category_param("category_id") || raise Partiduo::Api::NotFound.new("category")
      categories = categories_for(category.item?)
      form_errors = [] of {String, String}
      input = read_input(category, form_errors)
      if form_errors.empty?
        result = Partiduo::Api::Cards.create_card(current.actor, input)
        if card = result.value?
          flash["success"] = I18n.t("ui.cards.created", name: card.name, code: card.code)
          return go(reverse("cards:show", id: card.id))
        end
        return show(category, refused(category, input, categories, form_errors, result.errors), category.item?)
      end
      show(category, refused(category, input, categories, form_errors), category.item?)
    end

    private def show(category : Partiduo::Api::Cards::CategoryView?, form : Form?, items : Bool)
      choices = categories_for(items).map { |item| option(item.id.to_s, "#{item.name} (#{kind_label(item.kind)})") }
      unless category
        choices.unshift(option("", I18n.t("ui.cards.choose_category")))
      end
      chooser = Form.new([Form::Group.new(nil, [
        Form::Field.new("category", I18n.t("ui.cards.category"), "select", category.try(&.id.to_s) || "", options: choices),
      ])])
      context["chooser"] = chooser
      context["chooser_title"] = I18n.t("ui.cards.category_step")
      context["chooser_action"] = reverse("cards:new")
      title = I18n.t(items ? "ui.cards.new_item" : "ui.cards.new_party")
      form_page(title, crumbs(items), form, reverse("cards:new"), I18n.t("ui.forms.create"),
        reverse(items ? "cards:items" : "cards:index"))
    end
  end

  # Consultation d'une fiche.
  class CardHandler < CardScreen
    def get
      card = Partiduo::Api::Cards.card(current.actor, id_param)
      sections = [identification(card)]
      sections.concat(card.item? ? [item_section(card)] : party_sections(card))
      sections << attributes_section(card) unless card.extra.empty?
      if module_active?("ACCOUNTING") && can?("accounting.account.read")
        sections << accounting_section(card)
      end
      sections.concat(invoicing_sections(card))

      actions = [] of Screen::Action
      # Navigation transverse (ADR-005 D9) : consultation du tiers.
      if !card.item? && module_active?("ACCOUNTING") && can?("accounting.entry.read")
        actions << link_action("accounting.menu.acc_accounts", "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => card.code})}", icon: "book-open")
      end
      actions.concat(lot6_links(card))
      if can?("cards.card.write")
        actions << link_action("ui.forms.edit", reverse("cards:edit", id: card.id), "primary")
        actions << post_action(card.enabled ? "ui.cards.disable" : "ui.cards.enable", reverse("cards:enable", id: card.id))
        actions << post_action("ui.forms.delete", reverse("cards:delete", id: card.id), "ui.cards.delete_confirm", "danger")
      end
      detail_page(I18n.t("ui.cards.title", code: card.code, name: card.name), crumbs(card.item?), sections, actions,
        status_tag: card.enabled ? nil : I18n.t("ui.forms.inactive"))
    end

    # Réglage client de la Facturation : rythme, encours HT et plafond
    # (DECISIONS D-INV2-004, D-INV2-005).
    private def invoicing_sections(card) : Array(Screen::Section)
      return [] of Screen::Section unless card.kind == "customer" && module_active?("INVOICING") && can?("invoicing.invoice.read")
      [CustomerBillingDisplay.section(self, card, fmt)]
    end

    # Lot 6 : actions de suivi de la fiche, historique de son stock.
    private def lot6_links(card) : Array(Screen::Action)
      links = [] of Screen::Action
      if module_active?("FOLLOWUP") && can?("followup.action.read")
        params = {"card" => card.code, "state" => "all"}
        links << link_action("ui.followup.card_actions", "#{reverse("followup:actions")}?#{URI::Params.encode(params)}")
      end
      if card.item? && module_active?("STOCK") && can?("stock.movement.read")
        Partiduo::Api::Stock.item(current.actor, card.id).try do |item|
          params = {"stock_code" => item.stock_code, "f" => "1"}
          links << link_action("ui.stock.history", "#{reverse("stock:history")}?#{URI::Params.encode(params)}")
        end
      end
      links
    end

    private def identification(card) : Screen::Section
      Screen::Section.new(I18n.t("ui.cards.identification"), [
        Screen::Item.new(I18n.t("ui.cards.code"), card.code, mono: true),
        Screen::Item.new(I18n.t("ui.cards.name"), card.name),
        Screen::Item.new(I18n.t("ui.cards.category"), card.category_name),
        Screen::Item.new(I18n.t("ui.cards.kind"), kind_label(card.kind)),
        Screen::Item.new(I18n.t("ui.cards.description"), card.description),
        Screen::Item.new(I18n.t("ui.cards.created_at"), fmt.date(card.created_at), mono: true),
        Screen::Item.new(I18n.t("ui.cards.updated_at"), fmt.date(card.updated_at), mono: true),
      ])
    end

    private def item_section(card) : Screen::Section
      Screen::Section.new(I18n.t("ui.cards.item_group"), [
        Screen::Item.new(I18n.t("ui.cards.unit"), unit_label(card.unit_code)),
        Screen::Item.new(I18n.t("ui.cards.sale_price"), price(card.sale_price), mono: true),
        Screen::Item.new(I18n.t("ui.cards.purchase_price"), price(card.purchase_price), mono: true),
        Screen::Item.new(I18n.t("ui.cards.vat_rate"), card.vat_rate_code || "", card.vat_rate_id.try { |id| reverse("vat:rate", id: id) }, true),
      ])
    end

    private def party_sections(card) : Array(Screen::Section)
      contact = [
        Screen::Item.new(I18n.t("ui.cards.contact_name"), card.contact_name),
        Screen::Item.new(I18n.t("ui.cards.email"), card.email),
        Screen::Item.new(I18n.t("ui.cards.phone"), card.phone),
        Screen::Item.new(I18n.t("ui.cards.address"), address_text(card.address)),
      ]
      card.delivery_addresses.each { |address| contact << Screen::Item.new(I18n.t("ui.cards.delivery_address"), address_text(address)) }
      if card.kind == "customer"
        nature = card.customer_nature_key.try { |key| I18n.t(key) } ||
                 I18n.t("ui.cards.nature_unset_proposed", {"nature" => I18n.t("cards.natures.#{card.proposed_nature}")})
        contact << Screen::Item.new(I18n.t("ui.cards.nature"), nature)
        contact << Screen::Item.new(I18n.t("ui.cards.pdf_copy"), yes_no(card.pdf_copy))
      end
      if card.kind == "supplier"
        contact << Screen::Item.new(I18n.t("ui.cards.supplier_nature"),
          card.supplier_nature_key.try { |key| I18n.t(key) } || I18n.t("ui.cards.nature_unset"))
        if card.individual_supplier?
          contact << Screen::Item.new(I18n.t("ui.cards.last_name"), card.last_name)
          contact << Screen::Item.new(I18n.t("ui.cards.first_names"), card.first_names)
          contact << Screen::Item.new(I18n.t("ui.cards.birth_date"), fmt.date(card.birth_date), mono: true)
        end
      end
      [
        Screen::Section.new(I18n.t("ui.cards.contact_group"), contact),
        Screen::Section.new(I18n.t("ui.cards.ids_group"), [
          Screen::Item.new(I18n.t("ui.cards.vat_number"), card.vat_number, mono: true),
          Screen::Item.new(I18n.t("ui.cards.siren"), card.siren, mono: true),
          Screen::Item.new(I18n.t("ui.cards.siret"), card.siret, mono: true),
          Screen::Item.new(I18n.t("ui.cards.routing_id"), card.routing_id, mono: true),
          Screen::Item.new(I18n.t("ui.cards.electronic_address"), card.electronic_address || "", mono: true),
          Screen::Item.new(I18n.t("ui.cards.iban"), card.iban, mono: true),
          Screen::Item.new(I18n.t("ui.cards.bic"), card.bic, mono: true),
        ]),
      ]
    end

    private def attributes_section(card) : Screen::Section
      category = Partiduo::Api::Cards.category(current.actor, card.category_id)
      items = category.attributes.compact_map do |attribute|
        value = card.extra[attribute.key]?
        next unless value
        Screen::Item.new(attribute.label, attribute_text(attribute.value_type, value))
      end
      Screen::Section.new(I18n.t("ui.cards.attributes"), items)
    end

    private def attribute_text(value_type : String, value : JSON::Any) : String
      case value_type
      when "boolean" then yes_no(value.as_bool? || false)
      when "number"  then fmt.number(Format.canonical_decimal(json_text(value)), 6)
      when "date"    then fmt.date(fmt.parse_date(json_text(value)))
      else                json_text(value)
      end
    end

    private def accounting_section(card) : Screen::Section
      account = Partiduo::Api::Accounting.card_account(current.actor, card.id).try(&.account)
      return Screen::Section.new(I18n.t("ui.cards.accounting"), note: I18n.t("ui.cards.no_account")) unless account
      Screen::Section.new(I18n.t("ui.cards.accounting"), [
        Screen::Item.new(I18n.t("ui.cards.account"), "#{account.number} — #{account.label}", reverse("accounting:account", id: account.id)),
      ])
    end
  end

  class CardEditHandler < CardScreen
    def get
      require!("CARDS", "cards.card.write")
      card = Partiduo::Api::Cards.card(current.actor, id_param)
      category = Partiduo::Api::Cards.category(current.actor, card.category_id)
      show(card, card_form(category, card.to_input, categories_for(card.item?)))
    end

    def post
      card = Partiduo::Api::Cards.card(current.actor, id_param)
      category = category_param("category_id") || Partiduo::Api::Cards.category(current.actor, card.category_id)
      categories = categories_for(card.item?)
      form_errors = [] of {String, String}
      input = read_input(category, form_errors, card)
      if form_errors.empty?
        result = Partiduo::Api::Cards.update_card(current.actor, card.id, input)
        if updated = result.value?
          flash["success"] = I18n.t("ui.cards.updated", name: updated.name)
          return go(reverse("cards:show", id: updated.id))
        end
        return show(card, refused(category, input, categories, form_errors, result.errors))
      end
      show(card, refused(category, input, categories, form_errors))
    end

    private def show(card : Partiduo::Api::Cards::CardView, form : Form)
      form_page(I18n.t("ui.cards.edit", code: card.code), crumbs(card.item?), form, reverse("cards:edit", id: card.id),
        I18n.t("ui.forms.save"), reverse("cards:show", id: card.id))
    end
  end

  class CardEnableHandler < CardScreen
    def post
      card = Partiduo::Api::Cards.card(current.actor, id_param)
      result = Partiduo::Api::Cards.set_card_enabled(current.actor, card.id, !card.enabled)
      flash_result(result, card.enabled ? "ui.cards.disabled" : "ui.cards.enabled", {"name" => card.name})
      go(reverse("cards:show", id: card.id))
    end
  end

  class CardDeleteHandler < CardScreen
    def post
      card = Partiduo::Api::Cards.card(current.actor, id_param)
      if flash_result(Partiduo::Api::Cards.delete_card(current.actor, card.id), "ui.cards.deleted", {"name" => card.name})
        go(reverse(card.item? ? "cards:items" : "cards:index"))
      else
        go(reverse("cards:show", id: card.id))
      end
    end
  end
end
