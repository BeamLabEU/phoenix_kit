defmodule PhoenixKitWeb.OAuth.Responses do
  @moduledoc """
  What the controllers of the authorization flow share: the headers of a page a person decides
  on, a redirect back to the client, and an HTML page answer.

  ## Headers of a decision page

  `secure/1` puts `Cache-Control: no-store`, `Referrer-Policy: no-referrer` (the URL of a
  consent page is a capability), `X-Frame-Options: DENY`, `Vary: Accept-Language` (the language of
  the page follows that header, `PhoenixKitWeb.OAuth.Language`) and a `frame-ancestors 'none'`
  directive in the `Content-Security-Policy`. The host's policy is **kept**: only its own `frame-ancestors`
  directive is replaced (every `Content-Security-Policy` header the response already has is
  rewritten that way), and a response with no policy gets one that carries just that directive.
  Overwriting the header would take `default-src` and `script-src` away from the page.

  The pages carry an inline `<style>`, and the answer to the consent form is a redirect to the
  client's `redirect_uri`: a host policy with a strict `style-src` cuts the style (the page stays
  usable), and one with `form-action 'self'` makes some browsers refuse that redirect, so such a
  host has to list the redirect origins of its clients in `form-action` (or leave the directive
  out) for the flow to complete.

  ## The browser binding

  `bind_browser/1` gives the browser that starts an authorization request a random nonce in a
  cookie of its own (`browser_cookie/0`), and `browser_nonce/1` reads it back on the consent
  routes; `PhoenixKit.API.OAuth.Requests` keys the stored request by it. It is a cookie and not a
  session entry because signing in renews the session and **clears** it
  (`PhoenixKitWeb.Users.Auth.log_in_user/3`), and the person lands on the consent page right
  after the sign-in; the cookie is `HttpOnly`, `SameSite=Lax` (it travels with the top-level
  redirect back from a sign-in at another site, never with a cross-site form post) and `Secure`
  when the canonical origin (`PhoenixKit.API.OAuth.Resource.issuer/0`) is https, not when the
  request looks so (a proxy that ends TLS may hand over a plain `http` connection), limited to the
  path of the flow, and it lives an hour. A browser already holding a nonce keeps it, so two
  requests started in two tabs do not undo each other.

  The cookie cannot take the `__Host-` prefix, which needs `Path=/`. The accepted trade-off: a
  well-formed nonce is taken from whatever the browser sends, so someone who can set cookies for
  the site from a sibling subdomain could plant a nonce of their own and relay a consent URL
  they started.

  ## Redirects to the client

  `to_client/3` appends parameters to the client's redirect URI (which is already confirmed
  against the client's registered URIs), keeping a query it has. Every answer to the client, a
  success or an error, carries `iss`, the exact issuer string (RFC 9207), so a client talking to
  several authorization servers can tell which one answered.
  """

  import Plug.Conn

  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Utils.Routes

  @browser_cookie "pk_oauth_browser"
  @browser_max_age 3600

  @doc "The name of the cookie that binds a request to its browser."
  @spec browser_cookie() :: String.t()
  def browser_cookie, do: @browser_cookie

  @doc """
  The nonce of the browser behind `conn` (its cookie, when it is a well-formed nonce), or `nil`.
  """
  @spec browser_nonce(Plug.Conn.t()) :: String.t() | nil
  def browser_nonce(%Plug.Conn{} = conn) do
    value = conn |> fetch_cookies() |> Map.get(:req_cookies, %{}) |> Map.get(@browser_cookie)
    if Requests.browser?(value), do: value
  end

  @doc """
  Makes sure the browser has a nonce and refreshes its cookie. Returns `{conn, nonce}`: the
  nonce the browser already holds, or a new one.
  """
  @spec bind_browser(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  def bind_browser(%Plug.Conn{} = conn) do
    nonce = browser_nonce(conn) || Requests.new_browser()

    conn =
      put_resp_cookie(conn, @browser_cookie, nonce,
        http_only: true,
        same_site: "Lax",
        secure: String.starts_with?(Resource.issuer(), "https://"),
        max_age: @browser_max_age,
        path: Routes.path("/oauth")
      )

    {conn, nonce}
  end

  @doc "Headers of a page the person decides on (see the moduledoc)."
  @spec secure(Plug.Conn.t()) :: Plug.Conn.t()
  def secure(%Plug.Conn{} = conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> vary_accept_language()
    |> frame_ancestors_none()
  end

  # The language of the page depends on the header (`PhoenixKitWeb.OAuth.Language`); a `Vary` the
  # host has already set is kept.
  defp vary_accept_language(conn) do
    varies =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)

    if Enum.any?(varies, &(&1 == "*" or String.downcase(&1) == "accept-language")),
      do: conn,
      else: put_resp_header(conn, "vary", Enum.join(varies ++ ["Accept-Language"], ", "))
  end

  # Replaces the `frame-ancestors` directive of each policy the host has already set, or adds a
  # policy of that one directive.
  defp frame_ancestors_none(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [] ->
        put_resp_header(conn, "content-security-policy", "frame-ancestors 'none'")

      policies ->
        # `delete_resp_header/2` drops only the first header of a name; all of them go.
        conn = %{
          conn
          | resp_headers:
              Enum.reject(conn.resp_headers, &match?({"content-security-policy", _}, &1))
        }

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

  @doc """
  Sends `body` as JSON with `status`, `Cache-Control: no-store` and `Pragma: no-cache`
  (the answers of the machine endpoints, RFC 6749 section 5.1).
  """
  @spec json(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
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
