#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# shard.yml référence le cœur (`../partiduo-app`) et les shards maison
# (`../../prod-crystal/<nom>`) en `path:` tant qu'ils ne sont pas publiés. En CI, on les
# clone à ces emplacements, à côté du dépôt.
set -eu

cd "$(dirname "$0")/.."
base="${PARTIDUO_DEPS_BASE_URL:-https://github.com/aloli-crystal}"

if [ ! -d ../partiduo-app ]; then
  git clone --depth 1 --branch "${PARTIDUO_APP_BRANCH:-development}" "$base/partiduo-app.git" ../partiduo-app
fi

# Les shards maison du cœur, à l'emplacement attendu par les deux dépôts.
../partiduo-app/scripts/ci-checkout-deps.sh
