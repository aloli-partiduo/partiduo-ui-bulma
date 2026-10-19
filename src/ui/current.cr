# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Utilisateur de la requête, vu par l'interface : jeton de session (cookie),
  # acteur et session du contrat `Partiduo::Api::Auth` (ADR-002, ADR-005 D2).
  #
  # Le cœur tient les sessions (révocation immédiate) ; l'interface ne garde
  # que le jeton, dans un cookie `HttpOnly`, `SameSite=Lax`, `Secure` en HTTPS
  # et *toujours* en production (`secure_cookies?`).
  class Current
    # Cookie du jeton de session.
    COOKIE = "partiduo_session"

    # Cookie du jeton de second facteur, entre le mot de passe et le code.
    PENDING_COOKIE = "partiduo_pending"

    # Cookie de l'identifiant de requête d'une connexion fédérée.
    FEDERATED_COOKIE = "partiduo_federated"

    # Cookie de la page demandée avant une connexion fédérée.
    FEDERATED_NEXT_COOKIE = "partiduo_federated_next"

    # Cookie de l'invitation acceptée par une connexion connect (ADR-012 D6),
    # repassée au retour pour lier le compte connect à l'invité.
    INVITATION_COOKIE = "partiduo_invitation"

    getter token : String?
    getter actor : Partiduo::Api::Actor
    getter session : Partiduo::Api::Auth::SessionView?

    def initialize(@token : String?, @actor : Partiduo::Api::Actor, @session : Partiduo::Api::Auth::SessionView?)
    end

    # Utilisateur de la requête, mémorisé sur la requête.
    def self.for(request : Marten::HTTP::Request) : Current
      if current = request.partiduo_current
        return current
      end
      token = request.cookies[COOKIE]?.presence
      session = token ? Partiduo::Api::Auth.session(token) : nil
      actor = session ? Partiduo::Api::Auth.actor(token) : Partiduo::Api::Actor.anonymous
      session = nil unless actor.authenticated?
      current = new(token, actor, session)
      request.partiduo_current = current
      current
    end

    # Ouvre la session dans le navigateur : pose le cookie du jeton.
    def self.open(request : Marten::HTTP::Request, token : String) : Nil
      expires = Partiduo::Api::Auth.session(token).try(&.expires_at)
      request.cookies.set(COOKIE, token, expires: expires, http_only: true, secure: secure_cookies?(request), same_site: "Lax")
      request.partiduo_current = nil
    end

    # Attribut `Secure` des cookies : en HTTPS, et toujours en production —
    # même si le proxy n'indiquait pas `X-Forwarded-Proto`, un jeton ne part
    # jamais en clair (D-UI-021).
    def self.secure_cookies?(request : Marten::HTTP::Request) : Bool
      request.secure? || Marten.env.production?
    end

    # Ferme la session : révoque le jeton côté cœur et efface le cookie.
    def self.close(request : Marten::HTTP::Request) : Nil
      current = self.for(request)
      if token = current.token
        Partiduo::Api::Auth.logout(current.actor, token)
      end
      request.cookies.delete(COOKIE, same_site: "Lax")
      request.partiduo_current = nil
    end

    def authenticated? : Bool
      !@session.nil?
    end

    def session! : Partiduo::Api::Auth::SessionView
      @session || raise NilAssertionError.new("aucune session")
    end

    # Session d'enrôlement ouverte par une invitation (niveau 0) : l'utilisateur
    # ne peut qu'enrôler une passkey ou choisir un mot de passe.
    def enrollment? : Bool
      session.try(&.level.zero?) || false
    end

    # Session sous le niveau exigé : aucun droit tant qu'elle n'est pas élevée
    # (ADR-002 D6).
    def elevation_required? : Bool
      session.try(&.elevation_required) || false
    end

    # Contexte d'une tentative de connexion, consigné par l'audit du cœur.
    def self.login_context(request : Marten::HTTP::Request) : Partiduo::Api::Auth::LoginContext
      Partiduo::Api::Auth::LoginContext.new(
        ip: request.remote_ip_address || "",
        user_agent: request.headers["User-Agent"]? || "",
      )
    end
  end
end
