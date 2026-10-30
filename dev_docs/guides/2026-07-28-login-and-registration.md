# Login & Registration

Full reference for the auth surface: session persistence policy, post-auth
destinations, the email-confirmation toggle, and the traps each one hides.
Authentication policy settings live on the admin **Users settings** page (`/admin/settings/users`).

## Country and date formats

`User.country` is an optional ISO 3166-1 alpha-2 code, stored uppercase and validated
against `BeamLabCountries`. The profile and admin user forms edit it; it is separate
from the GeoIP `registration_country` and from any custom field named `country`.
New registrations start with a recognized registration country, while V221 leaves
existing profiles untouched.

`PhoenixKit.Users.FormatCountry.resolve/1` chooses the user's country, then their
organization account's country, then their registration country, then General
Settings → **Default Country for Formats** (`format_country`). Unknown codes are
skipped. With none set, date helpers keep the site's `date_format`.

The auth plugs, LiveView mount hooks and embedded identity helper set the viewer.
The country is resolved on first use; scope refreshes and profile saves reset it.
The site-default fallback follows the settings cache, including in an open LiveView.
Date helpers given a user format for that user; helpers without one format for the
current viewer. Time formats and date input parsing still follow the site settings.

## Session persistence

One site-wide policy, two settings, and a visible per-user choice.

| Setting | Default | Effect |
|---|---|---|
| `remember_me_enabled` | `true` | Master switch. Off hides the checkbox on every auth form **and** hard-blocks the cookie inside `maybe_write_remember_me_cookie/3`. |
| `remember_me_default` | `true` | Whether that checkbox starts **checked**. Users untick it for a session-only login. |

Enforcement lives at the cookie writer, not at the call sites, so the policy
holds by construction: with `remember_me_enabled` off, no caller — nor a forged
`remember_me` param — can leave a persistent cookie.

Every flow with a UI (password login, registration, magic-link completion, QR
handoff) renders the same pre-checked "Keep me logged in" box. Flows with
nothing to tick — **magic-link login** (arrives from an email) and **OAuth**
(external round-trip) — call `Auth.remember_me_params/0` and follow
`remember_me_default`.

Read the policy through `Auth.remember_me_enabled?/0` /
`Auth.remember_me_default?/0`. Never hardcode `%{"remember_me" => "true"}` at a
call site — magic-link and OAuth both used to, which is how they drifted from
the rest.

**Why it defaults on.** Registration used to force a session-only login: the
session rode the plain browser-session cookie, which mobile browsers drop when
they evict the tab, so users who registered on a phone were silently logged out
overnight. Their 60-day session token was valid the whole time — nothing
referenced it.

The two registration LiveViews track the checkbox across `phx-change="validate"`
re-renders (`assign(:remember_me, user_params["remember_me"] == "true")`).
Without that the box would snap back to the site default on the next keystroke,
and the value the user sees would disagree with what `phx-trigger-action` POSTs.

> ⚠️ In the settings UI, do **not** mark a `<.checkbox>` `disabled` to express
> "this doesn't apply right now". The component pairs the box with an
> **un-disabled** hidden `value="false"` input, so a disabled box still submits
> `false` and silently rewrites the stored setting on save.

## What the signup page may create

Two settings, and the second only exists while the first is on.

| Setting | Default | Effect |
|---|---|---|
| `enable_organization_accounts` | `false` | Master switch for organization accounts — the columns, tabs and pickers throughout the admin area. |
| `registration_account_type` | `"choice"` | What the **public** signup forms may create: `"choice"`, `"person"` or `"organization"`. |

Read both through `Auth.registration_account_type/0`, which collapses them into
one answer — it returns `"person"` whenever organization accounts are off, so no
caller has to ask two questions:

