# SPDX-License-Identifier: AGPL-3.0-or-later

# Écrans du socle, sous les noms de route que citent les menus des
# manifestes (`core:dashboard`) : le cœur n'a aucune route (ADR-005 D1).
CORE_ROUTES = Marten::Routing::Map.draw do
  path "/", PartiduoUi::DashboardHandler, name: "dashboard"
  # Exercices et périodes (lot 1) ; période de travail de la barre supérieure.
  path "/fiscal-years", PartiduoUi::FiscalYearsHandler, name: "fiscal_years"
  path "/fiscal-years/<id:int>", PartiduoUi::FiscalYearHandler, name: "fiscal_year"
  path "/fiscal-years/<id:int>/close", PartiduoUi::FiscalYearCloseHandler, name: "fiscal_year_close"
  path "/fiscal-years/<id:int>/delete", PartiduoUi::FiscalYearDeleteHandler, name: "fiscal_year_delete"
  path "/periods/<id:int>/close", PartiduoUi::PeriodCloseHandler, name: "period_close"
  path "/periods/<id:int>/reopen", PartiduoUi::PeriodReopenHandler, name: "period_reopen"
  path "/periods/<id:int>/delete", PartiduoUi::PeriodDeleteHandler, name: "period_delete"
  path "/period", PartiduoUi::CurrentPeriodHandler, name: "current_period"
  # Pièce jointe du socle affichée dans la page (aperçu d'une facture reçue).
  path "/attachments/<id:int>", PartiduoUi::AttachmentHandler, name: "attachment"
  # Paramètres du dossier (D-UI-051, D-UI-052) : société, modules, devises,
  # utilisateurs, profils et droits par journal.
  # Approbation des opérations sensibles des extensions (A-SEPA-3).
  path "/approvals", PartiduoUi::ApprovalsHandler, name: "approvals"
  path "/approvals/<id:int>", PartiduoUi::ApprovalHandler, name: "approval"
  path "/approvals/<id:int>/approve", PartiduoUi::ApprovalApproveHandler, name: "approval_approve"
  path "/approvals/<id:int>/reject", PartiduoUi::ApprovalRejectHandler, name: "approval_reject"
  path "/approvals/<id:int>/cancel", PartiduoUi::ApprovalCancelHandler, name: "approval_cancel"
  path "/approvals/<id:int>/reauth", PartiduoUi::ApprovalReauthHandler, name: "approval_reauth"
  path "/settings/company", PartiduoUi::CompanyHandler, name: "company"
  path "/settings/company/edit", PartiduoUi::CompanyEditHandler, name: "company_edit"
  path "/settings/modules", PartiduoUi::ModulesHandler, name: "modules"
  path "/settings/modules/<code:str>/<command:str>", PartiduoUi::ModuleToggleHandler, name: "module_toggle"
  path "/settings/currencies", PartiduoUi::CurrenciesHandler, name: "currencies"
  path "/settings/currencies/<code:str>", PartiduoUi::CurrencyHandler, name: "currency"
  path "/settings/currencies/<code:str>/edit", PartiduoUi::CurrencyEditHandler, name: "currency_edit"
  path "/settings/currencies/<code:str>/delete", PartiduoUi::CurrencyDeleteHandler, name: "currency_delete"
  path "/settings/users", PartiduoUi::UsersHandler, name: "users"
  path "/settings/users/new", PartiduoUi::UserNewHandler, name: "user_new"
  path "/settings/users/<id:int>", PartiduoUi::UserHandler, name: "user"
  path "/settings/users/<id:int>/edit", PartiduoUi::UserEditHandler, name: "user_edit"
  path "/settings/users/<id:int>/ledgers", PartiduoUi::UserLedgersHandler, name: "user_ledgers"
  path "/settings/users/<id:int>/access/<command:str>", PartiduoUi::UserCommandHandler, name: "user_command"
  # Identités fédérées d'un utilisateur et fournisseurs d'identité (ADR-002 D3, D-R5-010).
  path "/settings/users/<id:int>/identities", PartiduoUi::UserIdentitiesHandler, name: "user_identities"
  path "/settings/users/<id:int>/identities/<identity:int>/unlink", PartiduoUi::UserIdentityUnlinkHandler, name: "user_identity_unlink"
  path "/settings/identity-providers", PartiduoUi::IdentityProvidersHandler, name: "identity_providers"
  path "/settings/identity-providers/new", PartiduoUi::IdentityProviderNewHandler, name: "identity_provider_new"
  path "/settings/identity-providers/<code:str>", PartiduoUi::IdentityProviderEditHandler, name: "identity_provider_edit"
  path "/settings/audit", PartiduoUi::AuditHandler, name: "audit"
  path "/settings/profiles", PartiduoUi::ProfilesHandler, name: "profiles"
  path "/settings/profiles/new", PartiduoUi::ProfileNewHandler, name: "profile_new"
  path "/settings/profiles/defaults", PartiduoUi::ProfilesDefaultsHandler, name: "profiles_defaults"
  path "/settings/profiles/<id:int>", PartiduoUi::ProfileHandler, name: "profile"
  path "/settings/profiles/<id:int>/edit", PartiduoUi::ProfileEditHandler, name: "profile_edit"
  path "/settings/profiles/<id:int>/delete", PartiduoUi::ProfileDeleteHandler, name: "profile_delete"
end

