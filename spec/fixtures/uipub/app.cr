# SPDX-License-Identifier: AGPL-3.0-or-later

# Extension factice « UIPUB » : routes publiques montées sous /p/uipub/
# (A-FRM-1) et opération soumise à approbation (A-SEPA-3), telles que les
# déclarerait un dépôt `partiduo-<nom>`.
Partiduo::Modules.register do
  code "UIPUB"
  version "0.1.0"
  permission "uipub.batch.approve"
end

module UiPub
  # Application Marten de l'extension : ses libellés (`locales/`).
  class App < Marten::App
    label "uipub"
  end

  # Page publique : écho du jeton ; garde son propre `Cache-Control`.
  class HelloHandler < Marten::Handlers::Base
    def get
      response = respond("bonjour #{params["token"]?}")
      response.headers["Cache-Control"] = "no-store, private"
      response
    end

    def post
      respond("reçu #{params["token"]?}")
    end
  end

  PUBLIC_ROUTES = Marten::Routing::Map.draw do
    path "/hello/<token:str>", HelloHandler, name: "hello"
    path "/open", HelloHandler, name: "open"
  end
end

PartiduoUi::Extensions.public_mount "UIPUB", UiPub::PUBLIC_ROUTES,
  rate_limits: {"hello" => PartiduoUi::RateLimit::Rule.new(2, 1.minute)}, max_body_bytes: 100_i64

Marten.configure :test do |config|
  config.installed_apps = config.installed_apps + [UiPub::App] of Marten::Apps::Config.class
end
