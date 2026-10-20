# SPDX-License-Identifier: AGPL-3.0-or-later

require "spec"

# Contrastes du thème (WCAG 2.1 AA, 1.4.3 et 1.4.11), calculés à partir des
# jetons de `theme.css` en clair et en sombre : 4,5:1 pour le texte, 3:1
# pour les composants (bordure des champs, focus, couleur principale), et
# chaque couleur de texte qu'emploie `access.css` sur les fonds des pages
# d'accès. Le thème sombre est déclaré deux fois (préférence du poste et
# `data-theme="dark"`) : les deux déclarations doivent être identiques.
# Les feuilles sont recopiées octet pour octet par partiduo-admin.
module ThemeContrast
  CSS_DIR = File.expand_path("../../src/ui/assets/ui/css", __DIR__)

  record Rgb, r : Float64, g : Float64, b : Float64 do
    def luminance : Float64
      f = ->(v : Float64) { v /= 255; v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 }
      0.2126 * f.call(r) + 0.7152 * f.call(g) + 0.0722 * f.call(b)
    end

    def over(back : Rgb, alpha : Float64) : Rgb
      Rgb.new(r * alpha + back.r * (1 - alpha), g * alpha + back.g * (1 - alpha), b * alpha + back.b * (1 - alpha))
    end
  end

  def self.ratio(a : Rgb, b : Rgb) : Float64
    la, lb = a.luminance, b.luminance
    (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  end

  # Déclarations `--nom: valeur;` d'un bloc, commentaires retirés.
  def self.declarations(block : String) : Hash(String, String)
    block.gsub(%r{/\*.*?\*/}m, "").scan(/(--[a-z0-9-]+)\s*:\s*([^;]+);/).to_h { |match| {match[1], match[2].strip} }
  end

  # Contenu du premier bloc qui suit `selector` (accolades équilibrées).
  def self.block(css : String, selector : String) : String
    start = css.index(selector) || raise "bloc absent : #{selector}"
    open = css.index!('{', start)
    depth = 0
    (open...css.size).each do |index|
      depth += 1 if css[index] == '{'
      depth -= 1 if css[index] == '}'
      return css[(open + 1)...index] if depth == 0
    end
    raise "bloc non fermé : #{selector}"
  end

  def self.theme : String
    File.read(File.join(CSS_DIR, "theme.css"))
  end

  def self.light : Hash(String, String)
    declarations(block(theme, ":root {"))
  end

  def self.dark_media : Hash(String, String)
    declarations(block(block(theme, "@media (prefers-color-scheme: dark)"), %(:root:not([data-theme="light"]) {)))
  end

  def self.dark_attribute : Hash(String, String)
    declarations(block(theme, %(:root[data-theme="dark"] {)))
  end

  def self.dark : Hash(String, String)
    light.merge(dark_media)
  end

  def self.number(tokens : Hash(String, String), name : String) : Float64
    (tokens[name]? || raise "jeton absent : #{name}").gsub(/deg|%/, "").to_f
  end

  # Couleur HSL d'un trio de jetons Bulma (`<préfixe>-h`, `-s`) et d'une
  # luminosité (`lightness`, nom de jeton).
  def self.hsl(tokens : Hash(String, String), prefix : String, lightness : String) : Rgb
    h = number(tokens, "--bulma-#{prefix}-h") / 360
    s = number(tokens, "--bulma-#{prefix}-s") / 100
    l = number(tokens, lightness) / 100
    hsl(h, s, l)
  end

  def self.hsl(h : Float64, s : Float64, l : Float64) : Rgb
    return Rgb.new(l * 255, l * 255, l * 255) if s == 0
    q = l < 0.5 ? l * (1 + s) : l + s - l * s
    p = 2 * l - q
    channel = ->(t : Float64) do
      t += 1 if t < 0
      t -= 1 if t > 1
      value = if t < 1 / 6.0
                p + (q - p) * 6 * t
              elsif t < 1 / 2.0
                q
              elsif t < 2 / 3.0
                p + (q - p) * (2 / 3.0 - t) * 6
              else
                p
              end
      value * 255
    end
    Rgb.new(channel.call(h + 1 / 3.0), channel.call(h), channel.call(h - 1 / 3.0))
  end

  # Jeton de couleur `--pd-*` (hexadécimal, ou rgba posé sur `back`).
  def self.color(tokens : Hash(String, String), name : String, back : Rgb? = nil) : Rgb
    value = tokens[name]? || raise "jeton absent : #{name}"
    if match = value.match(/\A#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})\z/i)
      Rgb.new(match[1].to_i(16).to_f, match[2].to_i(16).to_f, match[3].to_i(16).to_f)
    elsif match = value.match(/\Argba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([\d.]+)\s*\)\z/)
      base = back || raise "fond requis pour #{name}"
      Rgb.new(match[1].to_f, match[2].to_f, match[3].to_f).over(base, match[4].to_f)
    else
      raise "couleur illisible : #{name} = #{value}"
    end
  end

  # Couples (texte ou composant, fond, minimum) communs aux deux thèmes.
  def self.pairs(tokens : Hash(String, String)) : Array({String, Rgb, Rgb, Float64})
    c = ->(name : String) { color(tokens, name) }
    grounds = {"--pd-ground", "--pd-surface", "--pd-row-alt"}
    list = [] of {String, Rgb, Rgb, Float64}
    grounds.each do |ground|
      %w[--pd-ink --pd-muted --pd-debit].each { |ink| list << {"#{ink} / #{ground}", c.call(ink), c.call(ground), 4.5} }
      list << {"lien du texte / #{ground}", hsl(tokens, "link", "--bulma-link-on-scheme-l"), c.call(ground), 4.5}
      list << {"--pd-gap / #{ground}", c.call("--pd-gap"), c.call(ground), 4.5}
      list << {"--pd-ok / #{ground}", c.call("--pd-ok"), c.call(ground), 4.5}
    end
    list << {"--pd-tag-ink / --pd-tag-bg", c.call("--pd-tag-ink"), c.call("--pd-tag-bg"), 4.5}
    list << {"--pd-ok / --pd-ok-bg", c.call("--pd-ok"), c.call("--pd-ok-bg"), 4.5}
    list << {"--pd-gap / --pd-gap-bg", c.call("--pd-gap"), c.call("--pd-gap-bg"), 4.5}
    list << {"--pd-warn / --pd-warn-bg", c.call("--pd-warn"), c.call("--pd-warn-bg"), 4.5}
    sidebar = c.call("--pd-sidebar")
    active = color(tokens, "--pd-sidebar-active-bg", sidebar)
    list << {"--pd-sidebar-text / --pd-sidebar", c.call("--pd-sidebar-text"), sidebar, 4.5}
    list << {"--pd-sidebar-active / entrée active", c.call("--pd-sidebar-active"), active, 4.5}
    list << {"--pd-focus-on-dark / --pd-sidebar", c.call("--pd-focus-on-dark"), sidebar, 3.0}
    primary = hsl(tokens, "primary", "--bulma-primary-l")
    list << {"bouton is-primary", hsl(tokens, "primary", "--bulma-primary-invert-l"), primary, 4.5}
    list << {"--pd-on-primary / principale", c.call("--pd-on-primary"), primary, 4.5}
    list << {"bouton is-link", hsl(tokens, "link", "--bulma-link-invert-l"), hsl(tokens, "link", "--bulma-link-l"), 4.5}
    list << {"principale / --pd-surface (composant)", primary, c.call("--pd-surface"), 3.0}
    list << {"--pd-field-border / --pd-surface", c.call("--pd-field-border"), c.call("--pd-surface"), 3.0}
    {"--pd-surface", "--pd-ground"}.each do |ground|
      list << {"--pd-focus / #{ground}", c.call("--pd-focus"), c.call(ground), 3.0}
    end
    list
  end

  # Couples propres au sombre : variantes `is-light` (fond --bulma-light-l
  # teinté, texte <couleur>-light-invert-l) et neutres de Bulma alignés.
  def self.dark_pairs(tokens : Hash(String, String)) : Array({String, Rgb, Rgb, Float64})
    list = %w[primary link info success warning danger].map do |name|
      text = hsl(tokens, name, "--bulma-#{name}-light-invert-l")
      {"#{name} is-light", text, hsl(tokens, name, "--bulma-light-l"), 4.5}
    end
    main = hsl(tokens, "scheme", "--bulma-scheme-main-l")
    list << {"texte des champs", hsl(tokens, "text", "--bulma-text-strong-l"), main, 4.5}
    list << {"texte de Bulma", hsl(tokens, "text", "--bulma-text-l"), main, 4.5}
    list << {"texte atténué de Bulma", hsl(tokens, "text", "--bulma-text-weak-l"), main, 4.5}
    list << {"is-light neutre", hsl(tokens, "scheme", "--bulma-light-invert-l"), hsl(tokens, "scheme", "--bulma-light-l"), 4.5}
    list
  end

  # Couleurs de texte qu'emploie access.css (`color: var(--…)`), hors
  # logotype (`--pd-brand-*`, exempté par WCAG 1.4.3).
  def self.access_inks : Array(String)
    File.read(File.join(CSS_DIR, "access.css")).scan(/(?<![-\w])color:\s*var\((--[a-z0-9-]+)\)/).map(&.[1]).uniq!
      .reject(&.starts_with?("--pd-brand-"))
  end

  def self.ink(tokens : Hash(String, String), name : String) : Rgb
    case name
    when "--bulma-link" then hsl(tokens, "link", "--bulma-link-l")
    else                     color(tokens, name)
    end
  end

  def self.failures(list : Array({String, Rgb, Rgb, Float64})) : Array(String)
    list.compact_map do |(label, front, back, minimum)|
      value = ratio(front, back)
      "#{label} : #{value.round(2)}:1 < #{minimum}:1" if value < minimum
    end
  end
end

describe "Contrastes du thème (WCAG AA)" do
  it "déclare le thème sombre à l'identique pour la préférence du poste et data-theme" do
    ThemeContrast.dark_media.should eq(ThemeContrast.dark_attribute)
    theme = ThemeContrast.theme
    theme.should contain(%(:root:not([data-theme="light"]) .notification.is-light { --bulma-notification-background-l: var(--bulma-light-l); }))
    theme.should contain(%(:root[data-theme="dark"] .notification.is-light { --bulma-notification-background-l: var(--bulma-light-l); }))
  end

  it "atteint 4,5:1 pour le texte et 3:1 pour les composants, en clair" do
    ThemeContrast.failures(ThemeContrast.pairs(ThemeContrast.light)).should eq([] of String)
  end

  it "atteint 4,5:1 pour le texte et 3:1 pour les composants, en sombre, variantes is-light et neutres de Bulma compris" do
    tokens = ThemeContrast.dark
    ThemeContrast.failures(ThemeContrast.pairs(tokens) + ThemeContrast.dark_pairs(tokens)).should eq([] of String)
  end

  it "atteint 4,5:1 pour chaque couleur de texte d'access.css sur les fonds des pages d'accès, dans les deux thèmes" do
    inks = ThemeContrast.access_inks
    inks.should contain("--pd-muted")
    inks.should contain("--bulma-link")
    [ThemeContrast.light, ThemeContrast.dark].each do |tokens|
      list = inks.flat_map do |name|
        %w[--pd-surface --pd-ground --pd-row-alt].map do |ground|
          {"#{name} / #{ground}", ThemeContrast.ink(tokens, name), ThemeContrast.color(tokens, ground), 4.5}
        end
      end
      ThemeContrast.failures(list).should eq([] of String)
    end
  end

  it "calcule les rapports de référence (noir sur blanc 21:1, gris #767676 sur blanc 4,54:1)" do
    white = ThemeContrast::Rgb.new(255, 255, 255)
    ThemeContrast.ratio(ThemeContrast::Rgb.new(0, 0, 0), white).round(1).should eq(21.0)
    ThemeContrast.ratio(ThemeContrast::Rgb.new(118, 118, 118), white).round(2).should eq(4.54)
    ThemeContrast.hsl(0.0, 0.0, 0.5).r.round.should eq(128)
  end
end
