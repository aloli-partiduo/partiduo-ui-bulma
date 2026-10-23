# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lot C (testeur) : panneau « Canal d'émission » d'une facture (dépôt sur la
# plateforme, copie PDF envoyée, échec), canal `public_portal` (Chorus Pro)
# et saisie express d'un particulier, cas limites et droits (ADR-004 D9
# révisé ; DECISIONS D-CPY-001, D-CPY-003, D-CPY-004).

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books
private alias Cards = Partiduo::Api::Cards

private def issued_invoice(email : String = "compta@morel.test", channel : String? = nil) : Inv::DocumentView
  customers = PartiduoUi::Reference.category("CUSTOMER")
  customer = Cards.create_card(Books.system, Cards::CardInput.new(category_id: customers.id, name: "Atelier Morel",
    siren: "443061841", email: email)).value!
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  item = Cards.create_card(Books.system, Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id,
    name: "Conseil", unit_code: "HUR", sale_price: Books.d("80"), vat_rate_id: rate.id)).value!
  draft = Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
    issue_channel: channel, lines: [Inv::LineInput.new(item_card_id: item.id, quantity: Books.d("1"))])).value!
  Inv.issue(Books.system, draft.id, Inv::IssueInput.new(Books.date("2026-09-15"))).value!
end

private def with_transport(&)
  transport = Inv::MemoryTransport.new
  previous = Inv.mail_transport
  Inv.mail_transport = transport
  begin
    yield transport
  ensure
    Inv.mail_transport = previous
  end
end

private def restricted_browser(permissions : Array(String)) : PartiduoUi::Browser
  profile = PartiduoUi::Accounts.profile("Profil restreint", permissions)
  PartiduoUi::Accounts.create("bob@example.com", profile_id: profile)
  PartiduoUi::Accounts.signed_in("bob@example.com")
end

