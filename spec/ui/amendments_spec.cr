# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Amendements de l'interface adoptés le 13 octobre 2026 (partiduo-app,
# DECISIONS D-AMD-031 à D-AMD-033) : route publique d'extension (A-FRM-1),
# formules neutralisées dans l'export CSV commun (A-FRM-5), écran
# d'approbation et ré-authentification forte avant d'approuver (A-SEPA-3).

private alias Approvals = Partiduo::Api::Approvals

private def activate(code : String) : Nil
  Partiduo::Api::Modules.activate(PartiduoUi::Accounts.system, code).success?.should be_true
end

private def approver_profile : Int64
  PartiduoUi::Accounts.profile("Approbateur", ["uipub.batch.approve"])
end

private def submit(email : String, subject : String = "batch:1") : Approvals::ApprovalView
  actor = Partiduo::Api::Auth.actor(PartiduoUi::Accounts.token(email))
  Approvals.submit(actor, Approvals::SubmitInput.new(module_code: "UIPUB", kind: "batch", subject: subject,
    summary: "Virements du 15 octobre", digest: "sha", permission: "uipub.batch.approve",
    amount: BigDecimal.new("1250.40"), currency_code: "EUR")).value!
end

describe "Route publique d'extension (A-FRM-1)" do
  it "monte les routes sous /p/<code>/, nommées pour l'extension" do
    Marten.routes.reverse("uipub_public:hello", token: "abc").should eq("/p/uipub/hello/abc")
    PartiduoUi::Extensions.public_mount?("uipub").try(&.code).should eq("UIPUB")
  end

  it "ignore une extension inactive ou inconnue, et une route inconnue (404), sans session" do
    PartiduoUi::Reference.provision
    response = PartiduoUi::Browser.new.get("/p/uipub/hello/abc")
    response.status.should eq(404)
    response.html.should contain("Lien non valide")
    response.headers["Content-Security-Policy"].should contain("default-src 'none'")
    response.content.should_not contain("<script")
    PartiduoUi::Browser.new.get("/p/inconnue/").status.should eq(404)
    activate("UIPUB")
    PartiduoUi::Browser.new.get("/p/uipub/nulle-part").status.should eq(404)
  end

  it "sert la page de l'extension active à un visiteur, avec les en-têtes stricts communs" do
    PartiduoUi::Reference.provision
    activate("UIPUB")
    response = PartiduoUi::Browser.new.get("/p/uipub/hello/abc")
    response.status.should eq(200)
    response.content.should eq("bonjour abc")
    response.headers["X-Frame-Options"].should eq("DENY")
    response.headers["Referrer-Policy"].should eq("same-origin")
    response.headers["X-Robots-Tag"].should contain("noindex")
    response.headers["X-Content-Type-Options"].should eq("nosniff")
    # Un en-tête que l'extension pose elle-même est gardé.
    response.headers["Cache-Control"].should eq("no-store, private")
    PartiduoUi::Browser.new.get("/p/uipub/open").headers["Cache-Control"].should eq("no-store, private")
  end

  it "limite le débit par route et par adresse (429), et la taille annoncée (413)" do
    PartiduoUi::Reference.provision
    activate("UIPUB")
    visitor = PartiduoUi::Browser.new
    2.times { visitor.get("/p/uipub/hello/a").status.should eq(200) }
    limited = visitor.get("/p/uipub/hello/a")
    limited.status.should eq(429)
    limited.headers["Retry-After"].should eq("60")
    limited.html.should contain("Trop de demandes")
    # Une autre route a sa propre limite (60 en 10 minutes par défaut).
    visitor.get("/p/uipub/open").status.should eq(200)
    big = visitor.post("/p/uipub/open", {"texte" => "x" * 200})
    big.status.should eq(413)
    visitor.post("/p/uipub/open", {"texte" => "court"}).content.should eq("reçu ")
  end
end

