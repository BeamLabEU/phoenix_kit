defmodule PhoenixKit.API.OAuth.Metadata do
  @moduledoc """
  The two discovery documents of the OAuth side of the MCP endpoint.

    * `protected_resource/0` - RFC 9728: where the resource is, and which authorization server
      issues tokens for it (this one). Published at
      `/.well-known/oauth-protected-resource<path of the resource>` (`PhoenixKit.API.OAuth.Resource.metadata_path/0`;
      the path variant only: the bare root path is not served, because the `resource` it names
      must be the identifier the URL was built from, RFC 9728 section 3.3).
    * `authorization_server/0` - RFC 8414, at `/.well-known/oauth-authorization-server`. There is
      no `openid-configuration` alias: this is not an OpenID provider.

  ## What they leave out

  Both are public (they are fetched before any credential exists) and are served only while
  OAuth is switched on (`PhoenixKit.API.Config.oauth_enabled?/0`). They name the MCP path and the
  Bearer scheme and **nothing else about the machine API**: no tool, no scope, no permission, no
  module. `scopes_supported` is deliberately absent, so an anonymous visitor cannot enumerate
  the modules of the install; a client asks for no scope, or any, and the person chooses on
  the consent screen. The `resource_name` is generic and never the admin label of the site.
  """

  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Utils.Routes

  @doc "The protected resource metadata document (RFC 9728)."
  @spec protected_resource() :: map()
  def protected_resource do
    %{
      "resource" => Resource.resource(),
      "authorization_servers" => [Resource.issuer()],
      "bearer_methods_supported" => ["header"],
      "resource_name" => "MCP server"
    }
  end

  @doc "The authorization server metadata document (RFC 8414)."
  @spec authorization_server() :: map()
  def authorization_server do
    issuer = Resource.issuer()

    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> Routes.path("/oauth/authorize"),
      "token_endpoint" => issuer <> Routes.path("/oauth/token"),
      "revocation_endpoint" => issuer <> Routes.path("/oauth/revoke"),
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "client_id_metadata_document_supported" => true,
      "authorization_response_iss_parameter_supported" => true
    }
  end
end
