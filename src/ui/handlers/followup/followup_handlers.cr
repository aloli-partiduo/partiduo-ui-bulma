# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des écrans du module Suivi (lot 6, `Partiduo::Api::Followup`,
  # successeur de `Follow_Up` et `action_gestion` d'origine) : actions de suivi,
  # rappels, types d'action, étiquettes. Module inactif : le contrat
  # lève `ModuleDisabled`, l'écran répond 404 (D-UI-019).
  #
  # Les fiches (destinataire, contact, fiches concernées) se désignent par
  # leur quick code, résolu par `Api::Cards.card_by_code` (D-UI-046).
  abstract class FupScreen < ReferenceHandler
    # Profil auquel l'action est réservée, ou « tout le monde ».
    def visible_to_label(profile_id : Int64?) : String
      return I18n.t("ui.followup.visible_to_all") unless profile_id
      Fup.visibility_profiles(current.actor).find(&.id.==(profile_id)).try(&.name) || profile_id.to_s
    end

    alias Fup = Partiduo::Api::Followup

    MODULE         = "FOLLOWUP"
    READ           = "followup.action.read"
    WRITE          = "followup.action.write"
    SETTINGS_WRITE = "followup.settings.write"

    # Actions lues pour une liste (le tableau les pagine ensuite).
    LIST_LIMIT = 1_000

    @action_types : Array(Fup::ActionTypeView)?
    @tags : Array(Fup::TagView)?

    def followup_crumbs(label_key : String? = nil, url : String? = nil) : Array(Screen::Crumb)
      crumbs = [crumb("core.menu.follow_up")]
      crumbs << crumb(label_key, url) if label_key
      crumbs
    end

    def action_types : Array(Fup::ActionTypeView)
      @action_types ||= Fup.action_types(current.actor)
    end

    def tags : Array(Fup::TagView)
      @tags ||= Fup.tags(current.actor)
    end

    def action_url(id : Int64) : String
      reverse("followup:action", id: id)
    end

    def card_url(id : Int64) : String
      reverse("cards:show", id: id)
    end

    def state_label(state : String) : String
      I18n.t("followup.states.#{state}")
    end

    def priority_label(priority : Int32) : String
      I18n.t("followup.priorities.p#{priority}")
    end

    def card_label(card : Fup::CardRef?) : String
      card.try { |value| "#{value.code} · #{value.name}" } || ""
    end

    def today : Time
      Partiduo::Api::Core.today
    end

    def parse_day(text : String) : Time?
      fmt.parse_short_date(text, today)
    end

    def iso(day : Time?) : String?
      day.try(&.to_s("%Y-%m-%d"))
    end

    # Opération rattachée (`entry:42`, `invoice:7`) : lien vers sa
    # consultation si le module qui la porte est actif (ADR-006 D2).
    def operation_url(reference : String) : String?
      kind, _, id_text = reference.partition(':')
      id = id_text.to_i64? || return
      case kind
      when "entry"
        module_active?("ACCOUNTING") ? reverse("accounting:entry", id: id) : nil
      when "invoice", "credit_note", "delivery_note", "quote", "order", "document"
        module_active?("INVOICING") ? reverse("invoicing:document", id: id) : nil
      end
    end

    # Tableau d'actions résumées (listes, rappels, fiche d'une opération).
    def actions_table(caption : String, actions : Array(Fup::ActionSummaryView), path : String,
                      params = {} of String => String, id : String = "pd-followup-actions") : Table
      columns = [
        Table::Column.new("reference", I18n.t("followup.columns.reference"), "mono"),
        Table::Column.new("date", I18n.t("followup.columns.date"), "mono"),
        Table::Column.new("type", I18n.t("followup.columns.type"), secondary: true),
        Table::Column.new("title", I18n.t("followup.columns.title")),
        Table::Column.new("card", I18n.t("followup.columns.card")),
        Table::Column.new("state", I18n.t("followup.columns.state")),
        Table::Column.new("remind_on", I18n.t("followup.columns.remind_on"), "mono", secondary: true),
        Table::Column.new("tags", I18n.t("followup.columns.tags"), secondary: true),
      ]
      day = today
      rows = actions.map do |action|
        url = action_url(action.id)
        late = action.open? && (remind = action.remind_on) && remind < day
        date_text = action.hour.empty? ? fmt.date(action.date) : "#{fmt.date(action.date)} #{action.hour}"
        Table::Row.new([
          Table::Cell.new(action.reference, url),
          Table::Cell.new(date_text, sort: "#{date_key(action.date)} #{action.hour}", csv: date_key(action.date)),
          Table::Cell.new(action.action_type_label),
          Table::Cell.new(action.title, url),
          Table::Cell.new(card_label(action.card), action.card.try { |card| card_url(card.id) }),
          Table::Cell.new(state_label(action.state)),
          Table::Cell.new(fmt.date(action.remind_on), sort: date_key(action.remind_on)),
          Table::Cell.new(action.tags.join(", ")),
        ], late ? "pd-row-warning" : (action.open? ? "" : "pd-row-closed"))
      end
      Table.new(caption, columns, rows, path, params, empty_message: I18n.t("ui.followup.no_actions"), id: id)
    end
  end

  # --- Actions ------------------------------------------------------------------------

  # Liste et recherche des actions (`Follow_Up::create_query`) : texte
  # (titre, commentaire, référence), état (ouvertes par défaut), type,
  # étiquette, fiche, dates, actions internes ; export CSV du cœur.
  class FollowupActionsHandler < FupScreen
    def get
      criteria = read_query
      return file(Fup.export_actions(current.actor, criteria)) if csv?
      actions = Fup.actions(current.actor, criteria.copy_with(limit: LIST_LIMIT, offset: 0))
      count = Fup.count_actions(current.actor, criteria)
      params = {} of String => String
      %w[q state type tag card from to internal].each { |name| params[name] = query(name) unless query(name).empty? }
      table = actions_table(I18n.t("followup.menu.fup_actions"), actions, reverse("followup:actions"), params)
      table.exportable = false
      page_actions = [] of Screen::Action
      page_actions << link_action("ui.followup.new_action", reverse("followup:action_new"), "primary", "plus") if can?(WRITE)
      export = params.merge({"format" => "csv"})
      page_actions << Screen::Action.new(I18n.t("ui.table.export_csv"), "#{reverse("followup:actions")}?#{URI::Params.encode(export)}",
        icon: "download")
      page_actions << Screen::Action.new(I18n.t("ui.reports.export_pdf"),
        "#{reverse("followup:actions")}?#{URI::Params.encode(params.merge({"format" => "pdf"}))}", icon: "printer")
      intro = count > LIST_LIMIT ? I18n.t("ui.followup.truncated", {"count" => count.to_s, "limit" => LIST_LIMIT.to_s}) : nil
      list_page(I18n.t("followup.menu.fup_actions"), table, followup_crumbs, "ui.followup.actions_csv", page_actions,
        filters: filters, intro: intro, filter: false)
    end

    private def read_query : Fup::ActionQuery
      state = query("state")
      tag_ids = query("tag").to_i64?.try { |id| [id] } || [] of Int64
      card_id = query("card").presence.try { |code| card_id_of(code) }
      Fup::ActionQuery.new(
        search: query("q").presence,
        card_id: card_id,
        action_type_id: query("type").to_i64?,
        state: Fup::STATES.includes?(state) ? state : nil,
        open_only: state != "all",
        internal_only: query("internal") == "1",
        date_from: query("from").presence.try { |text| parse_day(text) },
        date_to: query("to").presence.try { |text| parse_day(text) },
        tag_ids: tag_ids)
    end

    # Fiche cherchée inconnue : aucune action (identifiant impossible).
    private def card_id_of(code : String) : Int64
      Partiduo::Api::Cards.card_by_code(current.actor, code).try(&.id) || 0_i64
    rescue Partiduo::Api::AccessDenied
      0_i64
    end

    private def filters : Form
      states = [option("", I18n.t("ui.followup.open_states")), option("all", I18n.t("ui.followup.all_states"))] +
               Fup::STATES.map { |state| option(state, state_label(state)) }
      types = [option("", I18n.t("ui.followup.all_types"))] + action_types.map { |type| option(type.id.to_s, "#{type.code} · #{type.label}") }
      tag_options = [option("", I18n.t("ui.followup.all_tags"))] + tags.map { |tag| option(tag.id.to_s, tag.label) }
      search_filters([
        Form::Field.new("state", I18n.t("followup.columns.state"), "select", query("state"), options: states),
        Form::Field.new("type", I18n.t("followup.columns.type"), "select", query("type"), options: types),
        Form::Field.new("tag", I18n.t("followup.columns.tags"), "select", query("tag"), options: tag_options),
        Form::Field.new("card", I18n.t("ui.followup.card_code"), value: query("card"), mono: true),
        Form::Field.new("from", I18n.t("ui.accounts.from"), value: query("from"), mono: true),
        Form::Field.new("to", I18n.t("ui.accounts.to"), value: query("to"), mono: true),
        Form::Field.new("internal", I18n.t("ui.followup.internal_only"), "checkbox", query("internal") == "1" ? "1" : ""),
      ])
    end

    private def file(view : Fup::FileView) : Marten::HTTP::Response
      response = Marten::HTTP::Response.new(content: String.new(view.content), content_type: view.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{view.filename}")
      response
    end
  end

  # Création et modification d'une action (`Follow_Up::save`, `update`).
  abstract class FollowupActionFormScreen < FupScreen
    record Values, type : String, title : String, date : String, hour : String, priority : String, state : String,
      remind_on : String, card : String, contact : String, concerned : String, tag_ids : Array(String), comment : String,
      visible_to : String = ""

    def blank_values : Values
      type = action_types.first?.try(&.id.to_s) || ""
      Values.new(type, "", fmt.date(today), "", "2", "todo", "", query("card"), "", "", [] of String, "")
    end

    def values_of(action : Fup::ActionView) : Values
      Values.new(action.action_type_id.to_s, action.title, fmt.date(action.date), action.hour, action.priority.to_s,
        action.state, fmt.date(action.remind_on), action.card.try(&.code) || "", action.contact.try(&.code) || "",
        action.concerned.map(&.code).join(" "), action.tags.map(&.id.to_s), "", action.visible_profile_id.try(&.to_s) || "")
    end

    def submitted : Values
      Values.new(field("action_type_id"), field("title"), field("date"), field("hour"), field("priority"), field("state"),
        field("remind_on"), field("card"), field("contact"), field("concerned"),
        tags.select { |tag| checkbox("tag-#{tag.id}") }.map(&.id.to_s), field("comment", strip: false).strip,
        field("visible_profile_id"))
    end

    def action_form(values : Values, creating : Bool) : Form
      types = action_types.map { |type| option(type.id.to_s, "#{type.code} · #{type.label}") }
      priorities = Fup::PRIORITIES.map { |priority| option(priority.to_s, priority_label(priority)) }
      states = Fup::STATES.map { |state| option(state, state_label(state)) }
      main = Form::Group.new(nil, [
        Form::Field.new("action_type_id", I18n.t("followup.columns.type"), "select", values.type, options: types, required: true),
        Form::Field.new("title", I18n.t("followup.columns.title"), value: values.title, maxlength: 255, wide: true,
          help: I18n.t("ui.followup.title_help")),
        Form::Field.new("date", I18n.t("followup.columns.date"), value: values.date, required: true, mono: true),
        Form::Field.new("hour", I18n.t("followup.columns.hour"), value: values.hour, mono: true, maxlength: 5, placeholder: I18n.t("ui.followup.hour_placeholder")),
        Form::Field.new("priority", I18n.t("followup.columns.priority"), "select", values.priority, options: priorities),
        Form::Field.new("state", I18n.t("followup.columns.state"), "select", values.state, options: states),
        Form::Field.new("remind_on", I18n.t("followup.columns.remind_on"), value: values.remind_on, mono: true),
        Form::Field.new("visible_profile_id", I18n.t("ui.followup.visible_to"), "select", values.visible_to,
          options: visibility_options, help: I18n.t("ui.followup.visible_to_help")),
      ])
      cards = Form::Group.new(I18n.t("ui.followup.cards_legend"), [
        Form::Field.new("card", I18n.t("followup.columns.card"), value: values.card, mono: true,
          help: I18n.t("ui.followup.card_help")),
        Form::Field.new("contact", I18n.t("ui.followup.contact"), value: values.contact, mono: true),
        Form::Field.new("concerned", I18n.t("ui.followup.concerned"), value: values.concerned, mono: true, wide: true,
          help: I18n.t("ui.followup.concerned_help")),
      ])
      groups = [main, cards]
      unless tags.empty?
        tag_fields = tags.map do |tag|
          Form::Field.new("tag-#{tag.id}", tag.label, "checkbox", values.tag_ids.includes?(tag.id.to_s) ? "1" : "")
        end
        groups << Form::Group.new(I18n.t("followup.columns.tags"), tag_fields)
      end
      groups << Form::Group.new(nil, [
        Form::Field.new("comment", I18n.t(creating ? "ui.followup.first_comment" : "ui.followup.new_comment"), "textarea",
          values.comment, wide: true),
      ])
      Form.new(groups)
    end

    # Visibilité : tout le monde, ou un profil (D-R5-016).
    def visibility_options : Array(Form::Option)
      [option("", I18n.t("ui.followup.visible_to_all"))] +
        Fup.visibility_profiles(current.actor).map { |profile| option(profile.id.to_s, profile.name) }
    end

    # Entrée du contrat, ou `nil` et des erreurs de formulaire (dates,
    # fiches inconnues).
    def read_input(values : Values, errors : Array({String, String})) : Fup::ActionInput?
      type_id = values.type.to_i64?
      errors << {"action_type_id", I18n.t("ui.forms.required")} unless type_id
      day = parse_day(values.date)
      errors << {"date", I18n.t("ui.forms.invalid_date")} unless day
      remind = nil
      unless values.remind_on.empty?
        remind = parse_day(values.remind_on)
        errors << {"remind_on", I18n.t("ui.forms.invalid_date")} unless remind
      end
      card_id = card_of("card", values.card, errors)
      contact_id = card_of("contact", values.contact, errors)
      concerned = values.concerned.split(/[\s,;]+/, remove_empty: true).compact_map { |code| card_of("concerned", code, errors) }
      return unless type_id && day && errors.empty?
      Fup::ActionInput.new(action_type_id: type_id, date: day, title: values.title, hour: values.hour,
        priority: values.priority.to_i? || 2, state: values.state, remind_on: remind, card_id: card_id,
        contact_card_id: contact_id, concerned_card_ids: concerned.uniq, tag_ids: values.tag_ids.compact_map(&.to_i64?),
        comment: values.comment, visible_profile_id: values.visible_to.to_i64?)
    end

    private def card_of(name : String, code : String, errors : Array({String, String})) : Int64?
      return if code.empty?
      found = begin
        Partiduo::Api::Cards.card_by_code(current.actor, code)
      rescue Partiduo::Api::AccessDenied
        nil
      end
      errors << {name, I18n.t("ui.followup.card_unknown", code: code)} unless found
      found.try(&.id)
    end

    # Erreurs du contrat : `concerned_card_ids[i]` → champ des fiches
    # concernées, `tag_ids[i]` → ensemble du formulaire.
    def add_contract_errors(form : Form, errors : Array(Partiduo::Api::FieldError)) : Form
      errors.each do |error|
        name = error.field
        name = "concerned" if name.starts_with?("concerned_card_ids")
        name = "card" if name == "card_id"
        name = "contact" if name == "contact_card_id"
        form.add_error(name, fmt.message(error))
      end
      form
    end

    def form_errors(form : Form, errors : Array({String, String})) : Form
      errors.each { |(name, message)| form.add_error(name, message) }
      form
    end

    def intro : String?
      action_types.empty? ? I18n.t("ui.followup.no_types") : nil
    end
  end

  class FollowupActionNewHandler < FollowupActionFormScreen
    def get
      require!(MODULE, WRITE)
      show(action_form(blank_values, true))
    end

    def post
      require!(MODULE, WRITE)
      values = submitted
      errors = [] of {String, String}
      input = read_input(values, errors)
      return show(form_errors(action_form(values, true), errors)) unless input
      result = Fup.create_action(current.actor, input)
      if action = result.value?
        flash["success"] = I18n.t("ui.followup.action_created", reference: action.reference)
        return go(action_url(action.id))
      end
      show(add_contract_errors(action_form(values, true), result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.followup.new_action"), followup_crumbs("followup.menu.fup_actions", reverse("followup:actions")), form,
        reverse("followup:action_new"), I18n.t("ui.forms.create"), reverse("followup:actions"), intro: intro)
    end
  end

  class FollowupActionEditHandler < FollowupActionFormScreen
    def get
      require!(MODULE, WRITE)
      action = Fup.action(current.actor, id_param)
      show(action, action_form(values_of(action), false))
    end

    def post
      require!(MODULE, WRITE)
      action = Fup.action(current.actor, id_param)
      values = submitted
      errors = [] of {String, String}
      input = read_input(values, errors)
      return show(action, form_errors(action_form(values, false), errors)) unless input
      result = Fup.update_action(current.actor, action.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.followup.action_updated", reference: updated.reference)
        return go(action_url(updated.id))
      end
      show(action, add_contract_errors(action_form(values, false), result.errors))
    end

    private def show(action : Fup::ActionView, form : Form)
      form_page(I18n.t("ui.followup.edit_action", reference: action.reference),
        followup_crumbs("followup.menu.fup_actions", reverse("followup:actions")), form,
        reverse("followup:action_edit", id: action.id), I18n.t("ui.forms.save"), action_url(action.id))
    end
  end

  # Consultation d'une action : résumé, fiches, étiquettes, commentaires
  # (formulaire d'ajout), actions liées, opérations rattachées ; boutons de
  # changement d'état.
  class FollowupActionHandler < FupScreen
    def get
      action = Fup.action(current.actor, id_param)
      writable = can?(WRITE)
      actions = [] of Screen::Action
      if writable
        actions << link_action("ui.forms.edit", reverse("followup:action_edit", id: action.id), "primary")
        next_states = action.open? ? %w[closed abandoned] : %w[todo]
        next_states.each do |state|
          url = "#{reverse("followup:action_state", id: action.id)}?#{URI::Params.encode({"state" => state})}"
          actions << Screen::Action.new(I18n.t("ui.followup.set_state.#{state}"), url, "post")
        end
        actions << post_action("ui.forms.delete", reverse("followup:action_delete", id: action.id),
          "ui.followup.delete_confirm", "danger")
      end
      items = [
        Screen::Item.new(I18n.t("followup.columns.reference"), action.reference, mono: true),
        Screen::Item.new(I18n.t("followup.columns.type"), "#{action.action_type_code} · #{action.action_type_label}"),
        Screen::Item.new(I18n.t("followup.columns.date"), [fmt.date(action.date), action.hour].reject(&.empty?).join(" "), mono: true),
        Screen::Item.new(I18n.t("followup.columns.priority"), priority_label(action.priority)),
        Screen::Item.new(I18n.t("followup.columns.state"), state_label(action.state)),
        Screen::Item.new(I18n.t("followup.columns.remind_on"), fmt.date(action.remind_on), mono: true),
        Screen::Item.new(I18n.t("followup.columns.card"), action.internal? ? I18n.t("ui.followup.internal") : card_label(action.card),
          action.card.try { |card| card_url(card.id) }),
        Screen::Item.new(I18n.t("ui.followup.contact"), card_label(action.contact), action.contact.try { |card| card_url(card.id) }),
        Screen::Item.new(I18n.t("followup.columns.tags"), action.tags.map(&.label).join(", ")),
        Screen::Item.new(I18n.t("ui.followup.visible_to"), visible_to_label(action.visible_profile_id)),
        Screen::Item.new(I18n.t("ui.followup.updated_at"), fmt.datetime(action.updated_at), mono: true),
      ]
      sections = [Screen::Section.new(I18n.t("ui.followup.summary"), items)]
      unless action.concerned.empty?
        sections << Screen::Section.new(I18n.t("ui.followup.concerned"),
          action.concerned.map { |card| Screen::Item.new(card.code, card.name, card_url(card.id)) })
      end
      sections << comments_section(action)
      sections << related_section(action, writable)
      sections << links_section(action, writable)
      if writable
        set_form(Form.new([Form::Group.new(nil, [Form::Field.new("text", I18n.t("ui.followup.new_comment"), "textarea", "", wide: true)])]),
          reverse("followup:action_comment", id: action.id), I18n.t("ui.followup.add_comment"))
      end
      status = action.open? ? nil : state_label(action.state)
      title = action.title.empty? ? action.reference : "#{action.reference} · #{action.title}"
      detail_page(title, followup_crumbs("followup.menu.fup_actions", reverse("followup:actions")), sections, actions,
        status_tag: status)
    end

    private def comments_section(action : Fup::ActionView) : Screen::Section
      columns = [
        Table::Column.new("created_at", I18n.t("ui.followup.written_at"), "mono"),
        Table::Column.new("text", I18n.t("ui.followup.comment")),
      ]
      rows = action.comments.map do |comment|
        Table::Row.new([Table::Cell.new(fmt.datetime(comment.created_at), sort: comment.created_at.to_rfc3339), Table::Cell.new(comment.text)])
      end
      table = Table.new(I18n.t("ui.followup.comments"), columns, rows, action_url(action.id),
        empty_message: I18n.t("ui.followup.no_comments"), id: "pd-followup-comments")
      table.exportable = false
      Screen::Section.new(I18n.t("ui.followup.comments"), table: table)
    end

    private def related_section(action : Fup::ActionView, writable : Bool) : Screen::Section
      columns = [
        Table::Column.new("reference", I18n.t("followup.columns.reference"), "mono"),
        Table::Column.new("date", I18n.t("followup.columns.date"), "mono"),
        Table::Column.new("title", I18n.t("followup.columns.title")),
        Table::Column.new("state", I18n.t("followup.columns.state")),
      ]
      columns << Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions") if writable
      rows = action.related.map do |other|
        cells = [
          Table::Cell.new(other.reference, action_url(other.id)),
          Table::Cell.new(fmt.date(other.date), sort: date_key(other.date)),
          Table::Cell.new(other.title),
          Table::Cell.new(state_label(other.state)),
        ]
        if writable
          cells << Table::Cell.new("", actions: [post_action("ui.followup.unrelate",
            reverse("followup:action_unrelate", id: action.id, other_id: other.id), nil, "small")])
        end
        Table::Row.new(cells)
      end
      table = Table.new(I18n.t("ui.followup.related"), columns, rows, action_url(action.id),
        empty_message: I18n.t("ui.followup.no_related"), id: "pd-followup-related")
      table.exportable = false
      actions = writable ? [link_action("ui.followup.relate", reverse("followup:action_relate", id: action.id), "small", "plus")] : nil
      Screen::Section.new(I18n.t("ui.followup.related"), table: table, actions: actions)
    end

    private def links_section(action : Fup::ActionView, writable : Bool) : Screen::Section
      columns = [Table::Column.new("reference", I18n.t("ui.followup.operation"), "mono")]
      columns << Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions") if writable
      rows = action.links.map do |reference|
        cells = [Table::Cell.new(reference, operation_url(reference))]
        if writable
          url = "#{reverse("followup:action_unlink", id: action.id)}?#{URI::Params.encode({"reference" => reference})}"
          cells << Table::Cell.new("", actions: [post_action("ui.followup.unlink", url, nil, "small")])
        end
        Table::Row.new(cells)
      end
      table = Table.new(I18n.t("ui.followup.links"), columns, rows, action_url(action.id),
        empty_message: I18n.t("ui.followup.no_links"), id: "pd-followup-links")
      table.exportable = false
      actions = writable ? [link_action("ui.followup.link", reverse("followup:action_link", id: action.id), "small", "plus")] : nil
      Screen::Section.new(I18n.t("ui.followup.links"), table: table, actions: actions)
    end
  end

  class FollowupActionDeleteHandler < FupScreen
    def post
      action = Fup.action(current.actor, id_param)
      if flash_result(Fup.delete_action(current.actor, action.id), "ui.followup.action_deleted", {"reference" => action.reference})
        return go(reverse("followup:actions"))
      end
      go(action_url(action.id))
    end
  end

  # Changement d'état (`action_set_state`) : `state` en paramètre.
  class FollowupActionStateHandler < FupScreen
    def post
      id = id_param
      state = field("state").presence || query("state")
      result = Fup.set_state(current.actor, id, state)
      if result.success?
        flash["success"] = I18n.t("ui.followup.state_saved", state: state_label(state))
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(action_url(id))
    end
  end

  class FollowupActionCommentHandler < FupScreen
    def post
      id = id_param
      result = Fup.add_comment(current.actor, id, field("text", strip: false))
      if result.success?
        flash["success"] = I18n.t("ui.followup.comment_added")
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      go(action_url(id))
    end
  end

  # Lier une autre action, désignée par sa référence (`DI-12`).
  class FollowupActionRelateHandler < FupScreen
    def get
      require!(MODULE, WRITE)
      action = Fup.action(current.actor, id_param)
      show(action, relate_form(""))
    end

    def post
      require!(MODULE, WRITE)
      action = Fup.action(current.actor, id_param)
      other = Fup.action_by_reference(current.actor, field("reference"))
      unless other
        form = relate_form(field("reference"))
        form.add_error("reference", I18n.t("ui.followup.reference_unknown", reference: field("reference")))
        return show(action, form)
      end
      result = Fup.relate(current.actor, action.id, other.id)
      if result.success?
        flash["success"] = I18n.t("ui.followup.related_saved", reference: other.reference)
        return go(action_url(action.id))
      end
      form = relate_form(field("reference"))
      result.errors.each { |error| form.add_error("reference", fmt.message(error)) }
      show(action, form)
    end

    private def relate_form(value : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("reference", I18n.t("followup.columns.reference"), value: value, required: true, mono: true,
          help: I18n.t("ui.followup.reference_help")),
      ])])
    end

    private def show(action : Fup::ActionView, form : Form)
      form_page(I18n.t("ui.followup.relate_title", reference: action.reference),
        followup_crumbs("followup.menu.fup_actions", reverse("followup:actions")), form,
        reverse("followup:action_relate", id: action.id), I18n.t("ui.followup.relate"), action_url(action.id))
    end
  end

  class FollowupActionUnrelateHandler < FupScreen
    def post
      id = id_param
      flash_result(Fup.unrelate(current.actor, id, id_param("other_id")), "ui.followup.unrelated")
      go(action_url(id))
    end
  end

  # Rattacher une opération d'un module par sa référence (`entry:42`).
  class FollowupActionLinkHandler < FupScreen
    def get
      require!(MODULE, WRITE)
      action = Fup.action(current.actor, id_param)
      show(action, link_form(query("reference")))
    end

    def post
      require!(MODULE, WRITE)
      action = Fup.action(current.actor, id_param)
      result = Fup.link(current.actor, action.id, field("reference"))
      if result.success?
        flash["success"] = I18n.t("ui.followup.link_saved")
        return go(action_url(action.id))
      end
      form = link_form(field("reference"))
      result.errors.each { |error| form.add_error("reference", fmt.message(error)) }
      show(action, form)
    end

    private def link_form(value : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("reference", I18n.t("ui.followup.operation"), value: value, required: true, mono: true,
          help: I18n.t("ui.followup.operation_help")),
      ])])
    end

    private def show(action : Fup::ActionView, form : Form)
      form_page(I18n.t("ui.followup.link_title", reference: action.reference),
        followup_crumbs("followup.menu.fup_actions", reverse("followup:actions")), form,
        reverse("followup:action_link", id: action.id), I18n.t("ui.followup.link"), action_url(action.id))
    end
  end

  class FollowupActionUnlinkHandler < FupScreen
    def post
      id = id_param
      reference = field("reference").presence || query("reference")
      flash_result(Fup.unlink(current.actor, id, reference), "ui.followup.unlinked")
      go(action_url(id))
    end
  end

  # Rappels (`get_today`, `get_late`) : actions ouvertes dont le rappel
  # tombe aujourd'hui, ou est dépassé.
  class FollowupRemindersHandler < FupScreen
    def get
      view = Fup.reminders(current.actor, today)
      path = reverse("followup:reminders")
      today_table = actions_table(I18n.t("ui.followup.reminders_today"), view.today, path, id: "pd-followup-today")
      late_table = actions_table(I18n.t("ui.followup.reminders_late"), view.late, path, id: "pd-followup-late")
      [today_table, late_table].each(&.exportable=(false))
      sections = [
        Screen::Section.new(I18n.t("ui.followup.reminders_today"), table: today_table),
        Screen::Section.new(I18n.t("ui.followup.reminders_late"), table: late_table),
      ]
      actions = [] of Screen::Action
      actions << link_action("ui.followup.new_action", reverse("followup:action_new"), "primary", "plus") if can?(WRITE)
      detail_page(I18n.t("followup.menu.fup_reminders"), followup_crumbs, sections, actions,
        intro: I18n.t("ui.followup.reminders_intro", date: fmt.date(today)))
    end
  end

  # --- Types d'action -------------------------------------------------------------------

  abstract class FollowupTypeScreen < FupScreen
    def crumbs : Array(Screen::Crumb)
      followup_crumbs("followup.menu.fup_types", reverse("followup:types"))
    end

    def type_form(code : String, label : String, next_number : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("code", I18n.t("ui.followup.type_code"), value: code, required: true, mono: true, maxlength: 10,
          help: I18n.t("ui.followup.type_code_help")),
        Form::Field.new("label", I18n.t("ui.followup.type_label"), value: label, required: true, maxlength: 80, wide: true),
        Form::Field.new("next_number", I18n.t("ui.followup.next_number"), "number", next_number, mono: true,
          help: I18n.t("ui.followup.next_number_help")),
      ])])
    end

    # Entrée lue ; prochain numéro illisible : erreur sous le champ.
    def read_type(errors : Array({String, String})) : Fup::ActionTypeInput
      number = integer("next_number", errors, required: false)
      Fup::ActionTypeInput.new(field("code"), field("label"), number)
    end

    def form_errors(form : Form, errors : Array({String, String}), contract = [] of Partiduo::Api::FieldError) : Form
      errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(contract, fmt)
    end
  end

  class FollowupTypesHandler < FollowupTypeScreen
    def get
      writable = can?(SETTINGS_WRITE)
      columns = [
        Table::Column.new("code", I18n.t("ui.followup.type_code"), "mono"),
        Table::Column.new("label", I18n.t("ui.followup.type_label")),
        Table::Column.new("next_number", I18n.t("ui.followup.next_number"), "amount", secondary: true),
        Table::Column.new("count", I18n.t("ui.followup.actions_count"), "amount"),
      ]
      rows = action_types.map do |type|
        url = writable ? reverse("followup:type_edit", id: type.id) : nil
        count_url = "#{reverse("followup:actions")}?#{URI::Params.encode({"type" => type.id.to_s, "state" => "all"})}"
        Table::Row.new([
          Table::Cell.new(type.code, url),
          Table::Cell.new(type.label, url),
          Table::Cell.new(type.next_number.to_s, sort: BigDecimal.new(type.next_number)),
          Table::Cell.new(type.actions_count.to_s, type.actions_count.zero? ? nil : count_url, sort: BigDecimal.new(type.actions_count)),
        ])
      end
      table = Table.new(I18n.t("followup.menu.fup_types"), columns, rows, reverse("followup:types"),
        empty_message: I18n.t("ui.followup.no_types"))
      actions = [] of Screen::Action
      if writable
        actions << link_action("ui.followup.new_type", reverse("followup:type_new"), "primary", "plus")
        actions << post_action("ui.followup.load_default_types", reverse("followup:types_defaults"))
      end
      list_page(I18n.t("followup.menu.fup_types"), table, followup_crumbs, "ui.followup.types_csv", actions,
        intro: I18n.t("ui.followup.types_intro"))
    end
  end

  class FollowupTypeNewHandler < FollowupTypeScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      show(type_form("", "", "1"))
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      errors = [] of {String, String}
      input = read_type(errors)
      form = type_form(field("code"), field("label"), field("next_number"))
      return show(form_errors(form, errors)) unless errors.empty?
      result = Fup.create_action_type(current.actor, input)
      if type = result.value?
        flash["success"] = I18n.t("ui.followup.type_saved", code: type.code)
        return go(reverse("followup:types"))
      end
      show(form_errors(form, errors, result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.followup.new_type"), crumbs, form, reverse("followup:type_new"), I18n.t("ui.forms.create"),
        reverse("followup:types"))
    end
  end

  class FollowupTypeEditHandler < FollowupTypeScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      type = Fup.action_type(current.actor, id_param)
      show(type, type_form(type.code, type.label, type.next_number.to_s))
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      type = Fup.action_type(current.actor, id_param)
      errors = [] of {String, String}
      input = read_type(errors)
      form = type_form(field("code"), field("label"), field("next_number"))
      return show(type, form_errors(form, errors)) unless errors.empty?
      result = Fup.update_action_type(current.actor, type.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.followup.type_saved", code: updated.code)
        return go(reverse("followup:types"))
      end
      show(type, form_errors(form, errors, result.errors))
    end

    private def show(type : Fup::ActionTypeView, form : Form)
      actions = [post_action("ui.forms.delete", reverse("followup:type_delete", id: type.id), "ui.followup.type_delete_confirm", "danger")]
      form_page(I18n.t("ui.followup.edit_type", code: type.code), crumbs, form, reverse("followup:type_edit", id: type.id),
        I18n.t("ui.forms.save"), reverse("followup:types"), actions, intro: I18n.t("ui.followup.type_edit_intro"))
    end
  end

  class FollowupTypeDeleteHandler < FollowupTypeScreen
    def post
      type = Fup.action_type(current.actor, id_param)
      if flash_result(Fup.delete_action_type(current.actor, type.id), "ui.followup.type_deleted", {"code" => type.code})
        return go(reverse("followup:types"))
      end
      go(reverse("followup:type_edit", id: type.id))
    end
  end

  # Types d'action par défaut (repris de l'application d'origine), dans la
  # langue de l'utilisateur.
  class FollowupTypesDefaultsHandler < FollowupTypeScreen
    def post
      created = Fup.load_default_action_types(current.actor, I18n.locale)
      flash["success"] = I18n.t("ui.followup.default_types_loaded", {"count" => created.size.to_s})
      go(reverse("followup:types"))
    end
  end

  # --- Étiquettes ------------------------------------------------------------------------

  abstract class FollowupTagScreen < FupScreen
    COLORS = (1..10).to_a

    def crumbs : Array(Screen::Crumb)
      followup_crumbs("followup.menu.fup_tags", reverse("followup:tags"))
    end

    def tag_form(label : String, description : String, active : Bool, color : String) : Form
      colors = COLORS.map { |number| option(number.to_s, I18n.t("ui.followup.color", number: number)) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("label", I18n.t("ui.followup.tag_label"), value: label, required: true, maxlength: 60, wide: true),
        Form::Field.new("description", I18n.t("ui.followup.tag_description"), "textarea", description, wide: true),
        Form::Field.new("color", I18n.t("ui.followup.tag_color"), "select", color, options: colors),
        Form::Field.new("active", I18n.t("ui.followup.tag_active"), "checkbox", active ? "1" : ""),
      ])])
    end

    def read_tag : Fup::TagInput
      Fup::TagInput.new(field("label"), field("description", strip: false).strip, checkbox("active"), field("color").to_i? || 1)
    end

    def submitted_form : Form
      tag_form(field("label"), field("description", strip: false).strip, checkbox("active"), field("color"))
    end
  end

  class FollowupTagsHandler < FollowupTagScreen
    def get
      writable = can?(SETTINGS_WRITE)
      columns = [
        Table::Column.new("label", I18n.t("ui.followup.tag_label")),
        Table::Column.new("description", I18n.t("ui.followup.tag_description"), secondary: true),
        Table::Column.new("color", I18n.t("ui.followup.tag_color"), "amount", secondary: true),
        Table::Column.new("active", I18n.t("ui.followup.tag_active")),
      ]
      rows = tags.map do |tag|
        url = writable ? reverse("followup:tag_edit", id: tag.id) : nil
        Table::Row.new([
          Table::Cell.new(tag.label, url),
          Table::Cell.new(tag.description),
          Table::Cell.new(tag.color.to_s, sort: BigDecimal.new(tag.color)),
          Table::Cell.new(yes_no(tag.active)),
        ], tag.active ? "" : "pd-row-closed")
      end
      table = Table.new(I18n.t("followup.menu.fup_tags"), columns, rows, reverse("followup:tags"),
        empty_message: I18n.t("ui.followup.no_tags"))
      actions = [] of Screen::Action
      actions << link_action("ui.followup.new_tag", reverse("followup:tag_new"), "primary", "plus") if writable
      list_page(I18n.t("followup.menu.fup_tags"), table, followup_crumbs, "ui.followup.tags_csv", actions)
    end
  end

  class FollowupTagNewHandler < FollowupTagScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      show(tag_form("", "", true, "1"))
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      result = Fup.create_tag(current.actor, read_tag)
      if tag = result.value?
        flash["success"] = I18n.t("ui.followup.tag_saved", label: tag.label)
        return go(reverse("followup:tags"))
      end
      show(submitted_form.add_errors(result.errors, fmt))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.followup.new_tag"), crumbs, form, reverse("followup:tag_new"), I18n.t("ui.forms.create"),
        reverse("followup:tags"))
    end
  end

  class FollowupTagEditHandler < FollowupTagScreen
    def get
      require!(MODULE, SETTINGS_WRITE)
      tag = find_tag
      show(tag, tag_form(tag.label, tag.description, tag.active, tag.color.to_s))
    end

    def post
      require!(MODULE, SETTINGS_WRITE)
      tag = find_tag
      result = Fup.update_tag(current.actor, tag.id, read_tag)
      if updated = result.value?
        flash["success"] = I18n.t("ui.followup.tag_saved", label: updated.label)
        return go(reverse("followup:tags"))
      end
      show(tag, submitted_form.add_errors(result.errors, fmt))
    end

    private def find_tag : Fup::TagView
      tags.find(&.id.==(id_param)) || raise Partiduo::Api::NotFound.new("followup_tag", id_param)
    end

    private def show(tag : Fup::TagView, form : Form)
      actions = [post_action("ui.forms.delete", reverse("followup:tag_delete", id: tag.id), "ui.followup.tag_delete_confirm", "danger")]
      form_page(I18n.t("ui.followup.edit_tag", label: tag.label), crumbs, form, reverse("followup:tag_edit", id: tag.id),
        I18n.t("ui.forms.save"), reverse("followup:tags"), actions)
    end
  end

  class FollowupTagDeleteHandler < FollowupTagScreen
    def post
      tag = tags.find(&.id.==(id_param)) || raise Partiduo::Api::NotFound.new("followup_tag", id_param)
      flash_result(Fup.delete_tag(current.actor, tag.id), "ui.followup.tag_deleted", {"label" => tag.label})
      go(reverse("followup:tags"))
    end
  end
