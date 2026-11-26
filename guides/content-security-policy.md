# Content-Security-Policy

PhoenixKit sets no `Content-Security-Policy` of its own: the policy is the host application's.
This guide says what the kit's pages need from it.

## What the kit renders inline

The kit's layouts and some components render inline `<script>` and `<style>` tags (the theme
bootstrap that runs before first paint, the URL-prefix global, the sidebar state, the table's
view toggle). It renders no inline event handlers. A policy with `script-src 'self'` and
nothing else blocks them, and the admin area loses its theme switch, sidebar memory and more.

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
      # style-src-attr: the kit (like most UI libraries) sets some `style="…"` attributes,
      # and no nonce can be put on an attribute.
      "default-src 'self'; script-src 'self' 'nonce-#{nonce}'; " <>
        "style-src 'self' 'nonce-#{nonce}'; style-src-attr 'unsafe-inline'"
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

`mix phoenix_kit.doctor` ("Content-Security-Policy") reports a value of the wrong shape, which
would otherwise read as "no nonce" with nothing said, and lists the plugs of `pipeline :browser`
that run after `Plugs.Integration`.

### Why the plug order matters, and where it does not

`Plugs.Integration` reads the nonce when it runs, for the kit components on **your own pages**
(the theme bootstrap the installer put in your root layout). A nonce assigned later is not seen
there, and those tags render without one.

The kit's own routes read it again after your whole `:browser` pipeline, and its hand-written
pages (the website gate, the push pages, the OAuth consent pages) read it from the connection
when they render, so on those the order does not matter. When the kit sees that a nonce
appeared after `Integration` ran, it logs one warning naming the fix.

The maintenance page and the website gate are answered from inside `Integration`. They get the
nonce only when your plug ran before it.

### The script tags in your root layout

