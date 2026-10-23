# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Retours de marchandises et paiements rejetés (DECISIONS D-INV3-012) : bon
# de retour saisi depuis un bon de livraison, « Bons à facturer » (lignes
# négatives, avoir des retours cochés), « Faire l'avoir », rubrique client ;
# rejet d'un règlement (formulaire, erreurs, frais refacturés), règlement
# barré, « À traiter » ; droits ; accessibilité.

private alias Inv = Partiduo::Api::Invoicing
private alias Books = PartiduoUi::Books
private alias Cards = Partiduo::Api::Cards

private def customer(name : String, code : String) : Cards::CardView
  category = PartiduoUi::Reference.category("CUSTOMER")
  input = Cards::CardInput.new(category_id: category.id, name: name, code: code, siren: "443061841",
    address: Cards::AddressInput.new(line1: "3 rue du Port", postcode: "44100", city: "Nantes", country_code: "FR"))
  Cards.create_card(Books.system, input).value!
end

private def item : Cards::CardView
  rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
  input = Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil (heure)",
    code: "CONSEIL", unit_code: "HUR", sale_price: Books.d("80"), vat_rate_id: rate.id)
  Cards.create_card(Books.system, input).value!
end

private def lines(article : Cards::CardView, hours : String) : Array(Inv::LineInput)
  [Inv::LineInput.new(kind: "item", item_card_id: article.id, quantity: Books.d(hours))]
end

# Document émis le `day` : `hours` heures de conseil (80 € HT l'heure).
private def issued(kind : String, client : Cards::CardView, article : Cards::CardView, day : String,
                   hours : String = "1") : Inv::DocumentView
  input = Inv::DocumentInput.new(kind: kind, customer_card_id: client.id, lines: lines(article, hours),
    return_reason: kind == "return_note" ? "excess" : nil)
  draft = Inv.create_document(Books.system, input).value!
  Inv.issue(Books.system, draft.id, Inv::IssueInput.new(issue_date: Books.date(day))).value!
end

private def card_path(id : Int64) : String
  Marten.routes.reverse("cards:show", id: id)
end

private def amount(text : String) : String
  PartiduoUi::Format.new("fr").amount(Books.d(text))
end

private def without_accounting : Nil
  Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC")
  Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING")
end

