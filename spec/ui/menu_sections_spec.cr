# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Rubriques repliables du menu latéral (D-UI-078) : le titre de chaque
# rubrique est un bouton de divulgation (`aria-expanded`, `aria-controls`) ;
# seule la rubrique de la page affichée est dépliée à l'arrivée. Le choix de
# l'utilisateur est gardé sur le poste par `ui/js/shell.js` (exécuté plus bas
# sur un DOM simulé). Sans JavaScript, le titre est un texte et tout reste
# déplié (`pd-nojs`, `pd-jsonly`, règle masquante sous `.pd-js` seulement).

private alias Books = PartiduoUi::Books

private record MenuGroup, code : String, current : Bool, expanded : Bool, active : Bool, first_link : String?

# Rubriques du menu d'une page, vérifiées une à une : bouton relié à sa
# liste, liste nommée par le titre, description de l'action.
private def menu_groups(html : String) : Array(MenuGroup)
  html.scan(/<div class="pd-menu-group (is-current|is-collapsed)" data-pd-section="([^"]+)">(.*?)<\/ul>\s*<\/div>/m).map do |match|
    code, body = match[2], match[3]
    body.should match(/<button class="pd-menu-toggle pd-jsonly" type="button" aria-expanded="(true|false)" aria-controls="pd-menu-list-#{code}" title="[^"]+" data-pd-section-toggle /)
    body.should contain(%(<ul class="menu-list" id="pd-menu-list-#{code}" aria-labelledby="pd-menu-#{code}">))
    body.should contain(%(<span id="pd-menu-#{code}">))
    body.should contain("sprite.svg#chevron-down")
    MenuGroup.new(code, match[1] == "is-current", body.includes?(%(aria-expanded="true")),
      body.includes?(%(aria-current="page")), body[/<a href="([^"]+)"/, 1]?)
  end
end

# Seule la rubrique de la page affichée est dépliée (et marquée courante).
private def only_current_expanded(groups : Array(MenuGroup), code : String?) : Nil
  groups.each do |group|
    group.current.should eq(group.code == code)
    group.expanded.should eq(group.code == code)
    group.active.should eq(group.code == code)
  end
end

# Ouvre la première entrée de la première rubrique : elle seule se déplie.
private def follow_first_section(browser : PartiduoUi::Browser) : Array(MenuGroup)
  groups = menu_groups(browser.get("/").html)
  groups.should_not be_empty
  only_current_expanded(groups, nil)
  target = groups.find!(&.first_link)
  link = target.first_link || raise "rubrique sans entrée"
  page = menu_groups(browser.get(link).html)
  only_current_expanded(page, target.code)
  page
end

# Exécute shell.js sur le DOM simulé ; `before` règle l'environnement avant
# le chargement du script (stockage déjà rempli ou indisponible).
private def run_script(probe : String, before : String = "") : Array(String)
  engine = PartiduoUi::SpecSupport.javascript_engine
  pending!("aucun moteur JavaScript autonome (JavaScriptCore) ; PARTIDUO_JS_ENGINE pour en indiquer un") unless engine
  dom = File.tempname("partiduo-menu-dom", ".js")
  test = File.tempname("partiduo-menu-probe", ".js")
  File.write(dom, MENU_DOM + "\n" + before)
  File.write(test, probe)
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(engine, [dom, PartiduoUi::SpecSupport.path("src", "ui", "assets", "ui", "js", "shell.js"), test],
    output: output, error: error)
  status.success?.should be_true, "#{error}#{output}"
  output.to_s.lines
ensure
  File.delete?(dom) if dom
  File.delete?(test) if test
end

