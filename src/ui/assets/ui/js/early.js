/* SPDX-License-Identifier: AGPL-3.0-or-later
   Premier script de l'en-tête, chargé sans « defer » (D-UI-079) : pose la
   classe pd-js sur <html> avant le premier affichage, pour que la feuille
   de style replie dès l'arrivée les rubriques du menu (D-UI-078) et ferme
   le menu sur téléphone, au lieu de les montrer dépliés le temps que
   shell.js, différé, se charge. Reprend aussi le repli du menu entier
   gardé sur le poste (partiduo.menu.collapsed, tablette), que shell.js
   reporte ensuite sur la coquille. Fichier du site et non script en ligne :
   rien à ouvrir dans une politique de sécurité du contenu (script-src
   'self' suffit). Sans JavaScript, rien ne change : tout reste déplié. */
(function () {
  "use strict";
  var root = document.documentElement;
  root.classList.add("pd-js");
  try {
    if (window.localStorage.getItem("partiduo.menu.collapsed") === "1") root.classList.add("pd-menu-collapsed");
  } catch (e) { /* stockage indisponible : menu déplié */ }
})();
