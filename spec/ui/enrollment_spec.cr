# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def invited(email = "bob@example.com") : {PartiduoUi::Browser, String}
  created = PartiduoUi::Accounts.create(email: email, password: nil)
  browser = PartiduoUi::Browser.new
  {browser, created.invitation.token}
end

describe "Enrôlement par invitation (ADR-002 D6, D7)" do
  it "demande une confirmation avant d'utiliser le lien, puis ouvre la session d'enrôlement" do
    browser, token = invited
    page = browser.get("/invitation/#{token}")
    page.status.should eq(200)
    page.html.should contain("Activer votre accès")

    response = browser.post("/invitation/#{token}")
    response.headers["Location"].should eq("/account/enrollment")
    browser.cookie(PartiduoUi::Current::COOKIE).should_not be_nil
  end

  it "refuse un lien déjà utilisé" do
    browser, token = invited
    browser.post("/invitation/#{token}")
    again = PartiduoUi::Browser.new.post("/invitation/#{token}")
    again.status.should eq(422)
    again.html.should contain("Ce lien n'est plus valable.")
  end

  it "propose la clé d'accès d'abord, le mot de passe en repli" do
    browser, token = invited
    browser.post("/invitation/#{token}")
    body = browser.get("/account/enrollment").html
    passkey = body.index!(%(data-passkey="register"))
    password = body.index!(%(name="new_password"))
    passkey.should be < password
    body.should contain("recommandé")
    body.should contain("Choisir plutôt un mot de passe")
  end

  it "cantonne la session d'enrôlement à l'enrôlement" do
    browser, token = invited
    browser.post("/invitation/#{token}")
    browser.get("/").headers["Location"].should eq("/account/enrollment")
    browser.get("/account/security").headers["Location"].should eq("/account/enrollment")
  end

  it "enregistre un mot de passe puis renvoie vers la connexion" do
    browser, token = invited
    browser.post("/invitation/#{token}")
    weak = browser.post("/account/enrollment", {"new_password" => "court", "confirmation" => "court"})
    weak.status.should eq(422)
    weak.html.should contain("au moins 14 caractères")

    done = browser.post("/account/enrollment", {"new_password" => "Correcthorse42battery", "confirmation" => "Correcthorse42battery"})
    done.headers["Location"].should eq("/login")
    browser.cookie(PartiduoUi::Current::COOKIE).should be_nil
    PartiduoUi::Browser.new.post("/login", {"email" => "bob@example.com", "password" => "Correcthorse42battery"}).status.should eq(302)
  end

  it "enregistre une clé d'accès, affiche les codes de récupération une fois, puis renvoie vers la connexion" do
    browser, token = invited
    browser.post("/invitation/#{token}")
    authenticator = PartiduoUi::FakeAuthenticator.new
    options = browser.post("/account/passkeys/options").html
    JSON.parse(options)["publicKey"]["authenticatorSelection"]["residentKey"].as_s.should eq("required")
    outcome = JSON.parse(browser.post("/account/passkeys", authenticator.register(options, "Téléphone")).html)
    outcome["ok"].as_bool.should be_true
    html = outcome["html"].as_s
    html.should contain("Ces codes ne seront plus jamais affichés.")
    html.scan(/<li><code>[^<]+<\/code><\/li>/).size.should eq(10)
    html.should contain(%(href="/login"))
    browser.cookie(PartiduoUi::Current::COOKIE).should be_nil

    fresh = PartiduoUi::Browser.new
    login_options = fresh.post("/login/passkey/options").html
    JSON.parse(fresh.post("/login/passkey", authenticator.assert(login_options)).html)["ok"].as_bool.should be_true
  end

  it "vérifie le mot de passe à la volée (HTMX)" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    weak = browser.htmx_post("/password/check", {"new_password" => "abc"}).html
    weak.should contain(%(id="pd-password-feedback"))
    weak.should contain("au moins 14 caractères")
    fine = browser.htmx_post("/password/check", {"new_password" => "Anothergood42pass"}).html
    fine.should contain("Ce mot de passe respecte les règles.")
  end
end

describe "Invitation avec connect (ADR-012 D6)" do
  it "propose de se connecter avec le compte Partiduo, garde l'invitation et part vers connect" do
    # connect réglé mais injoignable ici : l'invitation reste valable, sans
    # lien de création de compte.
    ENV["PARTIDUO_CONNECT_URL"] = "http://127.0.0.1:9"
    ENV["PARTIDUO_CONNECT_CLIENT_ID"] = "demo"
    ENV["PARTIDUO_CONNECT_CLIENT_SECRET"] = "secret-du-dossier"
    browser, token = invited("carol@example.com")
    page = browser.get("/invitation/#{token}").html
    page.should contain("carol@example.com")
    page.should contain(%(href="/invitation/#{token}/connect"))
    browser.post("/invitation/#{token}").headers["Location"].should eq("/invitation/#{token}/connect")
    start = browser.get("/invitation/#{token}/connect")
    start.headers["Location"].should eq("/login/federated/connect?login_hint=carol%40example.com")
    browser.cookie(PartiduoUi::Current::INVITATION_COOKIE).should eq(token)
  ensure
    %w[PARTIDUO_CONNECT_URL PARTIDUO_CONNECT_CLIENT_ID PARTIDUO_CONNECT_CLIENT_SECRET].each { |name| ENV.delete(name) }
  end

  it "refuse un jeton de déconnexion par canal arrière illisible" do
    PartiduoUi::Browser.new.post("/login/federated/connect/backchannel-logout", {"logout_token" => "faux"}).status.should eq(400)
  end
end