describe "Export CSV commun : formules neutralisées (A-FRM-5)" do
  it "préfixe d'une apostrophe une cellule qui commence par = + - @, tabulation ou retour, sauf un nombre" do
    PartiduoUi::Table.csv_safe("=HYPERLINK(\"http://x\")").should eq("'=HYPERLINK(\"http://x\")")
    PartiduoUi::Table.csv_safe("+33 6 12 34 56 78").should eq("'+33 6 12 34 56 78")
    PartiduoUi::Table.csv_safe("-1+1").should eq("'-1+1")
    PartiduoUi::Table.csv_safe("@SUM(A1)").should eq("'@SUM(A1)")
    PartiduoUi::Table.csv_safe("\tcmd").should eq("'\tcmd")
    PartiduoUi::Table.csv_safe("\r=1").should eq("'\r=1")
    PartiduoUi::Table.csv_safe("-12.50").should eq("-12.50")
    PartiduoUi::Table.csv_safe("-3,2").should eq("-3,2")
    PartiduoUi::Table.csv_safe("Dupont = Durand").should eq("Dupont = Durand")
  end

  it "neutralise une fiche reçue du public quand elle ressort dans un export du cœur" do
    PartiduoUi::Reference.provision
    PartiduoUi::Accounts.create
    category = PartiduoUi::Reference.category("CUSTOMER")
    Partiduo::Api::Cards.create_card(PartiduoUi::Accounts.system,
      Partiduo::Api::Cards::CardInput.new(category_id: category.id, name: "=cmd|' /C calc'!A0")).value!
    csv = PartiduoUi::Accounts.signed_in.get("/cards?format=csv").content
    csv.should contain("'=cmd|")
    csv.should_not contain(";=cmd")
  end
end