| Mode | Signup page | Shape it serves |
|---|---|---|
| `"choice"` | Personal / Organization picker | Mixed consumer + business. The shipped default, and what an install that never touched the setting keeps. |
| `"person"` | no picker, always a person | Organizations exist, but only an admin creates them. |
| `"organization"` | no picker, Organization Name **required** | B2B: there is no personal account to open, and staff join by invitation. |

An organization account **is a user row** (`account_type: "organization"`, an
`organization_name`, no first/last name); staff are person rows carrying its
`organization_uuid`. So in `"organization"` mode the company registers itself
and then invites its people — nothing on the public form ever produces a
personal account.

> ⚠️ **The hidden `<select>` is not the control.** `registration_changeset/3`
> casts `account_type` and `organization_name` straight from the payload, and a
> `phx-submit` payload is whatever the client sends. Enforcement is
> `Auth.enforce_registration_account_type/2`, applied inside each form's
> `form_params/2` allowlist — the same arrangement as
> `maybe_write_remember_me_cookie/3`. Before it existed, a forged
> `user[account_type]=organization` created an organization account on a site
> with organization accounts switched off entirely.

`"choice"` mode normalises anything that is not `"organization"` to
`"person"` rather than passing it through: the registration changeset has no
`validate_inclusion` of its own, so an unknown string would otherwise reach the
insert and come back as a CHECK-constraint 500 instead of a validation error.

**Both registration forms honour it.** The magic-link completion form has no
picker at all, so it renders the Organization Name field exactly when the mode
is `"organization"` (and drops the first/last-name fields there — an
organization has neither).

**An organization invitation overrides the mode**, pinning the visitor to
`"person"`. Letting an invitee pick "Organization" would create a *second*
organization, and an organization account cannot hold an `organization_uuid`
(`validate_organization_fields/1` nils it), so the invitation could never be
redeemed afterwards.

A LiveView test that submits the signup form needs
`start_supervised!(PhoenixKit.Admin.SimplePresence)` — a **connected** mount
tracks the anonymous visitor, and the suite does not start what a host app
supervises.

## Post-auth destination

One resolver — `Routes.post_auth_path/1` — takes candidate destinations in
priority order, returns the first that passes `local_path?/1`, and falls back to
the `after_login_path` setting, then to `/admin`.

Precedence everywhere:

```
explicit return_to  >  after_registration_path  >  after_login_path  >  /admin
   (?return_to= param, or the         (registration only;
    :user_return_to a gate stashed)    empty = fall through)
```

The tail used to be a bare `"/"` — the host's home page, a route core cannot
declare and many hosts never route, so it 404'd. It is now `/admin`, which core
declares unconditionally and which admits every authenticated visitor (one
holding no rights is greeted and shown nothing else). With a `:context` the
resolver still prefers a better destination and only falls through to the
landing when nothing else resolves; see `Routes.safe_destination/2`.

`log_in_user/3` honors a `"return_to"` in its params map as well as the session
key — the OAuth callback had always passed one there and it was silently
dropped, so an OAuth login started from a protected page landed on the default.

Both settings are validated as local paths on save **and** re-guarded at read
time, so a hand-edited database row cannot turn a post-auth redirect into an
open redirect.

### Loop and lockout guards

`after_login_path` / `after_registration_path` are additionally refused when
they point at a page that *bounces an authenticated visitor* — every auth page
plus **`/users/log-out`**, which is a real GET route: set it and every
successful login signs the user straight back out, locking out the admin who
set it. `Routes.auth_page?/1` is the single predicate (over one `@auth_paths`
list covering log-in, log-out, register, confirm, magic-link, qr-login and
reset-password) and is applied at all three points: `Setting.SettingsForm` on
save, `Routes.after_login_path/0` and `Session.maybe_store_after_registration_path/1`
on read (`update_setting/2` bypasses the changeset), and
`Routes.post_auth_path/1` on each **candidate** — `?return_to=` is the least
trusted input of the three, and `?return_to=/users/log-out` planted in any auth
link would otherwise sign the user out the instant they signed in.

