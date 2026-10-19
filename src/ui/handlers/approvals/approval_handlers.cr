# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Approbation des opérations sensibles (A-SEPA-3) : écran commun à toutes
  # les extensions qui soumettent une opération (`Partiduo::Api::Approvals`).
  # Liste des demandes en attente, détail et piste d'audit, approuver,
  # rejeter, retirer. Approuver exige une authentification forte récente :
  # sinon, l'écran envoie confirmer son identité (TOTP ou passkey) puis
  # revient à la demande. Le contrat vérifie tout de nouveau à la décision
  # (même personne en validation à deux, délai, rejeu).
  abstract class ApprovalScreen < ReferenceHandler
    alias Approvals = Partiduo::Api::Approvals

    def approvals_crumbs : Array(Screen::Crumb)
      [crumb("ui.approvals.title", reverse("core:approvals"))]
    end

    def approval_url(id : Int64) : String
      reverse("core:approval", id: id)
    end

    # Nom affiché de l'extension qui a soumis la demande.
    def module_name(code : String) : String
      I18n.t(Partiduo::Api::Modules.get(current.actor, code).name_key)
    rescue Partiduo::Api::NotFound
      code
    end

    def amount_text(view : Approvals::ApprovalView) : String
      view.amount.try { |value| [fmt.amount(value), view.currency_code].reject(&.empty?).join(" ") } || ""
    end

    # Ce qui reste à faire, dit à la personne (colonne « Décision »).
    def decision_text(decision : Approvals::DecisionView) : String
      return I18n.t("ui.approvals.decision.ready") if decision.can_approve
      return I18n.t("ui.approvals.decision.reauth") if decision.reauthentication_required
      case decision.reason
      when .nil?                              then ""
      when "core.errors.approval.same_person" then I18n.t("ui.approvals.decision.other_person")
      when "core.errors.approval.forbidden"   then I18n.t("ui.approvals.decision.not_yours")
      else                                         I18n.t(decision.reason.to_s, {"minutes" => decision.reauth_minutes.to_s})
      end
    end
  end

  # Demandes en attente que l'utilisateur peut décider, ou qu'il a soumises.
  class ApprovalsHandler < ApprovalScreen
    def get
      policy = Approvals.policy(current.actor)
      columns = [
        Table::Column.new("requested_at", I18n.t("ui.approvals.requested_at"), "mono"),
        Table::Column.new("module", I18n.t("ui.approvals.module"), secondary: true),
        Table::Column.new("summary", I18n.t("ui.approvals.summary")),
        Table::Column.new("amount", I18n.t("ui.approvals.amount"), "amount"),
        Table::Column.new("requested_by", I18n.t("ui.approvals.requested_by"), secondary: true),
        Table::Column.new("decision", I18n.t("ui.approvals.decision.title")),
      ]
      rows = Approvals.pending(current.actor).map do |view|
        decision = Approvals.decision(current.actor, view.id)
        url = approval_url(view.id)
        Table::Row.new([
          Table::Cell.new(fmt.datetime(view.requested_at), url, sort: view.requested_at.to_rfc3339),
          Table::Cell.new(module_name(view.module_code)),
          Table::Cell.new(view.summary, url),
          Table::Cell.new(amount_text(view), sort: view.amount || BigDecimal.new(0), csv: view.amount.try(&.to_s) || ""),
          Table::Cell.new(view.requested_by_name),
          Table::Cell.new(decision_text(decision)),
        ])
      end
      table = Table.new(I18n.t("ui.approvals.title"), columns, rows, request.path, query_params,
        I18n.t("ui.approvals.empty"), "pd-approvals")
      intro = I18n.t(policy.dual? ? "ui.approvals.intro_dual" : "ui.approvals.intro_single", minutes: policy.reauth_minutes)
      list_page(I18n.t("ui.approvals.title"), table, approvals_crumbs, "ui.approvals.csv_name", intro: intro)
    end

    private def query_params : Hash(String, String)
      request.query_params.to_h.transform_values(&.to_s)
    end
  end

  # Détail d'une demande : objet, montant, décision, piste d'audit ;
  # approuver (avec un commentaire), rejeter, retirer.
  class ApprovalHandler < ApprovalScreen
    def get
      show(id_param)
    end

    def show(id : Int64, errors : Array(Partiduo::Api::FieldError) = [] of Partiduo::Api::FieldError,
             status : Int32 = 200) : Marten::HTTP::Response
      view = Approvals.approval(current.actor, id)
      decision = Approvals.decision(current.actor, id)
      request_items = items(view)
      sections = [Screen::Section.new(I18n.t("ui.approvals.request"), request_items)]
      unless view.details.empty?
        sections << Screen::Section.new(I18n.t("ui.approvals.details"),
          view.details.map { |key, value| Screen::Item.new(I18n.t(key), value) })
      end
      sections << Screen::Section.new(I18n.t("ui.approvals.trail"), table: trail(id))
      if view.pending? && !decision.can_approve
        note = decision_text(decision)
        sections.unshift(Screen::Section.new(I18n.t("ui.approvals.decision.title"), note: note)) unless note.empty?
      end
      actions = actions(id, decision)
      if decision.can_approve
        form = Form.new([Form::Group.new(nil, [Form::Field.new("comment", I18n.t("ui.approvals.comment"), "textarea",
          help: I18n.t("ui.approvals.comment_help"))])])
        form.add_errors(errors, fmt) unless errors.empty?
        set_form(form, reverse("core:approval_approve", id: id), I18n.t("ui.approvals.approve"), title: I18n.t("ui.approvals.approve_title"))
      end
      detail_page(view.summary, approvals_crumbs, sections, actions, status_tag: I18n.t(view.status_key), status: status)
    end

    private def items(view : Approvals::ApprovalView) : Array(Screen::Item)
      mode = view.decision_mode.presence || Approvals.policy(current.actor).mode
      [
        Screen::Item.new(I18n.t("ui.approvals.module"), module_name(view.module_code)),
        Screen::Item.new(I18n.t("ui.approvals.summary"), view.summary),
        Screen::Item.new(I18n.t("ui.approvals.amount"), amount_text(view), mono: true),
        Screen::Item.new(I18n.t("ui.approvals.subject"), view.subject, mono: true),
        Screen::Item.new(I18n.t("ui.approvals.requested_by"), view.requested_by_name),
        Screen::Item.new(I18n.t("ui.approvals.requested_at"), fmt.datetime(view.requested_at)),
        Screen::Item.new(I18n.t("ui.approvals.mode"), I18n.t("core.settings.approval_modes.#{mode}")),
        Screen::Item.new(I18n.t("ui.approvals.decided_by"), view.decided_by_name),
        Screen::Item.new(I18n.t("ui.approvals.decided_at"), view.decided_at.try { |time| fmt.datetime(time) } || ""),
        Screen::Item.new(I18n.t("ui.approvals.comment"), view.comment),
        Screen::Item.new(I18n.t("ui.approvals.consumed_at"), view.consumed_at.try { |time| fmt.datetime(time) } || ""),
      ]
    end

    private def actions(id : Int64, decision : Approvals::DecisionView) : Array(Screen::Action)
      actions = [] of Screen::Action
      if decision.reauthentication_required
        actions << link_action("ui.approvals.reauth_then_approve", reverse("core:approval_reauth", id: id), "primary")
      end
      if decision.can_reject
        actions << post_action("ui.approvals.reject", reverse("core:approval_reject", id: id), "ui.approvals.reject_confirm", "danger")
      end
      if decision.can_cancel
        actions << post_action("ui.approvals.cancel", reverse("core:approval_cancel", id: id), "ui.approvals.cancel_confirm")
      end
      actions
    end

    private def trail(id : Int64) : Table
      columns = [
        Table::Column.new("at", I18n.t("ui.approvals.event_at"), "mono"),
        Table::Column.new("action", I18n.t("ui.approvals.event_action")),
        Table::Column.new("who", I18n.t("ui.approvals.event_who")),
        Table::Column.new("detail", I18n.t("ui.approvals.event_detail"), secondary: true),
      ]
      rows = Approvals.events(current.actor, id).map do |event|
        detail = event.detail.starts_with?("core.errors.") ? I18n.t(event.detail, {"minutes" => "…"}) : event.detail
        Table::Row.new([
          Table::Cell.new(fmt.datetime(event.created_at), sort: event.created_at.to_rfc3339),
          Table::Cell.new(I18n.t(event.action_key)),
          Table::Cell.new(event.actor_name),
          Table::Cell.new(detail),
        ])
      end
      table = Table.new(I18n.t("ui.approvals.trail"), columns, rows, request.path, {} of String => String,
        I18n.t("ui.approvals.trail_empty"), "pd-approval-trail")
      table.exportable = false
      table
    end
  end

  # Approuver : refusé par le contrat sans authentification forte récente,
  # l'écran envoie alors la confirmer.
  class ApprovalApproveHandler < ApprovalHandler
    def post
      id = id_param
      result = Approvals.approve(current.actor, id, field("comment", strip: false))
      if result.success?
        flash["success"] = I18n.t("ui.approvals.approved")
        return go(approval_url(id))
      end
      if result.error_keys.includes?("core.errors.approval.reauthentication_required")
        flash["warning"] = result.errors.map(&.message).join(" ")
        return go(reverse("core:approval_reauth", id: id))
      end
      show(id, result.errors, 422)
    end
  end

  class ApprovalRejectHandler < ApprovalHandler
    def post
      id = id_param
      flash_result(Approvals.reject(current.actor, id), "ui.approvals.rejected")
      go(approval_url(id))
    end
  end

  class ApprovalCancelHandler < ApprovalHandler
    def post
      id = id_param
      flash_result(Approvals.cancel(current.actor, id), "ui.approvals.cancelled")
      go(approval_url(id))
    end
  end

  # Confirmer son identité avant d'approuver (A-SEPA-3) : code de
  # l'application d'authentification, ou passkey (élévation de la session,
  # qui renouvelle l'heure de l'authentification forte), puis retour à la
  # demande. Un code de récupération n'est pas proposé : il ne compte pas.
  class ApprovalReauthHandler < ApprovalScreen
    def get
      reauth_page(id_param)
    end

    def post
      id = id_param
      result = Partiduo::Api::Auth.elevate_with_totp(current.actor, current.token || "", field("code").delete(' '))
      return reauth_page(id, errors_of(result), 422) if result.failure?
      if Approvals.decision(Partiduo::Api::Auth.actor(current.token), id).reauthentication_required
        # Facteur sous le niveau qu'exige l'utilisateur (TOTP pour une
        # personne tenue à la passkey) : il ne compte pas.
        return reauth_page(id, {"code" => [I18n.t("ui.approvals.reauth_too_weak")]}, 422)
      end
      flash["success"] = I18n.t("ui.approvals.reauthenticated")
      go(approval_url(id))
    end

    private def reauth_page(id : Int64, errors = {} of String => Array(String), status : Int32 = 200) : Marten::HTTP::Response
      view = Approvals.approval(current.actor, id)
      overview = Partiduo::Api::Auth.security_overview(current.actor)
      page("ui/approvals/reauth.html", {
        "title"       => I18n.t("ui.approvals.reauth_title"),
        "crumbs"      => approvals_crumbs + [Screen::Crumb.new(view.summary, approval_url(id))],
        "summary"     => view.summary,
        "amount"      => amount_text(view),
        "minutes"     => Approvals.policy(current.actor).reauth_minutes.to_s,
        "has_totp"    => overview.methods.includes?("totp"),
        "has_passkey" => overview.methods.includes?("passkey"),
        "action"      => reverse("core:approval_reauth", id: id),
        "back"        => approval_url(id),
        "connect_url" => connect_elevation_url(overview.required_level, approval_url(id), fresh: true),
        "errors"      => errors,
      }, status)
    end
  end
end
