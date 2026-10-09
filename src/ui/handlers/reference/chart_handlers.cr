# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Plan comptable du module Comptabilité (`Partiduo::Api::Accounting`,
  # successeur de `tmp_pcmn`) : arbre par classe, création, consultation
  # (sous-comptes, fiches rattachées, usages par défaut), modification,
  # suppression. Soldes (lot 3, D-UI-020 levée) : ceux de la balance du
  # contrat, de l'exercice de travail, reliés au relevé du compte.
  abstract class ChartScreen < ReferenceHandler
    KINDS = Partiduo::Api::Accounting::AccountKind.values

    @balances : Hash(String, BigDecimal)?
    @balance_bounds : {Time, Time}?
    @balances_loaded = false

    # Soldes de clôture par numéro de compte (`Api::Accounting.trial_balance`)
    # de l'exercice de la période de travail ; `nil` sans le droit de lire
    # les éditions ou sans exercice. Calculés une seule fois par requête,
    # échec compris (`@balances_loaded`). Seuls les comptes mouvementés y figurent : un compte
    # parent n'a pas de solde propre, l'interface ne cumule rien.
    def balances : Hash(String, BigDecimal)?
      return @balances if @balances_loaded
      @balances_loaded = true
      return unless can?("accounting.report.read")
      period = Shell.working_period(request, current.actor)
      from = period.try { |value| Partiduo::Api::Core.fiscal_year(current.actor, value.fiscal_year_id).starts_on }
      view = Partiduo::Api::Accounting.trial_balance(current.actor,
        Partiduo::Api::Accounting::TrialBalanceQuery.new(date_from: from, date_to: period.try(&.ends_on)))
      @balance_bounds = {view.date_from, view.date_to}
      @balances = view.rows.to_h { |row| {row.number, row.closing.signed} }
    rescue Partiduo::Api::AccessDenied | Partiduo::Api::NotFound
      nil
    end

    def balance_cell(values : Hash(String, BigDecimal), number : String) : Table::Cell
      bounds = @balance_bounds
      value = values[number]?
      return Table::Cell.new("", sort: BigDecimal.new(0), csv: "") unless value && bounds
      url = "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => number, "from" => bounds[0].to_s("%Y-%m-%d"), "to" => bounds[1].to_s("%Y-%m-%d")})}"
      Table::Cell.new(fmt.amount(value), url, sort: value, csv: fmt.csv_amount(value))
    end

    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.reference"), crumb("accounting.menu.acc_chart", reverse("accounting:chart"))]
    end

    def kind_label(kind : Partiduo::Api::Accounting::AccountKind) : String
      I18n.t("accounting.account_kinds.#{kind.code}")
    end

    def account_form(number = "", label = "", parent = "", kind = "", direct_use = true, inherit : Bool = true) : Form
      kinds = KINDS.map { |item| option(item.code, kind_label(item)) }
      kinds.unshift(option("", I18n.t("ui.chart.kind_inherited"))) if inherit
      Form.new([Form::Group.new(nil, [
        Form::Field.new("number", I18n.t("ui.chart.number"), value: number, required: true, mono: true, maxlength: 40,
          help: I18n.t("ui.chart.number_help")),
        Form::Field.new("label", I18n.t("ui.chart.label"), value: label, required: true, maxlength: 255, wide: true),
        Form::Field.new("parent", I18n.t("ui.chart.parent"), value: parent, mono: true, maxlength: 40,
          help: I18n.t("ui.chart.parent_help")),
        Form::Field.new("kind", I18n.t("ui.chart.kind"), "select", kind, options: kinds),
        Form::Field.new("direct_use", I18n.t("ui.chart.direct_use"), "checkbox", direct_use ? "1" : "",
          help: I18n.t("ui.chart.direct_use_help")),
      ])])
    end

    def read_input : Partiduo::Api::Accounting::AccountInput
      Partiduo::Api::Accounting::AccountInput.new(
        number: field("number"), label: field("label"), parent: field("parent").presence,
        kind: KINDS.find { |item| item.code == field("kind") }, direct_use: checkbox("direct_use"),
      )
    end

    def posted_form(errors : Array(Partiduo::Api::FieldError), inherit : Bool = true) : Form
      account_form(field("number"), field("label"), field("parent"), field("kind"), checkbox("direct_use"), inherit).add_errors(errors, fmt)
    end

    # Ligne d'un compte ; `depth` : retrait dans l'arbre. `tree` faux (liste
    # triée sur une autre colonne que le numéro) : ni retrait ni niveau, qui
    # n'auraient plus de sens. Un compte hors usage direct porte une
    # étiquette, pas seulement une couleur (WCAG 1.4.1) ; le niveau est lu
    # par les technologies d'assistance (WCAG 1.3.1).
    def account_row(line : Partiduo::Api::Accounting::ChartLineView, depth : Int32, tree : Bool = true) : Table::Row
      account = line.account
      css = [] of String
      if tree
        css << "pd-depth-#{depth.clamp(0, 6)}"
        css << "pd-class" if depth.zero?
      end
      css << "pd-row-closed" unless account.direct_use
      number = Table::Cell.new(account.number, reverse("accounting:account", id: account.id), sort: account.number,
        tag: account.direct_use ? nil : I18n.t("ui.chart.not_direct_use"))
      number.hidden_text = I18n.t("ui.chart.level", level: depth + 1) if tree
      Table::Row.new([
        number,
        Table::Cell.new(account.label),
        Table::Cell.new(kind_label(account.kind)),
        Table::Cell.new(yes_no(account.direct_use)),
        Table::Cell.new(line.children_count.to_s, sort: BigDecimal.new(line.children_count)),
      ] + (balances.try { |values| [balance_cell(values, account.number)] } || [] of Table::Cell), css.join(" "))
    end

    # L'arbre n'a de sens que dans l'ordre des numéros.
    def tree_order? : Bool
      query("sort").in?("", "number")
    end

    def account_columns : Array(Table::Column)
      [
        Table::Column.new("number", I18n.t("ui.chart.number"), "mono"),
        Table::Column.new("label", I18n.t("ui.chart.label")),
        Table::Column.new("kind", I18n.t("ui.chart.kind"), secondary: true),
        Table::Column.new("direct_use", I18n.t("ui.chart.direct_use_short"), secondary: true),
        Table::Column.new("children", I18n.t("ui.chart.children"), "amount", secondary: true),
      ] + (balances ? [Table::Column.new("balance", I18n.t("ui.reports.columns.balance"), "amount")] : [] of Table::Column)
    end
  end

  # Plan comptable en arbre, par classe (maquette, écran « Plan comptable »).
  class ChartHandler < ChartScreen
    def get
      lines = Partiduo::Api::Accounting.chart(current.actor)
      classes = lines.select(&.depth.zero?).map(&.account.number[0].to_s).uniq!
      wanted = query("class")
      wanted = "" unless classes.includes?(wanted)
      shown = wanted.empty? ? lines : lines.select(&.account.number.starts_with?(wanted))
      params = wanted.empty? ? {} of String => String : {"class" => wanted}
      table = Table.new(I18n.t("accounting.menu.acc_chart"), account_columns, shown.map { |line| account_row(line, line.depth, tree_order?) },
        reverse("accounting:chart"), params, empty_message: I18n.t("ui.chart.empty"))
      tabs = [Screen::Tab.new(I18n.t("ui.chart.all_classes"), tab_url(""), wanted.empty?)]
      classes.each { |code| tabs << Screen::Tab.new(I18n.t("ui.chart.class", class: code), tab_url(code), code == wanted) }
      actions = [] of Screen::Action
      actions << link_action("ui.chart.new", reverse("accounting:account_new"), "primary", "plus") if can?("accounting.account.write")
      if can?(Partiduo::Api::Accounting::CHART_IMPORT_PERMISSION) && can?("accounting.account.write")
        actions << link_action("ui.imports.import_chart", reverse("accounting:chart_import"), icon: "upload")
      end
      actions << link_action("ui.imports.export_chart", reverse("accounting:chart_export"), icon: "download")
      filters = search_filters(wanted.empty? ? [] of Form::Field : [Form::Field.new("class", "", "hidden", wanted)])
      list_page(I18n.t("accounting.menu.acc_chart"), table, crumbs[0, 1], "ui.chart.csv_name", actions, tabs,
        I18n.t("ui.chart.classes"), filters)
    end

    private def tab_url(code : String) : String
      path = reverse("accounting:chart")
      values = {} of String => String
      values["class"] = code unless code.empty?
      values["q"] = query("q") unless query("q").empty?
      values.empty? ? path : "#{path}?#{URI::Params.encode(values)}"
    end
  end

  class AccountNewHandler < ChartScreen
    def get
      require!("ACCOUNTING", "accounting.account.write")
      parent = query("parent")
      show(account_form(number: parent, parent: parent))
    end

    def post
      result = Partiduo::Api::Accounting.create_account(current.actor, read_input)
      if account = result.value?
        flash["success"] = I18n.t("ui.chart.created", number: account.number)
        return go(reverse("accounting:account", id: account.id))
      end
      show(posted_form(result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.chart.new"), crumbs, form, reverse("accounting:account_new"), I18n.t("ui.forms.create"),
        reverse("accounting:chart"))
    end
  end

  # Consultation d'un compte : fiche du compte, sous-comptes, fiches
  # rattachées, usages par défaut.
  class AccountShowHandler < ChartScreen
    def get
      actor = current.actor
      account = Partiduo::Api::Accounting.account_by_id(actor, id_param)
      parent = account.parent_id.try { |id| Partiduo::Api::Accounting.account_by_id(actor, id) }
      items = [
        Screen::Item.new(I18n.t("ui.chart.number"), account.number, mono: true),
        Screen::Item.new(I18n.t("ui.chart.label"), account.label),
        Screen::Item.new(I18n.t("ui.chart.parent"), parent ? "#{parent.number} — #{parent.label}" : "",
          parent.try { |item| reverse("accounting:account", id: item.id) }),
        Screen::Item.new(I18n.t("ui.chart.kind"), kind_label(account.kind)),
        Screen::Item.new(I18n.t("ui.chart.direct_use"), yes_no(account.direct_use)),
      ]
      usages = Partiduo::Api::Accounting.default_accounts(actor).select(&.account.id.==(account.id)).map do |usage|
        I18n.t("accounting.default_accounts.#{usage.code}")
      end
      items << Screen::Item.new(I18n.t("ui.chart.default_for"), usages.join(", "))
      sections = [Screen::Section.new(I18n.t("ui.chart.summary"), items)]

      children = Partiduo::Api::Accounting.chart(actor, account.number).reject(&.depth.zero?)
      table = Table.new(I18n.t("ui.chart.sub_accounts"), account_columns, children.map { |line| account_row(line, line.depth - 1, tree_order?) },
        reverse("accounting:account", id: account.id), empty_message: I18n.t("ui.chart.no_sub_account"), id: "pd-sub-accounts")
      prepare(table)
      return export_response(table, "compte-#{account.number}") if export?
      sections << Screen::Section.new(I18n.t("ui.chart.sub_accounts"), table: table)
      sections << cards_section(account) if can?("cards.card.read")

      detail_page(I18n.t("ui.chart.title", number: account.number, label: account.label), crumbs, sections,
        account_actions(account))
    end

    private def cards_section(account) : Screen::Section
      ids = Partiduo::Api::Accounting.card_ids_for_account(current.actor, account.number)
      items = ids.first(50).compact_map do |card_id|
        card = Partiduo::Api::Cards.card(current.actor, card_id)
        Screen::Item.new(card.code, card.name, reverse("cards:show", id: card.id))
      rescue Partiduo::Api::NotFound
        nil
      end
      Screen::Section.new(I18n.t("ui.chart.cards"), items, note: items.empty? ? I18n.t("ui.chart.no_card") : nil)
    end

    private def account_actions(account) : Array(Screen::Action)
      actions = [] of Screen::Action
      # Navigation transverse (ADR-005 D9) : mouvements du compte.
      if can?("accounting.entry.read")
        actions << link_action("ui.accounts.moves", "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => account.number})}", icon: "book-open")
      end
      return actions unless can?("accounting.account.write")
      actions << link_action("ui.forms.edit", reverse("accounting:account_edit", id: account.id), "primary")
      actions << link_action("ui.chart.new_child", "#{reverse("accounting:account_new")}?#{URI::Params.encode({"parent" => account.number})}", icon: "plus")
      actions << post_action("ui.forms.delete", reverse("accounting:account_delete", id: account.id), "ui.chart.delete_confirm", "danger")
      actions
    end
  end

  class AccountEditHandler < ChartScreen
    def get
      require!("ACCOUNTING", "accounting.account.write")
      account = Partiduo::Api::Accounting.account_by_id(current.actor, id_param)
      show(account_form(account.number, account.label, account.parent_number || "", account.kind.code, account.direct_use, false), account)
    end

    def post
      account = Partiduo::Api::Accounting.account_by_id(current.actor, id_param)
      result = Partiduo::Api::Accounting.update_account(current.actor, account.id, read_input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.chart.updated", number: updated.number)
        return go(reverse("accounting:account", id: updated.id))
      end
      show(posted_form(result.errors, false), account)
    end

    private def show(form : Form, account : Partiduo::Api::Accounting::AccountView)
      form_page(I18n.t("ui.chart.edit", number: account.number), crumbs, form, reverse("accounting:account_edit", id: account.id),
        I18n.t("ui.forms.save"), reverse("accounting:account", id: account.id))
    end
  end

  class AccountDeleteHandler < ChartScreen
    def post
      account = Partiduo::Api::Accounting.account_by_id(current.actor, id_param)
      if flash_result(Partiduo::Api::Accounting.delete_account(current.actor, account.id), "ui.chart.deleted", {"number" => account.number})
        go(reverse("accounting:chart"))
      else
        go(reverse("accounting:account", id: account.id))
      end
    end
  end
end
