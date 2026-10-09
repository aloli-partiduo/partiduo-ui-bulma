# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Mode simplifié ouvert aux extensions (ADR-011 A2, DECISIONS D-FOY-002) :
# variante déclarée par `PartiduoUi::Extensions.simple_mode` — menu réduit,
# vocabulaire, interfaces offertes, tuiles, menus de la Comptabilité écartés
# —, éprouvée avec l'extension factice UITEST. La préférence d'interface
# reste celle de chaque utilisateur, enregistrée par le cœur (D-UI-077).

private alias Books = PartiduoUi::Books

# Déclare la variante d'UITEST le temps du bloc.
private def with_uitest_flavor(offer : PartiduoUi::SimpleMode::Offer? = nil, &) : Nil
  tiles = ->(_actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) do
    [PartiduoUi::Dashboard::Tile.new("UITEST", "Patrimoine du foyer", fmt.amount(BigDecimal.new("98765.4")))]
  end
  menu = [
    PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "core.menu.dashboard"),
    PartiduoUi::SimpleMode::Entry.new("UITEST_HOME", "uitest.menu.uitest_home"),
  ]
  if offer
    PartiduoUi::Extensions.simple_mode("UITEST", read: "uitest.page.view", menu: menu, offer: offer,
      hidden_menus: PartiduoUi::SimpleMode::BUSINESS_ACCOUNTING_MENUS, tiles: tiles)
  else
    PartiduoUi::Extensions.simple_mode("UITEST", read: "uitest.page.view", menu: menu,
      hidden_menus: PartiduoUi::SimpleMode::BUSINESS_ACCOUNTING_MENUS, tiles: tiles)
  end
  begin
    yield
  ensure
    PartiduoUi::SimpleMode.unregister("UITEST")
  end
end

# Menu latéral de la page.
private def side_menu(html : String) : String
  html.match(/<nav class="pd-side menu".*?<\/nav>/m).try(&.[0]) || fail "menu latéral absent"
end

private def href(route : String) : String
  %(href="#{Marten.routes.reverse(route)}")
end

describe "Mode simplifié d'une extension (Extensions.simple_mode, ADR-011 A2)" do
  it "présente le menu réduit, les tuiles et le vocabulaire commun de la variante" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "UITEST").success?.should be_true
    browser.get("/").html.should_not contain("pd-simple") # sans variante déclarée

    with_uitest_flavor do
      PartiduoUi::SimpleMode.flavor(Books.system).try(&.module_code).should eq("UITEST")
      home = browser.get("/").html
      home.should contain("pd-simple")
      home.should contain("Page de test")
      home.should contain(%(href="/ext/UITEST/"))
      home.should contain("Patrimoine du foyer")
      home.should contain("Passer à la comptabilité")
      home.should_not contain(href("accounting:entries"))
      home.should_not contain("missing translation")

      form = browser.get("/account/preferences").html
      form.should contain(%(<option value="simple" selected>Recettes et dépenses</option>))
      form.should contain(%(<option value="full">Comptabilité</option>))
      form.should_not contain("missing translation")
    end
  end

  it "écarte les menus TVA, FEC et clôture dans l'interface complète aussi" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "UITEST").success?.should be_true
    side_menu(browser.get("/").html).should contain(href("accounting:fec"))

    with_uitest_flavor do
      browser.post("/account/preferences", {"interface" => "full"}).status.should eq(302)
      page = browser.get("/").html
      page.should_not contain("pd-simple")
      page.should contain("Passer aux recettes et dépenses")
      full = side_menu(page)
      full.should contain(href("accounting:entries"))
      %w[accounting:fec accounting:closing accounting:vat_return accounting:vat_returns].each do |route|
        full.should_not contain(href(route))
      end
      # Présentation seulement : la route reste joignable.
      browser.get(Marten.routes.reverse("accounting:fec")).status.should eq(200)
    end
    # Variante retirée : la préférence enregistrée demeure, le menu revient.
    side_menu(browser.get("/").html).should contain(href("accounting:fec"))
  end

  it "n'offre que l'interface simplifiée quand la variante le dit" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "UITEST").success?.should be_true
    only_simple = ->(_role : String?, _active : Set(String)) { [PartiduoUi::SimpleMode::SIMPLE] }
    with_uitest_flavor(only_simple) do
      PartiduoUi::SimpleMode.interfaces("UITEST", "member", true).should eq(["simple"])
      browser.post("/account/preferences", {"interface" => "full"}).status.should eq(422)
      page = browser.get("/account/preferences").html
      page.should contain("Ce dossier se présente en recettes et dépenses.")
      browser.get("/").html.should_not contain("Passer à la comptabilité")
    end
  end

  it "laisse la priorité aux variantes de la micro-entreprise et de la profession libérale" do
    Books.admin
    Partiduo::Api::Modules.activate(Books.system, "UITEST").success?.should be_true
    with_uitest_flavor do
      Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
      PartiduoUi::SimpleMode.flavor(Books.system).try(&.module_code).should eq("LIBERAL")
    end
  end

  it "refuse une variante déclarée deux fois, un code invalide ou un menu vide" do
    with_uitest_flavor do
      expect_raises(ArgumentError, /déjà déclarée : UITEST/) do
        PartiduoUi::Extensions.simple_mode("UITEST", read: "uitest.page.view",
          menu: [PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "core.menu.dashboard")])
      end
    end
    expect_raises(ArgumentError, /déjà déclarée : MICRO/) do
      PartiduoUi::Extensions.simple_mode("MICRO", read: "micro.register.read",
        menu: [PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "core.menu.dashboard")])
    end
    expect_raises(ArgumentError, /code d'extension invalide/) do
      PartiduoUi::Extensions.simple_mode("perso", read: "perso.read",
        menu: [PartiduoUi::SimpleMode::Entry.new("DASHBOARD", "core.menu.dashboard")])
    end
    expect_raises(ArgumentError, /menu réduit vide/) do
      PartiduoUi::Extensions.simple_mode("UIEMPTY", read: "uitest.page.view", menu: [] of PartiduoUi::SimpleMode::Entry)
    end
  end

  it "retire une rubrique dont toutes les entrées sont écartées" do
    view = Partiduo::Api::Modules::MenuView
    menu = [
      view.new("VAT", "core.menu.vat", nil, "CORE", [view.new("ACC_VAT_RETURN", "x", "accounting:vat_return", "ACCOUNTING", [] of Partiduo::Api::Modules::MenuView)]),
      view.new("REPORTS", "core.menu.reports", nil, "CORE", [
        view.new("ACC_FEC", "x", "accounting:fec", "ACCOUNTING", [] of Partiduo::Api::Modules::MenuView),
        view.new("ACC_TRIAL_BALANCE", "x", "accounting:trial_balance", "ACCOUNTING", [] of Partiduo::Api::Modules::MenuView),
      ]),
    ]
    kept = PartiduoUi::SimpleMode.without(menu, PartiduoUi::SimpleMode::BUSINESS_ACCOUNTING_MENUS.to_set)
    kept.map(&.code).should eq(["REPORTS"])
    kept.first.children.map(&.code).should eq(["ACC_TRIAL_BALANCE"])
    PartiduoUi::SimpleMode.without(menu, Set(String).new).should eq(menu)
  end
end
