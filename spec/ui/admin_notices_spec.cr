# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Avis aux administrateurs d'un dossier (D-AMD-044 du cœur, contrat
# d'instance 1.5.0) : un administrateur ajouté depuis partiduo-admin est
# annoncé aux administrateurs actuels, avec le lien vers la fiche du compte,
# `https://<hôte>/settings/users/<id>`, écrit par le socle, qui ne connaît
# pas les routes de l'interface (sa spec
# `spec/core/instance_cli_admin_notices_spec.cr` vérifie ce même chemin).
# Ce lien doit mener à la fiche de l'écran des utilisateurs, où
# l'administrateur prévenu révoque l'accès.

private alias Auth = Partiduo::Api::Auth

# Chemin de la fiche d'un utilisateur cité par l'avis du socle.
private NOTICE_USER_PATH = "/settings/users/"

describe "Avis aux administrateurs : lien vers la fiche du compte (D-AMD-044 du cœur)" do
  it "suit la route de la fiche d'un utilisateur" do
    Marten.routes.reverse("core:user", id: 7).should eq("#{NOTICE_USER_PATH}7")
  end

  it "mène à la fiche où l'administrateur prévenu révoque l'accès ajouté" do
    PartiduoUi::Reference.provision
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    added = PartiduoUi::Accounts.create(email: "ajoute@example.com").user
    path = "#{NOTICE_USER_PATH}#{added.id}"

    page = browser.get(path).html
    page.should contain("ajoute@example.com")
    revoke = "#{path}/access/revoke"
    page.should contain(%(action="#{revoke}"))
    page.should contain("Révoquer l'accès")
    browser.post(revoke, {} of String => String).status.should eq(302)
    Auth.user_by_email(Partiduo::Api::Actor.system, "ajoute@example.com").try(&.revoked).should be_true
  end
end
