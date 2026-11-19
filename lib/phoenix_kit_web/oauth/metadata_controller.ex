defmodule PhoenixKitWeb.OAuth.MetadataController do
  @moduledoc """
  The two discovery documents (`PhoenixKit.API.OAuth.Metadata`), served at the site root
  (`/.well-known/...`), public and readable from any origin (`access-control-allow-origin: *`):

    * `GET /.well-known/oauth-protected-resource<path of the resource>` - RFC 9728;
    * `GET /.well-known/oauth-authorization-server` - RFC 8414.

  While OAuth is switched off (`api_oauth_enabled`, which needs the admin API on) both answer
  the same `404` problem document the public API gives when it is hidden, so an install that does
  not use OAuth says nothing about it.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Metadata
  alias PhoenixKit.API.Problem

  @cache_control "public, max-age=300"

  @doc "RFC 9728."
  def protected_resource(conn, _params), do: document(conn, &Metadata.protected_resource/0)

  @doc "RFC 8414."
  def authorization_server(conn, _params), do: document(conn, &Metadata.authorization_server/0)

  defp document(conn, build) do
    if Config.oauth_enabled?() do
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(build.()))
    else
      Problem.send(conn, :not_found, "", %{})
    end
  end
end
