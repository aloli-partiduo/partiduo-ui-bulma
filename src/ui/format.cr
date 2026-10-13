# SPDX-License-Identifier: AGPL-3.0-or-later

require "big"

module PartiduoUi
  # Présentation des montants, taux et dates selon la langue de
  # l'utilisateur et le pays de la société (conventions CLDR, DECISIONS
  # D-UI-017). Les montants restent des `BigDecimal` d'un bout à l'autre :
  # aucun passage par `Float`.
  struct Format
    # Séparateurs et motif de date d'une paire langue-pays.
    record Convention, decimal : String, group : String, date : String, percent : String

    NARROW_NBSP = " "

    # Langue seule (pays sans règle propre) puis paires langue-pays.
    CONVENTIONS = {
      "fr"    => Convention.new(",", NARROW_NBSP, "%d/%m/%Y", "#{NARROW_NBSP}%"),
      "fr-BE" => Convention.new(",", NARROW_NBSP, "%d/%m/%Y", "#{NARROW_NBSP}%"),
      "nl"    => Convention.new(",", ".", "%d-%m-%Y", "%"),
      "nl-BE" => Convention.new(",", ".", "%d/%m/%Y", "%"),
      "en"    => Convention.new(".", ",", "%d/%m/%Y", "%"),
      "en-BE" => Convention.new(",", ".", "%d/%m/%Y", "%"),
      "en-FR" => Convention.new(",", NARROW_NBSP, "%d/%m/%Y", "%"),
      "en-US" => Convention.new(".", ",", "%m/%d/%Y", "%"),
    }

    getter locale : String
    getter country : String
    getter convention : Convention

    def initialize(locale : String, country : String = "")
      @locale = locale.split(/[-_]/).first.downcase
      @country = country.upcase
      @convention = CONVENTIONS["#{@locale}-#{@country}"]? || CONVENTIONS[@locale]? || CONVENTIONS["fr"]
    end

    # Montant à `decimals` décimales (arrondi au demi supérieur), groupé :
    # `1 234,50` (fr), `1.234,50` (nl-BE), `1,234.50` (en).
    def amount(value : BigDecimal?, decimals : Int32 = 2, group : Bool = true) : String
      return "" if value.nil?
      rounded = value.round(decimals, mode: :ties_away)
      digits(rounded, decimals, group)
    end

    # Nombre sans zéros inutiles (`5,5`, `20`) : taux, quantités. `group:
    # false` pour préremplir un champ de saisie (relu par `parse_decimal`).
    def number(value : BigDecimal?, max_decimals : Int32 = 4, group : Bool = true) : String
      return "" if value.nil?
      text = amount(value, max_decimals, group: group)
      return text unless text.includes?(@convention.decimal)
      text.rstrip('0').rchop(@convention.decimal)
    end

    # Valeur d'un champ de saisie numérique : sans séparateur de milliers.
    def input_number(value : BigDecimal?, max_decimals : Int32 = 6) : String
      number(value, max_decimals, group: false)
    end

    # Taux en pourcentage (`20 %`, `5,5 %`).
    def percent(value : BigDecimal?) : String
      return "" if value.nil?
      "#{number(value)}#{@convention.percent}"
    end

    def date(value : Time?) : String
      return "" if value.nil?
      value.to_s(@convention.date)
    end

    # Horodatage : date de la langue et heure `HH:MM`, dans le fuseau du
    # dossier (`Partiduo::Api::Core.time_zone`, celui de l'instance) : les
    # horodatages du cœur sont en UTC, et le serveur peut tourner en UTC.
    def datetime(value : Time?, location : Time::Location = Partiduo::Api::Core.time_zone) : String
      return "" if value.nil?
      local = value.in(location)
      "#{date(local)} #{local.to_s("%H:%M")}"
    end

    # Date d'un horodatage (création, dernière modification, gel) dans le
    # fuseau du dossier : 23 h 30 UTC le 9 mars est le 10 mars à Paris. Une
    # date du contrat (minuit UTC, convention C1) passe par `date`.
    def timestamp_date(value : Time?, location : Time::Location = Partiduo::Api::Core.time_zone) : String
      return "" if value.nil?
      date(value.in(location))
    end

    # Message d'une erreur du contrat, ses paramètres de date (ISO, seul
    # format du contrat) présentés selon la langue et le pays.
    # Les montants (nombre décimal au point, seul format du contrat) le sont
    # aussi : `150.00` devient `150,00` en français (D-UI-044).
    def message(error : Partiduo::Api::FieldError) : String
      return error.message unless error.params.values.any? { |value| value.matches?(ISO_DATE) || value.matches?(RAW_DECIMAL) }
      params = error.params.transform_values do |value|
        if value.matches?(ISO_DATE)
          parse_date(value).try { |day| date(day) } || value
        elsif value.matches?(RAW_DECIMAL)
          amount(BigDecimal.new(value), value.partition('.').last.size)
        else
          value
        end
      end
      error.copy_with(params: params).message
    end

    ISO_DATE    = /\A\d{4}-\d{2}-\d{2}\z/
    RAW_DECIMAL = /\A-?\d+\.\d+\z/

    # Nom du mois (`septembre 2026`) : période mensuelle.
    def month(value : Time) : String
      "#{I18n.t("ui.months.m#{value.month}")} #{value.year}"
    end

    # Libellé d'une période : mois entier, jour unique ou bornes.
    def period(starts_on : Time, ends_on : Time) : String
      return date(starts_on) if starts_on == ends_on
      last_day = Time.days_in_month(starts_on.year, starts_on.month)
      if starts_on.day == 1 && ends_on.year == starts_on.year && ends_on.month == starts_on.month && ends_on.day == last_day
        month(starts_on)
      else
        "#{date(starts_on)} – #{date(ends_on)}"
      end
    end

    # Montant pour un export CSV : séparateur décimal de la langue, sans
    # séparateur de milliers (relu tel quel par un tableur).
    def csv_amount(value : BigDecimal?, decimals : Int32 = 2) : String
      amount(value, decimals, group: false)
    end

    # Séparateur de champs CSV : le point-virgule quand la virgule est le
    # séparateur décimal (tableurs européens).
    def csv_separator : Char
      @convention.decimal == "," ? ';' : ','
    end

    # Lecture d'un nombre saisi dans la convention de la langue : son
    # séparateur décimal est le *seul* admis (`1,5` en fr, `1.5` en en) ; son
    # séparateur de milliers (ou une espace) n'est admis qu'entre des groupes
    # de trois chiffres (`1 234,56` en fr, `1.234,56` en nl-BE, `1,234.56` en
    # en). Toute autre écriture est refusée (`nil`) plutôt que devinée : « 1,234 »
    # en en vaut mille deux cent trente-quatre, jamais 1,234.
    def parse_decimal(text : String) : BigDecimal?
      cleaned = text.strip
      return if cleaned.empty?
      negative = cleaned.starts_with?('-')
      cleaned = cleaned.lchop('-').lchop('+').strip
      parts = cleaned.split(@convention.decimal)
      return if parts.size > 2
      whole = parts[0]
      fraction = parts[1]?
      return if fraction && !fraction.matches?(/\A\d+\z/)
      whole = ungrouped(whole) || return
      return if whole.empty? && fraction.nil?
      value = BigDecimal.new("#{whole.empty? ? "0" : whole}#{fraction ? ".#{fraction}" : ""}")
      negative ? -value : value
    rescue ArgumentError | InvalidBigDecimalException
      nil
    end

    # Valeur décimale enregistrée (`BigDecimal#to_s`, point décimal), telle
    # que le cœur la rend dans un attribut libre ; `nil` si illisible.
    def self.canonical_decimal(text : String) : BigDecimal?
      value = text.strip
      return unless value.matches?(/\A-?\d+(\.\d+)?\z/)
      BigDecimal.new(value)
    rescue ArgumentError | InvalidBigDecimalException
      nil
    end

    # Partie entière sans ses séparateurs de milliers, s'ils sont bien placés.
    private def ungrouped(whole : String) : String?
      return whole if whole.matches?(/\A\d*\z/)
      separator = Regex.escape(@convention.group)
      pattern = /\A\d{1,3}(?:(?:#{separator}|[\s\x{00A0}\x{202F}])\d{3})+\z/
      return unless whole.matches?(pattern)
      whole.gsub(/\D/, "")
    end

    # Date saisie : `AAAA-MM-JJ` (champ date du navigateur) ou le motif de la
    # langue (`27/09/2026`). Minuit UTC (convention C1 du cœur).
    def parse_date(text : String) : Time?
      value = text.strip
      return if value.empty?
      ["%Y-%m-%d", @convention.date].each do |pattern|
        return Time.parse(value, pattern, Time::Location::UTC)
      rescue Time::Format::Error | ArgumentError
        next
      end
      nil
    end

    # Date saisie en abrégé (ADR-005 D5), relative à `reference` (en saisie :
    # le mois de la période de travail) : `12` → le 12 de ce mois ; `12/3`,
    # `12.3`, `12-3` ou `1203` → le 12 mars de son année ; `12/3/26` ou
    # `120326` → 2026 ; sinon une date complète (`parse_date`). L'ordre jour,
    # mois suit la langue (mois d'abord en `en-US`). `nil` si la date
    # n'existe pas.
    def parse_short_date(text : String, reference : Time) : Time?
      value = text.strip
      return if value.empty?
      full = parse_date(value)
      return full if full && full.year >= 1900
      numbers = short_parts(value) || return
      numbers[0], numbers[1] = numbers[1], numbers[0] if numbers.size >= 2 && @convention.date.starts_with?("%m")
      year = numbers[2]?.try { |given| given < 100 ? 2000 + given : given } || reference.year
      valid_day(year, numbers[1]? || reference.month, numbers[0])
    end

    private def valid_day(year : Int32, month : Int32, day : Int32) : Time?
      return unless (1..12).includes?(month) && year >= 1900
      return unless (1..Time.days_in_month(year, month)).includes?(day)
      Time.utc(year, month, day)
    end

    # Nombres d'une date abrégée : chiffres seuls (`12`, `1203`, `120326`,
    # `12032026`) ou séparés (`12/3`, `12.3.26`) ; `nil` sinon.
    private def short_parts(value : String) : Array(Int32)?
      parts = if value.matches?(/\A\d+\z/)
                SHORT_DIGITS[value.size]?.try { |sizes| split_digits(value, sizes) } || return
              else
                value.split(/[\/.\-\s]+/)
              end
      return if parts.empty? || parts.size > 3 || parts.any? { |part| !part.matches?(/\A\d{1,4}\z/) }
      parts.map(&.to_i)
    end

    # Découpage d'une date abrégée écrite sans séparateur, selon sa longueur.
    SHORT_DIGITS = {1 => [1], 2 => [2], 4 => [2, 2], 6 => [2, 2, 2], 8 => [2, 2, 4]}

    private def split_digits(value : String, sizes : Array(Int32)) : Array(String)
      offset = 0
      sizes.map do |size|
        part = value[offset, size]
        offset += size
        part
      end
    end

    private def digits(value : BigDecimal, decimals : Int32, group : Bool) : String
      negative = value < 0
      text = value.abs.to_s
      whole, _, fraction = text.partition('.')
      fraction = (fraction + "0" * decimals)[0, decimals]
      whole = grouped(whole) if group
      result = decimals > 0 ? "#{whole}#{@convention.decimal}#{fraction}" : whole
      negative && (whole != "0" || fraction.each_char.any? { |char| char != '0' }) ? "-#{result}" : result
    end

    private def grouped(whole : String) : String
      return whole if whole.size <= 3
      head = whole.size % 3
      parts = [] of String
      parts << whole[0, head] if head > 0
      (head...whole.size).step(3) { |index| parts << whole[index, 3] }
      parts.join(@convention.group)
    end
  end
end
