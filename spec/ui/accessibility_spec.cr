# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Contrôles automatisables de WCAG 2.2 AA (ADR-005 D5) sur les pages rendues :
# langue, titre unique, champs étiquetés, boutons nommés, icônes décoratives
# masquées, lien d'évitement, aucun ordre de tabulation forcé. Le contraste
# et le focus visible relèvent de theme.css et app.css (spec plus bas).
private def check_accessibility(html : String, path : String) : Nil
  html.should match(/<html lang="(fr|en|nl)">/)
  html.should contain(%(class="pd-skip" href="#pd-main"))
  html.should contain(%(id="pd-main"))
  html.scan(/<h1[\s>]/).size.should eq(1), "#{path} : un seul titre de niveau 1"
  html.should_not match(/tabindex="[1-9]/)

  labels = html.scan(/<label[^>]*\bfor="([^"]+)"/).map(&.[1]).to_set
  html.scan(/<(input|select|textarea)\b([^>]*)>/) do |match|
    attributes = match[2]
    next if attributes.matches?(/type="(hidden|submit|button)"/)
    id = attributes.match(/\bid="([^"]+)"/).try(&.[1])
    labelled = attributes.includes?("aria-label=") || attributes.includes?("aria-labelledby=") || (id && labels.includes?(id))
    labelled.should be_true, "#{path} : champ sans étiquette : <#{match[1]}#{attributes}>"
  end

  html.scan(/<button\b([^>]*)>(.*?)<\/button>/m) do |match|
    text = match[2].gsub(/<svg.*?<\/svg>/m, "").gsub(/<[^>]+>/, "").strip
    (text.presence || match[1].includes?("aria-label=")).should be_truthy, "#{path} : bouton sans nom : #{match[0][0, 120]}"
  end

  # Toute image a un texte de remplacement, vide si elle est décorative (le
  # symbole de la marque, doublé du nom en texte).
  html.scan(/<img\b([^>]*)>/) do |match|
    match[1].should match(/\balt="/), "#{path} : image sans alt : <img#{match[1]}>"
  end

  html.scan(/<svg\b([^>]*)>/) do |match|
    decorative = match[1].includes?(%(aria-hidden="true"))
    described = match[1].includes?(%(role="img")) && match[1].includes?("aria-label=")
    (decorative || described).should be_true, "#{path} : SVG ni décoratif ni décrit"
  end
end

describe "Accessibilité (WCAG 2.2 AA)" do
  it "respecte les règles automatisables sur les écrans d'authentification" do
    %w[/login /password/forgotten /unlock].each do |path|
      check_accessibility(PartiduoUi::Browser.new.get(path).html, path)
    end
  end

  it "respecte les règles automatisables sur les écrans de l'application" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    %w[/ /account/security /account/totp /account/passkey-prompt /search?q=x /about].each do |path|
      response = browser.get(path)
      response.status.should eq(200)
      check_accessibility(response.html, path)
    end
  end

  it "respecte les règles automatisables sur les écrans du référentiel" do
    PartiduoUi::Reference.provision
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    year = PartiduoUi::Reference.fiscal_year(2026)
    customer = PartiduoUi::Reference.category("CUSTOMER")
    card = Partiduo::Api::Cards.create_card(Partiduo::Api::Actor.system,
      Partiduo::Api::Cards::CardInput.new(category_id: customer.id, name: "Morel")).value!
    account = Partiduo::Api::Accounting.account(Partiduo::Api::Actor.system, "400")
    ledger = Partiduo::Api::Accounting.ledgers(Partiduo::Api::Actor.system).first
    rate = Partiduo::Api::Vat.rates(Partiduo::Api::Actor.system).first
    paths = ["/fiscal-years", "/fiscal-years/#{year.id}", "/accounting/chart", "/accounting/chart/new",
             "/accounting/chart/#{account.id}", "/accounting/chart/#{account.id}/edit", "/accounting/ledgers",
             "/accounting/ledgers/new", "/accounting/ledgers/#{ledger.id}", "/accounting/ledgers/#{ledger.id}/edit",
             "/vat/rates", "/vat/rates/new", "/vat/rates/#{rate.id}", "/vat/rates/#{rate.id}/edit", "/cards", "/cards/items",
             "/cards/new", "/cards/new?category=#{customer.id}", "/cards/#{card.id}", "/cards/#{card.id}/edit"]
    paths.each do |path|
      response = browser.get(path)
      response.status.should eq(200), "#{path} : #{response.status}"
      check_accessibility(response.html, path)
      response.html.should_not contain("missing translation")
    end
  end

  it "respecte les règles automatisables sur les écrans du mode simplifié (ADR-007 D3)" do
    browser = PartiduoUi::Books.admin
    system = PartiduoUi::Books.system
    Partiduo::Api::Modules.activate(system, "MICRO").success?.should be_true
    Partiduo::Api::Micro.load_defaults(system)
    nature = Partiduo::Api::Micro.natures(system, "receipt").first
    line = Partiduo::Api::Micro.record_receipt(system, Partiduo::Api::Micro::ReceiptInput.new(
      date: PartiduoUi::Books.date("2026-03-10"), nature_id: nature.id, amount: PartiduoUi::Books.d("50"), method: "cash")).value!
    ["/", "/micro/receipts", "/micro/receipts/new", "/micro/receipts/#{line.id}", "/micro/purchases", "/micro/purchases/new",
     "/micro/urssaf", "/micro/tax-return", "/micro/thresholds", "/micro/settings", "/micro/invoices/new"].each do |path|
      response = browser.get(path)
      response.status.should eq(200), "#{path} : #{response.status}"
      check_accessibility(response.html, path)
      response.html.should_not contain("missing translation")
    end
    refused = browser.post("/micro/receipts/new", {"amount" => "x", "date" => "2026-03-10", "nature_id" => nature.id.to_s, "method" => "cash"})
    refused.status.should eq(422)
    check_accessibility(refused.html, "/micro/receipts/new (refus)")
    refused.html.should contain(%(aria-invalid="true"))
  end

  it "respecte les règles automatisables sur les écrans de la profession libérale (ADR-007 D6)" do
    browser = PartiduoUi::Books.admin
    system = PartiduoUi::Books.system
    Partiduo::Api::Modules.activate(system, "LIBERAL").success?.should be_true
    Partiduo::Api::Liberal.load_defaults(system)
    nature = Partiduo::Api::Liberal.natures(system, "expense").first
    line = Partiduo::Api::Liberal.record_expense(system, Partiduo::Api::Liberal::LineInput.new(
      date: PartiduoUi::Books.date("2026-03-10"), nature_id: nature.id, amount: PartiduoUi::Books.d("50"), method: "cash")).value!
    asset = Partiduo::Api::Liberal.record_asset(system, Partiduo::Api::Liberal::AssetInput.new(label: "Ordinateur", category: "office",
      acquired_on: PartiduoUi::Books.date("2026-03-10"), amount: PartiduoUi::Books.d("1200"), duration_years: 3, method: "card")).value!
    Partiduo::Api::Liberal.add_adjustment(system, Partiduo::Api::Liberal::AdjustmentInput.new(2026, "deduction", "Exonération",
      PartiduoUi::Books.d("10"))).value!
    ["/", "/liberal/journal", "/liberal/receipts", "/liberal/receipts/new", "/liberal/expenses", "/liberal/expenses/new",
     "/liberal/lines/#{line.id}", "/liberal/assets", "/liberal/assets/new", "/liberal/assets/#{asset.id}",
     "/liberal/assets/#{asset.id}/dispose", "/liberal/tax-return", "/liberal/settings", "/liberal/natures",
     "/liberal/natures/#{nature.id}", "/liberal/form-lines"].each do |path|
      response = browser.get(path)
      response.status.should eq(200), "#{path} : #{response.status}"
      check_accessibility(response.html, path)
      response.html.should_not contain("missing translation")
    end
    refused = browser.post("/liberal/expenses/new", {"amount" => "x", "date" => "2026-03-10", "nature_id" => nature.id.to_s, "method" => "cash"})
    refused.status.should eq(422)
    check_accessibility(refused.html, "/liberal/expenses/new (refus)")
    refused.html.should contain(%(aria-invalid="true"))
    adjustment = browser.post("/liberal/tax-return/adjustments?year=2026", {"kind" => "deduction", "label" => "", "amount" => "x"})
    adjustment.status.should eq(422)
    check_accessibility(adjustment.html, "/liberal/tax-return (refus)")
  end

  it "respecte les règles automatisables sur l'enrôlement" do
    created = PartiduoUi::Accounts.create(email: "bob@example.com", password: nil)
    browser = PartiduoUi::Browser.new
    browser.post("/invitation/#{created.invitation.token}")
    check_accessibility(browser.get("/account/enrollment").html, "/account/enrollment")
  end

  it "signale la page courante, relie les erreurs à leur champ et annonce les alertes" do
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/").html.should contain(%(aria-current="page"))
    refused = browser.post("/account/password", {"current_password" => PartiduoUi::Accounts::PASSWORD, "new_password" => "court", "confirmation" => "court"}).html
    refused.should contain(%(aria-invalid="true"))
    refused.should contain(%(id="pd-new-password-errors"))
    refused.should contain(%(aria-describedby="pd-password-rules pd-password-feedback pd-new-password-errors"))
    PartiduoUi::Browser.new.post("/login", {"email" => "x@example.com", "password" => "y"}).html.should contain(%(role="alert"))
  end
end

describe "Mise en page adaptée à trois tailles d'écran (ADR-005 D5)" do
  css = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "app.css"))

  it "prévoit ordinateur, tablette (menu repliable) et téléphone (barre non figée)" do
    css.should contain("@media (max-width: 1279.98px)")
    css.should contain(".pd-app.is-menu-collapsed .pd-side { display: none; }")
    css.should contain("@media (max-width: 767.98px)")
    css.should match(/@media \(max-width: 767\.98px\) \{[^@]*\.pd-top \{ position: static;/m)
    css.should match(/@media \(max-width: 767\.98px\) \{[^@]*\.pd-hide-s \{ display: none; \}/m)
  end

  it "garde des cibles tactiles de 44 px, un focus visible et respecte la réduction des animations" do
    access = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "access.css"))
    access.should contain(".pd-touch { min-height: 44px; min-width: 44px; }")
    css.should contain(":focus-visible { outline: 2px solid var(--pd-focus); outline-offset: 2px; }")
    css.should contain("prefers-reduced-motion: reduce")
  end

  it "montre la bordure des champs des lignes de saisie, contrastée à 3:1 au moins (WCAG 1.4.11)" do
    css.should contain(".pd-inv-lines select { width: 100%; min-height: 36px; border: 1px solid var(--pd-field-border);")
    theme = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "theme.css"))
    token = ->(name : String) { theme.scan(/--pd-#{name}: #([0-9a-f]{6});/).map(&.[1]) }
    luminance = ->(hex : String) do
      rgb = {0, 2, 4}.map do |i|
        c = hex[i, 2].to_i(16) / 255.0
        c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
      end
      0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    end
    borders = token.call("field-border")
    surfaces = token.call("surface")
    borders.size.should eq(3)
    borders.zip(surfaces).each do |border, surface|
      a, b = luminance.call(border), luminance.call(surface)
      ((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)).should be >= 3.0
    end
  end

  it "contraste l'étiquette neutre (« annulée ») à 4,5:1 au moins dans les deux thèmes (WCAG 1.4.3)" do
    css.should contain(".tag.is-light:not(.is-primary):not(.is-link):not(.is-info):not(.is-success):not(.is-warning):not(.is-danger) {\n  background-color: var(--pd-tag-bg); color: var(--pd-tag-ink); }")
    theme = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "theme.css"))
    token = ->(name : String) { theme.scan(/--pd-#{name}: #([0-9a-f]{6});/).map(&.[1]) }
    luminance = ->(hex : String) do
      rgb = {0, 2, 4}.map do |i|
        c = hex[i, 2].to_i(16) / 255.0
        c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
      end
      0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    end
    inks = token.call("tag-ink")
    grounds = token.call("tag-bg")
    {inks.size, grounds.size}.should eq({3, 3}) # clair, sombre (préférence), sombre (choisi)
    inks.zip(grounds).each do |ink, ground|
      a, b = luminance.call(ink), luminance.call(ground)
      ((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)).should be >= 4.5
    end
  end

  it "fait tenir une liste dans 375 px sans couper la colonne « Actions »" do
    css.should match(/@media \(max-width: 767\.98px\) \{[^@]*\.pd-table\.is-narrow td, \.pd-table\.is-narrow th \{ padding-inline: \.3rem; \}/m)
    css.should match(/@media \(max-width: 767\.98px\) \{[^@]*\.pd-table tfoot td\.pd-mono \{ white-space: normal;/m)
  end

  it "n'utilise que des propriétés logiques pour les marges et bordures latérales (ADR-005 D7)" do
    css.should_not match(/(margin|padding|border)-(left|right)\s*:/)
    css.should_not match(/text-align:\s*(left|right)/)
  end
end
