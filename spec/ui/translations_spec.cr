# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions de toutes les pages (ADR-005 D7) : chaque route de l'interface
# servie en `GET` (liste tirée du routeur de Marten, jamais écrite à la
# main), obtenue en fr, en et nl par un administrateur qui a tous les
# droits, sur un jeu de données riche — dossier d'entreprise (écritures,
# factures, tiers, analytique, stock, suivi, budgets), micro-entreprise et
# profession libérale (interface simplifiée du membre, complète du
# comptable), foyer —, plus les pages d'accès sans connexion et les pages
# d'erreur. Le HTML rendu ne doit contenir ni marqueur de traduction
# absente, ni clé brute, ni interpolation non résolue
# (`PartiduoUi::Translations`, spec/support/translations.cr). Les pages à
# paramètres sont atteintes par les liens des pages du jeu de données : une
# route servie en `GET` qu'aucun lien n'atteint fait échouer la spec, sauf
# exclusion motivée ci-dessous.

private alias Books = PartiduoUi::Books
private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias Ana = Partiduo::Api::Analytic
private alias Stk = Partiduo::Api::Stock
private alias Fup = Partiduo::Api::Followup
private alias Cards = Partiduo::Api::Cards
private alias Auth = Partiduo::Api::Auth

# Routes servies en `GET` qui ne sont pas des pages à explorer.
private EXCLUSIONS = {
  "login_federated"          => "départ vers un fournisseur d'identité externe (redirection hors du site)",
  "login_federated_callback" => "retour d'un fournisseur d'identité : jeton externe exigé",
  "login_federated_acs"      => "réponse SAML, reçue en POST ; en GET, même handler que le retour OIDC",
  "invitation_connect"       => "départ vers connect (redirection hors du site)",
}

# Variables des modèles de relance, citées telles quelles dans l'aide des
# réglages de la Facturation.
private LITERALS = [PartiduoUi::InvoicingSettingsHandler::REMINDER_VARIABLES]

# Routes de l'interface ; les extensions (`/ext/`, `/p/`) sont contrôlées
# dans leur dépôt et dans la distribution.
private def explorer : PartiduoUi::Translations::Explorer
  PartiduoUi::Translations::Explorer.new(EXCLUSIONS, literals: LITERALS) do |route|
    !route.pattern.starts_with?("/ext/") && !route.pattern.starts_with?("/p/")
  end
end

# Base vidée entre deux jeux de données, comme entre deux exemples.
private def fresh! : Nil
  Marten::Spec.flush_databases
  PartiduoUi::RateLimit.reset!
end

private def customer(name : String, code : String) : Cards::CardView
  input = Cards::CardInput.new(category_id: PartiduoUi::Reference.category("CUSTOMER").id, name: name, code: code,
    siren: "443061841", email: "compta@morel.example",
    address: Cards::AddressInput.new(line1: "3 rue du Port", postcode: "44100", city: "Nantes", country_code: "FR"))
  Cards.create_card(Books.system, input).value!
end

private def article : Cards::CardView
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  input = Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil (heure)",
    code: "CONSEIL", unit_code: "HUR", sale_price: Books.d("80"), vat_rate_id: rate.id)
  Cards.create_card(Books.system, input).value!
end

private def document(kind : String, client : Cards::CardView, item : Cards::CardView, day : String? = "2026-03-02",
                     credited : Int64? = nil) : Inv::DocumentView
  lines = [Inv::LineInput.new(kind: "item", item_card_id: item.id, quantity: Books.d("1"))]
  input = Inv::DocumentInput.new(kind: kind, customer_card_id: client.id, lines: lines, credited_document_id: credited)
  draft = Inv.create_document(Books.system, input).value!
  return draft unless day
  Inv.issue(Books.system, draft.id, Inv::IssueInput.new(issue_date: Books.date(day))).value!
end

private def invoicing(client : Cards::CardView, item : Cards::CardView) : Nil
  invoice = document("invoice", client, item)
  # Règlement saisi en Facturation : sans Comptabilité seulement (sinon,
  # par la banque).
  Inv.record_payment(Books.system, Inv::PaymentInput.new(invoice.id, Books.d("50"), Books.date("2026-03-10"), "cheque", "CHQ 1"))
  document("invoice", client, item, "2026-03-05")
  document("quote", client, item)
  document("quote", client, item, nil)
  document("delivery_note", client, item)
  document("credit_note", client, item, nil, invoice.id)
