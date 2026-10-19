# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Sécurité du compte (ADR-002 D6)" do
  it "affiche le niveau atteint, le niveau exigé et ce qu'il manque pour monter" do
    PartiduoUi::Accounts.create
    body = PartiduoUi::Accounts.signed_in.get("/account/security").html
    body.should contain("<h1>Sécurité du compte</h1>")
    body.should contain("Votre session est au niveau 1 ; ce dossier exige le niveau 1")
    body.should contain("Pour monter d'un niveau")
    body.should contain("Activez une application d'authentification pour atteindre le niveau 2.")
    body.should contain("Enregistrez une clé d'accès (passkey) pour atteindre le niveau 3.")
    body.should contain("Aucune clé d'accès enregistrée.")
    body.should contain("Configurer une application d'authentification")
    body.should contain("0 code de récupération inutilisé.")
  end

  it "enrôle l'application d'authentification : QR code et secret base32, sans nommer d'application" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    # Le GET ne crée pas de secret : c'est le POST du bouton (CSRF).
    browser.get("/account/totp").html.should contain(%(action="/account/totp/start"))
    browser.post("/account/totp/start").headers["Location"].should eq("/account/totp")
    body = browser.get("/account/totp").html
    body.should contain(%(<svg class="pd-qr"))
    body.should contain(%(role="img" aria-label="QR code à scanner avec votre application d'authentification"))
    secret = body.match!(/<p class="pd-secret"[^>]*>.*?<code>([A-Z2-7 ]+)<\/code>/)[1]
    body.should contain(%(<span class="is-sr-only">Secret à saisir à la main : </span>))
    secret.delete(' ').size.should eq(32)
    body.should contain("fondé sur le temps, 6 chiffres, 30 secondes")
    %w[Google Microsoft Authy FreeOTP Aegis 2FAS Bitwarden 1Password KeePass].each do |brand|
      body.should_not contain(brand)
    end

    # Code refusé en HTMX : seul le message change, le QR code reste valable.
    refused = browser.htmx_post("/account/totp", {"code" => "000000"})
    refused.status.should eq(200)
    refused.html.should contain(%(<div id="pd-totp-feedback"))
    refused.html.should contain("Code incorrect.")

    code = PartiduoUi::Accounts.totp_code(secret.delete(' '))
    accepted = browser.htmx_post("/account/totp", {"code" => code})
    accepted.headers["HX-Retarget"].should eq("body")
    accepted.html.should contain("Codes de récupération")
    accepted.html.scan(/<li><code>[^<]+<\/code><\/li>/).size.should eq(10)

    browser.get("/account/security").html.should contain("10 codes de récupération inutilisés.")
  end

  it "exige une session de niveau 2 pour régénérer les codes, et le dit" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    body = browser.get("/account/security").html
    body.should contain("Pour cette opération, vérifiez d'abord votre identité")
    body.should_not contain(%(action="/account/recovery-codes"))
    response = browser.post("/account/recovery-codes")
    response.headers["Location"].should eq("/account/security")
    browser.get("/account/security").html.should contain("Cette opération demande une vérification supplémentaire de votre identité.")
  end

  it "élève la session par un code de l'application d'authentification" do
    PartiduoUi::Accounts.create
    secret = PartiduoUi::Accounts.enable_totp
    browser = PartiduoUi::Browser.new
    step = browser.post("/login", {"email" => "alice@example.com", "password" => PartiduoUi::Accounts::PASSWORD})
    browser.follow(step)
    browser.post("/login/second-factor", {"kind" => "totp", "code" => PartiduoUi::Accounts.totp_code(secret)})
    body = browser.get("/account/security").html
    body.should contain("Votre session est au niveau 2")
    body.should contain(%(action="/account/recovery-codes"))
    codes = browser.post("/account/recovery-codes").html
    codes.scan(/<li><code>[^<]+<\/code><\/li>/).size.should eq(10)
    # Fichier nommé d'après le dossier, qui le rappelle en première ligne.
    codes.should match(/download="codes-de-recuperation-[a-z0-9.-]+\.txt"/)
    codes.should contain(URI.encode_path_segment("Codes de récupération de votre compte sur "))
  end

  it "renvoie un comptable (niveau 3 exigé) vers l'élévation, sans accès aux écrans" do
    PartiduoUi::Accounts.create(email: "compta@example.com", role: "accountant", profile: "ACCOUNTANT")
    browser = PartiduoUi::Browser.new
    response = browser.post("/login", {"email" => "compta@example.com", "password" => PartiduoUi::Accounts::PASSWORD})
    response.headers["Location"].should eq("/account/security")
    body = browser.get("/account/security").html
    body.should contain("Vérifier votre identité")
    body.should contain("ce dossier exige le niveau 3")
    browser.get("/").headers["Location"].should eq("/account/security")
  end

  it "ajoute, renomme et liste une clé d'accès" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    options = browser.post("/account/passkeys/options").html
    browser.post("/account/passkeys", PartiduoUi::FakeAuthenticator.new.register(options, "Portable"))
    body = browser.get("/account/security").html
    body.should contain(%(value="Portable"))
    id = body.match!(/action="\/account\/passkeys\/(\d+)\/rename"/)[1]
    browser.post("/account/passkeys/#{id}/rename", {"name" => "Bureau"}).headers["Location"].should eq("/account/security")
    browser.get("/account/security").html.should contain(%(value="Bureau"))
  end
end
