# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Fournisseurs d'identité (ADR-002 D3, BLOCAGES B-CRIT-002) : liste,
  # création par type (SAML 2.0, OpenID Connect, tout type enregistré par
  # `Partiduo::Auth::Federation`), modification, niveau de sécurité reconnu,
  # activation. Les paramètres suivent la description du type rendue par le
  # contrat ; un secret n'est jamais réaffiché et se garde s'il est laissé
  # vide. Autorisation locale : un fournisseur atteste l'identité, les
  # identités se rattachent aux utilisateurs existants sur leur fiche.
  # DECISIONS D-R5-010.
  abstract class IdentityProvidersScreen < UsersScreen
    PROVIDERS = "auth.providers.manage"
    LEVELS    = [1, 2, 3]

    def providers_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.settings"), crumb("core.menu.core_users", reverse("core:users")),
       crumb("ui.providers.title", reverse("core:identity_providers"))]
    end

    def kinds : Array(Auth::ProviderKindView)
      @kinds ||= Auth.identity_provider_kinds(current.actor)
    end

    @kinds : Array(Auth::ProviderKindView)?

    def kind_label(kind : String) : String
      I18n.t("auth.provider_kinds.#{kind}", default: kind)
    end

    def level_label(level : Int32) : String
      I18n.t("ui.providers.levels.level_#{level}")
    end

    # Formulaire d'un type : code (création seulement), nom, niveau, actif,
    # puis les paramètres du type.
    def provider_form(kind : Auth::ProviderKindView, input : Auth::IdentityProviderInput,
                      detail : Auth::IdentityProviderDetailView? = nil) : Form
      general = [] of Form::Field
      if detail
        general << Form::Field.new("code", I18n.t("ui.providers.code"), "hidden", input.code)
      else
        general << Form::Field.new("code", I18n.t("ui.providers.code"), value: input.code, required: true, mono: true,
          maxlength: 64, help: I18n.t("ui.providers.code_help"))
      end
      general << Form::Field.new("kind", I18n.t("ui.providers.kind"), "hidden", kind.kind)
      general << Form::Field.new("name", I18n.t("ui.providers.name"), value: input.name, required: true, maxlength: 100)
      general << Form::Field.new("level", I18n.t("ui.providers.level"), "select", input.level.to_s,
        options: LEVELS.map { |level| option(level.to_s, level_label(level)) }, help: I18n.t("ui.providers.level_help"))
      general << Form::Field.new("active", I18n.t("ui.providers.active"), "checkbox", input.active ? "1" : "",
        help: I18n.t("ui.providers.active_help"))
      settings = kind.settings.map do |setting|
        name = "settings.#{setting.key}"
        value = input.settings[setting.key]? || ""
        if setting.secret
          kept = detail.try(&.secrets_set.includes?(setting.key)) || false
          Form::Field.new(name, I18n.t(setting.label_key), "password", "", required: setting.required && !kept,
            help: I18n.t(kept ? "ui.providers.secret_kept" : "ui.providers.secret_help"))
        elsif setting.multiline
          Form::Field.new(name, I18n.t(setting.label_key), "textarea", value, required: setting.required, wide: true)
        else
          Form::Field.new(name, I18n.t(setting.label_key), value: value, required: setting.required, wide: true, mono: true)
        end
      end
      Form.new([Form::Group.new(nil, general),
                Form::Group.new(I18n.t("ui.providers.settings", kind: kind_label(kind.kind)), settings)])
    end

    def read_input(kind : Auth::ProviderKindView, code : String) : Auth::IdentityProviderInput
      settings = kind.settings.to_h do |setting|
        name = "settings.#{setting.key}"
        {setting.key, setting.multiline ? field(name, strip: false).strip : field(name)}
      end
      Auth::IdentityProviderInput.new(code: code, kind: kind.kind, name: field("name"),
        level: field("level").to_i? || 2, active: checkbox("active"), settings: settings)
    end

    # Formulaire refusé : valeurs saisies (jamais un secret), erreurs rangées.
    def refused(kind, input, errors, detail = nil) : Form
      provider_form(kind, input, detail).add_errors(errors, fmt)
    end

    def kind_of(code : String) : Auth::ProviderKindView
      kinds.find(&.kind.==(code)) || raise Partiduo::Api::NotFound.new("identity_provider_kind", code)
    end

    # Adresse de retour à donner au fournisseur (ACS SAML, redirection OIDC).
    def return_url(kind : String, code : String) : String
      name = kind == "saml" ? "login_federated_acs" : "login_federated_callback"
      # `request.host` porte déjà le port éventuel (en-tête Host).
      "#{request.scheme}://#{request.host}#{reverse(name, code: code)}"
    end
  end

  class IdentityProvidersHandler < IdentityProvidersScreen
    def get
      require!("AUTH", PROVIDERS)
      columns = [
        Table::Column.new("code", I18n.t("ui.providers.code"), "mono"),
        Table::Column.new("name", I18n.t("ui.providers.name")),
        Table::Column.new("kind", I18n.t("ui.providers.kind")),
        Table::Column.new("level", I18n.t("ui.providers.level"), secondary: true),
        Table::Column.new("state", I18n.t("ui.providers.state")),
      ]
      rows = Auth.identity_providers(current.actor).map do |provider|
        Table::Row.new([
          Table::Cell.new(provider.code, reverse("core:identity_provider_edit", code: provider.code)),
          Table::Cell.new(provider.name),
          Table::Cell.new(kind_label(provider.kind)),
          Table::Cell.new(level_label(provider.level), sort: provider.level.to_s),
          Table::Cell.new(I18n.t(provider.active ? "ui.forms.active" : "ui.forms.inactive")),
        ], provider.active ? "" : "pd-row-closed")
      end
      table = Table.new(I18n.t("ui.providers.title"), columns, rows, reverse("core:identity_providers"),
        empty_message: I18n.t("ui.providers.empty"))
      actions = kinds.map do |kind|
        link_action(I18n.t("ui.providers.new", kind: kind_label(kind.kind)),
          "#{reverse("core:identity_provider_new")}?#{URI::Params.encode({"kind" => kind.kind})}", "primary", "plus")
      end
      list_page(I18n.t("ui.providers.title"), table, providers_crumbs[0, 2], "ui.providers.csv_name", actions,
        intro: I18n.t("ui.providers.intro"))
    end
  end

  class IdentityProviderNewHandler < IdentityProvidersScreen
    def get
      require!("AUTH", PROVIDERS)
      kind = kind_of(query("kind"))
      input = Auth::IdentityProviderInput.new(code: "", kind: kind.kind, name: "")
      show(kind, provider_form(kind, input))
    end

    def post
      require!("AUTH", PROVIDERS)
      kind = kind_of(field("kind"))
      code = field("code").downcase
      input = read_input(kind, code)
      if Auth.identity_providers(current.actor).any?(&.code.==(code))
        form = provider_form(kind, input).add_error("code", I18n.t("ui.providers.code_taken"))
        return show(kind, form)
      end
      result = Auth.save_identity_provider(current.actor, input)
      if provider = result.value?
        flash["success"] = I18n.t("ui.providers.created", name: provider.name)
        return go(reverse("core:identity_provider_edit", code: provider.code))
      end
      show(kind, refused(kind, input, result.errors))
    end

    private def show(kind : Auth::ProviderKindView, form : Form)
      form_page(I18n.t("ui.providers.new", kind: kind_label(kind.kind)), providers_crumbs, form,
        reverse("core:identity_provider_new"), I18n.t("ui.forms.create"), reverse("core:identity_providers"),
        intro: I18n.t("ui.providers.return_help", url: return_url(kind.kind, "<code>")))
    end
  end

  class IdentityProviderEditHandler < IdentityProvidersScreen
    def get
      require!("AUTH", PROVIDERS)
      detail = Auth.identity_provider(current.actor, params["code"].to_s)
      kind = kind_of(detail.kind)
      input = Auth::IdentityProviderInput.new(code: detail.code, kind: detail.kind, name: detail.name,
        level: detail.level, active: detail.active, settings: detail.settings)
      show(kind, detail, provider_form(kind, input, detail))
    end

    def post
      require!("AUTH", PROVIDERS)
      detail = Auth.identity_provider(current.actor, params["code"].to_s)
      kind = kind_of(detail.kind)
      input = read_input(kind, detail.code)
      result = Auth.save_identity_provider(current.actor, input)
      if provider = result.value?
        flash["success"] = I18n.t("ui.providers.updated", name: provider.name)
        return go(reverse("core:identity_providers"))
      end
      show(kind, detail, refused(kind, input, result.errors, detail))
    end

    private def show(kind : Auth::ProviderKindView, detail : Auth::IdentityProviderDetailView, form : Form)
      intro = [I18n.t("ui.providers.return_help", url: return_url(kind.kind, detail.code)),
               I18n.t("ui.providers.linked", count: detail.linked_identities)].join(" ")
      form_page(I18n.t("ui.providers.edit", name: detail.name), providers_crumbs, form,
        reverse("core:identity_provider_edit", code: detail.code), I18n.t("ui.forms.save"),
        reverse("core:identity_providers"), intro: intro)
    end
  end

  # Identités fédérées d'un utilisateur : rattacher (fournisseur + identifiant
  # chez lui), détacher. Sans rattachement, le fournisseur n'ouvre rien
  # (ADR-002 D3).
  class UserIdentitiesHandler < IdentityProvidersScreen
    def get
      require!("AUTH", USERS)
      require!("AUTH", PROVIDERS)
      show(Auth.user(current.actor, id_param))
    end

    def post
      require!("AUTH", USERS)
      require!("AUTH", PROVIDERS)
      user = Auth.user(current.actor, id_param)
      result = Auth.link_federated_identity(current.actor, user.id, field("provider"), field("subject"))
      if result.success?
        flash["success"] = I18n.t("ui.providers.linked_done", email: user.email)
        return go(reverse("core:user_identities", id: user.id))
      end
      show(user, link_form.add_errors(result.errors, fmt), 422)
    end

    private def link_form : Form
      providers = Auth.identity_providers(current.actor).map { |provider| option(provider.code, "#{provider.name} (#{provider.code})") }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("provider", I18n.t("ui.providers.provider"), "select", field("provider"), options: providers, required: true),
        Form::Field.new("subject", I18n.t("ui.providers.subject"), value: field("subject"), required: true, mono: true,
          wide: true, help: I18n.t("ui.providers.subject_help")),
      ])])
    end

    private def show(user : Auth::UserView, form : Form = link_form, status : Int32 = 200)
      columns = [
        Table::Column.new("provider", I18n.t("ui.providers.provider"), "mono"),
        Table::Column.new("subject", I18n.t("ui.providers.subject"), "mono"),
        Table::Column.new("last_used", I18n.t("ui.providers.last_used"), secondary: true),
        Table::Column.new("actions", I18n.t("ui.providers.actions"), "actions"),
      ]
      rows = Auth.federated_identities(current.actor, user.id).map do |identity|
        unlink = Screen::Action.new(I18n.t("ui.providers.unlink"),
          reverse("core:user_identity_unlink", id: user.id, identity: identity.id), "post", "danger",
          confirm: I18n.t("ui.providers.unlink_confirm"))
        Table::Row.new([
          Table::Cell.new(identity.provider), Table::Cell.new(identity.subject),
          Table::Cell.new(identity.last_used_at.try { |moment| fmt.datetime(moment) } || ""),
          Table::Cell.new("", actions: [unlink]),
        ])
      end
      table = Table.new(I18n.t("ui.providers.identities"), columns, rows, reverse("core:user_identities", id: user.id),
        empty_message: I18n.t("ui.providers.no_identity"), id: "pd-user-identities")
      table.exportable = false
      set_form(form, reverse("core:user_identities", id: user.id), I18n.t("ui.providers.link"), reverse("core:user", id: user.id))
      detail_page(I18n.t("ui.providers.identities_of", email: user.email),
        crumbs + [Screen::Crumb.new(user.email, reverse("core:user", id: user.id))],
        [Screen::Section.new(I18n.t("ui.providers.identities"), table: table)],
        intro: I18n.t("ui.providers.identities_intro"), status: status)
    end
  end

  class UserIdentityUnlinkHandler < IdentityProvidersScreen
    def post
      require!("AUTH", USERS)
      require!("AUTH", PROVIDERS)
      user = Auth.user(current.actor, id_param)
      identity = params["identity"].to_s.to_i64
      unless Auth.federated_identities(current.actor, user.id).any?(&.id.==(identity))
        raise Partiduo::Api::NotFound.new("federated_identity", identity)
      end
      flash_result(Auth.unlink_federated_identity(current.actor, identity), "ui.providers.unlinked", {"email" => user.email})
      go(reverse("core:user_identities", id: user.id))
    end
  end
end