describe "Retours de marchandises (D-INV3-012)" do
  it "saisit et émet un bon de retour depuis un bon de livraison, le déduit dans « Bons à facturer »" do
    browser = Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    article = item
    note = issued("delivery_note", client, article, "2026-09-03", "3")

    page = browser.get("/invoicing/documents/#{note.id}").html
    page.should contain("Créer un bon de retour")
    transformed = browser.post("/invoicing/documents/#{note.id}/transform?kind=return_note")
    transformed.status.should eq(302)
    edit_path = transformed.headers["Location"]
    draft_id = edit_path.split('/')[-2].to_i64
    edit = browser.get(edit_path).html
    edit.should contain(%(name="return_reason"))
    edit.should contain(%(<label class="label" for="pd-d-reason">Motif du retour))
    edit.should contain("Marchandise endommagée")
    edit.should contain("Date du retour")
    edit.should_not contain(%(name="payment_terms"))
    edit.should_not contain(%(name="issue_channel"))
    edit.should contain(%(name="line-0-return_note"))

    # Motif absent : l'émission est refusée en toutes lettres.
    refused = browser.post("/invoicing/documents/#{draft_id}/issue")
    browser.follow(refused).html.should contain("Indiquez le motif du retour avant d'émettre")
    values = {"kind" => "return_note", "customer" => "CLI-MOREL", "line-0-item" => "CONSEIL"}
    too_many = browser.post("/invoicing/documents/#{draft_id}/edit", values.merge({"line-0-quantity" => "5", "return_reason" => "damaged"}))
    too_many.status.should eq(422)
    too_many.html.should contain("retour au-delà de la quantité de #{note.number}")
    browser.post("/invoicing/documents/#{draft_id}/edit", values.merge({"line-0-quantity" => "1", "return_reason" => "damaged"}))
      .status.should eq(302)
    browser.post("/invoicing/documents/#{draft_id}/issue").status.should eq(302)
    returned = Inv.document(Books.system, draft_id)
    returned.draft?.should be_false
    shown = browser.get("/invoicing/documents/#{draft_id}").html
    shown.should contain("Motif du retour")
    shown.should contain("Marchandise endommagée")
    shown.should contain("Issu du bon de livraison #{note.number}")
    shown.should contain("Faire l'avoir")

    listing = browser.get("/invoicing/to-invoice").html
    listing.should contain(returned.number.to_s)
    listing.should contain(%(<p class="is-size-7 pd-ti-kind is-return">Bon de retour</p>))
    listing.should contain("Issu de : Bon de livraison #{note.number}")
    listing.should contain(amount("-80"))
    listing.should contain(%(aria-label="Sélectionner : Bon de retour #{returned.number}"))
    listing.should contain("Faire l'avoir des retours cochés")
    listing.should contain("Tous les bons de retour")
    browser.get("/invoicing/documents?kind=return_note").html.should contain("Nouveau bon de retour")

    card = browser.get(card_path(client.id)).html
    card.should contain("Retours à reprendre")
    card.should contain("1 bon de retour · 80,00 HT EUR, déduit de l'encours")

    # Livraison et retour cochés : facture dont le retour est déduit.
    response = browser.perform_raw("/invoicing/to-invoice", "note=#{note.id}&note=#{returned.id}")
    response.status.should eq(302)
    invoice = Inv.document(Books.system, PartiduoUi::Reference.id_from(response.headers["Location"]))
    invoice.kind.should eq("invoice")
    invoice.return_notes.map(&.id).should eq([returned.id])
    invoice.totals.total_net.should eq(Books.d("160"))
    browser.follow(response).html.should contain("Bon de retour #{returned.number} · rapporté le")
    browser.get("/invoicing/documents/#{invoice.id}/edit").html.should contain(%(value="#{returned.id}"))
    browser.post("/invoicing/documents/#{invoice.id}/issue").status.should eq(302)
    settled = browser.get("/invoicing/documents/#{returned.id}").html
    settled.should contain("Repris")
    settled.should contain("Repris par")
    settled.should_not contain("Faire l'avoir")
  end

  it "fait l'avoir d'un bon de retour et des retours cochés, demande la facture à créditer s'il n'y en a pas" do
    browser = Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    article = item
    invoice = issued("invoice", client, article, "2026-09-02", "5")
    first = issued("return_note", client, article, "2026-09-05")
    second = issued("return_note", client, article, "2026-09-06")
    third = issued("return_note", client, article, "2026-09-07")

    response = browser.post("/invoicing/to-invoice/credit-returns?note=#{first.id}&from=document")
    response.status.should eq(302)
    credit = Inv.document(Books.system, PartiduoUi::Reference.id_from(response.headers["Location"]))
    credit.kind.should eq("credit_note")
    credit.return_notes.map(&.id).should eq([first.id])
    credit.credited.try(&.id).should eq(invoice.id)
    browser.follow(response).html.should contain("Brouillon d'avoir créé pour 1 bon de retour.")
    page = browser.get("/invoicing/documents/#{first.id}").html
    page.should contain("Repris par")
    browser.get("/invoicing/to-invoice").html.should contain("Repris dans un brouillon</a>")

    checked = browser.perform_raw("/invoicing/to-invoice/credit-returns", "note=#{second.id}&note=#{third.id}")
    checked.status.should eq(302)
    grouped = Inv.document(Books.system, PartiduoUi::Reference.id_from(checked.headers["Location"]))
    grouped.return_notes.map(&.id).should eq([second.id, third.id])

    # Un bon de livraison n'est pas un retour : refus sur la liste.
    note = issued("delivery_note", client, article, "2026-09-08")
    refused = browser.perform_raw("/invoicing/to-invoice/credit-returns", "note=#{note.id}")
    refused.status.should eq(422)
    refused.html.should contain("n'est pas un bon de retour émis")

    # Client sans facture : on ne peut pas faire d'avoir.
    other = customer("Menuiserie Roux", "CLI-ROUX")
    orphan = issued("return_note", other, article, "2026-09-08")
    none = browser.post("/invoicing/to-invoice/credit-returns?note=#{orphan.id}&from=document")
    none.status.should eq(422)
    none.html.should contain("aucune facture émise à créditer")

    # Facture trop petite : choix de la facture proposé.
    small = issued("invoice", other, article, "2026-09-09", "1")
    big = issued("return_note", other, article, "2026-09-10", "2")
    choose = browser.perform_raw("/invoicing/to-invoice/credit-returns", "note=#{big.id}")
    choose.status.should eq(422)
    choose.html.should contain(%(<label class="label" for="pd-f-credited-document-id">Facture à créditer))
    choose.html.should contain(%(<option value="#{small.id}" selected>#{small.number} du 09/09/2026))
    choose.html.should contain(%(name="notes" value="#{big.id}"))
  end

  it "fait un avoir récapitulatif quand les retours cochés l'emportent sur les livraisons" do
    browser = Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    article = item
    issued("invoice", client, article, "2026-09-01", "5")
    note = issued("delivery_note", client, article, "2026-09-03", "1")
    returned = issued("return_note", client, article, "2026-09-04", "3")
    response = browser.perform_raw("/invoicing/to-invoice", "note=#{note.id}&note=#{returned.id}")
    response.status.should eq(302)
    credit = Inv.document(Books.system, PartiduoUi::Reference.id_from(response.headers["Location"]))
    credit.kind.should eq("credit_note")
    browser.follow(response).html.should contain("Avoir récapitulatif créé pour 2 bons : les retours l'emportent sur les livraisons.")
  end

  it "réserve l'avoir des retours à qui peut saisir des documents" do
    Books.admin
    client = customer("Atelier Morel", "CLI-MOREL")
    returned = issued("return_note", client, item, "2026-09-05")
    profile = PartiduoUi::Accounts.profile("Lecteur", %w[invoicing.invoice.read cards.card.read])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    reader = PartiduoUi::Accounts.signed_in("bob@example.com")
    reader.post("/invoicing/to-invoice/credit-returns?note=#{returned.id}").status.should eq(403)
    reader.get("/invoicing/documents/#{returned.id}").html.should_not contain("Faire l'avoir")
  end
end

describe "Paiements rejetés (D-INV3-012)" do
  it "enregistre le rejet d'un règlement, barre le règlement, refacture les frais et alerte « À traiter »" do
    browser = Books.admin
    without_accounting
    client = customer("Atelier Morel", "CLI-MOREL")
    invoice = issued("invoice", client, item, "2026-09-02", "1") # 96,00 TTC
    payment = Inv.record_payment(Books.system, Inv::PaymentInput.new(invoice.id, Books.d("50"), Books.date("2026-09-10"),
      "cheque", "CHQ 123")).value!
    second = Inv.record_payment(Books.system, Inv::PaymentInput.new(invoice.id, Books.d("46"), Books.date("2026-09-11"))).value!
    rate = Partiduo::Api::Vat.create_rate(Books.system, Partiduo::Api::Vat::RateInput.new(code: "HC", label: "Hors champ",
      rate: Books.d("0"), category: "O", exemption_code: "VATEX-EU-O")).value!
    reject_path = "/invoicing/documents/#{invoice.id}/payments/#{payment.id}/reject"

    page = browser.get("/invoicing/documents/#{invoice.id}").html
    page.should contain(%(href="#{reject_path}" aria-label="Enregistrer un rejet du règlement du 10/09/2026 de 50,00"))
    received = browser.get("/invoicing/payments?view=received").html
    received.should contain("Règlements reçus")
    received.should contain("Encaissé")
    received.should contain(%(aria-label="Enregistrer un rejet du règlement du 10/09/2026 de 50,00, facture #{invoice.number}"))

    form = browser.get(reject_path).html
    form.should contain(%(<label class="label" for="pd-f-reason">Motif du rejet))
    form.should contain("Provision insuffisante")
    form.should contain(%(<option value="#{rate.id}" selected>))
    form.should contain("En principe hors champ de la TVA (indemnité), catégorie O ; facture à part.")
    form.should contain(%(<label class="checkbox pd-check" for="pd-f-rebill-fees">))
    form.should contain("La facture redevient due et une relance est proposée.")

    other = browser.post(reject_path, {"rejected_on" => "12/09/2026", "reason" => "other"})
    other.status.should eq(422)
    other.html.should contain("Précisez le motif")
    other.html.should contain(%(aria-invalid="true"))
    no_fees = browser.post(reject_path, {"rejected_on" => "12/09/2026", "reason" => "insufficient_funds", "rebill_fees" => "1",
                                         "fees_vat_rate_id" => rate.id.to_s})
    no_fees.status.should eq(422)
    no_fees.html.should contain("Indiquez les frais à refacturer")
    early = browser.post(reject_path, {"rejected_on" => "01/09/2026", "reason" => "insufficient_funds"})
    early.html.should contain("Le rejet ne précède pas le règlement (10/09/2026)")

    done = browser.post(reject_path, {"rejected_on" => "12/09/2026", "reason" => "insufficient_funds", "fees" => "15",
                                      "rebill_fees" => "1", "fees_vat_rate_id" => rate.id.to_s})
    done.status.should eq(302)
    done.headers["Location"].should eq("/invoicing/documents/#{invoice.id}")
    shown = browser.follow(done).html
    shown.should contain("Rejet du règlement de 50,00 enregistré : la facture #{invoice.number} redevient due (reste dû 50,00 EUR).")
    shown.should contain("Une relance est proposée.")
    shown.should contain("La facture des frais est en brouillon.")
    shown.should contain("<s>50,00</s>")
    shown.should contain("Rejeté le 12/09/2026 — Provision insuffisante")
    shown.should contain("Relance proposée")
    shown.should contain("Facture des frais refacturés")
    shown.should contain("Rejet d'un règlement")
    shown.should_not contain(%(href="#{reject_path}"))
    shown.should contain(%(href="/invoicing/documents/#{invoice.id}/payments/#{second.id}/reject"))

    rejection = Inv.payment_rejections(Books.system).first
    fees = Inv.document(Books.system, rejection.fees_invoice_id || raise "sans facture de frais")
    fees.draft?.should be_true
    fees.lines.first.unit_price.should eq(Books.d("15"))
    fees.lines.first.vat_category.should eq("O")

    browser.get(reject_path).status.should eq(302)
    struck = browser.get("/invoicing/payments?view=received").html
    struck.should contain("Rejeté le 12/09/2026 — Provision insuffisante")
    struck.should contain("pd-struck")
    browser.get("/invoicing/reminders").html.should contain("Suite à un rejet de paiement")

    todo = browser.get("/").html
    todo.should contain("1 paiement rejeté à régulariser")
    todo.should contain("Atelier Morel · #{invoice.number} · 50,00 EUR")
    Inv.update_customer_billing(Books.system, client.id, Inv::CustomerBillingInput.new("monthly", Books.d("1000"))).value!
    browser.get("/").html.should contain("fin de mois : encours HT")
    browser.get("/").html.should contain("/ plafond 1 000,00 EUR")

    # Comptabilité active : le rejet reste possible, l'aide le dit.
    Partiduo::Api::Modules.activate(Books.system, "ACCOUNTING")
    browser.get("/invoicing/documents/#{invoice.id}/payments/#{second.id}/reject").html
      .should contain("l'encaissement est contre-passé et les frais comptabilisés automatiquement")
  end

  it "refuse le rejet sans la permission d'enregistrer les règlements" do
    Books.admin
    without_accounting
    client = customer("Atelier Morel", "CLI-MOREL")
    invoice = issued("invoice", client, item, "2026-09-02", "1")
    payment = Inv.record_payment(Books.system, Inv::PaymentInput.new(invoice.id, Books.d("96"), Books.date("2026-09-10"))).value!
    profile = PartiduoUi::Accounts.profile("Vendeur", %w[invoicing.invoice.read invoicing.invoice.write cards.card.read])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    seller = PartiduoUi::Accounts.signed_in("bob@example.com")
    path = "/invoicing/documents/#{invoice.id}/payments/#{payment.id}/reject"
    seller.get(path).status.should eq(403)
    seller.post(path, {"rejected_on" => "12/09/2026", "reason" => "stopped"}).status.should eq(403)
    seller.get("/invoicing/documents/#{invoice.id}").html.should_not contain("Enregistrer un rejet")
    Inv.payments(Books.system, invoice.id).first.rejected?.should be_false
  end

  it "libelle le rejet dans l'historique à comptabiliser" do
    I18n.with_locale("fr") { I18n.t("ui.history.events.payment_rejected").should eq("Rejet de règlement") }
    Partiduo::LOCALES.reject("fr").each do |locale|
      I18n.with_locale(locale) { I18n.t("ui.invoicing.events.payment_rejected", default: "").should_not be_empty }
    end
  end
end
