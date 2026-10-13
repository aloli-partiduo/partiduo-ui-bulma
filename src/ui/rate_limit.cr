# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Limitation par adresse IP des points d'entrée *anonymes* qui écrivent
  # (défi de passkey, demande de lien de remise à zéro ou de déblocage) :
  # un anonyme ne peut pas faire grossir les tables de défis et de jetons, ni
  # inonder une boîte aux lettres (D-UI-022). Fenêtre glissante en mémoire,
  # par processus : chaque instance a le sien ; un redémarrage remet à zéro.
  # La limitation *par compte* reste celle du cœur (D-AUTH-005, D-AUTH-012).
  module RateLimit
    record Rule, limit : Int32, window : Time::Span

    RULES = {
      "passkey_options" => Rule.new(30, 5.minutes),
      "token_request"   => Rule.new(10, 15.minutes),
    }

    @@hits = {} of String => Array(Time)
    @@mutex = Mutex.new

    # Plus longue fenêtre des règles déclarées hors de `RULES` (routes
    # publiques des extensions, A-FRM-1), pour la purge.
    @@longest_extra = Time::Span.zero

    # Enregistre une demande ; `false` si la limite de `bucket` est atteinte
    # pour cette adresse.
    def self.allow?(request : Marten::HTTP::Request, bucket : String, now : Time = Time.utc) : Bool
      allow?(request, bucket, RULES[bucket], now)
    end

    # Même contrôle avec une règle donnée (route publique d'une extension,
    # A-FRM-1) ; `bucket` distingue les compteurs.
    def self.allow?(request : Marten::HTTP::Request, bucket : String, rule : Rule, now : Time = Time.utc) : Bool
      @@mutex.synchronize { @@longest_extra = rule.window if rule.window > @@longest_extra }
      key = "#{bucket}|#{client_ip(request)}"
      @@mutex.synchronize do
        purge(now) if @@hits.size > 10_000
        hits = (@@hits[key] ||= [] of Time)
        hits.reject! { |time| time <= now - rule.window }
        return false if hits.size >= rule.limit
        hits << now
        true
      end
    end

    # Adresse du client : celle que pose le proxy de confiance (`X-Real-IP`)
    # quand l'instance est derrière lui (`use_x_forwarded_proto`), sinon
    # l'adresse de la connexion.
    def self.client_ip(request : Marten::HTTP::Request) : String
      if Marten.settings.use_x_forwarded_proto?
        if forwarded = request.headers["X-Real-IP"]?.presence
          return forwarded
        end
      end
      request.remote_ip_address || "?"
    end

    def self.reset! : Nil
      @@mutex.synchronize { @@hits.clear }
    end

    private def self.purge(now : Time) : Nil
      longest = {RULES.values.max_of(&.window), @@longest_extra}.max
      @@hits.reject! { |_, hits| hits.all? { |time| time <= now - longest } }
    end
  end
end
