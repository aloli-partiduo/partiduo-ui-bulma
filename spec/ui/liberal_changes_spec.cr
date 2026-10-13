# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# D-LIB2-001 à D-LIB2-006 : livre-journal et immobilisations de la
# profession libérale modifiables tant que l'exercice est ouvert. En-tête
# d'exercice (« ouvert, modifiable », « clôturé le … », « 2035 transmise le
# … ») ; ligne d'un exercice ouvert : Modifier et Supprimer (confirmation) ;
# exercice figé : cadenas et « Contre-passer ». Deux exercices ouverts à la
# fois. Mode simplifié et mode complet, téléphone (cibles de 44 px), fr, en,
# nl. Tout par `Partiduo::Api`.

private alias Liberal = Partiduo::Api::Liberal
private alias Books = PartiduoUi::Books

# Dossier d'un libéral (module liberal actif, Comptabilité inactive),
# exercices 2025 et 2026, administrateur connecté en mode simplifié.
private def open_books : PartiduoUi::Browser
  browser = Books.admin
  Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
  Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
  Liberal.load_defaults(Books.system)
  PartiduoUi::Reference.fiscal_year(2025)
  browser
end

private def open_nature(code : String) : Liberal::NatureView
  Liberal.natures(Books.system).find! { |item| item.code == code }
end

private def open_expense(day : String, amount : String, party : String = "SCI du Parc") : Liberal::LineView
  input = Liberal::LineInput.new(date: Books.date(day), nature_id: open_nature("RENT").id, amount: Books.d(amount),
    method: "transfer", party_name: party)
  Liberal.record_expense(Books.system, input).value!
end

private def open_asset(day : String = "2026-04-01") : Liberal::AssetView
  input = Liberal::AssetInput.new(label: "Table de massage", category: "equipment", acquired_on: Books.date(day),
    amount: Books.d("3000"), duration_years: 5, method: "transfer")
  Liberal.record_asset(Books.system, input).value!
end

# Exercice 2025 clôturé au socle.
private def close_2025 : Nil
  year = Partiduo::Api::Core.fiscal_years(Books.system).find! { |item| item.year == 2025 }
  Partiduo::Api::Core.close_fiscal_year(Books.system, year.id).value!
end

# 2035 de `year` transmise : ce que note le module à l'événement
# `tax_return.transmitted` de l'extension qui la dépose (l'interface ne
# publie pas d'événement, ADR-005 D3 ; le cœur éprouve l'abonnement) :
# exercice verrouillé (D-LIB5-002).
private def transmit(year : Int32) : Nil
  Marten::DB::Connection.default.open do |db|
    db.exec("INSERT INTO liberal_year (year, state, closed_at, transmitted_at, reference, transmitted_fingerprint, " \
            "frozen_fingerprint) VALUES ($1, 'locked', now(), now(), 'teledec:1', '', '')", year)
  end
end

# Date du jour du dossier : celle du figement, présentée dans son fuseau.
private def today_text : String
  Partiduo::Api::Core.today.to_s("%d/%m/%Y")
end

