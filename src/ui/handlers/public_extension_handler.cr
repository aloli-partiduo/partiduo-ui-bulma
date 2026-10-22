# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Point d'entrée des routes publiques d'extension, `/p/<code>/…` (A-FRM-1,
  # `PartiduoUi::Extensions.public_mount`). Dans l'ordre, avant le handler de
  # l'extension :
  #
  # . extension inconnue, sans routes publiques, ou inactive : 404 ;
  # . route inconnue de l'extension : 404 ;
  # . limitation de débit de la route, par adresse : 429 et `Retry-After` ;
  # . taille annoncée au-delà de la limite du montage : 413 ;
  #
  # puis le handler de l'extension (protection CSRF de Marten comprise).
  # Toute réponse, y compris le refus de la protection CSRF rendu avant
  # `dispatch`, reçoit les en-têtes stricts communs
  # (`Extensions::PUBLIC_HEADERS`) que le handler n'a pas posés lui-même ;
  # le chemin servi est masqué dans le journal des requêtes du serveur
  # (`/p/<code>/…`, D-AMD-037), quelle que soit la réponse. Aucune session
  # n'est exigée ni lue.
  class PublicExtensionHandler < Handler
    def process_dispatch : Marten::HTTP::Response
      secured(super)
    ensure
      Extensions.mask_logged_path(request, masked_path)
    end

    def dispatch : Marten::HTTP::Response
      answer
    end

    # Chemin écrit au journal : préfixe et code d'une extension montée,
    # jamais la suite (jeton, identifiant), ni un code inconnu.
    private def masked_path : String
      mount = Extensions.public_mount?(params["code"]?.to_s)
      mount ? "#{mount.path}/…" : "#{Extensions::PUBLIC_PREFIX}…"
    end

    private def answer : Marten::HTTP::Response
      mount = Extensions.public_mount?(params["code"].to_s)
      return PublicErrorPage.render(request, 404) if mount.nil? || !Extensions.public_active?(mount)

      path = request.path == mount.path ? "" : "/#{params["path"]?}"
      route_name = Extensions.route_name(mount.routes, path, mount.namespace)
      return PublicErrorPage.render(request, 404) if route_name.nil?

      rule = mount.rule_for(route_name)
      unless RateLimit.allow?(request, "public|#{route_name}", rule)
        response = PublicErrorPage.render(request, 429)
        response.headers["Retry-After"] = rule.window.total_seconds.to_i.to_s
        return response
      end
      if (limit = mount.max_body_bytes) && (length = request.headers["Content-Length"]?.try(&.to_i64?)) && length > limit
        return PublicErrorPage.render(request, 413)
      end
      match = mount.routes.resolve(path)
      match.handler.new(request, match.kwargs).process_dispatch
    rescue Marten::Routing::Errors::NoResolveMatch
      PublicErrorPage.render(request, 404)
    end

    private def secured(response : Marten::HTTP::Response) : Marten::HTTP::Response
      Extensions::PUBLIC_HEADERS.each do |name, value|
        response.headers[name] = value unless response.headers.has_key?(name)
      end
      response
    end
  end
end
