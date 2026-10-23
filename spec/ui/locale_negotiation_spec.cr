# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Langue d'une page selon le navigateur (ADR-005 D7 : fr, en, nl, de, es,
# it, pt) : le middleware I18n de Marten retient la première langue livrée
# de `Accept-Language` (langue de base : `de-DE` → `de`, `pt-BR` → `pt`) ;
# quand le navigateur n'en demande aucune, ou n'envoie pas l'en-tête, la page
# est dans la langue configurée du dossier (`default_locale`, D-UI-080),
# français si le dossier n'en a pas. Un cookie de langue non livrée est
# ignoré. La page est entière dans cette langue, sans « missing
# translation » ni clé brute.

private alias Translations = PartiduoUi::Translations

private def page(path : String, accept : String?, cookie : String? = nil,
                 browser : PartiduoUi::Browser = PartiduoUi::Browser.new) : Marten::HTTP::Response
  accept ? (browser.headers["Accept-Language"] = accept) : browser.headers.delete("Accept-Language")
  cookie ? (browser.jar[Marten.settings.i18n.locale_cookie_name] = cookie) : browser.jar.delete(Marten.settings.i18n.locale_cookie_name)
  browser.get(path)
end

private def language(response : Marten::HTTP::Response) : String?
  response.content[/<html lang="([^"]+)"/, 1]?
end

private def served_in(response : Marten::HTTP::Response, expected : String, label : String) : Nil
  {label, response.status, response.headers["Content-Language"]?, language(response)}.should eq({label, 200, expected, expected})
  Translations.problems(response.content).should eq([] of String)
end

# Langues non livrées, joker, en-tête vide ou absent.
private UNDELIVERED = ["pl", "sv-SE,sv;q=0.9", "ro, cs;q=0.5", "*", "", nil]

describe "Langue demandée par le navigateur" do
  it "sert chaque langue livrée demandée, langue seule ou avec son pays" do
    PartiduoUi::Reference.provision
    {"de" => "de", "de-DE" => "de", "de-AT,de;q=0.9" => "de", "es-ES" => "es", "es" => "es",
     "it-IT" => "it", "it-CH,it;q=0.8" => "it", "pt-BR" => "pt", "pt-PT" => "pt", "pt" => "pt",
     "nl-BE" => "nl", "en-GB" => "en", "fr-CA" => "fr"}.each do |accept, expected|
      served_in(page("/login", accept), expected, accept)
    end
  end

  it "retient la première langue livrée de la liste du navigateur, par priorité" do
    PartiduoUi::Reference.provision
    {"pl,de-DE;q=0.9,en;q=0.8" => "de", "sv,it;q=0.5,en;q=0.4" => "it", "en;q=0.3,pt-BR;q=0.9" => "pt",
     "nl-BE,fr;q=0.5" => "nl", "cs,es;q=0.7,de;q=0.6" => "es"}.each do |accept, expected|
      served_in(page("/login", accept), expected, accept)
    end
  end

  it "sert la langue du dossier quand le navigateur ne demande aucune langue livrée (D-UI-080)" do
    PartiduoUi::Reference.provision(default_locale: "de")
    UNDELIVERED.each { |accept| served_in(page("/login", accept), "de", accept.inspect) }
    served_in(page("/login", "it-IT"), "it", "it-IT")
  end

  it "sert le français quand le dossier garde sa langue par défaut" do
    PartiduoUi::Reference.provision
    UNDELIVERED.each { |accept| served_in(page("/login", accept), "fr", accept.inspect) }
  end

  it "suit un cookie de langue livrée, ignore un cookie de langue non livrée" do
    PartiduoUi::Reference.provision(default_locale: "es")
    served_in(page("/login", "de", cookie: "pt"), "pt", "cookie pt")
    served_in(page("/login", "de", cookie: "pl"), "de", "cookie pl, navigateur de")
    served_in(page("/login", "pl", cookie: "pl"), "es", "cookie pl, navigateur pl")
  end

  it "sert à un utilisateur connecté sa langue, quel que soit le navigateur ou le dossier" do
    PartiduoUi::Reference.provision(default_locale: "nl")
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    ["de", "es-ES", "pt-BR", "pl", nil].each do |accept|
      served_in(page("/", accept, browser: browser), "fr", accept.inspect)
    end
  end
end
