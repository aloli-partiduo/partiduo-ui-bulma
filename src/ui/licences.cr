# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Provenance du code (AGPL-3.0, article 13) : l'interface offre son code
  # source à qui l'utilise à travers le réseau, et les licences des
  # composants tiers qu'elle embarque (pied de page des pages d'accès, page
  # « Composants et licences », comme partiduo-admin).
  module Licences
    # Assemblé par scripts/third-party-licenses.sh, lu à la compilation.
    TEXT = {{ read_file("#{__DIR__}/../../THIRD-PARTY-LICENSES.txt") }}

    # Version et code source annoncés au pied des pages d'accès : ceux de
    # l'interface par défaut ; une distribution qui la compose avec d'autres
    # dépôts y met les siens.
    class_property version : String = VERSION
    class_property source_url : String = "https://github.com/aloli-partiduo/partiduo-ui-bulma"

    # Un composant du texte : nom, licence, provenance (tableau de la page).
    record Component, name : String, licence : String, source : String do
      include Marten::Template::Object::Auto

      # Adresse seule (la provenance d'une fourche cite aussi l'origine).
      def url : String
        source.split(' ').first
      end
    end

    def self.components : Array(Component)
      lines = TEXT.lines
      lines.each_index.compact_map do |index|
        next unless lines[index].starts_with?("Provenance : ")
        name = lines[index - 1]
        source = lines[index].sub("Provenance : ", "")
        licence = lines[index + 1]?.to_s.sub(/\ALicence *: /, "")
        Component.new(name, licence, source)
      end.to_a
    end

    # Valeurs du pied de page, pour tout gabarit des pages d'accès.
    def self.footer : Hash(String, String)
      {"app_version" => version, "source_url" => source_url}
    end
  end

  # Composants tiers et leurs licences ; code source. Sans connexion : l'offre
  # du code source vaut pour tout utilisateur.
  class LicencesHandler < Handler
    def get
      page("ui/licences.html", {"text" => Licences::TEXT, "components" => Licences.components})
    end
  end
end