# DOM minimal du menu : trois rubriques (A courante, B et C repliées par le
# serveur), une entrée chacune ; stockage local remplaçable.
private MENU_DOM = <<-JS
  function ClassList(names) { this.names = {}; var self = this; (names || []).forEach(function (n) { self.names[n] = true; }); }
  ClassList.prototype.add = function (n) { this.names[n] = true; };
  ClassList.prototype.remove = function (n) { delete this.names[n]; };
  ClassList.prototype.contains = function (n) { return !!this.names[n]; };
  ClassList.prototype.toggle = function (n, force) {
    var on = force === undefined ? !this.names[n] : !!force;
    if (on) this.names[n] = true; else delete this.names[n];
    return on;
  };
  function Element(tag, attrs, classes) { this.tag = tag; this.attrs = attrs || {}; this.classList = new ClassList(classes); this.kids = []; this.parent = null; }
  function HTMLFormElement() {}
  Element.prototype.append = function (child) { child.parent = this; this.kids.push(child); return child; };
  Element.prototype.getAttribute = function (n) { return n in this.attrs ? this.attrs[n] : null; };
  Element.prototype.setAttribute = function (n, v) { this.attrs[n] = String(v); };
  Element.prototype.removeAttribute = function (n) { delete this.attrs[n]; };
  Element.prototype.matches = function (s) {
    if (s === ".menu-list a[href]") return this.tag === "a" && "href" in this.attrs;
    var m = /^\\[([a-z-]+)\\]$/.exec(s);
    return !!m && m[1] in this.attrs;
  };
  Element.prototype.closest = function (s) { for (var e = this; e; e = e.parent) if (e.matches(s)) return e; return null; };
  Element.prototype.contains = function (other) { for (var e = other; e; e = e.parent) if (e === this) return true; return false; };
  Element.prototype.querySelectorAll = function (s) {
    var found = [];
    (function walk(e) { e.kids.forEach(function (k) { if (k.matches(s)) found.push(k); walk(k); }); })(this);
    return found;
  };
  Element.prototype.querySelector = function (s) { return this.querySelectorAll(s)[0] || null; };

  var listeners = {};
  var document = new Element("#document");
  document.readyState = "interactive";
  document.documentElement = new Element("html");
  document.addEventListener = function (t, f) { (listeners[t] = listeners[t] || []).push(f); };
  document.dispatch = function (t, e) { (listeners[t] || []).forEach(function (f) { f(e || {}); }); };
  var side = document.append(new Element("nav", {id: "pd-side"}));
  document.getElementById = function (id) { return id === "pd-side" ? side : null; };
  var groups = {}, buttons = {}, links = {};
  [["A", "/a"], ["B", "/b"], ["C", "/c"]].forEach(function (pair) {
    var code = pair[0];
    var group = side.append(new Element("div", {"data-pd-section": code}, ["pd-menu-group", code === "A" ? "is-current" : "is-collapsed"]));
    buttons[code] = group.append(new Element("button", {"data-pd-section-toggle": "", "aria-expanded": code === "A" ? "true" : "false",
      "data-pd-expand": "Déplier " + code, "data-pd-collapse": "Replier " + code}));
    var list = group.append(new Element("ul", {}, ["menu-list"]));
    links[code] = list.append(new Element("a", code === "A" ? {href: pair[1], "aria-current": "page"} : {href: pair[1]}, code === "A" ? ["is-active"] : []));
    groups[code] = group;
  });

  var store = {};
  var storage = {
    getItem: function (k) { return k in store ? store[k] : null; },
    setItem: function (k, v) { store[k] = String(v); }
  };
  var window = {
    location: { pathname: "/a/12" },
    localStorage: storage,
    matchMedia: function () { return { matches: false, addEventListener: function () {} }; },
    print: function () {}, confirm: function () { return true; }
  };
  function state() {
    return ["A", "B", "C"].map(function (c) {
      return c + "=" + buttons[c].getAttribute("aria-expanded") + (groups[c].classList.contains("is-collapsed") ? "/masquée" : "/visible");
    }).join(" ");
  }
  function click(c) { document.dispatch("click", { target: buttons[c] }); }
  JS

