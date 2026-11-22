# Cross-domain handoff

One application can serve several domains on **different TLDs** (`shop.com`,
`shop.de`, `shop.fr`: one per language, see `config :phoenix_kit,
:canonical_host_resolver`). Cookies are host-only, so a visitor who follows a
link from one of those domains to another arrives as a new anonymous session:
signed out, with the modules' per-session state (a shop's guest cart) gone.

The handoff lets your application link from one domain to another so that the
visitor arrives **still signed in**, and modules get the chance to carry and
re-apply their own state. The link is bound to the visitor's browser: a handoff
link opened in any other browser is useless.

## What you configure

1. **Several domains, one application, one `secret_key_base` and one session
   configuration.** The handoff moves a visitor between domains of the *same*
   application; it does not sign anyone in on a different application.
2. **The host resolver**, which you may already have for canonical URLs and
   `hreflang`:

   ```elixir
   config :phoenix_kit, :canonical_host_resolver, {MyApp.Domains, :host_for_language}
   ```

   `MyApp.Domains.host_for_language("de")` answers `"shop.de"` (a bare
   `host`, or `host:port`), and `nil` for a language without a domain.
   **The hosts the resolver names for the enabled languages are the only hosts
   a handoff may start from, go to or return to.** A host that is not named
   there is refused at every step, so no request parameter or header can make
   the handoff redirect somewhere else.
3. **Every domain on HTTPS.** The handoff redirects are always `https://`, and
   its two cookies (`__Host-pk_handoff_src`, `__Host-pk_handoff_nonce`) are
   `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, and live 60 seconds.
4. **No new routes**: `phoenix_kit_routes()` mounts them, under the kit's URL
   prefix and in your `:browser` pipeline, ahead of the `/:locale` scopes
   (`/handoff` is a reserved segment). With the default prefix:

   | Step | Request | Where |
   |---|---|---|
   | 1 | `GET /phoenix_kit/handoff/start?lang=de&to=/shop` | the domain the visitor is on |
   | 2 | `GET /phoenix_kit/handoff/prepare?return=shop.com&to=/shop` | the target domain |
   | 3 | `GET /phoenix_kit/handoff/mint?n=…&h=shop.de&to=/shop` | the source domain |
   | 4 | `GET /phoenix_kit/handoff/<token>` | the target domain |

   All four answer `Cache-Control: no-store`, are rate limited before anything
   is looked up, and are `log: false` routes.

## Linking

Build the link with the helper and keep a plain link when there is nothing to
hand over to:

```heex
<% href = if PhoenixKit.Handoff.enabled?(),
       do: PhoenixKit.Handoff.start_path("de", "/shop"),
       else: "https://shop.de/shop" %>
<a href={href} rel="nofollow" hreflang="de">Deutsch</a>
```

- `start_path/2` takes the language code of the target domain and a **local
  path on that domain** (`/`, `/shop?page=2`); anything else becomes `/`.
- `enabled?/0` is `true` when the resolver names at least two hosts for the
  enabled languages.
- **Put `rel="nofollow"` on every link to `start`.** The endpoint is not a page.
- A visitor who is anonymous, with nothing for any module to carry, is sent
  straight to `https://<target><to>`: no cookie, no database row.

## robots.txt, logs and analytics

- `Disallow: /phoenix_kit/handoff/` in `robots.txt` (your URL prefix, plus
  `/handoff/`). The routes also answer `X-Robots-Tag: noindex, nofollow` and
  are left out of the sitemap.
- The last step's URL **is a credential for 60 seconds**: the token is in the
  path. The routes are `log: false` (no "Processing with ..." or parameter
  lines) and answer `Referrer-Policy: no-referrer`, but **the kit does not
  filter the request line your endpoint's logger writes** (`Plug.Telemetry` /
  `Plug.Logger` log `GET /phoenix_kit/handoff/<token>` before the router runs;
  the OAuth consent token is the only path the kit's log filter hides), nor
  does it reach your proxy's access log, your analytics or your error tracker.
  Keep `/handoff/` out of them, or scrub the segment after it. The token is
  single use, bound to the target host and to the visitor's browser, and gone
  after 60 seconds, so a leaked one is nearly useless, but do not rely on that.
- A `Sec-Purpose` or `Purpose` header naming `prefetch`, `prerender` or
  `preview`, and a `HEAD` request, are answered `204` and change nothing: a
  browser warming the link or a link-preview robot cannot burn a token or set
  a cookie. (`HEAD` is recognised even behind `Plug.Head`; an adapter that
  keeps no original method is treated as a `GET`.)

## What happens to the visitor

- **Signed in on the source, signed in on the target**, through the normal
  sign-in path (`PhoenixKitWeb.Users.Auth.log_in_user/3`): a session token of
  the target's own (never the source's), the sign-in alert, no remember-me
  cookie. If the browser was signed in as someone else on the target, the
  handoff's account replaces it, and the flash names it ("You are signed in as
  …", in the language of the target domain).
- **Not carried, on purpose:** an impersonated session, a session acting for an
  organization, and an account that may not sign in (inactive, service user,
  organization). Such a visitor is simply sent on, signed out, or sent to `/`.
- **Any failure** at any step (an unknown host or parameter, an expired, used
  or foreign token, a rate limit, a missing cookie) is a `302` to `/` of the
  current domain. There is no error page and nothing tells "used" from
  "unknown".
- A token can be redeemed only on the host it was minted for, by the browser
  that holds the nonce its mint was bound to, and (when the target sees a
  `User-Agent`) by the same `User-Agent`. A request that fails one of those
  does not burn the token.

## Modules

A module takes part with two optional `PhoenixKit.Module` callbacks;
`PhoenixKit.Module` documents the exact context maps.

```elixir
@impl true
def handoff_snapshot(%{user_uuid: user_uuid, session: session, cookies: cookies}) do
  # at mint, on the source: nil when there is nothing to carry
  case session["my_cart_id"] do
    nil -> nil
    id -> %{"cart_id" => id}
  end
end

@impl true
def handoff_apply(%{user_uuid: user_uuid, session: session, cookies: cookies,
                    host: host, locale: locale}, payload) do
  # at redeem, on the target, before the sign-in
  {:ok, %{notices: ["Your cart came along."]}}
end
```

The core knows no module's keys: a module reads its own identity from the
`session` or `cookies` it is handed (they are the request's own), and a module
that needs an identity on the target browser returns `cookies:` from
`handoff_apply/2` (set on the redirect, with `Plug.Conn.put_resp_cookie/4`'s
options).

## Limits

- Requests per address and mint requests per account are capped
  (`handoff_limit`, `handoff_window_ms`, `handoff_mint_limit`,
  `handoff_mint_window_ms` under `config :phoenix_kit, PhoenixKit.Users.RateLimiter`;
  the defaults are 40 a minute per address, 10 mints a minute per account).
- Expired rows are deleted by `PhoenixKit.Handoff.prune_expired/0` (rows that
  expired more than a day ago). Nothing schedules it: call it from a job of
  your own, or let the table grow by one small row per handoff.
- The handoff is a chain of top-level navigations that carry first-party
  cookies; a browser that blocks those cookies, or strips them from redirect
  chains, falls back to the failure path (a plain visit to `/` on the target).
