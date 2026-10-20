# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Paramètres du dossier (D-UI-051, D-UI-052) : utilisateurs et profils,
# société, modules, devises, catégories de fiches.

private alias Auth = Partiduo::Api::Auth

private def system
  Partiduo::Api::Actor.system
end

private def admin : PartiduoUi::Browser
  PartiduoUi::Reference.provision
  PartiduoUi::Accounts.create
  PartiduoUi::Accounts.signed_in
end

describe "Paramètres : menu" do
  it "relie les entrées des paramètres à leurs écrans" do
    body = admin.get("/").html
    body.should contain(%(<a href="/settings/company"><span>Société</span></a>))
    body.should contain(%(<a href="/settings/users"><span>Utilisateurs et profils</span></a>))
    body.should contain(%(<a href="/settings/modules"><span>Modules</span></a>))
    body.should contain(%(<a href="/settings/currencies"><span>Devises</span></a>))
    body.should contain(%(<a href="/cards/categories"><span>Catégories de fiches</span></a>))
    body.should contain(%(<a href="/accounting/closing"><span>Clôture</span></a>))
    body.should contain(%(<a href="/accounting/reconciliation"><span>Rapprochement bancaire</span></a>))
  end
end

describe "Utilisateurs et profils (ADR-002 D4, ADR-006 D4)" do
  it "invite un comptable invité en lecture : courriel, lien affiché, profil en lecture seule" do
    browser = admin
    list = browser.get("/settings/users").html
    list.should contain("<h1>Utilisateurs et profils</h1>")
    list.should contain("alice@example.com")

    form = browser.get("/settings/users/new").html
    form.should contain(%(name="role"))
    form.should contain("Comptable invité (lecture)")
    guest = PartiduoUi::Accounts.profile_id("ACCOUNTANT_GUEST")
    Marten::Emailing::Backend::Development.delivered_emails.clear
    response = browser.post("/settings/users/new", {
      "email" => "cabinet@example.com", "first_name" => "Claire", "last_name" => "Expert", "locale" => "fr",
      "role" => "accountant", "profile_id" => guest.to_s, "access_ends_on" => "31/12/2026",
    })
    response.status.should eq(302)
    page = browser.follow(response).html
    page.should contain("Utilisateur cabinet@example.com créé.")
    page.should contain("Invitation envoyée à cabinet@example.com")
    page.should match(/http:\/\/demo\.partiduo\.localhost(:\d+)?\/invitation\/\S+/)
    page.should contain("Comptable invité (lecture)")
    page.should contain("31/12/2026")
    emails = Marten::Emailing::Backend::Development.delivered_emails
    emails.size.should eq(1)
    emails.first.to.map(&.address).should eq(["cabinet@example.com"])

    user = Auth.user_by_email(system, "cabinet@example.com") || raise "utilisateur absent"
    user.role.should eq("accountant")
    user.profile_id.should eq(guest)
  end

  it "refuse un comptable sans nom, champ par champ, et une date illisible" do
    browser = admin
    response = browser.post("/settings/users/new", {"email" => "x@example.com", "role" => "accountant", "access_ends_on" => "demain"})
    response.status.should eq(422)
    response.html.should contain("Indiquez une date valide.")
    Auth.user_by_email(system, "x@example.com").should be_nil
    response = browser.post("/settings/users/new", {"email" => "x@example.com", "role" => "accountant"})
    response.status.should eq(422)
    response.html.should contain(%(aria-invalid="true"))
  end

  it "modifie, révoque puis rouvre un utilisateur ; renvoie une invitation" do
    browser = admin
    bob = PartiduoUi::Accounts.create(email: "bob@example.com", profile: "ACCOUNTANT").user
    browser.post("/settings/users/#{bob.id}/edit", {"email" => "bob@example.com", "first_name" => "Bob", "last_name" => "Durand",
                                                    "locale" => "nl", "role" => "member", "profile_id" => bob.profile_id.to_s}).status.should eq(302)
    Auth.user(system, bob.id).locale.should eq("nl")

    browser.post("/settings/users/#{bob.id}/access/revoke").status.should eq(302)
    Auth.user(system, bob.id).revoked.should be_true
    browser.get("/settings/users/#{bob.id}").html.should contain("Rouvrir l'accès")
    browser.post("/settings/users/#{bob.id}/access/restore").status.should eq(302)
    Auth.user(system, bob.id).revoked.should be_false
    invited = browser.follow(browser.post("/settings/users/#{bob.id}/access/invite")).html
    invited.should contain("Invitation envoyée à bob@example.com")
    browser.post("/settings/users/#{bob.id}/access/nothing").status.should eq(404)
  end

  it "rouvre l'accès en gardant une fin d'accès au jour du dossier (D-AMD-035)" do
    browser = admin
    bob = PartiduoUi::Accounts.create(email: "bob@example.com", profile: "ACCOUNTANT").user
    today = Partiduo::Api::Core.today
    input = Auth::UserInput.new(email: "bob@example.com", first_name: "Bob", last_name: "Durand", locale: "fr",
      role: "member", profile_id: bob.profile_id, access_ends_on: today)
    Auth.update_user(system, bob.id, input).value!.access_ends_on.should eq(today)
    browser.post("/settings/users/#{bob.id}/access/revoke").status.should eq(302)
    browser.post("/settings/users/#{bob.id}/access/restore").status.should eq(302)
    restored = Auth.user(system, bob.id)
    restored.revoked.should be_false
    # Le dernier jour d'accès est celui du dossier : il n'est pas perdu.
    restored.access_ends_on.should eq(today)
  end

  it "règle les droits par journal d'un utilisateur" do
    browser = admin
    bob = PartiduoUi::Accounts.create(email: "bob@example.com", profile: "ACCOUNTANT").user
    ledger = Partiduo::Api::Accounting.ledger_by_code(system, "V01")
    page = browser.get("/settings/users/#{bob.id}/ledgers").html
    page.should contain(%(name="ledger_#{ledger.id}"))
    browser.post("/settings/users/#{bob.id}/ledgers", {"ledger_security" => "1", "ledger_#{ledger.id}" => "R"}).status.should eq(302)
    Auth.user(system, bob.id).ledger_security.should be_true
    Auth.user_ledger_access(system, bob.id, ledger.id).should eq("R")
  end

  it "crée un profil par ses cases, le modifie et le supprime" do
    browser = admin
    page = browser.get("/settings/profiles/new").html
    page.should contain(%(name="perm:cards.card.read"))
    response = browser.post("/settings/profiles/new", {"name" => "Saisie", "perm:cards.card.read" => "1",
                                                       "perm:accounting.entry.post" => "1"})
    response.status.should eq(302)
    id = PartiduoUi::Reference.id_from(response.headers["Location"])
    Auth.profile(system, id).permissions.sort.should eq(["accounting.entry.post", "cards.card.read"])
    browser.get("/settings/profiles/#{id}").html.should contain("Saisir des écritures")
    browser.post("/settings/profiles/#{id}/edit", {"name" => "Saisie", "perm:cards.card.read" => "1"}).status.should eq(302)
    Auth.profile(system, id).permissions.should eq(["cards.card.read"])
    browser.get("/settings/profiles").html.should contain("Comptable invité (lecture)")
    browser.post("/settings/profiles/#{id}/delete").status.should eq(302)
    expect_raises(Partiduo::Api::NotFound) { Auth.profile(system, id) }
  end

  it "consulte le journal d'audit, filtré par utilisateur" do
    browser = admin
    alice = Auth.user_by_email(system, "alice@example.com") || raise "utilisateur absent"
    browser.get("/settings/users").html.should contain(%(href="/settings/audit"))
    page = browser.get("/settings/audit?user=#{alice.id}").html
    page.should contain("<h1>Journal d'audit</h1>")
    page.should contain("alice@example.com")
  end

  it "refuse l'administration à un utilisateur sans la permission" do
    PartiduoUi::Reference.provision
    PartiduoUi::Accounts.create(profile: "ACCOUNTANT")
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/settings/users").status.should eq(403)
    browser.get("/settings/profiles").status.should eq(403)
    browser.get("/settings/modules").status.should eq(403)
    browser.get("/settings/company/edit").status.should eq(403)
    browser.get("/settings/audit").status.should eq(403)
  end
