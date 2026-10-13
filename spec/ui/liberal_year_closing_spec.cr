# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# D-LIB5-001, D-LIB5-005 : le professionnel clôture son exercice depuis le
# livre-journal (mode complet), les recettes et dépenses (mode simplifié) ou
# la 2035, et le rouvre tant que la 2035 n'est pas transmise ; transmise,
# l'exercice est verrouillé : plus de « Rouvrir l'exercice ». En-tête d'état
# (« ouvert », « clôturé le … », « 2035 transmise le … — verrouillé »),
# cadenas, confirmation, nom accessible avec l'année, historique ; fr, en,
# nl. Tout par `Partiduo::Api`.

private alias Liberal = Partiduo::Api::Liberal
private alias Books = PartiduoUi::Books

private def year_books : PartiduoUi::Browser
  browser = Books.admin
  Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
  Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
  Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
  Liberal.load_defaults(Books.system)
  PartiduoUi::Reference.fiscal_year(2025)
  browser
end

private def year_expense(day : String, amount : String) : Liberal::LineView
  nature = Liberal.natures(Books.system).find! { |item| item.code == "RENT" }
  input = Liberal::LineInput.new(date: Books.date(day), nature_id: nature.id, amount: Books.d(amount),
    method: "transfer", party_name: "SCI du Parc")
  Liberal.record_expense(Books.system, input).value!
end

# Transmission notée par le module à `tax_return.transmitted` (publié par
# l'extension qui dépose la 2035 ; l'interface ne publie pas d'événement,
# ADR-005 D3, le cœur éprouve l'abonnement) : exercice clôturé verrouillé.
private def year_transmit(year : Int32) : Nil
  Marten::DB::Connection.default.open do |db|
    db.exec("UPDATE liberal_year SET state = 'locked', transmitted_at = now(), reference = 'teledec:9' WHERE year = $1", year)
    db.exec("INSERT INTO liberal_year_change (year, action, at, reference) VALUES ($1, 'locked', now(), 'teledec:9')", year)
  end
end

# Date du jour du dossier : celle du figement, présentée dans son fuseau.
private def today_text : String
  Partiduo::Api::Core.today.to_s("%d/%m/%Y")
end

