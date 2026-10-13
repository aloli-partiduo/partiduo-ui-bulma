# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Base des écrans de la profession libérale (module `LIBERAL`, ADR-007
  # D6) : livre-journal des recettes et des dépenses, immobilisations,
  # 2035, paramètres. Tout passe par `Partiduo::Api::Liberal` ; module
  # inactif : le contrat lève `ModuleDisabled`, l'écran répond 404.
  #
  # Vocabulaire courant (ADR-007 D3, D6) : « recettes », « dépenses »,
  # « immobilisations », « annuler » ; jamais « débit » ni « crédit ».
  abstract class LiberalScreen < ReferenceHandler
    alias Liberal = Partiduo::Api::Liberal

    MODULE   = Liberal::MODULE_CODE
    READ     = Liberal::READ
    WRITE    = Liberal::WRITE
    SETTINGS = Liberal::SETTINGS_WRITE

    def today : Time
      Partiduo::Api::Core.today
    end

    # Année demandée (`?year=`), sinon l'année en cours.
    def year_param : Int32
      requested = query("year").to_i?
      requested && requested >= 2000 && requested <= today.year + 1 ? requested : today.year
    end

    # Montant en euros (`1 234,50 €`) : la 2035 relève du régime français.
    def euros(value : BigDecimal?, decimals : Int32 = 2) : String
      value.nil? ? "" : "#{fmt.amount(value, decimals)} €"
    end

    def heading_label(heading : String) : String
      I18n.t("liberal.headings.#{heading}")
    end

    def method_label(method : String) : String
      I18n.t("liberal.methods.#{method}")
    end

    def category_label(category : String) : String
      I18n.t("liberal.asset_categories.#{category}")
    end

    def method_options : Array(Form::Option)
      Liberal::METHODS.map { |code| option(code, method_label(code)) }
    end

    # Onglets d'années : les deux précédentes, l'année en cours.
    def year_tabs(path : String, year : Int32, extra = {} of String => String) : Array(Screen::Tab)
      ((today.year - 2)..today.year).map do |value|
        params = extra.merge({"year" => value.to_s})
        Screen::Tab.new(value.to_s, "#{path}?#{URI::Params.encode(params)}", value == year)
      end
    end

    # Fil d'Ariane : tableau de bord en mode simplifié, rubrique du menu
    # complet sinon.
    def liberal_crumbs : Array(Screen::Crumb)
      [Screen::Crumb.new(I18n.t("ui.liberal.menu.dashboard"), reverse("core:dashboard"))]
    end

    # Client ou fournisseur : nom saisi, sinon nom de la fiche.
    def party(name : String, card_id : Int64?) : String
      return name unless name.empty?
      card_id.try { |id| Partiduo::Api::Cards.card(current.actor, id).name } || ""
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      ""
    end

    def file_response(file : Liberal::FileView) : Marten::HTTP::Response
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end

    # Erreurs d'une commande en un message (après une action d'une ligne).
    def messages(errors : Array(Partiduo::Api::FieldError)) : String
      errors.map { |error| fmt.message(error) }.join(" ")
    end

    # Photo ou PDF du justificatif, déposé au socle avant l'inscription ;
    # gardé (`attachment_id`) si la saisie est refusée (comme D-UI-064).
    def upload(form : Form, values : Hash(String, String)) : Nil
      return unless values["attachment_id"].empty?
      file = request.data["attachment_file"]?
      return unless file.is_a?(Marten::HTTP::UploadedFile) && file.size > 0
      result = ReceivedInvoiceUpload.store(current.actor, file)
      if view = result.value?
        values["attachment_id"] = view.id.to_s
      else
        form.add_errors(result.errors, fmt)
      end
    end

    # Saisie rapide (gabarit `ui/liberal/entry.html`) : champs principaux,
    # « Plus de détails », photo du justificatif.
    def entry_page(title : String, crumbs : Array(Screen::Crumb), form : Form, action : String, cancel_url : String,
                   again : Bool = true, status : Int32 = 200, intro : String? = nil) : Marten::HTTP::Response
      context["title"] = title
      context["intro"] = intro
      context["crumbs"] = crumbs
      context["form"] = form
      context["main"] = form.groups[0].fields
      context["more"] = form.groups[1].fields
      context["more_open"] = form.groups[1].fields.any?(&.errors)
      context["attachment_kept"] = form.fields.find(&.name.==("attachment_id")).try(&.value.presence)
      context["form_action"] = action
      context["cancel_url"] = cancel_url
      context["again"] = again
      page("ui/liberal/entry.html", status: status)
    end

    # --- Exercices (D-LIB2-001, D-LIB5-001) ------------------------------------------

    # État d'un exercice, en clair : « ouvert, modifiable », « clôturé le …
    # par … », « 2035 transmise le … — verrouillé ».
    def exercise_status(view : Liberal::YearView) : String
      at = view.frozen_at.try { |moment| fmt.timestamp_date(moment) } || ""
      if view.locked?
        I18n.t("ui.liberal.exercise.locked", date: at)
      elsif view.closed? && !view.closed_by.empty?
        I18n.t("ui.liberal.exercise.closed_by", date: at, name: view.closed_by)
      elsif view.closed?
        I18n.t("ui.liberal.exercise.closed", date: at)
      else
        I18n.t("ui.liberal.exercise.open")
      end
    end

    # En-tête de groupe d'un exercice : « Exercice 2026 », état, cadenas s'il
    # est clôturé ou verrouillé.
    def exercise_group(view : Liberal::YearView) : Table::Group
      Table::Group.new(I18n.t("ui.liberal.exercise.label", year: view.year.to_s), exercise_status(view),
        view.frozen? ? "lock" : nil)
    end

    # Exercices des années citées, par année.
    def exercises(years : Enumerable(Int32)) : Hash(Int32, Liberal::YearView)
      years.to_set.to_h { |year| {year, Liberal.year(current.actor, year)} }
    end

    # « Clôturer l'exercice » (ouvert) ou « Rouvrir l'exercice » (clôturé
    # par le module, 2035 non transmise), avec confirmation ; rien pour un
    # exercice verrouillé ou clos au socle, ni sans le droit de saisie
    # (D-LIB5-001, D-LIB5-005). Retour à `back` après l'action.
    def year_actions(view : Liberal::YearView, back : String) : Array(Screen::Action)
      actions = [] of Screen::Action
      return actions unless can?(WRITE)
      year = view.year.to_s
      next_query = URI::Params.encode({"next" => back})
      action = if view.closable?
                 Screen::Action.new(I18n.t("ui.liberal.exercise.close"),
                   "#{reverse("liberal:year_close", year: view.year)}?#{next_query}", "post", "", "lock",
                   I18n.t("ui.liberal.exercise.close_confirm", year: year))
               elsif view.reopenable?
                 Screen::Action.new(I18n.t("ui.liberal.exercise.reopen"),
                   "#{reverse("liberal:year_reopen", year: view.year)}?#{next_query}", "post", "", "lock-open",
                   I18n.t("ui.liberal.exercise.reopen_confirm", year: year))
               end
      if action
        action.aria_label = "#{action.label} #{year}"
        actions << action
      end
      actions
    end

    # Actions d'une ligne du livre-journal selon son exercice (D-LIB2-001) :
    # ouvert, modifier et supprimer ; figé (ou période close), contre-passer
    # (ligne inverse datée du jour, dans l'exercice ouvert). `row` : boutons
    # d'une ligne de liste (nom accessible avec le numéro).
    def line_actions(item : Liberal::LineView, row : Bool = false) : Array(Screen::Action)
      actions = [] of Screen::Action
      return actions unless can?(WRITE)
      if item.editable?
        actions << link_action("ui.liberal.line.edit", reverse("liberal:line_edit", id: item.id), row ? "row" : "", "pencil")
      end
      if item.deletable?
        actions << post_action("ui.liberal.line.delete", reverse("liberal:line_delete", id: item.id),
          "ui.liberal.line.delete_confirm", row ? "row-danger" : "danger", "trash-2")
      end
      if item.locked && item.reversible?
        actions << post_action("ui.liberal.line.cancel", reverse("liberal:line_reverse", id: item.id),
          "ui.liberal.line.cancel_confirm", row ? "row" : "", "undo-2")
      end
      actions.each { |action| action.aria_label = "#{action.label} #{item.number}" } if row
      actions
    end

    # Recopie les erreurs d'un formulaire lu dans le formulaire réaffiché.
    def copy_errors(from : Form, to : Form) : Form
      from.fields.each { |item| item.errors.try &.each { |message| to.add_error(item.name, message) } }
      from.base_errors.try &.each { |message| to.add_error(Partiduo::Api::FieldError::BASE, message) }
      to
    end
  end
end