end

# Dossier d'entreprise : tous les modules du cœur, écritures, factures,
# tiers, analytique, stock, suivi, budget, état personnalisé, TVA, relevé
# rapproché, devise, modèle de facture, fournisseur d'identité, second
# utilisateur et profil, approbation. Rend le navigateur de
# l'administrateur et les adresses qu'aucun lien n'atteint.
private def company : {PartiduoUi::Browser, Array(String)}
  browser = Books.admin
  system = Books.system
  %w[ANALYTIC STOCK FOLLOWUP UIPUB].each { |code| Partiduo::Api::Modules.activate(system, code) }
  client = customer("Atelier Morel", "CLI-MOREL")
  Books.card("SUPPLIER", "Fournitures Alpha", "FOU-ALPHA")
  item = article
  invoicing(client, item)
  Books.sale("CLI-MOREL", "1200")
  receipts = Books.receipt("CLI-MOREL", "600")
  Acc.reconcile(system, Acc::ReconcileInput.new(Books.ledger("F01").id, "R-03", receipts.map(&.id))).value!
  Acc.post_entry(system, Acc::EntryInput.new(ledger_id: Books.ledger("O01").id, date: Books.date("2026-03-15"), lines: [
    Acc::EntryLineInput.new("603", Acc::Side::Debit, Books.d("90")),
    Acc::EntryLineInput.new("101", Acc::Side::Credit, Books.d("90")),
  ])).value!

  plan = Ana.create_plan(system, Ana::PlanInput.new("Activité")).value!
  sale = Ana.create_post(system, Ana::PostInput.new(plan.id, "vente", "Ventes")).value!
  workshop = Ana.create_post(system, Ana::PostInput.new(plan.id, "atelier", "Atelier")).value!
  Ana.create_group(system, Ana::GroupInput.new(plan.id, "PROD", "Production")).value!
  Ana.create_key(system, Ana::KeyInput.new("Moitié", [
    Ana::KeyRowInput.new(Books.d("50"), [sale.id]), Ana::KeyRowInput.new(Books.d("50"), [workshop.id]),
  ])).value!
  Ana.create_misc_operation(system, Ana::MiscOperationInput.new(Books.date("2026-03-10"), "Transfert", [
    Ana::MiscRowInput.new(Books.d("30"), Acc::Side::Debit, [sale.id]),
    Ana::MiscRowInput.new(Books.d("30"), Acc::Side::Credit, [workshop.id]),
  ])).value!

  repository = Stk.create_repository(system, Stk::RepositoryInput.new("Entrepôt Lyon", city: "Lyon")).value!
  screw = Books.card("SALE", "Vis inox", "VIS")
  Stk.track_item(system, Stk::ItemInput.new(screw.id)).value!
  Stk.record_change(system, Stk::ChangeInput.new(repository.id, Books.date("2026-03-10"),
    [Stk::ChangeLineInput.new(screw.id, Books.d("10"), Books.d("2"))])).value!

  type = Fup.create_action_type(system, Fup::ActionTypeInput.new("DI", "Document interne")).value!
  Fup.create_action(system, Fup::ActionInput.new(type.id, Books.date("2026-03-10"))).value!
  Fup.create_tag(system, Fup::TagInput.new("Client")).value!

  periods = Partiduo::Api::Core.fiscal_years(system).find! { |year| year.year == 2026 }.periods
  forecast = Acc.create_forecast(system, Acc::ForecastInput.new("Budget 2026", periods.first.id, periods.last.id)).value!
  category = Acc.create_forecast_category(system, forecast.id, Acc::ForecastCategoryInput.new("Exploitation")).value!
  Acc.create_forecast_item(system, category.id, Acc::ForecastItemInput.new("Ventes", "[70%]", Books.d("1000"))).value!
  Acc.create_report(system, Acc::ReportDefinitionInput.new("Ventes", [Acc::ReportLineInput.new("Ventes", "[70%]")])).value!
  vat_return = Acc.create_vat_return(system, Acc::VatReturnInput.new(form: "fr_ca3", year: 2026, periodicity: "quarter",
    number: 1)).value!.id
  Partiduo::Api::Core.create_currency(system, Partiduo::Api::Core::CurrencyInput.new("USD", "Dollar des États-Unis",
    rate: Books.d("1.08"), valid_from: Books.date("2026-01-01"))).value!
  Inv.create_layout(system, Inv::LayoutInput.new("Modèle principal")).value!
  issuer = "https://idp.example"
  Auth.save_identity_provider(system, Auth::IdentityProviderInput.new("cabinet", "oidc", "Cabinet Durand", settings: {
    "issuer" => issuer, "authorization_endpoint" => "#{issuer}/authorize", "token_endpoint" => "#{issuer}/token",
    "jwks_uri" => "#{issuer}/keys", "client_id" => "partiduo", "client_secret" => "s3cret",
    "redirect_uri" => "https://demo.partiduo.localhost/login/federated/cabinet/callback",
  })).value!
  attachment = Partiduo::Api::Core.store_attachment(system, Partiduo::Api::Core::AttachmentInput.new("note.txt", "text/plain",
    IO::Memory.new("Note"))).value!.id

  profile = PartiduoUi::Accounts.profile("Vendeur", %w[invoicing.invoice.read cards.card.read])
  PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
  approval = Partiduo::Api::Approvals.submit(Auth.actor(PartiduoUi::Accounts.token), Partiduo::Api::Approvals::SubmitInput.new(
    module_code: "UIPUB", kind: "batch", subject: "batch:1", summary: "Virements du 15 octobre", digest: "sha",
    permission: "uipub.batch.approve", amount: BigDecimal.new("1250.40"), currency_code: "EUR")).value!
  {browser, ["/attachments/#{attachment}", "/approvals/#{approval.id}/approve",
             "/accounting/vat/returns/#{vat_return}/settle", "/accounting/vat/returns/#{vat_return}/file"]}
