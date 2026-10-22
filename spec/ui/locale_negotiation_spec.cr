# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Langue d'une page quand le navigateur en demande une que Partiduo ne livre
# pas (ADR-005 D7 : fr, en, nl) : le middleware I18n de Marten retient la
# première langue livrée de `Accept-Language`, sinon la langue par défaut de
# l'instance (fr) ; un cookie de langue non livrée est ignoré. La page est
# entière dans cette langue, sans « missing translation » ni clé brute.

private alias Translations = PartiduoUi::Translations

private def page(path : String, accept : String, cookie : String? = nil,
                 browser : PartiduoUi::Browser = PartiduoUi::Browser.new) : Marten::HTTP::Response
  browser.headers["Accept-Language"] = accept
  cookie ? (browser.jar[Marten.settings.i18n.locale_cookie_name] = cookie) : browser.jar.delete(Marten.settings.i18n.locale_cookie_name)
  browser.get(path)
end

private def language(response : Marten::HTTP::Response) : String?
  response.content[/<html lang="([^"]+)"/, 1]?
end

describe "Langue demandée par le navigateur" do
  it "sert en français une langue non livrée (de, es, it, pt), sans traduction absente" do
    PartiduoUi::Reference.provision
    ["de", "es", "it", "pt", "de-DE,de;q=0.9", "pt-BR", "es-ES,es;q=0.8,it;q=0.6", "*", ""].each do |accept|
      response = page("/login", accept)
      response.status.should eq(200)
      response.headers["Content-Language"]?.should eq("fr")
      language(response).should eq("fr")
      Translations.problems(response.content).should eq([] of String)
    end
  end

  it "retient la première langue livrée de la liste du navigateur" do
    PartiduoUi::Reference.provision
    {"de-DE,de;q=0.9,en;q=0.8" => "en", "it,nl;q=0.5,en;q=0.4" => "nl", "en-GB" => "en", "nl-BE,fr;q=0.5" => "nl"}.each do |accept, expected|
      response = page("/login", accept)
      response.headers["Content-Language"]?.should eq(expected)
      language(response).should eq(expected)
      Translations.problems(response.content).should eq([] of String)
    end
  end

  it "ignore un cookie de langue non livrée" do
    PartiduoUi::Reference.provision
    response = page("/login", "de", cookie: "de")
    response.headers["Content-Language"]?.should eq("fr")
    Translations.problems(response.content).should eq([] of String)
  end

  it "sert à un utilisateur connecté sa langue, quel que soit le navigateur" do
    PartiduoUi::Reference.provision
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    ["de", "es-ES", "pt-BR"].each do |accept|
      response = page("/", accept, browser: browser)
      response.status.should eq(200)
      language(response).should eq("fr")
      Translations.problems(response.content).should eq([] of String)
    end
  end
end