describe "Approbations (A-SEPA-3)" do
  it "liste les demandes à décider, dans le menu et « À traiter », et les ouvre" do
    PartiduoUi::Reference.provision
    activate("UIPUB")
    profile = approver_profile
    PartiduoUi::Accounts.create("alice@example.com")
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    request = submit("alice@example.com")

    bob = PartiduoUi::Accounts.signed_in("bob@example.com")
    list = bob.get("/approvals")
    list.status.should eq(200)
    list.html.should contain("Virements du 15 octobre")
    list.html.should contain("Confirmer son identité pour approuver")
    list.html.should contain(%(href="/approvals"))
    bob.get("/").html.should contain("1 opération à approuver")
    detail = bob.get("/approvals/#{request.id}")
    detail.status.should eq(200)
    detail.html.should contain("Alice Martin")
    detail.html.should contain("1\u202F250,40 EUR")
    detail.html.should contain("Confirmer mon identité pour approuver")
    detail.html.should contain("Piste d'audit")

    # Sans rien d'attente, pas d'entrée de menu.
    nobody = PartiduoUi::Accounts.create("carol@example.com", profile: nil,
      profile_id: PartiduoUi::Accounts.profile("Aucun", ["accounting.entry.read"]))
    PartiduoUi::Accounts.signed_in("carol@example.com").get("/").html.should_not contain(%(href="/approvals"))
    nobody.user.id.should be > 0
    PartiduoUi::Accounts.signed_in("carol@example.com").get("/approvals/#{request.id}").status.should eq(404)
  end

  it "envoie confirmer son identité avant d'approuver, puis approuve" do
    PartiduoUi::Reference.provision
    activate("UIPUB")
    profile = approver_profile
    PartiduoUi::Accounts.create("alice@example.com")
    bob_id = PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile).user.id
    secret = PartiduoUi::Accounts.enable_totp("bob@example.com")
    request = submit("alice@example.com")

    bob = PartiduoUi::Browser.new
    bob.post("/login", {"email" => "bob@example.com", "password" => PartiduoUi::Accounts::PASSWORD}).status.should eq(302)
    bob.post("/login/second-factor", {"kind" => "totp", "code" => PartiduoUi::Accounts.totp_code(secret)}).status.should eq(302)
    # Authentification forte trop ancienne : la session a plus d'une heure.
    Marten::DB::Connection.default.open do |db|
      db.exec("UPDATE auth_session SET strong_auth_at = now() - interval '1 hour' WHERE user_id = $1", bob_id)
    end
    refused = bob.post("/approvals/#{request.id}/approve", {"comment" => "ok"})
    refused.status.should eq(302)
    refused.headers["Location"].should eq("/approvals/#{request.id}/reauth")
    page = bob.get("/approvals/#{request.id}/reauth")
    page.status.should eq(200)
    page.html.should contain("Confirmer votre identité")
    page.html.should contain("Un code de récupération ne suffit pas")

    bad = bob.post("/approvals/#{request.id}/reauth", {"code" => "000000"})
    bad.status.should eq(422)
    ok = bob.post("/approvals/#{request.id}/reauth", {"code" => PartiduoUi::Accounts.totp_code(secret, Time.utc + 30.seconds)})
    ok.status.should eq(302)
    ok.headers["Location"].should eq("/approvals/#{request.id}")
    bob.get("/approvals/#{request.id}").html.should contain("Approuver l'opération")
    approved = bob.post("/approvals/#{request.id}/approve", {"comment" => "Vu avec le fournisseur"})
    approved.status.should eq(302)
    view = Approvals.approval(Partiduo::Api::Actor.system, request.id)
    view.approved?.should be_true
    view.comment.should eq("Vu avec le fournisseur")
    bob.get("/approvals/#{request.id}").html.should contain("Approuvée")
  end

  it "refuse à la même personne en validation à deux, et règle le mode depuis l'écran de la société" do
    PartiduoUi::Reference.provision
    activate("UIPUB")
    PartiduoUi::Accounts.create("alice@example.com", profile: "ADMIN")
    admin = PartiduoUi::Accounts.signed_in("alice@example.com")
    form = admin.get("/settings/company/edit").html
    form.should contain("Validation des opérations sensibles")
    form.should contain("Identifiant créancier SEPA")
    settings = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
    data = {"company_name" => settings.company_name, "siren" => settings.siren, "vat_number" => settings.vat_number,
            "country_code" => "FR", "default_locale" => "fr", "domain" => settings.domain, "auth_minimum_level" => "1",
            "session_duration_minutes" => "480", "auth_method:password" => "1", "auth_method:passkey" => "1",
            "approval_mode" => "dual", "approval_reauth_minutes" => "10", "creditor_identifier" => "FR72ZZZ123456"}
    admin.post("/settings/company/edit", data).status.should eq(302)
    saved = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
    saved.approval_mode.should eq("dual")
    saved.approval_reauth_minutes.should eq(10)
    saved.creditor_identifier.should eq("FR72ZZZ123456")
    admin.get("/settings/company").html.should contain("Deux personnes")

    # Un formulaire sans ces champs ne les efface pas.
    admin.post("/settings/company/edit", data.reject("approval_mode", "approval_reauth_minutes", "creditor_identifier"))
      .status.should eq(302)
    Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).creditor_identifier.should eq("FR72ZZZ123456")

    profile = PartiduoUi::Accounts.profile("Approbateur", ["uipub.batch.approve"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    request = submit("bob@example.com")
    secret = PartiduoUi::Accounts.enable_totp("bob@example.com")
    bob = PartiduoUi::Browser.new
    bob.post("/login", {"email" => "bob@example.com", "password" => PartiduoUi::Accounts::PASSWORD})
    bob.post("/login/second-factor", {"kind" => "totp", "code" => PartiduoUi::Accounts.totp_code(secret)}).status.should eq(302)
    detail = bob.get("/approvals/#{request.id}")
    detail.html.should contain("Attend une autre personne")
    detail.html.should_not contain("Approuver l'opération")
    refused = bob.post("/approvals/#{request.id}/approve")
    refused.status.should eq(422)
    refused.html.should contain("une autre personne que celle qui a soumis la demande")
    Approvals.approval(Partiduo::Api::Actor.system, request.id).pending?.should be_true
  end
end