> ⚠️ **`Routes.local_path?/1` is the only redirect guard in the codebase.** It
> rejects `//`, `/\`, and **ASCII control characters**. The control-character
> rule is load-bearing: browsers strip tab/CR/LF while parsing a URL, so
> `"/\t/evil.example"` reaches `window.location` as `//evil.example` — a
> cross-origin navigation. `Phoenix.Controller.redirect/2` blocks those itself,
> but LiveView's `validate_local_url!` only rejects `\\` and a leading `//`, so
> **any** LiveView `redirect(to: ...)` of user-influenced input must go through
> `local_path?/1`.

### Carrying `return_to` between auth pages

Every route that can start a login threads the pending destination:
`Routes.return_to_query/1` appends it to the links between login, register,
magic-link, QR and the OAuth buttons, the magic-link *email* carries it in its
URL (re-sanitized by `MagicLinkVerify` before it reaches the session), and
`log_in_user/3` honors a `"return_to"` param as well as the session key. Adding
a new sign-in entry point means threading it there too, or the destination dies
the moment a user switches method.

## Email confirmation

`require_email_confirmation` (default `"true"`, the historical behavior) gates
**enforcement only** — confirmation emails always send.

All **six** enforcement sites honor it. Add the check to any new gate:

- conn plugs: `require_authenticated_user/2`, `require_authenticated_scope/2`
- `on_mount` hooks: `ensure_authenticated`, `ensure_authenticated_scope`,
  `ensure_owner`, `ensure_admin`, `ensure_module_access`

### The parked `/users/confirm` page

It moves users along instead of stranding them. Gates stash where the user was
headed as `?return_to=` (via `confirm_path_with_return_to/1`, mirroring the
login gate), and `ConfirmationInstructions` advances:

1. **On mount**, when the user is already confirmed — covers a `confirmed_at`
   flipped directly in the database followed by a refresh, since the user is
   reloaded from the session token on every mount.
2. **Live**, on the existing admin `{:user_confirmed, user}` broadcast, so
   clicking the emailed link in another tab advances the parked tab with no
   refresh.

It subscribes **before** re-reading the user, so a confirmation committed
between the on_mount load and the subscribe cannot be missed. The email-link
LiveView (`Users.Confirmation`) resolves the same destination, so the two tabs
can never diverge.

## Enumeration and abuse surfaces

Public auth endpoints must answer identically whether or not an account exists,
which means **rate-limiting before the lookup, not inside the send**:

- **Password reset** limited inside `deliver_*`, i.e. only for addresses that
  resolved to a user. Past the threshold a registered address got "Too many
  password reset requests" while an unknown one still got the generic notice —
  N+1 requests turned the deliberately vague copy into a precise oracle.
  ⚠️ The limiter inside `deliver_user_reset_password_instructions/3` **stays**
  for callers with none of their own (the admin "send reset link" action in
  `user_form.ex`), so the forgot-password LiveView passes `rate_limit: false`.
  Both checks hit the same per-email bucket: charging it twice spent two of the
  three allowed hits per submission, so a real user's *second* reset request in
  a window silently sent nothing while the page still showed the success notice.
  Any new pre-lookup limiter must opt the inner one out the same way.
- **Confirmation resend** had no limit at all: every request for an existing
  unconfirmed account inserted a token and sent mail synchronously, so it was
  both an unauthenticated targeted-mail-flood vector and a timing oracle.
  `RateLimiter.check_confirmation_resend_rate_limit/1` now runs first.
- **Magic-link registration request** answered "This email is already
  registered", which login and magic-link login never do. It returns the same
  generic confirmation as a success now.

## Soft-failure paths need `rescue` AND `catch :exit`

An unreachable database surfaces two different ways:

| Condition | Manifests as |
|---|---|
| Checkout with no owner for this process | **raises** `DBConnection.OwnershipError` |
| Dead pool, or an owner that died mid-flight | **exits** |

