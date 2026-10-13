# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Prévisions budgétaires (lot 6, menu `accounting:forecasts`, successeur
  # d'`Anticipation` et de `forecast.inc.php` de l'application d'origine) :
  # liste, création, modification, copie, suppression ; catégories et
  # éléments (formule du réel, montant estimé par période) ; comparaison de
  # l'estimé et du réel. Tout calcul vient de `Partiduo::Api::Accounting`
  # (`forecast_report`) ; les formules sont contrôlées par le cœur, jamais
  # par l'interface (D-UI-045).
  abstract class ForecastScreen < ReportScreen
    def screen_code : String
      "forecast"
    end

    def filter_names : Array(String)
      [] of String
    end

    def reports_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.reports"), crumb("accounting.menu.acc_forecasts", reverse("accounting:forecasts"))]
    end

    def forecast_url(id : Int64) : String
      reverse("accounting:forecast", id: id)
    end

    def writable? : Bool
      can?(Acc::REPORT_WRITE)
    end

    def require_write! : Nil
      require!("ACCOUNTING", Acc::REPORT_WRITE)
    end

    # Montant saisi (quatre décimales au plus, contrôlées par le cœur).
    def amount_text(value : BigDecimal) : String
      value.zero? ? "" : fmt.input_number(value, 4)
    end

    def decimal_or_zero(name : String, errors : Array({String, String})) : BigDecimal
      decimal(name, errors) || BigDecimal.new(0)
    end

    # Chemin d'erreur du contrat → champ : `period_amounts[2].amount` →
    # champ de la période correspondante (`period-<id>`).
    def add_contract_errors(form : Form, errors : Array(Partiduo::Api::FieldError),
                            period_ids : Array(Int64) = [] of Int64) : Form
      errors.each do |error|
        name = error.field
        if match = name.match(/\Aperiod_amounts\[(\d+)\]/)
          name = period_ids[match[1].to_i]?.try { |id| "period-#{id}" } || Partiduo::Api::FieldError::BASE
        end
        form.add_error(name, fmt.message(error))
      end
      form
    end

    def form_errors(form : Form, errors : Array({String, String})) : Form
      errors.each { |(name, message)| form.add_error(name, message) }
      form
    end

    def period_label(period : Partiduo::Api::Core::PeriodView) : String
      "#{fmt.period(period.starts_on, period.ends_on)} (#{period.fiscal_year_label})"
    end
  end

  # Liste des prévisions.
  class ForecastsHandler < ForecastScreen
    def report : Marten::HTTP::Response
      writable = writable?
      columns = [
        column("name", "ui.forecasts.name", sortable: true),
        column("starts_on", "ui.forecasts.starts_on", "mono", sortable: true),
        column("ends_on", "ui.forecasts.ends_on", "mono", sortable: true),
      ]
      columns << Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions") if writable
      rows = Acc.forecasts(current.actor).map do |forecast|
        cells = [
          Table::Cell.new(forecast.name, forecast_url(forecast.id)),
          date_cell(forecast.starts_on),
          date_cell(forecast.ends_on),
        ]
        if writable
          cells << Table::Cell.new("", actions: [
            link_action("ui.forecasts.compare", reverse("accounting:forecast_report", id: forecast.id), "small"),
            link_action("ui.forms.edit", reverse("accounting:forecast_edit", id: forecast.id), "small"),
          ])
        end
        Table::Row.new(cells)
      end
      table = Table.new(I18n.t("accounting.menu.acc_forecasts"), columns, rows, request.path,
        empty_message: I18n.t("ui.forecasts.none"), id: "pd-forecasts")
      actions = [] of Screen::Action
      actions << link_action("ui.forecasts.new", reverse("accounting:forecast_new"), "primary", "plus") if writable
      list_page(I18n.t("accounting.menu.acc_forecasts"), table, [crumb("core.menu.reports")], "ui.forecasts.csv_name", actions,
        intro: I18n.t("ui.forecasts.intro"))
    end
  end

  # Création et modification d'une prévision : nom, première et dernière
  # périodes.
  abstract class ForecastFormHandler < ForecastScreen
    abstract def existing : Acc::ForecastSummaryView?
    abstract def save(input : Acc::ForecastInput) : Partiduo::Api::Result(Acc::ForecastView)
    abstract def form_title : String
    abstract def action_url : String

    def report : Marten::HTTP::Response
      require_write!
      forecast = existing
      show(build_form(forecast.try(&.name) || "", forecast.try(&.start_period_id.to_s) || default_start,
        forecast.try(&.end_period_id.to_s) || default_end))
    end

    def post
      require_write!
      form = build_form(field("name"), field("start_period_id"), field("end_period_id"))
      start_id = field("start_period_id").to_i64?
      end_id = field("end_period_id").to_i64?
      form.add_error("start_period_id", I18n.t("ui.forms.required")) unless start_id
      form.add_error("end_period_id", I18n.t("ui.forms.required")) unless end_id
      return show(form) unless start_id && end_id
      result = save(Acc::ForecastInput.new(field("name"), start_id, end_id))
      if saved = result.value?
        flash["success"] = I18n.t("ui.forecasts.saved", name: saved.name)
        return go(forecast_url(saved.id))
      end
      show(add_contract_errors(form, result.errors))
    end

    private def periods : Array(Partiduo::Api::Core::PeriodView)
      @periods ||= Partiduo::Api::Core.periods(current.actor)
    end

    @periods : Array(Partiduo::Api::Core::PeriodView)?

    # Par défaut : l'exercice de la période de travail.
    private def default_start : String
      year_periods.first?.try(&.id.to_s) || ""
    end

    private def default_end : String
      year_periods.last?.try(&.id.to_s) || ""
    end

    private def year_periods : Array(Partiduo::Api::Core::PeriodView)
      year = working_period.try(&.fiscal_year_id) || return [] of Partiduo::Api::Core::PeriodView
      periods.select { |period| period.fiscal_year_id == year && period.starts_on != period.ends_on }
    end

    private def build_form(name : String, start : String, finish : String) : Form
      options = [option("", I18n.t("ui.forecasts.choose_period"))] + periods.map { |period| option(period.id.to_s, period_label(period)) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.forecasts.name"), value: name, required: true, maxlength: 255, wide: true),
        Form::Field.new("start_period_id", I18n.t("ui.forecasts.start_period"), "select", start, options: options, required: true),
        Form::Field.new("end_period_id", I18n.t("ui.forecasts.end_period"), "select", finish, options: options, required: true,
          help: I18n.t("ui.forecasts.periods_help")),
      ])])
    end

    private def show(form : Form) : Marten::HTTP::Response
      form_page(form_title, reports_crumbs, form, action_url, I18n.t("ui.forms.save"), reverse("accounting:forecasts"))
    end
  end

  class ForecastNewHandler < ForecastFormHandler
    def existing : Acc::ForecastSummaryView?
      nil
    end

    def save(input : Acc::ForecastInput) : Partiduo::Api::Result(Acc::ForecastView)
      Acc.create_forecast(current.actor, input)
    end

    def form_title : String
      I18n.t("ui.forecasts.new")
    end

    def action_url : String
      reverse("accounting:forecast_new")
    end
  end

  class ForecastEditHandler < ForecastFormHandler
    def existing : Acc::ForecastSummaryView?
      Acc.forecast(current.actor, id_param).forecast
    end

    def save(input : Acc::ForecastInput) : Partiduo::Api::Result(Acc::ForecastView)
      Acc.update_forecast(current.actor, id_param, input)
    end

    def form_title : String
      I18n.t("ui.forecasts.edit", name: Acc.forecast(current.actor, id_param).name)
    end

    def action_url : String
      reverse("accounting:forecast_edit", id: id_param)
    end
  end

  # Une prévision : ses catégories et leurs éléments.
  class ForecastHandler < ForecastScreen
    def report : Marten::HTTP::Response
      view = Acc.forecast(current.actor, id_param)
      writable = writable?
      actions = [link_action("ui.forecasts.compare", reverse("accounting:forecast_report", id: view.id), "primary")]
      if writable
        actions << link_action("ui.forecasts.new_category", reverse("accounting:forecast_category_new", id: view.id), icon: "plus")
        actions << link_action("ui.forms.edit", reverse("accounting:forecast_edit", id: view.id))
        actions << link_action("ui.forecasts.clone", reverse("accounting:forecast_clone", id: view.id))
        actions << post_action("ui.forms.delete", reverse("accounting:forecast_delete", id: view.id), "ui.forecasts.delete_confirm", "danger")
      end
      summary = [
        Screen::Item.new(I18n.t("ui.forecasts.starts_on"), fmt.date(view.forecast.starts_on), mono: true),
        Screen::Item.new(I18n.t("ui.forecasts.ends_on"), fmt.date(view.forecast.ends_on), mono: true),
      ]
      sections = [Screen::Section.new(I18n.t("ui.forecasts.summary"), summary)]
      view.categories.each { |category| sections << category_section(view.id, category, writable) }
      intro = view.categories.empty? ? I18n.t("ui.forecasts.no_categories") : nil
      detail_page(view.name, reports_crumbs, sections, actions, intro: intro)
    end

    private def category_section(forecast_id : Int64, category : Acc::ForecastCategoryView, writable : Bool) : Screen::Section
      columns = [
        column("label", "ui.forecasts.label"),
        column("formula", "ui.forecasts.formula", "mono"),
        column("nature", "ui.forecasts.nature", secondary: true),
        column("amount", "ui.forecasts.amount", "amount"),
        column("initial", "ui.forecasts.initial_amount", "amount", secondary: true),
        column("overrides", "ui.forecasts.period_amounts", "amount", secondary: true),
      ]
      columns << Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions") if writable
      rows = category.items.map do |item|
        cells = [
          Table::Cell.new(item.label, writable ? reverse("accounting:forecast_item_edit", id: forecast_id, item_id: item.id) : nil),
          Table::Cell.new(item.formula),
          Table::Cell.new(I18n.t("accounting.forecast_natures.#{item.nature}")),
          total_cell(item.amount),
          amount_cell(item.initial_amount),
          Table::Cell.new(item.period_amounts.empty? ? "" : item.period_amounts.size.to_s),
        ]
        if writable
          cells << Table::Cell.new("", actions: [
            link_action("ui.forms.edit", reverse("accounting:forecast_item_edit", id: forecast_id, item_id: item.id), "small"),
            post_action("ui.forms.delete", reverse("accounting:forecast_item_delete", id: forecast_id, item_id: item.id), "ui.forecasts.item_delete_confirm", "small"),
          ])
        end
        Table::Row.new(cells)
      end
      table = Table.new(category.label, columns, rows, request.path, empty_message: I18n.t("ui.forecasts.no_items"),
        id: "pd-forecast-category-#{category.id}")
      table.exportable = false
      actions = nil
      if writable
        actions = [
          link_action("ui.forecasts.new_item", reverse("accounting:forecast_item_new", id: forecast_id, category_id: category.id), "small", "plus"),
          link_action("ui.forms.edit", reverse("accounting:forecast_category_edit", id: forecast_id, category_id: category.id), "small"),
          post_action("ui.forms.delete", reverse("accounting:forecast_category_delete", id: forecast_id, category_id: category.id),
            "ui.forecasts.category_delete_confirm", "small"),
        ]
      end
      Screen::Section.new(category.label, table: table, actions: actions)
    end
  end

  class ForecastDeleteHandler < ForecastScreen
    def report : Marten::HTTP::Response
      go(forecast_url(id_param))
    end

    def post
      view = Acc.forecast(current.actor, id_param)
      if flash_result(Acc.delete_forecast(current.actor, view.id), "ui.forecasts.deleted", {"name" => view.name})
        return go(reverse("accounting:forecasts"))
      end
      go(forecast_url(view.id))
    end
  end

  # Copie d'une prévision sous un autre nom.
  class ForecastCloneHandler < ForecastScreen
    def report : Marten::HTTP::Response
      require_write!
      view = Acc.forecast(current.actor, id_param)
      show(view, clone_form(I18n.t("ui.forecasts.copy_name", name: view.name)))
    end

    def post
      require_write!
      view = Acc.forecast(current.actor, id_param)
      result = Acc.clone_forecast(current.actor, view.id, field("name"))
      if copy = result.value?
        flash["success"] = I18n.t("ui.forecasts.cloned", name: copy.name)
        return go(forecast_url(copy.id))
      end
      show(view, add_contract_errors(clone_form(field("name")), result.errors))
    end

    private def clone_form(name : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.forecasts.name"), value: name, required: true, maxlength: 255, wide: true),
      ])])
    end

    private def show(view : Acc::ForecastView, form : Form) : Marten::HTTP::Response
      form_page(I18n.t("ui.forecasts.clone_title", name: view.name), reports_crumbs, form,
        reverse("accounting:forecast_clone", id: view.id), I18n.t("ui.forecasts.clone"), forecast_url(view.id))
    end
  end

  # Catégories : création (dans une prévision), modification, suppression.
  abstract class ForecastCategoryFormHandler < ForecastScreen
    abstract def forecast : Acc::ForecastView
    abstract def existing : Acc::ForecastCategoryView?
    abstract def save(input : Acc::ForecastCategoryInput) : Partiduo::Api::Result(Acc::ForecastCategoryView)
    abstract def action_url : String

    def report : Marten::HTTP::Response
      require_write!
      category = existing
      position = category.try(&.position) || (forecast.categories.max_of?(&.position) || 0) + 10
      show(build_form(category.try(&.label) || "", position.to_s))
    end

    def post
      require_write!
      errors = [] of {String, String}
      position = integer("position", errors, required: false) || 0
      form = build_form(field("label"), field("position"))
      return show(form_errors(form, errors)) unless errors.empty?
      result = save(Acc::ForecastCategoryInput.new(field("label"), position))
      if result.success?
        flash["success"] = I18n.t("ui.forecasts.category_saved")
        return go(forecast_url(forecast.id))
      end
      show(add_contract_errors(form, result.errors))
    end

    private def build_form(label : String, position : String) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("label", I18n.t("ui.forecasts.label"), value: label, required: true, maxlength: 255, wide: true),
        Form::Field.new("position", I18n.t("ui.forecasts.position"), "number", position, mono: true,
          help: I18n.t("ui.forecasts.position_help")),
      ])])
    end

    private def show(form : Form) : Marten::HTTP::Response
      title = existing ? I18n.t("ui.forecasts.edit_category") : I18n.t("ui.forecasts.new_category")
      form_page(title, reports_crumbs + [Screen::Crumb.new(forecast.name, forecast_url(forecast.id))], form, action_url,
        I18n.t("ui.forms.save"), forecast_url(forecast.id))
    end
  end

  class ForecastCategoryNewHandler < ForecastCategoryFormHandler
    @forecast : Acc::ForecastView?

    def forecast : Acc::ForecastView
      @forecast ||= Acc.forecast(current.actor, id_param)
    end

    def existing : Acc::ForecastCategoryView?
      nil
    end

    def save(input : Acc::ForecastCategoryInput) : Partiduo::Api::Result(Acc::ForecastCategoryView)
      Acc.create_forecast_category(current.actor, forecast.id, input)
    end

    def action_url : String
      reverse("accounting:forecast_category_new", id: forecast.id)
    end
  end

  # Catégorie ou élément d'une prévision (`/forecasts/<id>/categories/<category_id>`,
  # `/forecasts/<id>/items/<item_id>`) : retrouvé dans la prévision lue
  # par le contrat ; absent de cette prévision : 404.
  module ForecastLookup
    alias Acc = Partiduo::Api::Accounting

    def forecast_of_category(actor : Partiduo::Api::Actor, id : Int64, category_id : Int64) : {Acc::ForecastView, Acc::ForecastCategoryView}
      view = Acc.forecast(actor, id)
      category = view.categories.find(&.id.==(category_id)) || raise Partiduo::Api::NotFound.new("forecast_category", category_id)
      {view, category}
    end

    def forecast_of_item(actor : Partiduo::Api::Actor, id : Int64, item_id : Int64) : {Acc::ForecastView, Acc::ForecastCategoryView, Acc::ForecastItemView}
      view = Acc.forecast(actor, id)
      view.categories.each do |category|
        item = category.items.find(&.id.==(item_id))
        return {view, category, item} if item
      end
      raise Partiduo::Api::NotFound.new("forecast_item", item_id)
    end
  end

  class ForecastCategoryEditHandler < ForecastCategoryFormHandler
    include ForecastLookup

    @found : {Acc::ForecastView, Acc::ForecastCategoryView}?

    private def found : {Acc::ForecastView, Acc::ForecastCategoryView}
      @found ||= forecast_of_category(current.actor, id_param, id_param("category_id"))
    end

    def forecast : Acc::ForecastView
      found[0]
    end

    def existing : Acc::ForecastCategoryView?
      found[1]
    end

    def save(input : Acc::ForecastCategoryInput) : Partiduo::Api::Result(Acc::ForecastCategoryView)
      Acc.update_forecast_category(current.actor, found[1].id, input)
    end

    def action_url : String
      reverse("accounting:forecast_category_edit", id: forecast.id, category_id: found[1].id)
    end
  end

  class ForecastCategoryDeleteHandler < ForecastScreen
    include ForecastLookup

    def report : Marten::HTTP::Response
      go(reverse("accounting:forecasts"))
    end

    def post
      view, category = forecast_of_category(current.actor, id_param, id_param("category_id"))
      flash_result(Acc.delete_forecast_category(current.actor, category.id), "ui.forecasts.category_deleted")
      go(forecast_url(view.id))
    end
  end

  # Éléments : libellé, formule du réel, montant estimé de chaque période,
  # montant initial, rang, et montant propre à certaines périodes (champ
  # `period-<id>`, vide : montant de l'élément).
  abstract class ForecastItemFormHandler < ForecastScreen
    abstract def forecast : Acc::ForecastView
    abstract def category : Acc::ForecastCategoryView
    abstract def existing : Acc::ForecastItemView?
    abstract def save(input : Acc::ForecastItemInput) : Partiduo::Api::Result(Acc::ForecastItemView)
    abstract def action_url : String

    @periods : Array(Partiduo::Api::Core::PeriodView)?

    # Périodes de la prévision : celles comprises entre le début de la
    # première et la fin de la dernière (même filtre que le cœur).
    def periods : Array(Partiduo::Api::Core::PeriodView)
      @periods ||= Partiduo::Api::Core.periods(current.actor).select do |period|
        period.starts_on >= forecast.forecast.starts_on && period.ends_on <= forecast.forecast.ends_on
      end
    end

    def report : Marten::HTTP::Response
      require_write!
      item = existing
      overrides = item.try(&.period_amounts.to_h { |row| {row.period_id, amount_text(row.amount)} }) || {} of Int64 => String
      position = item.try(&.position) || (category.items.max_of?(&.position) || 0) + 10
      show(build_form(item.try(&.label) || "", item.try(&.formula) || "", item.try { |value| amount_text(value.amount) } || "",
        item.try { |value| amount_text(value.initial_amount) } || "", position.to_s, overrides, item.try(&.nature) || ""))
    end

    def post
      require_write!
      errors = [] of {String, String}
      amount = decimal_or_zero("amount", errors)
      initial = decimal_or_zero("initial_amount", errors)
      position = integer("position", errors, required: false) || 0
      overrides = {} of Int64 => String
      rows = [] of Acc::ForecastPeriodAmountInput
      sent = [] of Int64
      periods.each do |period|
        text = field("period-#{period.id}")
        overrides[period.id] = text
        next if text.empty?
        value = decimal("period-#{period.id}", errors)
        next unless value
        rows << Acc::ForecastPeriodAmountInput.new(period.id, value)
        sent << period.id
      end
      form = build_form(field("label"), field("formula"), field("amount"), field("initial_amount"), field("position"), overrides,
        field("nature"))
      return show(form_errors(form, errors)) unless errors.empty?
      # Nature vide : déduite de la formule par le cœur (nouvel élément),
      # gardée (élément existant).
      input = Acc::ForecastItemInput.new(label: field("label"), formula: field("formula"), amount: amount,
        initial_amount: initial, position: position, period_amounts: rows, nature: field("nature").presence)
      result = save(input)
      if result.success?
        flash["success"] = I18n.t("ui.forecasts.item_saved")
        return go(forecast_url(forecast.id))
      end
      show(add_contract_errors(form, result.errors, sent))
    end

    private def build_form(label : String, formula : String, amount : String, initial : String, position : String,
                           overrides : Hash(Int64, String), nature : String = "") : Form
      natures = [option("", I18n.t("ui.forecasts.nature_auto"))] +
                Acc::FORECAST_NATURES.map { |code| option(code, I18n.t("accounting.forecast_natures.#{code}")) }
      main = Form::Group.new(nil, [
        Form::Field.new("label", I18n.t("ui.forecasts.label"), value: label, required: true, maxlength: 255, wide: true),
        Form::Field.new("formula", I18n.t("ui.forecasts.formula"), value: formula, mono: true, wide: true,
          help: I18n.t("ui.forecasts.formula_help")),
        Form::Field.new("nature", I18n.t("ui.forecasts.nature"), "select", nature, options: natures,
          help: I18n.t("ui.forecasts.nature_help")),
        Form::Field.new("amount", I18n.t("ui.forecasts.amount"), "number", amount, mono: true, help: I18n.t("ui.forecasts.amount_help")),
        Form::Field.new("initial_amount", I18n.t("ui.forecasts.initial_amount"), "number", initial, mono: true,
          help: I18n.t("ui.forecasts.initial_amount_help")),
        Form::Field.new("position", I18n.t("ui.forecasts.position"), "number", position, mono: true),
      ])
      period_fields = periods.map do |period|
        Form::Field.new("period-#{period.id}", fmt.period(period.starts_on, period.ends_on), "number",
          overrides[period.id]? || "", mono: true)
      end
      groups = [main]
      groups << Form::Group.new(I18n.t("ui.forecasts.period_amounts_legend"), period_fields) unless period_fields.empty?
      Form.new(groups)
    end

    private def show(form : Form) : Marten::HTTP::Response
      title = existing ? I18n.t("ui.forecasts.edit_item") : I18n.t("ui.forecasts.new_item")
      form_page(title, reports_crumbs + [Screen::Crumb.new(forecast.name, forecast_url(forecast.id))], form, action_url,
        I18n.t("ui.forms.save"), forecast_url(forecast.id), intro: I18n.t("ui.forecasts.item_intro", category: category.label))
    end
  end

  class ForecastItemNewHandler < ForecastItemFormHandler
    include ForecastLookup

    @found : {Acc::ForecastView, Acc::ForecastCategoryView}?

    private def found : {Acc::ForecastView, Acc::ForecastCategoryView}
      @found ||= forecast_of_category(current.actor, id_param, id_param("category_id"))
    end

    def forecast : Acc::ForecastView
      found[0]
    end

    def category : Acc::ForecastCategoryView
      found[1]
    end

    def existing : Acc::ForecastItemView?
      nil
    end

    def save(input : Acc::ForecastItemInput) : Partiduo::Api::Result(Acc::ForecastItemView)
      Acc.create_forecast_item(current.actor, category.id, input)
    end

    def action_url : String
      reverse("accounting:forecast_item_new", id: forecast.id, category_id: category.id)
    end
  end

  class ForecastItemEditHandler < ForecastItemFormHandler
    include ForecastLookup

    @found : {Acc::ForecastView, Acc::ForecastCategoryView, Acc::ForecastItemView}?

    private def found : {Acc::ForecastView, Acc::ForecastCategoryView, Acc::ForecastItemView}
      @found ||= forecast_of_item(current.actor, id_param, id_param("item_id"))
    end

    def forecast : Acc::ForecastView
      found[0]
    end

    def category : Acc::ForecastCategoryView
      found[1]
    end

    def existing : Acc::ForecastItemView?
      found[2]
    end

    def save(input : Acc::ForecastItemInput) : Partiduo::Api::Result(Acc::ForecastItemView)
      Acc.update_forecast_item(current.actor, found[2].id, input)
    end

    def action_url : String
      reverse("accounting:forecast_item_edit", id: forecast.id, item_id: found[2].id)
    end
  end

  class ForecastItemDeleteHandler < ForecastScreen
    include ForecastLookup

    def report : Marten::HTTP::Response
      go(reverse("accounting:forecasts"))
    end

    def post
      view, _, item = forecast_of_item(current.actor, id_param, id_param("item_id"))
      flash_result(Acc.delete_forecast_item(current.actor, item.id), "ui.forecasts.item_deleted")
      go(forecast_url(view.id))
    end
  end

  # Estimé et réel (`Anticipation::display`) : pour chaque élément, trois
  # lignes (estimé, réel, écart) et une colonne par période, total en fin de
  # ligne ; totaux par catégorie. Export CSV du tableau entier.
  class ForecastReportHandler < ForecastScreen
    def report : Marten::HTTP::Response
      view = Acc.forecast_report(current.actor, id_param)
      columns = [
        column("category", "ui.forecasts.category", secondary: true),
        column("label", "ui.forecasts.label"),
        column("kind", "ui.forecasts.row_kind"),
      ]
      view.periods.each_with_index do |period, index|
        columns << Table::Column.new("p#{index}", fmt.period(period.starts_on, period.ends_on), "amount", sortable: false)
      end
      columns << column("total", "ui.forecasts.total", "amount")
      rows = [] of Table::Row
      view.categories.each do |category|
        category.items.each do |item|
          rows << amount_row(category.label, item.label, "ui.forecasts.estimated", item.estimated)
          rows << amount_row(category.label, item.label, "ui.forecasts.real", item.real)
          rows << amount_row(category.label, item.label, "ui.forecasts.difference", item.differences, "pd-row-subtotal")
        end
        next if category.items.empty?
        total_label = I18n.t("ui.forecasts.category_total", category: category.label)
        rows << amount_row(category.label, total_label, "ui.forecasts.estimated", category.estimated, "pd-row-total")
        rows << amount_row(category.label, total_label, "ui.forecasts.real", category.real, "pd-row-total")
      end
      table = Table.new(view.forecast.name, columns, rows, request.path, empty_message: I18n.t("ui.forecasts.no_items"),
        id: "pd-forecast-report")
      table.exportable = false
      return export_response(table, I18n.t("ui.forecasts.report_csv_name")) if export?
      warnings = view.invalid_items.map { |label| I18n.t("ui.forecasts.invalid_formula", label: label) }
      actions = [link_action("ui.table.export_csv", "#{request.path}?format=csv", icon: "download"),
                 link_action("ui.reports.export_pdf", "#{request.path}?format=pdf", icon: "printer")]
      actions << link_action("ui.forecasts.back", forecast_url(view.forecast.id))
      summary = [
        Screen::Item.new(I18n.t("ui.forecasts.starts_on"), fmt.date(view.forecast.starts_on), mono: true),
        Screen::Item.new(I18n.t("ui.forecasts.ends_on"), fmt.date(view.forecast.ends_on), mono: true),
      ]
      report_page(I18n.t("ui.forecasts.report_title", name: view.forecast.name), nil,
        [Screen::Section.new(I18n.t("ui.forecasts.compare"), table: table)], summary, warnings, actions,
        intro: I18n.t("ui.forecasts.report_intro"))
    end

    private def amount_row(category : String, label : String, kind_key : String, values : Array(BigDecimal),
                           css : String = "") : Table::Row
      cells = [Table::Cell.new(category), Table::Cell.new(label), Table::Cell.new(I18n.t(kind_key))]
      values.each { |value| cells << total_cell(value) }
      cells << total_cell(values.sum(BigDecimal.new(0)))
      Table::Row.new(cells, css)
    end
  end
end