# Fiches du socle : tiers, articles et services (menu `cards:index`).
CARDS_ROUTES = Marten::Routing::Map.draw do
  path "", PartiduoUi::CardsHandler, name: "index"
  path "/items", PartiduoUi::ItemsHandler, name: "items"
  path "/new", PartiduoUi::CardNewHandler, name: "new"
  # Import CSV et export au format de l'import (D-OUT-003, D-OUT-007).
  path "/import", PartiduoUi::CardImportHandler, name: "import"
  path "/export", PartiduoUi::CardExportHandler, name: "export"
  path "/<id:int>", PartiduoUi::CardHandler, name: "show"
  path "/<id:int>/edit", PartiduoUi::CardEditHandler, name: "edit"
  path "/<id:int>/enable", PartiduoUi::CardEnableHandler, name: "enable"
  path "/<id:int>/delete", PartiduoUi::CardDeleteHandler, name: "delete"
  # Complétion des fiches (saisie, facturation) : options d'une datalist.
  path "/complete", PartiduoUi::CardCompletionHandler, name: "complete"
  # Catégories de fiches (menu `cards:categories`, D-UI-052).
  path "/categories", PartiduoUi::CategoriesHandler, name: "categories"
  path "/categories/new", PartiduoUi::CategoryNewHandler, name: "category_new"
  path "/categories/<id:int>", PartiduoUi::CategoryHandler, name: "category"
  path "/categories/<id:int>/edit", PartiduoUi::CategoryEditHandler, name: "category_edit"
  path "/categories/<id:int>/delete", PartiduoUi::CategoryDeleteHandler, name: "category_delete"
end

# Taux de TVA du socle (menu `vat:rates`).
VAT_ROUTES = Marten::Routing::Map.draw do
  path "/rates", PartiduoUi::VatRatesHandler, name: "rates"
  path "/rates/new", PartiduoUi::VatRateNewHandler, name: "rate_new"
  path "/rates/<id:int>", PartiduoUi::VatRateHandler, name: "rate"
  path "/rates/<id:int>/edit", PartiduoUi::VatRateEditHandler, name: "rate_edit"
  path "/rates/<id:int>/delete", PartiduoUi::VatRateDeleteHandler, name: "rate_delete"
end

