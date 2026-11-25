defmodule PhoenixKitWeb.Plugs.Integration do
  @moduledoc """
  Central integration plug for PhoenixKit.

  This plug serves as a single entry point for all PhoenixKit plugs that need to run
  in the parent application's browser pipeline. It coordinates multiple sub-plugs and
  ensures they run in the correct order.

  ## Current Features

  - **Remember-me sessions**: when the session has no user token but the
    remember-me cookie is present, the session is rebuilt from it
    (`PhoenixKitWeb.Users.Auth.restore_remembered_session/1`) — on every
    page, not only the ones that run the kit's fetch plugs
  - **Website access** (`PhoenixKitWeb.Plugs.WebsiteAccess`): allowed
    addresses, the redirect to production, the password gate, maintenance
    mode — in that order, plus the `X-Robots-Tag` header while the site is
    hidden from search engines

  ## The response is never rewritten

  The plug adds no markup to a page. It used to put an inline `<script>` after
  `<head>` on every HTML response (the clearing of the cached LongPoll
  fallback); a host with a `script-src` policy that has no `'unsafe-inline'`
  got that script blocked on its own pages. `phoenix_kit.js`, which the host's
  root layout loads before `app.js`, does the same clearing, so nothing is
  lost. Keep it that way: anything a page needs from the kit goes into that
  file or a component the layout renders, not into the response body here.

  - **CSP nonces** (`PhoenixKitWeb.CSP`): when the host names the assign
    that holds its Content-Security-Policy nonce, the kit's inline tags on
    this page carry it. The host's plug that assigns the nonce runs before
    this one.

  ## Future Extensions

  This plug can be extended to include additional PhoenixKit features such as:
  - Rate limiting
  - Security headers
  - Analytics tracking
  - Custom middleware

  ## Usage

  This plug is automatically added to your `:browser` pipeline during installation:

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug PhoenixKitWeb.Plugs.Integration  # ← Added automatically
      end

  ## Performance

  Each sub-plug is optimized to be a no-op when its feature is disabled, ensuring
  zero performance impact when features are not in use.
  """

  alias PhoenixKitWeb.CSP
  alias PhoenixKitWeb.Plugs.WebsiteAccess
  alias PhoenixKitWeb.Users.Auth

  @doc """
  Initializes the plug with options.
  """
  def init(opts), do: opts

  @doc """
  Runs all PhoenixKit integration plugs in sequence.
  """
  def call(conn, _opts) do
    # Website access — the allowed addresses, the redirect to production, the
    # password gate, and maintenance (which used to be called from here
    # directly).
    #
    # The session is rebuilt from the remember-me cookie first, because the
    # maintenance gate lets a signed-in administrator through by reading the
    # session's user token.
    #
    # The page's CSP nonces are remembered before anything can render (the
    # gate and the maintenance page are written from here).
    conn
    |> CSP.put_nonces_first()
    |> Auth.restore_remembered_session()
    |> WebsiteAccess.call([])
  end
end