describe "Profession libérale — livre-journal modifiable tant que l'exercice est ouvert (D-LIB2-001)" do
  it "montre l'exercice en tête : ouvert (modifier, supprimer), clôturé (cadenas, contre-passer)" do
    browser = open_books
    old = open_expense("2025-11-10", "900", "Loyer 2025")
    current = open_expense("2026-02-10", "950", "Loyer 2026")
    close_2025

    page = browser.get("/liberal/expenses?year=2026").html
    page.should contain("pd-simple")
    page.should contain(%(<th scope="rowgroup" colspan="7">))
    page.should contain("Exercice 2026")
    page.should contain("ouvert, modifiable")
    page.should contain(%(href="/liberal/lines/#{current.id}/edit" aria-label="Modifier #{current.number}"))
    page.should contain(%(action="/liberal/lines/#{current.id}/delete"))
    page.should contain(%(aria-label="Supprimer #{current.number}"))
    page.should contain("data-pd-confirm=\"Supprimer cette ligne ?")
    page.should contain("pd-row-button")
    page.should_not contain("missing translation")

    closed = browser.get("/liberal/expenses?year=2025").html
    closed.should contain("Exercice 2025")
    closed.should contain("clôturé le #{today_text}")
    closed.should contain("Exercice figé, ligne intangible :")
    closed.should contain(%(aria-label="Contre-passer #{old.number}"))
    closed.should_not contain(%(href="/liberal/lines/#{old.id}/edit"))
    closed.should_not contain(%(action="/liberal/lines/#{old.id}/delete"))

    # Mode complet : le livre-journal a les mêmes en-têtes et actions.
    full = browser.get("/liberal/journal?year=2026").html
    full.should contain(%(<th scope="rowgroup" colspan="8">))
    full.should contain(%(aria-label="Modifier #{current.number}"))
  end

  it "modifie une ligne de l'exercice ouvert par le formulaire prérempli, refuse une date d'un exercice figé" do
    browser = open_books
    line = open_expense("2026-02-10", "950")
    form = browser.get("/liberal/lines/#{line.id}/edit")
    form.status.should eq(200)
    html = form.html
    html.should contain("Modifier : Dépense #{line.number}")
    html.should contain(%(value="950,00"))
    html.should contain(%(value="2026-02-10"))
    html.should contain(%(action="/liberal/lines/#{line.id}/edit"))
    html.should contain("la 2035 de l'année est recalculée")
    html.should_not contain("Enregistrer et en saisir une autre")
    html.should_not contain("missing translation")

    refused = browser.post("/liberal/lines/#{line.id}/edit", {"amount" => "", "date" => "2026-02-10",
                                                              "nature_id" => open_nature("RENT").id.to_s, "method" => "cash"})
    refused.status.should eq(422)
    refused.html.should contain("Ce champ est obligatoire.")

    saved = browser.post("/liberal/lines/#{line.id}/edit", {"amount" => "980,50", "date" => "2026-02-11",
                                                            "nature_id" => open_nature("OFFICE").id.to_s, "method" => "cash",
                                                            "party_name" => "Papeterie"})
    saved.status.should eq(302)
    saved.headers["Location"].should eq("/liberal/lines/#{line.id}")
    shown = browser.follow(saved).html
    shown.should contain("Ligne #{line.number} modifiée.")
    shown.should contain("Modifiée le")
    changed = Liberal.line(Books.system, line.id)
    {changed.amount, changed.date, changed.heading, changed.method}.should eq({Books.d("980.5"), Books.date("2026-02-11"), "office", "cash"})

    # Nouvelle date dans l'exercice 2025, clôturé : refus du contrat, à l'écran.
    close_2025
    moved = browser.post("/liberal/lines/#{line.id}/edit", {"amount" => "980,50", "date" => "2025-12-30",
                                                            "nature_id" => open_nature("OFFICE").id.to_s, "method" => "cash"})
    moved.status.should eq(422)
    moved.html.should contain("période de cette date est close")
  end

  it "supprime une ligne de l'exercice ouvert, refuse celle d'un exercice figé et la contre-passe dans l'exercice ouvert" do
    browser = open_books
    old = open_expense("2025-11-10", "900")
    line = open_expense("2026-02-10", "950")
    transmit(2025)
    deleted = browser.post("/liberal/lines/#{line.id}/delete")
    deleted.status.should eq(302)
    deleted.headers["Location"].should eq("/liberal/expenses?year=2026")
    browser.follow(deleted).html.should contain("Ligne #{line.number} supprimée.")

    detail = browser.get("/liberal/lines/#{old.id}").html
    detail.should contain("2035 de 2025 transmise le #{today_text}")
    refused = browser.post("/liberal/lines/#{old.id}/delete")
    refused.headers["Location"].should eq("/liberal/lines/#{old.id}")
    browser.follow(refused).html.should contain("La 2035 de 2025 est transmise")
    edit = browser.get("/liberal/lines/#{old.id}/edit")
    edit.headers["Location"].should eq("/liberal/lines/#{old.id}")
    browser.get("/liberal/expenses?year=2025").html.should contain("2035 transmise le #{today_text}")

    browser.post("/liberal/lines/#{old.id}/reverse").status.should eq(302)
    reversal = Liberal.line(Books.system, Liberal.line(Books.system, old.id).reversed_by_id || raise "ligne non contre-passée")
    reversal.date.should eq(Partiduo::Api::Core.today)
    reversal.locked.should be_false
    reversal.deletable?.should be_true
  end

  it "présente l'état de l'exercice en tête de la 2035 : ouvert, clôturé, transmise" do
    browser = open_books
    open_expense("2025-11-10", "900")
    open_expense("2026-02-10", "950")
    page = browser.get("/liberal/tax-return?year=2026").html
    page.should contain("Exercice 2026 ouvert : la 2035 est recalculée")
    page.should contain(%(action="/liberal/tax-return/adjustments?year=2026"))
    close_2025
    closed = browser.get("/liberal/tax-return?year=2025").html
    closed.should contain("Exercice 2025 clôturé le #{today_text} avec l'exercice du dossier : la 2035 est figée")
    closed.should_not contain(%(action="/liberal/tax-return/adjustments?year=2025"))
    transmit(2026)
    sent = browser.get("/liberal/tax-return?year=2026").html
    sent.should contain("2035 de 2026 transmise le #{today_text} — exercice verrouillé")
    sent.should_not contain("Déclaration prête à être déposée")
    sent.should_not contain("missing translation")
  end
