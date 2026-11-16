defmodule PhoenixKitWeb.OAuth.Responses do
  @moduledoc """
  What the controllers of the authorization flow share: the headers of a page a person decides
  on, a redirect back to the client, and an HTML page answer.

  ## Headers of a decision page

  `secure/1` puts `Cache-Control: no-store`, `Referrer-Policy: no-referrer` (the URL of a
  consent page is a capability), `X-Frame-Options: DENY` and a `frame-ancestors 'none'` directive
  in the `Content-Security-Policy`. The host's policy is **kept**: only its own `frame-ancestors`
  directive is replaced (every `Content-Security-Policy` header the response already has is
  rewritten that way), and a response with no policy gets one that carries just that directive.
  Overwriting the header would take `default-src` and `script-src` away from the page.

  ## Redirects to the client

  `to_client/3` appends parameters to the client's redirect URI (which is already confirmed
  against the client's registered URIs), keeping a query it has. Every answer to the client, a
  success or an error, carries `iss`, the exact issuer string (RFC 9207), so a client talking to
  several authorization servers can tell which one answered.
  """

  import Plug.Conn

  alias PhoenixKit.API.OAuth.Resource

  @doc "Headers of a page the person decides on (see the moduledoc)."
  @spec secure(Plug.Conn.t()) :: Plug.Conn.t()
  def secure(%Plug.Conn{} = conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> frame_ancestors_none()
  end

  # Replaces the `frame-ancestors` directive of each policy the host has already set, or adds a
  # policy of that one directive.
  defp frame_ancestors_none(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [] ->
        put_resp_header(conn, "content-security-policy", "frame-ancestors 'none'")

      policies ->
        conn = delete_resp_header(conn, "content-security-policy")

        Enum.reduce(policies, conn, fn policy, acc ->
          prepend_resp_headers(acc, [{"content-security-policy", replace_directive(policy)}])
        end)
    end
  end

  @doc false
  @spec replace_directive(String.t()) :: String.t()
  def replace_directive(policy) when is_binary(policy) do
    kept =
      policy
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(String.downcase(&1), "frame-ancestors")))

    Enum.join(kept ++ ["frame-ancestors 'none'"], "; ")
  end

  @doc "Sends `html` (iodata) with `status`."
  @spec page(Plug.Conn.t(), pos_integer(), iodata()) :: Plug.Conn.t()
  def page(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  @doc """
  Redirects the browser to `redirect_uri` with `params` (a keyword list or a map; `nil` values
  are left out) and the issuer added.
  """
  @spec to_client(Plug.Conn.t(), String.t(), keyword() | map()) :: Plug.Conn.t()
  def to_client(conn, redirect_uri, params) do
    query =
      params
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.concat(iss: Resource.issuer())
      |> URI.encode_query()

    separator = if String.contains?(redirect_uri, "?"), do: "&", else: "?"

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("location", redirect_uri <> separator <> query)
    |> send_resp(302, "")
  end
end