`Settings.get_setting_cached/2` and the boot-safe URL wrappers
(`Routes.get_default_language_base/0`, `Languages.prefixless_primary_safe?/0`)
carried `rescue` only, so they leaked exits; `Settings.get_setting/1` had
neither, so a transient database problem crashed every caller — the login
redirect resolver among them. All now carry both clauses and log-then-default.

Because settings reads are ETS-cached, the pool is only touched on a cache
**miss**, so this presented as suite *flakiness* rather than a hard failure:
DB-less unit tests (`routes_test`, `language_refactor_test`, `tab_item_test`)
passed on a warm cache and died whenever another test's settings write had
evicted the key.

`test/integration/settings_unreachable_db_test.exs` pins the behavior. Two rules
that file follows, both learned the hard way:

1. **Reproducing "no database" needs `async: true` AND
   `Process.delete(:"$callers")`** in the spawned process. Shared sandbox mode
   (any `async: false` test) hands a connection to every process, and Ecto
   deliberately lets a `Task` borrow its caller's connection through `$callers`.
   Miss either and every assertion passes vacuously against a healthy database —
   which is why the file leads with a guard test.
2. **Never evict a real settings key in a test.** The ETS cache is global, so an
   `async: true` test that evicts `languages_enabled` (or any shared key) forces
   every concurrently-running test to hit the database at once. That surfaced as
   unrelated permission-test failures and a Postgres `40P01 deadlock_detected`.
   Read a unique probe key instead — one present in neither cache nor database
   misses inherently, with no eviction and no blast radius.

## Flash ownership

The flash group belongs **inside** the LiveView tree: LayoutWrapper's per-branch
`<.flash_group>`, the dashboard layout, or the host's own layout.
`root.html.heex` deliberately has none — a copy there rendered every message
twice with duplicate `flash-<kind>` element ids (which breaks LiveView DOM
patching) and froze at its dead-render value, since the root layout does not
re-render on connected updates. Don't add one back.

## Testing notes

Rate limiting keys on the peer from `Plug.Conn.get_peer_data/1`, **not**
`conn.remote_ip` — and the test adapter reports the same peer for every conn,
so a file that logs in repeatedly exhausts one shared bucket (15/min) and later
tests get bounced to the login page under some seed orderings. Hammer 7 removed
bucket deletion, so isolate rather than reset: give each test its own peer (see
`with_peer/2` in `auth_flows_test.exs`).

Related: LayoutWrapper's standalone fallback (no `config :phoenix_kit, layout:`)
renders content only. It previously nested a second full `Layouts.root` document
inside the LiveView and passed `app_layout`'s `attr :inner_content, default: nil`
into a template rendering `{@inner_content}` — so standalone auth pages rendered
chrome with an entirely empty body.

### Acting for a managed organization

Administrators create a managed organization from Users → New user → Create
managed organization, with a required first manager. A manager enters it from
the account menu; this creates a grant-bound session in a separate cookie slot,
independent of the ordinary multi-account setting. Back to my account revokes
that session; Log out signs out the whole browser stack.

While acting, Profile Settings → Managers supports contact-address editing,
manager invitations and removal. This tab cannot be hidden. Administrators can
also search/add people, convert an organization in either direction, and
explicitly leave it without an active manager from its details controls. Person
deactivation/deletion on the admin details page has the same explicit override.
The independent-login conversion requires a new email/password and sends a new
confirmation message; no former credentials or grants return.

Manager invitations always reach the invitee by mail: existing accounts get a
sign-in link; new accounts get a registration link. The inviter sees the same
response for either address. Accepting adds a manager grant and does not change
`organization_uuid` (employment). Kit pages display kind-aware banners from the
invitation hook; acceptance after registration/confirmation uses the same
locked path, and the organization switcher refreshes after accepting a banner.