describe "Profession libérale — clôturer et rouvrir l'exercice (D-LIB5-001)" do
  it "clôture l'exercice depuis les dépenses, le rouvre et le clôture de nouveau" do
    browser = year_books
    line = year_expense("2025-11-10", "900")
    page = browser.get("/liberal/expenses?year=2025").html
    page.should contain("pd-simple")
    page.should contain("ouvert, modifiable")
    page.should contain(%(action="/liberal/years/2025/close?next=%2Fliberal%2Fexpenses%3Fyear%3D2025"))
    page.should contain(%(data-pd-confirm="Clôturer l'exercice 2025 ?))
    page.should contain(%(aria-label="Clôturer l'exercice 2025"))
    page.should_not contain("/liberal/years/2025/reopen")

    closed = browser.post("/liberal/years/2025/close?next=%2Fliberal%2Fexpenses%3Fyear%3D2025")
    closed.status.should eq(302)
    closed.headers["Location"].should eq("/liberal/expenses?year=2025")
    after = browser.follow(closed).html
    after.should contain("Exercice 2025 clôturé : ses lignes sont figées.")
    after.should contain("clôturé le #{today_text}")
    after.should contain("sprite.svg#lock")
    after.should contain(%(aria-label="Rouvrir l'exercice 2025"))
    after.should contain(%(data-pd-confirm="Rouvrir l'exercice 2025 ?))
    after.should_not contain(%(href="/liberal/lines/#{line.id}/edit"))
    Liberal.year(Books.system, 2025).closed?.should be_true
    # Modifier une ligne d'un exercice clôturé : refus, avec la raison.
    refused = browser.get("/liberal/lines/#{line.id}/edit")
    refused.status.should eq(302)
    browser.follow(refused).html.should contain("L'exercice 2025 est clôturé : le rouvrir pour modifier la ligne")

    reopened = browser.post("/liberal/years/2025/reopen?next=%2Fliberal%2Fexpenses%3Fyear%3D2025")
    browser.follow(reopened).html.should contain("Exercice 2025 rouvert : ses lignes se modifient de nouveau.")
    Liberal.year(Books.system, 2025).open?.should be_true
    browser.get("/liberal/expenses?year=2025").html.should contain(%(href="/liberal/lines/#{line.id}/edit"))

    browser.post("/liberal/years/2025/close").headers["Location"].should eq("/liberal/tax-return?year=2025")
    Liberal.year_history(Books.system, 2025).map(&.action).should eq(%w[closed reopened closed])
  end

  it "clôture depuis la 2035 et le livre-journal complet, montre l'état, l'auteur et l'historique" do
    browser = year_books
    year_expense("2025-11-10", "900")
    tax = browser.get("/liberal/tax-return?year=2025").html
    tax.should contain("Clôturez l'exercice avant de transmettre la 2035.")
    tax.should contain(%(action="/liberal/years/2025/close?next=%2Fliberal%2Ftax-return%3Fyear%3D2025"))
    browser.post("/liberal/years/2025/close?next=%2Fliberal%2Ftax-return%3Fyear%3D2025").status.should eq(302)
    closed = browser.get("/liberal/tax-return?year=2025").html
    closed.should contain("Exercice 2025 clôturé le #{today_text} par ")
    closed.should contain("Clôtures et réouvertures")
    closed.should contain("Clôture de l'exercice")
    closed.should contain(%(action="/liberal/years/2025/reopen?))
    closed.should_not contain(%(action="/liberal/tax-return/adjustments?year=2025"))
    full = browser.get("/liberal/journal?year=2025").html
    full.should contain(%(aria-label="Rouvrir l'exercice 2025"))
    # Deux exercices indépendants : 2026 reste ouvert.
    browser.get("/liberal/journal?year=2026").html.should contain(%(aria-label="Clôturer l'exercice 2026"))
  end

  it "verrouille l'exercice dont la 2035 est transmise : plus de « Rouvrir », réouverture refusée" do
    browser = year_books
    year_expense("2025-11-10", "900")
    Liberal.close_year(Books.system, 2025).value!
    year_transmit(2025)
    page = browser.get("/liberal/expenses?year=2025").html
    page.should contain("2035 transmise le #{today_text} — verrouillé")
    page.should contain("sprite.svg#lock")
    page.should_not contain("/liberal/years/2025/reopen")
    page.should_not contain("/liberal/years/2025/close")
    tax = browser.get("/liberal/tax-return?year=2025").html
    tax.should contain("2035 de 2025 transmise le #{today_text} — exercice verrouillé")
    tax.should contain("2035 transmise : exercice verrouillé")
    tax.should_not contain("/liberal/years/2025/reopen")
    forced = browser.post("/liberal/years/2025/reopen?next=%2Fliberal%2Fexpenses%3Fyear%3D2025")
    browser.follow(forced).html.should contain("La 2035 de 2025 est transmise : l'exercice est verrouillé et ne se rouvre plus")
    Liberal.year(Books.system, 2025).locked?.should be_true
  end

  it "ne propose ni clôture ni réouverture au lecteur et les lui refuse" do
    year_books
    profile = PartiduoUi::Accounts.profile("Lecture", ["liberal.register.read"])
    PartiduoUi::Accounts.create("lecture@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("lecture@example.com")
    reader.get("/liberal/expenses?year=2025").html.should_not contain("/liberal/years/")
    reader.get("/liberal/tax-return?year=2025").html.should_not contain("/liberal/years/")
    reader.post("/liberal/years/2025/close").status.should eq(403)
    Liberal.year(Books.system, 2025).open?.should be_true
  end

  it "traduit clôture, réouverture et verrou en anglais et en néerlandais" do
    browser = year_books
    year_expense("2025-11-10", "900")
    Liberal.close_year(Books.system, 2025).value!
    year_transmit(2025)
    {"en" => {"Close the year", "2035 filed on", "— locked", "Closings and reopenings"},
     "nl" => {"Boekjaar afsluiten", "2035 ingediend op", "— vergrendeld", "Afsluitingen en heropeningen"}}.each do |locale, words|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      page = browser.get("/liberal/expenses?year=2026").html + browser.get("/liberal/expenses?year=2025").html +
             browser.get("/liberal/tax-return?year=2025").html
      words.each { |word| page.should contain(word) }
      page.should_not contain("missing translation")
    end
  end
end
