# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Préférences de l'utilisateur (DECISIONS D-UI-077) : réglages personnels,
  # enregistrés par le cœur avec son compte (`Partiduo::Api::Auth`,
  # D-AUTH-016), qui le suivent d'un appareil à l'autre et ne changent rien
  # pour les autres utilisateurs. Aujourd'hui : l'interface, « Recettes et
  # dépenses » ou « Comptabilité » (profession libérale), mode simplifié ou
  # complet (comptable d'une micro-entreprise), ou celles de la variante
  # d'une extension, selon `SimpleMode`.
  # Ouvertes à toute session authentifiée, comme la sécurité du compte.
  class PreferencesHandler < ReferenceHandler
    private def screen_access : Symbol
      :account
    end

    def get
      item = SimpleMode.choice(request)
      show(item && item.switchable? ? form(item, item.applied) : nil)
    end

    def post
      item = SimpleMode.choice(request)
      return show(nil, 422) unless item && item.switchable?
      interface = field("interface")
      shown = form(item, interface)
      unless item.interfaces.includes?(interface)
        return show(shown.add_error("interface", I18n.t("ui.preferences.unavailable")), 422)
      end
      result = Partiduo::Api::Auth.update_preferences(current.actor, Partiduo::Api::Auth::PreferencesInput.new(interface: interface))
      return show(shown.add_errors(result.errors, fmt), 422) if result.failure?
      flash["success"] = I18n.t("ui.preferences.saved")
      go(reverse("account_preferences"))
    end

    # Liste des interfaces offertes, dans le vocabulaire de la variante (seulement
    # quand il y a à choisir : plus d'une interface offerte).
    private def form(item : SimpleMode::Choice, value : String) : Form
      options = item.interfaces.map { |code| option(code, I18n.t(item.label_key(code))) }
      Form.new([Form::Group.new(nil, [
        Form::Field.new("interface", I18n.t("ui.preferences.interface"), "select", value, options: options,
          help: I18n.t(item.flavor.labels.help)),
      ])])
    end

    private def show(form : Form?, status : Int32? = nil) : Marten::HTTP::Response
      title = I18n.t("ui.preferences.title")
      crumbs = [Screen::Crumb.new(title, reverse("account_preferences"))]
      actions = [link_action("ui.security.title", reverse("account_security"), icon: "shield-check")]
      form_page(title, crumbs, form, reverse("account_preferences"), I18n.t("ui.forms.save"),
        actions: actions, intro: intro(SimpleMode.choice(request)), status: status)
    end

    # Ce que règlent les préférences et, sans choix possible, pourquoi.
    private def intro(item : SimpleMode::Choice?) : String
      parts = [I18n.t("ui.preferences.intro")]
      if item.nil?
        parts << I18n.t("ui.preferences.none")
      elsif !item.switchable?
        applied = I18n.t(item.label_key(item.applied))
        parts << I18n.t("ui.preferences.applied", interface: applied)
        labels = item.flavor.labels
        parts << I18n.t(labels.restricted)
        if (kept = labels.kept) && item.preferences.interface != item.applied
          parts << I18n.t(kept, interface: I18n.t(item.label_key(item.preferences.interface)))
        end
      elsif !item.preferences.interface_chosen
        parts << I18n.t("ui.preferences.role_default")
      end
      parts.join(" ")
    end
  end

  # Raccourci du menu de l'utilisateur (« Passer à la comptabilité », « Passer
  # aux recettes et dépenses », mode simplifié ou complet du comptable) :
  # enregistre la préférence, comme l'écran des préférences (D-UI-077).
  # Refusé (403) à qui n'a pas le choix.
  class InterfaceModeHandler < ScreenHandler
    def post
      target = SimpleMode.switch_target(request)
      return ErrorPage.render(request, 403) if target.nil? || field("mode") != target
      result = Partiduo::Api::Auth.update_preferences(current.actor, Partiduo::Api::Auth::PreferencesInput.new(interface: target))
      flash["danger"] = result.errors.map(&.message).join(" ") if result.failure?
      go(reverse("core:dashboard"))
    end
  end
end
