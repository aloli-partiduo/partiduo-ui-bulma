# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Pages d'erreur rendues par Marten hors des handlers de l'interface :
# adresse sans route (404), en-tête refusé (400), exception (500), refus de
# la protection CSRF (formulaire expiré, 403). Sans gabarit, Marten renvoie
# un texte brut en anglais ; elles sont ici traduites dans chaque langue,
# sans « missing translation » ni clé brute.

private alias Translations = PartiduoUi::Translations

private TITLES = {
  "fr" => {404 => "Page introuvable", 400 => "Demande non valide", 403 => "Accès refusé", 500 => "Erreur du serveur"},
  "en" => {404 => "Page not found", 400 => "Bad request", 403 => "Access denied", 500 => "Server error"},
  "nl" => {404 => "Pagina niet gevonden", 400 => "Ongeldige aanvraag", 403 => "Toegang geweigerd", 500 => "Serverfout"},
  "de" => {404 => "Seite nicht gefunden", 400 => "Ungültige Anfrage", 403 => "Zugriff verweigert", 500 => "Serverfehler"},
  "es" => {404 => "Página no encontrada", 400 => "Solicitud no válida", 403 => "Acceso denegado", 500 => "Error del servidor"},
  "it" => {404 => "Pagina non trovata", 400 => "Richiesta non valida", 403 => "Accesso negato", 500 => "Errore del server"},
  "pt" => {404 => "Página não encontrada", 400 => "Pedido inválido", 403 => "Acesso recusado", 500 => "Erro do servidor"},
}

describe "Pages d'erreur de Marten" do
  it "traduit les pages des handlers d'erreur de Marten (400, 403, 404, 500) dans chaque langue" do
    handlers = {400 => Marten.settings.handler400, 403 => Marten.settings.handler403,
                404 => Marten.settings.handler404, 500 => Marten.settings.handler500}
    Translations::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        handlers.each do |status, handler|
          raw = ::HTTP::Request.new("GET", "/adresse-qui-n-existe-pas", ::HTTP::Headers{"Host" => "127.0.0.1"})
          response = handler.new(Marten::HTTP::Request.new(raw)).dispatch
          response.status.should eq(status)
          response.content_type.to_s.should contain("text/html")
          response.html.should contain(TITLES[locale][status])
          response.html.should contain(%(<html lang="#{locale}">))
          Translations.problems(response.content).should eq([] of String)
        end
      end
    end
  end

  it "rend le refus CSRF d'un formulaire par une page « formulaire expiré » traduite" do
    {"fr" => "Formulaire expiré", "en" => "Form expired", "nl" => "Formulier verlopen", "de" => "Formular abgelaufen",
     "es" => "Formulario caducado", "it" => "Modulo scaduto", "pt" => "Formulário expirado"}.each do |locale, title|
      client = Marten::Spec::Client.new(disable_request_forgery_protection: false)
      response = client.post("/login", data: {"email" => "alice@example.com", "password" => "x"},
        content_type: "application/x-www-form-urlencoded", headers: {"Accept-Language" => locale})
      response.status.should eq(403)
      response.content_type.to_s.should contain("text/html")
      response.html.should contain(title)
      Translations.problems(response.content).should eq([] of String)
    end
  end

  it "rend le refus CSRF d'une route publique d'extension sans lien vers le dossier" do
    PartiduoUi::Reference.provision
    Partiduo::Api::Modules.activate(Partiduo::Api::Actor.system, "UIPUB")
    client = Marten::Spec::Client.new(disable_request_forgery_protection: false)
    refused = client.post("/p/uipub/open", data: {"texte" => "x"}, headers: {"Accept-Language" => "nl"})
    refused.status.should eq(403)
    refused.html.should contain("Formulier verlopen")
    refused.html.should_not contain("href=\"/\"")
    Translations.problems(refused.content).should eq([] of String)
  end
end
