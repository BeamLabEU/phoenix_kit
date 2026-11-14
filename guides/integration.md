# PhoenixKit Integration Guide

**For developers using PhoenixKit as a Hex dependency in their Phoenix application.**

This guide is designed to help both developers and AI assistants (Claude, Cursor, Copilot, Tidewave MCP, etc.) understand how to integrate and use PhoenixKit effectively.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Installation](#installation)
3. [Configuration Reference](#configuration-reference)
4. [Authentication Integration](#authentication-integration)
5. [Protecting Sign-up and the Mail You Send](#protecting-sign-up-and-the-mail-you-send)
6. [Updating](#updating)
7. [Testing Your App](#testing-your-app)
8. [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# 1. Verify database is prepared
mix ecto.migrations

# 2. Install PhoenixKit (adds dep, fetches, configures, generates migrations)
mix igniter.install phoenix_kit

# 3. Create database if needed
mix ecto.create

# 4. Run migrations
mix ecto.migrate

# 5. Start your server
mix phx.server
# Visit /phoenix_kit/admin
```

> Requires the `igniter_new` archive — install once with `mix archive.install hex igniter_new`. If you'd rather not, see the [two-step fallback](#step-2-install) below.

---

## Installation

### Step 1: Run the Installer

```bash
mix igniter.install phoenix_kit
```

The installer will:
- Add `{:phoenix_kit, "~> 3.0"}` to your `mix.exs` and fetch deps
- Detect your Repo automatically (or use `--repo` to specify)
- Add configuration to `config/config.exs`
- Generate migrations
- Set up mailer integration

> Requires the `igniter_new` archive — `mix archive.install hex igniter_new` if you don't already have it.

### Step 2: Install (two-step fallback)

If you can't or don't want to use the `igniter_new` archive, add the deps manually and run the installer directly. Declare **both** — PhoenixKit marks `:igniter` `optional: true`, and Mix does not resolve optional deps transitively, so a project that never declared igniter itself won't get it from PhoenixKit:

```elixir
# mix.exs
defp deps do
  [
    {:phoenix_kit, "~> 3.0"},
    {:igniter, "~> 0.7", only: [:dev, :test]}
  ]
end
```

```bash
mix deps.get
mix phoenix_kit.install
```

**Why optional?** A stock `mix phx.new` app declares `{:igniter, "~> 0.6", only: [:dev, :test]}`. A non-optional dep in PhoenixKit resolves for all environments and Mix refuses to converge the two (`the :only option for dependency igniter must include at least the environments of its parent`), which broke `mix igniter.install phoenix_kit` on every freshly generated project.

**Dev-only.** `only: [:dev, :test]` is deliberate — igniter is build-time tooling that never reaches production. Every reference to it in PhoenixKit is inside the `mix phoenix_kit.*` tasks and their installer helpers; nothing in the supervision tree or request path touches it, and Mix tasks aren't part of a release.

If `:igniter` is missing, `mix phoenix_kit.install` and `mix phoenix_kit.update` print setup instructions rather than running. Everything that doesn't patch code — `mix phoenix_kit.status`, `mix phoenix_kit.gen.migration`, `mix phoenix_kit.assets.rebuild` — is unaffected.

### Step 3: Configure

The installer adds this to your config. Customize as needed:

```elixir
# config/config.exs
config :phoenix_kit,
  parent_app_name: :my_app,
  parent_module: MyApp,
  url_prefix: "/phoenix_kit",
  repo: MyApp.Repo,
  mailer: MyApp.Mailer,
  layouts_module: MyApp.Layouts,
  phoenix_version_strategy: :modern
```

### Step 4: Add Routes

The installer adds something like this to your router.ex. Customize as needed:

```elixir
# lib/my_app_web/router.ex
import PhoenixKitWeb.Integration

scope "/" do
  pipe_through :browser
  phoenix_kit_routes()
end
```

### Step 5: Run Migrations

```bash
mix ecto.migrate
```

`mix phoenix_kit.status` shows what is installed and `mix phoenix_kit.doctor`
checks the setup (configuration, assets, hooks, Oban) and says what to fix.

---

## Configuration Reference

### Core Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `repo` | module | auto-detected | Your Ecto Repo module |
| `mailer` | module | nil | Your Swoosh Mailer module |
| `url_prefix` | string | "/phoenix_kit" | URL prefix for all routes |
| `admin_path` | string | "/admin" | Top-level segment of the admin area, inside `url_prefix` |
| `layout` | tuple | PhoenixKit default | `{LayoutModule, :template}` |
| `root_layout` | tuple | PhoenixKit default | Root layout for pages |

### Renaming the admin area

`url_prefix` names the mount; `admin_path` names the admin segment inside it.
They are independent:

```elixir
config :phoenix_kit,
  url_prefix: "/phoenix_kit",
  admin_path: "/backoffice"

# admin area now at /phoenix_kit/backoffice/users
# everything else is untouched: /phoenix_kit/users/log-in, /phoenix_kit/profile/settings
```

Useful when a signed-in end user would otherwise see a URL that reads as
somebody else's admin panel. The admin index admits **every** authenticated
visitor by design — one holding no permissions is greeted and shown nothing
else — so the URL is the only part that looks administrative.

- **Compile-time.** Put it in `config/config.exs`, never `runtime.exs`. The
  host router folds it into `__mix_recompile__?/0`, so changing it re-expands
  your router rather than leaving it serving the old segment.
- **Validated.** Exactly one lowercase path segment, and not one PhoenixKit
  already declares (`users`, `profile`, `dashboard`, `api`, …). A bad value
  raises at compile time instead of producing a router that 404s.
- **Nothing else changes.** The default (`"/admin"`) produces a byte-identical
  route table, and every PhoenixKit module package follows the rename with no
  changes of its own.

In **your own code**, keep writing `/admin` — `Routes.path("/admin/users")`
and `<.pk_link navigate="/admin/users">` apply the configured segment for you.
Never hardcode the renamed value.

### Authentication Settings

```elixir
config :phoenix_kit, :password_requirements,
  min_length: 8,
  max_length: 72,
  require_uppercase: false,
  require_lowercase: false,
  require_digit: false,
  require_special: false
```

### Rate Limiting

```elixir
# Hammer 7.x uses ETS backend via PhoenixKit.Users.RateLimiter.Backend
# No additional :hammer config needed

config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  login_limit: 5,                      # Max login attempts per window
  login_window_ms: 60_000,             # 1 minute window
  magic_link_limit: 3,                 # Max magic link requests per window
  magic_link_window_ms: 300_000,       # 5 minute window
  password_reset_limit: 3,             # Max password reset requests per window
  password_reset_window_ms: 300_000,   # 5 minute window
  registration_limit: 3,               # Max registration attempts per window
  registration_window_ms: 3_600_000,   # 1 hour window
  registration_ip_limit: 10,           # Max registrations per IP per window
  registration_ip_window_ms: 3_600_000, # 1 hour window

  # Each endpoint that sends mail on an anonymous request also has a per-IP
  # limit and one cap for the whole site (nil switches a cap off):
  password_reset_ip_limit: 10,
  password_reset_global_limit: 300,    # per hour, whoever asks
  magic_link_global_limit: 300,
  confirmation_resend_global_limit: 300,
  registration_global_limit: 300       # public sign-up forms only
```

Every limit is counted in memory, per server. Settings → Authorization →
Abuse protection shows the limits in force and what each whole-site counter
holds right now. A whole-site cap refuses everyone once it is reached, so raise
it before a launch or a forced password reset sends a crowd to one form.

### Client IP behind a reverse proxy

Rate limits, API key `allowed_ips`, login history and session checks all key on
the client address from `PhoenixKit.Utils.IpAddress`. Behind a reverse proxy
the TCP peer is the proxy, so PhoenixKit reads `X-Forwarded-For` (the last
entry, the one your proxy appended) and then `X-Real-IP` — but only from a peer
it trusts, because anyone else can send those headers with any value.

```elixir
# Believe the headers only from these peers (CIDR blocks or bare addresses)
config :phoenix_kit, :trusted_proxies, ["172.18.0.7/32"]

# Believe them from nobody: the client is always the connection's peer
config :phoenix_kit, :trusted_proxies, []
```

One proxy hop is supported: the client is the last `X-Forwarded-For` entry, so a
chain such as CDN -> Caddy -> app reports the CDN. A value that is not a list of
CIDR text trusts nobody and logs one warning. In a list, an entry that does not
parse matches nothing, while the valid entries still trust their peers (one
warning names the bad ones). In Docker the proxy's address changes when its
container is recreated, so a fixed `/32` like the one above silently stops
matching and every client appears as the proxy. Pin the address (`ipv4_address`
in compose), resolve the proxy by hostname at boot in `config/runtime.exs`, or
trust the network's CIDR block instead. Trusting a whole Docker network makes
every container on it a trusted header source, so prefer a network that holds
only the proxy and the app.

`:trusted_proxies` decides the client address only. `X-Forwarded-Proto` (the
scheme used for URLs such as the API `base_url`) is still believed from any
loopback or private peer.

- **Not set (default, unchanged).** Any loopback or private peer is treated as a
  proxy. The first request that relies on this logs one warning per VM.
- **A list.** Headers are believed only when the peer is inside one of the
  blocks, public or private. A malformed entry matches nothing.
- **`[]`.** Nobody is trusted.

Set it in production to the address(es) your proxy connects from. The same rule
covers LiveView sockets (`client_address_from_socket/1`).

---

## Authentication Integration

### Access Current User

```elixir
# In a LiveView
def mount(_params, _session, socket) do
  user = socket.assigns[:phoenix_kit_current_user]
  scope = socket.assigns[:phoenix_kit_current_scope]
  {:ok, socket}
end

# In a Controller
def index(conn, _params) do
  user = conn.assigns[:phoenix_kit_current_user]
  scope = conn.assigns[:phoenix_kit_current_scope]
  render(conn, :index)
end
```

The **scope** (`PhoenixKit.Users.Auth.Scope`) is what access decisions read: it
carries the user together with the roles and permissions they act with in this
session. `Scope.authenticated?(scope)` says whether anyone is signed in.

### Require Authentication

```elixir
# In your router
import PhoenixKitWeb.Users.Auth

scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user]

  # The plug covers the first page load; the on_mount hook covers the LiveView
  # socket, which outlives it.
  live_session :signed_in,
    on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
    live "/account", AccountLive
  end
end
```

The other hooks: `:phoenix_kit_mount_current_scope` (assigns the scope, admits
everyone), `:phoenix_kit_ensure_admin`, `:phoenix_kit_ensure_owner`,
`:phoenix_kit_ensure_module_access` and
`:phoenix_kit_redirect_if_authenticated_scope` (for sign-in pages of your own).
The matching plugs are `require_admin/2`, `require_owner/2`,
`require_module_access/2` and `require_role/2`.

### Staying signed in ("remember me")

A visitor who ticked "remember me" carries a signed cookie that lives 60 days
(`PhoenixKitWeb.Users.Auth.remember_me_max_age/0`). `PhoenixKitWeb.Plugs.Integration`,
which the installer adds to your `:browser` pipeline, rebuilds the session from
it on every page whenever the session has no signed-in user, so your own pages
see the visitor as signed in too.

The session cookie itself is yours. A stock `mix phx.new` endpoint gives it no
`max_age`, so the browser treats it as a session cookie, and a phone drops it
whenever the OS stops the web app. The rebuild covers for that, but you can give
it the same lifetime:

```elixir
# lib/my_app_web/endpoint.ex
@session_options [
  store: :cookie,
  key: "_my_app_key",
  signing_salt: "...",
  same_site: "Lax",
  max_age: 60 * 60 * 24 * 60
]
```

### Check User Roles

```elixir
# Check if user has a role
PhoenixKit.Users.Roles.user_has_role?(user, "Admin")
PhoenixKit.Users.Roles.user_has_role?(user, "Owner")

# Get user's roles
roles = PhoenixKit.Users.Roles.get_user_roles(user)

# In a template, ask the scope (no database read) and link with pk_link,
# which applies the URL prefix and a renamed admin segment
<%= if Scope.can_access_admin_area?(@phoenix_kit_current_scope) do %>
  <.pk_link navigate="/admin">Admin Panel</.pk_link>
<% end %>
```

`Roles.*` reads a person's roles from the database. With the role switcher on
(a person holding several roles acts as one per session), an access decision
should read the scope instead: `Scope.has_role?(scope, "Admin")`,
`Scope.user_roles(scope)`.

### Check Module-Level Permissions

Permissions are an allowlist per role: a row means granted, no row means denied, and the Owner always has everything. Each admin section and each module has a key; a module can add dotted sub-permissions under its key.

```elixir
# In a LiveView, use the scope from assigns
scope = socket.assigns.phoenix_kit_current_scope

# Check single permission
Scope.has_module_access?(scope, "billing")        # true/false

# Check multiple permissions
Scope.has_any_module_access?(scope, ["billing", "shop"])  # any granted?
Scope.has_all_module_access?(scope, ["billing", "shop"])  # all granted?

# Check system role (Owner or Admin, not custom roles)
Scope.system_role?(scope)

# A sub-permission (a dotted key under a section or module)
Scope.can?(scope, "calendar.view_others")

# May this person see the admin area at all? (Owner, Admin, or any permission)
Scope.can_access_admin_area?(scope)

# Get all granted keys
Scope.accessible_modules(scope)  # MapSet of granted permission keys
```

**Route enforcement**: PhoenixKit's `phoenix_kit_ensure_admin` and `phoenix_kit_ensure_module_access` on_mount hooks automatically enforce permissions on admin routes. Sidebar navigation is gated per-user.

### Edit link on public pages

When an admin is viewing a public page — a host LiveView, or a module's own
public controller/LiveView — you can offer them a one-click "Edit" link into
that page's admin counterpart.

Declare the edit target from `handle_params`/`mount` (or a controller action)
with `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3`. Route the path
through `PhoenixKit.Utils.Routes.path/1` when it targets a PhoenixKit admin
page (as here), so it still resolves under a mount prefix, a locale segment,
or a renamed `admin_path` segment:

```elixir
def handle_params(%{"slug" => slug}, _uri, socket) do
  post = Blog.get_post_by_slug!(slug)

  socket =
    PhoenixKitWeb.AdminEditHelper.assign_admin_edit(
      socket,
      PhoenixKit.Utils.Routes.path("/admin/posts/#{post.id}/edit")
    )

  {:noreply, assign(socket, :post, post)}
end
```

The third argument accepts a plain string label (used as-is) or a keyword
list — `label:` (default: gettext "Edit") and `permission:` (a module
permission key, e.g. `"publishing"`, checked with
`Scope.has_module_access?/2`):

```elixir
PhoenixKitWeb.AdminEditHelper.assign_admin_edit(
  socket,
  PhoenixKit.Utils.Routes.path("/admin/publishing/posts/#{post.id}/edit"),
  label: "Edit Post",
  permission: "publishing"
)
```

The link is only assigned when the current scope can access the admin area
at all and — when `permission:` is given — holds that specific module's
access. Otherwise nothing is assigned, so the render side never sees a URL
it shouldn't.

Then drop the renderer into your public layout once:

```heex
<.admin_edit_link url={assigns[:admin_edit_url]} label={assigns[:admin_edit_label]} />
```

`PhoenixKitWeb.Components.Core.AdminEditLink.admin_edit_link/1` renders
nothing when there is no URL, so this line is safe to leave in every public
layout unconditionally. Pass `variant={:menu_item}` to render it as a
daisyUI `menu` `<li>` instead of a standalone button, for dropping into an
existing dropdown menu.

In the admin chrome you do not render anything yourself: a LiveView shown
through `PhoenixKitWeb.Layouts.admin` (every plugin view, and a host view that
opts in) gets the pair threaded in by the layout, and the account menu shows
the entry first. A view that calls `LayoutWrapper.app_layout/1` directly is
not covered — a function component cannot see its caller's assigns — so it
must pass the attrs itself:

```heex
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  admin_edit_url={assigns[:admin_edit_url]}
  admin_edit_label={assigns[:admin_edit_label]}
  ...
>
```

A host layout (`config :phoenix_kit, :layout`) receives the same pair as
top-level assigns. Only `assign_admin_edit/3` checks the module permission;
a value placed in `module_assigns` by hand skips that check, and the chrome
backs it up with the admin-area test alone.

### User Registration

```elixir
# Register a new user
{:ok, user} = PhoenixKit.Users.Auth.register_user(%{
  email: "user@example.com",
  password: "securepassword123"
})

# First user automatically becomes Owner
```

`register_user/3` takes the caller's IP as its second argument (for the
per-address and per-IP limits) and options as its third. A plain call like the
one above is right for a seed, an import or a test. A public form of your own
is a different case: see the next section.

---

## Protecting Sign-up and the Mail You Send

A public sign-up form lets anyone make your site send email to any address.
PhoenixKit's own forms are protected in four layers; all of them are shown on
Settings → Authorization → Abuse protection.

| Layer | What it does | Default |
|---|---|---|
| Request limits | Per address, per network and for the whole site (see [Rate Limiting](#rate-limiting)) | on |
| Email address check | Refuses a domain that cannot receive mail (a DNS lookup); offers "Did you mean …@gmail.com?" for common typos | on |
| Cloudflare Turnstile | A check that the visitor is a person, on the forms that send mail | off |
| Unconfirmed accounts | An account that never confirmed its address gets only the mail its holder asks for (confirmation, password reset, sign-in link): no notifications, digests or alerts | on, with `require_email_confirmation` |

**Turnstile** needs a site key and a secret key from the Cloudflare dashboard
(Turnstile → Add widget, with your domain), entered on that settings tab. It
also needs the current `phoenix_kit.js` (`mix phoenix_kit.update` copies it),
and a Content-Security-Policy, if you have one, must allow
`https://challenges.cloudflare.com` in `script-src` and `frame-src`. If
Cloudflare cannot be reached, the forms keep working on the limits alone.

### A public sign-up form of your own

The layers above are applied by PhoenixKit's forms, not by
`Auth.register_user/3` itself, so that seeds, imports and tests are never
refused. A form of your own opts in:

```heex
<.form for={@form} id="signup-form" phx-submit="save">
  ...
  <PhoenixKitWeb.Components.Core.TurnstileWidget.turnstile_widget id="signup-turnstile" />
  <button type="submit">Create account</button>
</.form>
```

```elixir
alias PhoenixKit.Utils.IpAddress
alias PhoenixKitWeb.Users.BotCheck

def mount(_params, _session, socket) do
  # Read during mount: the peer is only available then.
  {:ok, assign(socket, :ip_address, IpAddress.client_address_from_socket(socket))}
end

def handle_event("save", %{"user" => user_params} = params, socket) do
  ip = socket.assigns.ip_address

  # First, before anything is counted or looked up. Does nothing while
  # Turnstile is off.
  case BotCheck.run(socket, params, ip) do
    {:ok, socket} ->
      PhoenixKit.Users.Auth.register_user(user_params, ip,
        site_wide: true,          # count against the whole-site sign-up cap
        check_email_domain: true  # refuse a domain that cannot receive mail
      )
      # ...

    {:error, socket} ->
      {:noreply, socket}
  end
end
```

For the address to be available, the socket in your endpoint must expose the
peer: `socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info:
[:peer_data, :x_headers, session: @session_options]]`.

`PhoenixKit.Users.EmailDomain.suggestion/1` returns the corrected address for
a likely typo (or `nil`); it reads no DNS, so it is safe to call as the person
types.

### Mail of your own to PhoenixKit users

Before sending anything a person did not just ask for (a reminder, a digest,
an announcement), ask `PhoenixKit.Users.Auth.unsolicited_mail_allowed?(user)`.
It is false for an account whose address nobody has confirmed: that address
may be a typo or made up, and mail to it is a bounce or a complaint against
your sending domain. Address the mail with
`PhoenixKit.Users.Auth.User.delivery_email(user)`, not `user.email`.

---

## Updating

```bash
mix deps.update phoenix_kit
mix phoenix_kit.update
```

`mix phoenix_kit.update` writes and applies the migration that brings the
schema to the installed version, runs the migrations of the installed
companion packages, repairs the configuration PhoenixKit depends on (Oban
queues and cron entries, the endpoint plugs, the test helpers) and rebuilds
the assets, which is how the current `phoenix_kit.js` reaches your app. Run it
after every PhoenixKit update, also for a patch release: some features need
the new JavaScript. It may ask to be run a second time when it had to add
configuration first.

Coming from 2.x: [Upgrading to PhoenixKit 3.0](upgrading-to-3.0.md).

---

## Testing Your App

PhoenixKit ships test helpers in `PhoenixKit.Test.Fixtures`. Use them instead of
signing users in by hand. A hand-rolled login that sets `:user_token` but not
`:live_socket_id` looks fine and quietly stops LiveView from disconnecting on
logout.

`mix phoenix_kit.install` and `mix phoenix_kit.update` add the import to
`test/support/conn_case.ex` when they can do so safely. They leave the file
alone if your tests already define a function with one of the same names. To
add it by hand, put it inside the `quote` block:

```elixir
# test/support/conn_case.ex
using do
  quote do
    # ...
    import Phoenix.ConnTest
    import PhoenixKit.Test.Fixtures
  end
end
```

Then:

```elixir
setup :register_and_log_in_user

test "the dashboard renders", %{conn: conn, user: user} do
  assert conn |> get(~p"/dashboard") |> html_response(200) =~ user.email
end
```

| Helper | Gives you |
|---|---|
| `register_and_log_in_user/1` | A confirmed user, signed into `conn`. Use it as a `setup` step. Adds `:user` to the context. |
| `log_in_user/2` | Signs an existing user into a conn. |
| `user_fixture/1` | A registered, **unconfirmed** user. |
| `confirmed_user_fixture/1` | The same, but confirmed. |
| `admin_fixture/1` | A user with the Admin role. |
| `scope_for/1` | A real `%Scope{}` for code that takes a scope directly. |

Sandbox ownership stays in your `ConnCase` and `DataCase`. The fixtures only
call `Auth.register_user/1` and put keys into the session.

Two things to know when a test goes through PhoenixKit's own sign-up form:

```elixir
# config/test.exs
# No DNS lookups in tests. `@example.com`, the usual test address, really does
# publish "this domain takes no mail", so the email address check refuses it.
config :phoenix_kit, :email_domain_check, false
```

And a test that expects an alert or a notification email needs a
**confirmed** user (`confirmed_user_fixture/1`): an unconfirmed account gets
none.

---

## Troubleshooting

### "Repo not configured"

```elixir
# Ensure config is set
config :phoenix_kit, repo: MyApp.Repo
```

### "Routes not found"

```elixir
# Ensure you imported and called the macro
import PhoenixKitWeb.Integration
phoenix_kit_routes()
```

### "Mailer not sending emails"

```elixir
# Check your mailer is configured
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  # ... your SMTP settings

# And PhoenixKit knows about it
config :phoenix_kit, mailer: MyApp.Mailer
```

### "Rate limiting not working"

PhoenixKit uses Hammer 7.x with ETS backend via `PhoenixKit.Users.RateLimiter.Backend`. No additional Hammer configuration is required. If you need to adjust rate limits:

```elixir
config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  login_limit: 5,
  login_window_ms: 60_000
```

### "This email domain cannot receive mail" in a test or on a dev machine

The sign-up form asks DNS whether the address's domain can receive mail. Test
addresses at `example.com` are refused, correctly. Switch the check off for
the test environment (`config :phoenix_kit, :email_domain_check, false`), or
for one site on Settings → Authorization → Abuse protection.

### A user gets no notification or alert emails

Their address is not confirmed. Such an account gets only the confirmation
mail, a password reset and a sign-in link until it confirms. The in-app inbox
still shows everything.

### `mix phoenix_kit.install` / `mix phoenix_kit.update` needs `:igniter`

Both tasks patch your code, so both require igniter — which PhoenixKit declares
`optional: true` and therefore does **not** hand down transitively. If it's
missing, the task prints setup instructions instead of running. Add it and
re-run:

```elixir
{:igniter, "~> 0.7", only: [:dev, :test]}
```

`mix deps.get` is enough — PhoenixKit tracks whether igniter was available when
it last compiled and recompiles itself when that changes, so the tasks appear
without a manual `mix deps.compile phoenix_kit --force`.

This bites most often on upgrade: a project that never declared igniter was
getting it transitively from an older PhoenixKit, and the switch to `optional:
true` drops it.

### `mix igniter.install` crashes with `Igniter.CopiedTasks is not available`

Not a PhoenixKit failure. When your `mix.exs` has no `{:igniter, ...}` line, the
`igniter_new` archive temporarily injects one, shells out to `mix deps.get`,
then removes it on exit. If that `deps.get` fails, the archive's cleanup handler
crashes on top of the original error because igniter was never loaded — burying
the real message. Read the `mix deps.get failed with exit code ...` output above
that stack trace, and check `mix.exs` for a stray `{:igniter, "~> 0.6", only:
[:dev, :test]}` line the crashed cleanup left behind.

Declaring igniter permanently (see above) avoids the inject/cleanup dance
entirely — `igniter_new` skips it when the dep is already present.

---

## Further Reading

- **[Custom Admin Pages](custom-admin-pages.md)** - Add pages to the admin sidebar
- **[Your App as a Module](your-app-as-a-module.md)** - Account-deletion cleanup, notification types, Oban crons and more, from your own app
- **[Locale Routing](locale-routing.md)** - The language lives in the URL
- **[OAuth & Magic Link Setup](oauth-and-magic-link-setup.md)** - Google, GitHub, Facebook and sign-in links
- **[AWS Email Setup](aws-email-setup.md)** and **[Customizing Emails](email-templates.md)**
- **[Making Pages Live](making-pages-live.md)** - Real-time updates
- **[Admin navigation and tabs](https://github.com/BeamLabEU/phoenix_kit/blob/main/lib/phoenix_kit/dashboard/ADMIN_README.md)** and **[dashboard components](https://github.com/BeamLabEU/phoenix_kit/blob/main/lib/phoenix_kit/dashboard/README.md)**
- **The machine API** (REST, MCP, keys): Settings → API → the guide, in your own admin once the API is switched on

---

## For AI Assistants

When helping a developer with PhoenixKit:

1. **PhoenixKit is a Hex dependency** - Code lives in `deps/phoenix_kit/`
2. **Don't modify PhoenixKit files** - Create code in the user's app that calls PhoenixKit APIs
3. **The assigns are prefixed** - `phoenix_kit_current_user` and `phoenix_kit_current_scope`, not `current_user`
4. **Access decisions read the scope** - `Scope.has_module_access?/2`, `Scope.can?/2`, `Scope.has_role?/2`; not raw database queries. Permissions are cached in it
5. **First user is Owner** - The first registered user gets the Owner role automatically, and the Owner passes every permission check with no rows needed
6. **Routes are prefixed** - Default is `/phoenix_kit/`, configurable via `url_prefix`; the admin segment is separately configurable via `admin_path`. Write `/admin` in code either way and let `Routes.path/1` or `<.pk_link>` apply both
7. **Primary keys are UUIDs** - Every PhoenixKit record is identified by `uuid` (UUIDv7), never an integer `id`; foreign keys end in `_uuid` (`created_by_uuid`, not `created_by`)
8. **A public sign-up form opts in to protection** - `BotCheck.run/3` first, then `Auth.register_user(attrs, ip, site_wide: true, check_email_domain: true)`; a plain `register_user/1` is for seeds and tests
9. **No automated mail to an unconfirmed address** - check `Auth.unsolicited_mail_allowed?/1` before sending anything the person did not just ask for
10. **Run `mix phoenix_kit.update` after updating the dependency** - it migrates the schema and copies the current JavaScript
11. **Entity names and field keys are snake_case** (`phoenix_kit_entities`) - `"contact_form"` and `"full_name"`, not `"Contact Form"`

---

**Last Updated**: 2026-11-14
