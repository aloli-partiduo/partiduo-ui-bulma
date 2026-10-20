# SPDX-License-Identifier: AGPL-3.0-or-later

require "./ext/request"
require "./current"
require "./strict_transport_security"
require "./rate_limit"
require "./navigation"
require "./extensions"
require "./format"
require "./screen"
require "./table"
require "./table_pdf"
require "./persistent_filters"
require "./form"
require "./entry_form"
require "./entry_analytic"
require "./entry_check"
require "./document_form"
require "./dashboard"
require "./folder_kind"
require "./simple_mode"
require "./micro_dashboard"
require "./liberal_dashboard"
require "./shell"
require "./passkey_json"
require "./qr_svg"
require "./emails/token_email"
require "./handlers/concerns/handler"
require "./handlers/concerns/login_flow"
require "./licences"
require "./handlers/auth/**"
require "./handlers/account/security_handlers"
require "./handlers/account/enrollment_handlers"
require "./handlers/screen_handlers"
require "./handlers/extension_handler"
require "./handlers/public_extension_handler"
require "./handlers/reference/reference_handler"
require "./handlers/reference/*"
require "./handlers/account/preferences_handlers"
require "./handlers/completion_handlers"
require "./handlers/accounting/entry_handlers"
require "./handlers/accounting/received_invoice_handlers"
require "./handlers/accounting/consultation_handlers"
require "./handlers/accounting/receipts_handlers"
require "./handlers/accounting/statement_handlers"
require "./handlers/accounting/matching_handlers"
require "./handlers/accounting/reconciliation_handlers"
require "./handlers/accounting/year_end_handlers"
require "./handlers/accounting/history_handlers"
require "./handlers/accounting/report_handlers"
require "./handlers/accounting/custom_report_handlers"
require "./handlers/accounting/forecast_handlers"
require "./handlers/accounting/vat_handlers"
require "./handlers/invoicing/document_handlers"
require "./handlers/invoicing/follow_up_handlers"
require "./handlers/invoicing/settings_handlers"
require "./handlers/invoicing/delivery_billing_handlers"
require "./handlers/analytic/analytic_screen"
require "./handlers/analytic/plan_handlers"
require "./handlers/analytic/key_handlers"
require "./handlers/analytic/misc_handlers"
require "./handlers/analytic/distribution_handlers"
require "./handlers/analytic/report_handlers"
require "./handlers/stock/stock_screen"
require "./handlers/stock/reference_handlers"
require "./handlers/stock/change_handlers"
require "./handlers/stock/report_handlers"
require "./handlers/followup/followup_handlers"
require "./handlers/settings/settings_handlers"
require "./handlers/approvals/approval_handlers"
require "./handlers/settings/users_handlers"
require "./handlers/settings/identity_providers_handlers"
require "./handlers/micro/micro_screen"
require "./handlers/micro/register_handlers"
require "./handlers/micro/urssaf_handlers"
require "./handlers/micro/invoice_handlers"
require "./handlers/micro/settings_handlers"
require "./handlers/accounting/micro_accounts_handlers"
require "./handlers/liberal/liberal_screen"
require "./handlers/liberal/journal_handlers"
require "./handlers/liberal/asset_handlers"
require "./handlers/liberal/tax_return_handlers"
require "./handlers/liberal/year_handlers"
require "./handlers/liberal/settings_handlers"
require "./handlers/accounting/liberal_accounts_handlers"

module PartiduoUi
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Types des favicons et du manifeste web (`assets/ui/brand/`) : absents des
  # types par défaut de Crystal, et de la base du système sur certains hôtes.
  # Marten sert les fichiers statiques d'après `MIME.from_filename`.
  MIME.register(".ico", "image/x-icon")
  MIME.register(".webmanifest", "application/manifest+json")

  # Application Marten de l'interface Bulma : ses gabarits (`templates/ui/`),
  # ses fichiers statiques (`assets/ui/`) et ses libellés d'écran (`locales/`).
  class App < Marten::App
    label "ui"

    # Monte les interfaces d'extension déclarées par
    # `PartiduoUi::Extensions.mount` (ADR-003 D3), avant que Marten ne prépare
    # les routes : l'ordre des `require` de la distribution n'importe pas.
    def setup
      Extensions.draw
    end
  end
end
