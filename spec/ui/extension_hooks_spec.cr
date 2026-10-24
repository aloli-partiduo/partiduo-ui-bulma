# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Points d'accroche des extensions (DECISIONS D-HOOK-001, D-HOOK-002) :
# tuiles des tableaux de bord (`Extensions.tile`) et panneau de la fiche
# d'un document de la Facturation (`Extensions.document_links`), éprouvés
# avec l'extension factice UITEST (`spec/fixtures/uitest/app.cr`).

private alias Books = PartiduoUi::Books
private alias Inv = Partiduo::Api::Invoicing

# Appels du crochet de sonde « UIPROBE » (pièce jamais enregistrée, donc
# jamais active).
class ExtensionHooksProbe
  class_property calls = 0
end

PartiduoUi::Extensions.tile "UIPROBE" do |_actor, _fmt|
  ExtensionHooksProbe.calls += 1
  [] of PartiduoUi::Dashboard::Tile
end

PartiduoUi::Extensions.document_links "UIPROBE" do |_actor, _document|
  ExtensionHooksProbe.calls += 1
  [] of PartiduoUi::Extensions::DocumentLink
end

private def activate_uitest : Nil
  Partiduo::Api::Modules.activate(Books.system, "UITEST").success?.should be_true
end

private def issued_invoice(draft : Bool = false) : Inv::DocumentView
  customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  item = Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(
    category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil", code: "CONSEIL", unit_code: "HUR",
    sale_price: Books.d("80"), vat_rate_id: rate.id)).value!
  document = Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
    lines: [Inv::LineInput.new(item_card_id: item.id, quantity: Books.d("1"))], due_date: Books.date("2026-01-20"))).value!
  return document if draft
  Inv.issue(Books.system, document.id, Inv::IssueInput.new(Books.date("2026-01-05"))).value!
end

private def tile_of(html : String) : String?
  html.match(/<(?:a|div) class="pd-panel pd-tile"[^>]*data-module="UITEST".*?<\/(?:a|div)>/m).try(&.[0])
end

private def panel_of(html : String) : String?
  html.match(/<aside class="pd-panel pd-ext-panel"[^>]*data-extension="UITEST".*?<\/aside>/m).try(&.[0])
end