end

# Pages d'accès à jeton valide : invitation, nouveau mot de passe.
private def token_pages : Array(String)
  invited = PartiduoUi::Accounts.create("invite@example.com", password: nil)
  reset = Auth.request_password_reset(Partiduo::Api::Actor.anonymous, "alice@example.com") || raise "jeton refusé"
  ["/invitation/#{invited.invitation.token}", "/password/reset/#{reset.token}"]
end

# Micro-entreprise (Micro et Facturation, sans Comptabilité).
private def micro : Nil
  Books.admin
  system = Books.system
  %w[ANALYTIC ACCOUNTING].each { |code| Partiduo::Api::Modules.deactivate(system, code) }
  Partiduo::Api::Modules.activate(system, "MICRO").value!
  Partiduo::Api::Micro.load_defaults(system)
  natures = Partiduo::Api::Micro.natures(system)
  Partiduo::Api::Micro.record_receipt(system, Partiduo::Api::Micro::ReceiptInput.new(date: Books.date("2026-03-10"),
    nature_id: natures.find!(&.code.==("SERVICE")).id, amount: Books.d("500"), method: "transfer", party_name: "Atelier Morel")).value!
  Partiduo::Api::Micro.record_purchase(system, Partiduo::Api::Micro::PurchaseInput.new(date: Books.date("2026-03-12"),
    nature_id: natures.find!(&.code.==("SUPPLIES")).id, amount: Books.d("40"), method: "card", party_name: "Papeterie Centrale")).value!
  invoicing(customer("Atelier Morel", "CLI-MOREL"), article)
end

