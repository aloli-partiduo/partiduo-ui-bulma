# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Imports CSV de fiches et du plan comptable, export au format de l'import,
# archive des pièces (DECISIONS D-OUT-003 à D-OUT-007).

private alias Books = PartiduoUi::Books

private CUSTOMERS = "Nom;Quick code;SIREN\nBoulangerie Martin;MARTIN;732829320\nGarage Morel;;123456789\n"

private def customers_id : String
  PartiduoUi::Reference.category("CUSTOMER").id.to_s
end

private def count_customers : Int64
  Partiduo::Api::Cards.count_cards(Books.system,
    Partiduo::Api::Cards::CardQuery.new(category_id: PartiduoUi::Reference.category("CUSTOMER").id))
end

describe "Import de fiches (D-OUT-003, D-OUT-007)" do
  it "relie l'import à la liste des tiers et montre le formulaire de dépôt" do
    browser = Books.admin
    browser.get("/cards").html.should contain(%(href="/cards/import"))
    page = browser.get("/cards/import?category=#{customers_id}").html
    page.should contain("<h1>Importer des fiches</h1>")
    page.should contain(%(enctype="multipart/form-data"))
    page.should contain(%(type="file"))
    page.should contain("Exporter la catégorie (CSV)")
  end

  it "montre l'aperçu ligne à ligne avec les motifs des refus, sans rien enregistrer" do
    browser = Books.admin
    before = count_customers
    page = browser.post("/cards/import", {"category" => customers_id, "content_text" => CUSTOMERS, "separator" => ";",
                                          "step" => "preview"}).html
    page.should contain("Aperçu (rien n'est encore enregistré)")
    page.should contain("À créer : 1 · à mettre à jour : 0 · refusées : 1")
    page.should contain("Garage Morel")
    page.should contain("SIREN : Le SIREN « 123456789 » n'est pas valide")
    page.should contain(%(<option value="siren" selected>SIREN</option>))
    page.should contain("Importer seulement les lignes acceptées : 1 ligne refusée sera écartée")
    page.should contain(%(name="content" value="))
    count_customers.should eq(before)
  end

  it "refuse d'importer tant qu'une ligne est refusée, puis importe les seules lignes acceptées sur confirmation" do
    browser = Books.admin
    before = count_customers
    content = Base64.strict_encode(CUSTOMERS)
    columns = {"columns" => "3", "column-0" => "name", "column-1" => "code", "column-2" => "siren"}
    base = {"category" => customers_id, "content" => content, "separator" => ";", "step" => "import"}.merge(columns)
    refused = browser.post("/cards/import", base)
    refused.status.should eq(422)
    refused.html.should contain("1 ligne est refusée : corrigez le fichier")
    count_customers.should eq(before)

    done = browser.post("/cards/import", base.merge({"skip_refused" => "1"})).html
    done.should contain("Import terminé. Créées : 1 · mises à jour : 0 · écartées : 1")
    count_customers.should eq(before + 1)
    Partiduo::Api::Cards.card_by_code(Books.system, "MARTIN").should_not be_nil
  end

  it "exporte une catégorie au format de l'import" do
    browser = Books.admin
    Books.card("CUSTOMER", "Martin", code: "MARTIN")
    response = browser.get("/cards/export?category=#{customers_id}")
    response.status.should eq(200)
    response.headers["Content-Disposition"].should contain("fiches-CUSTOMER.csv")
    response.content.should contain("MARTIN")
  end

  it "refuse l'import sans sa permission" do
    PartiduoUi::Reference.provision
    profile = PartiduoUi::Accounts.profile("Saisie", ["cards.card.read", "cards.card.write"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/cards").html.should_not contain(%(href="/cards/import"))
    browser.get("/cards/import").status.should eq(403)
    browser.post("/cards/import", {"content_text" => CUSTOMERS}).status.should eq(403)
  end
end

describe "Import et export du plan comptable (D-OUT-004, D-OUT-007)" do
  it "lit le format d'origine sans en-tête et importe après confirmation" do
    browser = Books.admin
    browser.get("/accounting/chart").html.should contain(%(href="/accounting/chart/import"))
    text = "60799;Achats d'essai;6;CHA\n60798;Autre essai;6;XYZ\n"
    page = browser.post("/accounting/chart/import", {"content_text" => text, "separator" => ";", "step" => "preview"}).html
    page.should contain("À créer : 1 · à mettre à jour : 0 · refusées : 1")
    page.should contain("Type : Type de compte non reconnu : « XYZ ».")
    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Accounting.account(Books.system, "60799") }

    done = browser.post("/accounting/chart/import", {"content_text" => text, "separator" => ";", "step" => "import",
                                                     "skip_refused" => "1"}).html
    done.should contain("Import terminé. Créées : 1")
    Partiduo::Api::Accounting.account(Books.system, "60799").label.should eq("Achats d'essai")
  end

  it "exporte le plan au format de l'import" do
    browser = Books.admin
    response = browser.get("/accounting/chart/export")
    response.status.should eq(200)
    response.headers["Content-Disposition"].should contain("plan-comptable.csv")
    response.content.lines.first.should eq("Numéro;Libellé;Compte parent;Type;Utilisation directe")
  end
end

describe "Archive des pièces (D-OUT-005)" do
  it "propose l'archive depuis les écritures et explique une période sans pièce" do
    browser = Books.admin
    browser.get("/accounting/entries").html.should contain(%(href="/accounting/receipts"))
    form = browser.get("/accounting/receipts").html
    form.should contain("<h1>Archive des pièces</h1>")
    page = browser.get("/accounting/receipts?from=01/01/2026&to=31/12/2026")
    page.status.should eq(422)
    page.html.should contain("Aucune écriture de la période n'a de pièce jointe.")
  end
end
