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

1. **Several domains, one application, one session configuration.** The
   handoff moves a visitor between domains of the *same* application; it does
   not sign anyone in on a different application. Nothing about the
   `secret_key_base` needs sharing between domains: the handoff's source cookie
   is a signed cookie (`Plug.Conn.put_resp_cookie/4` with `sign: true`), but it
   is issued and verified by the same application on the same host, and no other
   domain ever reads it.
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

   Two things follow from that list, and both are yours to keep true:

   - **Every host the resolver names is trusted with a signed-in session.** A
     visitor who follows a handoff link arrives on that host signed in as
     themselves. A name there that no longer points at your application (a
     domain that lapsed, a DNS record that dangles to a service anyone can claim)
     hands the session of every visitor who clicks the link to whoever answers
     for it: **that is an account takeover.** Take a domain out of the resolver
     before you let go of it.
   - A `www.` or any other alias host is **not** a domain of the site unless the
     resolver names it, and a handoff from or to one is refused silently (a
     `302` to `/`).
3. **The scheme.** The redirects of a handoff, and its two cookies, follow the
   scheme the site uses for its other absolute URLs
   (`PhoenixKit.Utils.Routes.canonical_scheme/0`): **`https`**, unless the
   `site_url` setting says `http`. It is never taken from the request or from a
   header. On `https` the cookies (`__Host-pk_handoff_src`,
   `__Host-pk_handoff_nonce`) are `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`,
   with no `Domain`, and live 60 seconds. A `__Host-` cookie must be `Secure`,
   so on an `http` site (a dev machine; set `site_url` to an `http://` URL) the
   same cookies are named `pk_handoff_src` and `pk_handoff_nonce` and are not
   `Secure`. A site that says `https` never falls back to the plain names,
   whatever the connection looks like to the application (a proxy that ends
   TLS hands it plain http).
