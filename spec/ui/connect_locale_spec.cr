# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Langue tenue par connect (D-UI-082) : une session ouverte par connect est
# dans la langue du compte connect (`SessionView#locale_from_connect`, claim
# `locale` repris par le cœur à chaque connexion : spec/auth/connect_spec.cr
# de partiduo-app), avant le cookie de langue et le navigateur ; un compte
# connect sans langue suit le navigateur, puis la langue du dossier. Une
# autre session garde l'ordre d'avant : cookie, langue de l'utilisateur,
# navigateur, dossier. L'interface ne remplace pas le transport OpenID
# Connect du cœur (ADR-005 D3) : le choix est contrôlé sur les vues du
# contrat.

private alias Locale = PartiduoUi::Locale

private def session(locale : String, connect : Bool) : Partiduo::Api::Auth::SessionView
  Partiduo::Api::Auth::SessionView.new(user_id: 1_i64, email: "alice@example.com", full_name: "Alice Martin",
    locale: locale, role: "member", method: connect ? "federated" : "password", level: 2, required_level: 2,
    elevation_required: false, suggest_passkey: false, expires_at: Time.utc + 1.hour, locale_from_connect: connect)
end

private def resolve(session : Partiduo::Api::Auth::SessionView?, cookie : String?, header : String,
                    dossier : String = "nl") : String?
  Locale.resolve(session, cookie, header) { dossier }
end

describe "Langue d'une session ouverte par connect (D-UI-082)" do
  it "prend la langue du compte connect, que ni le cookie ni le navigateur ni le dossier ne contredisent" do
    connect = session("de", connect: true)
    [{nil, "fr"}, {"pt", "es-ES"}, {"en", "it,en;q=0.5"}, {nil, ""}].each do |(cookie, header)|
      {cookie, header, resolve(connect, cookie, header)}.should eq({cookie, header, "de"})
    end
  end

  it "suit chaque changement fait dans connect, repris par la session suivante" do
    %w[it pt es].each { |locale| resolve(session(locale, connect: true), "fr", "fr").should eq(locale) }
  end

  it "suit le navigateur, puis la langue du dossier, pour un compte connect sans langue" do
    connect = session("", connect: true)
    resolve(connect, "pt", "es-ES,es;q=0.9").should eq("es")
    resolve(connect, "pt", "pl").should eq("nl")
    resolve(connect, nil, "", dossier: "fr").should eq("fr")
  end

  it "garde l'ordre d'avant pour une session sans connect : cookie, utilisateur, navigateur, dossier" do
    local = session("de", connect: false)
    resolve(local, "pt", "es").should be_nil # cookie de langue livrée : celui de Marten
    resolve(local, nil, "es").should eq("de")
    resolve(nil, nil, "es").should be_nil # navigateur : langue de Marten
    resolve(nil, "pl", "pl").should eq("nl")
  end

  it "ne lit la langue du dossier que si elle sert" do
    read = 0
    Locale.resolve(session("de", connect: true), nil, "") { read += 1; "nl" }.should eq("de")
    Locale.resolve(nil, nil, "it") { read += 1; "nl" }.should be_nil
    read.should eq(0)
  end

  it "mène à la page du compte connect pour régler la langue, quand connect est réglé" do
    Partiduo::Api::Auth.connect_account_url.should be_nil
    ENV["PARTIDUO_CONNECT_URL"] = "https://connect.partiduo.localhost/"
    ENV["PARTIDUO_CONNECT_CLIENT_ID"] = "demo"
    ENV["PARTIDUO_CONNECT_CLIENT_SECRET"] = "secret"
    begin
      Partiduo::Api::Auth.connect_account_url.should eq("https://connect.partiduo.localhost/account")
    ensure
      %w[PARTIDUO_CONNECT_URL PARTIDUO_CONNECT_CLIENT_ID PARTIDUO_CONNECT_CLIENT_SECRET].each { |name| ENV.delete(name) }
    end
  end
end
