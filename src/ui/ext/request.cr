# SPDX-License-Identifier: AGPL-3.0-or-later

class Marten::HTTP::Request
  # Utilisateur de la requête, calculé une seule fois par `PartiduoUi::Current.for`.
  property partiduo_current : PartiduoUi::Current? = nil
end

class Marten::HTTP::Request
  # Choix d'interface de l'utilisateur (`PartiduoUi::SimpleMode::Choice`,
  # `false` sans mode simplifié offert), calculé une seule fois par
  # `PartiduoUi::SimpleMode.choice`.
  property partiduo_interface_choice : (PartiduoUi::SimpleMode::Choice | Bool)? = nil
end

class Marten::HTTP::Request
  # Type du dossier (`company`, `household`…, ADR-011 A3), lu une seule fois
  # par `PartiduoUi::FolderKind.of`.
  property partiduo_folder_kind : String? = nil
end
