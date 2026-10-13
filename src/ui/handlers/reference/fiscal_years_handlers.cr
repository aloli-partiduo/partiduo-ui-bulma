# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Exercices et périodes (`Partiduo::Api::Core`, successeurs de
  # `parm_periode`) : liste et création, consultation, ajout de période,
  # clôture, réouverture, suppression. La lecture est ouverte à tout
  # utilisateur authentifié ; les commandes ont leurs permissions.
  abstract class FiscalYearScreen < ReferenceHandler
    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.settings"), crumb("core.menu.core_fiscal_years", reverse("core:fiscal_years"))]
    end

    def status_of(closed : Bool) : String
      I18n.t(closed ? "ui.fiscal_years.closed" : "ui.fiscal_years.open")
    end

    def month_options : Array(Form::Option)
      (1..12).map { |month| option(month.to_s, I18n.t("ui.months.m#{month}")) }
    end
  end

  # Liste des exercices et création d'un exercice mensuel
  # (`Periode::insert_exercice`).
  class FiscalYearsHandler < FiscalYearScreen
    def get
      years = Partiduo::Api::Core.fiscal_years(current.actor)
      # Sans exercice : l'année du jour du dossier (son fuseau, pas celui du serveur).
      next_year = (years.max_of?(&.year) || Partiduo::Api::Core.today.year - 1) + 1
      show(years, creation_form(year: next_year.to_s, start_year: next_year.to_s))
    end

    def post
      errors = [] of {String, String}
      year = integer("year", errors)
      start_year = integer("start_year", errors)
      start_month = integer("start_month", errors)
      months = integer("months", errors)
      form = creation_form(field("year"), field("start_year"), field("start_month"), field("months"), field("label"),
        checkbox("opening_period"), checkbox("closing_period"))
      errors.each { |(name, message)| form.add_error(name, message) }
      if year && start_year && start_month && months && errors.empty?
        input = Partiduo::Api::Core::FiscalYearInput.new(year: year, start_year: start_year, start_month: start_month,
          months: months, label: field("label").presence, opening_period: checkbox("opening_period"),
          closing_period: checkbox("closing_period"))
        result = Partiduo::Api::Core.create_fiscal_year(current.actor, input)
        if created = result.value?
          flash["success"] = I18n.t("ui.fiscal_years.created", label: created.label)
          return go(reverse("core:fiscal_year", id: created.id))
        end
        form.add_errors(result.errors, fmt)
      end
      show(Partiduo::Api::Core.fiscal_years(current.actor), form, 422)
    end

    private def show(years : Array(Partiduo::Api::Core::FiscalYearView), form : Form, status : Int32 = 200)
      columns = [
        Table::Column.new("label", I18n.t("ui.fiscal_years.label")),
        Table::Column.new("year", I18n.t("ui.fiscal_years.year"), "mono"),
        Table::Column.new("starts_on", I18n.t("ui.fiscal_years.starts_on"), "mono"),
        Table::Column.new("ends_on", I18n.t("ui.fiscal_years.ends_on"), "mono"),
        Table::Column.new("periods", I18n.t("ui.fiscal_years.periods"), "amount", secondary: true),
        Table::Column.new("open_periods", I18n.t("ui.fiscal_years.open_periods"), "amount", secondary: true),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status")),
      ]
      rows = years.map do |year|
        Table::Row.new([
          Table::Cell.new(year.label, reverse("core:fiscal_year", id: year.id)),
          Table::Cell.new(year.year.to_s, sort: BigDecimal.new(year.year)),
          Table::Cell.new(fmt.date(year.starts_on), sort: date_key(year.starts_on), csv: date_key(year.starts_on)),
          Table::Cell.new(fmt.date(year.ends_on), sort: date_key(year.ends_on), csv: date_key(year.ends_on)),
          Table::Cell.new(year.periods.size.to_s, sort: BigDecimal.new(year.periods.size)),
          Table::Cell.new(year.open_periods.size.to_s, sort: BigDecimal.new(year.open_periods.size)),
          Table::Cell.new(status_of(year.closed?)),
        ], year.closed? ? "pd-row-closed" : "")
      end
      table = Table.new(I18n.t("core.menu.core_fiscal_years"), columns, rows, reverse("core:fiscal_years"),
        empty_message: I18n.t("ui.fiscal_years.empty"))
      if can?("core.fiscal_year.write")
        set_form(form, reverse("core:fiscal_years"), I18n.t("ui.fiscal_years.create"), title: I18n.t("ui.fiscal_years.new"))
      end
      list_page(I18n.t("core.menu.core_fiscal_years"), table, crumbs[0, 1], "ui.fiscal_years.csv_name",
        intro: I18n.t("ui.fiscal_years.intro"), status: status)
    end

    private def creation_form(year = "", start_year = "", start_month = "1", months = "12", label = "",
                              opening = false, closing = false) : Form
      Form.new([
        Form::Group.new(nil, [
          Form::Field.new("year", I18n.t("ui.fiscal_years.year"), value: year, required: true, mono: true, maxlength: 4),
          Form::Field.new("label", I18n.t("ui.fiscal_years.label"), value: label, help: I18n.t("ui.fiscal_years.label_help"), maxlength: 80),
          Form::Field.new("start_month", I18n.t("ui.fiscal_years.start_month"), "select", start_month, options: month_options, required: true),
          Form::Field.new("start_year", I18n.t("ui.fiscal_years.start_year"), value: start_year, required: true, mono: true, maxlength: 4),
          Form::Field.new("months", I18n.t("ui.fiscal_years.months"), value: months, required: true, mono: true, maxlength: 2,
            help: I18n.t("ui.fiscal_years.months_help")),
          Form::Field.new("opening_period", I18n.t("ui.fiscal_years.opening_period"), "checkbox", opening ? "1" : ""),
          Form::Field.new("closing_period", I18n.t("ui.fiscal_years.closing_period"), "checkbox", closing ? "1" : ""),
        ]),
      ])
    end
  end

  # Consultation d'un exercice : ses périodes (clôture, réouverture,
  # suppression) et l'ajout d'une période.
  class FiscalYearHandler < FiscalYearScreen
    def get
      show(period_form)
    end

    def post
      errors = [] of {String, String}
      starts_on = date("starts_on", errors)
      ends_on = date("ends_on", errors)
      form = period_form(field("starts_on"), field("ends_on"))
      errors.each { |(name, message)| form.add_error(name, message) }
      if starts_on && ends_on
        input = Partiduo::Api::Core::PeriodInput.new(fiscal_year_id: id_param, starts_on: starts_on, ends_on: ends_on)
        result = Partiduo::Api::Core.add_period(current.actor, input)
        if added = result.value?
          flash["success"] = I18n.t("ui.fiscal_years.period_added", period: fmt.period(added.starts_on, added.ends_on))
          return go(reverse("core:fiscal_year", id: id_param))
        end
        form.add_errors(result.errors, fmt)
      end
      show(form, 422)
    end

    private def show(form : Form, status : Int32 = 200)
      year = Partiduo::Api::Core.fiscal_year(current.actor, id_param)
      summary = Screen::Section.new(I18n.t("ui.fiscal_years.summary"), [
        Screen::Item.new(I18n.t("ui.fiscal_years.label"), year.label),
        Screen::Item.new(I18n.t("ui.fiscal_years.year"), year.year.to_s, mono: true),
        Screen::Item.new(I18n.t("ui.fiscal_years.starts_on"), fmt.date(year.starts_on), mono: true),
        Screen::Item.new(I18n.t("ui.fiscal_years.ends_on"), fmt.date(year.ends_on), mono: true),
        Screen::Item.new(I18n.t("ui.fiscal_years.periods"), year.periods.size.to_s),
        Screen::Item.new(I18n.t("ui.fiscal_years.status"), status_of(year.closed?)),
      ])
      table = periods_table(year)
      table.pdf = table.exportable
      return export_response(table, "periodes-#{year.year}") if export?
      periods = Screen::Section.new(I18n.t("ui.fiscal_years.periods"), table: table)
      actions = [] of Screen::Action
      unless year.closed?
        if can?("core.period.close")
          actions << post_action("ui.fiscal_years.close", reverse("core:fiscal_year_close", id: year.id),
            "ui.fiscal_years.close_confirm", icon: "lock")
        end
        if can?("core.fiscal_year.write")
          actions << post_action("ui.forms.delete", reverse("core:fiscal_year_delete", id: year.id),
            "ui.fiscal_years.delete_confirm", "danger")
          set_form(form, reverse("core:fiscal_year", id: year.id), I18n.t("ui.fiscal_years.add_period"))
        end
      end
      detail_page(I18n.t("ui.fiscal_years.title", label: year.label), crumbs, [summary, periods], actions,
        status_tag: status_of(year.closed?), status: status)
    end

    private def periods_table(year : Partiduo::Api::Core::FiscalYearView) : Table
      columns = [
        Table::Column.new("period", I18n.t("ui.shell.period")),
        Table::Column.new("starts_on", I18n.t("ui.fiscal_years.starts_on"), "mono"),
        Table::Column.new("ends_on", I18n.t("ui.fiscal_years.ends_on"), "mono"),
        Table::Column.new("status", I18n.t("ui.fiscal_years.status")),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = year.periods.map do |period|
        Table::Row.new([
          Table::Cell.new(fmt.period(period.starts_on, period.ends_on), sort: date_key(period.starts_on)),
          Table::Cell.new(fmt.date(period.starts_on), sort: date_key(period.starts_on), csv: date_key(period.starts_on)),
          Table::Cell.new(fmt.date(period.ends_on), sort: date_key(period.ends_on), csv: date_key(period.ends_on)),
          Table::Cell.new(status_of(period.closed?)),
          Table::Cell.new("", actions: period_actions(year, period)),
        ], period.closed? ? "pd-row-closed" : "")
      end
      table = Table.new(I18n.t("ui.fiscal_years.periods"), columns, rows, reverse("core:fiscal_year", id: year.id),
        empty_message: I18n.t("ui.fiscal_years.no_period"), id: "pd-periods")
      prepare(table)
    end

    private def period_actions(year, period) : Array(Screen::Action)
      actions = [] of Screen::Action
      return actions if year.closed?
      if period.closed?
        actions << post_action("ui.fiscal_years.reopen", reverse("core:period_reopen", id: period.id), style: "small") if can?("core.period.reopen")
      else
        actions << post_action("ui.fiscal_years.close_period", reverse("core:period_close", id: period.id),
          "ui.fiscal_years.close_period_confirm", "small") if can?("core.period.close")
        actions << post_action("ui.forms.delete", reverse("core:period_delete", id: period.id),
          "ui.fiscal_years.delete_period_confirm", "small") if can?("core.fiscal_year.write")
      end
      actions
    end

    private def period_form(starts_on = "", ends_on = "") : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("starts_on", I18n.t("ui.fiscal_years.starts_on"), "date", starts_on, required: true),
        Form::Field.new("ends_on", I18n.t("ui.fiscal_years.ends_on"), "date", ends_on, required: true),
      ])])
    end
  end

  # Commandes sur un exercice ou une période : retour à l'exercice.
  abstract class FiscalYearCommandHandler < FiscalYearScreen
    def post
      target = run
      go(target)
    end

    abstract def run : String

    def year_url(fiscal_year_id : Int64) : String
      reverse("core:fiscal_year", id: fiscal_year_id)
    end

    def period_year(period_id : Int64) : Int64
      Partiduo::Api::Core.period(current.actor, period_id).fiscal_year_id
    end
  end

  class FiscalYearCloseHandler < FiscalYearCommandHandler
    def run : String
      result = Partiduo::Api::Core.close_fiscal_year(current.actor, id_param)
      flash_result(result, "ui.fiscal_years.closed_message", {"label" => result.value?.try(&.label) || ""})
      year_url(id_param)
    end
  end

  class FiscalYearDeleteHandler < FiscalYearCommandHandler
    def run : String
      label = Partiduo::Api::Core.fiscal_year(current.actor, id_param).label
      if flash_result(Partiduo::Api::Core.delete_fiscal_year(current.actor, id_param), "ui.fiscal_years.deleted", {"label" => label})
        reverse("core:fiscal_years")
      else
        year_url(id_param)
      end
    end
  end

  class PeriodCloseHandler < FiscalYearCommandHandler
    def run : String
      year_id = period_year(id_param)
      result = Partiduo::Api::Core.close_period(current.actor, id_param)
      flash_result(result, "ui.fiscal_years.period_closed", {"period" => result.value?.try { |item| fmt.period(item.starts_on, item.ends_on) } || ""})
      year_url(year_id)
    end
  end

  class PeriodReopenHandler < FiscalYearCommandHandler
    def run : String
      year_id = period_year(id_param)
      result = Partiduo::Api::Core.reopen_period(current.actor, id_param)
      flash_result(result, "ui.fiscal_years.period_reopened", {"period" => result.value?.try { |item| fmt.period(item.starts_on, item.ends_on) } || ""})
      year_url(year_id)
    end
  end

  class PeriodDeleteHandler < FiscalYearCommandHandler
    def run : String
      period = Partiduo::Api::Core.period(current.actor, id_param)
      flash_result(Partiduo::Api::Core.delete_period(current.actor, id_param), "ui.fiscal_years.period_deleted",
        {"period" => fmt.period(period.starts_on, period.ends_on)})
      year_url(period.fiscal_year_id)
    end
  end

  # Choix de la période de travail dans la barre supérieure : mémorisé dans
  # un cookie, contrôlé par le contrat (période existante et visible).
  class CurrentPeriodHandler < ScreenHandler
    def post
      if id = field("period").to_i64?
        begin
          period = Partiduo::Api::Core.period(current.actor, id)
          request.cookies.set(Shell::PERIOD_COOKIE, period.id.to_s, expires: Time.local + 365.days, http_only: true,
            secure: Current.secure_cookies?(request), same_site: "Lax")
        rescue Partiduo::Api::NotFound
        end
      end
      go(Navigation.next_path(request))
    end
  end
end
