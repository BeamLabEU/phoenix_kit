# Content-Security-Policy

PhoenixKit sets no `Content-Security-Policy` of its own: the policy is the host application's.
This guide says what the kit's pages need from it.

## What the kit renders inline

The kit's layouts and some components render inline `<script>` and `<style>` tags (the theme
bootstrap that runs before first paint, the URL-prefix global, the sidebar state, the table's
view toggle). A policy with `script-src 'self'` and nothing else blocks them, and the admin area
loses its theme switch, sidebar memory and more.

The kit writes nothing into the host's own pages: `PhoenixKitWeb.Plugs.Integration` leaves the
response body alone. Inline code appears only where a kit layout or a kit component is rendered.

## Option 1: a nonce (strict policy)

Generate a nonce per request in a plug of your own, put it in the policy and in `conn.assigns`,
and run that plug **before** `PhoenixKitWeb.Plugs.Integration` in the `:browser` pipeline:

```elixir
defmodule MyAppWeb.Plugs.CSP do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self' 'nonce-#{nonce}'; style-src 'self' 'nonce-#{nonce}'"
    )
  end
end
```

```elixir
pipeline :browser do
  # ...
  plug :put_secure_browser_headers
  plug MyAppWeb.Plugs.CSP
  plug PhoenixKitWeb.Plugs.Integration
end
```

Then tell the kit the name of the assign:

```elixir
config :phoenix_kit, csp_nonce_assign_key: :csp_nonce

# or one assign per kind
config :phoenix_kit, csp_nonce_assign_key: %{script: :script_nonce, style: :style_nonce}
```

Every inline tag the kit renders now carries `nonce="…"`. The kit's own LiveViews keep the nonce
after the socket connects (it travels in the LiveView session), so a `<style>` added by a later
patch is accepted too.

### Your own LiveViews that render kit components

A live session of yours that renders `LayoutWrapper`, the table or the theme controller takes two
options, so the nonce is known after the socket connects as well:

```elixir
live_session :app,
  session: {PhoenixKitWeb.CSP, :live_session, []},
  on_mount: [PhoenixKitWeb.CSP, ...] do
```

Without them the first render still has the nonce; tags added by live navigation do not.

### What a nonce does not cover

- **Inline event handlers** (`onclick="…"`). A few kit components still use them; a nonce cannot
  be attached to an attribute. Until they are replaced, the affected controls need
  `'unsafe-inline'` (which a browser ignores once a nonce is present in the same directive) or
  `'unsafe-hashes'` with their hashes.
- **Inline `style="…"` attributes**, for the same reason: `style-src-attr 'unsafe-inline'`.
- **The HTML sitemap and the public API guide.** They are cached and the same for everyone, so
  they carry no nonce. Their inline style is a constant.
- **Libraries fetched from a CDN** by some components. See
  [Public and admin JavaScript](public-and-admin-javascript.md) for serving them from your own
  origin.

## Option 2: allow inline code

```
script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'
```

Everything works with no configuration. Scripts from other origins and `eval` stay blocked; the
policy no longer stops an injected inline script, and output escaping is the only defence there.
