#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Assemble THIRD-PARTY-LICENSES.txt : licences des composants tiers compilés
# ou servis par l'interface — Crystal, shards du verrou (hors dépendances de
# développement), Bulma, htmx, Opal, Lucide, IBM Plex. Servi par /licences
# (pied des pages d'accès, comme partiduo-admin). À relancer après tout
# changement du verrou (shards installés dans lib/).
set -eu
cd "$(dirname "$0")/.."
out=THIRD-PARTY-LICENSES.txt
dev=$(sed -n '/^development_dependencies:/,/^[a-z]/p' shard.yml | sed -n 's/^  \([a-z0-9_-]*\):$/\1/p')

section() {
  printf '\n%s\n%s\n' "================================================================================" "$1"
  printf 'Provenance : %s\n' "$2"
  printf 'Licence    : %s\n' "$3"
  printf '%s\n\n' "--------------------------------------------------------------------------------"
}

{
  echo "Composants tiers de partiduo-ui-bulma (interface de Partiduo)"
  echo "Code source de partiduo-ui-bulma (AGPL-3.0-or-later) : https://github.com/aloli-partiduo/partiduo-ui-bulma"
  section "Crystal (bibliothèque standard)" "https://github.com/crystal-lang/crystal" "Apache-2.0"
  cat licenses/crystal.txt
  for name in $(sed -n 's/^  \([a-z0-9_-]*\):$/\1/p' shard.lock); do
    case " $(echo $dev) " in *" $name "*) continue ;; esac
    url=$(sed -n "/^  $name:$/,/^$/p" shard.lock | sed -n -E 's/^ *(git|github): *//p' | head -1 | sed 's/\.git$//')
    license=$(sed -n 's/^license: *//p' "lib/$name/shard.yml" 2>/dev/null | head -1)
    # Licence non déclarée dans shard.yml : celle de son fichier de licence.
    case "$name" in
      bindata | ed25519 | matrix) license=${license:-MIT} ;;
      pg) license=${license:-BSD-3-Clause} ;;
    esac
    # Fourche maison : le projet d'origine aussi.
    [ "$name" = marten ] && url="$url (fourche de https://github.com/martenframework/marten)"
    file=$(ls "lib/$name" 2>/dev/null | grep -iE '^(licen[cs]e|copying)' | head -1 || true)
    section "$name (shard)" "$url" "${license:-voir le texte}"
    if [ -n "$file" ]; then cat "lib/$name/$file"; else echo "Licence $license déclarée par le shard (aucun fichier de licence publié)."; fi
  done
  section "Bulma 1.0.4 (feuille de style)" "https://github.com/jgthms/bulma" "MIT"
  cat licenses/bulma.txt
  section "htmx 2.0.11 (script)" "https://github.com/bigskysoftware/htmx" "0BSD"
  cat licenses/htmx.txt
  section "Opal 1.8.2 (bibliothèque d'exécution des scripts Ruby)" "https://github.com/opal/opal" "MIT"
  cat licenses/opal.txt
  section "Lucide $(cat icons/lucide/VERSION) (icônes)" "https://github.com/lucide-icons/lucide" "ISC"
  cat icons/lucide/LICENSE
  section "IBM Plex (polices)" "https://github.com/IBM/plex" "OFL-1.1"
  cat src/ui/assets/ui/fonts/LICENSE-IBM-Plex.txt
} >"$out"
echo "$out : $(grep -c '^Provenance' "$out") composants"