describe "Panneau « Canal d'émission » : copie PDF et dépôt (lot C)" do
  it "affiche l'échec de la copie, traduit, et garde le bouton « Envoyer »" do
    browser = Books.admin
    with_transport do |transport|
      Inv.update_settings(Books.system, Inv.settings(Books.system).to_input
        .copy_with(sender_email: "factures@brunet.test")).value!
      invoice = issued_invoice
      transport.failure = "421 serveur occupé"
      failed = browser.follow(browser.post("/invoicing/documents/#{invoice.id}/send-pdf-copy")).html
      failed.should contain("Échec de la copie PDF le ")
      failed.should contain("421 serveur occupé")
      failed.should contain(I18n.t("ui.invoicing.pdf_copy_send"))
      failed.should_not contain(I18n.t("ui.invoicing.pdf_copy_resend"))
      transport.messages.should be_empty

      # Un envoi réussi efface l'échec et change le bouton.
      transport.failure = nil
      sent = browser.follow(browser.post("/invoicing/documents/#{invoice.id}/send-pdf-copy")).html
      sent.should_not contain("Échec de la copie PDF le ")
      sent.should contain("Copie PDF envoyée le ")
      sent.should contain(I18n.t("ui.invoicing.pdf_copy_resend"))
    end
  end

  it "présente en clair l'échec d'une copie sans destinataire, pas une clé de traduction" do
    browser = Books.admin
    with_transport do |transport|
      invoice = issued_invoice(email: "")
      page = browser.follow(browser.post("/invoicing/documents/#{invoice.id}/send-pdf-copy")).html
      transport.messages.should be_empty
      page.should contain("Échec de la copie PDF le ")
      page.should contain(HTML.escape(I18n.t("invoicing.errors.mail.no_recipient")))
      page.should_not contain("invoicing.errors.")
    end
  end

  it "affiche la date du dépôt sur la plateforme" do
    browser = Books.admin
    invoice = issued_invoice
    browser.get("/invoicing/documents/#{invoice.id}").html.should_not contain("Déposée sur la plateforme le ")
    # Le dépôt est un événement publié par l'extension de plateforme, hors de
    # portée de l'interface (ADR-005 D3) : sa trace est posée directement.
    Marten::DB::Connection.default.open do |db|
      db.exec("INSERT INTO invoicing_document_event (action, fingerprint, details, created_at, document_id) " \
              "VALUES ('platform_deposited', '', '{\"platform_ref\": \"PA-1\"}'::jsonb, now(), $1)", invoice.id)
    end
    page = browser.get("/invoicing/documents/#{invoice.id}").html
    page.should contain("Déposée sur la plateforme le ")
    # Historique : l'action a son libellé, jamais la chaîne brute.
    page.should contain(I18n.t("ui.invoicing.events.platform_deposited"))
    page.should_not contain(">platform_deposited<")
    # Jamais de second original : la copie est proposée par défaut,
    # l'original présenté comme archive à ne pas transmettre (D-CPY-010).
    page.should contain(HTML.escape(I18n.t("ui.invoicing.download_original_archived")))
    page.should_not contain(">#{HTML.escape(I18n.t("ui.invoicing.download_pdf"))}<")
  end

  it "propose le PDF original tant que la facture n'est pas déposée" do
    browser = Books.admin
    invoice = issued_invoice
    page = browser.get("/invoicing/documents/#{invoice.id}").html
    page.should contain(HTML.escape(I18n.t("ui.invoicing.download_pdf")))
    page.should_not contain(HTML.escape(I18n.t("ui.invoicing.download_original_archived")))
  end

  it "a un libellé d'historique, dans chaque langue livrée, pour toute action tracée par la Facturation" do
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        Inv::DOCUMENT_EVENT_ACTIONS.each do |action|
          I18n.t("ui.invoicing.events.#{action}", default: "").should_not be_empty
        end
      end
    end
  end

  it "traduit le motif d'échec avec son détail ; garde tel quel un ancien message du serveur" do
    display = PartiduoUi::ChannelDisplay
    display.copy_error("invoicing.errors.mail.delivery_failed", "421 plus tard")
      .should eq(I18n.t("invoicing.errors.mail.delivery_failed", {"error" => "421 plus tard"}))
    display.copy_error("invoicing.errors.pdf_copy.render_failed", "police absente").should contain("police absente")
    display.copy_error("421 serveur occupé").should eq("421 serveur occupé")
  end

  it "n'offre ni copie ni envoi de copie hors plateforme ; affiche le canal Chorus Pro" do
    browser = Books.admin
    invoice = issued_invoice(channel: "public_portal")
    invoice.issue_channel.should eq("public_portal")
    page = browser.get("/invoicing/documents/#{invoice.id}").html
    page.should contain("Chorus Pro")
    page.should_not contain("/invoicing/documents/#{invoice.id}/pdf-copy")
    page.should_not contain("/invoicing/documents/#{invoice.id}/send-pdf-copy")
    browser.get("/invoicing/documents/#{invoice.id}/pdf-copy").status.should eq(404)
  end

  it "réserve l'envoi de la copie au droit d'envoi" do
    Books.admin
    invoice = issued_invoice
    reader = restricted_browser(%w[invoicing.invoice.read])
    page = reader.get("/invoicing/documents/#{invoice.id}").html
    page.should contain("/invoicing/documents/#{invoice.id}/pdf-copy")
    page.should_not contain("/invoicing/documents/#{invoice.id}/send-pdf-copy")
    reader.post("/invoicing/documents/#{invoice.id}/send-pdf-copy").status.should eq(403)
  end
end

describe "Saisie express d'un particulier : cas limites (lot C)" do
  it "explique l'absence de catégorie de clients" do
    browser = Books.admin
    Cards.categories(Books.system, "customer").each { |category| Cards.delete_category(Books.system, category.id).value! }
    refused = browser.htmx_post("/invoicing/express-customer", {"express_name" => "Jeanne Martin"})
    refused.status.should eq(200)
    refused.content.should contain(HTML.escape(I18n.t("cards.errors.card.category_id.no_customer_category")))
    refused.content.should_not contain("cards.errors.")
  end

  it "refuse un courriel invalide et un utilisateur sans droit d'écriture sur les fiches" do
    browser = Books.admin
    refused = browser.htmx_post("/invoicing/express-customer", {"express_name" => "Jeanne", "express_email" => "x"})
    refused.content.should contain(HTML.escape(I18n.t("cards.errors.card.email.invalid")))
    Cards.cards(Books.system, Cards::CardQuery.new(search: "Jeanne")).should be_empty

    clerk = restricted_browser(%w[invoicing.invoice.read invoicing.invoice.write])
    clerk.htmx_post("/invoicing/express-customer", {"express_name" => "Paul"}).status.should eq(403)
    Cards.cards(Books.system, Cards::CardQuery.new(search: "Paul")).should be_empty
  end
end
