# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Origine d'une recherche de traduction (`Translations::Probe.place`), lue
# dans la pile avec ou sans informations de débogage : la CI lance
# `crystal spec --no-debug`, où une ligne de pile ne cite plus son fichier.
# Une recherche faite par le corps d'une spec doit y rester reconnue
# (contrôle de conventions qui lit chaque clé citée, pluriels compris), et
# celle du code rester rapportée.

private alias Probe = PartiduoUi::Translations::Probe

private BINARY = "/home/runner/.cache/crystal/crystal-run-spec.tmp"

describe "Sonde des traductions : origine d'une recherche" do
  it "rend telle quelle une ligne située du code ou d'une spec, et ignore la mécanique de recherche" do
    Probe.place("ui/bulma/handlers/dashboard_handlers.cr:48:11 in 'get'").should eq("ui/bulma/handlers/dashboard_handlers.cr:48:11 in 'get'")
    Probe.place("spec/architecture/conventions_spec.cr:51:31 in '->'").should eq("spec/architecture/conventions_spec.cr:51:31 in '->'")
    Probe.place("/home/runner/work/partiduo-crm/partiduo-crm/src/crm/x.cr:3:5 in 'y'").should_not be_nil
    Probe.place("/usr/share/crystal/src/array.cr:12:3 in 'each'").should be_nil
    Probe.place("lib/i18n/src/i18n/catalog.cr:120:7 in 'fetch_translation!'").should be_nil
    Probe.place("lib/partiduo-ui-bulma/spec/support/translations.cr:140:9 in 'lookup'").should be_nil
    Probe.place("lib/partiduo/src/partiduo/api/result.cr:40:5 in 'failure'").should be_nil
  end

  it "reconnaît sans informations de débogage le bloc d'une spec par l'emplacement que garde son symbole" do
    Probe.place("#{BINARY} in '~procProc(Nil)@spec/architecture/conventions_spec.cr:44'").should eq("spec/architecture/conventions_spec.cr:44")
    Probe.place("#{BINARY} in '~procProc(Nil)@lib/partiduo-crm/spec/crm/x_spec.cr:9'").should eq("lib/partiduo-crm/spec/crm/x_spec.cr:9")
  end

  it "désigne sans informations de débogage le code par sa méthode, jamais par « ? »" do
    Probe.place("#{BINARY} in 'Crm::Ui::DashboardHandler#get:Marten::HTTP::Response'").should eq("Crm::Ui::DashboardHandler#get:Marten::HTTP::Response")
  end

  it "ignore sans informations de débogage la pile, crystal-i18n, la sonde et le contrat d'erreurs" do
    [
      "caller:Array(String)",
      "Exception::CallStack::unwind:Array(Pointer(Void))",
      "I18n::Catalog#fetch_translation!<String, String, Nil, Nil, Bool>:(Bool | Int32 | String | Nil)",
      "I18n::t<String>:String",
      "PartiduoUi::Translations::Probe::lookup<String, Nil, Nil>:Nil",
      "Partiduo::Api::Result(Nil)::failure<String>:Partiduo::Api::Result(Nil)",
      "Partiduo::Api::FieldError#message:String",
    ].each { |symbol| Probe.place("#{BINARY} in '#{symbol}'").should be_nil }
  end
end