end

describe "Société, modules, devises, catégories" do
  it "modifie la société ; le régime fiscal ne change pas" do
    browser = admin
    browser.get("/settings/company").html.should contain("Atelier Brunet SARL")
    form = browser.get("/settings/company/edit").html
    form.should contain(%(name="auth_method:passkey"))
    data = {"company_name" => "Atelier Brunet SAS", "legal_form" => "SAS", "share_capital" => "10 000,00",
            "siren" => "732 829 320", "vat_number" => "FR 44 732829320", "city" => "Lyon", "country_code" => "FR",
            "default_locale" => "fr", "domain" => "demo.partiduo.localhost", "auth_minimum_level" => "1",
            "session_duration_minutes" => "480", "auth_method:password" => "1", "auth_method:passkey" => "1"}
    browser.post("/settings/company/edit", data).status.should eq(302)
    settings = Partiduo::Api::Core.settings(system)
    settings.company_name.should eq("Atelier Brunet SAS")
    settings.share_capital.should eq(BigDecimal.new("10000"))
    settings.tax_regime.should eq("fr")
    refused = browser.post("/settings/company/edit", data.merge({"siren" => "123"}))
    refused.status.should eq(422)
    refused.html.should contain(%(aria-invalid="true"))
  end

  it "désactive puis réactive un module ; le socle n'a pas de bouton" do
    browser = admin
    page = browser.get("/settings/modules").html
    page.should contain("Comptabilité")
    page.should contain(%(action="/settings/modules/ANALYTIC/deactivate"))
    page.should_not contain(%(action="/settings/modules/CORE/))
    # La Comptabilité est requise par l'Analytique : refus expliqué.
    refused = browser.follow(browser.post("/settings/modules/ACCOUNTING/deactivate")).html
    refused.should contain("ANALYTIC")
    browser.post("/settings/modules/ANALYTIC/deactivate").status.should eq(302)
    Partiduo::Api::Modules.get(system, "ANALYTIC").active.should be_false
    browser.get("/analytic/plans").status.should eq(404)
    browser.post("/settings/modules/ANALYTIC/activate").status.should eq(302)
    Partiduo::Api::Modules.get(system, "ANALYTIC").active.should be_true
  end

  it "crée une devise, ajoute un cours et refuse un cours antérieur" do
    browser = admin
    response = browser.post("/settings/currencies", {"code" => "usd", "name" => "Dollar", "decimals" => "2",
                                                     "rate" => "1,0850", "valid_from" => "2026-01-01"})
    response.status.should eq(302)
    browser.follow(response).html.should contain("USD — Dollar")
    browser.post("/settings/currencies/USD", {"rate" => "1,09", "valid_from" => "2026-02-01"}).status.should eq(302)
    Partiduo::Api::Core.currency(system, "USD").rates.size.should eq(2)
    browser.post("/settings/currencies/USD", {"rate" => "1,1", "valid_from" => "2026-01-15"}).status.should eq(422)
    browser.post("/settings/currencies/USD/delete").status.should eq(302)
    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Core.currency(system, "USD") }
  end

  it "crée une catégorie avec un attribut propre, la modifie, range l'erreur sous la ligne" do
    browser = admin
    response = browser.post("/cards/categories/new", {"code" => "partner", "name" => "Partenaires", "kind" => "customer",
                                                      "attributes[0].key" => "sector", "attributes[0].label" => "Secteur", "attributes[0].value_type" => "text",
                                                      "attributes[1].key" => "", "attributes[1].label" => ""})
    response.status.should eq(302)
    category = Partiduo::Api::Cards.category_by_code(system, "PARTNER") || raise "catégorie absente"
    category.attributes.map(&.key).should eq(["sector"])
    browser.get("/cards/categories/#{category.id}").html.should contain("Secteur")
    refused = browser.post("/cards/categories/#{category.id}/edit", {"name" => "Partenaires",
                                                                     "attributes[0].key" => "sector", "attributes[0].label" => "Secteur", "attributes[0].value_type" => "text",
                                                                     "attributes[1].key" => "Bad Key", "attributes[1].label" => "Mauvaise"})
    refused.status.should eq(422)
    refused.html.should contain(%(id="pd-f-attributes-1-key-errors"))
    browser.post("/cards/categories/#{category.id}/delete").status.should eq(302)
    Partiduo::Api::Cards.category_by_code(system, "PARTNER").should be_nil
  end
end