# Module Comptabilité : plan comptable et journaux (menus `accounting:chart`,
# `accounting:ledgers`). Module inactif : le contrat refuse, l'écran répond 404.
ACCOUNTING_ROUTES = Marten::Routing::Map.draw do
  path "/chart", PartiduoUi::ChartHandler, name: "chart"
  path "/chart/new", PartiduoUi::AccountNewHandler, name: "account_new"
  # Import et export CSV du plan comptable (D-OUT-004, D-OUT-007).
  path "/chart/import", PartiduoUi::ChartImportHandler, name: "chart_import"
  path "/chart/export", PartiduoUi::ChartExportHandler, name: "chart_export"
  path "/chart/<id:int>", PartiduoUi::AccountShowHandler, name: "account"
  path "/chart/<id:int>/edit", PartiduoUi::AccountEditHandler, name: "account_edit"
  path "/chart/<id:int>/delete", PartiduoUi::AccountDeleteHandler, name: "account_delete"
  path "/ledgers", PartiduoUi::LedgersHandler, name: "ledgers"
  path "/ledgers/new", PartiduoUi::LedgerNewHandler, name: "ledger_new"
  path "/ledgers/<id:int>", PartiduoUi::LedgerHandler, name: "ledger"
  path "/ledgers/<id:int>/edit", PartiduoUi::LedgerEditHandler, name: "ledger_edit"
  path "/ledgers/<id:int>/delete", PartiduoUi::LedgerDeleteHandler, name: "ledger_delete"
  # Archive ZIP des pièces jointes d'une période (D-OUT-005).
  path "/receipts", PartiduoUi::ReceiptsArchiveHandler, name: "receipts_archive"
  # Saisie (lot 2) : quatre formes, contrôle instantané, ajout de ligne.
  path "/entries/purchase", PartiduoUi::PurchaseEntryHandler, name: "entry_purchase"
  # Facture d'achat reçue hors plateforme, pièce jointe à côté (ADR-004 D9) ;
  # avant `/entries/<kind>/…`.
  path "/entries/received-invoice", PartiduoUi::ReceivedInvoiceHandler, name: "entry_received"
  path "/entries/received-invoice/check", PartiduoUi::ReceivedInvoiceCheckHandler, name: "entry_received_check"
  path "/entries/received-invoice/upload", PartiduoUi::ReceivedInvoiceUploadHandler, name: "entry_received_upload"
  path "/entries/sale", PartiduoUi::SaleEntryHandler, name: "entry_sale"
  path "/entries/financial", PartiduoUi::FinancialEntryHandler, name: "entry_financial"
  path "/entries/misc", PartiduoUi::MiscEntryHandler, name: "entry_misc"
  path "/entries/<kind:str>/check", PartiduoUi::EntryCheckHandler, name: "entry_check"
  path "/entries/<kind:str>/line", PartiduoUi::EntryLineHandler, name: "entry_line"
  path "/complete", PartiduoUi::AccountCompletionHandler, name: "complete"
  # Consultation : écritures, comptes et tiers (ADR-005 D9), lettrage.
  path "/entries", PartiduoUi::EntriesHandler, name: "entries"
  path "/entries/<id:int>", PartiduoUi::EntryShowHandler, name: "entry"
  path "/entries/<id:int>/cancel", PartiduoUi::EntryCancelHandler, name: "entry_cancel"
  path "/accounts", PartiduoUi::StatementHandler, name: "accounts"
  path "/matching", PartiduoUi::MatchingHandler, name: "matching"
  path "/matching/check", PartiduoUi::MatchingCheckHandler, name: "matching_check"
  path "/matching/<id:int>/unmatch", PartiduoUi::UnmatchHandler, name: "unmatch"
  # Rapprochement bancaire (D-UI-054) et fin d'exercice (D-UI-053).
  path "/reconciliation", PartiduoUi::ReconciliationHandler, name: "reconciliation"
  path "/reconciliation/check", PartiduoUi::ReconciliationCheckHandler, name: "reconciliation_check"
  path "/reconciliation/statements/<id:int>", PartiduoUi::BankStatementHandler, name: "bank_statement"
  path "/reconciliation/statements/<id:int>/delete", PartiduoUi::BankStatementDeleteHandler, name: "bank_statement_delete"
  path "/closing", PartiduoUi::ClosingHandler, name: "closing"
  # Historique de la Facturation à comptabiliser (ADR-006 D2).
  path "/invoicing-history", PartiduoUi::InvoicingHistoryHandler, name: "invoicing_history"
  path "/invoicing-history/post", PartiduoUi::InvoicingHistoryPostHandler, name: "invoicing_history_post"
  path "/invoicing-history/<id:int>/dismiss", PartiduoUi::InvoicingHistoryDismissHandler, name: "invoicing_history_dismiss"
  path "/invoicing-history/<id:int>/restore", PartiduoUi::InvoicingHistoryRestoreHandler, name: "invoicing_history_restore"
  # Éditions (lot 3) : balances, grand livre, journaux, bilan, compte de
  # résultat, rapports personnalisés, FEC ; `?format=csv|pdf` exporte.
  path "/reports/trial-balance", PartiduoUi::TrialBalanceHandler, name: "trial_balance"
  path "/reports/auxiliary-balance", PartiduoUi::AuxiliaryBalanceHandler, name: "auxiliary_balance"
  path "/reports/aged-balance", PartiduoUi::AgedBalanceHandler, name: "aged_balance"
  path "/reports/general-ledger", PartiduoUi::GeneralLedgerHandler, name: "general_ledger"
  path "/reports/journals", PartiduoUi::JournalsHandler, name: "journals"
  path "/reports/balance-sheet", PartiduoUi::BalanceSheetHandler, name: "balance_sheet"
  path "/reports/income-statement", PartiduoUi::IncomeStatementHandler, name: "income_statement"
  path "/reports/custom", PartiduoUi::CustomReportsHandler, name: "reports"
  path "/reports/custom/new", PartiduoUi::CustomReportNewHandler, name: "report_new"
  path "/reports/custom/<id:int>", PartiduoUi::CustomReportHandler, name: "report"
  path "/reports/custom/<id:int>/edit", PartiduoUi::CustomReportEditHandler, name: "report_edit"
  path "/reports/custom/<id:int>/delete", PartiduoUi::CustomReportDeleteHandler, name: "report_delete"
  path "/reports/fec", PartiduoUi::FecHandler, name: "fec"
  # Prévisions budgétaires (lot 6, menu `accounting:forecasts`).
  path "/forecasts", PartiduoUi::ForecastsHandler, name: "forecasts"
  path "/forecasts/new", PartiduoUi::ForecastNewHandler, name: "forecast_new"
  path "/forecasts/<id:int>", PartiduoUi::ForecastHandler, name: "forecast"
  path "/forecasts/<id:int>/edit", PartiduoUi::ForecastEditHandler, name: "forecast_edit"
  path "/forecasts/<id:int>/delete", PartiduoUi::ForecastDeleteHandler, name: "forecast_delete"
  path "/forecasts/<id:int>/clone", PartiduoUi::ForecastCloneHandler, name: "forecast_clone"
  path "/forecasts/<id:int>/report", PartiduoUi::ForecastReportHandler, name: "forecast_report"
  path "/forecasts/<id:int>/categories/new", PartiduoUi::ForecastCategoryNewHandler, name: "forecast_category_new"
  path "/forecasts/<id:int>/categories/<category_id:int>/edit", PartiduoUi::ForecastCategoryEditHandler, name: "forecast_category_edit"
  path "/forecasts/<id:int>/categories/<category_id:int>/delete", PartiduoUi::ForecastCategoryDeleteHandler, name: "forecast_category_delete"
  path "/forecasts/<id:int>/categories/<category_id:int>/items/new", PartiduoUi::ForecastItemNewHandler, name: "forecast_item_new"
  path "/forecasts/<id:int>/items/<item_id:int>/edit", PartiduoUi::ForecastItemEditHandler, name: "forecast_item_edit"
  path "/forecasts/<id:int>/items/<item_id:int>/delete", PartiduoUi::ForecastItemDeleteHandler, name: "forecast_item_delete"
  # Déclarations de TVA (lot 4, menu `accounting:vat_return`) : préparation,
  # déclaration enregistrée, contrôle, historique, exports, paramètres.
  path "/vat", PartiduoUi::VatPrepareHandler, name: "vat_return"
  path "/vat/returns", PartiduoUi::VatReturnsHandler, name: "vat_returns"
  path "/vat/returns/new", PartiduoUi::VatReturnCreateHandler, name: "vat_return_create"
  path "/vat/returns/<id:int>", PartiduoUi::VatReturnHandler, name: "vat_return_show"
  path "/vat/returns/<id:int>/edit", PartiduoUi::VatReturnEditHandler, name: "vat_return_edit"
  path "/vat/returns/<id:int>/recompute", PartiduoUi::VatReturnRecomputeHandler, name: "vat_return_recompute"
  path "/vat/returns/<id:int>/control", PartiduoUi::VatReturnControlHandler, name: "vat_return_control"
  path "/vat/returns/<id:int>/close", PartiduoUi::VatReturnCloseHandler, name: "vat_return_close"
  path "/vat/returns/<id:int>/settle", PartiduoUi::VatReturnSettleHandler, name: "vat_return_settle"
  path "/vat/returns/<id:int>/delete", PartiduoUi::VatReturnDeleteHandler, name: "vat_return_delete"
  path "/vat/returns/<id:int>/file", PartiduoUi::VatReturnFileHandler, name: "vat_return_file"
  path "/vat/settings", PartiduoUi::VatSettingsHandler, name: "vat_settings"
  # Comptes des registres de la micro-entreprise (ADR-007 D2).
  path "/micro-accounts", PartiduoUi::MicroAccountsHandler, name: "micro_accounts"
  # Comptes de la profession libérale (ADR-007 D6).
  path "/liberal-accounts", PartiduoUi::LiberalAccountsHandler, name: "liberal_accounts"
  path "/vat/rules/<regime:str>/<box:str>", PartiduoUi::VatRulesHandler, name: "vat_rules"
  path "/vat/reset-rules/<regime:str>", PartiduoUi::VatRulesResetHandler, name: "vat_rules_reset"
