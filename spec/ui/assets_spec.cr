# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Fichiers statiques servis par Marten" do
  {
    "ui/css/bulma.min.css"               => "text/css",
    "ui/css/theme.css"                   => "text/css",
    "ui/css/fonts.css"                   => "text/css",
    "ui/css/access.css"                  => "text/css",
    "ui/css/app.css"                     => "text/css",
    "ui/js/htmx.min.js"                  => "javascript",
    "ui/js/opal/demo.js"                 => "javascript",
    "ui/js/shell.js"                     => "javascript",
    "ui/js/passkey.js"                   => "javascript",
    "ui/icons/sprite.svg"                => "image/svg+xml",
    "ui/fonts/IBMPlexSans-Regular.woff2" => "font/woff2",
    "ui/fonts/IBMPlexMono-Regular.woff2" => "font/woff2",
  }.each do |asset, content_type|
    it "sert #{asset}" do
      response = Marten::Spec.client.get("/assets/#{asset}")
      response.status.should eq(200)
      response.content_type.should contain(content_type)
      response.content.bytesize.should eq(File.size(PartiduoUi::SpecSupport.path("src", "ui", "assets", asset)))
    end
  end

  it "refuse un fichier absent" do
    Marten::Spec.client.get("/assets/ui/js/absent.js").status.should eq(404)
  end

  it "embarque Bulma 1.x et HTMX 2.x" do
    File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "bulma.min.css")).should match(/bulma\.io v1\.\d+\.\d+/)
    File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "js", "htmx.min.js")).should match(/version:"2\.\d+\.\d+"/)
  end

  it "définit la charte dans theme.css, avec les polices IBM Plex (ADR-005 D5, D7)" do
    theme = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "theme.css"))
    theme.should contain(%(--bulma-family-primary: "IBM Plex Sans"))
    theme.should contain(%(--bulma-family-code: "IBM Plex Mono"))
    # Texte blanc sur les boutons `is-primary` au thème clair (contraste
    # WCAG 1.4.3), foncé au thème sombre.
    theme.should contain("--bulma-primary-invert-l: 100%;")
    theme.scan("--bulma-primary-invert-l: 6%;").size.should eq(2)
    fonts = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "fonts.css"))
    fonts.scan(/url\("\.\.\/fonts\/([^"]+)"\)/).each do |match|
      File.exists?(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "fonts", match[1])).should be_true
    end
  end

  it "fait défiler les tableaux larges dans leur cadre, jamais la page (.pd-scroll de la maquette)" do
    app = File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "css", "app.css"))
    app.should match(/\.pd-scroll \{[^}]*overflow-x: auto/)
  end
end
