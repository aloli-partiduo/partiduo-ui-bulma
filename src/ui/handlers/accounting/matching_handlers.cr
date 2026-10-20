# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Lettrage (menu `accounting:matching`, ADR-001 lot 2) : lignes non lettrées
  # d'un compte ou d'un tiers, cochées puis lettrées (`match_lines`) ; la
  # sélection est contrôlée à chaque case cochée par `check_matching` (HTMX),
  # avec les totaux des lignes choisies ; lettrages existants défaits par
  # `unmatch`. Sans JavaScript, le bouton « Lettrer » envoie la sélection.
  class MatchingView
    include Marten::Template::Object::Auto

    class Line
      include Marten::Template::Object::Auto

      getter id : Int64
      getter date : String
      getter ledger : String
      getter receipt : String
      getter label : String
      getter entry_url : String
      getter due_date : String
      getter overdue : Bool
      getter debit : String
      getter credit : String
      getter letter : String
      getter checked : Bool

      def initialize(@id, @date, @ledger, @receipt, @label, @entry_url, @due_date, @overdue, @debit, @credit, @letter, @checked)
      end
    end

    class Group
      include Marten::Template::Object::Auto

      getter id : Int64
      getter code : String
      getter lines : String
      getter difference : String
      getter balanced : Bool
      getter unmatch_url : String

      def initialize(@id, @code, @lines, @difference, @balanced, @unmatch_url)
      end
    end

    getter title : String
    getter lines : Array(Line)?
    getter groups : Array(Group)?

    def initialize(@title, @lines, @groups)
    end
  end

  # Sélection contrôlée : totaux des lignes cochées et refus du contrat.
  class MatchingCheck
    include Marten::Template::Object::Auto

    getter count : Int32
    getter debit : String
    getter credit : String
    getter difference : String
    getter balanced : Bool
    getter errors : Array(String)?

    def initialize(@count, @debit, @credit, @difference, @balanced, @errors)
    end
  end

  abstract class MatchingScreen < AccountingScreen
    PERMISSION = "accounting.matching.write"

    def selection : String
      query("q").presence || field("q")
    end

    def statement(text : String, unmatched_only : Bool) : Acc::AccountStatementView?
      card = card_code?(text)
      Acc.account_statement(current.actor, Acc::StatementQuery.new(account: card ? nil : text, card: card, unmatched_only: unmatched_only))
    rescue Partiduo::Api::NotFound
      nil
    end

    def selected_ids : Array(Int64)
      values = request.data.fetch_all("line", [] of String) || [] of String
      values.compact_map(&.to_s.to_i64?).uniq!
    end

    def check_view(statement : Acc::AccountStatementView?, ids : Array(Int64)) : MatchingCheck
      lines = statement.try(&.lines.select { |line| ids.includes?(line.line_id) }) || [] of Acc::StatementLineView
      debit = lines.sum(BigDecimal.new(0), &.debit)
      credit = lines.sum(BigDecimal.new(0), &.credit)
      errors = nil
      if ids.size >= 2
        result = Acc.check_matching(current.actor, ids)
        errors = result.errors.map { |error| fmt.message(error) } unless result.success?
      end
      MatchingCheck.new(ids.size, fmt.amount(debit), fmt.amount(credit), fmt.amount((debit - credit).abs), debit == credit && !debit.zero?,
        errors.try { |list| list.empty? ? nil : list })
    end
  end

  class MatchingHandler < MatchingScreen
    def get
      require!("ACCOUNTING", PERMISSION)
      show(selection)
    end

    def post
      require!("ACCOUNTING", PERMISSION)
      text = field("q")
      ids = selected_ids
      result = Acc.match_lines(current.actor, ids)
      if matching = result.value?
        flash["success"] = I18n.t("ui.matching.done", code: matching.code, count: matching.lines.size)
        return go("#{reverse("accounting:matching")}?#{URI::Params.encode({"q" => text})}")
      end
      show(text, ids, 422, result.errors.map { |error| fmt.message(error) })
    end

    private def show(text : String, checked = [] of Int64, status : Int32 = 200, refused : Array(String)? = nil) : Marten::HTTP::Response
      context["title"] = I18n.t("accounting.menu.acc_matching")
      context["crumbs"] = [crumb("core.menu.consult"), crumb("accounting.menu.acc_matching", reverse("accounting:matching"))]
      context["q"] = text
      context["matching"] = nil
      context["not_found"] = nil
      context["check"] = nil
      context["refused"] = refused
      context["statement_url"] = nil
      context["statement_key"] = kind_key("accounting.menu.acc_accounts")
      unless text.empty?
        open = statement(text, true)
        full = statement(text, false)
        if open.nil? || full.nil?
          context["not_found"] = I18n.t(kind_key("ui.accounts.not_found"), q: text)
          return page("ui/accounting/matching.html", status: 404)
        end
        context["matching"] = view(open, full, checked)
        context["check"] = check_view(open, checked)
        context["statement_url"] = "#{reverse("accounting:accounts")}?#{URI::Params.encode({"q" => text})}"
      end
      page("ui/accounting/matching.html", status: status)
    end

    private def view(open : Acc::AccountStatementView, full : Acc::AccountStatementView, checked : Array(Int64)) : MatchingView
      title = open.card_name || open.account.try { |account| "#{account.number} · #{account.label}" } || ""
      lines = open.lines.map do |line|
        MatchingView::Line.new(line.line_id, fmt.date(line.date), line.ledger_code, line.receipt || "", line.label,
          reverse("accounting:entry", id: line.entry_id), fmt.date(line.due_date), line.overdue,
          line.debit.zero? ? "" : fmt.amount(line.debit), line.credit.zero? ? "" : fmt.amount(line.credit),
          line.matching_code || "", checked.includes?(line.line_id))
      end
      groups = full.lines.select(&.matching_id).group_by { |line| line.matching_id || 0_i64 }.map do |id, members|
        difference = members.sum(BigDecimal.new(0)) { |line| line.debit - line.credit }
        MatchingView::Group.new(id, members.first.matching_code || "", members.map { |line| line.receipt || line.label }.join(", "),
          fmt.amount(difference.abs), difference.zero?, reverse("accounting:unmatch", id: id))
      end
      MatchingView.new(title, lines.empty? ? nil : lines, groups.empty? ? nil : groups.last(50))
    end
  end

  # Contrôle de la sélection (HTMX, à chaque case cochée).
  class MatchingCheckHandler < MatchingScreen
    def post
      require!("ACCOUNTING", PERMISSION)
      text = field("q")
      check = check_view(text.empty? ? nil : statement(text, true), selected_ids)
      render("ui/accounting/_matching_check.html", {"check" => check})
    end
  end

  class UnmatchHandler < MatchingScreen
    def post
      require!("ACCOUNTING", PERMISSION)
      matching = Acc.matching(current.actor, id_param)
      result = Acc.unmatch(current.actor, matching.id)
      if result.success?
        flash["success"] = I18n.t("ui.matching.undone", code: matching.code)
      else
        flash["danger"] = result.errors.map { |error| fmt.message(error) }.join(" ")
      end
      back = field("q").presence || matching.account_number
      go("#{reverse("accounting:matching")}?#{URI::Params.encode({"q" => back})}")
    end
  end
end
