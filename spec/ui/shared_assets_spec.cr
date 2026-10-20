# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "digest/sha256"

# Pages d'accès communes avec partiduo-admin : une seule définition des
# styles et des ressources, ici (interface de référence). partiduo-admin en
# garde une copie octet pour octet (`src/admin/assets/admin/…`), vérifiée
# par les mêmes empreintes dans son `spec/admin/shared_assets_spec.cr`.
# Après une modification : recopier le fichier dans partiduo-admin, puis
# mettre à jour l'empreinte dans les deux specs.
private SHARED_ASSETS = {
  "css/theme.css"        => "5a8f121b0bb22b3b6dbbd0d6d63fe5ba2071ff3474ade41513c06d0bf99648cf",
  "css/access.css"       => "7dd4e486308843f0cbfe8ff66867aa92df3e13cbe563dd15311dc8ecf5e19ab5",
  "css/bulma.min.css"    => "67fa26df1ca9e95d8f2adc7c04fa1b15fa3d24257470ebc10cc68b9aab914bee",
  "css/fonts.css"        => "28df0b5dad4409d1418e5b85a8c66d213cb8b7d38ccf01580017fac9d1967a1b",
  "icons/sprite.svg"     => "7e1ea6fe359c74727610d12f8c6d42877196bd987304c528b60054583a94277d",
  "brand/logo.svg"       => "5363f214ca835500e709a9385be2a544504aabd5f419d4fa73f26341a8426d49",
  "brand/aloli-logo.svg" => "b4860a1ff076eefaf1762a74ba3366ede980728c04a8216d2248f2ad75b8d042",
}

describe "Fichiers communs avec partiduo-admin (pages d'accès)" do
  SHARED_ASSETS.each do |file, digest|
    it "garde #{file} identique à la copie de partiduo-admin (empreinte SHA-256)" do
      path = PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", file)
      Digest::SHA256.hexdigest(File.read(path)).should eq(digest)
    end
  end

  it "les compare octet pour octet à la copie de travail voisine de partiduo-admin, si elle est là" do
    admin = PartiduoUi::SpecSupport.path("..", "partiduo-admin", "src", "admin", "assets", "admin")
    next unless Dir.exists?(admin)
    SHARED_ASSETS.each_key do |file|
      {file, File.read(File.join(admin, file))}.should eq({file, File.read(PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", file))})
    end
  end
end