end

describe "Profession libérale — immobilisations modifiables tant que l'exercice est ouvert (D-LIB2-004)" do
  it "groupe le registre par exercice, modifie, supprime la cession puis l'immobilisation" do
    browser = open_books
    old = open_asset("2025-05-02")
    item = open_asset("2026-04-01")
    close_2025
    list = browser.get("/liberal/assets").html
    list.should contain("Exercice 2026")
    list.should contain("Exercice 2025")
    list.should contain(%(href="/liberal/assets/#{item.id}/edit" aria-label="Modifier #{item.number}"))
    list.should_not contain(%(href="/liberal/assets/#{old.id}/edit"))
    list.should contain("Immobilisation intangible :")

    form = browser.get("/liberal/assets/#{item.id}/edit").html
    form.should contain("Modifier l'immobilisation #{item.number}")
    form.should contain(%(value="3000,00"))
    saved = browser.post("/liberal/assets/#{item.id}/edit", {"label" => "Table électrique", "category" => "equipment",
                                                             "acquired_on" => "2026-04-02", "amount" => "3200",
                                                             "duration_years" => "4", "method" => "transfer"})
    saved.status.should eq(302)
    Liberal.asset(Books.system, item.id).amount.should eq(Books.d("3200"))

    Liberal.dispose_asset(Books.system, Liberal::DisposalInput.new(item.id, Books.date("2026-08-01"), Books.d("100"), "cash")).value!
    detail = browser.get("/liberal/assets/#{item.id}").html
    detail.should contain(%(action="/liberal/assets/#{item.id}/disposal/delete"))
    detail.should_not contain(%(href="/liberal/assets/#{item.id}/edit"))
    browser.post("/liberal/assets/#{item.id}/disposal/delete").status.should eq(302)
    Liberal.asset(Books.system, item.id).disposal.should be_nil
    deleted = browser.post("/liberal/assets/#{item.id}/delete")
    deleted.headers["Location"].should eq("/liberal/assets")
    browser.follow(deleted).html.should contain("Immobilisation #{item.number} supprimée.")

    refused = browser.post("/liberal/assets/#{old.id}/delete")
    refused.headers["Location"].should eq("/liberal/assets/#{old.id}")
    Liberal.assets(Books.system).map(&.id).should eq([old.id])
  end
end

describe "Profession libérale — droits et langues des modifications (D-LIB2-006)" do
  it "ne propose rien au lecteur et lui refuse modification et suppression" do
    open_books
    line = open_expense("2026-02-10", "950")
    item = open_asset
    profile = PartiduoUi::Accounts.profile("Lecture", ["liberal.register.read"])
    PartiduoUi::Accounts.create("lecture@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("lecture@example.com")
    page = reader.get("/liberal/expenses?year=2026").html
    page.should_not contain("/edit")
    page.should_not contain("/delete")
    reader.get("/liberal/lines/#{line.id}/edit").status.should eq(403)
    reader.post("/liberal/lines/#{line.id}/edit", {"amount" => "1"}).status.should eq(403)
    reader.post("/liberal/lines/#{line.id}/delete").status.should eq(403)
    reader.get("/liberal/assets/#{item.id}/edit").status.should eq(403)
    reader.post("/liberal/assets/#{item.id}/delete").status.should eq(403)
    reader.post("/liberal/assets/#{item.id}/disposal/delete").status.should eq(403)
    Liberal.line(Books.system, line.id).amount.should eq(Books.d("950"))
  end

  it "traduit exercices et actions en anglais et en néerlandais" do
    browser = open_books
    open_expense("2025-11-10", "900")
    open_expense("2026-02-10", "950")
    close_2025
    {"en" => {"Year 2025", "closed on", "Reverse", "Year 2026", "open, editable", "Edit"},
     "nl" => {"Boekjaar 2025", "afgesloten op", "Tegenboeken", "Boekjaar 2026", "open, wijzigbaar", "Wijzigen"}}.each do |locale, words|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      page = browser.get("/liberal/expenses?year=2025").html + browser.get("/liberal/expenses?year=2026").html
      words.each { |word| page.should contain(word) }
      page.should_not contain("missing translation")
    end
  end
end
