# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Paramètres du dossier (menus `core:company`, `core:modules`,
  # `core:currencies`, `cards:categories`) : société, modules activables
  # (ADR-006 D2), devises et cours, catégories de fiches. Tout passe par
  # `Partiduo::Api` (D-UI-052).
  abstract class SettingsScreen < ReferenceHandler
    def settings_crumbs(label_key : String, route : String) : Array(Screen::Crumb)
      [crumb("core.menu.settings"), crumb(label_key, reverse(route))]
    end
  end

  # --- Société -----------------------------------------------------------------

  abstract class CompanyScreen < SettingsScreen
    alias Core = Partiduo::Api::Core

    PERMISSION = "core.settings.manage"

    # Libellé d'un champ, dans le vocabulaire du type de dossier (« Nom du
    # foyer » pour la raison sociale).
    def label(name : String) : String
      I18n.t(kind_key("core.settings.fields.#{name}"))
    end

    # Champ montré dans ce type de dossier : un foyer n'a ni forme juridique,
    # ni capital, ni RCS, ni SIREN, ni TVA, ni identifiant créancier
    # (`FolderKind::BUSINESS_FIELDS`, D-FOY-009).
    def shown?(name : String) : Bool
      FolderKind.company_field?(FolderKind.of(request), name)
    end

    def company_form(input : Core::SettingsInput) : Form
      identity = %w[company_name legal_form rcs siren vat_number creditor_identifier].select { |name| shown?(name) }.map do |name|
        Form::Field.new(name, label(name), value: text_of(input, name), mono: %w[siren vat_number creditor_identifier].includes?(name),
          required: name == "company_name", wide: name == "company_name")
      end
      if shown?("share_capital")
        identity.insert(2, Form::Field.new("share_capital", label("share_capital"), "number", fmt.input_number(input.share_capital, 2), mono: true))
      end
      address = %w[street street_number postcode city country_code phone email].map do |name|
        Form::Field.new(name, label(name), name == "email" ? "email" : "text", text_of(input, name), mono: name == "country_code",
          maxlength: name == "country_code" ? 2 : nil)
      end
      locales = Locale.available.map { |code| option(code, I18n.t("core.settings.locales.#{code}")) }
      levels = Core::AUTH_LEVELS.map { |level| option(level.to_s, I18n.t("core.settings.auth_levels.level_#{level}")) }
      methods = Core::AUTH_METHODS.map do |method|
        Form::Field.new("auth_method:#{method}", I18n.t("core.settings.auth_methods.#{method}"), "checkbox",
          (input.auth_methods || [] of String).includes?(method) ? "1" : "")
      end
      instance = [
        Form::Field.new("default_locale", label("default_locale"), "select", input.default_locale || "fr", options: locales),
        Form::Field.new("domain", label("domain"), value: input.domain || "", mono: true, help: I18n.t("ui.company.domain_help")),
        Form::Field.new("auth_minimum_level", label("auth_minimum_level"), "select", input.auth_minimum_level.to_s, options: levels),
        Form::Field.new("session_duration_minutes", label("session_duration_minutes"), value: input.session_duration_minutes.to_s,
          mono: true),
        # Approbation des opérations sensibles des extensions (A-SEPA-3).
        Form::Field.new("approval_mode", label("approval_mode"), "select", input.approval_mode || "single",
          options: Core::APPROVAL_MODES.map { |mode| option(mode, I18n.t("core.settings.approval_modes.#{mode}")) }),
        Form::Field.new("approval_reauth_minutes", label("approval_reauth_minutes"),
          value: (input.approval_reauth_minutes || 5).to_s, mono: true),
      ]
      Form.new([
        Form::Group.new(I18n.t(kind_key("ui.company.identity")), identity),
        Form::Group.new(I18n.t("ui.company.address"), address),
        Form::Group.new(I18n.t("ui.company.instance"), instance),
        Form::Group.new(label("auth_methods"), methods),
      ])
    end

    def read_company(current_settings : Core::SettingsView, form_errors : Array({String, String})) : Core::SettingsInput
      minutes = integer("session_duration_minutes", form_errors)
      reauth = integer("approval_reauth_minutes", form_errors, required: false)
      # Champs d'entreprise que l'écran ne propose pas (foyer) : la saisie
      # décrit la ligne entière, elle reprend donc les valeurs enregistrées.
      capital = shown?("share_capital") ? decimal("share_capital", form_errors) : current_settings.share_capital
      kept = ->(name : String, value : String) { shown?(name) ? field(name) : value }
      level = field("auth_minimum_level").to_i?
      methods = Core::AUTH_METHODS.select { |method| checkbox("auth_method:#{method}") }
      Core::SettingsInput.new(
        company_name: field("company_name"), legal_form: kept.call("legal_form", current_settings.legal_form),
        share_capital: capital, rcs: kept.call("rcs", current_settings.rcs), siren: kept.call("siren", current_settings.siren),
        vat_number: kept.call("vat_number", current_settings.vat_number), street: field("street"),
        street_number: field("street_number"), postcode: field("postcode"), city: field("city"),
        country_code: field("country_code").upcase.presence, phone: field("phone"), email: field("email"),
        tax_regime: current_settings.tax_regime, default_locale: field("default_locale").presence,
        domain: field("domain").presence, auth_methods: methods, auth_minimum_level: level,
        session_duration_minutes: minutes, creditor_identifier: posted("creditor_identifier"),
        approval_mode: field("approval_mode").presence, approval_reauth_minutes: reauth,
      )
    end

    # Champ envoyé par le formulaire, ou `nil` s'il n'y figure pas (le
    # contrat garde alors la valeur enregistrée).
    private def posted(name : String) : String?
      request.data.has_key?(name) ? field(name) : nil
    end

    private def text_of(input : Core::SettingsInput, name : String) : String
      {
        "company_name" => input.company_name, "legal_form" => input.legal_form, "rcs" => input.rcs,
        "siren" => input.siren, "vat_number" => input.vat_number, "street" => input.street,
        "street_number" => input.street_number, "postcode" => input.postcode, "city" => input.city,
        "country_code" => input.country_code, "phone" => input.phone, "email" => input.email, "domain" => input.domain,
        "creditor_identifier" => input.creditor_identifier,
      }[name]? || ""
    end
  end

  class CompanyHandler < CompanyScreen
    def get
      settings = Core.settings(current.actor)
      identity = [
        {"company_name", Screen::Item.new(label("company_name"), settings.company_name)},
        {"legal_form", Screen::Item.new(label("legal_form"), settings.legal_form)},
        {"share_capital", Screen::Item.new(label("share_capital"), settings.share_capital.try { |value| fmt.amount(value) } || "")},
        {"rcs", Screen::Item.new(label("rcs"), settings.rcs)},
        {"siren", Screen::Item.new(label("siren"), settings.siren, mono: true)},
        {"vat_number", Screen::Item.new(label("vat_number"), settings.vat_number, mono: true)},
        {"creditor_identifier", Screen::Item.new(label("creditor_identifier"), settings.creditor_identifier, mono: true)},
        {"tax_regime", Screen::Item.new(label("tax_regime"), I18n.t(settings.tax_regime_key))},
      ].compact_map { |(name, item)| item if shown?(name) }
      address = [
        Screen::Item.new(I18n.t("ui.company.address"),
          [[settings.street_number, settings.street].reject(&.empty?).join(" "),
           [settings.postcode, settings.city].reject(&.empty?).join(" "), settings.country_code].reject(&.empty?).join(", ")),
        Screen::Item.new(label("phone"), settings.phone),
        Screen::Item.new(label("email"), settings.email),
      ]
      instance = [
        Screen::Item.new(label("default_locale"), I18n.t("core.settings.locales.#{settings.default_locale}")),
        Screen::Item.new(label("domain"), settings.domain, mono: true),
        Screen::Item.new(label("auth_methods"), settings.auth_methods.map { |method| I18n.t("core.settings.auth_methods.#{method}") }.join(", ")),
        Screen::Item.new(label("auth_minimum_level"), I18n.t("core.settings.auth_levels.level_#{settings.auth_minimum_level}")),
        Screen::Item.new(label("session_duration_minutes"), settings.session_duration_minutes.to_s),
        Screen::Item.new(label("approval_mode"), I18n.t("core.settings.approval_modes.#{settings.approval_mode}")),
        Screen::Item.new(label("approval_reauth_minutes"), settings.approval_reauth_minutes.to_s),
      ]
      actions = [] of Screen::Action
      actions << link_action("ui.forms.edit", reverse("core:company_edit"), "primary") if can?(PERMISSION)
      detail_page(settings.company_name, settings_crumbs("core.menu.core_company", "core:company"), [
        Screen::Section.new(I18n.t(kind_key("ui.company.identity")), identity),
        Screen::Section.new(I18n.t("ui.company.address"), address),
        Screen::Section.new(I18n.t("ui.company.instance"), instance),
      ], actions, intro: I18n.t(kind_key("ui.company.intro")))
    end
  end

  class CompanyEditHandler < CompanyScreen
    def get
      require!("CORE", PERMISSION)
      show(company_form(Core.settings(current.actor).to_input))
    end

    def post
      require!("CORE", PERMISSION)
      settings = Core.settings(current.actor)
      form_errors = [] of {String, String}
      input = read_company(settings, form_errors)
      if form_errors.empty?
        result = Core.update_settings(current.actor, input)
        if result.success?
          flash["success"] = I18n.t(kind_key("ui.company.updated"))
          return go(reverse("core:company"))
        end
        return show(refused(input, form_errors, result.errors))
      end
      show(refused(input, form_errors))
    end

    private def refused(input, form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = company_form(input)
      %w[share_capital session_duration_minutes approval_reauth_minutes].each do |name|
        form.fields.find(&.name.==(name)).try(&.value=(field(name)))
      end
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end

    private def show(form : Form)
      form_page(I18n.t(kind_key("ui.company.edit")), settings_crumbs("core.menu.core_company", "core:company"), form,
        reverse("core:company_edit"), I18n.t("ui.forms.save"), reverse("core:company"))
    end
  end

  # --- Modules -----------------------------------------------------------------

  class ModulesHandler < SettingsScreen
    PERMISSION = "core.modules.manage"

    def get
      require!("CORE", PERMISSION)
      modules = Partiduo::Api::Modules.list(current.actor)
      names = modules.to_h { |item| {item.code, I18n.t(item.name_key)} }
      columns = [
        Table::Column.new("name", I18n.t("ui.modules.name")),
        Table::Column.new("code", I18n.t("ui.modules.code"), "mono", secondary: true),
        Table::Column.new("kind", I18n.t("ui.modules.kind")),
        Table::Column.new("depends", I18n.t("ui.modules.depends_on"), secondary: true),
        Table::Column.new("state", I18n.t("ui.modules.state")),
        Table::Column.new("actions", I18n.t("ui.forms.actions"), "actions"),
      ]
      rows = modules.sort_by { |item| {item.kind == "socle" ? 0 : (item.kind == "module" ? 1 : 2), item.code} }.map do |item|
        dependencies = item.depends_on.map { |code| names[code]? || code } +
                       item.depends_on_any.map(&.map { |code| names[code]? || code }.join(I18n.t("ui.modules.or")))
        actions = [] of Screen::Action
        unless item.kind == "socle"
          actions << if item.active
            post_action("ui.modules.deactivate", reverse("core:module_toggle", code: item.code, command: "deactivate"),
              "ui.modules.deactivate_confirm", "small")
          else
            post_action("ui.modules.activate", reverse("core:module_toggle", code: item.code, command: "activate"), nil, "small")
          end
        end
        Table::Row.new([
          Table::Cell.new(names[item.code]),
          Table::Cell.new(item.code),
          Table::Cell.new(I18n.t("ui.modules.kinds.#{item.kind}")),
          Table::Cell.new(dependencies.join(", ")),
          Table::Cell.new(I18n.t(item.active ? "ui.forms.active" : "ui.forms.inactive")),
          Table::Cell.new("", actions: actions),
        ], item.active ? "" : "pd-row-closed")
      end
      table = Table.new(I18n.t("core.menu.core_modules"), columns, rows, reverse("core:modules"))
      list_page(I18n.t("core.menu.core_modules"), table, [crumb("core.menu.settings")], "ui.modules.csv_name",
        intro: I18n.t("ui.modules.intro"), filter: false)
    end
  end

  class ModuleToggleHandler < SettingsScreen
    def post
      require!("CORE", ModulesHandler::PERMISSION)
      code = params["code"].to_s
      piece = Partiduo::Api::Modules.get(current.actor, code)
      name = I18n.t(piece.name_key)
      case params["command"].to_s
      when "activate"
        flash_result(Partiduo::Api::Modules.activate(current.actor, code), "ui.modules.activated", {"name" => name})
      when "deactivate"
        flash_result(Partiduo::Api::Modules.deactivate(current.actor, code), "ui.modules.deactivated", {"name" => name})
      else
        raise Partiduo::Api::NotFound.new("command", params["command"].to_s)
      end
      go(reverse("core:modules"))
    end
  end

  # --- Devises -----------------------------------------------------------------

  abstract class CurrenciesScreen < SettingsScreen
    alias Core = Partiduo::Api::Core

    PERMISSION = "core.currency.write"

    def crumbs : Array(Screen::Crumb)
      settings_crumbs("core.menu.core_currencies", "core:currencies")
    end

    def currency_form(code = "", name = "", decimals = "2", rate = "", valid_from = "", creating = true) : Form
      fields = [] of Form::Field
      fields << Form::Field.new("code", I18n.t("ui.currencies.code"), value: code, required: true, mono: true, maxlength: 3,
        help: I18n.t("ui.currencies.code_help")) if creating
      fields << Form::Field.new("name", I18n.t("ui.currencies.name"), value: name, required: true, maxlength: 80)
      fields << Form::Field.new("decimals", I18n.t("ui.currencies.decimals"), value: decimals, mono: true)
      if creating
        fields << Form::Field.new("rate", I18n.t("ui.currencies.rate"), "number", rate, required: true, mono: true,
          help: I18n.t("ui.currencies.rate_help"))
        fields << Form::Field.new("valid_from", I18n.t("ui.currencies.valid_from"), "date", valid_from, required: true)
      end
      Form.new([Form::Group.new(nil, fields)])
    end

    def rate_form(rate = "", valid_from = "") : Form
      Form.new([Form::Group.new(nil, [
        Form::Field.new("rate", I18n.t("ui.currencies.rate"), "number", rate, required: true, mono: true,
          help: I18n.t("ui.currencies.rate_help")),
        Form::Field.new("valid_from", I18n.t("ui.currencies.valid_from"), "date", valid_from, required: true),
      ])])
    end
  end

  class CurrenciesHandler < CurrenciesScreen
    def get
      show(can?(PERMISSION) ? currency_form : nil)
    end

    def post
      require!("CORE", PERMISSION)
      form_errors = [] of {String, String}
      decimals = integer("decimals", form_errors) || 2
      rate = decimal("rate", form_errors, required: true)
      valid_from = date("valid_from", form_errors)
      if form_errors.empty?
        input = Core::CurrencyInput.new(code: field("code"), name: field("name"), decimals: decimals, rate: rate,
          valid_from: valid_from)
        result = Core.create_currency(current.actor, input)
        if currency = result.value?
          flash["success"] = I18n.t("ui.currencies.created", code: currency.code)
          return go(reverse("core:currency", code: currency.code))
        end
        return show(refused(form_errors, result.errors), 422)
      end
      show(refused(form_errors), 422)
    end

    private def refused(form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = currency_form(field("code"), field("name"), field("decimals"), field("rate"), field("valid_from"))
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end

    private def show(form : Form?, status : Int32 = 200)
      columns = [
        Table::Column.new("code", I18n.t("ui.currencies.code"), "mono"),
        Table::Column.new("name", I18n.t("ui.currencies.name")),
        Table::Column.new("rate", I18n.t("ui.currencies.latest_rate"), "amount"),
        Table::Column.new("valid_from", I18n.t("ui.currencies.valid_from"), secondary: true),
      ]
      rows = Core.currencies(current.actor).map do |currency|
        latest = currency.latest_rate
        Table::Row.new([
          Table::Cell.new(currency.code, reverse("core:currency", code: currency.code)),
          Table::Cell.new(currency.name, tag: currency.base ? I18n.t("ui.currencies.base") : nil),
          Table::Cell.new(latest.try { |item| fmt.number(item.rate, 8) } || "", sort: latest.try(&.rate) || BigDecimal.new(0)),
          Table::Cell.new(latest.try { |item| fmt.date(item.valid_from) } || "", sort: date_key(latest.try(&.valid_from))),
        ])
      end
      table = Table.new(I18n.t("core.menu.core_currencies"), columns, rows, reverse("core:currencies"))
      set_form(form, reverse("core:currencies"), I18n.t("ui.forms.create"), title: I18n.t("ui.currencies.new")) if form
      list_page(I18n.t("core.menu.core_currencies"), table, [crumb("core.menu.settings")], "ui.currencies.csv_name",
        intro: I18n.t("ui.currencies.intro"), status: status)
    end
  end

  class CurrencyHandler < CurrenciesScreen
    def get
      show(can?(PERMISSION) ? rate_form : nil)
    end

    # Nouveau cours.
    def post
      require!("CORE", PERMISSION)
      currency = Core.currency(current.actor, params["code"].to_s)
      form_errors = [] of {String, String}
      rate = decimal("rate", form_errors, required: true)
      valid_from = date("valid_from", form_errors)
      if form_errors.empty? && rate && valid_from
        result = Core.add_currency_rate(current.actor, Core::CurrencyRateInput.new(currency.code, rate, valid_from))
        if result.success?
          flash["success"] = I18n.t("ui.currencies.rate_added", code: currency.code)
          return go(reverse("core:currency", code: currency.code))
        end
        return show(refused(form_errors, result.errors), 422)
      end
      show(refused(form_errors), 422)
    end

    private def refused(form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = rate_form(field("rate"), field("valid_from"))
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end

    private def show(form : Form?, status : Int32 = 200)
      currency = Core.currency(current.actor, params["code"].to_s)
      columns = [Table::Column.new("valid_from", I18n.t("ui.currencies.valid_from")),
                 Table::Column.new("rate", I18n.t("ui.currencies.rate"), "amount")]
      rows = currency.rates.reverse.map do |item|
        Table::Row.new([Table::Cell.new(fmt.date(item.valid_from), sort: date_key(item.valid_from)),
                        Table::Cell.new(fmt.number(item.rate, 8), sort: item.rate)])
      end
      table = Table.new(I18n.t("ui.currencies.rates"), columns, rows, reverse("core:currency", code: currency.code),
        empty_message: I18n.t("ui.currencies.no_rate"))
      items = [
        Screen::Item.new(I18n.t("ui.currencies.code"), currency.code, mono: true),
        Screen::Item.new(I18n.t("ui.currencies.name"), currency.name),
        Screen::Item.new(I18n.t("ui.currencies.decimals"), currency.decimals.to_s),
      ]
      actions = [] of Screen::Action
      if can?(PERMISSION) && !currency.base
        actions << link_action("ui.forms.edit", reverse("core:currency_edit", code: currency.code), "primary")
        actions << post_action("ui.forms.delete", reverse("core:currency_delete", code: currency.code), "ui.currencies.delete_confirm", "danger")
      end
      set_form(form, reverse("core:currency", code: currency.code), I18n.t("ui.currencies.add_rate")) if form && !currency.base
      detail_page("#{currency.code} — #{currency.name}", crumbs, [
        Screen::Section.new(currency.name, items),
        Screen::Section.new(I18n.t("ui.currencies.rates"), table: table,
          note: currency.base ? I18n.t("ui.currencies.base_note") : nil),
      ], actions, status_tag: currency.base ? I18n.t("ui.currencies.base") : nil, status: status)
    end
  end

  class CurrencyEditHandler < CurrenciesScreen
    def get
      require!("CORE", PERMISSION)
      currency = Core.currency(current.actor, params["code"].to_s)
      show(currency_form(currency.code, currency.name, currency.decimals.to_s, creating: false), currency.code)
    end

    def post
      require!("CORE", PERMISSION)
      currency = Core.currency(current.actor, params["code"].to_s)
      form_errors = [] of {String, String}
      decimals = integer("decimals", form_errors)
      if form_errors.empty? && decimals
        result = Core.update_currency(current.actor, currency.code, field("name"), decimals)
        if result.success?
          flash["success"] = I18n.t("ui.currencies.updated", code: currency.code)
          return go(reverse("core:currency", code: currency.code))
        end
        return show(currency_form(currency.code, field("name"), field("decimals"), creating: false).add_errors(result.errors, fmt), currency.code)
      end
      form = currency_form(currency.code, field("name"), field("decimals"), creating: false)
      form_errors.each { |(name, message)| form.add_error(name, message) }
      show(form, currency.code)
    end

    private def show(form : Form, code : String)
      form_page(I18n.t("ui.currencies.edit", code: code), crumbs, form, reverse("core:currency_edit", code: code),
        I18n.t("ui.forms.save"), reverse("core:currency", code: code))
    end
  end

  class CurrencyDeleteHandler < CurrenciesScreen
    def post
      require!("CORE", PERMISSION)
      code = params["code"].to_s
      if flash_result(Core.delete_currency(current.actor, code), "ui.currencies.deleted", {"code" => code.upcase})
        go(reverse("core:currencies"))
      else
        go(reverse("core:currency", code: code))
      end
    end
  end

  # --- Catégories de fiches ------------------------------------------------------

  abstract class CategoriesScreen < SettingsScreen
    alias Cards = Partiduo::Api::Cards

    PERMISSION = "cards.category.manage"
    # Lignes vides proposées pour de nouveaux attributs.
    BLANK_ROWS = 3

    def crumbs : Array(Screen::Crumb)
      settings_crumbs("cards.menu.cards_categories", "cards:categories")
    end

    def category_form(input : Cards::CategoryInput, creating : Bool) : Form
      kinds = FolderKind.card_kinds(FolderKind.of(request), Cards::KINDS).map { |kind| option(kind, card_kind_label(kind)) }
      types = %w[text number date boolean card].map { |type| option(type, I18n.t("cards.value_types.#{type}")) }
      main = [] of Form::Field
      main << Form::Field.new("code", I18n.t("ui.categories.code"), value: input.code, required: true, mono: true, maxlength: 32,
        help: I18n.t("ui.categories.code_help")) if creating
      main << Form::Field.new("name", I18n.t("ui.categories.name"), value: input.name, required: true, maxlength: 255)
      main << Form::Field.new("kind", I18n.t(kind_key("ui.categories.kind")), "select", input.kind, options: kinds, required: true) if creating
      main << Form::Field.new("description", I18n.t("ui.categories.description"), "textarea", input.description || "", wide: true)
      groups = [Form::Group.new(nil, main)]
      rows = input.attributes + Array.new(BLANK_ROWS) { Cards::AttributeInput.new(key: "", label: "") }
      rows.each_with_index do |attribute, index|
        groups << Form::Group.new(I18n.t("ui.categories.attribute", number: (index + 1).to_s), [
          Form::Field.new("attributes[#{index}].key", I18n.t("ui.categories.attribute_key"), value: attribute.key, mono: true,
            maxlength: 40, help: index == 0 ? I18n.t("ui.categories.attribute_key_help") : nil),
          Form::Field.new("attributes[#{index}].label", I18n.t("ui.categories.attribute_label"), value: attribute.label, maxlength: 255),
          Form::Field.new("attributes[#{index}].value_type", I18n.t("ui.categories.attribute_type"), "select", attribute.value_type,
            options: types),
          Form::Field.new("attributes[#{index}].required", I18n.t("ui.categories.attribute_required"), "checkbox",
            attribute.required ? "1" : ""),
        ])
      end
      Form.new(groups)
    end

    # Saisie ; les lignes d'attribut vides sont écartées. Le formulaire
    # refusé est rebâti depuis cette saisie : le rang d'un attribut dans les
    # erreurs du contrat (`attributes[i].key`) est celui de sa ligne.
    def read_category(current_code : String? = nil, current_kind : String? = nil) : Cards::CategoryInput
      attributes = [] of Cards::AttributeInput
      index = 0
      while request.data.has_key?("attributes[#{index}].key")
        key = field("attributes[#{index}].key")
        label = field("attributes[#{index}].label")
        unless key.empty? && label.empty?
          attributes << Cards::AttributeInput.new(key: key, label: label,
            value_type: field("attributes[#{index}].value_type").presence || "text", required: checkbox("attributes[#{index}].required"))
        end
        index += 1
      end
      Cards::CategoryInput.new(code: current_code || field("code").upcase, name: field("name"),
        kind: current_kind || field("kind"), description: field("description", strip: false).strip, attributes: attributes)
    end

    def refused_category(input : Cards::CategoryInput, creating : Bool, errors : Array(Partiduo::Api::FieldError)) : Form
      category_form(input, creating).add_errors(errors, fmt)
    end
  end

  class CategoriesHandler < CategoriesScreen
    def get
      columns = [
        Table::Column.new("name", I18n.t("ui.categories.name")),
        Table::Column.new("code", I18n.t("ui.categories.code"), "mono"),
        Table::Column.new("kind", I18n.t(kind_key("ui.categories.kind"))),
        Table::Column.new("attributes", I18n.t("ui.categories.attributes"), "amount", secondary: true),
        Table::Column.new("cards", I18n.t("ui.categories.cards"), "amount"),
      ]
      kinds = FolderKind.card_kinds(FolderKind.of(request), Cards::KINDS)
      rows = Cards.categories(current.actor).select { |category| kinds.includes?(category.kind) }.map do |category|
        Table::Row.new([
          Table::Cell.new(category_label(category.code, category.name), reverse("cards:category", id: category.id)),
          Table::Cell.new(category.code),
          Table::Cell.new(card_kind_label(category.kind)),
          Table::Cell.new(category.attributes.size.to_s, sort: BigDecimal.new(category.attributes.size)),
          Table::Cell.new(category.card_count.to_s, sort: BigDecimal.new(category.card_count)),
        ])
      end
      title = I18n.t(kind_key("cards.menu.cards_categories"))
      table = Table.new(title, columns, rows, reverse("cards:categories"))
      actions = [] of Screen::Action
      actions << link_action("ui.categories.new", reverse("cards:category_new"), "primary", "plus") if can?(PERMISSION)
      list_page(title, table, [crumb("core.menu.settings")], "ui.categories.csv_name", actions,
        intro: I18n.t(kind_key("ui.categories.intro")))
    end
  end

  class CategoryNewHandler < CategoriesScreen
    def get
      require!("CARDS", PERMISSION)
      show(category_form(Cards::CategoryInput.new(code: "", name: "", kind: "customer"), true))
    end

    def post
      require!("CARDS", PERMISSION)
      input = read_category
      result = Cards.create_category(current.actor, input)
      if category = result.value?
        flash["success"] = I18n.t("ui.categories.created", name: category.name)
        return go(reverse("cards:category", id: category.id))
      end
      show(refused_category(input, true, result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.categories.new"), crumbs, form, reverse("cards:category_new"), I18n.t("ui.forms.create"),
        reverse("cards:categories"))
    end
  end

  class CategoryHandler < CategoriesScreen
    def get
      category = Cards.category(current.actor, id_param)
      items = [
        Screen::Item.new(I18n.t("ui.categories.code"), category.code, mono: true),
        Screen::Item.new(I18n.t(kind_key("ui.categories.kind")), card_kind_label(category.kind)),
        Screen::Item.new(I18n.t("ui.categories.description"), category.description),
        Screen::Item.new(I18n.t("ui.categories.cards"), category.card_count.to_s,
          reverse("cards:index") + "?" + URI::Params.encode({"category" => category.id.to_s})),
      ]
      columns = [
        Table::Column.new("key", I18n.t("ui.categories.attribute_key"), "mono"),
        Table::Column.new("label", I18n.t("ui.categories.attribute_label")),
        Table::Column.new("type", I18n.t("ui.categories.attribute_type")),
        Table::Column.new("required", I18n.t("ui.categories.attribute_required")),
      ]
      rows = category.attributes.map do |attribute|
        Table::Row.new([Table::Cell.new(attribute.key), Table::Cell.new(attribute.label),
                        Table::Cell.new(I18n.t("cards.value_types.#{attribute.value_type}")), Table::Cell.new(yes_no(attribute.required))])
      end
      table = Table.new(I18n.t("ui.categories.attributes"), columns, rows, reverse("cards:category", id: category.id),
        empty_message: I18n.t("ui.categories.no_attribute"))
      table.exportable = false
      actions = [] of Screen::Action
      if can?(PERMISSION)
        actions << link_action("ui.forms.edit", reverse("cards:category_edit", id: category.id), "primary")
        actions << post_action("ui.forms.delete", reverse("cards:category_delete", id: category.id), "ui.categories.delete_confirm", "danger")
      end
      name = category_label(category.code, category.name)
      detail_page(name, crumbs, [Screen::Section.new(name, items),
                                 Screen::Section.new(I18n.t("ui.categories.attributes"), table: table)], actions)
    end
  end

  class CategoryEditHandler < CategoriesScreen
    def get
      require!("CARDS", PERMISSION)
      category = Cards.category(current.actor, id_param)
      attributes = category.attributes.map do |attribute|
        Cards::AttributeInput.new(key: attribute.key, label: attribute.label, value_type: attribute.value_type,
          required: attribute.required, max_length: attribute.max_length, decimals: attribute.decimals)
      end
      show(category_form(Cards::CategoryInput.new(code: category.code, name: category.name, kind: category.kind,
        description: category.description, attributes: attributes), false), category)
    end

    def post
      require!("CARDS", PERMISSION)
      category = Cards.category(current.actor, id_param)
      input = read_category(category.code, category.kind)
      # Bornes des attributs existants conservées (non modifiables ici).
      bounds = category.attributes.to_h { |attribute| {attribute.key, attribute} }
      input = input.copy_with(attributes: input.attributes.map do |attribute|
        known = bounds[attribute.key]?
        known ? attribute.copy_with(max_length: known.max_length, decimals: known.decimals) : attribute
      end)
      result = Cards.update_category(current.actor, category.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.categories.updated", name: updated.name)
        return go(reverse("cards:category", id: updated.id))
      end
      show(refused_category(input, false, result.errors), category)
    end

    private def show(form : Form, category : Cards::CategoryView)
      form_page(I18n.t("ui.categories.edit", name: category.name), crumbs, form, reverse("cards:category_edit", id: category.id),
        I18n.t("ui.forms.save"), reverse("cards:category", id: category.id))
    end
  end

  class CategoryDeleteHandler < CategoriesScreen
    def post
      require!("CARDS", PERMISSION)
      category = Cards.category(current.actor, id_param)
      if flash_result(Cards.delete_category(current.actor, category.id), "ui.categories.deleted", {"name" => category.name})
        go(reverse("cards:categories"))
      else
        go(reverse("cards:category", id: category.id))
      end
    end
  end
end
