# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "json"

# Identité visuelle (partiduo-docs/identite) : favicons, manifeste web,
# couleur du navigateur, marque de la barre supérieure et des pages hors
# connexion.

private BRAND = PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "brand")

# Largeur et hauteur d'un PNG, lues dans son en-tête IHDR.
private def png_size(path : String) : {Int32, Int32}
  bytes = File.read(path).to_slice
  {IO::ByteFormat::BigEndian.decode(Int32, bytes[16, 4]), IO::ByteFormat::BigEndian.decode(Int32, bytes[20, 4])}
end

# Tailles des images d'un fichier ICO, lues dans son répertoire (0 vaut 256).
private def ico_sizes(path : String) : Array(Int32)
  bytes = File.read(path).to_slice
  count = IO::ByteFormat::LittleEndian.decode(UInt16, bytes[4, 2])
  (0...count).map do |index|
    width = bytes[6 + index * 16].to_i
    width.zero? ? 256 : width
  end
end

private def check_head(html : String) : Nil
  html.should contain(%(<link rel="icon" href="/assets/ui/brand/favicon.ico" sizes="32x32">))
  html.should contain(%(<link rel="icon" href="/assets/ui/brand/favicon.svg" type="image/svg+xml">))
  html.should contain(%(<link rel="apple-touch-icon" href="/assets/ui/brand/apple-touch-icon.png">))
  html.should contain(%(<link rel="manifest" href="/assets/ui/brand/manifest.webmanifest">))
  html.should contain(%(<meta name="theme-color" content="#0f5d70" media="(prefers-color-scheme: light)">))
  html.should contain(%(<meta name="theme-color" content="#0f1719" media="(prefers-color-scheme: dark)">))
end

# Le symbole est décoratif (alt vide) : le nom, en texte, nomme la marque une
# seule fois pour les lecteurs d'écran.
private def check_auth_brand(html : String) : Nil
  check_head(html)
  brand = html.match!(/<div class="pd-auth-brand">.*?<\/div>/m)[0]
  brand.should contain(%(<img class="pd-logo" src="/assets/ui/brand/logo.svg" alt="" width="56" height="56">))
  brand.should contain(%(<b class="pd-name">Parti<span>duo</span></b>))
  brand.should contain("comptabilité libre")
  # Dans l'en-tête (repère banner), avant le contenu principal.
  html.index!(brand).should be < html.index!(%(<main class="pd-auth"))
  html.index!(brand).should be > html.index!(%(<header class="pd-auth-top">))
end

describe "Identité visuelle : favicons et marque" do
  it "sert les favicons, les icônes et le manifeste, chacun avec son type" do
    {
      "favicon.svg"          => "image/svg+xml",
      "favicon.ico"          => "image/x-icon",
      "apple-touch-icon.png" => "image/png",
      "icon-192.png"         => "image/png",
      "icon-512.png"         => "image/png",
      "logo.svg"             => "image/svg+xml",
      "manifest.webmanifest" => "application/manifest+json",
    }.each do |file, content_type|
      response = Marten::Spec.client.get("/assets/ui/brand/#{file}")
      response.status.should eq(200), file
      response.content_type.should contain(content_type)
      response.content.bytesize.should eq(File.size(File.join(BRAND, file)))
    end
  end

  it "fournit les favicons aux tailles attendues" do
    ico_sizes(File.join(BRAND, "favicon.ico")).should eq([16, 32, 48])
    png_size(File.join(BRAND, "apple-touch-icon.png")).should eq({180, 180})
    png_size(File.join(BRAND, "icon-192.png")).should eq({192, 192})
    png_size(File.join(BRAND, "icon-512.png")).should eq({512, 512})
    File.read(File.join(BRAND, "favicon.svg")).should contain(%(viewBox="0 0 32 32"))
  end

  it "décrit l'application dans le manifeste web, avec des icônes présentes" do
    manifest = JSON.parse(File.read(File.join(BRAND, "manifest.webmanifest")))
    manifest["name"].as_s.should eq("Partiduo")
    manifest["start_url"].as_s.should eq("/")
    manifest["theme_color"].as_s.should eq("#0f5d70")
    manifest["icons"].as_a.map(&.["sizes"].as_s).should eq(["192x192", "512x512", "any"])
    manifest["icons"].as_a.each do |icon|
      File.exists?(File.join(BRAND, icon["src"].as_s)).should be_true
    end
  end

  it "pose favicons et marque dans la barre supérieure, lien vers l'accueil" do
    PartiduoUi::Accounts.create
    html = PartiduoUi::Accounts.signed_in.get("/").html
    check_head(html)
    html.should contain(%(<a class="pd-brand" href="/"><img class="pd-logo" src="/assets/ui/brand/favicon.svg" alt="" width="32" height="32"><b class="pd-name">Parti<span>duo</span></b><small>comptabilité libre</small></a>))
  end

  it "garde la marque dans le mode simplifié" do
    browser = PartiduoUi::Books.admin
    Partiduo::Api::Modules.deactivate(PartiduoUi::Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(PartiduoUi::Books.system, "ACCOUNTING").success?.should be_true
    Partiduo::Api::Modules.activate(PartiduoUi::Books.system, "MICRO").success?.should be_true
    Partiduo::Api::Micro.load_defaults(PartiduoUi::Books.system)
    html = browser.get("/").html
    html.should contain("pd-simple")
    check_head(html)
    html.should contain(%(<a class="pd-brand" href="/"><img class="pd-logo"))
  end

  it "centre le logo et le nom en haut des pages hors connexion" do
    %w[/login /password/forgotten /unlock].each do |path|
      check_auth_brand(PartiduoUi::Browser.new.get(path).html)
    end
  end

  it "centre le logo et le nom en haut des pages d'erreur" do
    PartiduoUi::Accounts.create
    response = PartiduoUi::Accounts.signed_in.get("/ext/UITEST/")
    response.status.should eq(404)
    check_auth_brand(response.html)
  end

  it "règle les couleurs du nom pour les thèmes clair et sombre" do
    theme = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "theme.css"))
    theme.should contain("--pd-brand-parti: #0f5d70;")
    theme.should contain("--pd-brand-duo: #1c8aa5;")
    theme.scan("--pd-brand-parti: #e3eced;").size.should eq(2)
    theme.scan("--pd-brand-duo: #5cc3dc;").size.should eq(2)
  end
end