# Profession libérale (Comptabilité active : le comptable a l'interface
# complète).
private def liberal : Nil
  Books.admin
  system = Books.system
  Partiduo::Api::Modules.activate(system, "LIBERAL").value!
  Partiduo::Api::Liberal.load_defaults(system)
  natures = Partiduo::Api::Liberal.natures(system)
  nature = ->(code : String) { natures.find!(&.code.==(code)).id }
  Partiduo::Api::Liberal.record_receipt(system, Partiduo::Api::Liberal::LineInput.new(date: Books.date("2026-03-10"),
    nature_id: nature.call("RECEIPTS"), amount: Books.d("800"), method: "transfer", party_name: "Mme Durand")).value!
  Partiduo::Api::Liberal.record_expense(system, Partiduo::Api::Liberal::LineInput.new(date: Books.date("2026-03-11"),
    nature_id: nature.call("RENT"), amount: Books.d("400"), method: "transfer", party_name: "SCI du Parc")).value!
  Partiduo::Api::Liberal.record_asset(system, Partiduo::Api::Liberal::AssetInput.new(label: "Table de massage",
    category: "equipment", acquired_on: Books.date("2026-04-01"), amount: Books.d("3000"), duration_years: 3, method: "transfer")).value!
  Partiduo::Api::Liberal.add_adjustment(system, Partiduo::Api::Liberal::AdjustmentInput.new(2026, "deduction", "Exonération",
    Books.d("50"))).value!
  invoicing(customer("Mme Durand", "CLI-DURAND"), article)
end

# Foyer (ADR-011 A3) : modules d'entreprise exclus, opérations et budget.
private def household : Nil
  %w[ANALYTIC STOCK FOLLOWUP MICRO LIBERAL INVOICING].each { |code| Partiduo::Api::Modules.deactivate(Books.system, code) }
  PartiduoUi::Reference.provision(kind: Partiduo::Api::InitialData::HOUSEHOLD)
  PartiduoUi::Reference.fiscal_year(2026)
  PartiduoUi::Accounts.create
  lines = [
    Acc::PaymentLineInput.new(Books.d("3000"), account: "701", label: "Salaire"),
    Acc::PaymentLineInput.new(Books.d("-450"), account: "62", label: "Courses"),
  ]
  Acc.post_financial(Books.system, Acc::FinancialInput.new(ledger_id: Books.ledger("F01").id, date: Books.date("2026-03-10"),
    lines: lines)).value!
end

# Comptable du dossier (rôle `accountant`) : interface complète des
# dossiers simplifiés.
private def accountant : PartiduoUi::Browser
  PartiduoUi::Accounts.create("comptable@example.com", role: "accountant")
  PartiduoUi::Accounts.signed_in("comptable@example.com")
end

describe "Traductions de toutes les pages (fr, en, nl)" do
  it "rend chaque page de l'interface dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    explorer = explorer()

    # Pages d'accès sans connexion et pages d'erreur (paramètres qui ne
    # désignent rien) : avant tout dossier, puis dossier provisionné.
    explorer.visit_placeholders(PartiduoUi::Browser.new, "anonyme, instance vierge")
    PartiduoUi::Reference.provision
    explorer.visit_placeholders(PartiduoUi::Browser.new, "anonyme")
    fresh!

    browser, seeds = company
    explorer.crawl(browser, "entreprise", seeds)
    explorer.visit(PartiduoUi::Browser.new, "anonyme, jetons valides", token_pages)
    explorer.visit_placeholders(browser, "entreprise, objets inconnus")
    reduced = PartiduoUi::Accounts.signed_in("bob@example.com")
    explorer.crawl(reduced, "entreprise, droits réduits")
    # Envois de chaque formulaire relevé (vide, valeurs fausses, bouton
    # d'action tel quel) : refus de droits d'abord, puis administrateur.
    explorer.submit_forms(reduced, "entreprise, droits réduits", explorer.all_forms)
    explorer.submit_forms(browser, "entreprise")
    fresh!

    micro
    member = PartiduoUi::Accounts.signed_in
    explorer.crawl(member, "micro, simplifiée")
    explorer.crawl(accountant, "micro, complète")
    explorer.submit_forms(member, "micro, simplifiée")
    fresh!

    liberal
    member = PartiduoUi::Accounts.signed_in
    explorer.crawl(member, "libéral, simplifiée")
    explorer.crawl(accountant, "libéral, complète")
    explorer.submit_forms(member, "libéral, simplifiée")
    fresh!

    household
    member = PartiduoUi::Accounts.signed_in
    explorer.crawl(member, "foyer")
    explorer.submit_forms(member, "foyer")

    puts "\nTraductions : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
