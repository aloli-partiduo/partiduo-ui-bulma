# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Type de dossier vu de l'interface (ADR-011 A3) : `company` (entreprise,
  # micro-entreprise, profession libérale) ou `household` (foyer), choisi au
  # provisionnement et lu dans la configuration du dossier
  # (`Partiduo::Api::Core::SettingsView#kind`).
  #
  # Le type règle la présentation par défaut, avec ou sans variante du mode
  # simplifié (`SimpleMode`) : menus écartés (`SimpleMode::KIND_HIDDEN_MENUS`),
  # tableau de bord (`Dashboard#build_household`) et vocabulaire des rôles
  # (« Membre du foyer »). Une variante d'extension déclarée par
  # `Extensions.simple_mode` s'y ajoute : ses menus écartés s'unissent à
  # ceux du type, ses tuiles remplacent celles du foyer dans l'interface
  # simplifiée.
  module FolderKind
    COMPANY   = Partiduo::Api::InitialData::COMPANY
    HOUSEHOLD = Partiduo::Api::InitialData::HOUSEHOLD

    # Libellés des rôles propres à un type de dossier ; les autres rôles
    # gardent celui du cœur (`auth.roles.<rôle>`).
    ROLE_KEYS = {
      HOUSEHOLD => {"member" => "ui.household.roles.member"},
    }

    # Type du dossier de la requête ; `company` sans session ou avant le
    # provisionnement. Lu une seule fois par requête.
    def self.of(request : Marten::HTTP::Request) : String
      request.partiduo_folder_kind ||= of(Current.for(request).actor)
    end

    def self.of(actor : Partiduo::Api::Actor) : String
      return COMPANY unless actor.authenticated?
      Partiduo::Api::Core.settings(actor).kind
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      COMPANY
    end

    def self.household?(request : Marten::HTTP::Request) : Bool
      of(request) == HOUSEHOLD
    end

    # Clé i18n du libellé d'un rôle dans ce type de dossier (`member` :
    # « Membre du foyer » pour un foyer, « Utilisateur de la société »
    # ailleurs).
    def self.role_key(kind : String, role : String) : String
      ROLE_KEYS[kind]?.try(&.[role]?) || "auth.roles.#{role}"
    end

    def self.role_key(request : Marten::HTTP::Request, role : String) : String
      role_key(of(request), role)
    end
  end
end
