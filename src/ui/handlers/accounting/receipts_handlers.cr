# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Archive des pièces jointes des écritures d'une période
  # (`Api::Accounting.receipts_archive`, DECISIONS D-OUT-005) : un
  # formulaire de consultation (dates, journal), puis le fichier ZIP. Lecture
  # seule : ni renumérotation ni modification des pièces.
  class ReceiptsArchiveHandler < AccountingScreen
    def get
      require!("ACCOUNTING", "accounting.entry.read")
      raise Partiduo::Api::Forbidden.new("core.attachment.read") unless can?("core.attachment.read")
      form = archive_form
      return show(form) if query("from").empty? && query("to").empty?

      from = query_day("from")
      to = query_day("to")
      form.add_error("from", I18n.t("ui.forms.invalid_date")) unless from
      form.add_error("to", I18n.t("ui.forms.invalid_date")) unless to
      return show(form, 422) unless from && to

      result = Acc.receipts_archive(current.actor, from, to, query("ledger").to_i64?)
      if file = result.value?
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
        return response
      end
      form.add_errors(result.errors, fmt)
      show(form, 422)
    end

    private def archive_form : Form
      period = working_period
      from = query("from").presence || fiscal_year_start.try { |day| fmt.date(day) } || ""
      to = query("to").presence || period.try { |value| fmt.date(value.ends_on) } || ""
      ledgers = [option("", I18n.t("ui.receipts_archive.all_ledgers"))]
      begin
        Acc.ledgers(current.actor).each { |ledger| ledgers << option(ledger.id.to_s, "#{ledger.code} — #{ledger.name}") }
      rescue Partiduo::Api::Forbidden
      end
      Form.new([Form::Group.new(nil, [
        Form::Field.new("from", I18n.t("ui.receipts_archive.from"), value: from, required: true, mono: true),
        Form::Field.new("to", I18n.t("ui.receipts_archive.to"), value: to, required: true, mono: true),
        Form::Field.new("ledger", I18n.t("ui.receipts_archive.ledger"), "select", query("ledger"), options: ledgers),
      ])])
    end

    private def show(form : Form, status : Int32 = 200) : Marten::HTTP::Response
      context["form_method"] = "get"
      form_page(I18n.t("ui.receipts_archive.title"), [crumb("core.menu.consult"), crumb("accounting.menu.acc_entries", reverse("accounting:entries"))],
        form, reverse("accounting:receipts_archive"), I18n.t("ui.receipts_archive.download"), reverse("accounting:entries"),
        intro: I18n.t("ui.receipts_archive.intro"), status: status)
    end
  end
end
