# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Heure du dossier partout (13 octobre 2026) : les horodatages du cœur sont
# en UTC ; chaque écran les présente dans le fuseau du dossier
# (`Partiduo::Api::Core.time_zone`, `Format#datetime`,
# `Format#timestamp_date`), jamais en UTC ni dans le fuseau du serveur.
# Horodatage d'épreuve : 23 h 30 UTC le 9 mars 2026, soit 0 h 30 le 10 mars
# à Paris (fuseau par défaut, UTC+1 en mars).

private alias Books = PartiduoUi::Books
private alias Acc = Partiduo::Api::Accounting
private alias Auth = Partiduo::Api::Auth
private alias Liberal = Partiduo::Api::Liberal

private MOMENT     = "2026-03-09 23:30:00+00"
private LOCAL_TEXT = "10/03/2026 00:30"
private UTC_TEXT   = "09/03/2026 23:30"
private LOCAL_DAY  = "10/03/2026"
private UTC_DAY    = "09/03/2026"

private def sql(statement : String, *args) : Nil
  Marten::DB::Connection.default.open(&.exec(statement, *args))
end

private def alice : Auth::UserView
  Auth.users(Books.system).find! { |user| user.email == "alice@example.com" }
end

private def shows_local_time(html : String) : Nil
  html.should contain(LOCAL_TEXT)
  html.should_not contain(UTC_TEXT)
end

private def shows_local_day(html : String) : Nil
  html.should contain(LOCAL_DAY)
  html.should_not contain(UTC_DAY)
end

