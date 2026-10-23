# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Dossier provisionné par le contrat (`Api::Core.provision`) : société,
  # taux de TVA, catégories de fiches, plan comptable et journaux du régime.
  module Reference
    # `kind` : type de dossier (ADR-011 A3) ; un foyer porte un nom de foyer,
    # sans SIREN ni TVA. `default_locale` : langue configurée du dossier.
    def self.provision(regime : String = "fr", modules : Array(String) = [] of String,
                       kind : String = Partiduo::Api::InitialData::COMPANY, default_locale : String? = nil) : Nil
      settings = if kind == Partiduo::Api::InitialData::HOUSEHOLD
                   Partiduo::Api::Core::SettingsInput.new(company_name: "Foyer Martin", tax_regime: regime,
                     country_code: regime.upcase, domain: "demo.partiduo.localhost", default_locale: default_locale)
                 elsif regime == "be"
                   Partiduo::Api::Core::SettingsInput.new(company_name: "Atelier Dupont SRL", tax_regime: "be",
                     country_code: "BE", vat_number: "BE0417497106", domain: "demo.partiduo.localhost", default_locale: default_locale)
                 else
                   Partiduo::Api::Core::SettingsInput.new(company_name: "Atelier Brunet SARL", tax_regime: "fr",
                     country_code: "FR", siren: "732 829 320", vat_number: "FR 44 732829320", domain: "demo.partiduo.localhost",
                     default_locale: default_locale)
                 end
      input = Partiduo::Api::Core::ProvisionInput.new(settings: settings, modules: modules, kind: kind)
      result = Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, input)
      raise "provisionnement refusé : #{result.error_keys.join(", ")}" if result.failure?
    end

    # Exercice mensuel de l'année donnée.
    def self.fiscal_year(year : Int32 = 2026) : Partiduo::Api::Core::FiscalYearView
      input = Partiduo::Api::Core::FiscalYearInput.new(year: year, start_year: year)
      Partiduo::Api::Core.create_fiscal_year(Partiduo::Api::Actor.system, input).value!
    end

    def self.category(code : String) : Partiduo::Api::Cards::CategoryView
      Partiduo::Api::Cards.category_by_code(Partiduo::Api::Actor.system, code) || raise "catégorie #{code} absente"
    end

    # Identifiant extrait d'une redirection (`/cards/12` → 12).
    def self.id_from(location : String) : Int64
      location.split('?').first.split('/').reject(&.empty?).last.to_i64
    end
  end
end
