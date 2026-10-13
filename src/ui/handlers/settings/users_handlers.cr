# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Utilisateurs, profils et droits par journal (menu `core:users`, ADR-002
  # D4, ADR-003 D4) : tout passe par `Partiduo::Api::Auth`. Un utilisateur
  # créé reçoit une invitation (courriel à son adresse, lien aussi affiché à
  # l'administrateur, D-UI-051). Le comptable externe est un utilisateur de
  # rôle `comptable` ; le profil « Comptable invité (lecture) » lui donne
  # l'accès en lecture d'ADR-006 D4.
  abstract class UsersScreen < ReferenceHandler
    alias Auth = Partiduo::Api::Auth

    USERS    = "auth.users.manage"
    PROFILES = "auth.profiles.manage"
    ROLES    = %w[member accountant]

    def crumbs : Array(Screen::Crumb)
      [crumb("core.menu.settings"), crumb("core.menu.core_users", reverse("core:users"))]
    end

    def profile_names : Hash(Int64, String)
      can?(PROFILES) ? Auth.profiles(current.actor).to_h { |profile| {profile.id, profile.name} } : {} of Int64 => String
    end

    def state(user : Auth::UserView) : String
      key = if user.revoked
              "revoked"
            elsif !user.active
              "expired"
            elsif user.locked
              "locked"
            else
              "active"
            end
      I18n.t("ui.users.states.#{key}")
    end

    def user_form(input : Auth::UserInput) : Form
      profiles = Auth.profiles(current.actor).map { |profile| option(profile.id.to_s, profile.name) }
      roles = ROLES.map { |role| option(role, I18n.t(FolderKind.role_key(request, role))) }
      locales = Locale.available.map { |code| option(code, I18n.t("core.settings.locales.#{code}")) }
      fields = [
        Form::Field.new("email", I18n.t("ui.users.email"), "email", input.email, required: true, wide: true, maxlength: 254),
        Form::Field.new("first_name", I18n.t("ui.users.first_name"), value: input.first_name, maxlength: 100),
        Form::Field.new("last_name", I18n.t("ui.users.last_name"), value: input.last_name, maxlength: 100),
        Form::Field.new("locale", I18n.t("ui.users.locale"), "select", input.locale, options: locales),
      ]
      access = [
        Form::Field.new("role", I18n.t("ui.users.role"), "select", input.role, options: roles, required: true,
          help: I18n.t("ui.users.role_help")),
        Form::Field.new("profile_id", I18n.t("ui.users.profile"), "select", input.profile_id.to_s,
          options: [option("", I18n.t("ui.users.no_profile"))] + profiles),
        Form::Field.new("access_ends_on", I18n.t("ui.users.access_ends_on"), "date",
          input.access_ends_on.try(&.to_s("%Y-%m-%d")) || "", help: I18n.t("ui.users.access_ends_on_help")),
      ]
      Form.new([Form::Group.new(nil, fields), Form::Group.new(I18n.t("ui.users.access"), access)])
    end

    def read_user(form_errors : Array({String, String})) : Auth::UserInput
      ends = field("access_ends_on").presence.try do |text|
        value = fmt.parse_date(text)
        form_errors << {"access_ends_on", I18n.t("ui.forms.invalid_date")} unless value
        value
      end
      Auth::UserInput.new(
        email: field("email"), first_name: field("first_name"), last_name: field("last_name"),
        locale: field("locale").presence || "fr", role: field("role").presence || "member",
        profile_id: field("profile_id").to_i64?, access_ends_on: ends,
      )
    end

    def refused_user(input : Auth::UserInput, form_errors, errors = [] of Partiduo::Api::FieldError) : Form
      form = user_form(input)
      form.fields.find(&.name.==("access_ends_on")).try(&.value=(field("access_ends_on")))
      form_errors.each { |(name, message)| form.add_error(name, message) }
      form.add_errors(errors, fmt)
    end

    # Invitation : courriel à l'adresse enregistrée, et lien affiché à
    # l'administrateur qui peut le transmettre lui-même (D-UI-051).
    def announce_invitation(token : Auth::TokenView) : Nil
      TokenMail.send(token, "invitation")
      link = "#{TokenMail.base_url(token.domain)}#{reverse("invitation", token: token.token)}"
      flash["info"] = I18n.t("ui.users.invitation_link", link: link, email: token.email,
        date: fmt.datetime(token.expires_at, Time::Location::UTC))
    end
  end

  class UsersHandler < UsersScreen
    def get
      require!("AUTH", USERS)
      names = profile_names
      columns = [
        Table::Column.new("email", I18n.t("ui.users.email"), "mono"),
        Table::Column.new("name", I18n.t("ui.users.name")),
        Table::Column.new("role", I18n.t("ui.users.role")),
        Table::Column.new("profile", I18n.t("ui.users.profile"), secondary: true),
        Table::Column.new("last_login", I18n.t("ui.users.last_login"), secondary: true),
        Table::Column.new("state", I18n.t("ui.users.state")),
      ]
      rows = Auth.users(current.actor).map do |user|
        Table::Row.new([
          Table::Cell.new(user.email, reverse("core:user", id: user.id)),
          Table::Cell.new(user.full_name),
          Table::Cell.new(I18n.t(FolderKind.role_key(request, user.role))),
          Table::Cell.new(user.profile_id.try { |id| names[id]? } || ""),
          Table::Cell.new(user.last_login_at.try { |moment| fmt.datetime(moment, Time::Location::UTC) } || "",
            sort: user.last_login_at.try(&.to_s("%Y-%m-%dT%H:%M:%S")) || ""),
          Table::Cell.new(state(user)),
        ], user.active ? "" : "pd-row-closed")
      end
      table = Table.new(I18n.t("core.menu.core_users"), columns, rows, reverse("core:users"),
        empty_message: I18n.t("ui.users.empty"))
      actions = [link_action("ui.users.new", reverse("core:user_new"), "primary", "plus")]
      actions << link_action("ui.profiles.title", reverse("core:profiles")) if can?(PROFILES)
      actions << link_action("ui.audit.title", reverse("core:audit")) if can?(AuditHandler::AUDIT)
      actions << link_action("ui.providers.title", reverse("core:identity_providers")) if can?("auth.providers.manage")
      list_page(I18n.t("core.menu.core_users"), table, crumbs[0, 1], "ui.users.csv_name", actions,
        intro: I18n.t("ui.users.intro"))
    end
  end

  class UserNewHandler < UsersScreen
    def get
      require!("AUTH", USERS)
      show(user_form(Auth::UserInput.new(email: "", locale: I18n.locale.to_s)))
    end

    def post
      require!("AUTH", USERS)
      form_errors = [] of {String, String}
      input = read_user(form_errors)
      return show(refused_user(input, form_errors)) unless form_errors.empty?
      result = Auth.create_user(current.actor, input)
      if created = result.value?
        flash["success"] = I18n.t("ui.users.created", email: created.user.email)
        announce_invitation(created.invitation)
        return go(reverse("core:user", id: created.user.id))
      end
      show(refused_user(input, form_errors, result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.users.new"), crumbs, form, reverse("core:user_new"), I18n.t("ui.users.invite"),
        reverse("core:users"), intro: I18n.t("ui.users.new_intro"))
    end
  end

  class UserHandler < UsersScreen
    def get
      require!("AUTH", USERS)
      user = Auth.user(current.actor, id_param)
      names = profile_names
      identity = [
        Screen::Item.new(I18n.t("ui.users.email"), user.email, mono: true),
        Screen::Item.new(I18n.t("ui.users.name"), user.full_name),
        Screen::Item.new(I18n.t("ui.users.locale"), I18n.t("core.settings.locales.#{user.locale}")),
      ]
      access = [
        Screen::Item.new(I18n.t("ui.users.role"), I18n.t(FolderKind.role_key(request, user.role))),
        Screen::Item.new(I18n.t("ui.users.profile"), user.profile_id.try { |id| names[id]? } || I18n.t("ui.users.no_profile"),
          user.profile_id.try { |id| can?(PROFILES) ? reverse("core:profile", id: id) : nil }),
        Screen::Item.new(I18n.t("ui.users.access_ends_on"), user.access_ends_on.try { |day| fmt.date(day) } || ""),
        Screen::Item.new(I18n.t("ui.users.state"), state(user)),
        Screen::Item.new(I18n.t("ui.users.failed_attempts"), user.failed_attempts.to_s),
        Screen::Item.new(I18n.t("ui.users.last_login"), user.last_login_at.try { |moment| fmt.datetime(moment, Time::Location::UTC) } || ""),
      ]
      security = [
        Screen::Item.new(I18n.t("ui.users.has_password"), yes_no(user.has_password)),
        Screen::Item.new(I18n.t("ui.users.totp"), yes_no(user.totp_enabled)),
        Screen::Item.new(I18n.t("ui.users.passkeys"), user.passkey_count.to_s),
        Screen::Item.new(I18n.t("ui.users.ledger_security"), yes_no(user.ledger_security)),
      ]
      actions = [link_action("ui.forms.edit", reverse("core:user_edit", id: user.id), "primary")]
      actions << link_action("ui.users.ledgers", reverse("core:user_ledgers", id: user.id)) if module_active?("ACCOUNTING")
      actions << link_action("ui.providers.identities", reverse("core:user_identities", id: user.id)) if can?("auth.providers.manage")
      actions << post_action("ui.users.reinvite", reverse("core:user_command", id: user.id, command: "invite"), "ui.users.reinvite_confirm")
      actions << post_action("ui.users.unlock", reverse("core:user_command", id: user.id, command: "unlock")) if user.locked
      if user.revoked
        actions << post_action("ui.users.restore", reverse("core:user_command", id: user.id, command: "restore"))
      elsif current.actor.user_id != user.id
        actions << post_action("ui.users.revoke", reverse("core:user_command", id: user.id, command: "revoke"), "ui.users.revoke_confirm", "danger")
      end
      sections = [
        Screen::Section.new(I18n.t("ui.users.identity"), identity),
        Screen::Section.new(I18n.t("ui.users.access"), access),
        Screen::Section.new(I18n.t("ui.users.security"), security),
      ]
      detail_page(user.full_name.presence || user.email, crumbs, sections, actions,
        status_tag: user.active ? nil : state(user))
    end
  end

  class UserEditHandler < UsersScreen
    def get
      require!("AUTH", USERS)
      user = Auth.user(current.actor, id_param)
      input = Auth::UserInput.new(email: user.email, first_name: user.first_name, last_name: user.last_name,
        locale: user.locale, role: user.role, profile_id: user.profile_id, access_ends_on: user.access_ends_on)
      show(user_form(input), user)
    end

    def post
      require!("AUTH", USERS)
      user = Auth.user(current.actor, id_param)
      form_errors = [] of {String, String}
      input = read_user(form_errors)
      return show(refused_user(input, form_errors), user) unless form_errors.empty?
      result = Auth.update_user(current.actor, user.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.users.updated", email: updated.email)
        return go(reverse("core:user", id: updated.id))
      end
      show(refused_user(input, form_errors, result.errors), user)
    end

    private def show(form : Form, user : Auth::UserView)
      form_page(I18n.t("ui.users.edit", email: user.email), crumbs, form, reverse("core:user_edit", id: user.id),
        I18n.t("ui.forms.save"), reverse("core:user", id: user.id))
    end
  end

  # Actions d'une ligne : révocation, réouverture, déblocage, invitation.
  class UserCommandHandler < UsersScreen
    def post
      require!("AUTH", USERS)
      user = Auth.user(current.actor, id_param)
      case params["command"].to_s
      when "revoke"
        flash_result(Auth.revoke_access(current.actor, user.id), "ui.users.revoked", {"email" => user.email})
      when "restore"
        flash_result(Auth.restore_access(current.actor, user.id, user.access_ends_on.try { |day| day < Time.utc ? nil : day }),
          "ui.users.restored", {"email" => user.email})
      when "unlock"
        flash_result(Auth.unlock_user(current.actor, user.id), "ui.users.unlocked", {"email" => user.email})
      when "invite"
        announce_invitation(Auth.issue_invitation(current.actor, user.id))
      else
        raise Partiduo::Api::NotFound.new("command", params["command"].to_s)
      end
      go(reverse("core:user", id: user.id))
    end
  end

  # Droits par journal (héritiers de `user_sec_jrn`) : sécurité activée ou
  # non, puis écriture, lecture ou aucun accès par journal.
  class UserLedgersHandler < UsersScreen
    ACCESSES = %w[W R X]

    def get
      require!("AUTH", USERS)
      require!("ACCOUNTING", "accounting.ledger.read")
      user = Auth.user(current.actor, id_param)
      show(user)
    end

    def post
      require!("AUTH", USERS)
      require!("ACCOUNTING", "accounting.ledger.read")
      user = Auth.user(current.actor, id_param)
      errors = [] of Partiduo::Api::FieldError
      result = Auth.set_ledger_security(current.actor, user.id, checkbox("ledger_security"))
      errors.concat(result.errors)
      Partiduo::Api::Accounting.ledgers(current.actor).each do |ledger|
        access = field("ledger_#{ledger.id}")
        next unless ACCESSES.includes?(access)
        errors.concat(Auth.set_ledger_access(current.actor, user.id, ledger.id, access).errors)
      end
      if errors.empty?
        flash["success"] = I18n.t("ui.users.ledgers_saved", email: user.email)
        return go(reverse("core:user", id: user.id))
      end
      flash["danger"] = errors.map { |error| fmt.message(error) }.join(" ")
      show(Auth.user(current.actor, user.id))
    end

    private def show(user : Auth::UserView)
      accesses = Auth.ledger_accesses(current.actor, user.id).to_h { |row| {row.ledger_id, row.access} }
      options = ACCESSES.map { |code| option(code, I18n.t("ui.users.ledger_access.#{code.downcase}")) }
      fields = Partiduo::Api::Accounting.ledgers(current.actor).map do |ledger|
        Form::Field.new("ledger_#{ledger.id}", "#{ledger.code} — #{ledger.name}", "select", accesses[ledger.id]? || "X", options: options)
      end
      form = Form.new([
        Form::Group.new(nil, [Form::Field.new("ledger_security", I18n.t("ui.users.ledger_security"), "checkbox",
          user.ledger_security ? "1" : "", help: I18n.t("ui.users.ledger_security_help"))]),
        Form::Group.new(I18n.t("ui.users.ledgers"), fields),
      ])
      form_page(I18n.t("ui.users.ledgers_title", email: user.email), crumbs, form, reverse("core:user_ledgers", id: user.id),
        I18n.t("ui.forms.save"), reverse("core:user", id: user.id))
    end
  end

  # --- Profils ---------------------------------------------------------------------

  abstract class ProfilesScreen < UsersScreen
    def profile_crumbs : Array(Screen::Crumb)
      crumbs + [crumb("ui.profiles.title", reverse("core:profiles"))]
    end

    # Une case par permission des pièces actives, regroupées par pièce.
    def profile_form(input : Auth::ProfileInput) : Form
      catalog = Partiduo::Api::Modules.permissions(current.actor)
      modules = Partiduo::Api::Modules.list(current.actor).to_h { |item| {item.code, I18n.t(item.name_key)} }
      groups = [Form::Group.new(nil, [
        Form::Field.new("name", I18n.t("ui.profiles.name"), value: input.name, required: true, maxlength: 100),
        Form::Field.new("description", I18n.t("ui.profiles.description"), "textarea", input.description, wide: true),
        Form::Field.new("admin", I18n.t("ui.profiles.admin"), "checkbox", input.admin ? "1" : "", help: I18n.t("ui.profiles.admin_help")),
      ])]
      catalog.group_by(&.module_code).each do |code, permissions|
        fields = permissions.map do |permission|
          Form::Field.new("perm:#{permission.name}", I18n.t(permission.label_key), "checkbox",
            input.permissions.includes?(permission.name) ? "1" : "", help: permission.name)
        end
        groups << Form::Group.new(modules[code]? || code, fields)
      end
      Form.new(groups)
    end

    # Permissions cochées ; celles d'une pièce inactive déjà portées par le
    # profil (`kept`) sont conservées (elles reprennent effet à sa réactivation).
    def read_profile(kept = [] of String) : Auth::ProfileInput
      catalog = Partiduo::Api::Modules.permissions(current.actor).map(&.name)
      names = catalog.select { |name| checkbox("perm:#{name}") } + kept.reject { |name| catalog.includes?(name) }
      Auth::ProfileInput.new(name: field("name"), description: field("description", strip: false).strip,
        admin: checkbox("admin"), permissions: names)
    end

    def refused_profile(input : Auth::ProfileInput, errors : Array(Partiduo::Api::FieldError)) : Form
      profile_form(input).add_errors(errors, fmt)
    end
  end

  class ProfilesHandler < ProfilesScreen
    def get
      require!("AUTH", PROFILES)
      users = Auth.users(current.actor).group_by(&.profile_id)
      columns = [
        Table::Column.new("name", I18n.t("ui.profiles.name")),
        Table::Column.new("code", I18n.t("ui.profiles.code"), "mono", secondary: true),
        Table::Column.new("admin", I18n.t("ui.profiles.admin_short")),
        Table::Column.new("permissions", I18n.t("ui.profiles.permissions"), "amount"),
        Table::Column.new("users", I18n.t("ui.profiles.users"), "amount"),
      ]
      rows = Auth.profiles(current.actor).map do |profile|
        Table::Row.new([
          Table::Cell.new(profile.name, reverse("core:profile", id: profile.id)),
          Table::Cell.new(profile.code),
          Table::Cell.new(yes_no(profile.admin)),
          Table::Cell.new(profile.admin ? I18n.t("ui.profiles.all") : profile.permissions.size.to_s,
            sort: BigDecimal.new(profile.admin ? 9999 : profile.permissions.size)),
          Table::Cell.new((users[profile.id]?.try(&.size) || 0).to_s, sort: BigDecimal.new(users[profile.id]?.try(&.size) || 0)),
        ])
      end
      table = Table.new(I18n.t("ui.profiles.title"), columns, rows, reverse("core:profiles"), empty_message: I18n.t("ui.profiles.empty"))
      actions = [
        link_action("ui.profiles.new", reverse("core:profile_new"), "primary", "plus"),
        post_action("ui.profiles.defaults", reverse("core:profiles_defaults")),
      ]
      list_page(I18n.t("ui.profiles.title"), table, crumbs, "ui.profiles.csv_name", actions, intro: I18n.t("ui.profiles.intro"))
    end
  end

  # Profils par défaut manquants (administrateur, comptable, comptable invité).
  class ProfilesDefaultsHandler < ProfilesScreen
    def post
      require!("AUTH", PROFILES)
      Auth.ensure_default_profiles(current.actor)
      flash["success"] = I18n.t("ui.profiles.defaults_done")
      go(reverse("core:profiles"))
    end
  end

  class ProfileNewHandler < ProfilesScreen
    def get
      require!("AUTH", PROFILES)
      show(profile_form(Auth::ProfileInput.new(name: "")))
    end

    def post
      require!("AUTH", PROFILES)
      input = read_profile
      result = Auth.create_profile(current.actor, input)
      if profile = result.value?
        flash["success"] = I18n.t("ui.profiles.created", name: profile.name)
        return go(reverse("core:profile", id: profile.id))
      end
      show(refused_profile(input, result.errors))
    end

    private def show(form : Form)
      form_page(I18n.t("ui.profiles.new"), profile_crumbs, form, reverse("core:profile_new"), I18n.t("ui.forms.create"),
        reverse("core:profiles"))
    end
  end

  class ProfileHandler < ProfilesScreen
    def get
      require!("AUTH", PROFILES)
      profile = Auth.profile(current.actor, id_param)
      catalog = Partiduo::Api::Modules.permissions(current.actor)
      granted = profile.admin ? catalog : catalog.select { |permission| profile.permissions.includes?(permission.name) }
      columns = [Table::Column.new("permission", I18n.t("ui.profiles.permission")),
                 Table::Column.new("code", I18n.t("ui.profiles.code"), "mono", secondary: true)]
      rows = granted.map { |permission| Table::Row.new([Table::Cell.new(I18n.t(permission.label_key)), Table::Cell.new(permission.name)]) }
      table = Table.new(I18n.t("ui.profiles.permissions"), columns, rows, reverse("core:profile", id: profile.id),
        empty_message: I18n.t("ui.profiles.no_permission"))
      table.exportable = false
      members = Auth.users(current.actor).select(&.profile_id.==(profile.id))
      items = [
        Screen::Item.new(I18n.t("ui.profiles.code"), profile.code, mono: true),
        Screen::Item.new(I18n.t("ui.profiles.description"), profile.description),
        Screen::Item.new(I18n.t("ui.profiles.admin"), yes_no(profile.admin)),
        Screen::Item.new(I18n.t("ui.profiles.users"), members.map(&.email).join(", ")),
      ]
      actions = [
        link_action("ui.forms.edit", reverse("core:profile_edit", id: profile.id), "primary"),
        post_action("ui.forms.delete", reverse("core:profile_delete", id: profile.id), "ui.profiles.delete_confirm", "danger"),
      ]
      detail_page(profile.name, profile_crumbs, [Screen::Section.new(profile.name, items),
                                                 Screen::Section.new(I18n.t("ui.profiles.permissions"), table: table)], actions)
    end
  end

  class ProfileEditHandler < ProfilesScreen
    def get
      require!("AUTH", PROFILES)
      profile = Auth.profile(current.actor, id_param)
      show(profile_form(Auth::ProfileInput.new(name: profile.name, description: profile.description,
        admin: profile.admin, permissions: profile.permissions)), profile)
    end

    def post
      require!("AUTH", PROFILES)
      profile = Auth.profile(current.actor, id_param)
      input = read_profile(profile.permissions)
      result = Auth.update_profile(current.actor, profile.id, input)
      if updated = result.value?
        flash["success"] = I18n.t("ui.profiles.updated", name: updated.name)
        return go(reverse("core:profile", id: updated.id))
      end
      show(refused_profile(input, result.errors), profile)
    end

    private def show(form : Form, profile : Auth::ProfileView)
      form_page(I18n.t("ui.profiles.edit", name: profile.name), profile_crumbs, form, reverse("core:profile_edit", id: profile.id),
        I18n.t("ui.forms.save"), reverse("core:profile", id: profile.id))
    end
  end

  class ProfileDeleteHandler < ProfilesScreen
    def post
      require!("AUTH", PROFILES)
      profile = Auth.profile(current.actor, id_param)
      if flash_result(Auth.delete_profile(current.actor, profile.id), "ui.profiles.deleted", {"name" => profile.name})
        go(reverse("core:profiles"))
      else
        go(reverse("core:profile", id: profile.id))
      end
    end
  end
end

module PartiduoUi
  # Journal d'audit nominatif (héritier d'`audit_connect`, ADR-002 D4) : les
  # 1 000 derniers événements, filtrés par utilisateur ou par état.
  class AuditHandler < UsersScreen
    AUDIT = "auth.audit.view"
    LIMIT = 1000

    def get
      require!("AUTH", AUDIT)
      users = can?(USERS) ? Auth.users(current.actor) : [] of Auth::UserView
      user_id = query("user").to_i64?
      state = query("state").presence
      events = Auth.audit_events(current.actor, Auth::AuditQuery.new(user_id: user_id, state: state, limit: LIMIT))
      columns = [
        Table::Column.new("at", I18n.t("ui.audit.at")),
        Table::Column.new("user", I18n.t("ui.audit.user")),
        Table::Column.new("action", I18n.t("ui.audit.action"), "mono"),
        Table::Column.new("module", I18n.t("ui.audit.module"), "mono", secondary: true),
        Table::Column.new("state", I18n.t("ui.audit.state")),
        Table::Column.new("ip", I18n.t("ui.audit.ip"), "mono", secondary: true),
        Table::Column.new("detail", I18n.t("ui.audit.detail"), secondary: true),
      ]
      rows = events.map do |event|
        Table::Row.new([
          Table::Cell.new(event.created_at.try { |moment| fmt.datetime(moment, Time::Location::UTC) } || "",
            sort: event.created_at.try(&.to_s("%Y-%m-%dT%H:%M:%S")) || ""),
          Table::Cell.new(event.user_label), Table::Cell.new(event.action), Table::Cell.new(event.module_code),
          Table::Cell.new(event.state), Table::Cell.new(event.ip), Table::Cell.new(event.detail),
        ])
      end
      params = {"user" => query("user"), "state" => query("state")}.reject { |_, value| value.empty? }
      table = Table.new(I18n.t("ui.audit.title"), columns, rows, reverse("core:audit"), params, empty_message: I18n.t("ui.audit.empty"))
      extra = [] of Form::Field
      unless users.empty?
        extra << Form::Field.new("user", I18n.t("ui.audit.user"), "select", query("user"),
          options: [option("", I18n.t("ui.audit.all_users"))] + users.map { |user| option(user.id.to_s, user.email) })
      end
      list_page(I18n.t("ui.audit.title"), table, crumbs, "ui.audit.csv_name", filters: search_filters(extra),
        intro: I18n.t("ui.audit.intro", limit: LIMIT.to_s))
    end
  end
end
