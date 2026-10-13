# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot 6 — prévisions budgétaires (Comptabilité) : prévision, catégories,
# éléments (montants propres à une période), copie, estimé et réel.

private alias Acc = Partiduo::Api::Accounting
private alias Books = PartiduoUi::Books

private def months : Array(Partiduo::Api::Core::PeriodView)
  Partiduo::Api::Core.periods(Books.system).select { |period| period.starts_on.year == 2026 && period.starts_on != period.ends_on }
end

describe "Prévisions budgétaires (lot 6)" do
  it "crée une prévision, une catégorie et un élément par les formulaires ; compare l'estimé et le réel" do
    browser = Books.admin
    january, february, march = months[0], months[1], months[2]
    browser.get("/accounting/forecasts").html.should contain("Aucune prévision.")
    browser.get("/accounting/forecasts/new").html.should contain(%(name="start_period_id"))

    refused = browser.post("/accounting/forecasts/new", {"name" => "", "start_period_id" => march.id.to_s,
                                                         "end_period_id" => january.id.to_s})
    refused.status.should eq(422)
    refused.html.should contain("Indiquez le nom de la prévision.")

    created = browser.post("/accounting/forecasts/new", {"name" => "Budget T1", "start_period_id" => january.id.to_s,
                                                         "end_period_id" => march.id.to_s})
    created.status.should eq(302)
    forecast = Acc.forecasts(Books.system).first
    created.headers["Location"].should eq("/accounting/forecasts/#{forecast.id}")
    browser.get("/accounting/forecasts/#{forecast.id}").html.should contain("pas encore de catégorie")

    browser.post("/accounting/forecasts/#{forecast.id}/categories/new", {"label" => "Ventes", "position" => "10"}).status.should eq(302)
    category = Acc.forecast(Books.system, forecast.id).categories.first
    category.label.should eq("Ventes")

    item_form = browser.get("/accounting/forecasts/#{forecast.id}/categories/#{category.id}/items/new").html
    item_form.should contain(%(name="period-#{february.id}"))
    bad = browser.post("/accounting/forecasts/#{forecast.id}/categories/#{category.id}/items/new",
      {"label" => "", "formula" => "", "amount" => "1000"})
    bad.status.should eq(422)
    Acc.forecast(Books.system, forecast.id).categories.first.items.should be_empty
    # Formule vide admise (réel nul, D-FCT-003) : le champ n'est pas requis.
    item_form.should_not match(/<input[^>]*name="formula"[^>]*required/)

    browser.post("/accounting/forecasts/#{forecast.id}/categories/#{category.id}/items/new", {
      "label" => "Chiffre d'affaires", "formula" => "[706]", "amount" => "1000", "initial_amount" => "",
      "position" => "10", "period-#{february.id}" => "1500,50",
    }).status.should eq(302)
    item = Acc.forecast(Books.system, forecast.id).categories.first.items.first
    item.amount.should eq(Books.d("1000"))
    item.period_amounts.map { |row| {row.period_id, row.amount} }.should eq([{february.id, Books.d("1500.50")}])
    # Nature laissée « Selon la formule » : recette (classe 7).
    item_form.should contain(%(<option value="" selected>Selon la formule</option>))
    item.nature.should eq("income")

    detail = browser.get("/accounting/forecasts/#{forecast.id}").html
    detail.should contain("Chiffre d")
    detail.should contain("Recette")

    # Nature réglable : l'élément devient une dépense ; la modifier sans nature la garde.
    edit_url = "/accounting/forecasts/#{forecast.id}/items/#{item.id}/edit"
    browser.get(edit_url).html.should contain(%(<option value="income" selected>Recette</option>))
    values = {"label" => "Chiffre d'affaires", "formula" => "[706]", "amount" => "1000", "position" => "10",
              "period-#{february.id}" => "1500,50"}
    browser.post(edit_url, values.merge({"nature" => "expense"})).status.should eq(302)
    Acc.forecast(Books.system, forecast.id).categories.first.items.first.nature.should eq("expense")
    browser.post(edit_url, values.merge({"nature" => "dividende"})).status.should eq(422)
    browser.post(edit_url, values.merge({"nature" => ""})).status.should eq(302)
    Acc.forecast(Books.system, forecast.id).categories.first.items.first.nature.should eq("expense")
    browser.post(edit_url, values.merge({"nature" => "income"})).status.should eq(302)
    detail.should contain(%(href="/accounting/forecasts/#{forecast.id}/items/#{item.id}/edit"))

    Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    Books.sale("CLI-MOREL", "800", "2026-03-10")
    report = browser.get("/accounting/forecasts/#{forecast.id}/report")
    report.status.should eq(200)
    html = report.html
    html.should contain("Estimé")
    html.should contain("Réel")
    html.should contain("Écart")
    html.should match(/1.500,50/)
    html.should contain("-200,00")
    csv = browser.get("/accounting/forecasts/#{forecast.id}/report?format=csv")
    csv.content_type.should start_with("text/csv")
    csv.content.should contain("Chiffre d'affaires")

    browser.post("/accounting/forecasts/#{forecast.id}/clone", {"name" => "Budget T1 bis"}).status.should eq(302)
    copy = Acc.forecasts(Books.system).find! { |row| row.name == "Budget T1 bis" }
    Acc.forecast(Books.system, copy.id).categories.first.items.size.should eq(1)

    browser.post("/accounting/forecasts/#{forecast.id}/items/#{item.id}/delete").status.should eq(302)
    browser.post("/accounting/forecasts/#{forecast.id}/categories/#{category.id}/delete").status.should eq(302)
    Acc.forecast(Books.system, forecast.id).categories.should be_empty
    browser.post("/accounting/forecasts/#{forecast.id}/delete").status.should eq(302)
    Acc.forecasts(Books.system).map(&.name).should eq(["Budget T1 bis"])
  end

  it "refuse une catégorie d'une autre prévision (404)" do
    browser = Books.admin
    january = months[0]
    first = Acc.create_forecast(Books.system, Acc::ForecastInput.new("A", january.id, january.id)).value!
    second = Acc.create_forecast(Books.system, Acc::ForecastInput.new("B", january.id, january.id)).value!
    category = Acc.create_forecast_category(Books.system, first.id, Acc::ForecastCategoryInput.new("Charges")).value!
    browser.get("/accounting/forecasts/#{second.id}/categories/#{category.id}/edit").status.should eq(404)
    browser.get("/accounting/forecasts/#{first.id}/categories/#{category.id}/edit").status.should eq(200)
  end
end