describe "Tuiles des extensions (Extensions.tile, D-HOOK-001)" do
  it "n'appelle le bloc que pour une extension active et ignore un refus" do
    ExtensionHooksProbe.calls = 0
    fmt = PartiduoUi::Format.new("fr")
    PartiduoUi::Extensions.tiles(Books.system, fmt, Set{"UIPROBE_INACTIVE"}).should be_empty
    ExtensionHooksProbe.calls.should eq(0)
    PartiduoUi::Extensions.tiles(Books.system, fmt, Set{"UIPROBE"}).should be_empty
    ExtensionHooksProbe.calls.should eq(1)

    # Libellé dans la langue active : le français, quelle que soit celle
    # qu'une spec précédente a laissée.
    tiles = I18n.with_locale("fr") { PartiduoUi::Extensions.tiles(Books.system, fmt, Set{"UITEST"}) }
    tiles.map(&.label).should eq(["Tuile de test"])
    tiles.first.value.should eq(fmt.amount(BigDecimal.new("1234.5")))
    tiles.first.module_code.should eq("UITEST")
    # Refus (Forbidden) de l'extension : aucune tuile, aucune erreur.
    PartiduoUi::Extensions.tiles(Partiduo::Api::Actor.anonymous, fmt, Set{"UITEST"}).should be_empty
  end

  it "refuse un code d'extension invalide" do
    expect_raises(ArgumentError, /code d'extension invalide/) do
      PartiduoUi::Extensions.tile("crm") { [] of PartiduoUi::Dashboard::Tile }
    end
  end

  it "ajoute la tuile au tableau de bord complet de l'extension active, seulement" do
    browser = Books.admin
    tile_of(browser.get("/").html).should be_nil
    activate_uitest
    tile = tile_of(browser.get("/").html) || fail "tuile UITEST absente"
    tile.should contain(%(href="/ext/UITEST/"))
    tile.should contain("Tuile de test")
    tile.should contain("Sous-titre de test")
  end

  it "ajoute la tuile aux tableaux de bord simplifiés (micro-entreprise, profession libérale)" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
    activate_uitest
    Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
    Partiduo::Api::Liberal.load_defaults(Books.system)
    page = browser.get("/").html
    page.should contain("pd-simple")
    page.should contain(%(href="/liberal/receipts"))
    tile_of(page).should_not be_nil

    # Micro-entreprise et profession libérale ne s'activent pas ensemble
    # (D-AMD-038 du cœur) : l'une remplace l'autre.
    Partiduo::Api::Modules.deactivate(Books.system, "LIBERAL").success?.should be_true
    Partiduo::Api::Modules.activate(Books.system, "MICRO").success?.should be_true
    Partiduo::Api::Micro.load_defaults(Books.system)
    page = browser.get("/").html
    page.should contain(%(href="/micro/receipts"))
    tile_of(page).should_not be_nil
  end

  it "n'affiche rien, sans erreur, quand l'extension refuse l'acteur" do
    Books.admin
    activate_uitest
    profile = PartiduoUi::Accounts.profile("Comptable seul", ["accounting.entry.read"])
    PartiduoUi::Accounts.create(email: "lecteur@example.com", profile: nil, profile_id: profile)
    response = PartiduoUi::Accounts.signed_in("lecteur@example.com").get("/")
    response.status.should eq(200)
    tile_of(response.html).should be_nil
  end
end

describe "Panneau des extensions sur la fiche d'un document (Extensions.document_links, D-HOOK-002)" do
  it "présente actions et fichiers de l'extension active dans un panneau accessible" do
    browser = Books.admin
    document = issued_invoice
    panel_of(browser.get("/invoicing/documents/#{document.id}").html).should be_nil

    activate_uitest
    page = browser.get("/invoicing/documents/#{document.id}").html
    panel = panel_of(page) || fail "panneau UITEST absent"
    panel.should contain(%(aria-labelledby="pd-ext-uitest-title"))
    panel.should contain(%(<h2 id="pd-ext-uitest-title">Extension de test</h2>))
    panel.should contain(%(<a class="button pd-touch" href="/ext/UITEST/?document=#{document.id}">))
    panel.should contain("Action de test")
    panel.should contain("<h3 class=\"pd-ext-subtitle\">Fichiers produits</h3>")
    panel.should contain(%(<a class="pd-link pd-touch" href="/ext/UITEST/?file=#{document.id}">))
    panel.should contain("uitest-#{document.number}.txt")
    panel.scan(/<ul class="pd-ext-links/).size.should eq(2)
  end

  it "n'affiche pas de panneau sans lien ni pour un acteur refusé" do
    browser = Books.admin
    activate_uitest
    draft = issued_invoice(draft: true)
    panel_of(browser.get("/invoicing/documents/#{draft.id}").html).should be_nil

    issued = Inv.issue(Books.system, draft.id, Inv::IssueInput.new(Books.date("2026-01-05"))).value!
    profile = PartiduoUi::Accounts.profile("Factures seules", ["invoicing.invoice.read"])
    PartiduoUi::Accounts.create(email: "lecteur@example.com", profile: nil, profile_id: profile)
    response = PartiduoUi::Accounts.signed_in("lecteur@example.com").get("/invoicing/documents/#{issued.id}")
    response.status.should eq(200)
    panel_of(response.html).should be_nil
  end

  it "ne consulte que les extensions actives" do
    ExtensionHooksProbe.calls = 0
    Books.admin
    activate_uitest
    document = issued_invoice
    panels = PartiduoUi::Extensions.document_panels(Books.system, document)
    panels.map(&.code).should eq(["UITEST"])
    panels.first.actions.map(&.label).should eq(["Action de test"])
    panels.first.files.map(&.kind).should eq(["file"])
    ExtensionHooksProbe.calls.should eq(0)
  end
end
