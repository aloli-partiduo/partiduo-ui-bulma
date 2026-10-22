# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Dossier foyer (ADR-011 A3) : sans extension, l'interface écarte les menus
# d'entreprise (achats, ventes, factures reçues, Facturation à
# comptabiliser, TVA, FEC, clôture), présente un tableau de bord du foyer
# (trésorerie par compte, dépenses et recettes du mois, écart au budget) et
# dit « Membre du foyer ». Une variante d'extension s'y ajoute sans conflit.
# Les dossiers d'entreprise ne changent pas.

private alias Books = PartiduoUi::Books
private alias Acc = Partiduo::Api::Accounting

# Modules d'entreprise exclus d'un foyer, dépendants d'abord.
private EXCLUDED = %w[ANALYTIC STOCK FOLLOWUP MICRO LIBERAL INVOICING]

private def household_books : PartiduoUi::Browser
  EXCLUDED.each { |code| Partiduo::Api::Modules.deactivate(Books.system, code) }
  PartiduoUi::Reference.provision(kind: Partiduo::Api::InitialData::HOUSEHOLD)
  PartiduoUi::Reference.fiscal_year(2026)
  PartiduoUi::Accounts.create
  PartiduoUi::Accounts.signed_in
end

# Opérations de mars 2026 sur le compte courant : salaire, courses, retrait
# d'espèces.
private def march_operations : Nil
  lines = [
    Acc::PaymentLineInput.new(Books.d("3000"), account: "701", label: "Salaire"),
    Acc::PaymentLineInput.new(Books.d("-450"), account: "62", label: "Courses"),
    Acc::PaymentLineInput.new(Books.d("-200"), account: "53", label: "Retrait"),
  ]
  input = Acc::FinancialInput.new(ledger_id: Books.ledger("F01").id, date: Books.date("2026-03-10"), lines: lines)
  Acc.post_financial(Books.system, input).value!
end

# Budget 2026 : alimentation 400 et salaires 3 000 par mois ; un retrait
# d'espèces de 150 déclaré recette (nature réglée, contrat 0.10.0) : le
# tableau de bord ne le compte pas en dépense, quoique sa formule ne
# désigne pas la classe 7.
private def budget : Nil
  periods = Partiduo::Api::Core.fiscal_years(Books.system).find! { |year| year.year == 2026 }.periods
  forecast = Acc.create_forecast(Books.system, Acc::ForecastInput.new("Budget 2026", periods.first.id, periods.last.id)).value!
  category = Acc.create_forecast_category(Books.system, forecast.id, Acc::ForecastCategoryInput.new("Vie courante")).value!
  Acc.create_forecast_item(Books.system, category.id, Acc::ForecastItemInput.new("Alimentation", "[62]", Books.d("400"))).value!
  Acc.create_forecast_item(Books.system, category.id, Acc::ForecastItemInput.new("Salaires", "[701]", Books.d("3000"))).value!
  Acc.create_forecast_item(Books.system, category.id, Acc::ForecastItemInput.new("Espèces", "[53]", Books.d("150"),
    nature: Acc::FORECAST_INCOME)).value!
end

private def side_menu(html : String) : String
  html.match(/<nav class="pd-side menu".*?<\/nav>/m).try(&.[0]) || fail "menu latéral absent"
end

private def href(route : String) : String
  %(href="#{Marten.routes.reverse(route)}")
end

private def active_codes : Set(String)
  Partiduo::Api::Modules.list(Books.system).select(&.active).map(&.code).to_set
end

# Routes des menus d'entreprise qu'un foyer ne présente pas.
private BUSINESS_ROUTES = %w[accounting:entry_purchase accounting:entry_received accounting:entry_sale
  accounting:invoicing_history accounting:vat_return accounting:vat_returns accounting:vat_settings
  accounting:fec accounting:closing vat:rates accounting:auxiliary_balance accounting:aged_balance]

