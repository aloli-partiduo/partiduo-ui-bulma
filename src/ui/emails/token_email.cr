# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Courriel qui porte un lien à usage unique (remise à zéro du mot de passe,
  # déblocage, invitation). Le cœur fournit le jeton et ne produit aucun texte ;
  # l'interface rédige et envoie (doc/api/auth.adoc du cœur). `kind` :
  # `password_reset`, `unlock`, `invitation`.
  class TokenEmail < Marten::Email
    to @address
    subject I18n.t("ui.emails.#{@kind}.subject")

    def initialize(@address : String, @kind : String, @link : String, @expires_at : Time,
                   @format : Format = Format.new(I18n.locale))
    end

    def text_body : String?
      String.build do |io|
        io << I18n.t("ui.emails.#{@kind}.intro") << "\n\n"
        io << @link << "\n\n"
        # Heure du dossier, nommée : le destinataire peut lire ailleurs.
        zone = Partiduo::Api::Core.time_zone
        io << I18n.t("ui.emails.expires", at: @format.datetime(@expires_at, zone), zone: zone.name) << "\n"
        io << I18n.t("ui.emails.ignore") << "\n"
      end
    end
  end
end
