# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"

module PartiduoUi
  # Écran d'import CSV commun aux fiches et au plan comptable (DECISIONS
  # D-OUT-007) : dépôt du fichier (ou contenu collé), format, aperçu à blanc
  # ligne à ligne avec la suite prévue ou les motifs du refus, association
  # des colonnes modifiable, puis import. Rien ne passe d'office : avec une
  # ligne refusée, l'import exige de cocher « importer seulement les lignes
  # acceptées ». Le fichier ne séjourne pas sur le serveur : son contenu
  # voyage dans le formulaire (base64) d'une étape à l'autre.
  abstract class ImportScreen < ReferenceHandler
    alias Core = Partiduo::Api::Core

    # Taille au plus d'un fichier déposé : le contenu repasse, encodé, dans
    # chaque envoi du formulaire (limite des requêtes de Marten : 2,5 Mo).
    MAX_UPLOAD = 1_500_000
    # Lignes acceptées montrées dans l'aperçu ; les refusées le sont toutes.
    SHOWN_ROWS = 100

    # Valeurs des listes : noms (une tabulation ne survit pas sûrement dans
    # un attribut HTML) ; un caractère envoyé tel quel est aussi accepté.
    SEPARATORS = {"semicolon" => ';', "comma" => ',', "tab" => '\t', "pipe" => '|'}
    QUOTES     = {"double" => '"', "single" => '\''}

    # Colonne du fichier : numéro, champ associé (liste), exemple de valeur.
    class ColumnChoice
      include Marten::Template::Object::Auto

      getter index : Int32
      getter name : String
      getter label : String
      getter options : Array(Form::Option)
      getter sample : String

      def initialize(@index, @label, @options, @sample)
        @name = "column-#{@index}"
      end
    end

    # Ligne de l'aperçu, mise en forme.
    class PreviewRow
      include Marten::Template::Object::Auto

      getter line : Int32
      getter action : String
      getter tone : String
      getter reference : String
      getter cells : Array(String)
      getter messages : Array(String)

      def initialize(@line, @action, @tone, @reference, @cells, @messages)
      end
    end

    abstract def import_title : String
    abstract def import_crumbs : Array(Screen::Crumb)
    abstract def import_path : String
    abstract def back_url : String
    abstract def update_label : String
    abstract def preview(source : Core::ImportSource) : Core::ImportView
    abstract def import(source : Core::ImportSource, skip_refused : Bool) : Partiduo::Api::Result(Core::ImportView)

    # Champs propres de l'import (catégorie), placés avant le fichier.
    def own_fields : Array(Form::Field)
      [] of Form::Field
    end

    # Aide sous le titre : format attendu.
    def import_intro : String?
      nil
    end

    # Actions de la page (export au format de l'import).
    def import_actions : Array(Screen::Action)
      [] of Screen::Action
    end

    # Module actif et permission de l'import, vérifiés avant tout affichage.
    abstract def require_import! : Nil

    def get
      require_import!
      show(options_form, nil, nil)
    end

    def post
      require_import!
      form = options_form
      content = read_content(form)
      format = read_format(form)
      return show(form, nil, nil, status: 422) if form.invalid || content.nil? || format.nil?

      columns = field("step") == "detect" ? nil : read_columns
      source = Core::ImportSource.new(content: content, format: format, columns: columns,
        update_existing: checkbox("update_existing"))
      if field("step") == "import"
        result = import(source, checkbox("skip_refused"))
        if report = result.value?
          return show(form, report, content, done: true)
        end
        result.errors.each { |error| form.add_error(Partiduo::Api::FieldError::BASE, fmt.message(error)) }
      end
      view = preview(source)
      show(form, view, content, status: form.invalid ? 422 : 200)
    end

    # --- Formulaire des options -------------------------------------------------

    def options_form : Form
      separators = SEPARATORS.keys.map { |key| option(key, I18n.t("ui.imports.separators.#{key}")) }
      quotes = QUOTES.keys.map { |key| option(key, I18n.t("ui.imports.quotes.#{key}")) }
      encodings = Core::CSV_ENCODINGS.map { |value| option(value, I18n.t("ui.imports.encodings.#{value.tr("-", "_")}")) }
      separator = SEPARATORS.key_for?(separator_char) || "semicolon"
      quote = QUOTES.key_for?(quote_char) || "double"
      Form.new([
        Form::Group.new(nil, own_fields + [
          Form::Field.new("content_text", I18n.t("ui.imports.paste"), "textarea", "", wide: true,
            help: I18n.t("ui.imports.paste_help")),
        ]),
        Form::Group.new(I18n.t("ui.imports.format"), [
          Form::Field.new("separator", I18n.t("ui.imports.separator"), "select", separator, options: separators),
          Form::Field.new("quote", I18n.t("ui.imports.quote"), "select", quote, options: quotes),
          Form::Field.new("encoding", I18n.t("ui.imports.encoding"), "select", field("encoding").presence || "utf-8",
            options: encodings),
          Form::Field.new("skip_rows", I18n.t("ui.imports.skip_rows"), value: field("skip_rows").presence || "0", mono: true,
            help: I18n.t("ui.imports.skip_rows_help")),
          Form::Field.new("update_existing", update_label, "checkbox", checkbox("update_existing") ? "1" : ""),
        ]),
      ])
    end

    # Contenu : fichier déposé, sinon texte collé, sinon contenu déjà lu
    # (champ caché des étapes suivantes).
    private def read_content(form : Form) : Bytes?
      file = request.data["file"]?
      if file.is_a?(Marten::HTTP::UploadedFile) && file.size > 0
        if file.size > MAX_UPLOAD
          form.add_error(Partiduo::Api::FieldError::BASE, I18n.t("ui.imports.too_large", max: (MAX_UPLOAD // 1000).to_s))
          return
        end
        return file.io.getb_to_end
      end
      text = field("content_text", strip: false)
      return text.to_slice unless text.strip.empty?
      encoded = field("content")
      unless encoded.empty?
        return Base64.decode(encoded)
      end
      form.add_error(Partiduo::Api::FieldError::BASE, I18n.t("ui.imports.no_file"))
      nil
    rescue Base64::Error
      form.add_error(Partiduo::Api::FieldError::BASE, I18n.t("ui.imports.no_file"))
      nil
    end

    private def read_format(form : Form) : Core::CsvFormat?
      skip = field("skip_rows").presence || "0"
      rows = skip.to_i?
      if rows.nil? || rows < 0
        form.add_error("skip_rows", I18n.t("ui.forms.invalid_integer"))
        return
      end
      Core::CsvFormat.new(separator: separator_char, quote: quote_char, encoding: field("encoding").presence || "utf-8",
        skip_rows: rows)
    end

    private def separator_char : Char
      value = field("separator", strip: false)
      SEPARATORS[value]? || value[0]? || ';'
    end

    private def quote_char : Char
      value = field("quote")
      QUOTES[value]? || value[0]? || '"'
    end

    # Association choisie dans l'aperçu (`column-0`, `column-1`…) ; `nil`
    # avant le premier aperçu : le cœur reconnaît l'en-tête.
    private def read_columns : Array(String)?
      count = field("columns").to_i?
      return unless count && count > 0
      (0...count).map { |index| field("column-#{index}") }
    end

    # --- Rendu ------------------------------------------------------------------

    private def show(form : Form, view : Core::ImportView?, content : Bytes?, status : Int32 = 200,
                     done : Bool = false) : Marten::HTTP::Response
      context["title"] = import_title
      context["crumbs"] = import_crumbs
      context["actions"] = import_actions
      context["intro"] = import_intro
      context["form"] = form
      context["form_action"] = import_path
      context["back_url"] = back_url
      context["done"] = done
      context["content"] = content.try { |bytes| Base64.strict_encode(bytes) }
      if view
        view.errors.each { |error| form.add_error(Partiduo::Api::FieldError::BASE, fmt.message(error)) } unless done
        context["preview"] = true
        context["columns"] = column_choices(view)
        context["column_count"] = view.columns.size
        rows = shown_rows(view)
        context["rows"] = rows.map { |row| preview_row(row, view) }
        hidden = view.rows.size - rows.size
        context["hidden_note"] = hidden > 0 ? I18n.t("ui.imports.hidden_rows", count: hidden) : nil
        refused = view.refused_count
        context["skip_label"] = refused > 0 ? I18n.t("ui.imports.skip_refused", count: refused) : nil
        context["importable"] = view.importable? && !done
        context["summary"] = summary(view, done)
      end
      page("ui/reference/import.html", status: status)
    end

    private def shown_rows(view : Core::ImportView) : Array(Core::ImportRowView)
      accepted = 0
      view.rows.select do |row|
        next true if row.refused?
        accepted += 1
        accepted <= SHOWN_ROWS
      end
    end

    private def summary(view : Core::ImportView, done : Bool) : String
      key = done ? "ui.imports.done" : "ui.imports.summary"
      I18n.t(key, created: view.created_count.to_s, updated: view.updated_count.to_s, refused: view.refused_count.to_s)
    end

    private def column_choices(view : Core::ImportView) : Array(ColumnChoice)
      ignored = option("", I18n.t("ui.imports.ignored"))
      choices = [ignored] + view.fields.map { |item| option(item.key, item.required ? "#{item.title} *" : item.title) }
      first = view.rows.first?
      view.columns.map_with_index do |key, index|
        options = choices.map { |choice| Form::Option.new(choice.value, choice.label, choice.value == key) }
        ColumnChoice.new(index, I18n.t("ui.imports.column", number: (index + 1).to_s), options, first.try(&.cells[index]?) || "")
      end
    end

    private def preview_row(row : Core::ImportRowView, view : Core::ImportView) : PreviewRow
      tone = case row.action
             when .create? then "is-success"
             when .update? then "is-info"
             else               "is-danger"
             end
      messages = row.errors.map do |error|
        label = error.base? ? nil : view.field(error.field).try(&.title)
        label ? I18n.t("ui.forms.label_value", label: label, value: fmt.message(error)) : fmt.message(error)
      end
      cells = (0...view.columns.size).map { |index| row.cells[index]? || "" }
      PreviewRow.new(row.line, I18n.t("core.imports.actions.#{row.action.code}"), tone, row.reference, cells, messages)
    end
  end

  # --- Fiches -------------------------------------------------------------------

  # Import de fiches d'une catégorie (`Api::Cards.preview_card_import`,
  # `import_cards`) et export de la catégorie au format de l'import.
  class CardImportHandler < ImportScreen
    def require_import! : Nil
      require!("CARDS", Partiduo::Api::Cards::IMPORT_PERMISSION)
    end

    def import_title : String
      I18n.t("ui.imports.cards_title")
    end

    def import_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.reference"), crumb("ui.cards.parties", reverse("cards:index"))]
    end

    def import_path : String
      reverse("cards:import")
    end

    def back_url : String
      reverse("cards:index")
    end

    def update_label : String
      I18n.t("ui.imports.update_cards")
    end

    def import_intro : String?
      I18n.t("ui.imports.cards_intro")
    end

    def import_actions : Array(Screen::Action)
      id = category.try(&.id)
      return [] of Screen::Action unless id
      [link_action("ui.imports.export_cards", "#{reverse("cards:export")}?#{URI::Params.encode({"category" => id.to_s})}",
        icon: "download")]
    end

    def own_fields : Array(Form::Field)
      options = categories.map { |item| option(item.id.to_s, "#{category_label(item.code, item.name)} (#{card_kind_label(item.kind)})") }
      [
        Form::Field.new("category", I18n.t("ui.cards.category"), "select", category.try(&.id.to_s) || "", options: options,
          required: true),
        Form::Field.new("file", I18n.t("ui.imports.file"), "file", help: I18n.t("ui.imports.file_help")),
      ]
    end

    def preview(source : Core::ImportSource) : Core::ImportView
      Partiduo::Api::Cards.preview_card_import(current.actor, chosen.id, source)
    end

    def import(source : Core::ImportSource, skip_refused : Bool) : Partiduo::Api::Result(Core::ImportView)
      Partiduo::Api::Cards.import_cards(current.actor, chosen.id, source, skip_refused)
    end

    @categories : Array(Partiduo::Api::Cards::CategoryView)?

    private def categories : Array(Partiduo::Api::Cards::CategoryView)
      @categories ||= Partiduo::Api::Cards.categories(current.actor)
    end

    # Catégorie choisie (formulaire, sinon paramètre `category`, sinon la
    # première).
    private def category : Partiduo::Api::Cards::CategoryView?
      wanted = (field("category").presence || query("category")).to_i64?
      categories.find(&.id.==(wanted)) || categories.first?
    end

    private def chosen : Partiduo::Api::Cards::CategoryView
      category || raise Partiduo::Api::NotFound.new("card_category", 0_i64)
    end
  end

  # Fiches d'une catégorie au format de l'import (CSV).
  class CardExportHandler < ReferenceHandler
    def get
      file = Partiduo::Api::Cards.export_cards(current.actor, query("category").to_i64? || 0_i64)
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: "text/csv; charset=utf-8")
      response["Content-Disposition"] = %(attachment; filename="#{file.filename.gsub(/["\\[:cntrl:]]/, "")}")
      response
    end
  end

  # --- Plan comptable -----------------------------------------------------------

  # Import du plan comptable (`Api::Accounting.preview_chart_import`,
  # `import_chart`) ; format d'origine accepté sans en-tête.
  class ChartImportHandler < ImportScreen
    def require_import! : Nil
      require!("ACCOUNTING", Partiduo::Api::Accounting::CHART_IMPORT_PERMISSION)
    end

    def import_title : String
      I18n.t("ui.imports.chart_title")
    end

    def import_crumbs : Array(Screen::Crumb)
      [crumb("core.menu.reference"), crumb("accounting.menu.acc_chart", reverse("accounting:chart"))]
    end

    def import_path : String
      reverse("accounting:chart_import")
    end

    def back_url : String
      reverse("accounting:chart")
    end

    def update_label : String
      I18n.t("ui.imports.update_accounts")
    end

    def import_intro : String?
      I18n.t("ui.imports.chart_intro")
    end

    def import_actions : Array(Screen::Action)
      [link_action("ui.imports.export_chart", reverse("accounting:chart_export"), icon: "download")]
    end

    def own_fields : Array(Form::Field)
      [Form::Field.new("file", I18n.t("ui.imports.file"), "file", help: I18n.t("ui.imports.file_help"))]
    end

    def preview(source : Core::ImportSource) : Core::ImportView
      Partiduo::Api::Accounting.preview_chart_import(current.actor, source)
    end

    def import(source : Core::ImportSource, skip_refused : Bool) : Partiduo::Api::Result(Core::ImportView)
      Partiduo::Api::Accounting.import_chart(current.actor, source, skip_refused)
    end
  end

  # Plan comptable au format de l'import (CSV).
  class ChartExportHandler < ReferenceHandler
    def get
      file = Partiduo::Api::Accounting.export_chart(current.actor)
      response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: "text/csv; charset=utf-8")
      response["Content-Disposition"] = %(attachment; filename="#{file.filename}")
      response
    end
  end
end