A nonce is not needed on a `<script src="…">` of your own origin under `script-src 'self'`.
Put it on the tag that loads `phoenix_kit.js` anyway (see "Styles and scripts the bundle
creates" below), and on every script tag if your policy uses `'strict-dynamic'`, which ignores
`'self'`:

```heex
<script defer nonce={assigns[:csp_nonce]} src={~p"/assets/vendor/phoenix_kit.js"}></script>
<script defer nonce={assigns[:csp_nonce]} src={~p"/assets/vendor/phoenix_kit_modules.js"}></script>
<script defer nonce={assigns[:csp_nonce]} phx-track-static src={~p"/assets/app.js"}></script>
```

### Your own LiveViews that render kit components

A live session of yours that renders `LayoutWrapper`, the table or the theme controller takes two
options, so the nonce is known after the socket connects as well:

```elixir
live_session :app,
  session: {PhoenixKitWeb.CSP, :live_session, []},
  on_mount: [PhoenixKitWeb.CSP, ...] do
```

Without them the first render still has the nonce; tags added by live navigation do not.

`live_session` takes one `session:`. If you already have one, merge:

```elixir
def live_session(conn) do
  Map.merge(my_session(conn), PhoenixKitWeb.CSP.live_session(conn))
end
```

### Nested LiveViews

A view rendered with `live_render/3` is a process of its own and skips the live session's
`on_mount`. The kit hands the nonce to its own nested views (the header widgets, the
notifications bell, the admin home). For one of yours that renders kit components, pass the
session through `PhoenixKitWeb.CSP.nested_session/1` and restore it in the child:

```elixir
{live_render(@socket, MyAppWeb.WidgetLive, id: "w", session: PhoenixKitWeb.CSP.nested_session(%{}))}

defmodule MyAppWeb.WidgetLive do
  use Phoenix.LiveView
  on_mount PhoenixKitWeb.CSP   # already there with `use PhoenixKitWeb, :live_view`
end
```

A module's header widget (`header_widgets/0`) gets the session for free; its view needs the
`on_mount` line unless it uses `PhoenixKitWeb, :live_view`.

### Inline event handlers

The kit renders none (`onclick="…"`, `onerror="…"`): no nonce can be put on an attribute, so what
they did is now done by listeners in `phoenix_kit.js`, keyed on `data-pk-*` attributes. Your root
layout must load that file (the installer adds it) for copy buttons, dropdowns that close after a
choice, the decimal field's zero and the preview card's arrows to work.

A handler you pass to a kit component yourself (`<.decimal_input onfocus="…">`) is rendered as
you wrote it. Under a nonce policy the browser blocks it like any other inline handler; the
component's own behaviour keeps working.

A page rendered under the kit's fallback root layout (a host with no `root_layout` configured)
loads `/assets/vendor/phoenix_kit.js` by itself when your application serves that file.

### Styles and scripts the bundle creates

`phoenix_kit.js` and `phoenix_kit_admin.js` also insert `<style>` elements after the page has
loaded: the fresco theme bridge (on every page that loads the public bundle), the consent
widget's rules, the change cue, gallery chrome, and the rules a table uses to hide columns.
A nonce policy drops a style element that has none. The bundle stamps the document's **style**
nonce on the element before inserting it — the nonce of a `<style>` already on the page, or,
when the page has none, the nonce of the `<script>` tag that loaded the bundle. With one nonce
for both, as in the plug above, put that nonce on the tag:

```heex
<script defer nonce={assigns[:csp_nonce]} src={~p"/assets/vendor/phoenix_kit.js"}></script>
```

A host page that has neither a nonced `<style>` nor a nonce on that script tag still blocks
those rules. When the two nonces differ, a `<style>` already on the page is what the bundle
reads; it does not reuse the script nonce in that case.

A script the consent widget releases, once its category is accepted, keeps the nonce of the
tag it replaces. The browser does not put that nonce in the attribute list, so copying the
attributes is not enough.

The table's first paint does not replay a stylesheet it stored. It rebuilds the rules from the
column numbers and only then gives them the nonce. Text kept in the browser is not made an
allowed stylesheet by the page holding a nonce.

### What a nonce does not cover

- **Inline `style="…"` attributes.** The kit uses them, and so does the cookie-consent widget
  (its `<style>` element is nonced; the attributes on its buttons are not): `style-src-attr
  'unsafe-inline'`, or `style-src 'unsafe-inline'` if you do not split the directive.
- **The HTML sitemap and the public API guide.** They are cached and the same for everyone, so
  they carry no nonce. Their inline style is a constant.
- **Libraries fetched from a CDN** by some components. See
  [Public and admin JavaScript](public-and-admin-javascript.md) for serving them from your own
  origin.
- **Module packages** (`phoenix_kit_*`) are converted on their `main` branches (their inline
  handlers are gone, their inline tags and bundle-created styles take the nonce); each reaches
  you with its own next release. Where a module's handler moved into its own JavaScript
  (billing, inbox, ecommerce, sync, document creator and others), the page has to load
  `phoenix_kit_modules.js`. Styles a module appends to a cached body (publishing's post styles)
  carry no nonce, like the sitemap's.
- **The calendar popup of date fields** (the vendored `cally` library) creates a style element
  of its own, without a nonce.

### Other directives the kit's features need

A policy that starts from `default-src 'self'` also has to allow what these features reach:

| Feature | Directive |
|---|---|
| LiveView's socket | `connect-src 'self'` covers `wss:` of the same origin in current browsers; older ones need the `wss://` origin spelled out |
| Cloudflare Turnstile on the public auth forms | `script-src` and `frame-src https://challenges.cloudflare.com` |
| Upload previews, the image editor, avatars cropped in the browser | `img-src 'self' blob: data:` (and `media-src blob:` for recorded audio) |
| Files served straight from a bucket or CDN | that origin in `img-src` / `media-src` |
| Gravatar avatars | `img-src https://www.gravatar.com` |
| The OAuth consent form, which answers with a redirect to the client | the clients' redirect origins in `form-action`, or no `form-action` |

## What was checked in a browser

Headless Chromium, with the policy of Option 1 and the bundles of this repository: an otherwise
empty page that loads the two bundles, a controller page with the theme toggle, a decimal
field, copy buttons, a broken image and a dropdown, and a LiveView with nested views that add a
`<style>` after the socket connects; each with one nonce, with a nonce per kind, and with the
nonce assigned after `Integration`. No violation from the kit in any of them. The harness is in
`dev_docs/handoffs/2026-11-25-csp-browser-harness/`. Not checked there: the consent widget, the
table's column fitting, the kit's real router and layouts, Safari and Firefox.

## Option 2: allow inline code

```
script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'
```

Everything works with no configuration. Scripts from other origins and `eval` stay blocked; the
policy no longer stops an injected inline script, and output escaping is the only defence there.
