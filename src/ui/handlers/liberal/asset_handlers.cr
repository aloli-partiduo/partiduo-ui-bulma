# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Registre des immobilisations et des amortissements (ADR-007 D6) :
  # liste groupée par exercice d'acquisition, saisie d'une acquisition
  # (amortissement linéaire), consultation avec le plan d'amortissement,
  # cession. Tant que l'exercice d'acquisition est ouvert et qu'aucune année
  # figée n'en dépend, l'immobilisation se modifie et se supprime, sa cession
  # aussi (D-LIB2-004) ; ensuite cadenas, contre-passation la même année ou
  # cession.
  abstract class AssetScreen < LiberalScreen
    def assets_crumbs : Array(Screen::Crumb)
      liberal_crumbs << Screen::Crumb.new(I18n.t("ui.liberal.asset.title"), reverse("liberal:assets"))
    end

    def duration(item : Liberal::AssetView) : String
      return I18n.t("ui.liberal.asset.not_depreciable") if item.duration_years.zero?
      rate = item.rate.try { |value| fmt.percent(value) } || ""
      I18n.t("ui.liberal.asset.duration_value", years: item.duration_years.to_s, rate: rate)
    end

    def state(item : Liberal::AssetView) : String?
      if item.reversal_of_id
        I18n.t("ui.liberal.line.reversal")
      elsif item.reversed_by_id
        I18n.t("ui.liberal.line.cancelled")
      elsif item.disposal
        I18n.t("ui.liberal.asset.disposed")
      end
    end

    # Modifier et supprimer tant que l'immobilisation n'est pas intangible
    # (D-LIB2-004). `row` : boutons d'une ligne de liste.
    def asset_actions(item : Liberal::AssetView, row : Bool = false) : Array(Screen::Action)
      actions = [] of Screen::Action
      return actions unless can?(WRITE)
      if item.editable?
        actions << link_action("ui.liberal.asset.edit", reverse("liberal:asset_edit", id: item.id), row ? "row" : "", "pencil")
      end
      if item.deletable?
        actions << post_action("ui.liberal.asset.delete", reverse("liberal:asset_delete", id: item.id),
          "ui.liberal.asset.delete_confirm", row ? "row-danger" : "danger", "trash-2")
      end
      actions.each { |action| action.aria_label = "#{action.label} #{item.number}" } if row
      actions
    end
  end

  # Registre : toutes les immobilisations, dans l'ordre des acquisitions.
  class LiberalAssetsHandler < AssetScreen
    def get
      items = Liberal.assets(current.actor)
      columns = [
        Table::Column.new("date", I18n.t("ui.liberal.asset.acquired_on"), "mono"),
        Table::Column.new("number", I18n.t("ui.liberal.columns.number"), "mono", secondary: true),
        Table::Column.new("label", I18n.t("ui.liberal.asset.label")),
        Table::Column.new("category", I18n.t("ui.liberal.asset.category"), secondary: true),
        Table::Column.new("duration", I18n.t("ui.liberal.asset.duration"), secondary: true),
        Table::Column.new("amount", I18n.t("ui.liberal.asset.amount"), "amount"),
        Table::Column.new("actions", I18n.t("ui.liberal.columns.actions"), "actions"),
      ]
      rows = items.reverse.map do |item|
        date = Table::Cell.new(fmt.date(item.acquired_on), reverse("liberal:asset", id: item.id), sort: date_key(item.acquired_on),
          csv: date_key(item.acquired_on))
        if item.locked
          date.icon = "lock"
          date.hidden_text = I18n.t("ui.liberal.asset.locked_short")
        end
        css = [] of String
        css << "pd-row-closed" unless item.live? && item.disposal.nil?
        css << "pd-row-locked" if item.locked
        Table::Row.new([
          date,
          Table::Cell.new(item.number),
          Table::Cell.new(item.label, tag: state(item)),
          Table::Cell.new(category_label(item.category)),
          Table::Cell.new(duration(item)),
          Table::Cell.new(euros(item.amount), sort: item.amount, csv: fmt.csv_amount(item.amount)),
          Table::Cell.new("", actions: asset_actions(item, row: true)),
        ], css.join(" "), item.acquired_on.year.to_s)
      end
      table = Table.new(I18n.t("ui.liberal.asset.title"), columns, rows, reverse("liberal:assets"),
        empty_message: I18n.t("ui.liberal.asset.empty"))
      # Groupes par exercice d'acquisition : ouvert, clôturé, 2035 transmise.
      table.groups = exercises(items.map(&.acquired_on.year)).to_h { |year, view| {year.to_s, exercise_group(view)} }
      table.group_sort = "date"
      actions = [] of Screen::Action
      actions << link_action("ui.liberal.asset.new", reverse("liberal:asset_new"), "primary", "plus") if can?(WRITE)
      actions << link_action("ui.liberal.asset.depreciation", reverse("liberal:tax_return"))
      list_page(I18n.t("ui.liberal.asset.title"), table, liberal_crumbs, "ui.liberal.asset.csv_name", actions,
        intro: "#{I18n.t("ui.liberal.asset.intro")} #{I18n.t("ui.liberal.asset.exercise_intro")}")
    end
  end

  # Acquisition : désignation, catégorie, date, montant, durée, règlement ;
  # mise en service, fournisseur et pièce sous « Plus de détails ».
  class LiberalAssetNewHandler < AssetScreen
    FIELDS = %w[label category acquired_on amount duration_years method service_on party_name reference attachment_id]

    def get
      require!(MODULE, WRITE)
      show(build_form({"acquired_on" => today.to_s("%Y-%m-%d"), "method" => "transfer", "category" => "office", "duration_years" => "3"}))
    end

    def post
      require!(MODULE, WRITE)
      values = FIELDS.to_h { |name| {name, field(name)} }
      form = build_form(values)
      upload(form, values)
      input = read(form, values)
      return show(copy_errors(form, build_form(values)), 422) if input.nil?
      result = Liberal.record_asset(current.actor, input)
      if created = result.value?
        flash["success"] = I18n.t("ui.liberal.asset.recorded", number: created.number, amount: euros(created.amount))
        return go(reverse("liberal:asset", id: created.id))
      end
      show(build_form(values).add_errors(result.errors, fmt), 422)
    end

    private def read(form : Form, values : Hash(String, String)) : Liberal::AssetInput?
      amount = fmt.parse_decimal(values["amount"])
      form.add_error("amount", I18n.t(values["amount"].empty? ? "ui.forms.required" : "ui.forms.invalid_number")) unless amount
      acquired = fmt.parse_date(values["acquired_on"])
      form.add_error("acquired_on", I18n.t("ui.forms.invalid_date")) unless acquired
      years = values["duration_years"].to_i?
      form.add_error("duration_years", I18n.t("ui.forms.invalid_integer")) unless years
      service = values["service_on"].empty? ? nil : fmt.parse_date(values["service_on"])
      form.add_error("service_on", I18n.t("ui.forms.invalid_date")) if service.nil? && !values["service_on"].empty?
      return if form.invalid || amount.nil? || acquired.nil? || years.nil?
      Liberal::AssetInput.new(label: values["label"], category: values["category"], acquired_on: acquired, amount: amount,
        duration_years: years, method: values["method"], service_on: service, party_name: values["party_name"],
        reference: values["reference"], attachment_id: values["attachment_id"].to_i64?)
    end

    private def build_form(values : Hash(String, String)) : Form
      categories = Liberal::ASSET_CATEGORIES.map { |code| option(code, category_label(code)) }
      main = [
        Form::Field.new("amount", I18n.t("ui.liberal.asset.amount_field"), "number", values["amount"]? || "", required: true, mono: true,
          placeholder: "0,00", help: I18n.t("ui.liberal.asset.amount_help")),
        Form::Field.new("label", I18n.t("ui.liberal.asset.label"), value: values["label"]? || "", required: true, maxlength: 255),
        Form::Field.new("category", I18n.t("ui.liberal.asset.category"), "select", values["category"]? || "", required: true,
          options: categories),
        Form::Field.new("acquired_on", I18n.t("ui.liberal.asset.acquired_on"), "date", values["acquired_on"]? || "", required: true),
        Form::Field.new("duration_years", I18n.t("ui.liberal.asset.duration_field"), "number", values["duration_years"]? || "",
          required: true, mono: true, help: I18n.t("ui.liberal.asset.duration_help")),
        Form::Field.new("method", I18n.t("ui.liberal.columns.method"), "select", values["method"]? || "", required: true,
          options: method_options),
      ]
      more = [
        Form::Field.new("service_on", I18n.t("ui.liberal.asset.service_on"), "date", values["service_on"]? || "",
          help: I18n.t("ui.liberal.asset.service_on_help")),
        Form::Field.new("party_name", I18n.t("ui.liberal.expense.party"), value: values["party_name"]? || "", maxlength: 255),
        Form::Field.new("reference", I18n.t("ui.liberal.fields.reference"), value: values["reference"]? || "", maxlength: 100,
          help: I18n.t("ui.liberal.fields.reference_help")),
        Form::Field.new("attachment_id", "", "hidden", values["attachment_id"]? || ""),
      ]
      Form.new([Form::Group.new(nil, main), Form::Group.new(I18n.t("ui.liberal.fields.more"), more)])
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      entry_page(I18n.t("ui.liberal.asset.new"), assets_crumbs, form, reverse("liberal:asset_new"), reverse("liberal:assets"),
        again: false, status: status)
    end
  end

  # Modification d'une immobilisation d'un exercice ouvert (D-LIB2-004) :
  # même formulaire que l'acquisition, prérempli ; le contrat refuse une
  # immobilisation intangible, cédée ou contre-passée.
  class LiberalAssetEditHandler < LiberalAssetNewHandler
    @item : Liberal::AssetView? = nil

    private def item : Liberal::AssetView
      @item ||= Liberal.asset(current.actor, id_param)
    end

    def get
      require!(MODULE, WRITE)
      unless item.editable?
        flash["danger"] = I18n.t("ui.liberal.asset.not_editable")
        return go(reverse("liberal:asset", id: item.id))
      end
      show(build_form({
        "label"          => item.label,
        "category"       => item.category,
        "acquired_on"    => item.acquired_on.to_s("%Y-%m-%d"),
        "amount"         => fmt.amount(item.amount, 2, group: false),
        "duration_years" => item.duration_years.to_s,
        "method"         => item.method,
        "service_on"     => item.service_on == item.acquired_on ? "" : item.service_on.to_s("%Y-%m-%d"),
        "party_name"     => item.party_name,
        "reference"      => item.reference,
        "attachment_id"  => item.attachment_id.to_s,
      }))
    end

    def post
      require!(MODULE, WRITE)
      values = FIELDS.to_h { |name| {name, field(name)} }
      form = build_form(values)
      upload(form, values)
      input = read(form, values)
      return show(copy_errors(form, build_form(values)), 422) if input.nil?
      result = Liberal.update_asset(current.actor, item.id, input)
      if changed = result.value?
        flash["success"] = I18n.t("ui.liberal.asset.updated", number: changed.number)
        return go(reverse("liberal:asset", id: changed.id))
      end
      show(build_form(values).add_errors(result.errors, fmt), 422)
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      entry_page(I18n.t("ui.liberal.asset.edit_title", number: item.number),
        assets_crumbs << Screen::Crumb.new(item.number, reverse("liberal:asset", id: item.id)), form,
        reverse("liberal:asset_edit", id: item.id), reverse("liberal:asset", id: item.id), again: false, status: status,
        intro: I18n.t("ui.liberal.asset.edit_intro"))
    end
  end

  # Suppression d'une immobilisation (ou de sa contre-passation) d'un
  # exercice ouvert, après confirmation.
  class LiberalAssetDeleteHandler < AssetScreen
    def post
      require!(MODULE, WRITE)
      item = Liberal.asset(current.actor, id_param)
      result = Liberal.delete_asset(current.actor, item.id)
      if result.success?
        flash["success"] = I18n.t("ui.liberal.asset.deleted", number: item.number)
        return go(reverse("liberal:assets"))
      end
      flash["danger"] = messages(result.errors)
      go(reverse("liberal:asset", id: item.id))
    end
  end

  # Suppression de la cession d'une immobilisation (exercice ouvert).
  class LiberalDisposalDeleteHandler < AssetScreen
    def post
      require!(MODULE, WRITE)
      item = Liberal.asset(current.actor, id_param)
      result = Liberal.delete_disposal(current.actor, item.id)
      if result.success?
        flash["success"] = I18n.t("ui.liberal.asset.disposal_deleted", number: item.number)
      else
        flash["danger"] = messages(result.errors)
      end
      go(reverse("liberal:asset", id: item.id))
    end
  end

  # Consultation : fiche, plan d'amortissement, cession ; annulation (la
  # même année que l'acquisition, sans cession) et cession.
  class LiberalAssetHandler < AssetScreen
    def get
      item = Liberal.asset(current.actor, id_param)
      details = [
        Screen::Item.new(I18n.t("ui.liberal.columns.number"), item.number, mono: true),
        Screen::Item.new(I18n.t("ui.liberal.asset.label"), item.label),
        Screen::Item.new(I18n.t("ui.liberal.asset.category"), category_label(item.category)),
        Screen::Item.new(I18n.t("ui.liberal.asset.acquired_on"), fmt.date(item.acquired_on)),
        Screen::Item.new(I18n.t("ui.liberal.asset.service_on"), fmt.date(item.service_on)),
        Screen::Item.new(I18n.t("ui.liberal.asset.amount"), euros(item.amount)),
        Screen::Item.new(I18n.t("ui.liberal.asset.duration"), duration(item)),
        Screen::Item.new(I18n.t("ui.liberal.columns.method"), method_label(item.method)),
        Screen::Item.new(I18n.t("ui.liberal.expense.party"), party(item.party_name, item.card_id)),
        Screen::Item.new(I18n.t("ui.liberal.fields.reference"), item.reference),
      ]
      if attachment = item.attachment_id
        details << Screen::Item.new(I18n.t("ui.liberal.fields.attachment"), I18n.t("ui.liberal.fields.attachment_open"),
          reverse("core:attachment", id: attachment))
      end
      item.reversal_of_id.try { |id| details << Screen::Item.new(I18n.t("ui.liberal.line.cancels"), Liberal.asset(current.actor, id).number, reverse("liberal:asset", id: id), mono: true) }
      item.reversed_by_id.try { |id| details << Screen::Item.new(I18n.t("ui.liberal.line.cancelled_by"), Liberal.asset(current.actor, id).number, reverse("liberal:asset", id: id), mono: true) }
      exercise = Liberal.year(current.actor, item.acquired_on.year)
      details << Screen::Item.new(I18n.t("ui.liberal.exercise.title"),
        "#{I18n.t("ui.liberal.exercise.label", year: exercise.year.to_s)} · #{exercise_status(exercise)}")
      item.modified_at.try { |moment| details << Screen::Item.new(I18n.t("ui.liberal.line.modified_at"), fmt.timestamp_date(moment)) }
      # La rubrique copie ses éléments : elle se construit après le dernier.
      sections = [Screen::Section.new(I18n.t("ui.liberal.asset.one"), details)]
      sections << schedule(item) if item.live? && item.duration_years > 0
      item.disposal.try { |disposal| sections << disposal_section(item, disposal) }
      intro = I18n.t(item.locked ? "ui.liberal.asset.intangible" : "ui.liberal.asset.open")
      detail_page("#{I18n.t("ui.liberal.asset.one")} #{item.number}", assets_crumbs, sections, detail_actions(item),
        status_tag: state(item), intro: intro)
    end

    # Modifier, supprimer ; céder ; contre-passer une immobilisation
    # intangible de l'année (période close) ; supprimer une cession d'un
    # exercice ouvert.
    private def detail_actions(item : Liberal::AssetView) : Array(Screen::Action)
      actions = asset_actions(item)
      return actions unless can?(WRITE)
      if item.live? && item.disposal.nil?
        actions << link_action("ui.liberal.asset.dispose", reverse("liberal:asset_dispose", id: item.id), icon: "log-out")
        if item.locked && item.acquired_on.year == today.year
          actions << post_action("ui.liberal.asset.cancel", reverse("liberal:asset_reverse", id: item.id),
            "ui.liberal.asset.cancel_confirm", "", "undo-2")
        end
      end
      if (disposal = item.disposal) && !disposal.locked
        actions << post_action("ui.liberal.asset.delete_disposal", reverse("liberal:asset_disposal_delete", id: item.id),
          "ui.liberal.asset.delete_disposal_confirm", "danger", "trash-2")
      end
      actions
    end

    private def schedule(item : Liberal::AssetView) : Screen::Section
      columns = [
        Table::Column.new("year", I18n.t("ui.liberal.year"), "mono", sortable: false),
        Table::Column.new("annuity", I18n.t("ui.liberal.asset.annuity"), "amount", sortable: false),
        Table::Column.new("net", I18n.t("liberal.columns.net_value"), "amount", sortable: false),
      ]
      remaining = item.amount
      rows = Liberal.schedule(current.actor, item.id).map do |(year, annuity)|
        remaining -= annuity
        Table::Row.new([Table::Cell.new(year.to_s), Table::Cell.new(euros(annuity)), Table::Cell.new(euros(remaining))],
          year == today.year ? "pd-class" : "")
      end
      table = Table.new(I18n.t("ui.liberal.asset.schedule"), columns, rows, reverse("liberal:asset", id: item.id),
        id: "pd-schedule")
      table.exportable = false
      Screen::Section.new(I18n.t("ui.liberal.asset.schedule"), table: table)
    end

    private def disposal_section(item : Liberal::AssetView, disposal : Liberal::DisposalView) : Screen::Section
      items = [
        Screen::Item.new(I18n.t("ui.liberal.asset.disposed_on"), fmt.date(disposal.date)),
        Screen::Item.new(I18n.t("liberal.columns.price"), euros(disposal.price)),
        Screen::Item.new(I18n.t("ui.liberal.columns.method"), method_label(disposal.method)),
        Screen::Item.new(I18n.t("ui.liberal.fields.reference"), disposal.reference),
      ]
      if result = Liberal.disposal_result(current.actor, item.id)
        items << Screen::Item.new(I18n.t("liberal.columns.gain"), euros(result.gain))
        items << Screen::Item.new(I18n.t("liberal.columns.short_term"), euros(result.short_term))
        items << Screen::Item.new(I18n.t("liberal.columns.long_term"), euros(result.long_term))
      end
      Screen::Section.new(I18n.t("ui.liberal.asset.disposal"), items)
    end
  end

  # Contre-passation d'une immobilisation, datée du jour (la même année).
  class LiberalAssetReverseHandler < AssetScreen
    def post
      require!(MODULE, WRITE)
      item = Liberal.asset(current.actor, id_param)
      result = Liberal.reverse_asset(current.actor, Liberal::ReverseInput.new(item.id, today))
      if reversal = result.value?
        flash["success"] = I18n.t("ui.liberal.line.cancelled_flash", number: item.number, reversal: reversal.number)
      else
        flash["danger"] = messages(result.errors)
      end
      go(reverse("liberal:asset", id: item.id))
    end
  end

  # Cession : date (du jour par défaut), prix, règlement, pièce.
  class LiberalAssetDisposeHandler < AssetScreen
    def get
      require!(MODULE, WRITE)
      item = Liberal.asset(current.actor, id_param)
      show(item, build_form({"date" => today.to_s("%Y-%m-%d"), "price" => "", "method" => "transfer", "reference" => ""}))
    end

    def post
      require!(MODULE, WRITE)
      item = Liberal.asset(current.actor, id_param)
      values = {"date" => field("date"), "price" => field("price"), "method" => field("method"), "reference" => field("reference")}
      form = build_form(values)
      date = fmt.parse_date(values["date"])
      form.add_error("date", I18n.t("ui.forms.invalid_date")) unless date
      price = fmt.parse_decimal(values["price"])
      form.add_error("price", I18n.t(values["price"].empty? ? "ui.forms.required" : "ui.forms.invalid_number")) unless price
      return show(item, form, 422) if form.invalid || date.nil? || price.nil?
      result = Liberal.dispose_asset(current.actor, Liberal::DisposalInput.new(item.id, date, price, values["method"], values["reference"]))
      if result.success?
        flash["success"] = I18n.t("ui.liberal.asset.disposed_flash", number: item.number)
        return go(reverse("liberal:asset", id: item.id))
      end
      show(item, form.add_errors(result.errors, fmt), 422)
    end

    private def build_form(values : Hash(String, String)) : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("date", I18n.t("ui.liberal.asset.disposed_on"), "date", values["date"], required: true),
        Form::Field.new("price", I18n.t("liberal.columns.price"), "number", values["price"], required: true, mono: true,
          help: I18n.t("ui.liberal.asset.price_help")),
        Form::Field.new("method", I18n.t("ui.liberal.columns.method"), "select", values["method"], required: true, options: method_options),
        Form::Field.new("reference", I18n.t("ui.liberal.fields.reference"), value: values["reference"], maxlength: 100),
      ])])
    end

    private def show(item : Liberal::AssetView, form : Form, status : Int32? = nil) : Marten::HTTP::Response
      form_page(I18n.t("ui.liberal.asset.dispose_title", number: item.number),
        assets_crumbs << Screen::Crumb.new(item.number, reverse("liberal:asset", id: item.id)), form,
        reverse("liberal:asset_dispose", id: item.id), I18n.t("ui.liberal.asset.dispose"), reverse("liberal:asset", id: item.id),
        intro: I18n.t("ui.liberal.asset.dispose_intro"), status: status)
    end
  end
end
