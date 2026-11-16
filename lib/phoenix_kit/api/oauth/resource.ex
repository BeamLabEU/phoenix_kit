defmodule PhoenixKit.API.OAuth.Resource do
  @moduledoc """
  The one resource the OAuth server protects, and the identifiers built from it.

  The install is its own authorization server and its own resource server, and the resource
  is the admin MCP endpoint:

      resource = <canonical origin> <> Routes.path(Paths.mcp_path(:admin))
      issuer   = <canonical origin>

  Both come from `PhoenixKit.API.MCP.Origin.canonical_origin/0` (the `site_url` setting, else
  the endpoint's URL; never the request's `Host` header), so a request cannot change what a
  token is for. `Routes.path/1` carries the kit's URL prefix.

  `metadata_url/0` is where the protected-resource metadata of RFC 9728 lives, built the way
  that RFC says (the well-known segment goes between the host and the path of the resource):
  the URL a `401` challenge names in `resource_metadata`.

  A `resource` a client sends is compared after `normalize/1` (RFC 8707): scheme and host in
  lower case, no fragment, no trailing `/`, the default port left out.
  """

  alias PhoenixKit.API.MCP.Origin
  alias PhoenixKit.API.Paths
  alias PhoenixKit.Utils.Routes

  @well_known "/.well-known/oauth-protected-resource"

  @doc "The identifier of the resource tokens are issued for, as a string without a trailing `/`."
  @spec resource() :: String.t()
  def resource, do: Origin.canonical_origin() <> path()

  @doc "The issuer: the canonical origin, without a trailing `/`."
  @spec issuer() :: String.t()
  def issuer, do: Origin.canonical_origin()

  @doc "The path of the resource under the origin, with the kit's URL prefix: `/mcp/admin`."
  @spec path() :: String.t()
  def path, do: Routes.path(Paths.mcp_path(:admin))

  @doc "The URL of the protected-resource metadata document (RFC 9728, the path variant)."
  @spec metadata_url() :: String.t()
  def metadata_url, do: Origin.canonical_origin() <> @well_known <> path()

  @doc "The well-known path of the metadata document, under the origin."
  @spec metadata_path() :: String.t()
  def metadata_path, do: @well_known <> path()

  @doc """
  Whether `candidate` names the resource of this install, after `normalize/1`.
  """
  @spec matches?(term()) :: boolean()
  def matches?(candidate) do
    with {:ok, given} <- normalize(candidate),
         {:ok, own} <- normalize(resource()) do
      given == own
    else
      :error -> false
    end
  end

  @doc """
  Normalizes a resource identifier: an absolute `http(s)` URL with a host, no userinfo and
  no fragment. The scheme and the host are lowered, the default port is dropped and a
  trailing `/` is removed. `:error` for anything else.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(candidate) when is_binary(candidate) do
    case URI.new(candidate) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri}
      when scheme in ["http", "https", "HTTP", "HTTPS"] and is_binary(host) and host != "" ->
        {:ok, build(uri, String.downcase(scheme))}

      _ ->
        :error
    end
  end

  def normalize(_candidate), do: :error

  defp build(%URI{host: host, port: port, path: path, query: query}, scheme) do
    authority = host_text(host) <> port_suffix(scheme, port)
    "#{scheme}://#{authority}#{trim_slash(path)}#{query_suffix(query)}"
  end

  defp host_text(host) do
    host = String.downcase(host)
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  defp trim_slash(nil), do: ""
  defp trim_slash(path), do: String.trim_trailing(path, "/")

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query
end