end

# Module Facturation (menus `invoicing:documents`, `to_invoice`, `invoice_new`,
# `payments`, `reminders`, `export`, `templates`, `settings`). Module inactif : le contrat refuse, l'écran répond 404.
INVOICING_ROUTES = Marten::Routing::Map.draw do
  path "/documents", PartiduoUi::DocumentsHandler, name: "documents"
  path "/documents/new", PartiduoUi::DocumentNewHandler, name: "document_new"
  path "/invoices/new", PartiduoUi::InvoiceNewHandler, name: "invoice_new"
  path "/documents/check", PartiduoUi::DocumentCheckHandler, name: "document_check"
  path "/documents/line", PartiduoUi::DocumentLineHandler, name: "document_line"
  path "/documents/delivery", PartiduoUi::DocumentDeliveryHandler, name: "document_delivery"
  path "/documents/<id:int>", PartiduoUi::DocumentHandler, name: "document"
  path "/documents/<id:int>/edit", PartiduoUi::DocumentEditHandler, name: "document_edit"
  path "/documents/<id:int>/preview", PartiduoUi::DocumentPreviewHandler, name: "document_preview"
  path "/documents/<id:int>/pdf", PartiduoUi::DocumentPdfHandler, name: "document_pdf"
  path "/documents/<id:int>/issue", PartiduoUi::DocumentIssueHandler, name: "document_issue"
  path "/documents/<id:int>/transform", PartiduoUi::DocumentTransformHandler, name: "document_transform"
  path "/documents/<id:int>/decide", PartiduoUi::DocumentDecideHandler, name: "document_decide"
  path "/documents/<id:int>/delete", PartiduoUi::DocumentDeleteHandler, name: "document_delete"
  path "/documents/<id:int>/payment", PartiduoUi::DocumentPaymentHandler, name: "document_payment"
  # Canal d'émission et envoi hors courriel (ADR-004 D9).
  path "/documents/<id:int>/channel", PartiduoUi::DocumentChannelHandler, name: "document_channel"
  path "/documents/<id:int>/mark-sent", PartiduoUi::DocumentMarkSentHandler, name: "document_mark_sent"
  path "/documents/<id:int>/pdf-copy", PartiduoUi::DocumentPdfCopyHandler, name: "document_pdf_copy"
  path "/express-customer", PartiduoUi::ExpressCustomerHandler, name: "express_customer"
  path "/documents/<id:int>/send-pdf-copy", PartiduoUi::DocumentSendPdfCopyHandler, name: "document_send_pdf_copy"
  path "/payments", PartiduoUi::PaymentsHandler, name: "payments"
  path "/reminders", PartiduoUi::RemindersHandler, name: "reminders"
  path "/reminders/propose", PartiduoUi::RemindersProposeHandler, name: "reminders_propose"
  path "/reminders/<id:int>/send", PartiduoUi::ReminderSendHandler, name: "reminder_send"
  path "/reminders/<id:int>/dismiss", PartiduoUi::ReminderDismissHandler, name: "reminder_dismiss"
  path "/export", PartiduoUi::ExportHandler, name: "export"
  # Bons à facturer, facture récapitulative, fin de mois, réglage client
  # (DECISIONS D-INV2-010).
  path "/to-invoice", PartiduoUi::ToInvoiceHandler, name: "to_invoice"
  path "/to-invoice/month", PartiduoUi::MonthPrepareHandler, name: "month_prepare"
  path "/to-invoice/send-all", PartiduoUi::ProposalsIssueSendHandler, name: "proposals_issue_send"
  path "/documents/<id:int>/issue-send", PartiduoUi::DocumentIssueSendHandler, name: "document_issue_send"
  path "/customers/<id:int>/billing", PartiduoUi::CustomerBillingHandler, name: "customer_billing"
  # Retours de marchandises et paiements rejetés (DECISIONS D-INV3-012) :
  # avoir d'un ou de plusieurs bons de retour, rejet d'un règlement.
  path "/to-invoice/credit-returns", PartiduoUi::ReturnNotesCreditHandler, name: "credit_returns"
  path "/documents/<id:int>/payments/<payment_id:int>/reject", PartiduoUi::PaymentRejectHandler, name: "payment_reject"
  path "/documents/<id:int>/send", PartiduoUi::DocumentSendHandler, name: "document_send"
  # Paramètres et modèles de mise en page (menus `invoicing:settings`, `templates`).
  path "/settings", PartiduoUi::InvoicingSettingsHandler, name: "settings"
  path "/templates", PartiduoUi::LayoutsHandler, name: "templates"
  path "/templates/new", PartiduoUi::LayoutNewHandler, name: "template_new"
  path "/templates/<id:int>/edit", PartiduoUi::LayoutEditHandler, name: "template_edit"
  path "/templates/<id:int>/delete", PartiduoUi::LayoutDeleteHandler, name: "template_delete"