end

module PartiduoUi
  # Actions de suivi qui citent une opération (`Follow_Up::get_all_operation`,
  # `actions_linked_to`) : rubrique ajoutée à la consultation d'une
  # écriture quand le Suivi est actif et lisible ; `nil` sinon, ou si aucune
  # action ne la cite (D-UI-046).
  module FollowupLinkedSection
    alias Fup = Partiduo::Api::Followup

    def self.build(handler : ScreenHandler, reference : String) : Screen::Section?
      return unless handler.module_active?("FOLLOWUP") && handler.can?(Fup::READ)
      actions = Fup.actions_linked_to(handler.current.actor, reference)
      return if actions.empty?
      fmt = handler.fmt
      columns = [
        Table::Column.new("reference", I18n.t("followup.columns.reference"), "mono"),
        Table::Column.new("date", I18n.t("followup.columns.date"), "mono"),
        Table::Column.new("title", I18n.t("followup.columns.title")),
        Table::Column.new("state", I18n.t("followup.columns.state")),
      ]
      rows = actions.map do |action|
        url = handler.reverse("followup:action", id: action.id)
        Table::Row.new([
          Table::Cell.new(action.reference, url),
          Table::Cell.new(fmt.date(action.date), sort: action.date.to_s("%Y-%m-%d")),
          Table::Cell.new(action.title, url),
          Table::Cell.new(I18n.t(action.state_key)),
        ])
      end
      table = Table.new(I18n.t("ui.followup.card_actions"), columns, rows, handler.request.path, id: "pd-followup-linked")
      table.exportable = false
      Screen::Section.new(I18n.t("ui.followup.card_actions"), table: table)
    end
  end
end