4. **The session cookie must be `SameSite=Lax`** (what `mix phx.new` ships), **not
   `Strict`.** The `mint` step is a navigation that comes from another site (the
   target's `prepare`); a `Strict` session cookie is not sent with it, so the
   mint sees no session and the handoff quietly turns into a guest handoff: the
   visitor arrives signed out.
5. **No new routes**: `phoenix_kit_routes()` mounts them, under the kit's URL
   prefix and in your `:browser` pipeline, ahead of the `/:locale` scopes
   (`/handoff` is a reserved segment). With the default prefix:

   | Step | Request | Where |
   |---|---|---|
   | 1 | `GET /phoenix_kit/handoff/start?lang=de&to=/shop` | the domain the visitor is on |
   | 2 | `GET /phoenix_kit/handoff/prepare?return=shop.com&to=/shop&s=…` | the target domain |
   | 3 | `GET /phoenix_kit/handoff/mint?n=…&h=shop.de&to=/shop&s=…` | the source domain |
   | 4 | `GET /phoenix_kit/handoff/<token>` | the target domain |

   All four answer `Cache-Control: no-store` and are `log: false` routes.

## Deploying

Run the migration (V236, `mix phoenix_kit.update`) **before** the code that links to
`start` goes live. Until V236 has run there is no table to write: every handoff ends
with a `302` to `/` (and a logged error), and `enabled?/0` is already `true`, so a
language switcher that links to `start` lands the visitor back on `/` of the domain
they started on. Signing out, signing out everywhere and a password change keep working
without the table; they delete nothing from it.

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
- **Links to `start` must be same-origin links, rendered by your own pages**
  (a language switcher, a "continue in the German shop" button): `start` refuses a
  request that is not a top-level navigation of the visitor's own, from the
  host's own page. A link to it on another site, a sibling subdomain, an `<img>`
  or `<iframe>` that loads it, a form or script that aims the visitor at it, is
  answered with a `302` to `/` and changes nothing. The rule: `Sec-Fetch-Site`
  must be `same-origin` or `none`, and `Sec-Fetch-Dest`, when sent, `document`. It
  is the answer to a page of another site that would otherwise replace whoever is
  signed in on the target with the account signed in on the source, just by
  sending the visitor there. It is checked **before** the rate limit, so such
  requests cost the visitor's address no budget.
  - **`none` is not only "typed or bookmarked".** Browsers send it for every
    navigation started outside a page: the address bar, a bookmark, a link in a
    mail client, a link opened by another application. A mail or a desktop
    application can therefore aim a visitor at `start`, and so can a link in user
    content, which is same-origin. The effect is bounded: it can only move the
    visitor between **their own** signed-in accounts (the account signed in on the
    source replaces the one signed in on the target), and the destination is a
    local path on one of your own hosts.
  - **`same-site` is refused.** It is what a browser reports for a request from a
    *sibling subdomain* (`blog.shop.com` to `shop.com`), which is not the host's
    own page and may be a dangling or a tenant-controlled one. Your links to
    `start` are always same-origin, so nothing legitimate is lost.
  - **A link to `start` on ANOTHER of your own domains is cross-site, and
    refused.** The link must be on the domain the visitor is *leaving*: the
    German link on `shop.com`'s pages points at `shop.com`'s own `start`
    (`/phoenix_kit/handoff/start?lang=de`), never at `shop.de`'s from a page of
    `shop.com`. `start_path/2` gives exactly that path, without a host.
  - **What this does not cover: clients that send no fetch metadata.** A request
    with no `Sec-Fetch-Site` and no `Sec-Fetch-Dest` cannot be told from a
    visitor's own click, and is let through. That is: Chrome before 76, Firefox
    before 90, Safari before 16.4, some old WebViews, sites served over plain
    `http` (browsers send the headers only to trustworthy origins), and proxies or
    security software that strip them. For such a client the guard does not exist:
    a page of another site can aim it at `start`. What that buys the page is
    limited, not nothing: the visitor must be signed in on the source or hold
    module state, the destination is always one of your own hosts, and the
    redeem replaces the account signed in on the target with the one signed in on
    the source (the same swap between your own domains).
- **The other three steps check only what is loaded, not the site.** `prepare`,
  `mint` and `redeem` are reached by *redirects* from another of your domains, for
  which the browser reports `Sec-Fetch-Site: cross-site`; refusing that would
  refuse every handoff. But a `Sec-Fetch-Dest` that is present and is not
  `document` (an `<img src=".../handoff/<token>">` on another site, an iframe, a
  `fetch()`) is refused at each of them with a `302` to `/`, **before** the rate
  limit, a cookie or the database: such a request takes no failed-redeem slot, burns
  no token and deletes no cookie. What protects them beyond that is what they
  need: a cookie only an earlier step of the same browser sets, a proof, a nonce.
- A visitor who is anonymous, with nothing for any module to carry, is sent
  straight to `<scheme>://<target><to>`: no cookie, no database row.

## robots.txt, logs and analytics

- `Disallow: /phoenix_kit/handoff/` in `robots.txt` (your URL prefix, plus
  `/handoff/`). The routes also answer `X-Robots-Tag: noindex, nofollow` and
  are left out of the sitemap.
- The last step's URL **is a credential for 60 seconds**: the token is in the
  path. The routes are `log: false` (no "Processing with ..." or parameter
  lines) and answer `Referrer-Policy: no-referrer`. Every line **the kit owns**
  shows `/handoff/[FILTERED]`: the kit registers a Logger filter
  (`PhoenixKit.API.OAuth.RequestLog`, the one that hides the OAuth consent
  token, started with the kit's supervisor, so your endpoint needs no option) that
  rewrites the request line of the stock endpoint loggers (`Plug.Telemetry` /
  `Plug.Logger`), and the `[RequestTimer]` lines of the kit's own plug log the
  same hidden path. `start`, `prepare` and `mint` stay readable.
  **Loggers and proxies that are yours are yours to scrub**: your proxy's or
  CDN's access log, your analytics, your error tracker, and a request logger of
  your own that writes the path as metadata or in a report instead of a plain
  text line. Keep `/handoff/` out of them, or scrub the segment after it. The
  token is single use, bound to the target host and to the visitor's browser,
  and gone after 60 seconds, so a leaked one is nearly useless, but do not rely on
  that.
- A `Sec-Purpose` or `Purpose` header naming `prefetch`, `prerender` or
  `preview`, and a `HEAD` request, are answered `204` and change nothing: a
  browser warming the link or a link-preview robot cannot burn a token or set
  a cookie. (`HEAD` is recognised even behind `Plug.Head`; an adapter that
  keeps no original method is treated as a `GET`.)

## What happens to the visitor

- **Signed in on the source, signed in on the target**, through the normal
  sign-in path (`PhoenixKitWeb.Users.Auth.log_in_user/4`): a session token of
  the target's own (never the source's), the sign-in alert, no remember-me
  cookie, and **the age of the session it continues** (next section). If the browser was signed in as someone else on the target, the
  handoff's account replaces it, and the flash names it ("You are signed in as
  …", in the language of the target domain).
- **The visitor lands on the path the link named.** The link chose `to` for the
  target domain, so a person's saved language does not turn `/shop` into
  `/fr/shop` there (the ordinary sign-in does that, a handoff does not).
- **Not carried, on purpose:** an impersonated session, a session acting for an
  organization, and an account that may not sign in (inactive, service user,
  organization: `PhoenixKit.Users.Auth.sign_in_refusal/1`, the one rule
  `log_in_user` also uses). Such a visitor is simply sent on, signed out, or
  sent to `/`.
- **Any failure** at any step (an unknown host or parameter, an expired, used
  or foreign token, a rate limit, a missing or forged cookie) is a `302` to `/`
  of the current domain. There is no error page and nothing tells "used" from
  "unknown".
- A token can be redeemed only on the host it was minted for, by the browser
  that holds the nonce its mint was bound to, and (when the target sees a
  `User-Agent`) by the same `User-Agent`. A request that fails one of those
  does not burn the token.
- **A token dies with the sessions of its account.** Every deletion of session
  tokens (log out everywhere, a password change or reset, an account switched
  off or deleted, an admin's revoke) also deletes that account's unused
  handoff rows, in the same transaction; and `redeem` loads the account again
  and asks `Auth.sign_in_refusal/1` once more.

## Session age

A handoff **continues** a sign-in; it does not start a new one. The session the
target signs in is built from the source session the handoff was minted from
(`phoenix_kit_handoff_tokens.source_session_uuid`, V236), so it inherits what the
kit's rules read from a session:

| Inherited | Why it matters |
|---|---|
| **`inserted_at`**: the new token has the source token's, not "now" | Every rule that reads a session's age sees the real sign-in. A session that is 59 days old is still 59 days old on the target and expires at the same moment as the source (the 60 days a session lives). **Handing a session over, any number of times, never lengthens its life.** The 15-minute window in which a passkey may be added (`PhoenixKit.Users.Passkeys.check_may_add/2`) is the same on both: a session that is stale on the source is stale on the target, and a fresh one is fresh on the target until it stops being fresh on the source. A rule of your own that reads `phoenix_kit_users_tokens.inserted_at` gets the same for free. |
| **`active_role_uuid`**: the role the session acts as (`PhoenixKit.Users.ActiveRole`) | A session an Admin narrowed to "Seller" stays narrowed on the target, instead of falling back to the default (widest) role. |

Not inherited, because it describes the browser that opens the target session, not
the sign-in: the IP address, the user agent and the device name on the token (the
target browser's own), the remember-me cookie (none is set), and the new-device
alert (the target browser has not been seen on that host, so the alert is the
normal one).

- **The source session must still exist at redeem.** The token names it; `redeem`
  looks it up again and the handoff fails if it was signed out, revoked or has
  expired in the meantime, however it went (it does not matter whether a
  revocation hook ran). No timing is involved: a revocation that commits at any
  moment before the redeem ends the handoff. The look-up is repeated right before
  the visitor is signed in, after the modules' apply hooks (which can take up to
  five seconds): a session revoked in that window also ends the handoff, with a
  `302` to `/`. What the modules already did on the server by then stays; they have
  been told, and it cannot be taken back.
- `mint` refuses an account whose session it cannot find (it went between the
  pipeline and the insert), and `Handoff.mint/1` refuses an account with no
  session to name: a row for an account always continues one.
- A **guest** has no session and a guest's row names none; nothing is inherited.
- The sessions list shows the handed-over session with the date of the original
  sign-in (it is the same sign-in), so the source and the target rows share it.
- The cookie session is not carried: a "recently signed in" marker a host keeps in
  the cookie session of the source is not on the target, which is the safe side.
  Put such a rule on the session token's age, where the kit puts its own.

## What the binding gives, and what it does not

`start` sets a **signed** cookie on the source domain (a secret, 60 seconds, made
with the application's `secret_key_base`) and sends the SHA-256 of that secret
through `prepare` to `mint` (`s`). `mint` reads the cookie as a signed cookie, so
a value the application did not issue is not a cookie at all, and requires its
hash to equal `s` (a constant-time comparison); only then does it delete the cookie.
A request that does not carry the matching proof leaves the cookie alone, so a page of
another site cannot take it by sending the visitor to `mint`; likewise the nonce cookie is
deleted only by a `redeem` that went through, not by a request for a token that does not
exist.

That gives:

- `mint` writes a row only for a browser that holds a cookie this application
  issued in the last minute, which only a counted `start` hands out. A script
  that never clicked a link cannot make the table grow, however it forges the
  cookie or the parameters.
- **A source cookie yields at most one row, whatever the client does.** The
  response to `mint` deletes the cookie, but that is only a `Set-Cookie`, which a
  client that is not a browser ignores, and within its minute the same genuine
  cookie and the same `s` would pass the check every time. So the proof is made
  single use **on the server**: the row stores the proof's hash
  (`source_proof_hash`, V236) under a unique index, and a second `mint` with the
  same proof hits it and is refused (`Handoff.mint/1` answers
  `{:error, :proof_used}`). This is the guarantee, and it holds across nodes and
  restarts. In front of it sit three things that only save work: `mint` asks the
  database, with one indexed existence query on `source_proof_hash`, whether the
  proof already has a row, **before it asks the host resolver or any module**, so a
  replay (on another node, after a restart, after the limiter forgot it) is
  refused there and costs no snapshot round. (The session token has been looked
  up by then, by the pipeline's own `fetch_phoenix_kit_current_user` ahead of the
  controller; what a replay skips is building the scope, the resolver and every
  module's snapshot.) one `mint` per proof per minute (per
  node, in memory); and, **for a guest and a signed-in account alike**, 60 mints a
  minute per address. What a client with one genuine cookie can cost is therefore
  one row and, at most, the snapshot rounds of the requests that arrive before the
  first row is committed: parallel replays all pass the existence check, each
  takes a snapshot round, and the unique index lets exactly one of them write
  (the rest are refused). That burst is bounded by the per-address budget (and,
  per node, by the proof's). To cost more it needs more `start`s, and those are
  counted per address. A refused request is still a request: the table is bounded,
  the request rate is the limiter's and your proxy's.
- A `mint` request that someone else crafts for a victim's browser is refused:
  it needs the hash of a secret that sits in an `HttpOnly` cookie of the victim.
- A handoff with nothing to carry (no account and no snapshot) is refused at
  `mint`, so the endpoint cannot be used to write empty rows either.

It does **not** give:

- `n`, the nonce hash, is **not** bound to `s`: the target cannot know the source
  secret, so nothing ties the two together on the target's side. What stops a
  mix-up is that the token a `mint` produces carries the identity of the session in
  the browser that performs the mint, is bound to the nonce hash the request
  names, and goes out in a redirect only that browser reads. A crafted `mint` can
  at most choose `n`; the token it produces can be redeemed only by a browser
  holding the matching nonce cookie, and signs in the account of the minting
  browser, never anyone else's.
- It is not an authentication of the visitor: a person with their own account
  can complete a handoff for that account, which is what it is for.

## Modules

A module takes part with two optional `PhoenixKit.Module` callbacks. This is
the contract: what is called when, what is handed over, what may come back.

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
  {:ok, %{notices: ["Your cart came along."],
          cookies: [{"my_cart_id", payload["cart_id"], [max_age: 86_400, sign: true]}]}}
end
```

The core knows no module's keys: a module reads its own identity from the
`session` or `cookies` it is handed (they are the request's own), and a module
that needs an identity on the target browser returns `cookies:` from
`handoff_apply/2`.

**What a module is handed is the visitor's own input.** The `cookies` are what
the browser sent, and the `session` holds whatever the visitor's earlier
requests put in it; a snapshot is stored and handed to `handoff_apply/2` on the
other domain. Validate it as you would a request parameter (a cart id is looked
up and checked to be a guest's, never trusted because it arrived here).

### When they are called

- **Only for an enabled module** (`enabled?/0` is `true`). A module that is
  switched off is never snapshotted and never applied, even if a row names it.
  (`before_user_delete/1` is the other way round: it reaches every module.)
- `handoff_snapshot/1`: **once at `mint`**, and, for a visitor who is not signed
  in, once more at `start` to find out whether there is anything to carry. So
  once for a signed-in visitor, twice for a guest. Cheap, and it changes nothing.
- `handoff_apply/2`: **once at `redeem`, before the sign-in**, for a module that
  has an entry in the payload. It may change things (merge a cart); the visitor
  is signed in after it returns.
- **Each call runs in a supervised task of its own, all of a call site at the
  same time, under one deadline for the whole call site**: **2000 ms** for the
  snapshots (the one round at `start` or `mint`), **5000 ms** for the applies (the
  one round at `redeem`). M modules therefore cost one deadline, not M. A task
  still running at the deadline is killed (`:brutal_kill`) and logged, the module
  is left out (or its answer ignored) and the handoff goes on. The modules'
  answers are used in the order of the modules, not of who finished first.
- **What the task has, and has not.** It inherits the request's `$callers` (so an
  Ecto sandbox allowance follows it, and a hook can read and write the database)
  and its Gettext locale. It does **not** have the rest of the request's process
  state, because it is a different process: no process dictionary, so **no
  per-request dynamic repo or prefix** (a hook reads and writes the host's default
  repo), **no request currency or other per-request setting a plug put in the
  process**, and **no `Logger` metadata** (the request id is not on its log
  lines). A module derives what it needs from what it is handed: the `:host` and
  `:locale` (at apply), the `session` and the `cookies`.
- **A hook killed at the deadline may leave effects that are not in the
  database.** Its open database transaction is rolled back (the connection is dropped), but a message it sent,
  a request it made, a file it wrote or a cache entry it set stays. Keep a
  snapshot free of side effects (it must change nothing), and make an apply
  idempotent or tolerant of having run partly.
- Any failure of a module (a raise, an exit, a throw, a timeout, a wrong answer)
  is logged with the module and the kind of failure, never the message, and
  never stops the handoff of the others.

### What a module is handed

`handoff_snapshot/1` gets a map with exactly the keys `:user_uuid`,
`:session` and `:cookies`; `handoff_apply/2` gets those and `:host` and
`:locale`, then the `payload`.

| Key | Value |
|---|---|
| `:user_uuid` | the signed-in account, or `nil` for a visitor (at apply: the account about to be signed in, or `nil` for a guest) |
| `:session` | the Plug session of the request (`Plug.Conn.get_session/1`, string keys), **without** the kit's auth material |
| `:cookies` | the request cookies, `%{name => value}`, unsigned as the browser sent them, **without** the kit's auth cookies, and **empty** when the host's session cookie cannot be named (below) |
| `:host` | (apply only) the host the request arrived on |
| `:locale` | (apply only) the enabled language code that host serves (`"de"`, `"de-DE"`), or `nil` |

**Removed from `:session`** (`PhoenixKit.Handoff.auth_session_keys/0`, the one
list, built on `PhoenixKit.HeaderWidget.reserved_session_keys/0`, which a header
widget's session is held to as well): `"user_token"` and `"live_socket_id"` (the
signed-in session); `"pk_session_accounts"`, `"pk_own_tokens"`,
`"pk_impersonators"` and `"pk_organization_token"` (the multi-account stack);
`"phoenix_kit_session_uuid"`; `"website_access_unlock"` and
`"website_access_allowed"` (the website gate); `"_csrf_token"`.

**Removed from `:cookies`** (`PhoenixKit.Handoff.auth_cookie_names/1`):
`"_phoenix_kit_web_user_remember_me"`; `"_phoenix_kit_web_session_accounts"`;
`"_phoenix_kit_device"`; `"pk_oauth_browser"`; the four handoff cookies
(`"pk_handoff_src"`, `"pk_handoff_nonce"` and their `__Host-` forms); and **the
host's session cookie**, whose name the kit reads from the `session:` connect
info of the sockets of the endpoint that served the request
(`PhoenixKit.Handoff.session_cookie_names/1`). Keep your LiveView socket's
`connect_info: [session: @session_options]` (every Phoenix 1.7+ app has it; a
keyword list or an `{module, function, args}` that returns one is read).
**If the name cannot be told, the module is handed no cookies at all**: the
session cookie is a signed cookie that exposes `user_token`, and one that cannot
be told from the others must not be passed on, so the handoff fails closed and
logs a warning once per endpoint. A host in that case loses its modules'
cookies (a guest cart kept in a cookie is not carried), not its sessions;
declaring the session on a socket restores them. **The same on the way back:**
without the session cookie's name, every cookie a module's `handoff_apply/2` asks
to set is refused (and logged once per module), so that a module cannot set a
cookie with the session cookie's name either. When the name is known it is
reserved with the kit's own names, and a module that tries it is left out.

A snapshot is stored as plaintext `jsonb`: **a module never puts a secret in it**
(a token, a password, anything it does not want read from the database), and
never snapshots `session` or `cookies` wholesale. The same applies to the
payload a module gets back.

`payload` (apply) is what `handoff_snapshot/1` returned, with string keys.

There is no currency in the context: the core has none. A module derives it
from `:host` or `:locale` itself.

### What `handoff_snapshot/1` may return

- `nil` or `%{}`: nothing to carry.
- A JSON-safe map whose JSON encoding is at most **65 536 bytes**.
- Anything else (not a map, not JSON-encodable, too large) is logged and the
  module is left out.

### What `handoff_apply/2` may return

- `{:ok, notices}`, a list of strings;
- `{:ok, %{notices: [...], cookies: [{name, value, opts}]}}`, either key
  optional, any other key (`moved: 2`, `skipped: [...]`) ignored;
- `{:error, term}`: logged, ignored.

Everything is **validated; what is invalid is left out, never raised on**, and
the visitor is handed over without it:

| | Limit |
|---|---|
| Notices | text only (valid UTF-8, trimmed, empty ones dropped); at most **5**, at most **300 bytes** each and **600 bytes** in all, cut on a character boundary. They are shown with the sign-in message, in the flash, which lives in the cookie session: that is why the total is capped. |
| Cookies | at most **5** per module and **10** in all |
| Cookie `name` | an RFC 6265 token (letters, digits, ``!#$%&'*+-.^_`|~``), 1 to 64 bytes, and none of the kit's own names (the list above, session cookie included) |
| Cookie `value` | a binary of at most **2048 bytes**, of cookie characters (printable ASCII but space, `"`, `,`, `;` and `\`); with `sign: true` or `encrypt: true`, any binary of that size |
| Cookie `opts` | a keyword list; only `:max_age` (integer, 0 to 34 560 000), `:http_only`, `:secure`, `:sign`, `:encrypt` (booleans, not both), `:same_site` (`"Lax"`, `"Strict"`, `"None"`; `"None"` only with `secure: true`) and `:path` (starts with `/`, at most 256 bytes) are passed on. Any other key (`:domain`, ...) is dropped; an invalid value drops the cookie. |

**Cookie defaults**, unless the module passes the option itself:
`secure: true` (`false` on a plain-http dev site, where the browser would drop
a `Secure` cookie), `http_only: true`, `same_site: "Lax"`. A cookie is always
host-only (no `Domain`).

A **signed or encrypted** cookie is made with the application's `secret_key_base`
(read it later with `Plug.Conn.fetch_cookies(conn, signed: [name])`), and Plug
puts the cookie's `:max_age` into the signature, **a day when none is given**:
pass the lifetime your own plug expects, or the cookie stops verifying after a
day however long the browser keeps it.

**A `sign: true` cookie proves that this application issued it, not that its
value is trustworthy.** The value comes from the visitor's own cookies and
session on the source domain, and the signing salt is the cookie's name. Your
plug that reads it back must still treat the value as input (look the cart up,
check it is a guest's and still open), exactly as it would a cookie it had set
itself in an earlier request that took a value from the visitor.

The handoff never lets a module set a cookie of the kit's (the list above), or
read the kit's auth material. It does not give a module the means to sign
anyone in: the sign-in is the core's, after the hooks.

## Limits

- **Rate limits** (`config :phoenix_kit, PhoenixKit.Users.RateLimiter`; a
  handoff is counted **once**, where it starts):

  | Key | Default | What |
  |---|---|---|
  | `handoff_start_limit`, `handoff_start_window_ms` | 60 a minute | `start`, per address (an office behind one NAT) |
  | `handoff_mint_limit`, `handoff_mint_window_ms` | 20 a minute | `mint`, per account |
  | `handoff_mint_ip_limit`, `handoff_mint_ip_window_ms` | 60 a minute | `mint`, per address, for guests and signed-in accounts alike |
  | `handoff_redeem_failure_limit`, `handoff_redeem_failure_window_ms` | 30 a minute | `redeem`, per address, **failures only** (a good redeem hands its slot back) |

  The one-mint-per-source-proof budget has no setting: it is the lifetime of the
  source cookie.

  Buckets are per node (a second node has its own), which is why the one guarantee
  that must hold across nodes, a source proof's single use, lives in the
  database. A refusal is a silent redirect to `/` and is logged at debug level,
  not as a warning. The windows are fixed, aligned to the clock: a count of
  failed redeems can be one off at a window boundary (a good redeem hands its
  slot back to the window it finds, which at the boundary may be the next one:
  at most one extra attempt, once). A check that counted a failure only after it
  happened would be exact but would let a parallel burst through before the
  first failure was counted, so the slot is taken up front.
- **Retention.** A row holds an account uuid, hashes and the modules' payload
  (at most 64 KB per module), and is refused after 60 seconds whether or not it
  has been pruned. It is deleted by `PhoenixKit.Handoff.PruneWorker`, a daily
  Oban worker (04:55; `mix phoenix_kit.update` adds it to a host's crontab like the
  other cleanup workers; commenting its line out declines it) that removes the
  rows that expired more than a day ago, and every mint deletes a small batch
  (20) of rows that expired more than five minutes ago. A host with no Oban
  crontab would let the table grow by one row per handoff (a handoff needs a
  signed-in account or a module snapshot, and a `start` from an address inside its
  limit): schedule `PhoenixKit.Handoff.prune_expired/0` yourself.
- **Sessions accumulate.** Each handoff adds a session row on the target that lives until the
  source session expires, and the kit has no per-account session cap, so switching language grows
  the account's session list (bounded only by the mint limit above).
- The handoff is a chain of top-level navigations that carry first-party
  cookies; a browser that blocks those cookies, or strips them from redirect
  chains, falls back to the failure path (a plain visit to `/` on the target).