# Libellé d'une entrée du menu latéral, d'après sa route.
private def menu_label(menu : String, route : String) : String
  menu.match(/#{Regex.escape(href(route))}[^>]*><span>([^<]+)<\/span>/).try(&.[1]) || fail "entrée #{route} absente"
end

describe "Dossier foyer (ADR-011 A3)" do
  it "écarte du menu les achats, les ventes, les factures reçues, la TVA, le FEC et la clôture" do
    browser = household_books
    PartiduoUi::FolderKind.of(Books.system).should eq("household")
    menu = side_menu(browser.get("/").html)
    BUSINESS_ROUTES.each { |route| menu.should_not contain(href(route)) }
    menu.should contain(href("accounting:entry_financial"))
    menu.should contain(href("accounting:entries"))
    menu.should contain(href("accounting:forecasts"))
    menu.should contain(href("accounting:trial_balance"))
    # Présentation seulement : la route reste joignable.
    browser.get(Marten.routes.reverse("accounting:fec")).status.should eq(200)
    browser.get(Marten.routes.reverse("accounting:aged_balance")).status.should eq(200)
  end

  it "dit « Contacts » et « Foyer » dans le menu, le titre et le fil d'Ariane, en fr, en et nl" do
    browser = household_books
    {"fr" => {"Contacts", "Foyer", "Modifier le foyer", "Foyer enregistré."},
     "en" => {"Contacts", "Household", "Edit household", "Household saved."},
     "nl" => {"Contacten", "Huishouden", "Huishouden wijzigen", "Huishouden opgeslagen."}}.each do |locale, (cards, company, edit, saved)|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      I18n.with_locale(locale) do
        menu = side_menu(browser.get("/").html)
        menu_label(menu, "cards:index").should eq(cards)
        menu_label(menu, "core:company").should eq(company)
        {I18n.t("cards.menu.cards_list"), I18n.t("core.menu.core_company")}.each { |label| menu.should_not contain(">#{label}<") }
        detail = browser.get(Marten.routes.reverse("core:company")).html
        detail.should contain(%(<a href="#{Marten.routes.reverse("core:company")}">#{company}</a>))
        detail.should contain(I18n.t("ui.household.company.intro"))
        form = browser.get(Marten.routes.reverse("core:company_edit")).html
        form.should contain(edit)
        form.should_not contain(I18n.t("ui.company.edit"))
        list = browser.get(Marten.routes.reverse("cards:index")).html
        list.should contain(cards)
        I18n.t(PartiduoUi::FolderKind.label_key("household", "ui.company.updated")).should eq(saved)
      end
    end
  end

  it "présente les tuiles et le bouton du foyer, sans tuile d'entreprise" do
    browser = household_books
    page = browser.get("/").html
    ["Clients à encaisser", "Fournisseurs à payer", "TVA due", "Nouvelle écriture d'achat"].each do |text|
      page.should_not contain(text)
    end
    page.should contain("Trésorerie")
    page.should contain("Dépenses ·")
    page.should contain("Recettes ·")
    page.should contain(%(<a class="button pd-touch is-primary" href="#{Marten.routes.reverse("accounting:entry_financial")}">))
    page.should contain("Nouvelle opération")
    page.should_not contain("missing translation")
  end

  it "calcule la trésorerie par compte, les dépenses et recettes du mois et l'écart au budget" do
    household_books
    march_operations
    budget
    fmt = PartiduoUi::Format.new("fr", "FR")
    board = PartiduoUi::Dashboard.new(Books.system, fmt, active_codes, Books.date("2026-03-20")).build_household
    tiles = board.tiles.to_h { |tile| {tile.label, tile} }

    cash = tiles["Trésorerie"]
    cash.value.should eq(fmt.amount(Books.d("2550")))
    cash.sub.should eq("Compte courant : #{fmt.amount(Books.d("2350"))} · Espèces : #{fmt.amount(Books.d("200"))}")

    month = fmt.month(Books.date("2026-03-20"))
    expenses = tiles["Dépenses · #{month}"]
    expenses.value.should eq(fmt.amount(Books.d("450")))
    expenses.sub.should eq("Premier poste : Alimentation")
    income = tiles["Recettes · #{month}"]
    income.value.should eq(fmt.amount(Books.d("3000")))
    income.sub.should eq("Reste après dépenses : +#{fmt.amount(Books.d("2550"))}")

    # Seule l'alimentation compte (le salaire, classe 7, et les espèces, réglées
    # en recette, n'en sont pas) : 450 pour 400.
    gap = tiles["Écart au budget · #{month}"]
    gap.value.should eq("+#{fmt.amount(Books.d("50"))}")
    gap.sub.should eq("Dépensé #{fmt.amount(Books.d("450"))} pour #{fmt.amount(Books.d("400"))} prévus (Budget 2026)")
    gap.alert.should eq("1 poste dépassé")

    board.new_entry_url.should eq(Marten.routes.reverse("accounting:entry_financial"))
    board.new_entry_label.should eq("ui.dashboard.household.new_operation")
    tiles.keys.none?(&.includes?("Clients")).should be_true
  end

  it "omet l'écart au budget sans prévision qui couvre le jour" do
    household_books
    fmt = PartiduoUi::Format.new("fr", "FR")
    board = PartiduoUi::Dashboard.new(Books.system, fmt, active_codes, Books.date("2026-03-20")).build_household
    board.tiles.map(&.label).none?(&.starts_with?("Écart au budget")).should be_true
  end

  it "dit « Membre du foyer » dans la barre et la liste des utilisateurs" do
    browser = household_books
    browser.get("/").html.should contain("Membre du foyer")
    users = browser.get(Marten.routes.reverse("core:users")).html
    users.should contain("Membre du foyer")
    users.should_not contain("Utilisateur de la société")
    PartiduoUi::FolderKind.role_key("household", "accountant").should eq("auth.roles.accountant")
  end

  it "unit les menus écartés du foyer à ceux d'une variante d'extension, dont les tuiles l'emportent" do
    browser = household_books
    Partiduo::Api::Modules.activate(Books.system, "UITEST").success?.should be_true
    tiles = ->(_actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) do
      [PartiduoUi::Dashboard::Tile.new("UITEST", "Patrimoine du foyer", fmt.amount(BigDecimal.new("98765.4")))]
    end
    menu = [
      PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "core.menu.dashboard"),
      PartiduoUi::SimpleMode::Entry.new("UITEST_HOME", "uitest.menu.uitest_home"),
    ]
    PartiduoUi::Extensions.simple_mode("UITEST", read: "uitest.page.view", menu: menu,
      hidden_menus: %w[ACC_MATCHING], tiles: tiles)
    begin
      simple = browser.get("/").html
      simple.should contain("Patrimoine du foyer")
      simple.should_not contain("Dépenses ·")
      browser.post("/account/preferences", {"interface" => "full"}).status.should eq(302)
      page = browser.get("/").html
      page.should contain("Dépenses ·")
      full = side_menu(page)
      BUSINESS_ROUTES.each { |route| full.should_not contain(href(route)) }
      full.should_not contain(href("accounting:matching"))
      full.should contain(href("accounting:entry_financial"))
    ensure
      PartiduoUi::SimpleMode.unregister("UITEST")
    end
  end
end

describe "Dossier foyer : écran « Foyer », contacts, comptes (D-FOY-009)" do
  it "dit « Comptes et contacts » au menu, au titre et à l'écran, en fr, en et nl" do
    browser = household_books
    {"fr" => {"Comptes et contacts", "Compte ou contact"},
     "en" => {"Accounts and contacts", "Account or contact"},
     "nl" => {"Rekeningen en contacten", "Rekening of contact"}}.each do |locale, (entry, pick)|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      I18n.with_locale(locale) do
        menu = side_menu(browser.get("/").html)
        menu_label(menu, "accounting:accounts").should eq(entry)
        page = browser.get(Marten.routes.reverse("accounting:accounts")).html
        page.should contain("<h1>#{entry}")
        page.should contain(pick)
        page.should_not contain(I18n.t("accounting.menu.acc_accounts"))
        page.should_not contain(I18n.t("ui.accounts.pick"))
        page.should_not contain("missing translation")
      end
    end
  end

  it "présente les contacts sans onglet d'articles, avec « Nouveau contact »" do
    browser = household_books
    page = browser.get(Marten.routes.reverse("cards:index")).html
    page.should contain("<h1>Contacts")
    page.should contain("Nouveau contact")
    page.should_not contain("Articles et services")
    page.should_not contain(%(class="pd-tabs"))
    page.should_not contain("Nouveau tiers")
    page.should_not contain("Numéro de TVA")
    page.should contain(%(placeholder="Nom, code, description…"))
    form = browser.get("#{Marten.routes.reverse("cards:new")}?for=parties").html
    form.should contain("Nouveau contact")
  end

  it "dit le type et les catégories des contacts dans le vocabulaire du foyer, en fr, en et nl" do
    browser = household_books
    {"fr" => {"Tous les types", "Type de contact", "Payeurs", "Prestataires et commerçants", "Employés à domicile",
              "Catégories de contacts", "Payeur"},
     "en" => {"All types", "Contact type", "Payers", "Providers and shops", "Household employees",
              "Contact categories", "Payer"},
     "nl" => {"Alle soorten contacten", "Soort contact", "Betalers", "Dienstverleners en winkels", "Huispersoneel",
              "Contactcategorieën", "Betaler"}}.each do |locale, (all_kinds, kind, customers, suppliers, employees, categories, payer)|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      I18n.with_locale(locale) do
        page = browser.get(Marten.routes.reverse("cards:index")).html
        page.should contain(">#{all_kinds}</option>")
        page.should contain(kind)
        page.should contain(">#{customers}</option>")
        page.should contain(">#{suppliers}</option>")
        page.should contain(">#{employees}</option>")
        page.should_not contain(">#{I18n.t("ui.cards.all_kinds")}</option>")
        page.should_not contain(">#{I18n.t("cards.initial.categories.customer")}</option>")
        listing = browser.get(Marten.routes.reverse("cards:categories")).html
        listing.should contain("<h1>#{categories}")
        listing.should contain(customers)
        listing.should contain(payer)
        listing.should_not contain(I18n.t("cards.initial.categories.sale"))
        listing.should_not contain("missing translation")
        form = browser.get("#{Marten.routes.reverse("cards:new")}?for=parties").html
        form.should contain("#{customers} (#{payer})")
      end
    end
  end

  it "garde le nom d'une catégorie renommée par l'utilisateur" do
    browser = household_books
    category = Partiduo::Api::Cards.categories(Books.system).find! { |item| item.code == "CUSTOMER" }
    Partiduo::Api::Cards.update_category(Books.system, category.id, Partiduo::Api::Cards::CategoryInput.new(
      code: "CUSTOMER", name: "Locataires", kind: "customer")).value!
    page = browser.get(Marten.routes.reverse("cards:index")).html
    page.should contain(">Locataires</option>")
    page.should_not contain(">Payeurs</option>")
  end

  it "montre et propose le nom et l'adresse du foyer, sans champ d'entreprise, et garde leurs valeurs" do
    browser = household_books
    settings = Partiduo::Api::Core.settings(Books.system)
    Partiduo::Api::Core.update_settings(Books.system, settings.to_input.copy_with(rcs: "RCS conservé")).value!
    detail = browser.get(Marten.routes.reverse("core:company")).html
    detail.should contain("Nom du foyer")
    detail.should contain("Identité du foyer")
    detail.should contain("Coordonnées")
    %w[legal_form share_capital rcs siren vat_number creditor_identifier].each do |name|
      detail.should_not contain(I18n.t("core.settings.fields.#{name}"))
    end
    detail.should_not contain("Raison sociale")
    form = browser.get(Marten.routes.reverse("core:company_edit")).html
    form.should contain(%(name="company_name"))
    form.should contain(%(name="street"))
    %w[legal_form share_capital rcs siren vat_number creditor_identifier].each do |name|
      form.should_not contain(%(name="#{name}"))
    end
    values = {"company_name" => "Foyer Durand", "street" => "rue des Pins", "street_number" => "3", "postcode" => "44000",
              "city" => "Nantes", "country_code" => "FR", "phone" => "", "email" => "", "default_locale" => "fr",
              "domain" => settings.domain, "auth_minimum_level" => settings.auth_minimum_level.to_s,
              "session_duration_minutes" => settings.session_duration_minutes.to_s, "approval_mode" => "single",
              "approval_reauth_minutes" => "5"}
    settings.auth_methods.each { |method| values["auth_method:#{method}"] = "1" }
    response = browser.post(Marten.routes.reverse("core:company_edit"), values)
    response.status.should eq(302)
    browser.follow(response).html.should contain("Foyer enregistré.")
    saved = Partiduo::Api::Core.settings(Books.system)
    saved.company_name.should eq("Foyer Durand")
    saved.street.should eq("rue des Pins")
    saved.rcs.should eq("RCS conservé")
  end

  it "réunit les paramètres de la variante à l'entrée « Foyer » : une entrée, deux onglets" do
    browser = household_books
    Partiduo::Api::Modules.activate(Books.system, "UITEST").success?.should be_true
    menu = [PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "core.menu.dashboard")]
    PartiduoUi::Extensions.simple_mode("UITEST", read: "uitest.page.view", menu: menu, settings_route: "uitest:index",
      settings_permission: "uitest.page.view", settings_label: "uitest.menu.uitest_home")
    begin
      # Interface simplifiée : le lien du menu de l'utilisateur mène à « Foyer ».
      simple = browser.get("/").html
      simple.should contain(%(<li><a href="#{Marten.routes.reverse("core:company")}">))
      simple.should_not contain(%(<li><a href="/ext/UITEST/">))

      browser.post("/account/preferences", {"interface" => "full"}).status.should eq(302)
      full = side_menu(browser.get("/").html)
      menu_label(full, "core:company").should eq("Foyer")
      full.should_not contain(%(href="/ext/UITEST/"))

      detail = browser.get(Marten.routes.reverse("core:company")).html
      tabs = detail.match(/<nav class="pd-tabs mb-3" aria-label="Foyer">.*?<\/nav>/m).try(&.[0]) || fail "onglets absents"
      tabs.should contain(%(<a href="#{Marten.routes.reverse("core:company")}" aria-current="page">Identité du foyer</a>))
      tabs.should contain(%(<a href="/ext/UITEST/">Page de test</a>))
      browser.get(Marten.routes.reverse("core:company_edit")).html.should contain(%(aria-current="page">Identité du foyer</a>))

      # Sur l'écran des paramètres de l'extension, « Foyer » reste l'entrée active.
      settings = PartiduoUi::FolderKind.household_settings(Books.system).should_not be_nil
      PartiduoUi::FolderKind.menu_path("/ext/UITEST/", settings).should eq(Marten.routes.reverse("core:company"))
      PartiduoUi::FolderKind.menu_path("/", settings).should eq("/")
      on_settings = PartiduoUi::FolderKind.tabs("/ext/UITEST/", settings).should_not be_nil
      on_settings.map(&.current).should eq([false, true])
      PartiduoUi::FolderKind.tabs("/", settings).should be_nil
    ensure
      PartiduoUi::SimpleMode.unregister("UITEST")
    end
  end

  it "garde « Foyer » seul, sans onglet, sans variante qui déclare ses paramètres" do
    browser = household_books
    browser.get(Marten.routes.reverse("core:company")).html.should_not contain(%(class="pd-tabs))
  end
end

describe "Dossier d'entreprise inchangé par le type foyer" do
  it "garde les tuiles, le bouton, les menus et le vocabulaire de l'entreprise" do
    browser = Books.admin
    PartiduoUi::FolderKind.of(Books.system).should eq("company")
    page = browser.get("/").html
    page.should contain("Clients à encaisser")
    page.should contain("Fournisseurs à payer")
    page.should contain("Nouvelle écriture d'achat")
    page.should_not contain("Nouvelle opération")
    page.should contain("Utilisateur de la société")
    menu = side_menu(page)
    %w[accounting:entry_purchase accounting:entry_sale accounting:entry_received accounting:fec accounting:closing
      accounting:vat_return accounting:auxiliary_balance accounting:aged_balance].each { |route| menu.should contain(href(route)) }
    menu_label(menu, "cards:index").should eq("Tiers et articles")
    menu_label(menu, "core:company").should eq("Société")
    menu.should_not contain(">Contacts<")
    detail = browser.get(Marten.routes.reverse("core:company")).html
    detail.should contain(%(<a href="#{Marten.routes.reverse("core:company")}">Société</a>))
    detail.should_not contain("Foyer")
    browser.get(Marten.routes.reverse("core:company_edit")).html.should contain("Modifier la société")
    detail.should contain("Raison sociale")
    detail.should contain(I18n.t("core.settings.fields.siren"))
    detail.should_not contain(%(class="pd-tabs))
    menu_label(menu, "accounting:accounts").should eq("Comptes et tiers")
    cards = browser.get(Marten.routes.reverse("cards:index")).html
    cards.should contain("Articles et services")
    cards.should contain("Nouveau tiers")
    cards.should contain(">Toutes les natures</option>")
    cards.should contain(">Clients</option>")
    cards.should_not contain("Payeurs")
    categories = browser.get(Marten.routes.reverse("cards:categories")).html
    categories.should contain("<h1>Catégories de fiches")
    categories.should contain("Ventes : articles et services")
  end
end
