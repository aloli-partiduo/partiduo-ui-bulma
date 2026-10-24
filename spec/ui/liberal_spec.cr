# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# ADR-007 D6 (et D3) — écrans de la profession libérale : mode simplifié
# (menu Tableau de bord, Recettes, Dépenses, Immobilisations, Factures,
# 2035, Justificatifs), saisie d'une recette ou d'une dépense en quelques
# champs avec choix de la rubrique, registre des immobilisations, 2035
# préparée (2035-A, 2035-B, contrôles, préparation du dépôt), paramètres.
# Tout par `Partiduo::Api`.

private alias Liberal = Partiduo::Api::Liberal
private alias Books = PartiduoUi::Books

# Dossier d'un libéral : module liberal et Facturation actifs,
# Comptabilité inactive (configuration `liberal` d'ADR-007).
private def liberal_books(accounting : Bool = false) : PartiduoUi::Browser
  browser = Books.admin
  unless accounting
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  end
  Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
  Liberal.load_defaults(Books.system)
  browser
end

private def nature(code : String) : Liberal::NatureView
  Liberal.natures(Books.system).find! { |item| item.code == code }
end

private def receipt(day : String, amount : String, code : String = "RECEIPTS") : Liberal::LineView
  input = Liberal::LineInput.new(date: Books.date(day), nature_id: nature(code).id, amount: Books.d(amount), method: "transfer",
    party_name: "Mme Durand")
  Liberal.record_receipt(Books.system, input).value!
end

private def expense(day : String, amount : String, code : String = "RENT") : Liberal::LineView
  input = Liberal::LineInput.new(date: Books.date(day), nature_id: nature(code).id, amount: Books.d(amount), method: "transfer",
    party_name: "SCI du Parc")
  Liberal.record_expense(Books.system, input).value!
end

private def asset(day : String = "2026-04-01", amount : String = "3000", years : Int32 = 3) : Liberal::AssetView
  input = Liberal::AssetInput.new(label: "Table de massage", category: "equipment", acquired_on: Books.date(day),
    amount: Books.d(amount), duration_years: years, method: "transfer")
  Liberal.record_asset(Books.system, input).value!
end

# Vocabulaire courant : jamais « débit » ni « crédit » à l'écran.
private def plain_words(html : String) : String
  html.gsub(/<script.*?<\/script>/m, "").gsub(/<[^>]+>/, " ")
end