end

# Module Analytique (lot 5, menus `analytic:plans`, `keys`,
# `misc_operations`, `reports`, `settings`) : plans, groupes et postes, clés
# de répartition, opérations diverses, ventilation d'une écriture,
# paramètres, éditions (`?format=csv` exporte). Module inactif : 404.
ANALYTIC_ROUTES = Marten::Routing::Map.draw do
  path "/plans", PartiduoUi::AnalyticPlansHandler, name: "plans"
  path "/plans/new", PartiduoUi::AnalyticPlanNewHandler, name: "plan_new"
  path "/plans/<id:int>", PartiduoUi::AnalyticPlanHandler, name: "plan"
  path "/plans/<id:int>/edit", PartiduoUi::AnalyticPlanEditHandler, name: "plan_edit"
  path "/plans/<id:int>/delete", PartiduoUi::AnalyticPlanDeleteHandler, name: "plan_delete"
  path "/plans/<plan_id:int>/posts/new", PartiduoUi::AnalyticPostNewHandler, name: "post_new"
  path "/plans/<plan_id:int>/groups/new", PartiduoUi::AnalyticGroupNewHandler, name: "group_new"
  path "/posts/<id:int>", PartiduoUi::AnalyticPostHandler, name: "post"
  path "/posts/<id:int>/edit", PartiduoUi::AnalyticPostEditHandler, name: "post_edit"
  path "/posts/<id:int>/delete", PartiduoUi::AnalyticPostDeleteHandler, name: "post_delete"
  path "/groups/<id:int>/edit", PartiduoUi::AnalyticGroupEditHandler, name: "group_edit"
  path "/groups/<id:int>/delete", PartiduoUi::AnalyticGroupDeleteHandler, name: "group_delete"
  path "/keys", PartiduoUi::AnalyticKeysHandler, name: "keys"
  path "/keys/new", PartiduoUi::AnalyticKeyNewHandler, name: "key_new"
  path "/keys/<id:int>", PartiduoUi::AnalyticKeyHandler, name: "key"
  path "/keys/<id:int>/edit", PartiduoUi::AnalyticKeyEditHandler, name: "key_edit"
  path "/keys/<id:int>/delete", PartiduoUi::AnalyticKeyDeleteHandler, name: "key_delete"
  path "/misc", PartiduoUi::AnalyticMiscOperationsHandler, name: "misc_operations"
  path "/misc/new", PartiduoUi::AnalyticMiscNewHandler, name: "misc_new"
  path "/misc/<id:int>", PartiduoUi::AnalyticMiscHandler, name: "misc_operation"
  path "/misc/<id:int>/edit", PartiduoUi::AnalyticMiscEditHandler, name: "misc_edit"
  path "/misc/<id:int>/delete", PartiduoUi::AnalyticMiscDeleteHandler, name: "misc_delete"
  path "/entries/<id:int>", PartiduoUi::AnalyticEntryDistributionHandler, name: "entry_distribution"
  path "/settings", PartiduoUi::AnalyticSettingsHandler, name: "settings"
  path "/reports", PartiduoUi::AnalyticBalanceHandler, name: "reports"
  path "/reports/cross", PartiduoUi::AnalyticCrossBalanceHandler, name: "cross_balance"
  path "/reports/groups", PartiduoUi::AnalyticGroupBalanceHandler, name: "group_balance"
  path "/reports/history", PartiduoUi::AnalyticHistoryHandler, name: "history"
  path "/reports/ledger", PartiduoUi::AnalyticLedgerHandler, name: "ledger"
  path "/reports/table", PartiduoUi::AnalyticTableHandler, name: "table"
  path "/reports/undistributed", PartiduoUi::AnalyticUndistributedHandler, name: "undistributed"
end

# Module Stock (lot 6, menus `stock:changes`, `inventory`, `state`,
# `history`, `valuation`, `repositories`, `items`) : dépôts et dépôt par
# défaut, articles suivis, opérations manuelles, inventaire, éditions
# (`?format=csv` exporte). Module inactif : 404.
STOCK_ROUTES = Marten::Routing::Map.draw do
  path "/repositories", PartiduoUi::StockRepositoriesHandler, name: "repositories"
  path "/repositories/new", PartiduoUi::StockRepositoryNewHandler, name: "repository_new"
  path "/repositories/<id:int>", PartiduoUi::StockRepositoryHandler, name: "repository"
  path "/repositories/<id:int>/edit", PartiduoUi::StockRepositoryEditHandler, name: "repository_edit"
  path "/repositories/<id:int>/delete", PartiduoUi::StockRepositoryDeleteHandler, name: "repository_delete"
  path "/settings", PartiduoUi::StockSettingsHandler, name: "settings"
  path "/rights", PartiduoUi::StockRightsHandler, name: "rights"
  path "/items", PartiduoUi::StockItemsHandler, name: "items"
  path "/items/new", PartiduoUi::StockItemNewHandler, name: "item_new"
  path "/items/<card_id:int>/edit", PartiduoUi::StockItemEditHandler, name: "item_edit"
  path "/items/<card_id:int>/delete", PartiduoUi::StockItemDeleteHandler, name: "item_delete"
  path "/changes", PartiduoUi::StockChangesHandler, name: "changes"
  path "/changes/new", PartiduoUi::StockChangeNewHandler, name: "change_new"
  path "/changes/<id:int>", PartiduoUi::StockChangeHandler, name: "change"
  path "/changes/<id:int>/delete", PartiduoUi::StockChangeDeleteHandler, name: "change_delete"
  path "/inventory", PartiduoUi::StockInventoryHandler, name: "inventory"
  path "/state", PartiduoUi::StockStateHandler, name: "state"
  path "/history", PartiduoUi::StockHistoryHandler, name: "history"
  path "/valuation", PartiduoUi::StockValuationHandler, name: "valuation"