describe "Rubriques repliables du menu latéral (D-UI-078)" do
  it "rend un bouton par rubrique, seule la rubrique de la page affichée dépliée (entreprise)" do
    browser = Books.admin
    html = browser.get("/").html
    html.should contain(%(<p class="menu-label"><span class="pd-menu-title pd-nojs">Saisie</span><button class="pd-menu-toggle pd-jsonly"))
    html.should contain(%(title="Déplier la section Saisie"))
    html.should contain(%(data-pd-collapse="Replier la section Saisie"))
    # Le tableau de bord n'est dans aucune rubrique : toutes repliées.
    only_current_expanded(menu_groups(html), nil)
    page = follow_first_section(browser)
    page.size.should be > 3
    # Sur une écriture (`/accounting/entries/…`), la rubrique « Consultation » est la courante.
    entries = menu_groups(browser.get("/accounting/entries").html)
    entries.count(&.expanded).should eq(1)
    entries.find!(&.expanded).active.should be_true
  end

  it "traduit la description des boutons en anglais et en néerlandais" do
    browser = Books.admin
    {"en" => {"Expand the", "Collapse the"}, "nl" => {"openklappen", "dichtklappen"}}.each do |locale, (expand, collapse)|
      browser.post("/language", {"locale" => locale, "next" => "/"})
      html = browser.get("/accounting/entries").html
      html.should contain(expand)
      html.should contain(collapse)
      html.should_not contain("missing translation")
    end
  end

  it "laisse le menu réduit de la micro-entreprise sans rubrique, et replie celles du mode complet" do
    browser = Books.admin
    Partiduo::Api::Modules.deactivate(Books.system, "ANALYTIC").success?.should be_true
    Partiduo::Api::Modules.deactivate(Books.system, "ACCOUNTING").success?.should be_true
    Partiduo::Api::Modules.activate(Books.system, "MICRO").success?.should be_true
    Partiduo::Api::Micro.load_defaults(Books.system)
    html = browser.get("/").html
    html.should contain(%(class="pd-app pd-simple"))
    html.should_not contain("data-pd-section-toggle")
    html.should contain(%(<nav class="pd-side menu" id="pd-side"))
  end

  it "replie les rubriques de la profession libérale en interface comptable" do
    browser = Books.admin
    Partiduo::Api::Modules.activate(Books.system, "LIBERAL").success?.should be_true
    Partiduo::Api::Liberal.load_defaults(Books.system)
    # Interface « Recettes et dépenses » : menu réduit, sans rubrique.
    browser.get("/").html.should_not contain("data-pd-section-toggle")
    browser.post("/account/preferences", {"interface" => "full"}).status.should eq(302)
    follow_first_section(browser)
  end

  it "replie les rubriques d'un dossier foyer" do
    %w[ANALYTIC STOCK FOLLOWUP MICRO LIBERAL INVOICING].each { |code| Partiduo::Api::Modules.deactivate(Books.system, code) }
    PartiduoUi::Reference.provision(kind: Partiduo::Api::InitialData::HOUSEHOLD)
    PartiduoUi::Reference.fiscal_year(2026)
    PartiduoUi::Accounts.create
    browser = PartiduoUi::Accounts.signed_in
    follow_first_section(browser)
  end

  it "applique le choix gardé, déplie et replie au clic, et l'enregistre (shell.js)" do
    lines = run_script(<<-JS)
      print("js=" + document.documentElement.classList.contains("pd-js"));
      print(state());
      click("B");
      print(state() + " " + store["partiduo.menu.sections"]);
      click("A");
      print(state() + " " + buttons.A.getAttribute("title") + " / " + buttons.B.getAttribute("title"));
      JS
    lines.should eq([
      "js=true",
      "A=true/visible B=false/masquée C=false/masquée",
      %(A=true/visible B=true/visible C=false/masquée {"B":1}),
      "A=false/masquée B=true/visible C=false/masquée Déplier A / Replier B",
    ])
  end

  it "restaure le choix d'une visite précédente, la rubrique courante toujours dépliée (shell.js)" do
    seed = %(store["partiduo.menu.sections"] = '{"A":0,"C":1}';)
    run_script("print(state());", seed).should eq(["A=true/visible B=false/masquée C=true/visible"])
    # Retour dans l'historique de HTMX : même règle sur le menu restauré.
    run_script(<<-JS, seed).should eq(["A=true/visible B=false/masquée C=true/visible"])
      groups.C.classList.add("is-collapsed");
      document.dispatch("htmx:historyRestore");
      print(state());
      JS
  end

  it "reste utilisable sans stockage local (shell.js)" do
    refused = %(window.localStorage = { getItem: function () { throw new Error("refusé"); }, setItem: function () { throw new Error("refusé"); } };)
    run_script(<<-JS, refused).should eq(["js=true A=true/visible B=false/masquée C=true/visible"])
      click("C");
      print("js=" + document.documentElement.classList.contains("pd-js") + " " + state());
      JS
  end

  it "suit l'entrée active quand HTMX change l'adresse sans recharger (shell.js)" do
    lines = run_script(<<-JS)
      window.location.pathname = "/b/7";
      document.dispatch("htmx:pushedIntoHistory");
      print(state() + " " + links.B.getAttribute("aria-current") + " " + links.A.getAttribute("aria-current") + " " + groups.B.classList.contains("is-current"));
      window.location.pathname = "/ailleurs";
      document.dispatch("htmx:replacedInHistory");
      print(links.B.classList.contains("is-active"));
      JS
    lines.should eq(["A=true/visible B=true/visible C=false/masquée page null true", "true"])
  end
end