describe "Écrans de la profession libérale (ADR-007 D6)" do
  it "n'existent pas quand le module est inactif" do
    browser = Books.admin
    browser.get("/").html.should_not contain("pd-simple")
    %w[/liberal/journal /liberal/receipts /liberal/expenses/new /liberal/assets /liberal/assets/new /liberal/tax-return
      /liberal/settings /liberal/natures /liberal/form-lines].each do |path|
      browser.get(path).status.should eq(404), path
    end
  end

  it "présente le menu réduit et le tableau de bord de la profession libérale" do
    browser = liberal_books
    receipt("2026-03-10", "1200")
    expense("2026-03-12", "450")
    page = browser.get("/").html
    page.should contain("pd-simple")
    menu = page.match!(/<nav class="pd-side menu".*?<\/nav>/m)[0]
    labels = menu.scan(/<a href="[^"]+"[^>]*><span>([^<]+)<\/span>/).map(&.[1])
    labels.should eq(["Tableau de bord", "Recettes", "Dépenses", "Immobilisations", "Factures", "2035"])
    menu.should contain(%(href="/liberal/receipts"))
    menu.should contain(%(href="/liberal/expenses"))
    menu.should contain(%(href="/liberal/tax-return"))
    page.should contain("Recettes 2026")
    page.should contain("1 200,00 €")
    page.should contain("Dépenses 2026")
    page.should contain("450,00 €")
    page.should contain("Résultat estimé 2026")
    page.should contain("Loyers et charges locatives")
    page.should contain("Nouvelle recette")
    page.should contain("Nouvelle dépense")
    page.should contain(%(href="/liberal/settings"))
    page.should contain("Paramètres de la profession libérale")
    page.should_not contain("missing translation")
    plain_words(page).should_not match(/d[ée]bit|cr[ée]dit/i)
    # Factures : le formulaire habituel de la Facturation (pas la facture
    # allégée de la micro-entreprise).
    browser.get("/invoicing/documents").html.should contain(%(href="/invoicing/invoices/new"))
  end

  it "applique la préférence de chaque utilisateur, réglée dans ses préférences et gardée d'une session à l'autre (D-UI-077)" do
    PartiduoUi::SimpleMode.interfaces("LIBERAL", "member", true).should eq(["simple", "full"])
    PartiduoUi::SimpleMode.interfaces("LIBERAL", "accountant", false).should eq(["simple"])
    PartiduoUi::SimpleMode.choose("full", ["simple", "full"]).should eq("full")
    PartiduoUi::SimpleMode.choose("full", ["simple"]).should eq("simple")
    browser = liberal_books(accounting: true)
    # Utilisateur de la société : recettes et dépenses tant qu'il n'a rien choisi.
    simple = browser.get("/").html
    simple.should contain("pd-simple")
    simple.should contain(%(href="/account/preferences"))
    form = browser.get("/account/preferences").html
    form.should contain(%(<option value="simple" selected>Recettes et dépenses</option>))
    form.should contain(%(<option value="full">Comptabilité</option>))
    form.should contain("les journaux, les écritures et le plan comptable")
    form.should contain("Vous n'avez encore rien choisi")
    form.should_not contain("missing translation")
    browser.post("/account/preferences", {"interface" => "expert"}).status.should eq(422)
    saved = browser.post("/account/preferences", {"interface" => "full"})
    saved.headers["Location"].should eq("/account/preferences")
    browser.get("/account/preferences").html.should contain(%(<option value="full" selected>Comptabilité</option>))
    full = browser.get("/").html
    full.should_not contain("pd-simple")
    full.should contain(%(href="/accounting/))
    full.should contain("Passer aux recettes et dépenses")
    # Aucun cookie : la préférence est enregistrée avec le compte.
    browser.jar.has_key?("partiduo_mode").should be_false
    PartiduoUi::Accounts.signed_in.get("/").html.should_not contain("pd-simple")
    # Un autre utilisateur de la société garde la sienne (le défaut).
    PartiduoUi::Accounts.create(email: "bob@example.com")
    PartiduoUi::Accounts.signed_in("bob@example.com").get("/").html.should contain("pd-simple")
    # Les paramètres du dossier ne règlent plus l'interface.
    browser.get("/liberal/settings").html.should_not contain(%(name="interface"))

    # Le raccourci du menu enregistre la préférence, comme l'écran.
    browser.post("/mode", {"mode" => "simple"}).headers["Location"].should eq("/")
    browser.get("/").html.should contain("Passer à la comptabilité")
    PartiduoUi::Accounts.signed_in.get("/account/preferences").html
      .should contain(%(<option value="simple" selected>Recettes et dépenses</option>))
    browser.post("/mode", {"mode" => "simple"}).status.should eq(403) # déjà en recettes et dépenses
    browser.post("/mode", {"mode" => "full"}).headers["Location"].should eq("/")

    # Comptabilité désactivée : recettes et dépenses, préférence conservée.
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
    home = browser.get("/").html
    home.should contain("pd-simple")
    home.should_not contain(%(action="/mode"))
    page = browser.get("/account/preferences").html
    page.should_not contain(%(name="interface"))
    page.should contain("Interface appliquée : Recettes et dépenses.")
    page.should contain("« Comptabilité », est conservée")
    browser.post("/account/preferences", {"interface" => "full"}).status.should eq(422)
    browser.post("/mode", {"mode" => "full"}).status.should eq(403)
    Partiduo::Api::Modules.activate(Books.system, "ACCOUNTING").success?.should be_true
    browser.get("/").html.should_not contain("pd-simple")
  end

  it "met le comptable en comptabilité par défaut ; lui aussi règle sa préférence" do
    liberal_books(accounting: true)
    PartiduoUi::Accounts.create(email: "compta@example.com", role: "accountant", profile: "ACCOUNTANT")
    browser = PartiduoUi::Accounts.signed_in("compta@example.com")
    authenticator = PartiduoUi::FakeAuthenticator.new
    options = browser.post("/account/passkeys/options").html
    JSON.parse(browser.post("/account/passkeys", authenticator.register(options)).html)["ok"].as_bool.should be_true
    sign_in = -> do
      accountant = PartiduoUi::Browser.new
      login = accountant.post("/login/passkey/options").html
      JSON.parse(accountant.post("/login/passkey", authenticator.assert(login)).html)["ok"].as_bool.should be_true
      accountant
    end
    accountant = sign_in.call

    full = accountant.get("/").html
    full.should_not contain("pd-simple")
    full.should contain("Passer aux recettes et dépenses")
    accountant.get("/account/preferences").html.should contain(%(<option value="full" selected>Comptabilité</option>))
    accountant.post("/mode", {"mode" => "simple"}).headers["Location"].should eq("/")
    accountant.get("/").html.should contain("Passer à la comptabilité")
    # Nouvelle session, nouvel appareil : la préférence suit le comptable.
    sign_in.call.get("/").html.should contain("pd-simple")
    # Sans la Comptabilité, recettes et dépenses pour lui aussi.
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
    accountant.post("/account/preferences", {"interface" => "full"}).status.should eq(422)
  end

  it "saisit une dépense en quelques champs avec le choix de la rubrique, pensée pour le téléphone" do
    browser = liberal_books
    form = browser.get("/liberal/expenses/new").html
    form.should contain(%(inputmode="decimal"))
    form.should contain(%(capture="environment"))
    form.should contain("Rubrique")
    form.should contain("Loyers et charges locatives")
    form.should contain("Frais de véhicules")
    form.should_not contain("Recettes encaissées")
    form.should contain("Part privée")
    form.should contain(%(value="#{Partiduo::Api::Core.today.to_s("%Y-%m-%d")}"))
    plain_words(form).should_not match(/d[ée]bit|cr[ée]dit/i)

    refused = browser.post("/liberal/expenses/new", {"amount" => "", "date" => "2026-03-10", "nature_id" => nature("RENT").id.to_s,
                                                     "method" => "transfer"})
    refused.status.should eq(422)
    refused.html.should contain("Ce champ est obligatoire.")
    too_private = browser.post("/liberal/expenses/new", {"amount" => "100", "date" => "2026-03-10", "nature_id" => nature("VEHICLE").id.to_s,
                                                         "method" => "card", "nondeductible_amount" => "150"})
    too_private.status.should eq(422)
    too_private.html.should contain("La part non déductible ne peut dépasser le montant")

    saved = browser.post("/liberal/expenses/new", {"amount" => "400", "date" => "2026-03-10", "nature_id" => nature("VEHICLE").id.to_s,
                                                   "method" => "card", "party_name" => "Garage Martin", "nondeductible_amount" => "100"})
    saved.status.should eq(302)
    saved.headers["Location"].should eq("/liberal/expenses")
    line = Liberal.lines(Books.system).first
    {line.kind, line.amount, line.nondeductible_amount, line.heading}.should eq({"expense", Books.d("400"), Books.d("100"), "vehicle"})
    list = browser.follow(saved).html
    list.should contain("Dépense #{line.number} enregistrée : 400,00 € payés.")
    list.should contain("Total dépensé")
    list.should contain("Dont Frais de véhicules")
    list.should contain("Garage Martin")

    again = browser.post("/liberal/receipts/new", {"amount" => "60", "date" => "2026-03-11", "nature_id" => nature("RECEIPTS").id.to_s,
                                                   "method" => "cheque", "again" => "1"})
    again.headers["Location"].should eq("/liberal/receipts/new")
    Liberal.lines(Books.system, Liberal::JournalQuery.new(kind: "receipt")).size.should eq(1)
  end

  it "contre-passe une ligne par une ligne inverse datée du jour et édite le livre-journal" do
    browser = liberal_books
    line = expense("2026-03-12", "80")
    show = browser.get("/liberal/lines/#{line.id}").html
    # Exercice ouvert : modifier ou supprimer (D-LIB2-001).
    show.should contain(%(action="/liberal/lines/#{line.id}/delete"))
    show.should contain("SCI du Parc")
    cancelled = browser.post("/liberal/lines/#{line.id}/reverse")
    cancelled.headers["Location"].should eq("/liberal/lines/#{line.id}")
    reversal = Liberal.line(Books.system, Liberal.line(Books.system, line.id).reversed_by_id || raise "ligne non annulée")
    reversal.amount.should eq(Books.d("-80"))
    browser.follow(cancelled).html.should contain("annulée par #{reversal.number}")

    journal = browser.get("/liberal/journal?year=2026").html
    journal.should contain("Livre-journal 2026")
    journal.should contain("Total des recettes")
    journal.should contain("Solde")
    csv = browser.get("/liberal/journal?year=2026&format=csv")
    csv.status.should eq(200)
    csv.headers["Content-Disposition"].should contain("attachment")
    pdf = browser.get("/liberal/expenses?format=pdf")
    pdf.content_type.should eq("application/pdf")
    pdf.content.should start_with("%PDF-")
  end

  it "tient le registre des immobilisations : acquisition, plan d'amortissement, cession" do
    browser = liberal_books
    form = browser.get("/liberal/assets/new").html
    form.should contain("Durée d'amortissement")
    form.should contain(%(capture="environment"))
    refused = browser.post("/liberal/assets/new", {"amount" => "1000", "label" => "", "category" => "equipment",
                                                   "acquired_on" => "2026-04-01", "duration_years" => "3", "method" => "transfer"})
    refused.status.should eq(422)
    refused.html.should contain("Indiquer une désignation")
    saved = browser.post("/liberal/assets/new", {"amount" => "3000", "label" => "Table de massage", "category" => "equipment",
                                                 "acquired_on" => "2026-04-01", "duration_years" => "3", "method" => "transfer"})
    saved.status.should eq(302)
    item = Liberal.assets(Books.system).first
    saved.headers["Location"].should eq("/liberal/assets/#{item.id}")
    show = browser.follow(saved).html
    show.should contain("Plan d'amortissement")
    show.should contain("750,00 €")
    show.should contain("Céder")
    browser.get("/liberal/assets").html.should contain("Table de massage")

    browser.get("/liberal/assets/#{item.id}/dispose").status.should eq(200)
    disposed = browser.post("/liberal/assets/#{item.id}/dispose", {"date" => "2026-06-30", "price" => "2800", "method" => "transfer"})
    disposed.headers["Location"].should eq("/liberal/assets/#{item.id}")
    page = browser.follow(disposed).html
    page.should contain("Cession de #{item.number} enregistrée.")
    page.should contain("Plus ou moins-value")
    Liberal.asset(Books.system, item.id).disposal.should_not be_nil
  end

  it "présente la 2035 : 2035-A, 2035-B, contrôles, réintégrations et préparation du dépôt" do
    browser = liberal_books
    receipt("2026-03-01", "60000.40")
    expense("2026-03-06", "9600")
    asset
    page = browser.get("/liberal/tax-return?year=2026").html
    page.should contain("Déclaration 2035 des revenus 2026")
    page.should contain("2035-A · Compte de résultat fiscal")
    page.should contain("Recettes encaissées")
    page.should contain("60 000 €")
    page.should contain("9 600 €")
    page.should contain("2035-B · Détermination du résultat")
    page.should contain("Immobilisations et amortissements")
    page.should contain("Table de massage")
    page.should contain("Contrôles")
    page.should contain("Préparation du dépôt")
    page.should contain("Empreinte de cette version : #{Liberal.tax_return(Books.system, 2026).fingerprint}")
    page.should contain("Montants à transmettre par case")
    page.should_not contain("missing translation")
    if Liberal.tax_return(Books.system, 2026).ready?
      page.should contain("Déclaration prête à être déposée")
    else
      page.should contain("À corriger avant le dépôt")
    end

    refused = browser.post("/liberal/tax-return/adjustments?year=2026", {"kind" => "deduction", "label" => "", "amount" => "500"})
    refused.status.should eq(422)
    refused.html.should contain("Indiquer un libellé")
    added = browser.post("/liberal/tax-return/adjustments?year=2026", {"kind" => "deduction", "label" => "Exonération", "amount" => "500"})
    added.headers["Location"].should eq("/liberal/tax-return?year=2026")
    browser.follow(added).html.should contain("Exonération")
    adjustment = Liberal.adjustments(Books.system, 2026).first
    Liberal.tax_return(Books.system, 2026).amount("deductions").should eq(Books.d("500"))
    browser.post("/liberal/adjustments/#{adjustment.id}/delete?year=2026").headers["Location"].should eq("/liberal/tax-return?year=2026")
    Liberal.adjustments(Books.system, 2026).should be_empty

    pdf = browser.get("/liberal/tax-return?year=2026&format=pdf")
    pdf.content_type.should eq("application/pdf")
  end

  it "signale un poste sans ligne au millésime et le corrige dans la table de correspondance" do
    browser = liberal_books
    expense("2026-03-06", "120", "OFFICE")
    office = Liberal.form_lines(Books.system).find! { |line| line.item == "office" }
    browser.get("/liberal/form-lines?millesime=2026").html.should contain("Lignes en vigueur pour 2026")
    browser.post("/liberal/form-lines/#{office.id}/delete?millesime=2026").status.should eq(302)
    blocked = browser.get("/liberal/tax-return?year=2026").html
    blocked.should contain("À corriger avant le dépôt")
    blocked.should contain("n'a pas de ligne dans la table du millésime 2026")
    blocked.should contain("sans ligne au millésime")
    saved = browser.post("/liberal/form-lines", {"millesime" => "2026", "item" => "office", "form" => "2035-A", "line" => "27",
                                                 "box" => "bx"})
    saved.headers["Location"].should eq("/liberal/form-lines?millesime=2026")
    Liberal.form_lines(Books.system, 2026).find!(&.item.==("office")).box.should eq("BX")
    browser.get("/liberal/tax-return?year=2026").html.should_not contain("sans ligne au millésime")
  end

  it "modifie les paramètres et les natures" do
    browser = liberal_books
    browser.get("/liberal/settings").status.should eq(200)
    saved = browser.post("/liberal/settings", {"profession" => "Masseur-kinésithérapeute", "activity_started_on" => "2020-01-01",
                                               "default_nature_id" => nature("RECEIPTS").id.to_s})
    saved.status.should eq(302)
    Liberal.settings(Books.system).profession.should eq("Masseur-kinésithérapeute")
    browser.get("/liberal/tax-return?year=2026").html.should contain("Masseur-kinésithérapeute")

    created = browser.post("/liberal/natures", {"code" => "LOYER_CABINET", "label" => "Loyer du cabinet", "kind" => "expense",
                                                "heading" => "rent", "enabled" => "1"})
    created.headers["Location"].should eq("/liberal/natures")
    wrong = browser.post("/liberal/natures", {"code" => "MAUVAIS", "label" => "Mauvais", "kind" => "receipt", "heading" => "rent"})
    wrong.status.should eq(422)
    wrong.html.should contain("Rubrique incompatible avec le sens")
    browser.get("/liberal/expenses/new").html.should contain("Loyer du cabinet")
    browser.post("/liberal/defaults").headers["Location"].should eq("/liberal/settings")
  end

  it "paramètre les comptes et republie quand la Comptabilité est active" do
    browser = liberal_books(accounting: true)
    receipt("2026-03-10", "300")
    browser.get("/").html.should contain("pd-simple")
    browser.get("/liberal/settings").html.should contain("Republier vers la Comptabilité")
    browser.post("/liberal/republish").headers["Location"].should eq("/liberal/settings")
    page = browser.get("/accounting/liberal-accounts").html
    page.should contain("Comptes de la profession libérale")
    page.should contain("Loyers et charges locatives (rent)")
    saved = browser.post("/accounting/liberal-accounts", {"key" => "receipts", "account" => "706"})
    saved.status.should eq(302)
    Partiduo::Api::Accounting.liberal_accounts(Books.system).map(&.key).should eq(["receipts"])
    browser.follow(saved).html.should contain("Recettes encaissées (receipts)")
  end

  it "est traduit en anglais et en néerlandais" do
    browser = liberal_books
    line = receipt("2026-03-10", "100")
    item = asset
    {"en" => "Income 2026", "nl" => "Ontvangsten 2026"}.each do |locale, title|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      ["/", "/liberal/journal", "/liberal/receipts", "/liberal/receipts/new", "/liberal/expenses", "/liberal/expenses/new",
       "/liberal/lines/#{line.id}", "/liberal/assets", "/liberal/assets/new", "/liberal/assets/#{item.id}",
       "/liberal/assets/#{item.id}/dispose", "/liberal/tax-return", "/liberal/settings", "/liberal/natures",
       "/liberal/natures/#{line.nature_id}", "/liberal/form-lines"].each do |path|
        response = browser.get(path)
        response.status.should eq(200), "#{locale} #{path} : #{response.status}"
        response.html.should_not contain("missing translation"), "#{locale} #{path}"
        response.html.should contain(%(<html lang="#{locale}">))
      end
      browser.get("/").html.should contain(title)
    end
  end

  it "compose le menu réduit selon le module ; micro-entreprise et profession libérale ne sont jamais actives ensemble" do
    liberal_books
    actor = Books.system
    PartiduoUi::SimpleMode.flavor(actor).try(&.module_code).should eq("LIBERAL")
    # Deux régimes d'imposition distincts (D-AMD-038 du cœur) : l'une
    # remplace l'autre.
    Partiduo::Api::Modules.activate(actor, "MICRO").error_keys.should eq(["modules.errors.activation.incompatible_with"])
    Partiduo::Api::Modules.deactivate(actor, "LIBERAL").success?.should be_true
    Partiduo::Api::Modules.activate(actor, "MICRO").success?.should be_true
    PartiduoUi::SimpleMode.flavor(actor).try(&.module_code).should eq("MICRO")
  end
end