describe "Heure du dossier dans les écrans" do
  it "fixe le fuseau d'épreuve" do
    Partiduo::Api::Core.time_zone.name.should eq("Europe/Paris")
  end

  it "présente la dernière connexion dans la liste et la fiche des utilisateurs" do
    browser = Books.admin
    sql("UPDATE auth_user SET last_login_at = $1::timestamptz", MOMENT)
    shows_local_time(browser.get("/settings/users").html)
    shows_local_time(browser.get("/settings/users/#{alice.id}").html)
  end

  it "présente le journal d'audit à l'heure du dossier" do
    browser = Books.admin
    # Journal en ajout seul : un événement daté de l'instant d'épreuve.
    sql("INSERT INTO auth_audit_event (user_label, action, module_code, state, ip, detail, created_at) " \
        "VALUES ('Épreuve', 'user.login', 'AUTH', 'SUCCESS', '', '', $1::timestamptz)", MOMENT)
    shows_local_time(browser.get("/settings/audit").html)
  end

  it "présente l'échéance d'une invitation à l'heure du dossier" do
    browser = Books.admin
    response = browser.post("/settings/users/#{alice.id}/access/invite")
    response.status.should eq(302)
    page = browser.follow(response).html
    expires = Marten::DB::Connection.default.open do |db|
      db.scalar("SELECT expires_at FROM auth_token WHERE purpose = 'invitation' ORDER BY id DESC LIMIT 1").as(Time)
    end
    fmt = PartiduoUi::Format.new("fr", "FR")
    # L'heure du jeton ne se choisit pas : Paris a une ou deux heures d'avance sur UTC.
    page.should contain("valable jusqu'au #{fmt.datetime(expires)}")
    page.should_not contain("valable jusqu'au #{fmt.datetime(expires, Time::Location::UTC)}")
  end

  it "présente l'échéance du courriel d'invitation à l'heure du dossier, fuseau nommé" do
    email = PartiduoUi::TokenEmail.new("bob@example.com", "invitation", "https://demo.partiduo.localhost/i/x",
      Time.utc(2026, 3, 9, 23, 30), PartiduoUi::Format.new("fr", "FR"))
    body = email.text_body.to_s
    body.should contain("Ce lien expire le #{LOCAL_TEXT} (fuseau Europe/Paris).")
    body.should_not contain("UTC")
  end

  it "présente la dernière utilisation d'une identité fédérée à l'heure du dossier" do
    browser = Books.admin
    issuer = "https://login.cabinet.test"
    browser.post("/settings/identity-providers/new", {
      "kind" => "oidc", "code" => "cabinet", "name" => "Cabinet", "level" => "2", "active" => "1",
      "settings.issuer" => issuer, "settings.authorization_endpoint" => "#{issuer}/authorize",
      "settings.token_endpoint" => "#{issuer}/token", "settings.jwks_uri" => "#{issuer}/keys",
      "settings.client_id" => "partiduo", "settings.client_secret" => "s3cret",
      "settings.redirect_uri" => "https://demo.partiduo.localhost/login/federated/cabinet/callback",
    }).status.should eq(302)
    browser.post("/settings/users/#{alice.id}/identities", {"provider" => "cabinet", "subject" => "sub-42"}).status.should eq(302)
    sql("UPDATE auth_federated_identity SET last_used_at = $1::timestamptz", MOMENT)
    shows_local_time(browser.get("/settings/users/#{alice.id}/identities").html)
  end

  it "présente la date de création d'un rapprochement dans la liste et son heure dans le relevé" do
    browser = Books.admin
    customer = Books.card("CUSTOMER", "Client Morel")
    entry = Books.receipt(customer.code, "1200", "2026-03-20").first
    f01 = Books.ledger("F01").id
    statement = Acc.reconcile(Books.system, Acc::ReconcileInput.new(f01, "R-03", [entry.id])).value!
    sql("UPDATE accounting_bank_statement SET created_at = $1::timestamptz", MOMENT)
    shows_local_day(browser.get("/accounting/reconciliation?ledger=#{f01}").html)
    shows_local_time(browser.get("/accounting/reconciliation/statements/#{statement.id}").html)
  end

  it "présente les dates de création et de modification d'une fiche à l'heure du dossier" do
    browser = Books.admin
    card = Books.card("CUSTOMER", "Client Morel")
    sql("UPDATE cards_card SET created_at = $1::timestamptz, updated_at = $1::timestamptz", MOMENT)
    shows_local_day(browser.get("/cards/#{card.id}").html)
  end

  it "présente les dates d'une clé d'accès (passkey) à l'heure du dossier" do
    browser = Books.admin
    sql("INSERT INTO auth_passkey (user_id, credential_id, public_key, cose_algorithm, name, created_at, last_used_at) " \
        "VALUES ($1, 'cle-epreuve', 'cle', -7, 'Clé d''épreuve', $2::timestamptz, $2::timestamptz)", alice.id, MOMENT)
    page = browser.get("/account/security").html
    page.should contain(%(value="Clé d'épreuve"))
    shows_local_day(page)
  end

  it "présente la date de modification et de figement d'une ligne et d'une immobilisation libérales" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
    Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
    Liberal.load_defaults(Books.system)
    PartiduoUi::Reference.fiscal_year(2025)
    rent = Liberal.natures(Books.system).find! { |item| item.code == "RENT" }
    old = Liberal.record_expense(Books.system, Liberal::LineInput.new(date: Books.date("2025-11-10"), nature_id: rent.id,
      amount: Books.d("900"), method: "transfer", party_name: "SCI du Parc")).value!
    line = Liberal.record_expense(Books.system, Liberal::LineInput.new(date: Books.date("2026-02-10"), nature_id: rent.id,
      amount: Books.d("950"), method: "transfer", party_name: "SCI du Parc")).value!
    asset = Liberal.record_asset(Books.system, Liberal::AssetInput.new(label: "Table de massage", category: "equipment",
      acquired_on: Books.date("2026-04-01"), amount: Books.d("3000"), duration_years: 5, method: "transfer")).value!
    sql("UPDATE liberal_line SET modified_at = $1::timestamptz WHERE id = $2", MOMENT, line.id)
    sql("UPDATE liberal_asset SET modified_at = $1::timestamptz WHERE id = $2", MOMENT, asset.id)
    # 2035 de 2025 transmise à l'instant d'épreuve : exercice verrouillé.
    sql("INSERT INTO liberal_year (year, state, closed_at, transmitted_at, reference, transmitted_fingerprint, " \
        "frozen_fingerprint) VALUES (2025, 'locked', $1::timestamptz, $1::timestamptz, 'teledec:1', '', '')", MOMENT)

    shows_local_day(browser.get("/liberal/lines/#{line.id}").html)
    asset_page = browser.get("/liberal/assets/#{asset.id}").html
    asset_page.should contain("Modifiée le")
    shows_local_day(asset_page)
    shows_local_day(browser.get("/liberal/lines/#{old.id}").html)
  end

  it "nomme un export et propose le premier exercice d'après la date du jour du dossier" do
    # L'horloge du cœur ne se règle pas depuis l'interface (contrat seul,
    # ADR-005 D3) : la date attendue est celle du jour du dossier.
    browser = Books.admin
    today = Partiduo::Api::Core.today
    csv = browser.get("/settings/users?format=csv")
    csv.headers["Content-Disposition"].should contain("-#{today.to_s("%Y%m%d")}.csv")
    Partiduo::Api::Core.fiscal_years(Books.system).each do |year|
      Partiduo::Api::Core.delete_fiscal_year(Books.system, year.id).value!
    end
    browser.get("/fiscal-years").html.should contain(%(name="year" value="#{today.year}"))
  end
end
