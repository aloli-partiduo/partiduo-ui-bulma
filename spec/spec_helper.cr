# SPDX-License-Identifier: AGPL-3.0-or-later

ENV["MARTEN_ENV"] = "test"

require "spec"

require "../src/partiduo_ui"
# Migrations du cœur : le schéma de test est construit par elles (D-UI-028).
require "partiduo/cli"
# Extension factice montée sous /ext/UITEST/ (contrôle d'accès des extensions).
require "./fixtures/uitest/app"
# Extension factice à routes publiques (/p/uipub/) et approbations.
require "./fixtures/uipub/app"
require "marten/spec"
require "marten_auth/spec"

require "./support/**"