end

# Module Suivi (lot 6, menus `followup:actions`, `reminders`, `types`,
# `tags`) : actions de suivi, commentaires, actions liées, opérations
# rattachées, rappels, types d'action, étiquettes. Module inactif : 404.
FOLLOWUP_ROUTES = Marten::Routing::Map.draw do
  path "/actions", PartiduoUi::FollowupActionsHandler, name: "actions"
  path "/actions/new", PartiduoUi::FollowupActionNewHandler, name: "action_new"
  path "/actions/<id:int>", PartiduoUi::FollowupActionHandler, name: "action"
  path "/actions/<id:int>/edit", PartiduoUi::FollowupActionEditHandler, name: "action_edit"
  path "/actions/<id:int>/delete", PartiduoUi::FollowupActionDeleteHandler, name: "action_delete"
  path "/actions/<id:int>/state", PartiduoUi::FollowupActionStateHandler, name: "action_state"
  path "/actions/<id:int>/comment", PartiduoUi::FollowupActionCommentHandler, name: "action_comment"
  path "/actions/<id:int>/relate", PartiduoUi::FollowupActionRelateHandler, name: "action_relate"
  path "/actions/<id:int>/unrelate/<other_id:int>", PartiduoUi::FollowupActionUnrelateHandler, name: "action_unrelate"
  path "/actions/<id:int>/link", PartiduoUi::FollowupActionLinkHandler, name: "action_link"
  path "/actions/<id:int>/unlink", PartiduoUi::FollowupActionUnlinkHandler, name: "action_unlink"
  path "/reminders", PartiduoUi::FollowupRemindersHandler, name: "reminders"
  path "/types", PartiduoUi::FollowupTypesHandler, name: "types"
  path "/types/new", PartiduoUi::FollowupTypeNewHandler, name: "type_new"
  path "/types/defaults", PartiduoUi::FollowupTypesDefaultsHandler, name: "types_defaults"
  path "/types/<id:int>/edit", PartiduoUi::FollowupTypeEditHandler, name: "type_edit"
  path "/types/<id:int>/delete", PartiduoUi::FollowupTypeDeleteHandler, name: "type_delete"
  path "/tags", PartiduoUi::FollowupTagsHandler, name: "tags"
  path "/tags/new", PartiduoUi::FollowupTagNewHandler, name: "tag_new"
  path "/tags/<id:int>/edit", PartiduoUi::FollowupTagEditHandler, name: "tag_edit"
  path "/tags/<id:int>/delete", PartiduoUi::FollowupTagDeleteHandler, name: "tag_delete"
end

# Module micro-entreprise (ADR-007 D1, D3 ; menus `micro:receipts`,
# `purchases`, `urssaf`, `tax_return`, `thresholds`, `settings`) : livre des
# recettes, registre des achats (saisie en quelques champs, modification et
# suppression en période ouverte, contre-passation en période déclarée ou
# close, D-MIC2-001, éditions `?format=csv|pdf`), aide URSSAF, 2042-C-PRO,
# seuils, paramètres (natures, paramètres datés, natures des articles,
# bascules guidées vers la TVA et le régime réel, republication vers la
# Comptabilité), facture allégée. Module inactif : 404.
MICRO_ROUTES = Marten::Routing::Map.draw do
  path "/receipts", PartiduoUi::ReceiptsHandler, name: "receipts"
  path "/receipts/new", PartiduoUi::ReceiptNewHandler, name: "receipt_new"
  path "/receipts/<id:int>", PartiduoUi::ReceiptHandler, name: "receipt"
  path "/receipts/<id:int>/reverse", PartiduoUi::ReceiptReverseHandler, name: "receipt_reverse"
  path "/receipts/<id:int>/edit", PartiduoUi::ReceiptEditHandler, name: "receipt_edit"
  path "/receipts/<id:int>/delete", PartiduoUi::ReceiptDeleteHandler, name: "receipt_delete"
  path "/purchases", PartiduoUi::PurchasesHandler, name: "purchases"
  path "/purchases/new", PartiduoUi::PurchaseNewHandler, name: "purchase_new"
  path "/purchases/<id:int>", PartiduoUi::PurchaseHandler, name: "purchase"
  path "/purchases/<id:int>/reverse", PartiduoUi::PurchaseReverseHandler, name: "purchase_reverse"
  path "/purchases/<id:int>/edit", PartiduoUi::PurchaseEditHandler, name: "purchase_edit"
  path "/purchases/<id:int>/delete", PartiduoUi::PurchaseDeleteHandler, name: "purchase_delete"
  path "/urssaf", PartiduoUi::UrssafHandler, name: "urssaf"
  path "/urssaf/declare", PartiduoUi::UrssafDeclareHandler, name: "urssaf_declare"
  path "/tax-return", PartiduoUi::TaxReturnHandler, name: "tax_return"
  path "/thresholds", PartiduoUi::ThresholdsHandler, name: "thresholds"
  path "/settings", PartiduoUi::MicroSettingsHandler, name: "settings"
  path "/natures", PartiduoUi::MicroNaturesHandler, name: "natures"
  path "/natures/<id:int>", PartiduoUi::MicroNatureHandler, name: "nature"
  path "/parameters", PartiduoUi::MicroParametersHandler, name: "parameters"
  path "/parameters/<id:int>/delete", PartiduoUi::MicroParameterDeleteHandler, name: "parameter_delete"
  path "/items", PartiduoUi::MicroItemNaturesHandler, name: "items"
  path "/switch/vat", PartiduoUi::MicroVatSwitchHandler, name: "switch_vat"
  path "/switch/real", PartiduoUi::MicroRealSwitchHandler, name: "switch_real"
  path "/republish", PartiduoUi::MicroRepublishHandler, name: "republish"
  path "/invoices/new", PartiduoUi::MicroInvoiceNewHandler, name: "invoice_new"
