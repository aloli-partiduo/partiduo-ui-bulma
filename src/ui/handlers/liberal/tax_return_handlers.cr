# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Déclaration 2035 préparée (ADR-007 D6, D-LIB-007) : état du dépôt en
  # tête (prête ou contrôles bloquants), identification, 2035-A (postes non
  # nuls et totaux, ligne et case du millésime), 2035-B (immobilisations et
  # amortissements, plus et moins-values), réintégrations et déductions
  # (ajout et retrait tant que l'année est ouverte), contrôles de cohérence,
  # préparation du dépôt (empreinte, montants par case), édition de contrôle
  # PDF. Tout vient de `Partiduo::Api::Liberal.tax_return`, recalculée à
  # chaque lecture ; l'état de l'exercice est en tête : ouvert (la 2035 suit
  # le livre-journal), clôturé (figée, se rouvre) ou verrouillé (2035
  # transmise, D-LIB2-005, D-LIB5-001), avec « Clôturer l'exercice » ou
  # « Rouvrir l'exercice » et l'historique des clôtures et réouvertures.
  class LiberalTaxReturnHandler < LiberalScreen
    # Postes toujours présentés, même nuls : ce que le déclarant cherche.
    KEY_ITEMS = %w[total_receipts total_expenses profit]

    # Contrôle présenté : niveau, texte.
    class Control
      include Marten::Template::Object::Auto

      getter severity : String
      getter text : String
      getter error : Bool # ameba:disable Naming/QueryBoolMethods

      def initialize(@severity, @text, @error)
      end
    end

    def get
      year = year_param
      return file_response(Liberal.export_tax_return(current.actor, year)) if query("format") == "pdf"
      open = Liberal.year(current.actor, year).open?
      render(year, can?(WRITE) && open ? adjustment_form({"kind" => "reintegration", "label" => "", "amount" => ""}) : nil)
    end

    def render(year : Int32, form : Form?, status : Int32 = 200) : Marten::HTTP::Response
      view = Liberal.tax_return(current.actor, year)
      controls = view.controls.map do |item|
        Control.new(I18n.t("liberal.severities.#{item.severity}"), I18n.t(item.key, item.params), item.error?)
      end
      sections = [identity(view)]
      sections << form_section("2035", I18n.t("ui.liberal.tax_return.form_2035"), view) if view.form("2035").any? { |line| shown?(line) }
      sections << form_section("2035-A", I18n.t("ui.liberal.tax_return.form_a"), view)
      sections << form_section("2035-B", I18n.t("ui.liberal.tax_return.form_b"), view)
      sections << assets_section(view)
      sections << disposals_section(view) unless view.disposals.empty?
      sections << adjustments_section(view)
      sections << controls_section(controls)
      sections << filing_section(view)
      history(year).try { |section| sections << section }
      actions = year_actions(view.exercise, "#{reverse("liberal:tax_return")}?year=#{year}")
      actions << link_action("ui.liberal.tax_return.export", "#{reverse("liberal:tax_return")}?year=#{year}&format=pdf", icon: "printer")
      actions << link_action("ui.liberal.form_lines.title", "#{reverse("liberal:form_lines")}?millesime=#{year}") if can?(SETTINGS)
      context["title"] = I18n.t("ui.liberal.tax_return.title", year: year.to_s)
      context["crumbs"] = liberal_crumbs
      context["actions"] = actions
      context["tabs"] = year_tabs(reverse("liberal:tax_return"), year)
      context["year"] = year.to_s
      context["ready"] = view.ready?
      context["exercise_frozen"] = view.exercise.frozen?
      context["transmitted"] = view.exercise.locked?
      context["exercise_text"] = exercise_text(view.exercise)
      context["blocking"] = Screen.listed(controls.select(&.error).map(&.text))
      context["sections"] = sections
      context["form"] = form
      context["form_action"] = "#{reverse("liberal:adjustment_new")}?year=#{year}"
      context["form_submit"] = I18n.t("ui.liberal.adjustments.add")
      context["form_title"] = I18n.t("ui.liberal.adjustments.new")
      context["cancel_url"] = nil
      page("ui/liberal/tax_return.html", status: status)
    end

    # État de l'exercice en tête de la 2035 (D-LIB2-005, D-LIB5-001) :
    # ouvert, clôturé (par qui, réversible ou clos au socle), verrouillé.
    private def exercise_text(exercise : Liberal::YearView) : String
      date = exercise.frozen_at.try { |moment| fmt.timestamp_date(moment) } || ""
      year = exercise.year.to_s
      if exercise.locked?
        I18n.t("ui.liberal.tax_return.exercise_locked", year: year, date: date)
      elsif exercise.reopenable?
        by = exercise.closed_by.empty? ? "" : I18n.t("ui.liberal.tax_return.by", name: exercise.closed_by)
        I18n.t("ui.liberal.tax_return.exercise_closed", year: year, date: date, by: by)
      elsif exercise.closed?
        I18n.t("ui.liberal.tax_return.exercise_core_closed", year: year, date: date)
      else
        I18n.t("ui.liberal.tax_return.exercise_open", year: year)
      end
    end

    # Clôtures, réouvertures, transmission et rejet de l'exercice : quand,
    # qui ; rien avant la première clôture.
    private def history(year : Int32) : Screen::Section?
      changes = Liberal.year_history(current.actor, year)
      return if changes.empty?
      columns = [
        Table::Column.new("at", I18n.t("ui.liberal.exercise.history_at"), "mono", sortable: false),
        Table::Column.new("action", I18n.t("ui.liberal.exercise.history_action"), sortable: false),
        Table::Column.new("user", I18n.t("ui.liberal.exercise.history_user"), secondary: true, sortable: false),
      ]
      rows = changes.reverse.map do |item|
        Table::Row.new([
          Table::Cell.new(fmt.datetime(item.at)),
          Table::Cell.new(I18n.t("ui.liberal.exercise.actions.#{item.action}")),
          Table::Cell.new(item.user),
        ])
      end
      title = I18n.t("ui.liberal.exercise.history")
      table = Table.new(title, columns, rows, reverse("liberal:tax_return"), id: "pd-year-history")
      table.exportable = false
      Screen::Section.new(title, table: table)
    end

    def adjustment_form(values : Hash(String, String)) : Form
      kinds = Liberal::ADJUSTMENT_KINDS.map { |code| option(code, I18n.t("liberal.adjustment_kinds.#{code}")) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("kind", I18n.t("ui.liberal.adjustments.kind"), "select", values["kind"], required: true, options: kinds),
        Form::Field.new("label", I18n.t("ui.liberal.adjustments.label"), value: values["label"], required: true, maxlength: 255),
        Form::Field.new("amount", I18n.t("ui.liberal.columns.amount"), "number", values["amount"], required: true, mono: true),
      ])])
    end

    private def shown?(line : Liberal::TaxLineView) : Bool
      !line.amount.zero? || KEY_ITEMS.includes?(line.item)
    end

    private def identity(view : Liberal::TaxReturnView) : Screen::Section
      who = view.identity
      address = [[who.street_number, who.street].reject(&.empty?).join(" "), [who.postcode, who.city].reject(&.empty?).join(" ")]
        .reject(&.empty?).join(", ")
      items = [
        Screen::Item.new(I18n.t("ui.liberal.tax_return.company"), who.company_name),
        Screen::Item.new(I18n.t("ui.liberal.tax_return.siren"), who.siren.presence || I18n.t("ui.liberal.tax_return.missing"), mono: true),
        Screen::Item.new(I18n.t("ui.liberal.tax_return.address"), address),
        Screen::Item.new(I18n.t("ui.liberal.settings.profession"), who.profession.presence || I18n.t("ui.liberal.tax_return.missing")),
        Screen::Item.new(I18n.t("ui.liberal.settings.activity_started_on"), who.activity_started_on.try { |day| fmt.date(day) } || ""),
      ]
      Screen::Section.new(I18n.t("ui.liberal.tax_return.identity"), items)
    end

    # Postes d'un formulaire : ligne, poste, case, montant en euros entiers ;
    # poste sans ligne au millésime signalé.
    private def form_section(form : String, title : String, view : Liberal::TaxReturnView) : Screen::Section
      columns = [
        Table::Column.new("line", I18n.t("liberal.columns.line"), "mono", sortable: false),
        Table::Column.new("item", I18n.t("liberal.columns.item"), sortable: false),
        Table::Column.new("box", I18n.t("liberal.columns.box"), "mono", secondary: true, sortable: false),
        Table::Column.new("amount", I18n.t("ui.liberal.columns.amount"), "amount", sortable: false),
      ]
      rows = view.form(form).select { |line| shown?(line) }.map do |line|
        tag = line.mapped ? nil : I18n.t("ui.liberal.tax_return.unmapped")
        Table::Row.new([
          Table::Cell.new(line.line),
          Table::Cell.new(I18n.t(line.item_key), tag: tag),
          Table::Cell.new(line.box),
          Table::Cell.new(euros(line.amount, 0)),
        ], line.mapped ? (KEY_ITEMS.includes?(line.item) || line.item.in?("loss", "net_receipts", "excess", "shortfall") ? "pd-class" : "") : "pd-row-warning")
      end
      table = Table.new(title, columns, rows, reverse("liberal:tax_return"), empty_message: I18n.t("ui.liberal.tax_return.nothing"),
        id: "pd-form-#{form.downcase}")
      table.exportable = false
      Screen::Section.new(title, table: table)
    end

    private def assets_section(view : Liberal::TaxReturnView) : Screen::Section
      columns = [
        Table::Column.new("label", I18n.t("ui.liberal.asset.label"), sortable: false),
        Table::Column.new("acquired", I18n.t("liberal.columns.acquired_on"), "mono", secondary: true, sortable: false),
        Table::Column.new("amount", I18n.t("ui.liberal.asset.amount"), "amount", sortable: false),
        Table::Column.new("rate", I18n.t("liberal.columns.rate"), "amount", secondary: true, sortable: false),
        Table::Column.new("prior", I18n.t("liberal.columns.prior"), "amount", secondary: true, sortable: false),
        Table::Column.new("year", I18n.t("liberal.columns.year_amount"), "amount", sortable: false),
        Table::Column.new("net", I18n.t("liberal.columns.net_value"), "amount", secondary: true, sortable: false),
      ]
      rows = view.assets.map do |row|
        Table::Row.new([
          Table::Cell.new("#{row.number} · #{row.label}", reverse("liberal:asset", id: row.asset_id)),
          Table::Cell.new(fmt.date(row.acquired_on)),
          Table::Cell.new(euros(row.amount)),
          Table::Cell.new(row.rate.try { |rate| fmt.percent(rate) } || ""),
          Table::Cell.new(euros(row.prior)),
          Table::Cell.new(euros(row.year_amount)),
          Table::Cell.new(euros(row.net_value)),
        ])
      end
      title = I18n.t("ui.liberal.tax_return.assets")
      table = Table.new(title, columns, rows, reverse("liberal:tax_return"), empty_message: I18n.t("ui.liberal.asset.empty"),
        id: "pd-depreciation")
      table.exportable = false
      Screen::Section.new(title, table: table)
    end

    private def disposals_section(view : Liberal::TaxReturnView) : Screen::Section
      columns = [
        Table::Column.new("label", I18n.t("ui.liberal.asset.label"), sortable: false),
        Table::Column.new("price", I18n.t("liberal.columns.price"), "amount", sortable: false),
        Table::Column.new("net", I18n.t("liberal.columns.net_value"), "amount", secondary: true, sortable: false),
        Table::Column.new("short", I18n.t("liberal.columns.short_term"), "amount", sortable: false),
        Table::Column.new("long", I18n.t("liberal.columns.long_term"), "amount", sortable: false),
      ]
      rows = view.disposals.map do |row|
        Table::Row.new([
          Table::Cell.new("#{row.number} · #{row.label}", reverse("liberal:asset", id: row.asset_id)),
          Table::Cell.new(euros(row.price)), Table::Cell.new(euros(row.net_value)),
          Table::Cell.new(euros(row.short_term)), Table::Cell.new(euros(row.long_term)),
        ])
      end
      title = I18n.t("ui.liberal.tax_return.disposals")
      table = Table.new(title, columns, rows, reverse("liberal:tax_return"), id: "pd-disposals")
      table.exportable = false
      Screen::Section.new(title, table: table)
    end

    private def adjustments_section(view : Liberal::TaxReturnView) : Screen::Section
      columns = [
        Table::Column.new("kind", I18n.t("ui.liberal.adjustments.kind"), sortable: false),
        Table::Column.new("label", I18n.t("ui.liberal.adjustments.label"), sortable: false),
        Table::Column.new("amount", I18n.t("ui.liberal.columns.amount"), "amount", sortable: false),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = view.adjustments.map do |item|
        actions = [] of Screen::Action
        if can?(WRITE) && !item.locked
          actions << post_action("ui.liberal.adjustments.delete", "#{reverse("liberal:adjustment_delete", id: item.id)}?year=#{item.year}",
            "ui.liberal.adjustments.delete_confirm", "small")
        end
        Table::Row.new([
          Table::Cell.new(I18n.t(item.kind_key)), Table::Cell.new(item.label), Table::Cell.new(euros(item.amount)),
          Table::Cell.new("", actions: actions),
        ])
      end
      title = I18n.t("ui.liberal.adjustments.title")
      table = Table.new(title, columns, rows, reverse("liberal:tax_return"), empty_message: I18n.t("ui.liberal.adjustments.empty"),
        id: "pd-adjustments")
      table.exportable = false
      Screen::Section.new(title, table: table, note: I18n.t("ui.liberal.adjustments.intro"))
    end

    private def controls_section(controls : Array(Control)) : Screen::Section
      columns = [
        Table::Column.new("severity", I18n.t("liberal.columns.severity"), sortable: false),
        Table::Column.new("control", I18n.t("liberal.columns.control"), sortable: false),
      ]
      rows = controls.map do |item|
        Table::Row.new([Table::Cell.new(item.severity), Table::Cell.new(item.text)], item.error ? "pd-row-warning" : "")
      end
      title = I18n.t("ui.liberal.tax_return.controls")
      table = Table.new(title, columns, rows, reverse("liberal:tax_return"), empty_message: I18n.t("liberal.reports.no_control"),
        id: "pd-controls")
      table.exportable = false
      Screen::Section.new(title, table: table)
    end

    # Préparation du dépôt : état, empreinte à comparer au dépôt, montants
    # par formulaire et par case (ce que transmet `partiduo-teledec`).
    private def filing_section(view : Liberal::TaxReturnView) : Screen::Section
      columns = [
        Table::Column.new("form", I18n.t("liberal.columns.form"), sortable: false),
        Table::Column.new("box", I18n.t("liberal.columns.box"), "mono", sortable: false),
        Table::Column.new("amount", I18n.t("ui.liberal.columns.amount"), "amount", sortable: false),
      ]
      rows = view.boxes.flat_map do |form, boxes|
        boxes.map { |box, amount| Table::Row.new([Table::Cell.new(form), Table::Cell.new(box), Table::Cell.new(euros(amount, 0))]) }
      end
      title = I18n.t("ui.liberal.tax_return.filing")
      table = Table.new(I18n.t("ui.liberal.tax_return.boxes"), columns, rows, reverse("liberal:tax_return"),
        empty_message: I18n.t("ui.liberal.tax_return.nothing"), id: "pd-boxes")
      table.exportable = false
      note = I18n.t("ui.liberal.tax_return.filing_note", state: I18n.t(view.ready? ? "ui.liberal.tax_return.ready" : "ui.liberal.tax_return.blocked"),
        fingerprint: view.fingerprint)
      Screen::Section.new(title, table: table, note: note)
    end
  end

  # Ajout d'une réintégration ou d'une déduction de l'année ; refus :
  # l'écran de la 2035 réaffiché avec les erreurs sous leurs champs.
  class LiberalAdjustmentNewHandler < LiberalTaxReturnHandler
    def get
      go("#{reverse("liberal:tax_return")}?year=#{year_param}")
    end

    def post
      require!(MODULE, WRITE)
      year = year_param
      values = {"kind" => field("kind"), "label" => field("label"), "amount" => field("amount")}
      form = adjustment_form(values)
      amount = fmt.parse_decimal(values["amount"])
      form.add_error("amount", I18n.t(values["amount"].empty? ? "ui.forms.required" : "ui.forms.invalid_number")) unless amount
      return render(year, form, 422) if amount.nil?
      result = Liberal.add_adjustment(current.actor, Liberal::AdjustmentInput.new(year, values["kind"], values["label"], amount))
      if result.success?
        flash["success"] = I18n.t("ui.liberal.adjustments.added")
        return go("#{reverse("liberal:tax_return")}?year=#{year}")
      end
      render(year, form.add_errors(result.errors, fmt), 422)
    end
  end

  # Retrait d'une réintégration ou d'une déduction (année encore ouverte).
  class LiberalAdjustmentDeleteHandler < LiberalScreen
    def post
      require!(MODULE, WRITE)
      result = Liberal.delete_adjustment(current.actor, id_param)
      if result.success?
        flash["success"] = I18n.t("ui.liberal.adjustments.deleted")
      else
        flash["danger"] = messages(result.errors)
      end
      go("#{reverse("liberal:tax_return")}?year=#{year_param}")
    end
  end
end
