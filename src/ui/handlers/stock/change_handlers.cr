# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Opérations manuelles et inventaires (menus `stock:changes`,
  # `stock:inventory`, successeurs de `stock_inv.inc.php`,
  # `stock_inv_histo.inc.php` et `Stock_Goods`) : liste, consultation,
  # saisie de mouvements, inventaire compté, suppression.
  abstract class StockChangeScreen < StockScreen
    def crumbs : Array(Screen::Crumb)
      stock_crumbs("stock.menu.stock_changes", reverse("stock:changes"), "core.menu.entry")
    end

    # Ligne saisie : article (fiche), quantité signée, coût unitaire.
    record LineValues, card : String, quantity : String, unit_cost : String

    def blank_line : LineValues
      LineValues.new("", "", "")
    end

    def header_fields(repository : String, date : String, comment : String) : Array(Form::Field)
      [
        Form::Field.new("repository_id", I18n.t("ui.stock.repository"), "select", repository, options: repository_options,
          required: true),
        Form::Field.new("date", I18n.t("ui.stock.date"), value: date, required: true, mono: true),
        Form::Field.new("comment", I18n.t("ui.stock.comment"), value: comment, maxlength: 1000, wide: true),
      ]
    end

    def change_form(repository : String, date : String, comment : String, lines : Array(LineValues)) : Form
      groups = [Form::Group.new(nil, header_fields(repository, date, comment))]
      (lines + Array.new(SPARE_ROWS) { blank_line }).each_with_index do |line, index|
        prefix = "lines-#{index}"
        groups << Form::Group.new(I18n.t("ui.stock.line_number", number: index + 1), [
          Form::Field.new("#{prefix}-card_id", I18n.t("ui.stock.item"), "select", line.card, options: item_options),
          Form::Field.new("#{prefix}-quantity", I18n.t("ui.stock.signed_quantity"), "number", line.quantity, mono: true,
            help: index.zero? ? I18n.t("ui.stock.signed_quantity_help") : nil),
          Form::Field.new("#{prefix}-unit_cost", I18n.t("ui.stock.unit_cost"), "number", line.unit_cost, mono: true),
        ])
      end
      Form.new(groups)
    end

    # Opération relue : entrée du contrat (`nil` si un champ est illisible)
    # et valeurs à réafficher (lignes vides ignorées, compactées).
    def read_change(form_errors : Array({String, String})) : {Stk::ChangeInput?, Array(LineValues)}
      values = [] of LineValues
      inputs = [] of Stk::ChangeLineInput
      row_indices("lines").each do |index|
        line = read_line("lines-#{index}", values, form_errors)
        inputs << line if line
      end
      repository_id = field("repository_id").to_i64?
      form_errors << {"repository_id", I18n.t("ui.forms.required")} unless repository_id
      day = parse_day(field("date"))
      form_errors << {"date", I18n.t("ui.forms.invalid_date")} unless day
      return {nil, values} unless repository_id && day && form_errors.empty?
      {Stk::ChangeInput.new(repository_id: repository_id, date: day, lines: inputs, comment: field("comment")), values}
    end

    # Ligne `prefix` : ignorée si vide ; sinon ajoutée à `values` (position
    # compactée, reprise par les erreurs) et lue si ses champs sont lisibles.
    private def read_line(prefix : String, values : Array(LineValues), form_errors : Array({String, String})) : Stk::ChangeLineInput?
      card, text, cost = field("#{prefix}-card_id"), field("#{prefix}-quantity"), field("#{prefix}-unit_cost")
      return if card.empty? && text.empty? && cost.empty?
      position = values.size
      values << LineValues.new(card, text, cost)
      errors = [] of {String, String}
      card_id = card.to_i64?
      errors << {"#{prefix}-card_id", I18n.t("ui.forms.required")} unless card_id
      amount = decimal("#{prefix}-quantity", errors, required: true)
      unit_cost = decimal("#{prefix}-unit_cost", errors)
      errors.each { |(name, message)| form_errors << {name.sub(prefix, "lines-#{position}"), message} }
      Stk::ChangeLineInput.new(card_id, amount, unit_cost) if card_id && amount
    end
  end

  class StockChangesHandler < StockChangeScreen
    def get
      from = query("from").presence.try { |text| parse_day(text) }
      to = query("to").presence.try { |text| parse_day(text) }
      kind = Stk::CHANGE_KINDS.find(&.==(query("kind")))
      criteria = Stk::ChangeQuery.new(repository_id: query("repository").to_i64?, date_from: from, date_to: to, kind: kind)
      changes = Stk.changes(current.actor, criteria).reverse
      columns = [
        Table::Column.new("date", I18n.t("ui.stock.date"), "mono"),
        Table::Column.new("kind", I18n.t("ui.stock.kind")),
        Table::Column.new("repository", I18n.t("ui.stock.repository")),
        Table::Column.new("comment", I18n.t("ui.stock.comment")),
        Table::Column.new("movements", I18n.t("ui.stock.movements_count"), "amount", secondary: true),
      ]
      rows = changes.map do |change|
        url = change_url(change.id)
        Table::Row.new([
          Table::Cell.new(fmt.date(change.date), url, sort: date_key(change.date)),
          Table::Cell.new(kind_label(change.kind), url),
          Table::Cell.new(change.repository_name),
          Table::Cell.new(change.comment),
          Table::Cell.new(change.movements.size.to_s, sort: BigDecimal.new(change.movements.size)),
        ])
      end
      params = {} of String => String
      %w[from to kind repository].each { |name| params[name] = query(name) unless query(name).empty? }
      table = Table.new(I18n.t("stock.menu.stock_changes"), columns, rows, reverse("stock:changes"), params,
        empty_message: I18n.t("ui.stock.no_changes"))
      actions = [] of Screen::Action
      if can?(WRITE)
        actions << link_action("ui.stock.new_change", reverse("stock:change_new"), "primary", "plus")
        actions << link_action("stock.menu.stock_inventory", reverse("stock:inventory"))
      end
      kinds = [option("", I18n.t("ui.stock.all_kinds")), option("change", I18n.t("ui.stock.kind_change")),
               option("inventory", I18n.t("ui.stock.kind_inventory"))]
      filters = search_filters([
        Form::Field.new("repository", I18n.t("ui.stock.repository"), "select", query("repository"),
          options: repository_options(I18n.t("ui.stock.all_repositories"))),
        Form::Field.new("kind", I18n.t("ui.stock.kind"), "select", query("kind"), options: kinds),
        Form::Field.new("from", I18n.t("ui.accounts.from"), value: query("from"), mono: true),
        Form::Field.new("to", I18n.t("ui.accounts.to"), value: query("to"), mono: true),
      ])
      list_page(I18n.t("stock.menu.stock_changes"), table, stock_crumbs(parent: "core.menu.entry"), "ui.stock.changes_csv",
        actions, filters: filters, intro: I18n.t("ui.stock.changes_intro"))
    end
  end

  class StockChangeNewHandler < StockChangeScreen
    def get
      require!(MODULE, WRITE)
      show(change_form(default_repository_id.to_s, fmt.date(today), "", [] of LineValues))
    end

    def post
      # Droit vérifié avant la lecture du formulaire : un refus de saisie
      # (422) ne doit pas masquer l'absence de permission (403).
      require!(MODULE, WRITE)
      form_errors = [] of {String, String}
      input, values = read_change(form_errors)
      unless input
        return show(refused(values, form_errors))
      end
      result = Stk.record_change(current.actor, input)
      if change = result.value?
        flash["success"] = I18n.t("ui.stock.change_recorded", {"count" => change.movements.size.to_s})
        return go(change_url(change.id))
      end
      show(refused(values, form_errors, result.errors))
    end

    private def refused(values : Array(LineValues), form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = change_form(field("repository_id"), field("date"), field("comment"), values)
      form_errors.each { |(name, message)| form.add_error(name, message) }
      add_contract_errors(form, errors)
    end

    private def show(form : Form)
      intro = items.empty? ? I18n.t("ui.stock.no_items") : (repositories.empty? ? I18n.t("ui.stock.no_repositories") : I18n.t("ui.stock.change_help"))
      form_page(I18n.t("ui.stock.new_change"), crumbs, form, reverse("stock:change_new"), I18n.t("ui.forms.save"),
        reverse("stock:changes"), intro: intro)
    end
  end

  class StockChangeHandler < StockChangeScreen
    def get
      change = Stk.change(current.actor, id_param)
      actions = [] of Screen::Action
      if can?(WRITE)
        actions << post_action("ui.forms.delete", reverse("stock:change_delete", id: change.id), "ui.stock.change_delete_confirm", "danger")
      end
      items = [
        Screen::Item.new(I18n.t("ui.stock.kind"), kind_label(change.kind)),
        Screen::Item.new(I18n.t("ui.stock.repository"), change.repository_name, repository_url(change.repository_id)),
        Screen::Item.new(I18n.t("ui.stock.date"), fmt.date(change.date), mono: true),
        Screen::Item.new(I18n.t("ui.stock.comment"), change.comment),
        Screen::Item.new(I18n.t("ui.stock.recorded_at"), fmt.datetime(change.created_at), mono: true),
      ]
      sections = [
        Screen::Section.new(I18n.t("ui.stock.summary"), items),
        Screen::Section.new(I18n.t("ui.stock.movements"), table: movements_table(change),
          note: change.movements.empty? ? I18n.t("ui.stock.no_difference") : nil),
      ]
      detail_page(I18n.t("ui.stock.change_title", kind: kind_label(change.kind), date: fmt.date(change.date)), crumbs, sections, actions)
    end

    private def movements_table(change : Stk::ChangeView) : Table
      columns = [
        Table::Column.new("stock_code", I18n.t("ui.stock.stock_code"), "mono"),
        Table::Column.new("card", I18n.t("ui.stock.card"), "mono"),
        Table::Column.new("name", I18n.t("ui.stock.card_name")),
        Table::Column.new("direction", I18n.t("ui.stock.direction")),
        Table::Column.new("quantity", I18n.t("ui.stock.quantity"), "amount"),
        Table::Column.new("unit_cost", I18n.t("ui.stock.unit_cost"), "amount"),
      ]
      rows = change.movements.map do |movement|
        Table::Row.new([
          Table::Cell.new(movement.stock_code, history_url(movement.stock_code, movement.repository_id)),
          Table::Cell.new(movement.card_code, card_url(movement.card_id)),
          Table::Cell.new(movement.card_name),
          Table::Cell.new(direction_label(movement.direction)),
          quantity_cell(movement.quantity),
          Table::Cell.new(movement.unit_cost.try { |cost| fmt.number(cost) } || "", sort: movement.unit_cost || BigDecimal.new(0)),
        ])
      end
      table = Table.new(I18n.t("ui.stock.movements"), columns, rows, change_url(change.id), id: "pd-stock-change")
      table.exportable = false
      table
    end
  end

  class StockChangeDeleteHandler < StockChangeScreen
    def post
      change = Stk.change(current.actor, id_param)
      result = Stk.delete_change(current.actor, change.id)
      if result.success?
        flash["success"] = I18n.t("ui.stock.change_deleted")
        go(reverse("stock:changes"))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
        go(change_url(change.id))
      end
    end
  end

  # Inventaire compté (`take_last_inventory`, `Stock_Goods::input`) : on
  # choisit le dépôt et la date, le cœur propose la quantité théorique de
  # chaque code stock suivi, on saisit la quantité comptée ; l'écart devient
  # un mouvement. Deux temps dans le même écran : « Préparer » (quantités
  # proposées), puis « Enregistrer l'inventaire ».
  class StockInventoryHandler < StockChangeScreen
    def crumbs : Array(Screen::Crumb)
      stock_crumbs("stock.menu.stock_inventory", reverse("stock:inventory"), "core.menu.entry")
    end

    def get
      require!(MODULE, WRITE)
      repository = query("repository").presence || default_repository_id.to_s
      date = query("date").presence || fmt.date(today)
      show(prepare_form(repository, date, ""), false)
    end

    def post
      require!(MODULE, WRITE)
      form_errors = [] of {String, String}
      repository_id = field("repository_id").to_i64?
      form_errors << {"repository_id", I18n.t("ui.forms.required")} unless repository_id
      day = parse_day(field("date"))
      form_errors << {"date", I18n.t("ui.forms.invalid_date")} unless day
      unless repository_id && day
        form = prepare_form(field("repository_id"), field("date"), field("comment"))
        form_errors.each { |(name, message)| form.add_error(name, message) }
        return show(form, false)
      end
      # Dépôt ou date changés depuis la préparation : nouvelle proposition.
      prepared = field("prepared") == "#{repository_id}/#{iso(day)}"
      proposal = Stk.inventory_proposal(current.actor, repository_id, day)
      return show(inventory_form(repository_id, day, proposal, nil), true) unless prepared
      input = read_inventory(repository_id, day, proposal, form_errors)
      unless form_errors.empty?
        return show(refused(repository_id, day, proposal, form_errors), true)
      end
      result = Stk.record_inventory(current.actor, input)
      if change = result.value?
        flash["success"] = I18n.t("ui.stock.inventory_recorded", {"count" => change.movements.size.to_s})
        return go(change_url(change.id))
      end
      show(refused(repository_id, day, proposal, form_errors, result.errors), true)
    end

    private def prepare_form(repository : String, date : String, comment : String) : Form
      Form.new([Form::Group.new(nil, header_fields(repository, date, comment))])
    end

    # Une rubrique par code stock : quantité théorique (légende), quantité
    # comptée (préremplie : la quantité théorique, sauf si elle est négative
    # — la ligne reste alors vide, le cœur refusant un compte négatif),
    # coût unitaire d'une entrée. Les lignes laissées vides ne sont pas
    # envoyées au cœur.
    private def inventory_form(repository_id : Int64, day : Time, proposal : Array(Stk::InventoryLineView),
                               values : Hash(Int64, {String, String})?) : Form
      groups = [Form::Group.new(nil, header_fields(repository_id.to_s, fmt.date(day), field("comment")) +
                                     [Form::Field.new("prepared", "", "hidden", "#{repository_id}/#{iso(day)}")])]
      proposal.each_with_index do |line, index|
        prefix = "lines-#{index}"
        counted, cost = values.try(&.[line.card_id]?) || {line.quantity < 0 ? "" : input_quantity(line.quantity), ""}
        legend = I18n.t("ui.stock.inventory_line", code: line.stock_code, name: line.card_name, quantity: quantity(line.quantity))
        groups << Form::Group.new(legend, [
          Form::Field.new("#{prefix}-card_id", "", "hidden", line.card_id.to_s),
          Form::Field.new("#{prefix}-counted", I18n.t("ui.stock.counted"), "number", counted, mono: true),
          Form::Field.new("#{prefix}-unit_cost", I18n.t("ui.stock.unit_cost"), "number", cost, mono: true),
        ])
      end
      Form.new(groups)
    end

    # Lignes envoyées au cœur, dans l'ordre : fiche de la proposition et
    # quantité comptée non vide. `read_inventory` et `refused` partagent ce
    # filtre, pour que `lines[i]` désigne la même ligne des deux côtés.
    private def sent_rows(proposal : Array(Stk::InventoryLineView)) : Array({String, Int64})
      known = proposal.map(&.card_id).to_set
      rows = [] of {String, Int64}
      row_indices("lines").each do |index|
        prefix = "lines-#{index}"
        card_id = field("#{prefix}-card_id").to_i64? || next
        next unless known.includes?(card_id)
        next if field("#{prefix}-counted").empty?
        rows << {prefix, card_id}
      end
      rows
    end

    private def read_inventory(repository_id : Int64, day : Time, proposal : Array(Stk::InventoryLineView),
                               form_errors : Array({String, String})) : Stk::InventoryInput
      lines = [] of Stk::InventoryLineInput
      sent_rows(proposal).each do |(prefix, card_id)|
        counted = decimal("#{prefix}-counted", form_errors, required: true)
        unit_cost = decimal("#{prefix}-unit_cost", form_errors)
        lines << Stk::InventoryLineInput.new(card_id, counted, unit_cost) if counted
      end
      Stk::InventoryInput.new(repository_id: repository_id, date: day, lines: lines, comment: field("comment"))
    end

    # Formulaire réaffiché avec les valeurs saisies ; erreurs du contrat
    # (`lines[i]` = i-ième ligne envoyée) rangées sous la ligne affichée de
    # la même fiche.
    private def refused(repository_id : Int64, day : Time, proposal : Array(Stk::InventoryLineView),
                        form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      values = {} of Int64 => {String, String}
      row_indices("lines").each do |index|
        prefix = "lines-#{index}"
        card_id = field("#{prefix}-card_id").to_i64? || next
        values[card_id] = {field("#{prefix}-counted"), field("#{prefix}-unit_cost")}
      end
      sent = sent_rows(proposal)
      form = inventory_form(repository_id, day, proposal, values)
      form_errors.each { |(name, message)| form.add_error(name, message) }
      errors.each do |error|
        name = error_field(error.field)
        if match = name.match(/\Alines-(\d+)-(.+)\z/)
          card_id = sent[match[1].to_i]?.try(&.[1])
          index = card_id.try { |id| proposal.index { |line| line.card_id == id } } || match[1].to_i
          name = "lines-#{index}-#{match[2] == "card_id" ? "counted" : match[2]}"
        end
        form.add_error(name, fmt.message(error))
      end
      form
    end

    private def show(form : Form, prepared : Bool)
      intro = if repositories.empty?
                I18n.t("ui.stock.no_repositories")
              elsif prepared
                I18n.t("ui.stock.inventory_help")
              else
                I18n.t("ui.stock.inventory_intro")
              end
      submit = prepared ? I18n.t("ui.stock.record_inventory") : I18n.t("ui.stock.prepare_inventory")
      form_page(I18n.t("stock.menu.stock_inventory"), crumbs, form, reverse("stock:inventory"), submit,
        reverse("stock:changes"), intro: intro)
    end
  end
end
