/* SPDX-License-Identifier: AGPL-3.0-or-later
   Liaison de la coquille au navigateur (DECISIONS D-UI-005), sans logique
   d'écran : repli du menu latéral (tablette, téléphone), rubriques du menu
   repliables (D-UI-078), raccourci Ctrl+K
   (⌘K) vers la recherche, impression des codes, confirmation des commandes
   (data-pd-confirm). Aucun envoi de formulaire au changement d'une liste
   (WCAG 3.2.2) : langue, période et catégorie ont leur bouton « Appliquer ».
   La page reste utilisable sans JavaScript. */
(function () {
  "use strict";
  var KEY = "partiduo.menu.collapsed";
  // Rubriques dépliées (1) ou repliées (0) par l'utilisateur, par code de
  // rubrique : gardées sur le poste, d'une page et d'une visite à l'autre.
  var SECTIONS = "partiduo.menu.sections";

  function app() { return document.getElementById("pd-app"); }

  function phone() { return window.matchMedia("(max-width: 767.98px)").matches; }

  function setExpanded(button, expanded) {
    button.setAttribute("aria-expanded", expanded ? "true" : "false");
  }

  function sync() {
    var root = app();
    var button = document.querySelector("[data-pd-menu-toggle]");
    if (!root || !button) return;
    var open = phone() ? root.classList.contains("is-menu-open") : !root.classList.contains("is-menu-collapsed");
    setExpanded(button, open);
  }

  function toggleMenu() {
    var root = app();
    if (!root) return;
    if (phone()) {
      root.classList.toggle("is-menu-open");
    } else {
      var collapsed = root.classList.toggle("is-menu-collapsed");
      try { window.localStorage.setItem(KEY, collapsed ? "1" : "0"); } catch (e) { /* stockage indisponible */ }
    }
    sync();
  }

  /* Rubriques repliables (D-UI-078). Le serveur rend la rubrique de la page
     affichée dépliée (is-current) et les autres repliées (is-collapsed,
     aria-expanded="false") ; la feuille de style ne les masque qu'avec la
     classe pd-js, posée ici : sans JavaScript, tout reste déplié. S'y ajoute
     le choix de l'utilisateur gardé dans localStorage ; la rubrique de la
     page affichée est toujours dépliée à l'arrivée. */
  function readSections() {
    try {
      var value = JSON.parse(window.localStorage.getItem(SECTIONS) || "{}");
      return value && typeof value === "object" ? value : {};
    } catch (e) { return {}; /* stockage indisponible ou valeur illisible */ }
  }

  function storeSection(code, open) {
    try {
      var value = readSections();
      value[code] = open ? 1 : 0;
      window.localStorage.setItem(SECTIONS, JSON.stringify(value));
    } catch (e) { /* stockage indisponible : le choix vaut pour la page */ }
  }

  function setSection(group, open) {
    group.classList.toggle("is-collapsed", !open);
    var button = group.querySelector("[data-pd-section-toggle]");
    if (!button) return;
    button.setAttribute("aria-expanded", open ? "true" : "false");
    var title = button.getAttribute(open ? "data-pd-collapse" : "data-pd-expand");
    if (title) button.setAttribute("title", title);
  }

  function applySections(scope) {
    var stored = readSections();
    scope.querySelectorAll("[data-pd-section]").forEach(function (group) {
      setSection(group, group.classList.contains("is-current") || stored[group.getAttribute("data-pd-section")] === 1);
    });
  }

  function toggleSection(button) {
    var group = button.closest("[data-pd-section]");
    if (!group) return;
    var open = group.classList.contains("is-collapsed");
    setSection(group, open);
    storeSection(group.getAttribute("data-pd-section"), open);
  }

  // Même règle que `Shell.active?` : « / » seul pour le tableau de bord,
  // sinon le chemin lui-même ou une page en dessous.
  function activeFor(url, path) {
    return url === "/" ? path === "/" : (path === url || path.indexOf(url.replace(/\/+$/, "") + "/") === 0);
  }

  /* Adresse changée par HTMX sans rechargement (hx-push-url) : l'entrée
     active et sa rubrique suivent, si une entrée du menu correspond au
     nouveau chemin ; sinon le marquage du serveur reste. */
  var shownPath = window.location.pathname;
  function followPath() {
    var path = window.location.pathname;
    if (path === shownPath) return;
    shownPath = path;
    var side = document.getElementById("pd-side");
    if (!side) return;
    var links = Array.prototype.slice.call(side.querySelectorAll(".menu-list a[href]"));
    var found = null;
    links.forEach(function (link) {
      if (activeFor(link.getAttribute("href"), path) && (!found || link.getAttribute("href").length > found.getAttribute("href").length)) found = link;
    });
    if (!found) return;
    links.forEach(function (link) {
      var active = link === found;
      link.classList.toggle("is-active", active);
      if (active) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
    });
    side.querySelectorAll("[data-pd-section]").forEach(function (group) {
      var current = group.contains(found);
      group.classList.toggle("is-current", current);
      if (current) setSection(group, true);
    });
  }

  function start() {
    // Déjà posée par early.js dans l'en-tête (D-UI-079) ; reposée ici si
    // ce script-là manquait. Le repli du menu entier, repris de même par
    // early.js sur <html>, passe à la coquille, qui le tient désormais.
    var html = document.documentElement;
    html.classList.add("pd-js");
    var root = app();
    try {
      if (root && window.localStorage.getItem(KEY) === "1") root.classList.add("is-menu-collapsed");
    } catch (e) { /* stockage indisponible */ }
    html.classList.remove("pd-menu-collapsed");
    applySections(document);
    sync();
    window.matchMedia("(max-width: 767.98px)").addEventListener("change", sync);
  }

  // Script différé : le document est déjà lu, les rubriques sont réglées
  // avant le premier affichage autant que possible.
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();

  // Menu remplacé par HTMX (contenu chargé, retour dans l'historique) :
  // rubriques réglées de nouveau, entrée active suivie.
  document.addEventListener("htmx:load", function (event) {
    var element = event.target;
    if (element instanceof Element && (element.matches("[data-pd-section]") || element.querySelector("[data-pd-section]"))) applySections(element);
  });
  document.addEventListener("htmx:historyRestore", function () { shownPath = null; applySections(document); followPath(); });
  document.addEventListener("htmx:pushedIntoHistory", followPath);
  document.addEventListener("htmx:replacedInHistory", followPath);

  document.addEventListener("click", function (event) {
    var target = event.target;
    if (!(target instanceof Element)) return;
    if (target.closest("[data-pd-menu-toggle]")) { toggleMenu(); return; }
    var section = target.closest("[data-pd-section-toggle]");
    if (section) { toggleSection(section); return; }
    if (target.closest("[data-pd-print]")) { window.print(); }
  });

  document.addEventListener("submit", function (event) {
    var form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    var message = form.getAttribute("data-pd-confirm");
    if (message && !window.confirm(message)) event.preventDefault();
  }, true);

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      var root = app();
      if (root && root.classList.contains("is-menu-open")) {
        root.classList.remove("is-menu-open");
        sync();
        var button = document.querySelector("[data-pd-menu-toggle]");
        if (button) button.focus();
      }
      return;
    }
    // Raccourci avec modificateur (WCAG 2.1.4) : jamais une touche de
    // caractère seule, qui gênerait la commande vocale et les lecteurs d'écran.
    if (!(event.key === "k" || event.key === "K") || !(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return;
    var search = document.querySelector("[data-pd-search]");
    if (search) { event.preventDefault(); search.focus(); }
  });
})();