end

# Module de la profession libérale (ADR-007 D6 ; menus `liberal:journal`,
# `assets`, `tax_return`, `settings`) : livre-journal (tout, recettes,
# dépenses ; saisie en quelques champs, modification et suppression tant
# que l'exercice est ouvert, contre-passation une fois figé, D-LIB2-001,
# éditions `?format=csv|pdf`), immobilisations (acquisition, modification et
# suppression dans un exercice ouvert, contre-passation, cession et sa
# suppression, plan d'amortissement), 2035 préparée (réintégrations et
# déductions, édition de contrôle `?format=pdf`), clôture et réouverture de
# l'exercice (POST, D-LIB5-001), paramètres (natures, table
# de correspondance, valeurs par défaut, republication). Module inactif : 404.
LIBERAL_ROUTES = Marten::Routing::Map.draw do
  path "/journal", PartiduoUi::LiberalJournalHandler, name: "journal"
  path "/receipts", PartiduoUi::LiberalReceiptsHandler, name: "receipts"
  path "/receipts/new", PartiduoUi::LiberalReceiptNewHandler, name: "receipt_new"
  path "/expenses", PartiduoUi::LiberalExpensesHandler, name: "expenses"
  path "/expenses/new", PartiduoUi::LiberalExpenseNewHandler, name: "expense_new"
  path "/lines/<id:int>", PartiduoUi::LiberalLineHandler, name: "line"
  path "/lines/<id:int>/reverse", PartiduoUi::LiberalLineReverseHandler, name: "line_reverse"
  path "/lines/<id:int>/edit", PartiduoUi::LiberalLineEditHandler, name: "line_edit"
  path "/lines/<id:int>/delete", PartiduoUi::LiberalLineDeleteHandler, name: "line_delete"
  path "/assets", PartiduoUi::LiberalAssetsHandler, name: "assets"
  path "/assets/new", PartiduoUi::LiberalAssetNewHandler, name: "asset_new"
  path "/assets/<id:int>", PartiduoUi::LiberalAssetHandler, name: "asset"
  path "/assets/<id:int>/reverse", PartiduoUi::LiberalAssetReverseHandler, name: "asset_reverse"
  path "/assets/<id:int>/dispose", PartiduoUi::LiberalAssetDisposeHandler, name: "asset_dispose"
  path "/assets/<id:int>/edit", PartiduoUi::LiberalAssetEditHandler, name: "asset_edit"
  path "/assets/<id:int>/delete", PartiduoUi::LiberalAssetDeleteHandler, name: "asset_delete"
  path "/assets/<id:int>/disposal/delete", PartiduoUi::LiberalDisposalDeleteHandler, name: "asset_disposal_delete"
  path "/tax-return", PartiduoUi::LiberalTaxReturnHandler, name: "tax_return"
  path "/tax-return/adjustments", PartiduoUi::LiberalAdjustmentNewHandler, name: "adjustment_new"
  path "/adjustments/<id:int>/delete", PartiduoUi::LiberalAdjustmentDeleteHandler, name: "adjustment_delete"
  path "/years/<year:int>/close", PartiduoUi::LiberalYearCloseHandler, name: "year_close"
  path "/years/<year:int>/reopen", PartiduoUi::LiberalYearReopenHandler, name: "year_reopen"
  path "/settings", PartiduoUi::LiberalSettingsHandler, name: "settings"
  path "/natures", PartiduoUi::LiberalNaturesHandler, name: "natures"
  path "/natures/<id:int>", PartiduoUi::LiberalNatureHandler, name: "nature"
  path "/form-lines", PartiduoUi::LiberalFormLinesHandler, name: "form_lines"
  path "/form-lines/<id:int>/delete", PartiduoUi::LiberalFormLineDeleteHandler, name: "form_line_delete"
  path "/defaults", PartiduoUi::LiberalDefaultsHandler, name: "defaults"
  path "/republish", PartiduoUi::LiberalRepublishHandler, name: "republish"
end

Marten.routes.draw do
  path "", CORE_ROUTES, name: "core"
  path "/cards", CARDS_ROUTES, name: "cards"
  path "/vat", VAT_ROUTES, name: "vat"
  path "/accounting", ACCOUNTING_ROUTES, name: "accounting"
  path "/invoicing", INVOICING_ROUTES, name: "invoicing"
  path "/analytic", ANALYTIC_ROUTES, name: "analytic"
  path "/stock", STOCK_ROUTES, name: "stock"
  path "/followup", FOLLOWUP_ROUTES, name: "followup"
  path "/micro", MICRO_ROUTES, name: "micro"
  path "/liberal", LIBERAL_ROUTES, name: "liberal"
  # Raccourci du menu de l'utilisateur : enregistre sa préférence
  # d'interface (DECISIONS D-UI-077).
  path "/mode", PartiduoUi::InterfaceModeHandler, name: "interface_mode"

  # Connexion (ADR-002).
  path "/login", PartiduoUi::LoginHandler, name: "login"
  path "/login/second-factor", PartiduoUi::LoginSecondFactorHandler, name: "login_second_factor"
  path "/login/passkey/options", PartiduoUi::LoginPasskeyOptionsHandler, name: "login_passkey_options"
  path "/login/passkey", PartiduoUi::LoginPasskeyHandler, name: "login_passkey"
  # Connexion fédérée (ADR-002 D3) : départ, retour OIDC (GET), réponse SAML (POST).
  path "/login/federated/<code:str>", PartiduoUi::LoginFederatedHandler, name: "login_federated"
  path "/login/federated/<code:str>/callback", PartiduoUi::LoginFederatedReturnHandler, name: "login_federated_callback"
  path "/login/federated/<code:str>/acs", PartiduoUi::LoginFederatedReturnHandler, name: "login_federated_acs"
  path "/logout", PartiduoUi::LogoutHandler, name: "logout"
  path "/invitation/<token:str>", PartiduoUi::InvitationHandler, name: "invitation"
  path "/password/forgotten", PartiduoUi::PasswordForgottenHandler, name: "password_forgotten"
  path "/password/reset/<token:str>", PartiduoUi::PasswordResetHandler, name: "password_reset"
  path "/password/check", PartiduoUi::PasswordCheckHandler, name: "password_check"
  path "/unlock", PartiduoUi::UnlockRequestHandler, name: "unlock_request"
  path "/unlock/<token:str>", PartiduoUi::UnlockHandler, name: "unlock"
  path "/language", PartiduoUi::LanguageHandler, name: "language"

  # Compte : enrôlement, sécurité, élévation (ADR-002 D6, D7).
  path "/account/enrollment", PartiduoUi::EnrollmentHandler, name: "account_enrollment"
  path "/account/security", PartiduoUi::SecurityHandler, name: "account_security"
  path "/account/password", PartiduoUi::PasswordChangeHandler, name: "account_password"
  path "/account/totp", PartiduoUi::TotpEnrollmentHandler, name: "account_totp"
  path "/account/totp/start", PartiduoUi::TotpStartHandler, name: "account_totp_start"
  path "/account/totp/disable", PartiduoUi::TotpDisableHandler, name: "account_totp_disable"
  path "/account/recovery-codes", PartiduoUi::RecoveryCodesHandler, name: "account_recovery_codes"
  path "/account/passkeys/options", PartiduoUi::PasskeyRegistrationOptionsHandler, name: "account_passkey_options"
  path "/account/passkeys", PartiduoUi::PasskeyRegistrationHandler, name: "account_passkeys"
  path "/account/passkeys/<id:int>/rename", PartiduoUi::PasskeyRenameHandler, name: "account_passkey_rename"
  path "/account/passkeys/<id:int>/delete", PartiduoUi::PasskeyRemoveHandler, name: "account_passkey_remove"
  path "/account/passkey-prompt", PartiduoUi::PasskeyPromptHandler, name: "account_passkey_prompt"
  path "/account/elevate/totp", PartiduoUi::ElevateTotpHandler, name: "account_elevate_totp"
  path "/account/elevate/passkey/options", PartiduoUi::ElevatePasskeyOptionsHandler, name: "account_elevate_passkey_options"
  path "/account/elevate/passkey", PartiduoUi::ElevatePasskeyHandler, name: "account_elevate_passkey"
  # Préférences de l'utilisateur : interface (DECISIONS D-UI-077).
  path "/account/preferences", PartiduoUi::PreferencesHandler, name: "account_preferences"

  path "/search", PartiduoUi::SearchHandler, name: "search"
  path "/about", PartiduoUi::AboutHandler, name: "about"

  # Interfaces d'extension (ADR-003 D3) : toute requête sous /ext/<CODE>/
  # passe par le contrôle d'accès, qui appelle ensuite le handler de
  # l'extension. Les cartes de routes des extensions sont ajoutées par
  # PartiduoUi::App#setup, après ces deux règles : elles servent à nommer
  # les routes (`uitest:index`), jamais à les atteindre directement.
  # `/ext/<CODE>` sans barre finale aussi : une route d'extension de chemin
  # vide (`path ""`) serait sinon servie par la carte de l'extension, sans
  # contrôle.
  path "/ext/<code:str>", PartiduoUi::ExtensionHandler, name: "extension_bare"
  path "/ext/<code:str>/", PartiduoUi::ExtensionHandler, name: "extension_root"
  path "/ext/<code:str>/<path:path>", PartiduoUi::ExtensionHandler, name: "extension"

  # Routes publiques d'extension (A-FRM-1), sans session : toute requête sous
  # /p/<code>/ passe par PartiduoUi::PublicExtensionHandler (extension active,
  # limitation de débit, taille, en-têtes stricts). Les cartes des
  # extensions sont ajoutées après, pour le nommage seulement.
  path "/p/<code:str>", PartiduoUi::PublicExtensionHandler, name: "public_extension_bare"
  path "/p/<code:str>/", PartiduoUi::PublicExtensionHandler, name: "public_extension_root"
  path "/p/<code:str>/<path:path>", PartiduoUi::PublicExtensionHandler, name: "public_extension"

  # Fichiers statiques servis par Marten : directement depuis les applications
  # en développement et en test ; en production, après `collectassets`, par le
  # middleware Marten::Middleware::AssetServing (config/settings/production.cr).
  if Marten.env.development? || Marten.env.test?
    path "#{Marten.settings.assets.url}<path:path>", Marten::Handlers::Defaults::Development::ServeAsset, name: "asset"
  end
end
