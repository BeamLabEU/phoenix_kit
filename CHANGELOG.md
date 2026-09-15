## Unreleased

### Added

- **`mix precommit` now compiles the test tree** via a new `test.compile`
  alias, run between `deps.unlock --check-unused` and `quality.ci`. No
  existing gate step ever *compiled* `test/**/*_test.exs`: `format` and
  `credo` only parse them, `compile` and `dialyzer` see `elixirc_paths`
  (which covers `test/support`, not the `.exs` test files), and ExUnit is
  the only thing that compiles those — so a test file that is valid syntax
  but fails to compile (a duplicate `describe` name, for example, which
  ExUnit rejects at `defmodule` time) passed every step and only surfaced on
  the next `mix test`. The alias compiles every test file with
  `Kernel.ParallelCompiler.compile/1` in a `MIX_ENV=test` subprocess,
  deliberately without `test_helper.exs`: no `ExUnit.start`, no database
  probe, no migration, zero tests run, so it cannot go red from the
  environment — only from a genuine compile error in `test/`. `mix test`
  itself is still not part of `precommit`; see AGENTS.md "CI/CD".
- Media reorganizer: `PhoenixKit.Modules.Storage.Reorganizer`, `Source`
  contract, `media_reorganizer/0` module callback,
  `mix phoenix_kit.media.reorganize`. `apply_one/1` is isolated against a
  raise/throw/exit anywhere in the apply path (including `after_move`),
  and `plan/2` isolates each `Source` and each of its actions the same way,
  so one bad source or action never takes the rest of the run down. A
  collision is checked with a SELECT before the write rather than retried
  after a failed `UPDATE`, since a real unique-constraint violation poisons
  the surrounding Postgres transaction and a retry inside it is unusable.

## 2.23.2 - 2026-09-15

### Added

- **Hosts can choose the folder core's own uploads land in** (#813).
  `config :phoenix_kit, :uploads_parent_folder, {Mod, :fun}` is called as
  `fun(kind, actor_uuid, subject)` (or `fun(kind, actor_uuid)`) with `kind`
  `:avatar` or `:branding` and returns `{:ok, folder_uuid}` or `nil` for the
  storage root (the default). `Auth.update_user_avatar/4` places the stored
  avatar there; the user form's avatar picker and the logo / site-icon /
  auth-background pickers on `/admin/settings` and
  `/admin/settings/authorization` pass the answer to `MediaSelectorModal` as
  `scope_folder_id`. Note that `scope_folder_id` also scopes browsing, so once
  the hook is configured those pickers list only files under the returned
  folder. An answer that is not a live folder (not a UUID, no such folder, or
  trashed), or a hook that raises or exits, falls back to the root.
- **The standalone media selector accepts `?scope_folder=<uuid>`** (#813) and
  attaches uploads made from it to that folder; a malformed, missing or
  trashed folder is ignored. `MediaSelectorHelper.media_selector_url/2` takes
  a matching `:scope_folder` option.
- **Annotation-comment attachments can be placed by the host** (#813) through
  `config :phoenix_kit_comments, :attachments_parent_folder`, called with
  `:annotation_attachment` and `%{resource_type: "file", resource_uuid: uuid}`.
- **Storage moduledoc: folder conventions for module packages** (#813) — the
  parent-folder and folder-name hooks, the lookup order for an object's
  folder, and leaving re-parenting to the host.

### Fixed

- The upload placement hook is consulted when a picker opens, not in
  `mount/3`, so viewing a settings page or the user form no longer runs a
  host hook (which may create a folder) twice per load.
- A hook answering a folder that no longer exists no longer crashes
  `Auth.update_user_avatar/4` after the file was stored, nor the picker's
  upload.
- The standalone media selector logs a failed scope-folder attach instead of
  discarding it.

## 2.23.1 - 2026-09-13

### Changed

- **A module whose database schema is newer than its code is now reported
  as "ahead of code", not "up to date"** (#806).
  `PhoenixKit.Migrations.Modules.classify/2` returns a new `:ahead_of_code`
  status for `installed > target` (a rollback, or a dependency pinned
  backwards), with a matching `Modules.ahead_of_code/1` filter.
  `mix phoenix_kit.status` shows it in red with a new
  `{:modules_ahead_of_code, names}` next action; `mix phoenix_kit.doctor`
  warns; `mix phoenix_kit.update` names it instead of printing "up to date".
  When another module is genuinely behind, `update` is still the next action
  and the ahead module is listed as an extra reason. Note:
  `mix phoenix_kit.status --exit-code` exits non-zero for this state, as it
  does for every non-Ready action, so a deploy gated on it fails after a
  code rollback past a module migration.
- **Apple Sign-In and billing-provider secrets are encrypted at rest**
  (#807). `oauth_apple_private_key`, `billing_stripe_secret_key`,
  `billing_stripe_webhook_secret`, `billing_stripe_api_key`,
  `billing_paypal_client_secret`, `billing_paypal_webhook_secret`,
  `billing_razorpay_key_secret`, `billing_razorpay_webhook_secret` and
  `billing_everypay_api_secret` join `restricted_setting_keys/0`, so writes
  through `Settings.update_setting/2` store `enc:v1:` ciphertext and
  `Settings.get_setting/2` decrypts. phoenix_kit_billing reads every one of
  them through `get_setting/2` and needs no change. Existing plaintext values
  keep reading correctly and are encrypted on the next save or
  `mix phoenix_kit.integrations.rotate_key`. The public identifiers (Stripe
  publishable key, PayPal client/webhook ID, Razorpay key ID, EveryPay
  username/account) stay unencrypted. A new test-support perimeter scan
  asserts that every secret-shaped setting key core references or seeds is
  restricted.

### Fixed

- **Settings batch reads now actually fill cache misses from the database**
  (#810). `Settings.get_settings_cached/2` and `get_json_settings_cached/2`
  looked for a missing key in `Cache.get_multiple/3`'s result, but that
  function returns every requested key and substitutes the default on a
  miss, so a miss was never detected. A cold or expired cache read as `nil`
  for every key without querying the database. This affected every
  `get_settings_cached/2` caller, including phoenix_kit_web_analytics and
  phoenix_kit_publishing. Misses are now detected with a sentinel. A
  restricted key that fails to decrypt is answered but not cached, so the
  next read retries, matching the boot warmer. A JSON read of a row with no
  JSON value now caches `nil` instead of "not found".
- **Activity feed order is stable when timestamps tie** (#809).
  `Activity.list/1` and `Activity.recent/1` sorted by `inserted_at` alone,
  so rows with the same timestamp (every pre-V185 whole-second row) could
  come back in any order. They now add `uuid` as a tiebreak.
- **A blocked role-permissions click shows a translated reason** (#805). The
  Roles page flashed the raw error atom (`owner_immutable`). The message
  mapping moved from `PermissionsMatrix` to
  `Permissions.edit_role_permissions_error_message/1`, and both pages use it.
- **The OAuth "Test Credentials" button now actually tests the credentials.**
  It compared each field to `""` and nothing else, so a 9-character Google
  client secret — or a field containing only a space — read as "properly
  formatted" while Google itself answered the same values with 401
  `invalid_client`. For Google, the button now POSTs the current client
  ID/secret to `oauth2.googleapis.com/token` with a deliberately invalid
  authorization code and reads Google's own verdict: `invalid_client` means
  the credentials are wrong; `invalid_grant` means they are right (only the
  fake code was rejected, as expected) — this "right credentials" leg
  follows from Google's documented error definitions and was not itself
  exercised against a real registered app, and falls back to inconclusive
  if Google ever answers a correct pair with anything else. No
  `redirect_uri` is sent — this used to send an RFC 2606 `.invalid`
  placeholder, which fails Google's "Host TLDs must belong to the public
  suffix list" redirect-URI rule and came back `invalid_request` regardless
  of the credentials, making the check permanently inconclusive; a
  placeholder on a real public-suffix host was not affected (verified
  live with fabricated credentials: `example.com`/`localhost` and no
  `redirect_uri` all answered the same `invalid_client`). A third outcome
  — could not reach Google, or a response that isn't cleanly one of the two
  verdicts above — is reported as inconclusive (a distinct `:inconclusive`
  result, shown as a warning rather than an error flash), never folded into
  either a pass or a fail. GitHub and Facebook keep the previous
  format-only check (now actually enforcing it — see below) rather than an
  unverified live check against their token endpoints.
- **A short or blank-looking OAuth secret is now rejected on save**, not just
  by the button. `PhoenixKit.Users.OAuthConfig.validate_secret_format/2`
  rejects a value that is only whitespace or implausibly short (under 16
  characters — real secrets from all three providers are at least 24) before
  `PhoenixKitWeb.Live.Settings.Authorization` persists it; the generic
  settings schema (`PhoenixKit.Settings.Setting`) is deliberately left alone,
  since a Google-secret-shaped format check does not belong in a schema
  shared by every setting in the app. A secret already saved before this fix
  does not retroactively block saving an unrelated field. A secret with
  leading/trailing whitespace (a copy-paste artifact) is now trimmed before
  it is persisted or tested, instead of being saved and sent to the
  provider padded.
- **OAuth test-result messages are now translated.** The success message was
  never wrapped in `gettext` — a translated button produced an English
  response, and the wording ("...properly formatted. Initiate OAuth flow to
  test actual connection.") was easy to mistake for "this works" at a glance.
  All three providers' messages, on all three (now honest) outcomes, are
  gettext-wrapped, along with the adjacent "Reload Config" flash and the
  "Test Credentials" button name repeated in the on-page setup instructions.
- **Post-merge review fixes (#808, #807).** The nine new OAuth msgids had
  never been extracted, so every locale still rendered them in English. They
  are now extracted and translated into de/es/et/fr/it/pl/ru. The Google
  credential check no longer logs an exit/throw reason verbatim (a
  `GenServer.call` exit reason embeds the call's arguments), matching the
  `rescue` branch's rule. The secret-key perimeter test no longer runs under
  `DataCase`, which had silently excluded it on database-less runs.

## 2.23.0 - 2026-09-13

### Added

- **Active role: users act as one role at a time, per session** (opt-in,
  `role_switcher_enabled`, default off). A user holding two or more switchable
  roles acts as exactly one of them, and `Scope.for_user/1` narrows
  `cached_roles` and `cached_permissions` to that role plus the always-on roles
  — an Admin acting as "Seller" has no admin access until they switch back.
  Owner and Admin are always switchable; User is always on; custom roles are
  switchable unless listed in `role_switcher_always_on_roles`. The choice is
  stored **on the session token** (`phoenix_kit_users_tokens.active_role_uuid`,
  V190): Admin on one machine and Seller on another at the same time, a role
  of its own for an impersonation session, a fresh start for every sign-in and
  every added multi-session account. It reaches `for_user/1` through
  `%User{active_role_uuid: _}`, a virtual field only the session-token loader
  fills, so every scope rebuild — plugs, LiveView mounts, the role-change
  refresh (now reloading through the session token), sibling packages —
  narrows without changes. A stored role the user no longer holds is ignored.
  New: `PhoenixKit.Users.ActiveRole`, `Scope.active_role/1`,
  `Scope.held_roles/1`, `Scope.narrowed?/1`, `Scope.switchable_roles/1`,
  `Scope.for_user(user, narrow: false)`, `Roles.get_user_role_records/1`,
  `Roles.get_role_records_for_users/1`, `Permissions.get_permissions_for_roles/1`;
  settings `role_switcher_enabled`, `role_switcher_location`,
  `role_switcher_always_on_roles`. Design and review record:
  `dev_docs/plans/2026-09-13-active-role.md`.
- **Role order** — `phoenix_kit_user_roles.position` (V190; seeded Owner,
  Admin, User, then custom roles by creation). Reordered on
  `/admin/users/roles` by dragging or with the arrows (`Roles.reorder_roles/1`,
  `Roles.move_role/2`); `Roles.list_roles/0`, `list_roles_paginated/1`,
  `get_custom_roles/0` and `get_user_role_records/1` follow it. It decides the
  **default role** of every new session — the first switchable role the user
  holds — and the order the switcher lists roles in.
- **Switching the active role** — `PUT /users/session/role` (`role_uuid`,
  optional `return_to`) through `ActiveRole.switch/3`: refused unless the
  switcher is on and the role is one of the user's switchable roles, written
  to that session's token only, logged as `session.role_switched`, and
  broadcast so every open LiveView of the user rebuilds its scope from its own
  token and leaves pages the new role cannot reach ("This page is not
  available in the role you switched to."). `return_to` is followed only when
  the new scope can mount it — admin-area paths are resolved through the
  router to their LiveView and asked the mount gate's own question, every
  role alike.
- **Removing a role signs out the sessions acting as it**
  (`Sessions.revoke_user_sessions_in_role/2`, from `Roles.remove_role/3` and
  `sync_user_roles/3`): the person starts over in whatever they still hold.
  Sessions in another role keep going and refresh in place.
- **The role switcher UI** — `PhoenixKitWeb.Components.Core.RoleSwitcher`. A
  "Role" section under Language in both account dropdowns
  (`AdminNav.admin_user_dropdown/1`, `UserDashboardNav.user_dropdown/1`), and
  with `role_switcher_location` set to `"header"` a compact control in the
  admin and dashboard headers from `sm` up, the menu section taking over on
  phones. Renders only for a narrowed scope — an impersonation session
  included; the switchable roles ride on the scope
  (`Scope.switchable_roles/1`), so it costs no query per page. The
  multi-session account list labels each account with the role its session is
  acting as.
- **Sessions lists show the role each session acts as** — `Sessions.*` rows
  carry `active_role`; `/admin/users/sessions` and the user's own devices list
  render it beside the device.
- **A "Roles" tab on `/admin/settings/users`** for the `role_switcher_*`
  settings: the on/off switch, the switcher location, and which custom roles
  are always on (Owner, Admin and User are fixed and not offered). Guide:
  `dev_docs/guides/2026-09-13-active-role.md`.

### Changed

- **`Roles.list_roles/0` and `list_roles_paginated/1` order by role order**
  (`position`, then name) instead of system-roles-first-then-name. The seeded
  order is the same for an untouched install.

### Fixed

- **Permanently deleting from a folder's trash view no longer destroys a file
  merely linked in from another scope** (post-#804 review): the single-file
  delete now requires the file's home in scope, like the bulk delete always
  did; a linked file in this folder's trash is unlinked instead. Rotation,
  which is written on the file, again requires the file's home in scope
  rather than only its appearance in the viewed folder.
- **The parked "Wrong email? Change it" form asks for the password when
  email confirmation is not enforced.** With `require_email_confirmation` off
  an unconfirmed account is fully usable, so the password-less path (2.22.7)
  would have let a stolen session re-address a live account. Confirmation
  enforced keeps the password-less path.
- **A stolen copy of the session cookie survived a password change** on the
  submitting browser's token, which 2.22.18 exempted from the disconnect so
  the re-login could go out. `Session.create` now disconnects that token five
  seconds after the new one is issued (`Sessions.disconnect_tokens_later/2`).
- **The LiveView scope refresh handed a deactivated user a fresh scope.**
  `reload_session_user/2` now passes through `ensure_active_user/1` like every
  other token/user resolution.
- **An Admin acting as another role could still impersonate.** The
  impersonation authority now reads the root session's roles in effect, so it
  follows the active role even for a hand-crafted POST. Targets are still
  judged by their real roles.
- **"You cannot edit your own role" ignored roles you hold but are not acting
  as.** `Permissions.can_edit_role_permissions?/2` now checks
  `Scope.held_roles/1`.
- **A role or permission change emptied the header's account switcher** until
  the next full page load: the LiveView scope refresh rebuilt the scope
  without the multi-session fields. They are now carried over.
- **The time-zone alert replaced the whole `custom_fields` map** from the
  socket's user struct, silently restoring stale values of every other key a
  concurrent tab had changed. It now merges its one key atomically
  (`Auth.merge_user_custom_fields/3`).

## 2.22.24 - 2026-09-12

### Changed

- **Etcher pinned to 0.13.2** (#803) — `mix.lock` and the `ETCHER_CDN` tag in
  `priv/static/assets/phoenix_kit.js` move together. Both media-viewer embeds
  (the lightbox and the `viewer_only` page) pass the new
  `panel_offset={%{top: 56}}`, so Etcher's style-panel chevron anchors below
  the viewer's details button instead of sharing its row.
- **The media viewer's sidebar toggle sits on the viewer/sidebar seam** (#803)
  on desktop with the sidebar expanded, hosted in a zero-width column between
  the panels (the viewer clips and the sidebar scrolls, so neither can hold it).
  Collapsed and stacked-mobile layouts keep the in-viewer button. The prev/next
  arrows gained 16px of inset from the image edge.

### Fixed

- **The `:fresco`, `:tessera` and `:etcher` requirements now stop at the pinned
  minor** (#802) — the same patch-less-`~>` bug 2.22.21 fixed for `:leaf`:
  `~> 0.10`, `~> 0.3` and `~> 0.9` each meant `< 1.0.0`, letting a host float
  the Elixir half past the exact jsDelivr tag core serves the browser half
  from. `vendored_cdn_pins_test.exs` now holds every pinned sibling's ceiling
  to its pinned minor. Resolution is unchanged.
- **The `:etcher` floor is raised to 0.13.2.** Core's markup passes
  `panel_offset` (Etcher 0.13.2) and `connectors={:off}` (0.12.2), and
  `phoenix_kit.js` bridges `etcher:tooltip-action` (0.13.0), but the
  requirement still admitted 0.9.0. A host whose lock held etcher 0.12.x kept
  it through `mix deps.update phoenix_kit`: the attrs were silently dropped
  (connector anchors reappeared on the lightbox) and the 0.13.2 bundle ran
  against a 0.12 server half. Such a host now gets a resolver error naming
  etcher instead.

## 2.22.23 - 2026-09-12

### Fixed

- **The inactive account rows in the user dropdown still sat a few pixels right
  of everything else.** The row that switches accounts is a `<button>`, which
  inherits the user-agent `text-align: center`, and the email inside it is
  `flex-1` — so an email shorter than its column centred itself and drifted
  right of the active row, which is a `<div>` and starts at the text edge. The
  effect scaled with how much slack the email had, which is why it survived the
  structural alignment fix in 2.22.22. The button now carries `text-start`.

## 2.22.22 - 2026-09-12

### Fixed

- **The account switcher in the user dropdown is aligned and legible again**
  (both `AdminNav.admin_user_dropdown/1` and `UserDashboardNav.user_dropdown/1`,
  which carried byte-identical markup and so carried identical bugs).
  - **"Add account" wore a gear icon** — `icon_settings`, the same glyph as the
    Settings row above it, reading as a second settings entry rather than an
    action. It is now `icon_user_add`.
  - **The active and inactive rows were built differently and did not line up.**
    The active row put its padding on the `li`'s direct child; the inactive row
    split it across a wrapper and a `<button>` two levels deeper, so daisyUI's
    own menu-child padding landed on each differently and the emails drifted a
    pad's width apart. The wrapper is now the only `li > *` and carries the
    `!p-0` reset (the idiom the in-menu language list already used), with every
    bit of spacing on an inner row that is structurally identical in both
    branches.
  - **The role badge on the active row was invisible** — `badge-ghost` renders
    as `base-200` and the row's own background was `base-200`, so the current
    account's role read as bare text while every other row showed a chip.
  - **Role badges now share a right edge**: the active row reserves width for
    its check mark, the inactive rows gained a matching spacer.
  - **Rows no longer change width with their remove button.** The trailing slot
    is a fixed width rendered on every row as soon as any account is removable
    (empty on the active and root rows), so the email column stops stepping in
    and out down the list. The literal `✕` character became `icon_x_thin`, and
    the button gained an `aria-label` naming the account it removes.
  - The active account now takes the `bg-primary` treatment the active language
    row above it already used, instead of a grey highlight — one active style
    per menu.

## 2.22.21 - 2026-09-11

### Changed

- **Leaf pinned to 0.8.0** (#801) — `mix.lock` and the `LEAF_CDN` constant in
  `priv/static/assets/phoenix_kit.js` move together to `leaf@v0.8.0`, bringing
  the atomic-chip editing batch: hand-typed preserved tags chip when the cursor
  leaves the line, chips are click-selectable (Backspace deletes, Enter opens a
  paragraph after, arrows step the caret out), and Ctrl+Backspace/Ctrl+Delete
  word deletion works in hybrid source blocks. Riding along: a wiki link can be
  typed in a row that already holds a markdown link, and the toolbar heading
  button edits the source in hybrid mode so it survives leaving the line.

### Fixed

- **The `:leaf` requirement now has the ceiling its comment always claimed.**
  Every alternative was patch-less — and `~> 0.5` means `>= 0.5.0 and < 1.0.0`,
  not "the 0.5 line", so that one alternative swallowed the whole 0.x range and
  made the `or ~> 0.6 or ~> 0.7 or ~> 0.8` enumeration after it inert. This
  matters more than for an ordinary dep: core serves leaf's browser half from an
  exact jsDelivr tag while Hex resolves the Elixir half, so an open ceiling let
  a host float the server half past the frozen bundle the day leaf 0.9 shipped —
  the silent cross-version editor the pin exists to prevent. The requirement is
  now `~> 0.4.1 or ~> 0.5.0 or ~> 0.6.0 or ~> 0.7.0 or ~> 0.8.0`
  (`>= 0.4.1 and < 0.9.0`); resolution is unchanged at leaf 0.8.0 and `mix.lock`
  did not move. `leaf_bundle_pin_test.exs` gained a test that rejects the next
  minor above the CDN pin, which the old floor-only check could never catch.

## 2.22.20 - 2026-09-11

### Fixed

- **Changing your password no longer signs you out of the tab that submitted
  the form.** The session-revocation fix in 2.22.18 broadcasts LiveView's
  `"disconnect"` (a page reload) for every token it deletes. The settings form
  still needs that socket: `phx-trigger-action` POSTs the re-login, and a
  reload here lands on a remember-me cookie pointing at a token that was just
  deleted. Other devices still close immediately; the submitting browser is
  skipped via `update_user_password/4`'s `:except_token`.

## 2.22.19 - 2026-09-11

### Security

- **The three endpoints that send mail to anyone who asks are no longer
  throttled per address alone.** Magic link, password reset and confirmation
  resend each counted hits per email address, while login and registration
  already counted per IP too. An address bucket cannot see a spray: ten
  thousand addresses take one hit each, no bucket ever fires, and the install
  sends ten thousand emails — mailbox flooding for the people named, and
  sender-reputation and mailer-quota damage for the operator. Each endpoint now
  has three buckets:

  - **per address** (unchanged, 3 per 5 minutes) — stops one person being
    hammered;
  - **per IP** (new, 10 per 5 minutes) — stops a spray from one host;
  - **per install** (new, 300 per hour) — the total the site will send at all,
    whoever asks and from wherever. A botnet with a fresh address and a fresh
    IP per request walks through the first two; only this bounds the mail bill.

  The site-wide cap is charged **last**, by requests the narrower two already
  allowed. Charged first, an attacker hammering a single address — refused, and
  sending nothing — would drain the allowance for everybody else, which is the
  one way a site-wide limit becomes an attack in itself. It trips loudly (a
  logged error naming the setting to raise), and is meant as a circuit breaker:
  raise it before anything that sends a crowd to the forgot-password form at
  once, such as a forced credential rotation. `nil` switches it off. All of it
  is tunable under `config :phoenix_kit, PhoenixKit.Users.RateLimiter`.

  Public pages capture the visitor's address during mount, which is the only
  point a LiveView can read connect info — captured anywhere else the bucket
  silently keys on nothing.

## 2.22.18 - 2026-09-11

### Security

- **Revoking a session now actually closes the tab it belongs to.** Every path
  that drops session tokens — "Sign out this device", "sign out everywhere",
  deactivating a user, an admin password reset, a password change, the
  external-proof confirmation — deleted the row and left any already-connected
  LiveView running. A socket keeps its assigns, an authenticated scope
  included, and goes on serving events until it re-mounts, so the account an
  operator had just cut off kept working in an open tab. Two defects stacked:
  the only function that broadcast the disconnect had no callers, and the
  broadcast itself resolved `PhoenixKitWeb.Endpoint` — a module that ships in
  this library but that nothing starts inside a host app, so it raised "no
  :pubsub_server configured", was swallowed by a rescue, and disconnected
  nothing anywhere. Disconnects now go to the host's endpoint (via
  `PhoenixKit.Config.get_parent_endpoint/0`) and are part of the token drain
  itself, so a future revocation path cannot forget them.

### Fixed

- **The user detail page names the account type and the organization.** "Basic
  Information" showed an "Account Type" row only for organization accounts, so
  the answer for everyone else lived in the summary card — not where you look
  first. A person account linked to an organization showed the organization's
  raw uuid; it now renders the organization's name as a link to it, the same
  way the summary card already did.

- **The account switcher no longer forgets accounts when the browser's session
  cookie goes away.** The multi-account stack lived only in the Plug session,
  which on a stock `mix phx.new` endpoint is a browser-session cookie — so at
  browser restart the remember-me cookie restored the one identity it holds and
  every account the user had added silently disappeared, with no error and
  nothing in the activity log. Added accounts are now mirrored into a second
  persistent cookie and the whole stack comes back with the remembered login.
  The mirror is written only for a browser that already holds a remember-me
  cookie (a deliberately session-only login stays session-only), is bound to the
  root token it was created under (so a stale mirror cannot attach itself to the
  next person who signs in on a shared computer), drops tokens that no longer
  resolve to an active user, and is cleared on logout, on a fresh login, and
  when `multi_session_enabled` is turned off. An impersonation is never
  mirrored: "sign in as this user" still ends with the browser session.

## 2.22.17 - 2026-09-11

### Added

- **An installed dashboards module can own the `/admin` landing page.** When
  one is present, enabled, and a dashboard is bound to the home place, it
  renders there instead of the built-in overview — live, so binding or
  unbinding one updates the page without a reload. Nothing changes on an
  install without that module.
- **Users can pick where they land after signing in.** A new "Start page"
  picker in profile settings lists the visitor's own visible, top-level admin
  tabs; the choice is honored on every login/magic-link/OAuth sign-in, after
  an explicit return-to destination and before the site's configured default.

### Fixed

- **`update_user_start_page/2` now delegates its local-path check to
  `Routes.local_path?/1`** instead of a private re-implementation that missed
  the ASCII control-character case documented as load-bearing elsewhere in
  the codebase. The stored preference was already re-validated by the real
  guard at redirect time, so this was not a live open redirect, but it closes
  a second, drifting copy of a security-critical check (PR #800 review).

## 2.22.16 - 2026-09-10

### Changed

- **Leaf bumped to 0.7.0.** Widens the `~> 0.4.1 or ~> 0.5 or ~> 0.6` requirement
  to also admit `~> 0.7`, and moves the `LEAF_CDN` pin in `phoenix_kit.js` to
  `leaf@v0.7.0` in lockstep with the resolved `mix.lock` version. Brings wiki-link
  chips to hybrid source mode and an announced (rather than silent) flush
  conflict in the collaboration layer.

## 2.22.15 - 2026-09-09

### Changed

- **Permanent user deletion moved off the Users list, and gets a real
  confirmation screen.** The "Delete" action is no longer offered from
  the list's row menu (table or card view) — it's a one-way, everything-
  related action that now belongs only on the user's own page, renamed
  "Permanently Delete" there. Confirming it now shows `Auth.
  preview_user_deletion/1`'s real, per-user counts (session tokens, role
  assignments, OAuth connections, billing profiles, shopping carts, admin
  notes — and what would be anonymized: orders, posts, comments, support
  tickets, email logs, files) instead of the same generic six-item bullet
  list for every user regardless of whether any of it actually applied.

## 2.22.14 - 2026-09-09

### Fixed

- **A boolean custom field on the user's own `/profile/settings` page had
  no checkbox at all.** The self-service custom-fields form had no
  `"boolean"` clause, so a boolean field fell through to the generic
  text-input default — the account holder saw (and could freely retype)
  the raw `"true"`/`"false"` value instead of a checkbox. The admin edit
  form already had a checkbox for this type; the profile page now does
  too.

### Changed

- **A boolean custom field on the admin edit form no longer shows two
  redundant labels.** The generic "Label / Type" header above every field
  plus the checkbox's own generic "Enable this option" label meant a field
  named e.g. "Approved for Wood Matrix" rendered as "Approved for Wood
  Matrix / Boolean" followed by an unrelated "[ ] Enable this option".
  A boolean field now renders as a single checkbox labeled with the
  field's own label, matching how a checkbox is normally presented.

## 2.22.13 - 2026-09-09

### Changed

- **"New login" alerts no longer fire on an IP change alone.**
  `LoginAlerts` treated a login as an unrecognized "new device" whenever
  the exact `(ip_address, user_agent_hash)` pair had no matching history
  row — so a user with a non-static IP (most residential/mobile
  connections) got a "we noticed a new login" email on a large fraction
  of logins from a browser they'd used many times before, training people
  to ignore it. The email/in-app alert now fires only when the browser/OS
  itself (`user_agent_hash`, regardless of IP) hasn't been seen for the
  account before; an IP-only change on an already-recognized browser
  updates the device record and activity log silently, same as it
  already does for the account's first-ever login. The per-`(ip, ua)`
  device history itself is unchanged — still used to enrich the
  self-service Active Sessions list.

## 2.22.12 - 2026-09-09

### Fixed

- **A successful geolocation lookup crashed registration mid-signup.**
  `registration_country` is a 2-char column by design (ISO 3166-1
  alpha-2), but `Geolocation.lookup_location/1` only ever fetched and
  returned the full country name (e.g. "United States"), and
  `register_user_with_geolocation/2` wrote that straight into the column.
  This had gone unnoticed because geolocation never actually succeeded in
  production before the 2.22.10/2.22.11 IP fixes — once it started
  resolving real visitor IPs, every successful lookup raised an unhandled
  Postgres `string_data_right_truncation` and killed the registration
  LiveView mid-signup. `Geolocation` now also fetches the ISO alpha-2 code
  from both providers, and only a genuine 2-letter code is written to
  `registration_country`.
- **`registration_country`'s changeset validation didn't match its own
  column.** It allowed up to 100 characters — copied from
  `registration_region`/`registration_city` — instead of the 2 the column
  actually holds, so an oversized value reached Postgres as "valid" and
  only failed at the SQL layer instead of a normal `{:error, changeset}`.
  Now validated at `max: 2`, matching the column, as defense-in-depth for
  any caller.
- Admin UI locations (`user_details`'s and the Users list's "City, Region,
  Country" text) now expand the stored ISO code back to a full country
  name via `PhoenixKit.Utils.CountryData.country_name/1` for display.

## 2.22.11 - 2026-09-09

### Fixed

- **The IP address behind session-hijack detection and "new device" login
  alerts could be spoofed with a plain HTTP header.**
  `SessionFingerprint.get_ip_address/1` trusted `x-forwarded-for` /
  `x-real-ip` unconditionally — with no check that the request actually
  came through a trusted reverse proxy — and took the FIRST
  `x-forwarded-for` entry, which is exactly the part a client controls. An
  attacker replaying a stolen session token could forge that header to
  match the victim's original login IP and defeat the "IP changed, force
  re-auth" hijack check, or spoof the location shown in a "new login"
  alert email. It now delegates to the already-proxy-aware
  `IpAddress.client_address/1`, which trusts a forwarded header only when
  `conn.remote_ip` is itself a loopback/private address, and only the LAST
  entry — the one a proxy appends, not the one a client sent.

## 2.22.10 - 2026-09-09

### Fixed

- **Registration IP/geolocation tracking silently recorded "unknown" for
  every self-registered user.** `register_user_with_geolocation/2` guarded
  on `is_binary(ip_address)` alone, and the socket/conn IP extractors return
  the literal string `"unknown"` — never `nil` — when they can't tell the
  visitor's address. That literal string satisfied the guard and got
  written to `registration_ip` as if it were a real IP, then rendered
  verbatim in the admin UI instead of "No data." Self-registration,
  magic-link registration, and OAuth registration all funnel through this
  one function, so all three are fixed at once.
- **IP tracking now reads the visitor's real address behind a reverse
  proxy, everywhere it's tracked.** `IpAddress.extract_from_socket/1` and
  `extract_from_conn/1` — used for registration, login, magic link,
  sessions, multi-session, live sessions, dashboard presence, the referral
  gate, and the admin user form — used to read the raw TCP peer, which
  behind nginx (or in a container) is the proxy's own address for every
  visitor. They now delegate to the already-proxy-aware
  `client_address_from_socket/1` / `client_address/1`, which read
  `x-forwarded-for` / `x-real-ip` when the peer is a loopback or private
  address.
- Documented that `track_registration_geolocation` requires the host
  endpoint's LiveView socket to declare `:peer_data` in `connect_info` —
  `mix phoenix_kit.install` doesn't (and can't) set this up automatically,
  and without it the setting silently does nothing.

## 2.22.9 - 2026-09-09

### Added

- **`<.load_more>` forwards extra HTML/`phx-*` attributes to its button.**
  A page rendering more than one `<.load_more>` list can now attach
  `phx-value-*` so a single shared `handle_event` clause can tell which
  list's button was clicked, instead of minting a distinct `on_load_more`
  event name per list.

## 2.22.8 - 2026-09-09

### Changed

- **The parked "wrong email?" fix-up form no longer asks for the current
  password.** It reused the same `apply_user_email/3` path Profile
  Settings uses for a confirmed user's email change, but there is no
  live/confirmed account yet for a hijacked session to protect at that
  point — just a pending signup fixing a typo before its first
  confirmation. New `Auth.apply_unconfirmed_user_email/2` is
  pattern-matched on `confirmed_at: nil` so it structurally cannot be
  reused once an account is confirmed.
- **A confirmation resend now says what actually happened.** The handler
  ran the rate-limit check, the account lookup, and the send inside a
  `with` whose result was never inspected, so hitting the 3-per-5-minutes
  resend limit (or a genuine mailer failure) still flashed "we've sent a
  new confirmation link" with nothing to explain why no mail showed up.
  The parked (authenticated) branch now flashes the real outcome —
  success, a clear rate-limit notice, or a retry message with the actual
  reason logged server-side. The anonymous branch is unchanged: it always
  shows the same vague message regardless of outcome, which is what
  avoids turning the endpoint into an account-enumeration oracle for a
  signed-out visitor.
- **The "new login" security alert no longer fires on an account's own
  signup.** Registration ends by logging the new user in through the same
  path every other login uses, and a brand-new account has no device
  history yet — so with `new_login_alert_enabled` on, every signup
  immediately triggered a "we noticed a new login to your account" email
  about the login it had just performed to finish registering.
  `LoginAlerts` now checks whether the account has *any* known device on
  record before alerting; a true first device is still recorded (so an
  actual second device correctly reads as new) and still logged to the
  activity feed, but skips the email and in-app notification.

## 2.22.7 - 2026-09-08

### Changed

- **Reworked the parked "confirm your email" screen** (`/users/confirm` for
  an already-logged-in, unconfirmed user). The card now says what actually
  happened and when ("Sent 3m ago", backed by a real read of the
  confirmation token's `inserted_at` — there was previously no record shown
  at all); the email field is a plain read-only display instead of a
  disabled-looking, falsely-required `<input>`; the resend button reads
  "Resend email" instead of the truncation-prone "Resend confirmation
  instructions"; and the "Wrong email? Change it" password re-entry now
  explains itself instead of looking arbitrary to an already-authenticated
  visitor.
- **The Register / Log in links on that same screen were nonsensical for a
  parked, already-authenticated visitor** — clicking either just bounced
  back to the same confirmation gate. They're now a single **Log out**
  link while parked, matching the pattern already used on the referral-gate
  screen; the anonymous "resend instructions" form (no session) keeps
  Register / Log in.

### Added

- `PhoenixKit.Users.Auth.get_last_confirmation_sent_at/1` — the `inserted_at`
  of a user's most recent live confirmation-email token, `nil` if none is on
  record. Backs the "Sent X ago" wording above.

## 2.22.6 - 2026-09-08

### Changed

- **Integrations encryption's legacy-key warning no longer logs on every
  boot by default.** Any install still on the `secret_key_base`-derived
  fallback (every install before the dedicated-key feature existed) got a
  `Logger.warning` on every single restart with no way to quiet it short of
  configuring a dedicated key. `PhoenixKit.boot/1` now only emits it when
  `config :phoenix_kit, integration_encryption_warn_on_boot: true` is set
  (default `false`). `mix phoenix_kit.doctor` and the admin-only system page
  still surface the same diagnosis on demand, unconditionally — only the
  unsolicited boot-time push is now opt-in.

## 2.22.5 - 2026-09-08

### Changed

- **"Email Sending" settings page renamed to "Emails Transactional."**
  Labels and copy only — the route stays `/admin/settings/email-sending`
  so existing links and bookmarks keep working.
- **Send Profiles promoted to its own top-level "Emails Bulk" Settings
  tab** (`/admin/settings/emails-bulk`), a sibling of Emails Transactional
  rather than a subtab nested under it — bulk/marketing sending config is
  a distinct concern from the always-needed transactional setup. Stays in
  core: it's live infrastructure Newsletters' delivery worker depends on
  today, not something `phoenix_kit_emails` itself consumes.
- **Website access: dropped the environment banner, the presets, and the
  visitor notice** (#797). The admin header's automatic `[dev]` tag
  already tells a dev/staging box apart from production on every page, so
  the banner and the notice repeated that signal; the presets picked
  between values every feature already lets you set directly. "Hide from
  search engines" keeps its `X-Robots-Tag` header, now its own plug step
  instead of riding inside the removed notice's callback.

## 2.22.4 - 2026-09-08

### Added

- **Active / Disabled / Not Installed tabs on the admin Modules page.** The
  page previously listed every accessible module in one grid regardless of
  its on/off state. Toggling a module now moves it live between tabs (no
  reload), and each tab shows a running count badge.

### Changed

- **Storage and Notifications no longer appear on the admin Modules page.**
  Both are core capabilities, not real install/uninstall toggles — Storage
  has always been unconditionally enabled (`enable_system`/`disable_system`
  are no-ops) and Notifications is a settings kill-switch already exposed on
  `/admin/settings/users`. Listing them alongside genuinely optional modules
  (Languages, Crawlers, Sitemap, external packages) misrepresented them as
  removable features. Their permission keys, admin tabs, and Settings pages
  are unchanged — only the redundant Modules-page card was removed.
- **`phoenix_kit_hello_world` no longer appears in "Not Installed" packages.**
  It's a starter template for building a new module, not a real feature to
  install.

### Fixed

- **The not-yet-installed "Og" package card showed "Og" instead of "OG".**
  `PhoenixKit.KnownPackages`' key-to-name humanizer capitalized every word
  instead of upper-casing known acronyms; it now special-cases them.
- **`billing_default_currency` dead setting removed (V189).** Seeded by V135,
  read by nothing (confirmed by a full grep across `phoenix_kit`,
  `phoenix_kit_billing`, and `phoenix_kit_ecommerce`), and actively
  disagreeing with the real base currency (the `is_default` row of
  `phoenix_kit_currencies`) — worse than merely unread. Follows V184's
  `shop_currency` removal shape exactly; `down/1` restores V135's exact seed
  statement without clobbering a hand-recreated value. (#796)

## 2.22.3 - 2026-09-08

### Added

- **`PhoenixKit.TestSupport.PostgresPreflight`** — a shared, classified
  PostgreSQL connection check for a package's `test_helper.exs`. Replaces the
  `psql -lqt` listing that ran as the shell user over a unix socket and
  answered the wrong question: it said nothing about whether the *configured*
  role could reach the database over TCP, so a wrong `PGUSER` did not surface
  as "wrong `PGUSER`" — it queued through the SQL sandbox and died minutes
  later as a pool-checkout timeout that read like a flaky test. Ships in
  `lib/` (not `test/support/`) so sibling packages depending on `phoenix_kit`
  through Hex can call it too; never call it from application code.

### Fixed

- **`phoenix_kit_user_connections`' three `unique_constraint/3` declarations
  were inert.** `phoenix_kit_user_follows_unique_idx`,
  `phoenix_kit_user_blocks_unique_idx` and
  `phoenix_kit_user_connections_requester_recipient_uidx` have always been
  named in the module's schemas, but the indexes backing them never existed —
  a database violation is what `unique_constraint/3` translates into a
  changeset error, and with no index there was no violation. Two users
  clicking "connect" on each other at the same moment both passed
  `request_connection/2`'s read-then-write pre-check and both inserted,
  leaving a duplicate relationship that a later auto-accept could turn into a
  live pending request between two already-connected users, or into two
  "accepted" rows that made `get_accepted_connection/2` raise
  `Ecto.MultipleResultsError`. V188 removes any duplicates the race already
  produced (favoring an accepted row over a pending one) and creates the
  three indexes — an expression index on `LEAST`/`GREATEST` of the pair for
  the undirected `phoenix_kit_user_connections` table, ordered-pair indexes
  for the directed follows/blocks tables — so the existing
  `unique_constraint/3` calls start enforcing what they always claimed to.

## 2.22.2 - 2026-09-08

### Added

- **Rows-per-page selector on the Users admin tabs.** Users, Sessions, Live
  Sessions, Roles and the media picker each get a daisyUI `<select>` next to
  the page links (`<.page_size_selector>`, a sibling of `<.pagination>` in
  `PhoenixKitWeb.Components.Core.Pagination`). The choice lives in the URL as
  `?per_page=` — validated against an allowlist, invalid values fall back to
  the tab's default — so a size survives reload and is shareable; picking a
  new size lands on page 1.
- **Roles is paginated** (25 per page by default). It used to render every
  role on one page; the summary cards now count the whole table rather than
  the rows on screen.
- **"Auto" page size (opt-in pilot on the Users tab).** `<.page_size_selector
  auto_fit>` offers an Auto option backed by a small `PageSizeAutoFit` JS hook
  that measures the table's top offset and one row against the viewport and
  picks the largest allowed size that fits, re-fitting on resize. Off by
  default; `?fit=true` in the URL.

### Changed

- Users, Sessions, Live Sessions and the media picker share the core
  `<.pagination_controls>` instead of four hand-rolled `join` blocks with
  their own page-range helpers.
- `<.pagination_info>` is translated ("Showing … of … results" / "No results"
  were hardcoded English) and takes a `noun_plural` attr so a caller can name
  what is counted — Sessions passes `gettext("sessions")`, keeping the line it
  had before switching to the shared component.
- Sessions now filters and pages in SQL (`Sessions.list_sessions_paginated/1`)
  instead of loading every session token and slicing the list in memory.
  Live Sessions keeps the in-memory slice: Presence is an ETS-backed
  GenServer, there is no table to push LIMIT/OFFSET down to.

### Fixed

- The **Integrations** sidebar tab still pointed at
  `/admin/settings/integrations/website`, the path 2.21.3 renamed to
  `/admin/settings/integrations`. That URL does not 404 as the rename note
  expected — it matches `/admin/settings/integrations/:uuid` with
  `uuid = "website"`, so `Repo.get/2` raises `Ecto.Query.CastError` and
  LiveView returns a 400 reload response, which loops. The two README route
  lists and `AGENTS.md`'s owner-scope note were stale from the same rename
  and are corrected alongside it.

## 2.22.1 - 2026-09-08

### Added

- Tabs on the Media settings page (`/admin/settings/media`) — Buckets /
  Configuration / Quick Actions, the same `<.nav_tabs>` treatment already
  applied to Email Sending and Sitemap. The ImageMagick/FFmpeg dependency
  warnings stay above the tab strip since they apply regardless of which
  tab is open.
- **Public "Edit link" API** — `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3`
  is now a documented public API: a host LiveView or a module's own public
  controller/LiveView calls it to declare a public page's matching admin
  edit target. The label argument now also accepts a keyword list
  (`label:`, `permission:`), gating the link on a specific module's
  `Scope.has_module_access?/2` in addition to the existing admin-area check,
  while every existing string-label call site keeps working unchanged. A new
  `PhoenixKitWeb.Components.Core.AdminEditLink.admin_edit_link/1` component
  (`<.admin_edit_link .../>`) renders the link — as a standalone button or a
  `:menu_item` for dropdowns — and renders nothing when there is no URL, so
  hosts can drop one line into their public layout unconditionally. See the
  "Edit link on public pages" section in `guides/integration.md`.

## 2.22.0 - 2026-09-08

### Added

- The parked `/users/confirm` page (where a logged-in but unconfirmed user
  lands) now has a "Wrong email? Change it" option — a compact version of
  Profile Settings' change-email form (current password + new address).
  Confirming the new address both changes the account's email and confirms
  it in one step, so a typo'd signup email no longer strands the account.
  The confirmation link points at a new, purpose-built page
  (`/users/confirm/change-email/:token`) rather than the normal
  `/profile/settings/confirm-email/:token` — that page requires a confirmed
  account to reach, which would have made the fix for "I'm unconfirmed"
  depend on already being confirmed.

### Fixed

- The parked page's "Resend confirmation instructions" flash message said
  "If your email is in our system and it has not been confirmed yet..." even
  though the visitor was already logged in as that exact account — the
  enumeration-safe hedge (correct for the public, logged-out resend form)
  read as a wrong answer once you're signed in. A logged-in unconfirmed user
  now gets a direct message naming their own address, and the (previously
  editable) email field on that form is now read-only and its value ignored
  server-side — editing it could otherwise be used to probe whether an
  arbitrary address is registered.

## 2.21.5 - 2026-09-08

### Changed

- The "Development site" preset (Website Access settings) no longer switches
  on the visitor notice bar — the admin header's automatic "[dev]" tag
  (added in 2.21.3) already tells an admin apart from production, so the
  preset only needs the password gate and hiding from search engines now.
  The notice feature itself is unchanged and still available for hosts that
  want a visitor-facing banner for any reason (maintenance, under
  construction, or their own dev-site text). Existing installs that already
  applied the old preset keep their notice switched on until turned off by
  hand on Settings → Website Access → Notice.

### Fixed

- Flash notifications could get stuck on screen indefinitely instead of
  auto-dismissing. `@flash` is one Phoenix assign covering all three kinds
  (info/warning/error), so putting or clearing a *different* kind's flash —
  or the same kind with unchanged text — marks the whole assign dirty and
  re-diffs every currently-shown flash node, not just the one that actually
  changed. The `FlashAutoDismiss` hook's `updated()` callback (added in
  2.21.0 to fix a related issue) treated every such patch as "a new message
  landed" and unconditionally restarted the dismiss timer, so a flash on a
  page where anything else touched flash state could sit on screen forever.
  It now fingerprints the message text and only restarts the timer when it
  actually changed.

## 2.21.4 - 2026-09-07

### Fixed

- The "igniter dependency is missing" message that `mix phoenix_kit.update`
  (and the other Igniter-backed tasks) prints for an unsupported `MIX_ENV`
  (e.g. `prod`) told the operator to add
  `{:igniter, "~> 0.7", only: [:dev, :test]}` — the exact fix the message had
  just explained would not work, since that scoping excludes the very
  environment the task is running in. It now explains that these tasks
  generate/apply code and genuinely need igniter loaded wherever they run,
  and offers the two real options: run the task from dev/CI and ship the
  generated files, or broaden the host's own igniter dependency's `only:` to
  include that environment.

## 2.21.3 - 2026-09-07

### Added

- A quiet "[dev]" tag next to the project title in the admin header,
  automatic whenever `PhoenixKit.WebsiteAccess.environment().looks_like_dev?`
  is true (non-`prod` mix env, or a dev/staging/test/local/sandbox/preview
  word in the hostname or configured site URL) — no setting to remember to
  flip. Replaces the old workflow of switching on the general-purpose Notice
  bar (a fixed bar across the bottom of every page) just to signal "this
  isn't the production site"; that feature is unchanged and still available
  for actual visitor announcements.

### Changed

- **Breaking:** the website-wide Integrations settings page moved from
  `/admin/settings/integrations/website` to `/admin/settings/integrations`.
  The `/website` segment only ever existed to disambiguate it from the
  personal per-user integrations page, which shared the same base path; that
  page has since moved to `/profile/settings/integrations`, so the
  disambiguation segment is no longer needed. Any bookmarked or linked
  `/website` URL will 404.

## 2.21.2 - 2026-09-07

### Added

- Non-destructive avatar cropping, Apple Photos style — picking a new avatar
  opens a drag/wheel/slider crop editor before anything persists; the crop
  geometry (`x`, `y`, `zoom`, aspect ratio) is stored alongside the original
  upload rather than baked into re-encoded pixels, so re-cropping never loses
  quality.

### Fixed

- Multi-domain sitemaps could list the same home URL twice (once bare, once
  with the full cross-domain hreflang set) when a locale-prefixed clone route
  had no `canonical_path` of its own, and a single-language canonical group
  on a non-primary domain could carry a self-only hreflang pair that the
  page's own `<head>` never backed up.
- The storage orphan-file check now recognizes catalogue-owned tables:
  `phoenix_kit_cat_items`, `phoenix_kit_cat_categories`, and
  `phoenix_kit_cat_catalogues` store image references inside a JSONB `data`
  column rather than dedicated FK columns, so a plain join was missing them
  and could queue a live catalogue image for deletion. `phoenix_kit_cat_pdfs`
  references its file through a real FK with `ON DELETE RESTRICT`; a PDF
  still in use could have its file data deleted and then crash the cleanup
  job on the FK violation — that table is now guarded too.
- A stale avatar crop could outlive the file it was framed for — replacing
  an avatar without submitting a new crop now clears the old geometry
  instead of stretching the old aspect ratio onto the new image.
- Landscape avatars rendered soft: crop-variant selection compared needed
  pixels against the image's width instead of its short side, which is what
  actually bounds sharpness under cover-fit.

## 2.21.1 - 2026-09-07

### Fixed

- **Languages settings page's breadcrumb fix from 2.21.0 was incomplete**
  — the `page_section`/`page_section_path` assigns were added to `mount/3`
  but never threaded into the template's `app_layout` call, so the
  breadcrumb still showed bare "Languages" instead of "Settings /
  Languages".
- Media settings page's subtitle was a full paragraph that didn't fit in
  the header on any but the widest screens, truncating to unreadable
  fragments. Shortened to match the length of every other Settings page's
  subtitle.
- **Two mistranslated strings from 2.21.0's gettext round-trip**: the
  Sitemap tab label "Sources" had been auto-fuzzy-matched to unrelated
  "Success" translations in Russian, French, German, Spanish, Italian,
  Polish, and Estonian; the Email Sending tab label "Local Dev Mailbox"
  was fuzzy-matched correctly but never had its fuzzy flag verified and
  cleared. Both fixed with real translations.

## 2.21.0 - 2026-09-07

### Added

- Tabs on the Email Sending and Sitemap settings pages — same treatment
  as the rest of Settings: Sender Identity / Transport / Local Dev
  Mailbox / Default Integration / Test Send / Send Profiles for Email
  Sending, and Sources / Configuration / Quick Actions / Advanced for
  Sitemap.

### Fixed

- **Settings breadcrumb regressions on several pages that don't call
  `LayoutWrapper.app_layout` from a per-page `.ex`/`.heex` pair the same
  way the rest of Settings does** — Media (`/admin/settings/media` and
  its Dimensions/Health/bucket/dimension sub-pages) and Sitemap
  (`/admin/settings/sitemap`) both linked their breadcrumb's second
  segment to "Modules" → `/admin/modules` instead of "Settings" →
  `/admin/settings`, even though both live under the Settings sidebar
  group — the wrong link, not just a mislabeled one. Media's page title
  was also shortened from "Media Settings" to "Media" to match the
  sidebar and stop the breadcrumb truncating to unreadable fragments on
  narrower screens.
- **Languages settings page had no breadcrumb section at all**, showing
  bare "Languages" instead of "Settings / Languages" like every sibling
  page.
- Renamed "Website Integrations" back to plain "Integrations" now that
  the personal "My Integrations" page (the reason for the "Website"
  qualifier) lives under Profile Settings instead of colliding with this
  one.
- "Main countries" label capitalization on the Organization settings
  page's Main Countries tab (was inconsistent with the other tab
  labels).
- Drag-and-drop reordering on touch devices (iPad) for the Main
  Countries list — SortableJS's fallback drag mode needs
  `touch-action: none` on the drag handle, which nothing in the
  codebase set; added it globally to `.pk-drag-handle`, plus a larger
  touch target for this specific handle.
- Flash notifications no longer auto-dismissed after their timeout — the
  `FlashAutoDismiss` hook only started its timer in `mounted()`, which
  LiveView doesn't call again when it patches an existing flash node in
  place. Added the missing `updated()` lifecycle callback.
- VAT/Tax ID on the Organization settings page is optional again (format
  is still validated when a value is given) — most jurisdictions don't
  require every company to register for VAT/a tax ID below a threshold.
  Registration Number is now required instead, since every incorporated
  company gets one.
- The "Main Page" field under General → Site Address is now labeled
  "Signed-Out Landing Page" with a clearer explanation of what it
  actually controls (where a signed-out visitor lands, including right
  after logging out).

## 2.20.0 - 2026-09-07

### Added

- **Multiple bank accounts** — the Organization settings page's Bank
  Accounts card now supports more than one account (a EUR operating
  account and a USD reserve account, say), each with a label, bank name,
  IBAN, SWIFT/BIC, and a "primary" flag, via a proper add/edit/delete UI.
  Previously there was room for exactly one. `phoenix_kit_billing`'s
  integration point is unaffected — it now reads the primary account.
- **Country-aware Company Information fields** — the State/Province field
  is a real dropdown for the 224 countries with subdivision data (US: 50
  states + DC + territories; Canada: 13 provinces/territories; and 222
  others), falling back to free text only for the 26 without. The tax-ID
  field is labeled and validated correctly per country instead of always
  saying "VAT Number": **EIN** for the US, **Business Number (BN)** for
  Canada, **VAT Number** for EU members, generic **Tax ID** elsewhere. The
  postal-code field says **ZIP Code** for the US and **Postal Code**
  everywhere else, both with real format validation.
- Tabs on the Authorization, Users, Crawlers, Website Access, and
  Organization settings pages — same treatment as General settings' tabs
  in 2.19.0, each page's sections behind a strip instead of one long
  scroll.

### Fixed

- The bank accounts list could not actually be saved: `value_json` is an
  Ecto `:map` column that silently rejects a bare JSON array, so every
  save looked successful (the flash fired) while quietly never
  persisting past a single legacy account on reload. Fixed by wrapping
  the list the same way Custom User Fields already does
  (`%{"accounts" => [...]}`).
- `CountryData.get_subdivision_label("CA")` had a stale doctest claiming
  "Province"; the real value from `beamlab_countries` is "Provinces and
  territories".

||||||| parent of 8fbfa12992 (Make the public-page Edit link a documented API with a component and a permission gate)
## 2.19.0 - 2026-09-07

### Changed

- **Personal integrations moved off Settings, onto the profile page** — "My
  Integrations" was a Settings sub-sub-tab three levels deep (Settings ›
  Integrations › My Integrations), and holding only the personal
  `integrations` permission made the whole Settings section appear in a
  regular user's sidebar just for that one page, despite it being per-user
  data rather than a site-wide setting. It now lives at
  `/profile/settings/integrations`, reached from a new **Integrations**
  section on the Profile Settings page (connection summary + a "Manage
  Integrations" link). The Settings sidebar's "Integrations" grouping tab is
  gone; "Website Integrations" is now a plain flat Settings subtab like
  Users/Authorization, gated on `integrations_system` alone. Hosts linking
  directly to the old `/admin/settings/integrations` path need to update to
  `/profile/settings/integrations`.

### Added

- Tabs on the General settings page (Site Identity, Site Address, Features,
  Content Editor, Date & Time) instead of one long scroll — one form, one
  Save button underneath all of them.

### Fixed

- Settings breadcrumbs are consistent across every subtab now: "Settings /
  <Name>", matching the sidebar label exactly. Most subtabs previously
  hardcoded their own breadcrumb title directly in the template (ignoring
  the `page_title` their own `mount/3` set) and none showed a "Settings /"
  parent crumb, so titles drifted from the sidebar's labels (e.g.
  "Authorization Settings" vs. sidebar "Authorization") and General showed
  bare "Settings" with no subtab name at all. Nested pages (Send Profiles,
  the integration forms) now show their full breadcrumb trail.

## 2.18.1 - 2026-09-07

### Fixed

- Login page heading hierarchy — the bold heading said "Welcome back" and the
  subtext said "Sign in to %{project_title}", backwards for a visitor who
  isn't authenticated yet. Swapped which string gets which styling.
- Removed duplicate in-body page headings on the General, Users, and
  Authorization settings pages, and on the profile settings page
  (`/profile/settings`) — each repeated the page title already shown in the
  top breadcrumb bar.
- Removed hardcoded Comments, Referrals, Customer Support, and Connections
  cards from the admin Modules page — each of those modules was extracted
  into its own hex package that auto-registers via `PhoenixKit.Module` and
  already renders through the generic external-module card loop, so
  installing any of them showed a duplicate card. The generic card now
  covers everything the hardcoded ones did via each package's
  `module_stats/0`.

## 2.18.0 - 2026-09-07

### Added

- **Website access** — one settings page (`/admin/settings/website-access`) for every
  way of controlling who sees the site, with independently switchable features and
  presets (Maintenance, Under construction, Development site, Live) that bundle them:
  - **Password gate** — a blank page with one field at `<prefix>/access`, before
    anyone sees anything. Unlock is a session epoch (rotated on password change,
    switch-on, or "ask everyone again"), never password-derived. Every try is
    recorded with a verdict (correct, case, close, unrelated, empty, locked, link)
    and, by default, what was typed — narrowable to near-misses or nothing. Optional
    per-address lockout under a per-address advisory lock. An access link unlocks
    only on the button's POST, never on the link's own GET, so a preview fetcher
    can't burn it. Logged-in users pass by default.
  - **Redirect to production** — public GET/HEAD to the same path and query on the
    production URL, never for logged-in users, the kit's own pages, or back to this
    host; everyone or crawlers only.
  - **Visitor notice** — an escaped bar injected after `<body>` on HTML 200s
    (byte-safe), editable live from the settings page.
  - **Site closed** — maintenance is now part of core: heading, message, a
    from/until window, a status line, a preview, and a visitor 503 page that counts
    down to the end. `PhoenixKit.Modules.Maintenance` keeps its name and API.
  - **Hide from search engines** — the crawlers noindex switch, plus
    `X-Robots-Tag` on every response in the chain.
  - **Allowed addresses** — pass the gate and the redirect; editing the list
    relocks already-open sessions.
  - **Environment panel** — release/mix, `MIX_ENV`, host, site URL — suggests a
    preset, never switches anything on. Header badges (lock, wrench, arrow) show
    while a feature is on and link to its settings.

  `PhoenixKitWeb.Plugs.WebsiteAccess` runs the chain in the host's browser
  pipeline: allowed-address bookkeeping → notice/robots → redirect → gate →
  maintenance. Every `on_mount` hook in `Users.Auth` checks the gate first. New
  migration **V187** adds `phoenix_kit_access_attempts`. Core's `<.checkbox>`
  gained `variant="toggle"`; `Routes.prefix_base/0` was added for root-mounted
  kits.

### Fixed

- The settings cache warmer could run before the host's endpoint was up. Under
  the legacy encryption tier the endpoint's `secret_key_base` **is** the key, so
  a restricted value failed to decrypt at boot and the failure was cached as
  `nil` until that key's next write — any host reading an OAuth secret or AWS
  key through `get_setting_cached/2` right after a restart hit this. The warm
  map now leaves an undecryptable key out instead of caching `nil` for it, and a
  cache miss caused by a decrypt failure is answered `nil` without being cached.
- A password-gate redirect-target test asserted a maintenance schedule starting
  exactly 60 seconds in the past, which sits on the validator's own tolerance
  boundary and failed deterministically once clock drift pushed it a hair past
  `-60`.
- The gate's `?to=` redirect-target check reimplemented local-path validation
  with its own regex instead of `Routes.local_path?/1`; it now calls the shared
  guard, with the gate's own rules layered on top.

## 2.17.0 - 2026-09-06

### Changed

- **`Mailer.send_from_template/4` no longer depends on the email templates
  table.** It is core's generic host-facing send API, and it resolved names
  from the database alone — answering `{:error, :template_not_found}` when
  there was no row. That table is being retired, and `phoenix_kit_billing`
  reaches through this function for its invoice, receipt, credit-note and
  payment-confirmation emails, so dropping the table with this path untouched
  would have stopped those emails **silently**, with an error shape the caller
  already tolerates.

  It now resolves through `PhoenixKit.Email.Content`, in order: an active
  database template, then a host override file for the recipient's locale, then
  the caller's own `:defaults`.

  **Nothing changes for an install that has a row** — the database layer still
  wins, exactly as it does for the auth emails. This ships ahead of the schema
  move on purpose, so no caller is ever in a window where its emails depend on
  a path that no longer works.

  Three new options:

  | Option | Effect |
  |---|---|
  | `:defaults` | content to fall back to — a `%{subject:, text:, html:}` map, or a zero-arity function returning one. Prefer the function for `gettext/1` content: it is evaluated inside the recipient's locale |
  | `:locale` | render in this locale instead of the one resolved from the recipient (a bare address carries no preference, so that falls through to the site's content language) |
  | `:paths` | host override roots to search, overriding the configured ones |

  A host or module that calls this function should add `:defaults` before the
  table is retired. Until then, adding them changes nothing.

- `PhoenixKit.Email.Content.resolve/5` accepts `:locale`, for callers whose
  recipient is a bare address rather than a user, and treats an explicit `nil`
  `:paths` as "use the configured roots".

### Fixed

- `{:error, :template_inactive}` is documented as no longer returned by
  `send_from_template/4`, and never was:
  `get_active_template_by_name/1` already filters on `status == "active"`, so
  the branch that returned it was unreachable.

## 2.16.0 - 2026-09-06

### Added

- **Outbound messages are rendered in the recipient's language.** Every auth
  email had been going out in English no matter who received it. Five call
  sites in `UserNotifier` and one in `Mailer` used the two-arity
  `render_template/2`, whose locale defaults to `"en"` — so a template
  translated into all seven locales was only ever read in one of them, and the
  translations sat in the database unread. Only
  `Mailer.send_from_template/4` passed a locale.

  `PhoenixKit.Utils.RecipientLocale` is now the single answer to "whose
  language is this message in": `for_rendering/1` returns the recipient's full
  dialect and never `nil`, falling back to the site content language and then
  `"en"`; `base/1` returns the base code or `nil` for Gettext, which reads
  `nil` as "leave the current locale alone". It keeps the dialect rather than
  narrowing it, since template resolution tries `"en-GB"` before `"en"` and
  pre-truncating would discard a dialect-specific translation. The preference
  comes from `custom_fields["preferred_locale"]`, written by the language
  switcher.

- **Message templates can be customized by the host, as files.**
  `PhoenixKit.Email.Content` resolves every auth email across three layers: an
  active database template (unchanged, and still winning — see below), then a
  host override file for the recipient's locale, then core's own translated
  default. Parts resolve independently, so a host that overrides only the body
  keeps core's translated subject.

  An override is a file in the host's own repo, version-controlled and
  reviewable. The template's **name is a directory**; the files inside it are
  named for the part they supply:

      <host>/priv/phoenix_kit_templates/
      └── new_login_alert/
          ├── text.txt          # <part>.<ext>
          └── text.de.txt       # <part>.<locale>.<ext>

  Lookup runs most- to least-specific — `text.de-AT.txt` → `text.de.txt` →
  `text.txt` → core's default — so a single-language host writes one file and
  is done. Roots come from `config :phoenix_kit, template_paths:`, defaulting
  to the host application's `priv/phoenix_kit_templates`.

- **New dependency: `phoenix_kit_templates`.** A leaf package with no runtime
  dependencies of its own, which is what lets core depend on it rather than
  feature-detect it through a behaviour. `mix deps.get` after upgrading.

- **The new-login alert finally carries a link.** It had been telling readers
  to change their password immediately while giving them nothing to click — on
  the one email that reaches a genuinely compromised account.

- **Three templates that were looked up but never existed.**
  `new_login_alert` and `magic_link_registration` were both resolved by name
  and had no seeded template, so they always fell through to a hardcoded
  English string. Both now exist, as does `organization_invitation`, which had
  never been templated at all.

### Changed

- ⚠️ **Auth email wording changes for hosts with no database template.** Those
  installs were receiving the hardcoded English fallbacks; they now receive
  core's Gettext defaults in the recipient's language. This is the point of
  the release, but it is visible — someone will notice their confirmation
  email reads differently. **Hosts with customized database templates see
  nothing change**: that layer still wins, deliberately, and will keep winning
  until an export task ships and operators have moved their edits to files.
  Removing it now would silently revert every customized message.

- **Notification text is translated.** `Notifications.Render` held 21
  hardcoded English literals — the text of every notification reaching the
  inbox, Telegram, the email channel and any future push. `Channel`'s own
  moduledoc had named the hole: the envelope carried `:locale` "but the core's
  built-in rendering is English today". It no longer is. `render/2` installs
  the recipient's locale for the lookup; a `nil` locale still means "leave the
  current locale alone", which is what the admin inbox wants — it renders in
  the viewer's language, not a recipient's.

  Three strings that concatenated a detail onto a translated stem ("Your email
  was changed" + " to x") became two complete msgids each. A suffix cannot be
  reordered, and several languages need the detail somewhere other than the
  end.

- 38 new msgids, translated into all seven locales. Five of them arrived from
  `gettext.merge` carrying a translation matched from a *different* msgid —
  `"New notification."` had inherited the translation of "My notifications" in
  every locale, and `"Confirm your account"` had inherited "Confirm **my**
  account". Gettext compiles and serves fuzzy entries, so all five were
  rewritten by hand.

### Fixed

- **Batch settings writes could deadlock.** The settings history added in this
  release reads each key `FOR UPDATE` inside the write's transaction, and the
  batch path took those locks in `Enum.reduce` order over a map. Erlang map iteration is not a stable total
  order — a map of 32 keys or fewer is a flatmap iterated in term order, a
  larger one is a hashmap iterated in hash order, and the same two keys come
  out reversed between them. Two concurrent `update_settings_batch/2` calls
  sharing keys, one small and one large, would take them in opposite orders
  and deadlock. Keys are now sorted before the reduce, so every batch acquires
  in the same order whatever its size.

- **`ModuleRegistry.not_installed_packages/0` advertised an installed
  package.** It derived "installed" from module discovery alone, which only
  finds packages implementing the `PhoenixKit.Module` behaviour — so an
  infrastructure dependency that implements none looked absent, and the admin
  Modules page would have offered `phoenix_kit_templates` as available to
  install while it was already a transitive dependency of core. It now also
  consults loaded applications; neither check subsumes the other.

- The notification delivery and digest workers each carried their own
  identical private copy of the recipient-locale resolution, and a third was
  about to be written. All three now share one.

## 2.15.1 - 2026-09-05

### Added

- **A B2B site can stop asking whether an account is personal.** With
  organization accounts on, the signup page has always shown a Personal /
  Organization picker — a dead question on a site where every account is a
  company. A new **Account types on the signup page** setting
  (`registration_account_type`, on `/admin/settings/users` beside the feature
  switch) takes three values:

  | Mode | Signup page |
  |---|---|
  | `"choice"` | the picker, as before — the default, and what every existing install keeps |
  | `"person"` | no picker; organizations exist, but only an admin creates them |
  | `"organization"` | no picker; Organization Name required, and staff join by invitation |

  `Auth.registration_account_type/0` collapses this with the master switch, so
  one call answers "what may this form create?" — it returns `"person"`
  whenever organization accounts are off.

  The magic-link completion form honours the same policy: it has no picker, so
  it grows the Organization Name field (and drops first/last name, which an
  organization has neither of) exactly in `"organization"` mode.

### Fixed

- **The account type was never enforced server-side.** `registration_changeset/3`
  casts `account_type` and `organization_name` straight from the payload, and a
  `phx-submit` payload is whatever the client sends — so a forged
  `user[account_type]=organization` created an organization account on a site
  with organization accounts **switched off entirely**, where the picker had
  never been rendered. Both public forms now pipe their params through
  `Auth.enforce_registration_account_type/2` inside their field allowlist, the
  same arrangement that makes `remember_me_enabled` hold at the cookie writer.
  In `"choice"` mode an unknown string normalises to `"person"` rather than
  reaching the insert and coming back as a CHECK-constraint 500.

- **An organization invitation no longer offers "Organization".** A visitor
  registering from an invitation link saw the full picker, and choosing
  Organization created a *second* organization — which cannot hold an
  `organization_uuid`, so the invitation could never be redeemed. The
  invitation now pins the signup to a person account, on the page and in the
  payload.

## 2.15.0 - 2026-09-05

The deprecated user dashboard stops being routed by default, and the admin area
gets a name of its own — one that a host can change without giving up
translation.

⚠️ **Two behaviour changes for existing hosts**, both covered below:
`:user_dashboard_enabled` now defaults to `false`, so `/dashboard` stops routing
for anyone who never wrote the key; and a host already running a renamed
`:admin_path` that matches a preset will see its header wording change to match
the URL. Neither deletes anything — one config line restores either.

### Added

- **The admin area can be called something else, and stay translated.**
  Ten built-in names — Admin Panel, Dashboard, Backoffice, Console, Control
  Panel, Workspace, Portal, My Account, Management, Studio — each a real
  `gettext/1` msgid translated into all seven shipped locales. A host picks
  one and a German visitor still reads "Arbeitsbereich" where an English one
  reads "Workspace":

      config :phoenix_kit, admin_panel_label: :workspace

  **Unset, the name is derived from `:admin_path`**, so renaming the URL renames
  the wording with it and the two cannot drift:

      config :phoenix_kit, admin_path: "/backoffice"
      # URL /backoffice, header "Backoffice" — one key, both aligned

  `-` and `_` are equivalent in the segment, and a segment matching no preset
  (`/x7q`, or any deliberately obscure rename) keeps the translated "Admin
  Panel" rather than inventing a label out of the URL.

  A free-text string still works — `admin_panel_label: "Acme HQ"` — as the
  escape hatch for a brand name no preset covers. ⚠️ It is **not** translated:
  one string, shown to every visitor in every language. That is exactly why the
  presets exist, and why neither form is an operator field on
  `/admin/settings`: `config.exs` puts the tradeoff at the point of the
  decision, and keeps the wording next to `:admin_path`, which is compile-time
  config for the same reason.

  Resolution is `PhoenixKit.Config.admin_panel_label/0` → `{:preset, atom}` or
  `{:custom, binary}`, rendered by the new
  `PhoenixKitWeb.Components.Core.AdminLabel`. Both the header chip and the
  account-menu admin entry go through it, so they cannot disagree. Unlike
  `:admin_path`, an unrecognised value here **falls back rather than raising** —
  this is cosmetic, and a typo must not take the admin area down in production
  — but it logs once, naming the valid presets, so the fallback is not silent.
- **`mix phoenix_kit.install` / `.update` write the naming options into the
  host's `config/config.exs`, commented out.** A closed vocabulary of atoms is
  not something a developer can guess, and neither of the places it was first
  written down reaches them: the settings page is read by operators who cannot
  act on it, and a CHANGELOG is read once. The block puts the whole list — each
  preset, what it reads as, and the `admin_path` it pairs with — in the file
  they open to make the change.

  Every line is a comment, so the block is inert: it cannot execute, cannot
  conflict, and does not care where in the file it lands, which is what makes
  appending it after `import_config` safe. A test asserts that property
  directly, and a second walks `admin_label_presets/0` so a preset added
  without its comment entry fails the suite instead of raising partway through
  somebody's install. Idempotent on a marker, and skipped entirely once the
  host has an uncommented `admin_panel_label:` — at that point they have made
  the choice the block exists to explain.

  With the list living there, the settings-page description shortened to point
  at it rather than reciting ten names to an audience that cannot use them.

### Changed

- **The "Admin Panel" settings field says where the label appears and how to
  change the wording.** The checkbox now reads *Show the "Admin Panel" label in
  the admin header* rather than leaving the location to the description, and
  the description no longer repeats it. It also no longer says the wording
  "has no setting" — it lists the built-in names and points at `admin_panel_label`,
  and notes that renaming the URL with `admin_path` picks the matching name on
  its own. Both strings translated in all seven shipped locales.
- **`:user_dashboard_enabled` now defaults to `false` — the user dashboard is
  retired from core's defaults.** `/dashboard`, `/dashboard/settings` and the
  confirm-email compat redirects are no longer routed unless a host asks for
  them. Its job has moved into `/admin`, which shows each visitor the sections
  their permissions allow and greets a permission-less visitor rather than
  bouncing them (`PhoenixKitWeb.Users.Auth.landing_view?/1`). Together with the
  widget change below, nothing in core links to `/dashboard` any more.

  ⚠️ **Breaking for a host that never wrote the key** — it took the old default
  without choosing it, and `/dashboard` stops routing on the next compile.
  `mix phoenix_kit.update` now says so, and says the one line that keeps it.

  **Nothing has been deleted.** The LiveViews, the layout, the sidebar, the tab
  machinery and the route macros are all still there, so this is a switch and
  not a removal:

      config :phoenix_kit, user_dashboard_enabled: true

  restores the routes unchanged. That is only true because of the next item.
- **`user_dashboard_enabled` is now tracked by `__mix_recompile__?/0`.** It is
  read at macro-expansion time by the route macros, exactly like `admin_path`,
  so the compiler had no idea the host router depended on it — and it was not
  in the recompile check. A host flipping the flag would have kept serving a
  router compiled against the old value until something unrelated forced a
  recompile. The setting only became worth having as a real switch once the
  default flipped, which is what surfaced this.
- **`/dashboard` is no longer a reserved `admin_path` segment while the user
  dashboard is off.** `@admin_path_collisions` refused it unconditionally
  because core declared a route tree there; with `user_dashboard_enabled: false`
  nothing occupies it, so `config :phoenix_kit, admin_path: "/dashboard"` is now
  legal — the rename a host retiring the user dashboard is most likely to want.
  Turning the dashboard back on puts the segment back in the list and the next
  compile raises, rather than letting whichever tree the router declared first
  silently win.
- **The deprecation notices split by what the host actually configured.**
  `mix phoenix_kit.install` no longer warns about a dashboard a fresh install
  does not have. `mix phoenix_kit.update` prints the deprecation heads-up only
  to a host that switched the dashboard **on**, the new default-changed notice
  to a host that never wrote the key, and nothing to a host that chose `false`
  — via the new `PhoenixKit.Config.user_dashboard_configured?/0`, which
  distinguishes "took the default" from "chose false" (`user_dashboard_enabled?/0`
  answers `false` to both).
- **The session widget's user-facing entry now leads to the admin area, not the
  deprecated user dashboard.** `PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1`
  — the avatar dropdown a host embeds in its own header — rendered a "Dashboard"
  item pointing at `/dashboard` for every signed-in visitor, and was the one
  place in core that did **not** gate that link on
  `PhoenixKit.Config.user_dashboard_enabled?/0`. Every other call site does
  (`auth_router.ex`, both route macros in `integration.ex`,
  `NotificationsBell.default_link/1`, the `AdminNav` divider), so a host that
  compiled the dashboard out was left with a menu entry that 404s.

  Every signed-in visitor now gets exactly **one** entry leading to
  `Routes.path("/admin")`, which is the page core declares unconditionally and
  admits every authenticated visitor to — `PhoenixKitWeb.Users.Auth.landing_view?/1`
  exempts the index from the admin-area gate, and it shows a permission-less
  visitor the welcome block and nothing else. An admin-area holder sees it as
  "Admin Panel" with a shield; everybody else sees "My Account" with a house.
  The two are mutually exclusive and take their wording from one private
  `admin_entry_label/1`, so the pair cannot drift.

  Because the destination is built with `Routes.path("/admin")`, it picks up a
  renamed admin segment (`config :phoenix_kit, admin_path: "/myaccount"`) for
  free. Note that `admin_path: "/dashboard"` is still refused — `dashboard` is
  on `@admin_path_collisions` for as long as core declares the `/dashboard`
  route family.

  The `:dashboard` key in the `:authenticated_links` attr keeps its name and
  its place in the default list, so a host passing an explicit list needs no
  edit; only where it points has changed. Wording stays `gettext/1` on both
  arms rather than becoming an operator-typed setting, for the reason
  `LayoutWrapper` already gives for the "Admin Panel" chip: a stored string
  would serve one language's wording to every locale. `"My Account"` is
  translated in all seven shipped locales.
- **The context-switch fallback redirect points at `/admin`.**
  `PhoenixKitWeb.Controllers.ContextController` string-built
  `"#{url_prefix}/dashboard"` for requests arriving with no usable referer —
  the same dead destination, reached by exactly the visitors who got there by
  accident. It now goes through `Routes.path("/admin")`, so it also honours a
  renamed admin segment instead of concatenating the URL prefix by hand.

### Fixed

- **Menu links no longer emit a locale segment the router immediately redirects
  away from.** `user_dropdown/1` passed `@current_locale` straight into
  `Routes.path/2` and `Routes.user_settings_path/1`. That assign is the
  **gettext dialect** (`"en-US"`); URLs are served on the **base** code
  (`"en"`), as `PhoenixKitWeb.Users.Auth.validate_and_set_locale/2` documents.
  `Routes.path/2` takes `:locale` verbatim, so a visitor on `/en/profile/settings`
  was offered `/en-US/…` links — which route, then bounce through a redirect to
  `/en/…`. Worse, `default_locale?/1` compares against the base default, so
  `"en-US" != "en"` also defeated prefixless-primary and produced a locale
  segment where there should have been none. Both links now go through the
  normalising helpers (`Routes.locale_aware_path/2` /
  `locale_aware_user_settings_path/1`) that the multi-session forms three lines
  below were already using. Same slip fixed in the modules page's "Configure"
  link for crawler settings.
- **The dropdown's active-item highlight survives a renamed admin segment.**
  `active_path?/2` compared the real request path against the `/admin` written
  in the markup without canonicalising, so under `admin_path: "/myaccount"`
  nothing ever highlighted. It now folds the configured segment back through
  `Routes.canonical_admin_path/1` first.

## 2.14.2 - 2026-09-05

PR #783 — annotations stop requiring a file to anchor to — plus the two fixes
from its review.

### Added

- **An annotation anchors to a TARGET, not necessarily a file** (#783, V183).
  Every row pointed at `phoenix_kit_files` through a `NOT NULL file_uuid`,
  which is right for the media viewer and wrong for a whiteboard with no image
  — the projects module was minting a solid-white PNG per board just to have
  something to draw over. `target_type` + `target_uuid` (Etcher's own
  vocabulary) are now the anchor: a `"file"` target still carries its file in
  both columns, so every file-side feature keeps its hard FK, and any other
  target carries no file at all. A CHECK pins the two shapes and the changeset
  mirrors it, so a bad shape is a changeset error rather than a constraint
  exception. Existing rows are backfilled and unchanged in meaning.

  ⚠️ `down/1` **deletes non-file annotations** — they have no home in the old
  shape. Back the table up first if a rollback is not final.

- **Modal drawers and a client-side close guard** (#783). `<.modal placement={:end}>`
  is a full-height sheet sliding in from the edge for tall forms;
  `close_guard={:input}` makes Esc and the backdrop no-ops from the first
  keystroke in a submittable form inside it, before the server has heard of the
  edit — the round trip plus any `phx-debounce` window would otherwise let a
  quick Esc discard what was just typed. Never latched: once the server
  re-renders, `closeable` is the only authority again.

- **`<.nav_tabs>` gains a `:trailing` slot** and the admin header a page
  toolbar beside the title (#783).

### Fixed

- **`PkUrlMirror` accepted network-path references and fragments** (#783). The
  root-relative check took `//host` and `/\host` — same-origin-looking,
  other-origin-going — and any fragment, which the comparison against
  pathname + search never sees, so `/p#x` re-fired on every update. Same guard
  shape as `Routes.local_path?/1`; control characters refused too.

- **`target_type` was only validated in the Etcher adapter** (review of #783).
  The adapter checked the format before building attrs; the changeset did not.
  The adapter is not the sole writer — `Annotations.create/1` is public and is
  the path a board takes — so a `target_type` over 32 characters reached
  `character varying(32)` and came back as a raw Postgres error, the exact
  failure `validate_target/1` exists to prevent one field over. The regex moved
  onto the changeset and the adapter now reads it from
  `Annotation.target_type_format/0`, so the two answers cannot drift.

- **V183 checked constraint existence with `::regclass`** (review of #783),
  which the prefix rules forbid — the cast raises rather than answering false
  when the relation is absent, aborting the whole transaction. Replaced with
  the mandated name-based `pg_class` + `pg_namespace` JOIN, as V180 does. It
  could not bite (V135 creates the table at the migration floor), but V183 is
  the newest migration and therefore the template the next one is copied from.
  Amended in place rather than superseded, since V183 has never shipped.

## 2.14.1 - 2026-09-05

Fixes found by running 2.14.0 against a real install: a dashboard statistic
that could only ever report the wrong number, two timezone consumers left
behind when the picker moved to IANA identifiers, and every statistic on the
dashboard becoming a link to the list behind it.

### Added

- **`TimeZone.offset_seconds/2` and `TimeZone.day_start/2`.** The first gives
  the offset for either kind of stored value — a legacy `"2"` or an IANA id
  resolved at an instant, since `Europe/Warsaw` has no single answer. The
  second gives the UTC instant at which the current day began somewhere, for
  "how many X today" where *today* is the operator's day. Both are what the two
  fixes below needed and neither had.

- **Every number on the admin dashboard is now a link to the report behind it.**
  A statistic you cannot drill into is a dead end: seeing "29 Active Sessions"
  and having no way to ask *which 29* is what sent one operator to the Live
  Sessions page to reconcile it by hand. All sixteen cards across Platform
  Statistics, Active Sessions, Real-Time Activity and the user-status row now
  navigate to a filtered list.

  Five of them had no report to point at, so the filters came first rather than
  linking at a list that could not contain the counted rows:

  - `Auth.list_users_paginated/1` gains `:status` (`active` / `inactive`) and
    `:confirmation` (`confirmed` / `pending`), deep-linkable as `?status=` and
    `?confirmation=` and surfaced as two dropdowns on `/admin/users` — a filter
    with no visible control would leave a visitor arriving from a card looking
    at a filtered list with nothing on screen saying why.
  - `Sessions.list_active_sessions/1` takes a scope — `:active` (the default,
    so existing callers are unchanged), `:today` and `:expired` — deep-linkable
    as `?scope=` with a matching selector on `/admin/users/sessions`.

  The predicates are deliberately identical to the ones
  `Roles.get_extended_stats/0` and `Sessions.get_session_stats/0` count with,
  and a test file asserts each card's number against its own link's result
  rather than either in isolation. Unknown values (`?status=nonsense` from a
  hand-edited URL) fall back to unfiltered rather than to an empty list, which
  would read as "you have no users".

  `StatCard` and `HeroStatCard` gain an optional `navigate` attr; without it
  they render exactly as before.

### Fixed

- **"Unique Users" counted session rows, not people.** `get_session_stats/0`
  asked for `Repo.aggregate(query, :count, :user_uuid, distinct: true)`, but
  `aggregate/4`'s last argument is REPO options — `:prefix`, `:timeout` — and
  `Ecto.Repo.Queryable.query_for_aggregate/3` builds the select from the field
  alone and never sees them. `distinct: true` was accepted and silently
  ignored, so the card reported one "unique user" per session row and was equal
  to "Active Sessions" by construction. Reported from a live install showing 29
  unique users against 2 registered accounts.

- **"Active Sessions / Currently logged in" invited exactly that confusion.**
  The number counts session tokens inside the 60-day validity window across
  every device, so one person who has signed in 29 times over two months is 29
  — while the Live Sessions page, which reads Presence, correctly showed one.
  The subtitle now reads "Unexpired sign-ins, not live connections".

- **"Today's Sessions" counted UTC's day, not the operator's.** `get_session_stats/0`
  took midnight from `DateTime.utc_now()` and ignored the `time_zone` setting
  entirely, so on any site east of UTC every sign-in after 21:00 local (UTC+3)
  fell into "yesterday" — the card read 0 while somebody was signed in. Both it
  and the new `:today` session scope now start the day in the configured zone.

- **`Utils.Date.offset_to_seconds/1` returned 0 for every named timezone.** It
  was `Float.parse/1`, which cannot read `"Europe/Warsaw"` — and since the
  timezone picker moved to IANA ids, that is what the setting holds on any site
  that has touched it. Every caller was therefore computing in UTC without
  saying so. It now delegates to the new `TimeZone.offset_seconds/2`.

  ⚠️ **This one reaches outside core.** Three call sites in module packages take
  that number as gospel and were silently off by the site's whole offset:
  `phoenix_kit_bookings`' `site_offset_seconds/0` (availability windows),
  `phoenix_kit_calendar`'s `window_bounds/3` (timed events near midnight fall
  out of the day the grid puts them in) and its `tz_differs?/2` (two different
  named zones compared equal, so "show in their timezone" saw no difference).
  The first two are corrected by this delegation; `tz_differs?/2` should move to
  `TimeZone.effectively_same?/2`, which answers the question it is actually
  asking.

## 2.14.0 - 2026-09-05

The admin area stops being nailed to `/admin`, the deprecated user dashboard
stops being promoted from core's own defaults, and the admin sidebar gains a
collapsed icon rail with hover flyouts.

### Security

- **`mint` 1.9.3 → 1.10.0**, clearing two advisories the release gate refused
  to publish over: EEF-CVE-2026-82728 (HIGH — unbounded HTTP/1 status-line and
  chunk-extension buffering, memory-exhaustion DoS) and EEF-CVE-2026-82729
  (MEDIUM — quadratic chunk-size parsing in `Mint.HTTP1.Parse`, CPU-exhaustion
  DoS). Transitive, via `finch`, `swoosh` and `tz`; every constraint on it
  already allowed 1.10.0, so this is a lockfile move with no API change.

### Added

- **The admin area's URL segment is configurable.**

      config :phoenix_kit, admin_path: "/backoffice"

  moves the whole admin surface inside the mount prefix — `/phoenix_kit/backoffice/users`
  — for hosts that would rather not show end users a URL that reads as somebody
  else's admin panel. Independent of `:url_prefix`, which names the mount
  itself. Compile-time, so it belongs in `config.exs`; `phoenix_kit_routes()`
  folds it into `__mix_recompile__?/0`, so changing it re-expands the host
  router instead of leaving it serving the old segment. Default `"/admin"`
  produces a byte-identical route table, so an existing install is untouched.

  **`/admin` remains the canonical name in code.** Nothing in core or in a
  module package is written against the configured value — call sites keep
  saying `Routes.path("/admin/users")`. The substitution lives in two inverse
  functions: `Routes.apply_admin_segment/1` when a URL is emitted (reached from
  `Routes.path/2`, `Routes.admin_path/2`, and the router's own route table),
  and `Routes.canonical_admin_path/1` when one is read back (tab active state,
  the admin nav parser, `LayoutWrapper.admin_page?/1`, the language switcher).
  A module package therefore needs **no changes at all** to honour a rename:
  its tabs are declared with relative paths and its links go through
  `Routes.path/1`.

  The route table is rewritten once, on the assembled AST of
  `phoenix_kit_admin_routes/1` — the single point where core's own table,
  `:admin_dashboard_tabs` entries, plugin views and a package's `admin_routes/0`
  all converge. So the rewrite reaches packages compiled long before the option
  existed, and cannot be forgotten by the next route added to the table.

  The value is validated (exactly one lowercase path segment, and not one of
  the segments core already declares — `users`, `profile`, `dashboard`, `api`,
  …) and raises rather than producing a router that compiles and then 404s.

- **The admin sidebar collapses to icons.** A toggle at the foot of the menu
  narrows it to a 5rem icon rail; the label of each item moves to a hover
  tooltip, group headings and subtab lists fold away, and the choice is
  remembered per browser. Desktop only — below `lg` the sidebar is an overlay
  drawer that is already absent until summoned, so narrowing it buys nothing
  and costs the labels.

  **Entirely client-side, and deliberately so.** The sidebar is a *function
  component*, not a LiveView: there is no `handle_event/3` owner for a
  `phx-click`, and giving one to every admin page (or bolting a global
  `attach_hook` onto the admin `on_mount` chain) is a lot of machinery for a
  display preference. It is also a per-browser density choice, like the theme,
  so it lives in `localStorage` beside it rather than in a settings row — and a
  client toggle costs no round trip and gives morphdom nothing to fight over,
  since the DOM is identical either way and only `<html>` changes.

  That makes the first paint the whole problem, which is why the stamp is a
  synchronous inline `<script>` rendered immediately above the sidebar rather
  than a hook in `phoenix_kit.js`: it has to run before the menu is parsed or a
  viewer who chose compact gets a frame of the full-width sidebar on every
  load, and it must not depend on the host having re-run
  `mix phoenix_kit.update` to refresh its vendored bundle. Same shape, and the
  same one-instance guard, as `PhoenixKitWeb.Components.ThemeBootstrap`.

  **Hovering a rail icon opens a flyout** naming that entry and listing its
  children. It is rendered for every navigable top-level entry, not only the
  active one: `subtab_display` defaults to `:when_active`, so the inline subtab
  list exists only for the section you are already in — precisely the browsing
  an icon rail otherwise loses.

  Built on the `popover` API, which earns its place three times over. The top
  layer escapes the sidebar's own `overflow-y: auto` clipping — an absolutely
  positioned panel is cut off at the rail's edge, which is what would have made
  a plain CSS flyout (and the hover tooltip this replaces) unusable.
  Light-dismiss and Esc come free. And only one `popover="auto"` can be open,
  so moving between icons closes the previous flyout with no bookkeeping.
  Positioned against the viewport on open, clamped so a section near the bottom
  of a long menu does not open past the fold.

  Touch is handled rather than assumed: with no hover available, a tap on a
  rail icon opens its flyout instead of navigating, so a touch user on a wide
  screen (a convertible laptop, a tablet in landscape — the rail is `lg`-only)
  can still reach a subtab. Keyboard works because the panel sits immediately
  after its link in the DOM: the top layer changes painting, not the tree, so
  Tab walks straight into it.

  The collapsed rail **marks where you are with a right-edge bar over a light
  primary tint**, rather than the filled block the expanded menu uses — at 5rem
  a solid primary slab is most of the row and reads as a state rather than a
  marker. The tint is `color-mix`-based and preceded by a plain `transparent`
  declaration, so a browser without `color-mix` keeps the bar-only rendering
  rather than the block. Two cases both get it:
  the entry that IS the current page, and the section that merely contains it.
  The second needed new information — expanded, that highlight sits on the
  active subtab, and compact mode hides the subtab list, so the parent now
  states the fact (`data-pk-branch-active`) and the rail's CSS paints it. The
  flyout keeps the ordinary filled highlight; it is a wide panel with text,
  where the block is right.

  Accessibility: labels are visually hidden (`clip-path`), never
  `display: none`, so every link keeps its accessible name and the collapsed
  menu still reads correctly to a screen reader. The toggle carries
  `aria-expanded` and swaps its own `aria-label` with the state.

- **The "Admin Panel" label in the admin header can be turned off.** New
  `show_admin_panel_label` setting (Site Identity, `/admin/settings`), on by
  default — the row is absent on every existing install and
  `get_boolean_setting/2` answers `true`, so nothing changes until an operator
  says so. Off renders just `Project name / Page`.

  **A switch rather than a title field, deliberately.** The obvious version —
  let the operator type their own label — cannot work here: the wording is
  `gettext("Admin Panel")`, already translated in all seven shipped locales,
  and an operator-typed string is one language. A German operator's "Adminbereich"
  would be served to English and Russian visitors too. `project_title` gets away
  with being a plain string because a project name is a brand; "Admin Panel" is
  a common noun phrase. So the setting controls whether the translated string
  renders, not what it says.

  The label also stays subject to the permission gate it already had: it is
  hidden for a visitor holding no admin rights whatever the setting says, since
  `/admin` is the landing every authenticated user can reach and telling
  someone with no sidebar that they are in the "Admin Panel" is the one claim
  on the page that would be false. `<LayoutWrapper.app_layout>` gains a
  matching `show_admin_panel_label` attr — `nil` reads the setting — so the
  header stays renderable, and testable, without a database.

  Unrelated and unchanged: the browser tab still reads `<project> Admin`
  (override it with the existing `default_tab_title` setting), and
  `config :phoenix_kit, project_title_suffix:` still applies only to the user
  dashboard layout, never to the admin header.

- **`Routes.admin_area_path?/1` is now public** — "does this REAL URL land in
  the admin area?", asked of the shape a `?return_to=`, a saved setting or an
  HTTP referer actually has: mount prefix on, locale segment optional. An audit
  of the 39 `phoenix_kit_*` packages found the gap it fills. Of 897 `"/admin"`
  literals across 32 of them, all but one are canonical inputs that the
  emit/read pair already handles — but `phoenix_kit_entities` allowlists a
  client-supplied `_live_referer` with `String.contains?(path, "/admin/")`,
  because core exposed nothing better. That hand-rolled form claims
  `/administrators`, claims a host's own page at `/shop/admin`, and silently
  matches nothing once the admin area is renamed. Pair it with `local_path?/1`
  when the path came from a client — that is the one that rejects `//evil.com`
  and ASCII control characters. Behaviour is unchanged; only the visibility and
  the docs are new.

### Fixed

- **The custom-admin-pages guide taught hosts to hardcode `/admin`.** Its
  worked example used a plain `<.link navigate="/admin/blog/new">`, which
  ignores `url_prefix` (so it was already broken on every install that changed
  the mount) and now `admin_path` too. Switched to `<.pk_link>`, with the
  import the example was missing.
- **`/admin` prefix tests were not segment-aware.** `Routes`' internal
  `admin_path?/1` and the language switcher's admin branch used
  `String.starts_with?(path, "/admin")` / `String.contains?(path, "/admin")`,
  which also claimed `/administrators` and a host page at `/shop/admin`. Both
  now compare whole segments. Cosmetic before — a link built through the wrong
  branch still resolved — but not once a rewrite started acting on the match:
  `/administrators` would have become `/backofficeistrators`.

### Changed

- **The default notification click-through no longer points at the deprecated
  user dashboard.** `notification_default_link` — the catch-all destination for
  a notification carrying no `notification_link` of its own — shipped with
  `/dashboard` as its built-in default, prefilled in the "Default notification
  link" field on `/admin/settings` and described there as the page "every
  signed-in user can reach". That page is deprecated
  (`PhoenixKit.Install.Deprecations.user_dashboard_warning/0`; `phoenix_kit.install`,
  `.update` and `.doctor` have been announcing its removal), and a host can
  compile it out today with `user_dashboard_enabled: false` — so core was
  steering every new install toward a surface it is asking them to leave, and
  the field was the one place an operator would read that recommendation as
  official. The default is now `/admin`, which core declares unconditionally and
  admits **every** authenticated visitor to: `PhoenixKitWeb.Users.Auth.landing_view?/1`
  exempts the admin index from the admin-area gate, so a recipient holding no
  permissions is greeted rather than bounced. That is the same page
  `PhoenixKit.Utils.Routes.safe_destination/2` already terminates on for exactly
  this reason. Hosts that saved `/dashboard` into the settings row while it was
  the prefilled value are unaffected — that value is still honoured, still
  guarded against `user_dashboard_enabled: false`, and can be cleared or
  repointed from the same field.
- **`mix phoenix_kit.gen.user.dashboard` now carries the deprecation notice** it
  generates into. The task writes a page onto the deprecated user-dashboard
  surface, and a host that only ever runs generators never saw the heads-up that
  `install` and `update` print. It is now emitted as an Igniter warning on every
  run and summarised under `--help`, which points at `mix phoenix_kit.gen.admin.page`
  for new work. Advisory only — nothing generated changes, and existing pages
  keep working.
- Documentation examples for `<.pk_link>` / `<.pk_link_button>` and the URL-prefix
  section of `CLAUDE.md` used `/dashboard` as their canonical path; they now use
  `/admin`, so the snippet a developer copies is not the deprecated one.

## 2.13.19 - 2026-09-02

Checkbox alignment (PR #779) and a Git Hooks doctor check that tests the
property it actually cares about (PR #778), plus the post-merge review fixes
for #779
(`dev_docs/pull_requests/2026/779-checkbox-first-line-centering/CLAUDE_REVIEW.md`)
and the catalogue sweep that closes 2.13.18's translation backlog.

### Fixed

- **Described checkboxes sat 2px below their own label.** `<.checkbox>` nudged
  the box down with a fixed `mt-0.5` whenever a `<:description>` was present.
  That constant was tuned for `checkbox-sm`; the default box is 24px and the
  label's line is `leading-6` — also 24px — so the nudge was pure error, and
  `checkbox-xs` was off by a different amount again. The input now sits in a
  `h-6` flex wrapper that centers **any** checkbox size against the first text
  line, and picks up `shrink-0` for every caller instead of only the ones that
  remembered to pass it. The three storage-settings checkboxes that were
  hand-compensating with `class="mt-0.5 flex-shrink-0"` drop their nudges.
- **The notification-preferences form kept a hand-rolled copy of that bug.**
  `Live.Components.UserSettings` built its own `<label>` + `<input>` + text
  block with an `mt-1` nudge on a `checkbox-sm` — 4px of the same error, and
  exactly what `<.checkbox>` exists to prevent. Converted to the component,
  with the description slot guarded by `:if` so preference types without one
  still center. Post-merge review of #779.
- **`mix phoenix_kit.doctor` reported a working Git Hooks setup as broken.**
  The check compared `core.hooksPath` against the literal string `.githooks`,
  so pointing it at any other directory produced a warning — with a "fix" that
  told the reader to point somewhere unrelated to why. It now checks the
  property git actually uses: whether the configured directory holds an
  executable `pre-commit`. `.githooks` is only this checkout's convention.

### i18n

- **Every catalogue is complete again — and 175 entries were serving the wrong
  string.** The de/es/fr/it/pl `default` catalogues each carried 212
  untranslated msgids (the backlog 2.13.18 recorded); all 212 are now
  translated by hand in all five, so all seven translated locales sit at 0
  untranslated across `default`, `errors` and `phoenix_kit`.
- **Cleared every `fuzzy` flag, which was not cosmetic.** Elixir Gettext
  *compiles and serves* fuzzy entries — the flag is only a translator hint —
  so 33 entries per Western locale (and 5 in ru/et) were shipping a
  translation gettext had carried over from a different msgid: "Add a country"
  rendered as *Add account*, "Search countries…" as *Search files…*, "Bedrock
  error %{status}" as *Brevo error*, "Crawler Settings" as *Legal settings*,
  "Verification" as *Notifications*, "Check your timezone" as *Check your
  inbox*. All 175 rewritten against the msgid they actually belong to.
  `en` had one too — "Sign in to request access." was served as *Sign in as
  user*; emptied, so it falls back to the msgid as every other `en` entry
  does, and its 41 inert flags went with it. `grep -c fuzzy` is now 0 across
  `priv/gettext`, which makes a non-zero count a real signal again.
- Line references re-extracted and merged (`mix gettext.extract` +
  `mix gettext.merge`, reported as *0 new, 0 removed, 0 reworded* for every
  locale) after 2.13.18's digest changes shifted them.

## 2.13.18 - 2026-08-31

Dialog layering, component-scoped pushes and an image-quality sweep (PR #777),
plus the post-merge review fixes for each
(`dev_docs/pull_requests/2026/777-pkdialog-esc-layering-component-routing/CLAUDE_REVIEW.md`)
and the igniter-recovery work on the install/update tasks.

### Fixed

- **Esc closed both popups when one dialog was stacked inside another.**
  Chromium groups the close watchers of dialogs whose `showModal()` ran
  without user activation - which is every dialog LiveView opens from a patch
  - so a single Esc fired `cancel` on the whole stack. `PkDialog` now keeps
  the outer dialog open and relays the request to the deepest stacked child in
  its own semantics; `preventDefault` alone was not enough, since Chromium
  stops the grouped chain at the first prevented watcher and the child's own
  cancel then never fired. Openness is matched with `:modal`, not the `open`
  attribute, which morphdom can strip between a patch and the next sync.
- **A component-owned modal's close event landed on the host LiveView.**
  `pushEventTo` with an element resolves the target from that element's
  `phx-target`, which a `<dialog>` does not carry, so the push fell through to
  the LiveView: the item selector's stacked details popup never closed on Esc,
  and the selector itself only "closed" because the misrouted event hit the
  host. Both `PkDialog` and `InfiniteScroll`'s load-more sentinel (useless
  inside a LiveComponent for the same reason) now push to the owning
  component by numeric CID, through one shared helper that stops its search at
  a nested LiveView root - a component on the far side of one belongs to a
  different view, and its CID means nothing to the pushing socket.
- **A stacked close could strand a dialog the server never heard about.** The
  parent marks the child it closed so the child's own `close` handler does not
  double-push - but that handler is exactly what was observed not to run in
  this stack, and the boolean marker then suppressed the child's *next*
  genuine close for the life of the element (the server kept believing it was
  open, and re-opened it on the following patch). The marker is now a
  timestamp with a one-second window, so a stamp whose event never arrives
  expires instead.
- **Tab matching broke on a query-carrying `current_path`.** Pages that
  publish their full URL into `:url_path` (so the language switcher can
  rebuild locale links without dropping state) handed `Tab.matches_path?/2` a
  path with `?…` attached, which no exact or prefix rule could match.
  `normalize_path/1` strips the query and the fragment; matching is about the
  path. `AdminNav.parse_admin_path/1` - the sidebar's own matcher, and the
  reason a highlighted tab could sit above an unhighlighted sidebar item -
  stripped only the query, and its `?tab=` extraction turned `?tab=files#top`
  into the tab `"files#top"`. Both now cut on `?` and `#`.
- **Card-size image slots served the smallest variant.** `resolve_url/2`
  preferred the 150px thumbnail over an 800px medium whenever `small` was
  missing, and an explicit `:medium` request preferred the thumbnail outright
  - the untyped clauses had the ordering inverted relative to the
  `file_type: "image"` clauses they mirror. The media selector's grid also
  asked for the default `:small` tier and stretched a 150px thumbnail across
  an aspect-square tile; it now asks for `:card`, as the media browser's own
  grid already did.
- **Digest notifications rendered in the server's locale, not the
  recipient's.** The digest strings were built with
  `Gettext.dgettext/3` - invisible to `mix gettext.extract`, so they had never
  been translated - and are now `gettext/2` calls that extract normally. That
  alone would not have reached anyone: `gettext/2` resolves the locale from
  the calling process, and an Oban worker starts on the default one, so the
  new translations would have rendered in English for every recipient. Both
  digest surfaces (the channel envelope, which already resolved the
  recipient's locale for the channel, and the persisted in-app inbox row) now
  build their text inside `Gettext.with_locale/3`. `%{label}` stays English:
  type labels are runtime registry data that extraction cannot see.

- **The installer's post-install steps never ran on the recommended entry
  point.** `mix igniter.install phoenix_kit` - the command this task's own
  help recommends - composes installers through
  `Igniter.Mix.Task.configure_and_run/3`, which invokes the task's `igniter/1`
  callback and nothing else. Everything parked in
  `Mix.Tasks.PhoenixKit.Install.run/1` after `super(argv)` was therefore dead
  code on that path: the interactive `mix ecto.migrate` prompt, the asset
  rebuild, and the database connectivity check. Hosts saw
  `• mix ecto.migrate` in the closing notice and were never offered the
  migration, and their assets were never rebuilt after the CSS/JS integration
  wrote to `app.css` and `app.js`. Those steps now ship as a queued
  `mix phoenix_kit.post_install` task (`Igniter.add_task/3`), which runs after
  changes are committed on **both** entry points - and is correctly skipped
  on `--dry-run`, where the old code would have migrated anyway. `run/1` no
  longer duplicates the work.
- **Two "PhoenixKit ready!" banners.** Igniter runs queued tasks before
  printing notices, so a successful migration announced readiness moments
  before the closing notice did. The migration path now reports what it did
  (and the resolved sign-up path) and leaves the banner to the notice, whose
  `mix ecto.migrate` step is marked as applying only if the prompt was
  skipped.

- **The daisyUI version warning accused healthy installs of a rendering bug.**
  `PhoenixKit.Install.DaisyUI.outdated_warning/1` fired below 5.6.0 but its
  copy described the pre-5.1 failure mode (phantom right-edge strip, ~15px
  content shift around modals), so every host in the 5.1-5.5 band - including
  a freshly scaffolded `mix phx.new` app, which vendors 5.5.19 - was told its
  modals were broken when they were not. New `severity/1` splits the two
  bands: `:broken` below `gutter_fix_version/0` (5.1.0, where daisyUI made
  the modal scrollbar gutter conditional) keeps the bug report; `:behind`
  gets an advisory heads-up that says nothing is broken. Unparseable versions
  take the benign branch. `mix phoenix_kit.doctor` makes the same split.
  The floor stays 5.6.0 - it is the release that finished the modal gutter
  fix (`scrollbar-gutter: auto`), not merely a recent tag.
- **Installer notices rendered as orphan `*` bullets.** Igniter renders each
  notice as a `* ` bullet, so the four notices whose heredoc opened with a
  blank line printed a bare `*` with the body pushed to the next line: the
  layout recompile notice, the CSS integration notice, the migration-ready
  notice, and the closing "PhoenixKit ready! Next:" block. All now trim, the
  way the Oban notice already did.
- **`PhoenixKit V2.13.17` read as a migration version.** A capital `V` prefix
  means a migration version in this codebase (`V181`), and the package
  version carried one on the line directly above `Target version: V181`.
  Lowercased.
- **Dropping igniter crashed the igniter tasks instead of explaining
  itself.** Igniter is an optional dependency, so `mix phoenix_kit.install`,
  `.update`, `.gen.admin.page` and `.gen.user.dashboard` are wrapped in a
  compile-time `Code.ensure_loaded?(Igniter.Mix.Task)` guard whose `else`
  branch prints the "add `{:igniter, "~> 0.7", only: [:dev, :test]}`"
  guidance. That branch is chosen when PhoenixKit is compiled into the host's
  `_build`, and PhoenixKit is not recompiled when the host's own dependency
  list changes - so a project that installed while igniter was on the path
  and later dropped it kept a beam that had taken the igniter branch, and got
  `** (UndefinedFunctionError) function Igniter.Mix.Task.help_requested?/1 is
  undefined` from the generated `run/1`. New
  `PhoenixKit.Install.MissingIgniter.ensure_available!/1` re-asks the question
  at the top of each task's `run/1`, so the guidance is printed whether the
  compiled branch was right or has since become a lie.

### Added

- **The igniter-backed tasks now offer to add the dependency instead of only
  naming it.** With igniter genuinely absent,
  `PhoenixKit.Install.MissingIgniter` prints what is missing and asks to write
  `{:igniter, "~> 0.7", only: [:dev, :test]}` into the host's `deps/0`
  (auto-accepted under `--yes`/`-y`), then shells out to `mix deps.get` - a
  fresh OS process, since the running one evaluated `mix.exs` at boot and
  cannot see the new dep. It stops there and names the one command to re-run:
  PhoenixKit itself has to recompile to pick the other side of its
  `Code.ensure_loaded?(Igniter.Mix.Task)` guard, which cannot happen inside a
  run that is already executing the wrong side. Declining, a MIX_ENV where
  `only: [:dev, :test]` would not help, an unrecognised `deps/0` (anything but
  the list shape the generators emit - it never guesses), or a failed fetch
  all fall back to the manual instructions, each carrying only the part that
  is still true - a declined prompt is not re-told what it just declined, and
  a failed fetch is not told to add a line that is already written.
- **The opposite staleness is diagnosed too.** A host that installed
  PhoenixKit *without* igniter and added it afterwards keeps the compiled
  stand-in task, so following its own advice appeared to change nothing.
  `stand_in_run/2` now notices that igniter is loadable and asks for
  `mix deps.compile phoenix_kit --force` rather than repeating the
  instructions the host already followed.

### i18n

- Russian and Estonian catalogues are complete again (ru: 82 untranslated →
  0), including the newly extractable digest strings. The refresh added 57
  msgids overall; de/es/fr/it/pl carry them untranslated (160 → 212) and fall
  back to the msgid, so nothing renders empty - those five still want a
  dedicated sweep.

### Changed

- **The install warning glyph is reserved for things that need attention.**
  The rate-limiter and Oban "configuration added" notices used `⚠️` (and, for
  Oban, `IMPORTANT: Restart your server`) for what is a routine config write
  - on a fresh install there is no server running, and the closing steps tell
  you to start one. They now use their modules' neutral glyphs with the
  restart advice as a parenthetical, correct on both the install and update
  paths. `⚠️` is left to the daisyUI and dashboard-deprecation advisories.

## 2.13.17 - 2026-08-30

Toolchain and test-fidelity release: PRs #773-#776, plus the post-merge review
findings for each (`dev_docs/pull_requests/2026/77{3,4,5,6}-*/CLAUDE_REVIEW.md`).

### Fixed

- **`mix format --check-formatted` was failing on Elixir 1.19.** A reformat of
  `phoenix_kit_doctor_test.exs` pinned one assertion to Elixir 1.18.4's
  line-breaking, which 1.19 undoes - so `mix quality.ci`, `mix precommit` and
  the CI format step were all red on `main` for anyone on 1.19, which
  `elixir: "~> 1.18"` admits. The assertion is now decomposed below the
  break threshold, so no formatter version has a decision to make: verified
  idempotent and byte-identical under 1.19.5 and 1.20.0-rc.6.
- **`.formatter.exs` excluded nothing.** The key was `exclude:`; Mix reads
  `:excludes` (plural, added in Elixir 1.19). `priv/templates` was skipped only
  because no `:inputs` pattern happened to reach it. Corrected to `excludes:` -
  note this filters `:inputs` expansion only, so `.claude/hooks/format-edited-file.sh`
  still needs its own explicit skip for `mix format <path>`.
- **The destructive orphaned-FK doctor test no longer needs superuser** (#774),
  and now proves the branch it was written for. Planting the orphan behind a
  re-added `NOT VALID` constraint routed it to `classify_fk_check/6`'s
  `:validate` clause - which predates the widening fix - instead of the
  `:validated` -> `:existing_orphan` clause that used to discard real orphans;
  the assertion could not tell them apart. It now defers the FK's referential
  check (`ALTER CONSTRAINT ... DEFERRABLE INITIALLY DEFERRED`, plain
  table-owner DDL) so the constraint stays validated, and asserts both
  `convalidated` and the `:existing_orphan` wording.

### Changed

- **The git-guard hook fails closed, and says why** (#773). A missing `jq`,
  malformed JSON, or an absent `.tool_input.command` all used to leave the
  command empty and fall through to `exit 0`. They now block - and, unlike the
  merged version, write a reason to stderr, where a `PreToolUse` hook's exit 2
  actually surfaces it; a missing `jq` is named explicitly, since otherwise it
  silently blocks every Bash call in the session. `git push` with plain
  `--force` is still blocked; `--force-with-lease` no longer is.
- **Format-on-save is scoped to the edited file** (#775). The `Write|Edit`
  hook ran bare `mix format`, rewriting every file in the tree that differed
  from canonical form and mixing that collateral diff into `git status`.
  `.claude/hooks/format-edited-file.sh` formats only the file from the hook
  payload, skips `priv/templates`, and refuses anything outside
  `$CLAUDE_PROJECT_DIR` (realpath + `commonpath`, not a prefix compare).
- **Leaf pinned to 0.6.1** (#776) - lock and the `LEAF_CDN` constant together.
  Conflict reporting on a refused flush (`{:leaf_conflict, ...}` broadcast,
  `@leaf_collab.conflict`, honest `flush_now/1`), `Room.stop/1` and
  `idle_after:` for self-tidying rooms, wiki links following on click in hybrid
  mode, `Leaf.Collab.leave/1`, and the lists-and-checkboxes selection fixes.

## 2.13.16 - 2026-08-30

### Added

- **`<.context_menu>` — right-click and touch-and-hold menus.** New
  `PhoenixKitWeb.Components.Core.ContextMenu` plus a `ContextMenu` JS hook. One
  menu element serves every row it matches: a tree of five hundred nodes renders
  one hidden `<ul>`, not five hundred. On right-click the hook finds the row
  under the pointer, copies its identifier onto each item's `phx-value-*`, and
  opens the menu there — so opening costs no server round-trip and the event
  that fires afterwards still names the right target. Items are
  `TableRowMenu`'s, so a context menu and a `⋮` row menu look identical.
  `value_name` takes a list when a menu's items were written against handlers
  that spell the param differently. Overflow flips the menu to the other side of
  the pointer rather than sliding it, then clamps; the menu is portaled to
  `<body>` while open so `position: fixed` escapes `<dialog>` and `transform`ed
  ancestors. Touch gets a 450ms hold (cancelled by a 10px move) with the
  following click swallowed, and Android's native `contextmenu` de-duplicated.
  Several menus on one page resolve by **deepest match**, not DOM order; `within`
  confines a menu to one region.
- **`<.folder_explorer>` rows are context-menu ready.** Every folder row and leaf
  row carries `data-context-kind` (`"folder"` / `"item"`), `data-context-value`
  and `data-context-label`, so a consumer gets right-click menus by declaring
  the menus alone — no flag, no slot. They sit on the folder's row `<div>` and
  the leaf `<li>`, never on a folder's wrapping `<li>`, so a right-click on a
  nested row resolves to that row rather than its ancestor folder. Consumers
  that declare no menu pay three attributes per row and keep the browser's own
  menu.

Post-merge review of #772 and of `585973ca` (ContextMenu, pushed without a PR)
— see `dev_docs/pull_requests/2026/772-form-field-label-parity/CLAUDE_REVIEW.md`.

### Fixed (post-merge review)

- **Form labels now match `<.input>` exactly, and the four bare `<.label>`
  call sites keep their bottom gap.** #772 removed `fieldset-legend` from
  `FormFieldLabel` on the premise that it shrank and muted those labels. It
  does neither — daisyUI's `.fieldset-legend` sets no `font-size` at all; what
  it sets is `color: var(--color-base-content)` (overriding `.label`'s
  60%-alpha muting) and `padding-block: 0.5rem`. Removing it was still right,
  because that padding was the *only* bottom gap the callers that pass no
  class had (`registration`, `magic_link_registration`, `send_profile_form`
  ×2), and they lost it. `mb-2` now lives in the component, as it does in
  `<.input>`.
- **`<.translatable_field>` labels are the same size as the `<.input>` labels
  beside them.** The 0.75rem came from the component's own `fieldset` wrapper,
  not from `fieldset-legend`, so #772's compensating `text-sm` was a 12px→14px
  bump against a 16px neighbour. Dropping `fieldset` from the wrapper makes the
  span byte-identical to Input's — now pinned by a test that renders both and
  compares.
- **`Mentions.mention_input/1` tracks `<.translatable_field>` again.** The two
  were byte-identical before #772 and render side by side in the same forms.
- **The required marker on `<.select>`/`<.textarea>` matches `<.input>`'s** —
  a non-bold sibling span rather than a bold one nested inside the label span.
- **`ContextMenu`: a long press interrupted by a LiveView patch no longer
  strands a menu in `<body>`** — `destroyed()` cancels the pending timer.
- **`ContextMenu`: `within` honours every matching container**, not just the
  first one `document.querySelector` happened to return.
- **`ContextMenu`: a right-click on empty space closes the open menu** instead
  of leaving it under the browser's native one; the native-menu grace window
  no longer suppresses a right-click when no menu is showing.
- **`ContextMenu`: the post-long-press click is swallowed even if the menu
  closed in between** (Escape, a scroll, an Android URL-bar resize) — the
  swallower was registered and removed with the menu, so the release click
  used to activate the row underneath. The backstop timer is tracked, so
  overlapping presses no longer clear each other's flag.
- **`ContextMenu` docs:** the `MediaDragDrop` collision warning said a
  non-overlapping `selector` avoids it. Rows resolve via `Element.closest/1`,
  so containment collides too — and FolderExplorer is exactly that shape. The
  warning now states the real rule and the workaround that works
  (`long_press={false}`). Not reachable in core: nothing in `lib/` declares a
  `<.context_menu>` yet.

Repo-wide review sweep (no single PR): six areas audited, the verified
defects fixed, the larger items recorded below under "Known / deferred".

### Fixed

**Auth & sessions**

- **Organization invitations are email-bound again.** `accept_invitation_by_uuid/2`
  checked existence, status and expiry but never that the invitation was
  addressed to the accepting user, and `decline_invitation_by_uuid` took no
  user at all — the uuid arrives from a client event, so any signed-in user
  who learned one could join (or cancel) somebody else's invitation. Both now
  return `{:error, :not_invitee}` on a mismatch (case-insensitive); the decline
  API is now `decline_invitation_by_uuid/2`. Registration via an invite link
  only stashes the auto-accept when the registered address IS the invited one.
- **Confirming an account through a verified OAuth email or a magic link now
  closes the pre-hijack window.** Both paths called `admin_confirm_user/1`,
  which only stamps `confirmed_at` — an attacker who pre-registered the
  victim's address kept a working password and live sessions on the row the
  victim was just handed. New `Auth.confirm_user_from_external_proof/1`
  confirms, deletes every token and rotates the stored password hash in one
  transaction; the rightful owner sets a password via "forgot password".
- **Logout no longer 500s** when the browser holds no session stack (stale
  tab / double-click on the unauthenticated `DELETE /users/log-out`) or when a
  secondary account is active but the root token no longer resolves (revoked,
  role change, expiry) — both are now a full logout.
- **Admin user form: editing an email to an already-taken address returns a
  changeset error instead of crashing the LiveView.** `validate_email: false`
  skipped `unique_constraint` along with the pre-flight uniqueness query.
- **Magic-link request page is no longer an account-existence oracle** — the
  registered and unregistered branches used different flash copy.
- **A non-last Owner can be deactivated again.** `status_changeset/2` rejected
  `is_active: false` for every Owner, contradicting the context's
  last-owner-under-lock guard that deliberately allows revoking a compromised
  non-last Owner.
- **`MultiSession.add_account/3` now passes the client IP**, so the per-IP
  login bucket applies to it as it does on the main login form.
- **Magic-link consumption is atomic** (`delete_all` by uuid, branch on the
  row count) — a concurrent replay yields `{:error, :invalid_token}` instead of
  `Ecto.StaleEntryError`. OAuth accounts with no email (GitHub allows it) now
  fail with `{:error, :provider_email_missing}` rather than a
  `FunctionClauseError` inside the transaction.

**Integrations, settings, cache**

- **`Cache.clear_by_prefix/2` no longer crashes a cache started without
  `ttl:`** — its fold matched only 3-tuples, but TTL-less entries are
  `{key, value}`; the `FunctionClauseError` killed the GenServer and dropped
  its `:named_table`.
- **`Encryption.decrypt_fields/1` never returns `enc:v1:` ciphertext as a live
  credential.** With no key resolving (encryption disabled, key store
  unreachable) the map path passed encrypted values through untouched; they
  are now dropped and logged, matching the existing wrong-key behaviour.
- **OAuth token refresh treats a failed persist as an error.** The save result
  was discarded, so a failed UPDATE still returned `{:ok, token}` and — for
  IdPs that rotate refresh tokens — left the burned old refresh token in the
  row.
- **`Settings.get_json_settings_cached/2` fills cache misses from the
  database** instead of returning `nil` for every absent/expired key (the same
  bug `get_settings_cached/2` was patched for).
- **`Integrations.get_integration/1` by uuid only resolves
  `module: "integrations"` rows** — any JSONB settings row's uuid used to
  decrypt-as-integration.
- **Removed the legacy `:cache_settings` ETS table** — it received every
  decrypted setting on warm and was never read or invalidated.
- **File key-store preflight opens its probe with `:exclusive`**, so a planted
  symlink at `<key>.preflight` can no longer truncate the real key.

**Notifications, activity, jobs**

- **External-channel delivery reaches every recipient of a fan-out.** The
  `DeliveryWorker` unique key was `{source_uuid, channel}`, so when one
  activity was routed to N recipients only the first job was inserted within
  the 300 s window. `recipient_uuid` is now part of the key.
- **`Notifications.prune/1` also ages out standalone rows** (`create/1`,
  `create_many/2`, digest summaries) — the delete joined on the activity entry,
  so rows with `activity_uuid: nil` accumulated forever.
- **`Activity.log/1`, `Notifications.maybe_create_from_activity/1` and the
  delivery enqueue `catch :exit`** as well as rescuing — a dead pool exits
  rather than raises, and the business action that logged the activity was
  crashing on a DB blip.
- **`DigestWorker` survives one user's exit** — previously an Oban retry
  re-sent every digest already delivered to earlier users in the sweep.
- **`ScheduledJobs` marks a job failed on `exit`/`throw`** instead of leaving
  the row in `processing` until the stale reclaim and skipping the rest of the
  sweep.
- **`activity_retention_days` of `0` or negative falls back to 90** instead of
  crashing both prune workers daily with a `FunctionClauseError`.

**Built-in modules**

- **Sitemap: an anonymous miss can no longer trigger a full regeneration
  storm.** Any `GET /sitemaps/<unknown>` used to run `Generator.generate_all/1`
  (every source, every language) and then 404 — N bogus filenames meant N
  concurrent full regenerations. Misses within 5 minutes of a full generation
  now 404 directly, and on-demand generation is single-flight
  (`:global.trans`; concurrent callers get a 503 with `Retry-After`).
- **Sitemap scheduler goes through `Oban.insert/1` and `Oban.Repo`** instead
  of the host repo — `Oban.Job` carries no `@schema_prefix`, so on a prefixed
  install jobs landed in `public.oban_jobs`, a table no Oban instance polls.
- **Scheduled sitemap chain survives a skipped or failed run.** A scheduled job
  that returned early (base URL briefly empty) or errored never rescheduled, so
  regeneration silently stopped until the next boot.
- **Video processing parses `ffprobe` output by key** (`stream=…:format=
  duration`) instead of positionally — WebM/MKV carry duration on the format,
  not the stream, so the old `[w, h, d] =` match crashed and the file never
  became active.
- **`SyncFilesJob` is unique** across `available/scheduled/executing`; the
  LiveView's `persistent_term` guard was node-local and only set once the job
  started, so two clicks before pickup ran two concurrent syncs.
- **Bucket form connection test uses `start_async/3`** — the linked
  `Task.async` took the form down on an HTTP-pool exit.

**Admin UI**

- **`remove_member` on the user-details page only accepts a member of the
  organization being viewed**; any uuid used to be detached, and a bogus one
  crashed the LiveView.
- **Activity index no longer runs the paginated query twice per mount.**
- **Authorization settings and the markdown editor map event params through
  literal allowlists** instead of `String.to_existing_atom/1`.
- **MediaSelector's `return_to` goes through `Routes.local_path?/1`**, the one
  redirect guard (rejects control characters), instead of a local copy.

**Install & migrations**

- **`mix phoenix_kit.update -y` fails when `ecto.migrate` fails** instead of
  printing a warning and exiting 0 with the schema still behind.
- **`mix phoenix_kit.gen.admin.page` refuses to touch a non-literal
  `admin_dashboard_tabs`** (a variable, `base ++ […]`, a helper call) — it used
  to replace the whole value, dropping every page the host had registered.
- **The migrator raises on a version-lookup query error** instead of folding
  it into "fresh install" and replaying the whole chain onto a current
  database.
- **`DbConnectionCheck` rescues/catches** an unstarted repo and reports the
  friendly "cannot connect" message instead of a stack trace.
- **Asset rebuild reports `:rebuild_failed`** when every build command fails;
  `mix phoenix_kit.assets.rebuild` no longer prints "✅ completed" over it.
  `MigrationStrategy` says when the DB was unreachable rather than reporting
  "installed (V00)".

### Known / deferred (recorded, not fixed here)

- Storage: `Manager.public_url/2` issues an S3 `HEAD` per bucket on every
  `<.image>` render (resolve from `FileLocation` rows instead); orphan
  detection hardcodes `table_schema = 'public'` and runs a `LIKE '%uuid%'`
  scan per file on every MediaBrowser mount; `Manager.delete_file/2` reports
  success if any bucket returned `:ok` (Local returns `:ok` for `enoent`).
- Settings: no cross-node invalidation (`Settings.Events.broadcast_setting_changed/2`
  has no callers); read-then-put race can cache a stale value for one TTL.
- Install: supervisor-order rewrite can emit an unparseable `application.ex`
  (trailing commas); `gen.migration` mis-detects the version after
  `consolidate_wrappers`; `modernize_layouts` is a stub that reports success;
  V179/V180 `down/1` can fail on a raw FK violation after a local
  manufacturer delete.
- Auth: reset-password submit does not re-verify the token (upstream
  phx.gen.auth behaviour); `count_remaining_owners/1` in `delete_user` does
  not take the last-owner advisory lock.
- Maintenance: an unparseable schedule `end` value is stored as "no end".

## 2.13.15 - 2026-08-29

### Fixed

- **Repair no longer reports two composite-key PRIMARY KEYs as missing.**
  `phoenix_kit_shop_product_slugs_pkey` and
  `phoenix_kit_shop_category_slugs_pkey` were hand-declared alongside V171 as
  `kind: :index`, but on the catalog they are PRIMARY KEY constraints on a
  composite natural key `(lang, value)` — and the index a `p`/`u` constraint
  owns is deliberately never listed among bare indexes, so the check could
  never match anything. Both read `:missing` on every run, on every install,
  no matter how many times repair ran. They are now declared as constraints.
  Separately, `Probe` keeps constraint-backed index rows in a new
  `constraint_backed_indexes` map instead of dropping them, and a
  `kind: :index` lookup falls back to it — so a manifest entry with the wrong
  `kind` degrades to a shape comparison rather than a permanent phantom. (#762)
- **`mix phoenix_kit.update`'s supervisor-ordering check reads the staged
  edit, not stale disk.** It decided "order is correct" from a fresh
  `File.read!` of `application.ex`, but two earlier steps in the same run
  stage their `application.ex` edits in the Igniter buffer, which is not
  flushed to disk until the run ends. The check could see neither
  `PhoenixKit.Supervisor` nor `Oban`, conclude there was nothing to verify,
  and pass an install whose buffer was genuinely misordered. It now reads the
  same buffer the subsequent fix does. (#763)
- **`Integrations.add_connection/4` rejects unregistered provider keys.** The
  provider arrives from a tamperable client event; an unknown key made
  `Providers.get/1` return `nil`, which made the scope check default to
  `[:system]` and pass trivially, birthing a connection row for a provider
  that was never installed. Unknown keys now return
  `{:error, :unknown_provider}`. (#765)
- **A module registered after the provider cache was warmed now contributes
  its providers.** `Providers.all/0` caches built-in plus external providers
  in `persistent_term` with no expiry, and `ModuleRegistry.all_modules/0`
  answers `[]` until the registry has started — so a module arriving later
  (the parent app's `rescan/0`, a runtime `register/1`, a dev hot-reload)
  stayed invisible to the provider list for the life of the VM.
  `Providers.clear_cache/0` existed for exactly this and nothing outside the
  test suite ever called it. The registry now calls it whenever the module set
  actually changes. This was survivable while an unknown key merely fell back
  to a `[:system]` default; with the `add_connection/4` guard above it meant a
  legitimately installed provider could not be connected at all until a
  restart. (post-merge review of #765)

### Added

- **A repository-level guard against running the test suite on a live
  database.** `config/test.exs` honors `PGDATABASE` so the suite can target an
  already-provisioned database on a role without `CREATEDB` — which also means
  a shell that leaks `myapp_dev` into every process turns a bare `mix test`
  into a silent migrate-and-seed of the real thing. `test_helper.exs` now
  refuses, before anything opens a connection, a database name ending in
  `_dev`, `_development`, `_prod`, `_production` or `_staging`, plus any exact
  name listed in `PHOENIX_KIT_TEST_DB_DENYLIST`. It deliberately does not
  require a `_test` suffix: an arbitrary scratch name is the case
  `PGDATABASE` support exists for and passes through untouched. (#764)
- **Coverage for rotating a restricted setting that is still plaintext.**
  Every existing rotation test seeded through the encrypting write path, so
  none could tell "rotation handles a restricted setting" apart from
  "rotation handles one that was already encrypted". The real row this
  protects — an `oauth_google_client_secret` written before encryption
  shipped — is genuinely plaintext, and the new test asserts both that
  rotation encrypts it and that the live OAuth credential read path still
  hands back the original secret. (#766)

## 2.13.14 - 2026-08-28

### Added

- **`<.folder_explorer>` can show what is in the folders.** It rendered a tree
  of folders and nothing else, which suits MediaBrowser — its files live in a
  grid beside the tree — but not a consumer whose leaves *are* the point. A new
  `items` attr (`%{folder_uuid => [item]}`, with `"root"` for the top level) and
  an `:item` slot interleave leaves with folders the way Obsidian and Finder do.
  Each item needs an `:id`, which becomes `data-draggable-file`, so leaves are
  draggable on the same terms as folders with no work from the consumer. A
  folder holding only leaves now gets a chevron. Empty by default: the
  folders-only tree is unchanged.
- **`show_rename` and `enable_drag` are settable on `<.folder_explorer>`.** Both
  existed on the recursive node and neither was plumbed through the public
  component, so a consumer could not turn off an affordance it had no handler
  for. Defaults are unchanged.

### Fixed

- **`<.folder_explorer>` no longer raises on a folder without a colour.** It
  read `folder.color` directly, which is fine for `PhoenixKit.Media.Folder` and
  a `KeyError` for any other consumer's folder struct — taking the page down the
  moment such a consumer had one folder. Read through `folder_color/1`
  (`Map.get/2`) everywhere.
- **`myself` is optional on `<.folder_explorer>`.** It was `required: true`, and
  every control targets it, which made the component effectively
  LiveComponent-only. Pass `myself={nil}` from a plain LiveView: HEEx omits a
  nil attribute, so the events arrive at the LiveView. Documented rather than
  discovered.
- **Corrected a stale comment in `MediaDragDrop`** claiming folder drags are
  refused by trash targets. V119 added recursive folder trash and the comment
  was left behind; the code accepts files, folders and batches. It cost a
  consumer an afternoon of believing it.

## 2.13.13 - 2026-08-28

### Added

- **Integrations encryption key store** — a rotated secret from
  `mix phoenix_kit.integrations.rotate_key` now survives past the terminal
  it was printed in. `PhoenixKit.Integrations.KeyStore` (file/S3/chain
  backends) persists it, verified by a write-then-read-back check before
  rotation touches any data; `mix phoenix_kit.doctor` and the admin
  Integrations settings page report the same key verdict as the boot-time
  warning, from one shared `Encryption.key_report/0`. (#756)
- **Restricted setting values are encrypted at rest** —
  `oauth_google_client_secret`, `oauth_github_client_secret`,
  `oauth_facebook_app_secret`, `aws_access_key_id`, and
  `aws_secret_access_key` are now written through the same encryption used
  for integration credentials, and decrypted on every read path (including
  the boot-time settings cache warmer). (#759)
- **`config.exs`/`application.ex` splices verify before they're adopted** —
  every regex-based install/update splice (Oban wiring, boot hook, Ueberauth
  fix, dev-mailer guard) now parses the candidate output and confirms the
  intended change actually landed in the right place before writing it;
  otherwise the original content is kept and a manual-fallback message is
  printed. Along the way, fixed a buffer-vs-disk bug that could silently
  discard an earlier install/update step's edit to the same file, an
  unanchored `plugins:`/`crontab:` regex that could match a neighbouring
  app's config, and an unconditional leading comma that could corrupt a
  crontab already ending in one. (#758)
- `<.line_chart>` / `<.sparkline>` gained a `y_invert` attr so rank-like
  data (search position, leaderboard) plots "1 is best, at the top" without
  the caller negating its own values; `table_default.ex`'s `card_media_class`
  attr frames the `:card_media` slot; `<.translatable_field>` forwards
  `phx-hook`/`data-*`/`aria-*` to its underlying input via a new `debounce`-
  configurable `:rest` global attr. (#760)

### Fixed

- **Key rotation silently stranded restricted settings.** The key rotation
  added by #756 only re-encrypted `module: "integrations"` rows; the
  restricted setting values #759 added (same PR cycle) are stored with
  `module: nil` and share the same encryption key, so a routine rotation
  left them under the old key — reads then failed closed (logged, dropped)
  the moment the app restarted onto the new key, taking OAuth login and AWS
  config dark with no warning from the rotation task. `KeyRotation` now
  rotates both row shapes in the same pass.
- The admin dashboard's rotating greeting re-rolled the instant the
  websocket connected (LiveView calls `mount/3` twice per page load), so
  the greeting visibly changed on nearly every visit instead of staying put
  for the page load. (#761)
- The language switcher stacked locale prefixes (`/en/fr/...`) instead of
  replacing one — three drifted copies of the URL builder in `AdminNav`,
  `LayoutWrapper`, and `UserDashboardNav` are now one
  `Routes.locale_switch_path/3`. (#761)
- Bumped the Leaf JS bundle to 0.6.0, with a test holding the CDN pin and
  the Hex lock together. (#761)

## 2.13.12 - 2026-08-27

### Fixed

- **A module tab colliding with a host admin page, or with another
  module's tab, compiled to two `live` declarations at the same path** —
  Phoenix kept the first, the second was dead code, discoverable only by
  chance via the compiler's "this clause cannot match" warning. Host pages
  now always win; ties between modules keep whichever was discovered
  first. (#753)
- The same collision was still possible between two modules'
  `user_dashboard_tabs` — the sibling route family `compile_module_user_routes/1`
  builds, which #753 didn't cover. Fixed with the same dedup logic.
- **"Test Connection" stamped a provider with no way to actually check a
  connection as `"connected"`**, with a fabricated `connected_at`
  timestamp — a check that never ran was indistinguishable from one that
  passed. Such providers now report `:unverified`, threaded through to a
  distinct "Not tested — this provider has no connection check" warning
  (not the green "verified" a real pass gets, not the red "failed" a real
  failure gets) on both the system and personal integration forms. (#754)

### Added

- `mix phoenix_kit.doctor` check 13, **Schema-Declared Relations Without a
  DB FK** — cross-references every `belongs_to` PhoenixKit's own schemas
  declare against `pg_constraint`, reporting (advisory, not a failure) any
  relation with no matching database foreign key. Complements check 12,
  which only ever examines a relationship that already has a declared FK
  constraint. (#755)

## 2.13.11 - 2026-08-25

Every install migrating through V180 crashed outright — a bare
`LOCK TABLE` statement outside a transaction block, `25P01
no_active_sql_transaction`. Not only apps using the catalogue module: the
table V180 locks is created unconditionally by the chain (V149, and the
V135 floor), so **every** release from 2.13.4 through 2.13.10 is affected.
Upgrade straight to this one.

### Fixed

- **V180 (`enforce_one_current_supplier_per_pair/2`) crashed every
  install with `Postgrex.Error: LOCK TABLE can only be used in
  transaction blocks`.** Migration wrappers carry `@disable_ddl_transaction
  true` (core convention — every generated wrapper does this so a long DDL
  statement isn't held inside one giant transaction), so each top-level
  `execute/1` auto-commits on its own and a bare `LOCK TABLE` has no
  transaction to hold. Even accepted, the lock would have released at its
  own commit — before the `UPDATE` and `CREATE UNIQUE INDEX` it existed to
  protect, leaving the concurrent-writer race it was written to close still
  open. Lock, dedupe `UPDATE`, and `CREATE UNIQUE INDEX` now run inside one
  `DO $$` block, same shape V170 already used for
  `phoenix_kit_notifications_dedupe_unseen_idx`. Recovery for an install
  that hit the crash: block 1 of V180 (the manufacturer/supplier
  federation columns) already committed, and the version comment still
  reads `'179'`, so a plain re-run (`mix ecto.migrate` /
  `mix phoenix_kit.update`) completes it — every block-1 statement is
  `IF NOT EXISTS`-guarded.
- **V180's dedupe wrote `updated_at` off by the session's UTC offset.**
  `now() AT TIME ZONE 'utc'` is the right idiom for core's `timestamp
  without time zone` columns, but `phoenix_kit_cat_item_supplier_info`
  declares `TIMESTAMPTZ` (V149): the expression yields a UTC wall clock
  that the assignment then re-reads in the session time zone, so a host on
  `America/New_York` stamped the closed rows four hours in the future. Bare
  `now()` now, as V170's dedupe already used. Only rows this migration
  closes were affected.

### Added

- **Static chain check: no `LOCK TABLE` outside a `DO $$` block.**
  `lock_table_guard_test.exs` already asserted that every `LOCK TABLE` sits
  behind a table-existence guard, but it only ever looked *inside* `DO $$`
  bodies — a bare top-level one was invisible to it, which is how V180
  shipped. Nothing else in the suite can catch this class either:
  `PhoenixKit.Migration.Runner` carries no `@disable_ddl_transaction`, so
  `ensure_current/2` (and therefore `test_helper.exs`, and the full-chain
  prefix test) runs migrations inside a transaction — the one condition
  under which a bare `LOCK TABLE` succeeds.

## 2.13.10 - 2026-08-25

A live install's default (dev-parity) logging wrote OAuth/AWS setting
secrets straight into `/var/log/elixir.log` in cleartext, on two independent
paths — closes the second half of the DOM leak fixed in 2.13.9. Doctor's
orphaned-FK check also grows from 4 hardcoded relationships to every foreign
key constraint on the schema (#751).

### Fixed

- **Saving a Settings/Authorization credential (`oauth_google_client_secret`
  and friends) logged the real value.** `Phoenix.LiveView.Logger` writes a
  `"HANDLE EVENT ... Parameters: ..."` line for every `handle_event`, filtered
  only by `config :phoenix, :filter_parameters` (Phoenix's own default:
  `password`/`token`) — a value the settings form's field names
  (`oauth_google_client_secret`, `billing_stripe_secret_key`, ...) never
  matched. `PhoenixKit.boot/1` now installs `secret`/`api_key` into that list
  itself (merging into `{:keep, [...]}` mode; replacing an already-compiled
  filter with a fresh one carrying Phoenix's own default plus these — found,
  by a destructive test, that Phoenix pre-compiles this on every boot
  regardless of host config, so "leave an already-configured filter alone"
  meant "leave every real host alone"). Also merges in every
  `PhoenixKit.Settings.restricted_setting_keys/0` entry by exact name —
  `aws_access_key_id` names neither half of a keypair by the generic
  words above, so it only gets caught by being on that list. No host
  action required — every app already calls `boot/1` via
  `phoenix_kit.install`/`update`.
- **Every write to `phoenix_kit_settings` was logged with its raw value at
  Ecto's default `:debug` SQL log level** (`UPDATE ... SET value = $1 ...
  [<secret>, ...]`) — the table stores every setting's value in the same
  generic columns, secret or not, and Ecto's SQL logger has no notion of the
  schema (no `redact:` field option reaches it). `Queries.insert_setting/1`
  and `update_setting/1` now pass `log: false`.
- **`mix phoenix_kit.doctor`'s orphaned-FK check covered 4 of 70+ foreign key
  relationships** — a hardcoded 4-pair list, checked and printed `PASS`, which
  read as "everything is fine" but only ever meant "the four pairs we
  happened to list are fine". Two real orphans on a live site sat outside
  those four and were invisible the whole time. Now discovers every
  single-column FK constraint straight from `pg_constraint` (self-maintaining
  — a future migration's constraint is covered without touching this file),
  reports coverage explicitly in every result line ("checked N of M foreign
  key constraints" — zero coverage can never read as `PASS` again, whatever
  caused it), classifies orphans behind an already-`VALID` constraint
  (previously silently discarded), gives a per-constraint probe a 5s time
  budget so one huge table can't hang the whole run, and gives a
  probe-failure-only result its own `:warn` tier instead of the same `:fail`
  red as confirmed data damage. Multi-column FKs are enumerated but not
  probed (reported as "not supported by this check, verify manually").

## 2.13.9 - 2026-08-24

Timezones move from a bare offset to full IANA identifiers, so DST is
tracked instead of frozen at whatever the account's offset was when it was
set; saved integration secrets stop round-tripping into the setup form;
Estonian and Russian translations get another pass (#748, #749, #750).

### Added

- **`phoenix_kit_users.user_timezone` now holds IANA identifiers**
  (`Europe/Helsinki`) instead of a bare offset (`"2"`), so a summer-set
  timezone no longer reads an hour behind once winter DST kicks in.
  `PhoenixKit.Utils.TimeZone` still reads existing offset rows as fixed
  offsets — nothing is migrated in place, only the column widens
  (V181). New `/profile/settings` page for setting it (#750).

### Fixed

- **The "you haven't set a timezone" banner fired for almost every signed-in
  user.** It compared the account's blank preference against the site
  default using identifier-only equality, but a fresh/unmigrated install's
  site default is the legacy offset `"0"`, which can never match an IANA id.
  Added `TimeZone.effectively_same?/2`, which compares effective UTC offsets
  when either side is a legacy offset (#750, post-merge review).
- **A hand-edited `user_settings_path` override could resolve to
  `/users/log-out`**, turning a "Settings" link into a silent sign-out.
  `Routes.user_settings_path/1` now runs the override through the same
  `usable_candidate?/1` guard as `main_page_path/0` (post-merge review).
- Media viewer forced a 1:1 aspect ratio regardless of the actual image;
  settings page content could overflow its container (#750).
- **Saved integration secrets (API keys, bot tokens) were decrypted and
  rendered straight into the setup form's `value=` attribute on every edit.**
  The field now renders empty with an "already configured" placeholder
  instead of the credential; submitting it blank still keeps the existing
  secret rather than wiping it (#748).

### i18n

- Estonian translation gaps filled; a batch of Russian strings that were
  fuzzy-matched onto the wrong English source corrected (#749).

## 2.13.8 - 2026-08-24

Authentication and session flash messages now go through gettext, so a
non-English visitor is no longer greeted in English after signing in
(#747).

### Changed

- **Auth, session, OAuth, magic-link, registration, confirmation, and
  password-reset flashes resolve through gettext.** Named `%{}` bindings
  replace `#{}` interpolation so the strings extract. `Users.Auth` now
  `use`s Gettext itself (`:verified_routes` does not pull the macros in).
  One pre-existing `Gettext.dgettext/3` runtime call is a macro, so
  extract can see it. Estonian translations are filled in; other locales
  stay on the English msgid until they are translated (#747).

### Fixed

- **Inline magic-link errors were still English on an otherwise-translated
  page.** The flash half of `error_state/3` was wrapped; the alert rendered
  next to it was not. `MagicLink`'s `:error` assign (never a flash) was
  the same gap. Both now go through gettext (#747).
- **The two Ueberauth-missing OAuth flashes survived only in `et.po`.**
  `mix gettext.extract --merge` treated them as orphans and deleted them.
  They now live in `default.pot` as well, which is the path the catalog
  header names for a string that cannot be compiled-extracted (#747).

### i18n

- Estonian translations for the auth/session flashes this release
  introduces, including the five leftover inline errors. Fuzzy matches
  from extract (e.g. "Please enter a valid email address" ← "Please
  enter a name") were replaced, not kept (#747).

## 2.13.7 - 2026-08-22

### Fixed

- **`mix igniter.install phoenix_kit` no longer writes `config :phoenix_kit,
  PhoenixKit.Mailer` above `import Config` in `config/runtime.exs`.** On a
  stock Phoenix 1.7+ app (simple `dev.exs` plus a `runtime.exs` that calls
  `System.get_env` — every `mix phx.new` tree) the installer preferred
  `runtime.exs` and inserted the Local adapter at line 1, before the
  `import Config` that defines `config/3`. The next boot then died with
  `undefined function config/3 (there is no such import)`. The Local
  adapter now lands in `config/dev.exs` on that layout. When the installer
  does write `runtime.exs` (no simple `dev.exs`), the block is placed after
  `import Config` and wrapped in `if config_env() == :dev`.
  `mix phoenix_kit.update` relocates any `config` calls that already sit
  above `import Config` and wraps the unguarded 2.13.6 Local adapter in
  `if config_env() == :dev`, so a host that hit this on 2.13.6 boots again
  after upgrading without overriding production mailer config.

## 2.13.6 - 2026-08-22

The second `nav_tabs` adoption wave: daisyUI's underline look, and link
keys that no longer double-prefix module Paths helpers (#746).

### Added

- **`variant={:border}`** — daisyUI 5's `tabs-border` underline look, the
  convention on show-page and settings strips. Unlike `:boxed` there is
  no frame to shed, so no bg/padding overrides ride along (#746).

### Changed

- **`:navigate` and `:patch` now pass through verbatim**, matching
  `Phoenix.Component.link/1`. They used to run through `Routes.path/1`,
  which double-prefixed URLs already built by a module's Paths helpers.
  `:path` is unchanged: it still applies the helper, because its callers
  have always passed unprefixed paths. The two keys are the same link
  *kind* with different prefix rules — not interchangeable spellings
  (#746). Callers that passed unprefixed values to `:navigate` / `:patch`
  against 2.13.5 need to prefix them at the call site (one consumer:
  `phoenix_kit_user_connections`).

## 2.13.5 - 2026-08-21

`nav_tabs` becomes the strip the rest of the ecosystem can actually adopt:
patch links, an unframed variant, nil-tolerant badges, and the daisyUI 5
`tabs-box` class (#744). Companion PRs in seven modules migrate onto it.

### Added

- **`nav_tabs` link keys now mirror `Phoenix.Component.link/1`.** `:navigate`
  for a full LiveView navigation, `:patch` to stay in the current LiveView
  (query-param tabs need this — a navigate remounts and drops socket state).
  `:path` is a permanent alias for `:navigate`, so existing callers do not
  change. Two link keys on one tab raise; a `nil` value counts as absent
  (#744).
- **`variant={:plain}`** drops the daisyUI frame (`tabs-box`) so a strip
  nested in an already-framed container is not double-boxed. `class` can
  only add, which is why callers had been hand-rolling instead (#744).
- **`:badge_class`** lets a tab keep its own badge tone (a pending-requests
  count stays `badge-warning` whether or not it is the active tab) (#744).
- **`tablist_class/2` and `tab_class/2`** are public so tab-*styled* markup
  that is not a tab strip can share one daisyUI definition. The next class
  rename should be a change here, not another sweep (#744).

### Changed

- **`tabs-boxed` → `tabs-box`.** daisyUI 5 renamed the class; the old name
  styled nothing (#744).
- **Optional tab keys treat `nil` as absent**, so `badge: if(n > 0, do: n)`
  renders no badge rather than an empty pill. Zero still renders (#744).
- **`live_sessions`' filter row** uses `<.nav_tabs>`. Its handler now
  matches on `%{"tab" => _}` instead of `%{"type" => _}` — the URL query
  key stays `type` (#744).

### Fixed

- **`import PhoenixKitWeb.Components.Core.NavTabs` is now explicit
  (`only:`)** so a later helper on that module does not silently join
  every LiveView's namespace. `tab_class` / `tablist_class` are the
  intended additions; the same file already documents this failure mode
  on `EmailStatusBadge` (post-merge follow-up for #744).

## 2.13.4 - 2026-08-21

Catalogue manufacturer/supplier links become CRM-federated (V178–V180), and
the Authorization settings page no longer leaks OAuth secrets via the DOM or
application logs (#742, #743).

### Added

- **V178: `phoenix_kit_cat_manufacturers.crm_company_uuid`** — a soft,
  nullable cross-reference onto a CRM party (no FK — optional-module
  boundary), plus partial unique indexes on both `cat_manufacturers` and
  `cat_suppliers`' `crm_company_uuid` so each stays one-to-one against a CRM
  party (#743).
- **V179: `phoenix_kit_cat_items.manufacturer_uuid` becomes a federated
  reference** — a manufacturer can now be a CRM party, not only a local
  `phoenix_kit_cat_manufacturers` row. Adds `manufacturer_source`
  (`local`/`crm_company`) and `manufacturer_name_snapshot` (a tombstone shown
  only when the reference resolves to nothing), and drops
  `phoenix_kit_cat_items_manufacturer_uuid_fkey` — integrity moves to the
  application, as it already had for the item↔supplier junction since V149
  (#743).
- **V180: `phoenix_kit_cat_manufacturer_suppliers` becomes federated on both
  sides** — adds `manufacturer_source`/`supplier_source` and drops both of
  the join table's foreign keys (which carried `ON DELETE CASCADE`). Also
  adds a partial unique index so one item can no longer carry two *open*
  price rows for the same supplier at once; pre-existing duplicates are
  closed (not deleted) during the upgrade (#743).

### Fixed

- **The Authorization settings page (`/admin/settings/authorization`) no
  longer renders real OAuth client secrets into the DOM.** The three secret
  inputs previously round-tripped the real Google/GitHub/Facebook secret
  through `value=`, which meant editing *any other field* re-submitted it as
  part of the full-form `validate_settings` event and Phoenix's own LiveView
  telemetry logger wrote it to the application log. Inputs now always render
  blank with a "secret already configured" placeholder; a blank submission no
  longer wipes the stored secret (#742).

### ⚠️ Upgrade note

If you use `phoenix_kit_catalogue`: upgrade it to a version that includes its
own explicit cleanup of `phoenix_kit_cat_manufacturer_suppliers` links
(`phoenix_kit_catalogue` PR #75) before or alongside this release. V180 drops
the `ON DELETE CASCADE` that used to clear those links automatically when a
local supplier/manufacturer was deleted; an older `phoenix_kit_catalogue`
will silently leave orphaned (but harmless and recoverable) join rows behind
until it's upgraded.

## 2.13.3 - 2026-08-20

Closes an OAuth/AWS secret-value leak on the General and Users settings
pages (#741), plus a post-merge fix for a reset-to-defaults gap the same PR
left open.

### Fixed

- **OAuth login secrets and AWS credentials no longer load into the
  General/Users settings LiveViews** — both mounted with
  `Settings.list_all_settings/0`, holding the real `oauth_*_client_secret`
  and `aws_access_key_id`/`aws_secret_access_key` values in socket state
  even though only the Authorization page renders them. Replaced with
  `Settings.list_public_settings/0`, an explicit allow list
  (`@public_setting_keys`) rather than a blacklist of `list_all_settings/0`
  — a new setting that isn't classified on either list now fails a test
  instead of silently defaulting to exposed (#741).
- **General settings' "Reset to Defaults" no longer overwrites those same
  restricted keys** — the reset handler still called `update_settings/1`
  with the full, unfiltered defaults map (including the 5 restricted keys),
  so clicking Reset silently wiped live OAuth client secrets and AWS
  credentials — `aws_access_key_id`/`aws_secret_access_key` can default to
  the host's real configured credentials, not a placeholder. The confirm
  dialog never mentioned this. Reset now filters through the same allow
  list used at mount (post-merge fix for #741).

## 2.13.2 - 2026-08-19

A catalogue attribute-sets table, an OAuth registration crash fix, and a
sitemap/noindex decoupling flag (#737, #739, #740).

### Added

- **V177: `phoenix_kit_cat_item_attribute_sets`** — the catalogue's item ↔
  attribute-set join backing the attribute-sets rework, with a reserved
  per-attachment `data` JSONB for upcoming per-item value selection (#737).
- **`crawlers_sitemap_exempt_from_no_index`** setting — lets an operator keep
  the sitemap publishing its real URLs while `crawlers_no_index` is active,
  without touching the `noindex` robots meta directive. Off by default, so
  existing installs keep today's lockstep behavior (#740).

### Fixed

- **`Ecto.CastError` on OAuth registration with geolocation tracking
  enabled** — `register_user_with_geolocation/2` merged a string key onto
  atom-keyed `attrs` from the OAuth path, producing a mixed-key map that
  `Ecto.Changeset.cast/3` rejects outright. `attrs` is now normalized to
  string keys before the merge (#739).

## 2.13.1 - 2026-08-18

FK validation, auth-page SEO, an S3-compatible object-storage integration
provider, and a tracked pre-commit hook (#733, #734, #735, #736).

### Added

- **V176 validates existing `NOT VALID` user foreign keys in place** and
  never deletes or nulls a row — a name-matched re-probe after `VALIDATE`
  guards against shape-only false positives. `mix phoenix_kit.doctor`'s
  orphaned-FK probe now fails closed on a probe error instead of reporting a
  pass (#733).
- **Canonical/hreflang tags on the stable auth pages** (login, registration,
  magic-link registration request) via a new `PhoenixKitWeb.Users.AuthSeo`
  helper (#734).
- **`object_storage` integration provider (S3-compatible)** — registers with
  `PhoenixKit.Integrations`, with URL/bucket/region validators covering
  AWS/Backblaze/Cloudflare/China-partition endpoint shapes. This is the
  provider-side half of the bucket `integration_uuid` credential source added
  in 2.13.0 — no admin-UI picker yet (#735).
- **`.githooks/pre-commit`** is now tracked in the repo (`git config
  core.hooksPath .githooks` to enable) and `mix phoenix_kit.doctor` reports
  its status under "Git Hooks" — scoped to a checkout of phoenix_kit itself,
  since the hook is a contributor convention, not something installed into a
  consuming host app (#736).

### Fixed

- **`.githooks/pre-commit` now runs the same steps as `mix precommit`**, in
  the same order (`compile --warnings-as-errors --all-warnings`,
  `deps.unlock --check-unused`, `quality.ci`, `test.js`), instead of a
  weaker, format-mutating `mix quality` that could leave the working tree
  dirty immediately after a hook-approved commit (post-#736 review fix).

## 2.13.0 - 2026-08-18

Storage bucket credentials are now encrypted at rest, with an alternative
credential source for cloud buckets (#732).

### Added

- **`phoenix_kit_buckets.integration_uuid`** — a cloud bucket (S3/B2/R2) may
  now point at a `PhoenixKit.Integrations` connection instead of storing
  `access_key_id`/`secret_access_key` directly. Mutually exclusive with the
  bucket's own credentials — `Bucket.changeset/2` rejects setting both in the
  same change rather than letting one silently win. Not yet wired up to any
  admin UI or a registered `object_storage` integration provider — usable via
  the context API today, a follow-up PR is expected to add the picker (#732).
- **`PhoenixKit.Integrations.Encryption.encrypt_value/1` and `decrypt_value/1`**
  — single-value encrypt/decrypt for callers with one bare field to protect
  (e.g. an Ecto schema field) rather than a full `encrypt_fields/1`-shaped map.
  Same cipher, key derivation, and `enc:v1:` prefix (#732).

### Changed

- **`secret_access_key` on storage buckets is now encrypted at rest**, decrypted
  only at the point of use (`Providers.S3.resolve_credentials/1`) — general
  accessors like `Storage.get_bucket/1` return it as stored. A row written
  before encryption existed stays plaintext until the next save of the bucket
  for any reason (no bulk backfill). `access_key_id` is left as-is — it is a
  credentials identifier, not a secret (#732).
- **`phoenix_kit_buckets.secret_access_key` widened from `varchar(255)` to
  `text`** (migration V175) — the encrypted encoding runs ~1.6x the plaintext
  length, which overflowed the old column past a ~158-char secret (#732).

## 2.12.1 - 2026-08-17

Two defects in the sitemap domain-mode code that landed with 2.12.0, found by
reviewing that release's own follow-up commits after it shipped (#731).

### Fixed

- **Duplicate `<loc>` on the primary sitemap domain.** When the primary
  domain hosts a language that is NOT the site default, and the site default
  has no domain of its own, the default language's unprefixed home page
  re-hosted onto exactly the URL the primary's own language already
  occupied — the same URL twice in one file. The host's own language now
  wins its URL and the colliding domainless entry is dropped (#731).
- **One junk element in `sitemap_non_page_pipelines` emptied the whole
  router-discovery source, silently.** A hand-edited settings value like
  `["phoenix_kit_api", 1]` raised inside `safe_to_atom/1`, which `collect/1`'s
  rescue swallowed — removing every discovered route from the sitemap with
  nothing in the log. Junk elements are now ignored while the good ones still
  apply; this also hardens `sitemap_protected_pipelines`, which shares the
  same helper (#731).

## 2.12.0 - 2026-08-17

Every mapped sitemap domain gets its own static pages, with the review
follow-ups needed to ship it safely (#730).

### Added

- **A mapped sitemap domain now gets its own static pages** (home page and
  any other `sitemap_static_routes` / `sitemap_custom_urls` entry) — a
  language with a domain of its own serves these prefix-free from that host,
  but `Sources.Static` previously emitted them for the default language
  only, so every non-primary domain's sitemap was missing its own home page
  while still listing its products. The prefixed URL this collects is an
  intermediate for `DomainMode` to re-host, not a published one — it never
  reaches the legacy/index set served to unmapped hosts (#730).
- **`sitemap_non_page_pipelines` setting** — an escape hatch for the
  JSON-pipeline route exclusion added in 2.11.0: unlike
  `sitemap_protected_pipelines`, this one *replaces* the default pipeline
  list rather than extending it, so a host that serves real pages through a
  pipeline literally named `:api` can take it off the list. Saving `[]`
  turns pipeline-based exclusion off entirely (#730).

### Fixed

- **`Sitemap.regenerate/1` accepted an unconfigured `site_url`** and would
  have written host-less `<loc>` entries instead of failing — it now returns
  `{:error, :base_url_not_configured}`, matching the guard
  `SchedulerWorker` already had for scheduled regeneration (#730).

## 2.11.0 - 2026-08-17

Sitemap round-out (domainless-language URLs, a real `regenerate/1`, JSON-pipeline
route exclusion), independent integrations encryption keys with rotation, and a
media-annotation comment fix, with etcher bumped to 0.13.1 (#725, #726, #727,
#728, #729).

### Added

- **Integrations encryption key rotation.** `mix phoenix_kit.integrations.rotate_key`
  re-encrypts (or, for a still-plaintext row from before this release, encrypts for
  the first time) every stored integration credential under the currently
  configured key, and the encryption key can now be decoupled from
  `secret_key_base` via a dedicated config, with an admin-UI warning when a host is
  still relying on the legacy shared-key fallback (#728).
- **`sitemap_router_discovery` now excludes JSON-pipeline routes**, not just
  `^/api`-path routes — a route piped through `:api` or `:phoenix_kit_api` is
  recognized as non-page regardless of where it's mounted (a module's own API
  prefix, or a host's infrastructure endpoint like Caddy's on-demand-TLS ask
  hook) (#727).

### Fixed

- **Domain-mode sitemap dropped every URL for a language with no domain of its
  own.** Domainless languages now fall back into the primary domain's file with
  their locale-prefixed path intact, computed the same way as a mapped
  language's alternates (#725).
- **`Sitemap.regenerate/1` returned a "not implemented" placeholder** instead of
  actually regenerating the sitemap; wired to the same `Generator` call the
  sitemap controller already uses (#726).
- **Master comment on a labelled annotation shape repeated the shape's label**
  as the comment body, even though the sidebar already renders the label as the
  thread's heading — post-merge review found the described fallback for older
  `phoenix_kit_comments` releases didn't actually work (the new
  `allow_empty_content` flag doesn't exist in any released version, so the
  bodiless-content attempt always failed and **Reply silently did nothing** for
  every labelled shape); fixed by retrying with the label as content on that
  specific failure, so the flow works today and upgrades transparently once
  `phoenix_kit_comments` ships real support for the flag (#729).
- **etcher bumped to 0.13.1** — the annotation tooltip anchored above the shape
  element, which for a labelled shape is exactly where the label floats,
  covering it; the anchor box is now the shape unioned with its label and badge
  (#729).

## 2.10.0 - 2026-08-17

Locale resolution gets smarter about dialect/bare-code mismatches, hosts
running multiple domains gain a request-scoped default-language override, and
sitemaps can now be generated, cached, and served per domain (#722, #723,
#724).

### Added

- **Multilang dialect/bare-code resolution.** Reading translatable content no
  longer requires an exact locale-code match — a bare code (`"en"`) resolves
  against a full-dialect record (`"en-US"`) and vice versa, and a same-base
  sibling is used as a deterministic, primary-preferring fallback when the
  requested code has no data of its own. `PhoenixKitWeb.Users.Auth` gained
  `resolve_active_dialect/1` (resolves a base code to the host's actually
  *enabled* dialect) and `put_gettext_locale/1` (de-duplicating the
  `Gettext.put_locale/2` pair previously repeated at 7 call sites); LiveView
  navigation to a full-dialect URL segment (`/en-GB/...`) is now honored the
  same way the HTTP plug already honored it (#722).
- **`PhoenixKit.Modules.Languages.put_request_default_language/1` /
  `request_default_language/0`.** A `Process`-scoped override that
  `get_default_language/0` consults before falling back to the configured
  `is_default` language, for multi-domain hosts that want a different
  default language per request. `pass nil` or `""` to clear it. Explicitly
  process-scoped — not inherited by `Task`/Oban (#723).
- **`PhoenixKitWeb.Integration.extra_on_mount/0`**, read from
  `config :phoenix_kit, :extra_live_session_on_mount`, prepended to the
  `on_mount` list of every `live_session` PhoenixKit generates (public,
  admin, authenticated dashboard, deprecated user-dashboard, maintenance),
  so a host can hook `put_request_default_language/1` into its own
  domain-resolution logic on the LiveView socket path (#723).
- **Per-domain sitemap generation, storage, cache, and serving.** A host app
  can map several domains to distinct languages (one domain = one canonical
  language); `PhoenixKit.Modules.Sitemap.DomainMode` builds a per-host
  `sitemap.xml`/`sitemaps/*` set by re-hosting each language's
  already-collected entries and computing cross-domain hreflang alternates
  once per canonical group. Host strings are validated/normalized once and
  re-validated in `FileStorage` as defense in depth; `Cache.invalidate/0` and
  `cleanup_stale_domain_dirs/0` sweep per-host directories so stale/renamed
  domains don't linger (#724).

### Fixed

Post-merge review of #722/#723/#724 found and fixed the following before
release:

- **`same_base?/2` collapsed genuinely distinct sibling dialects** (e.g.
  independently-maintained `en-US` and `en-GB` content), not just
  bare/dialect naming-drift of the *same* language slot. Saving a secondary
  dialect tab could silently overwrite the primary language's data, or
  promoting a dialect to primary could delete an unrelated sibling as a
  false "ghost." Narrowed the equivalence to same-string or literal
  bare-code-of-the-other only.
- **Request-scoped language override lost to a same-base dialect earlier in
  the configured list.** An exact-code override (e.g. `"fr-CA"`) could
  resolve to a different, earlier-listed dialect of the same base (`"fr-FR"`)
  on any host with 2+ enabled dialects sharing a base, because the lookup
  OR'd "exact match" and "base match" into one `Enum.find/2` pass instead of
  trying exact matches first.
- **`put_request_default_language("")` silently forced English** instead of
  behaving like "no override" (its documented behavior for `nil` and for any
  unknown/disabled code) — a naive host plug computing the override from an
  unmapped host (`Map.get(domain_map, host, "")`) would trip this on every
  unmapped domain.
- **Domain-mode sitemap generation force-collected in index mode**,
  bypassing `enabled?/0` and leaking a disabled source's URLs into the
  public, crawlable per-domain files — even though those same URLs were
  correctly absent from `/sitemap.xml` and every per-module file. Index-mode
  domain-file collection now honors `enabled?/0` exactly like the legacy
  per-module path; flat mode's existing, separately-documented force-collect
  behavior is unchanged.

## 2.9.0 - 2026-08-17

Media file-type integrity gets defended at the write boundary and repaired
for rows already corrupted, and the media viewer's shape annotations grow a
real discussion flow (#721).

### Added

- **Annotation discussions.** Drawing a shape on the media viewer's canvas
  no longer opens a composer — every kind saves silently, with labels typed
  through Etcher's inline editor. The tooltip gets three header buttons
  (Etcher 0.13's `tooltipActions`): **Reply** lazily creates the shape's
  master comment (content = label, author = shape creator, backdated to the
  shape's creation) and opens a body-only popup that threads under it;
  **Edit** reopens Etcher's inline label editor; **View** scrolls the
  sidebar to the shape's thread. Shapes show a live comment-count badge that
  refreshes on create/delete via the existing comments PubSub relay.
- **`Storage.store_file_in_buckets/7` `:mime_type` opt.** Callers can now
  pass the browser-observed mime (`client_type` / `content_type`) so it's
  stored verbatim instead of guessed from the extension; all core upload
  call sites (`UploadController`, `MediaBrowser`, `MediaSelectorModal`,
  `MediaSelector`) now pass it.
- **`Storage.display_file_type/1`.** Reconciles a stored row's `file_type`
  against its own mime/filename evidence for display, so a row misclassified
  before this release (e.g. a `.mov` stored as `"image"`) renders correctly
  without needing the repair migration to have run.
- **V174 migration** — repairs media rows corrupted by two now-fixed writer
  defects: blank/octet-stream mimes with a known audio extension get the
  real audio mime (files and file instances), and generic `file_type` values
  contradicted by the mime are reclassified. System types (`"tile"`) and
  rows without evidence are left untouched; the migration is idempotent and
  its `down/1` is deliberately a no-op (there's no record of the pre-repair
  values to restore).

### Fixed

- **Upload paths could poison `file_type` for every downstream surface.**
  The storage write boundary now cross-checks a caller's claimed `file_type`
  against the mime/filename evidence and corrects a contradicted generic
  claim, so one careless call site (e.g. an external module hardcoding
  `"image"`) can no longer break the thumbnail grid, type filters, and
  variant processing for every file it uploads.
- **`determine_mime_type/1` had no audio entries.** Every `.mp3`/`.m4a`/
  `.wav` guessed from an extension landed as `application/octet-stream` and
  was served that way. Now routed through `MIME.type/1` with an audio
  fallback map for the extensions it still answers octet-stream for.
- **Etcher label text silently vanished on reload.** `annotation_unchanged?`
  compared geometry/style/kind only, so a label typed into Etcher's inline
  editor (the only way text/callout/dimension shapes collect text since
  Etcher 0.12) changed nothing the comparison looked at and the write was
  skipped.
- **Committing a shape label crashed the LiveView.** The sync path read a
  curated map (as `load_annotations_for/1` produces it) as if it were the
  `Annotation` schema struct.
- **Deleting a sidebar comment killed the whole LiveView**, which read as
  "the page refreshed and the media modal closed" — the `Embed` macro now
  handles the `{:comments_updated, ...}` message the comments component
  reports to the host process.
- **The media viewer's connector anchors are now hard-disabled** (`connectors={:off}`)
  instead of following a shared saved preference that could follow a user in
  from boards, where the anchors point at nothing.
- **Lightbox video/audio sizing.** Video fills the column via
  `object-contain` instead of floating as a tiny box at its intrinsic size;
  the audio player is centered with a max width instead of stretching full
  width.
- **`default.pot` extraction drift + missing translations.** The composer's
  copy change ("Reply to this annotation") had never been extracted;
  re-extracted and translated into de/es/et/fr/it/pl/ru.

### Dependencies

- **etcher 0.13.0** (was 0.12.1) — adds `tooltipActions` and the hard
  `connectors={:off}` layer option.

## 2.8.1 - 2026-08-16

### Added

- **UploadGuard.** `Core.FileUpload` now blocks accidental tab close/refresh
  while a file is mid-upload — the browser's native `beforeunload` dialog
  fires instead of silently losing an in-flight transfer (LiveView uploads
  aren't resumed). Applies to both the drag-drop and button variants (#720).

### Changed

- **`Core.FileUpload` static strings are translatable.** "Cancel upload",
  "Drag files here or click to browse", "Drop your files to upload", and
  "Maximum file size: …" now go through `gettext`; the `label` attr defaults
  to a translated "Upload Files" instead of a hardcoded string (#720).

### Fixed

- **`default.pot` extraction drift.** `Core.ColumnSettings`' "Columns" and
  "Shown" labels (added in 2.8.0) had never been extracted, leaving them
  untranslated in every non-English locale. Re-extracted and translated into
  de/es/et/fr/it/pl/ru.

## 2.8.0 - 2026-08-16

The admin header becomes a real breadcrumb for drill-down pages, and
catalogue's live column editor lands in core as a reusable modal. UrlState
stops leaking router path params into every patched query (#719).

### Added

- **`page_crumbs` on `app_layout`.** Extra `%{label, path | patch}` crumbs
  between `page_section` and the page title for pages nested deeper than
  one level. The last crumb stays visible below `sm`; earlier crumbs and
  the section drop first, so a drilled page reads `… / parent / page`
  instead of the bare title (#719).

- **`Core.ColumnSettings`** (`<.column_settings_modal>`). Live
  column-configuration modal: Shown list (SortableGrid drag-reorder,
  remove) beside Available (click to add), Reset + Close, no Apply
  step. Labels accept strings or 0-arity functions. The consumer owns
  the catalog, selection, and persistence (#719).

- **`table_row_menu_link` `patch` attr.** Same-LiveView navigation for
  menus that drill via `push_patch` (#719).

### Changed

- **Admin header progressive collapse.** Below `lg` the site name and
  "Admin Panel" give way to a home-linked `…`; below `sm` the trail
  truncates from the left rather than collapsing to the page title
  (#719).

### Fixed

- **UrlState extras come from the URI query string**, not LiveView's
  merged params map. A `/:uuid` segment was being re-encoded into every
  patched URL (`?q=oak` became `?q=oak&uuid=<uuid>`). `decode/2`'s spec
  now admits `:not_mounted_at_router` (#719).

- **ColumnSettings Shown list is actually sortable.** Rows use the
  `sortable-item` class SortableGrid reads; a custom `.col-item` was
  silently ignored. Drag starts on `.pk-drag-handle` only (post-merge
  review of #719).

- **`page_crumbs` accept `patch:`** for same-LiveView drill trails,
  matching the row-menu attr the PR already added (post-merge review
  of #719).

- **`column_settings_modal` is imported** with the other list-UI
  primitives (post-merge review of #719).

## 2.7.0 - 2026-08-15

Catalogue gets reusable, translatable attribute groups; list tables grow a
comfortable density between compact and cards; uploads say what is happening
after the bar hits 100%. Chain moves V172 → **V173** (#718).

### Added

- **V173 — catalogue attribute groups.** Four tables (groups / attributes /
  values / item assignments) for `phoenix_kit_catalogue`: a group owns
  ordered attributes, each attribute owns ordered values with an explicit
  `is_default`, and items link through a join table. One-group-per-item is
  a droppable `UNIQUE (item_uuid)` index, so multi-group later is not a
  data migration. Definition-tree FKs are `RESTRICT`; a group any item still
  references can only be archived. ExpectedSchema entries were emitted from
  a migrated database and `chain_hash` restamped (#718).

- **`Core.TreeTable`** (`<.tree_name_cell>`). File-explorer name cell —
  depth indent, disclosure chevron, optional type icon — that composes
  into `<.table_default>` rows instead of replacing the table. The consumer
  owns the walk and the expanded set (#718).

- **Comfortable view mode** on `<.table_default>` and the `TableCardView`
  hook. The same table with roomier cell padding (`pk-comfy`), sitting
  between compact rows and cards, and the default when nothing is stored
  (#718).

- **Live upload transfer stats.** The `UploadStats` JS hook computes
  transferred bytes, sliding-window speed, and ETA from the patched
  `data-progress` attribute, then flips to a ticking "Processing on
  server…" clock at 100%. Wired through `<.upload_entry_stats>` on both
  `<.file_upload>` variants, the media selector, and MediaBrowser
  (#718).

### Changed

- **FolderExplorer wrapper `class` attr.** The hardcoded `hidden lg:block`
  is now overridable so embeds outside MediaBrowser can pick their own
  breakpoint (#718).

- **Drag handles stay visible.** A muted grip that strengthens on hover
  replaces `opacity-0` + `group-hover/row` — an affordance you cannot see
  is one nobody discovers (#718).

- **Multilang tabs drop the "Content Language" header** by default
  (`show_header` / `show_info` remain as an opt-in). The tab strip itself
  stretches full width (#718).

- **Media picker names its purpose.** Callers pass a `title` (Select
  Avatar, Select Cover Image, …); a locked picker without one derives a
  type-aware heading. Search hides below ten files on a locked picker,
  empty libraries get a type-aware empty state, a dry search offers
  Clear search, and double-click confirms in single mode (#718).

- **MediaBrowser upload drain is two-phase.** Pending stores queue through
  `send_update_after` so a "Processing on server…" row paints before each
  store, and the batch flash waits until the queue is empty (#718).

### Fixed

- **Media picker grid sat flush against the search bar.** The browse
  wrapper's `display:contents` swallowed the parent's `space-y-4`
  (#718).

- **V173 rollback uses plain `DROP TABLE`s** in dependency order. CASCADE
  could have taken out FKs or views a parent app hung off these tables
  (#718).

- **`tree_name_cell` is imported** with the other list-UI primitives, so
  a `use PhoenixKitWeb, :html` caller does not need a manual import
  (post-merge review of #718).

- **Uncontrolled tables first-paint comfortable**, matching the JS hook's
  default, instead of flashing compact until `localStorage` is read
  (post-merge review of #718).

- **Long tree-cell names truncate** inside the flex row instead of
  overflowing the cell (post-merge review of #718).

## 2.6.0 - 2026-08-14

The built-in SEO module becomes **Crawlers** and grows into the one page where an
operator decides who may read the site; the theme system becomes one generated
controller plus a pre-paint bootstrap that hosts can brand from config; shop
slugs get a uniqueness bucket that matches the URL the resolver actually serves;
scheduled jobs stop double-firing; and every vendored CDN pin is now held to its
lock. Chain moves V170 → **V172** (#714, #715, #716).

### Added

- **Crawlers module** (`PhoenixKit.Modules.Crawlers`, settings at
  `/admin/settings/crawlers`, permission key `crawlers`). Per-bot-group access
  toggles over a curated registry — search engines, AI training scrapers, AI
  assistants, SEO tool crawlers, web archives — all default-allowed, so enabling
  the module changes nothing until the operator decides otherwise (#714).

- **Generated `robots.txt`.** The settings page renders the complete file the
  toggles describe, for copy-paste. Core still deliberately does not serve it:
  `robots.txt` is host policy and `Plug.Static` answers before the router (#714).

- **`llms.txt`**, served at the site root and under the kit prefix (same reasoning
  as `/sitemap.xml`), 404ing while the module is disabled. Heading from the project
  title, body from an operator-edited setting (#714).

- **Search-engine verification metas** (`google-site-verification`,
  `msvalidate.01`). Pasting a whole `<meta>` tag extracts the content value (#714).

- **`PhoenixKitWeb.Components.Core.CrawlerMetas`** — a head component that reads its
  own settings, so it renders in ANY root layout. Most installs render the head in
  the host app's root layout, where core's assigns never arrive, and the previous
  assign-based noindex meta silently reached no page on those installs. Core's two
  shells use it; hosts embed one line (#714).

- **`PhoenixKitWeb.Plugs.CrawlerBlocker`** — default-off, honestly advisory 403 for
  user-agents of blocked groups, wired into the kit page pipeline. Policy-file
  scopes skip it on purpose: `robots.txt` and `llms.txt` must stay fetchable by the
  bots they are about (#714).

- **Doctor check "Crawler Visibility"** — warns on noindex left ON for a
  production-looking host, and on a staging-looking host left indexable (#714).

- **`PhoenixKit.Conformance.ComponentAssigns`** — a static check that a HEEx function
  component never reads an assign it neither declares nor assigns itself. The
  compiler validates call sites, never callee bodies, which let a `KeyError` behind
  an `:if={...}` guard ship for four releases (#714).

- **Host-branded themes from config** (`:theme_definitions`). Override a built-in
  palette or define a named theme (`:label`, `:base`, optional `:extends` /
  `:variables`); one validation pass feeds both the CSS and the JS embeds.
  Injection-hardened at both sinks (#716).

- **One theme controller script** (`ThemeControllerScript`) replaces the three
  drifted copies (dashboard inline, admin inline, static `phoenix_kit_themes.js`).
  Pre-paint `ThemeBootstrap` stamps the saved choice — and now ships the palettes
  next to the stamp — so a dark-OS visitor is not painted `color-scheme: dark`
  over light variables. Picker modes `:auto | :dropdown | :toggle`; a light/dark
  pair renders one persistent `aria-pressed` toggle (#716).

- **`PhoenixKit.Utils.Pagination`** — `parse_page/1` and `total_pages/2` (floored
  at 1). The unfloored `ceil` copies fed `1..0` decreasing ranges on empty lists
  (#716).

- **`<button variant="error">` (and info/success/warning).** Status colours are
  first-class variants; appending `btn-error` through `class` collided with the
  variant's own colour and stylesheet order decided who won (#716).

### Changed

- **V172 renames the SEO module to Crawlers.** Settings rows
  (`seo_module_enabled`/`seo_no_index` → `crawlers_*`) are renamed with a dedupe
  guard where the old row's value wins — it is what the running site was honouring —
  and roles granted `seo` gain `crawlers`. The old `seo` permission rows are kept
  deliberately: the repair manifest still lists the V135 `seo` seed, so deleting
  them would set `mix phoenix_kit.repair` and this migration fighting over the same
  row. A deprecated `PhoenixKit.Modules.SEO` shim keeps host callers compiling, and
  frees the `seo` module key for the external `phoenix_kit_seo` package (#714).

- **V171 gives shop slugs a uniqueness bucket of (base language, value).** The
  V52-era expression index on the alphabetically-first key's value under- and
  over-enforced at once: other languages were unconstrained, so collisions surfaced
  far from the save that caused them, while `{"en":"hat"}` and `{"de":"hat"}`
  collided though they can never shadow each other in a URL. Trigger-maintained
  projection tables now enforce the bucket the resolver reads, and their pkeys give
  `phoenix_kit_ecommerce` a real `unique_constraint` to name — a collision comes back
  as a changeset error on `:slug` instead of a raw `Postgrex.Error` (#714).

- **Scheduled jobs are claimed before they run.** The plain `SELECT` let two
  overlapping sweeps — core's cron worker and a host calling the public function, or
  two nodes — both see the same rows and both fire the handler, which host handlers
  are not required to survive. A row is now claimed with a CAS into a new
  `processing` status and only the winner executes; a sweep that dies holds its claim
  until a reclaim window returns the row to `pending` (or to `failed` once attempts
  are spent). Both terminal marks are CAS'd, so a late mark from a slow sweep cannot
  stomp a row that has already been requeued (#714).

- **Every vendored CDN pin is held to the version the lock resolves.** #709 fixed
  leaf's pin and pinned it with a leaf-only test; the three sibling pins in the same
  file had all drifted — etcher by three minors, so none of the 0.12.0 tldraw-parity
  work reached any host. The test is generalized to every `gh/` pin, resolves the
  expected version from `Application.spec/2`, and fails when a pin appears for a
  repo it does not cover (#715).

- **Admin theme picker honours `:dashboard_themes`.** Hardcoding `:all` meant a
  host's narrowed list governed only the user dashboard (#716).

- **Removed unused `ThemeConfig` helpers** (`get_theme/0`,
  `theme_data_attributes/0`, `modern_css_variables/0`, the slider maps). They
  had no remaining in-repo callers; a host still calling them will not compile
  (#716).

- **Route-pattern tabs hide themselves from navigation.** `admin_dashboard_tabs`
  entries whose path carries `:param` or `*splat` segments are routes, not nav —
  they rendered a literal `:uuid` in the sidebar unless every host remembered
  `visible: false`. Detection is per-segment, so `https://`, ports, and `mailto:`
  are unaffected; `visible: true` is the opt-out. Nil-scope callers no longer
  receive `visible: false` tabs unfiltered (#716).

### Fixed

- **A maintenance broadcast killed admins' LiveViews.** The on_mount hook returned
  `{:cont, ...}` for an admin — maintenance never blocks them, so there was nothing
  left to do — which handed `{:maintenance_status_changed, _}` to the LiveView's own
  `handle_info`. Any view without a clause for it (most of them) died in
  `FunctionClauseError` the moment a toggle broadcast, or the hook's own
  end-of-window timer, fired while an admin had the page open (#714).

- **V171's dedup counted slug entries instead of owner rows.** A single row carrying
  two spellings of one language at the same value (`{"en":"hat","en-GB":"hat"}`)
  projects — via the trigger's `SELECT DISTINCT` — to one projection row, so it is
  not a collision. Counting entries made it one: an `active` row in that shape
  aborted the upgrade with `shared by 2 live rows`, naming a second row the operator
  would never find, and a non-live one had a spelling silently rewritten to `hat-2`,
  giving the row two public URLs where it had one. Both loops now count
  `DISTINCT uuid`, and a row that does lose a bucket moves all its spellings to the
  one candidate (post-merge review of #714).

- **`V172.down/1` deleted every `crawlers` permission grant**, though its comment
  promised only the copies `up/1` made. After the upgrade `crawlers` is a first-class
  key in the admin matrix, so a rollback discarded grants an operator had added to
  roles that never held `seo` — and re-running `up/1` could not restore them. The
  delete is now qualified by a surviving `seo` grant for the same role (post-merge
  review of #714).

- **Empty Crawlers string settings failed their first write.** The three optional
  slots (Google/Bing verification, llms.txt extra) were not in `@optional_settings`,
  so the first write of an empty value — with no row yet — failed validation and a
  form saving both slots half-applied: the non-empty one landed, the empty one
  errored, and the flash reported failure (#714).

- **Three doc sites named V170 as the rename migration; it is V172.** V170 is a real,
  unrelated migration, so the stale numbers from an in-flight renumber pointed anyone
  debugging a half-renamed settings table at the wrong file (post-merge review
  of #714).

- **`:crawlers_verifications` was assigned on every LiveView navigation and read by
  nothing.** `CrawlerMetas` reads its own settings, which is the whole point of it;
  the assign-based path it replaced was kept and extended, costing two unguarded
  settings reads per navigation for a value with no reader. Removed;
  `:crawlers_no_index` stays as the published signal for host templates (post-merge
  review of #714).

- **`crawlers_no_index?/0` in the sitemap generator guarded `rescue` but not
  `catch :exit`.** An unreachable database raises on an unowned checkout but *exits*
  on a dead pool (post-merge review of #714).

- **Host `:theme_definitions` never appeared in the default picker.**
  `dropdown_themes(:all)` was the compile-time catalogue only, so a branded
  theme landed in CSS / labels / `system_pair` and not in the picker until the
  host also listed it in `:dashboard_themes` (post-merge review of #716).

- **ThemeBootstrap stamped `phoenix-dark` without shipping the palettes.**
  Standalone admin and every host layout the installer injects into painted
  `color-scheme: dark` over daisyUI's light variables until a later body
  `<style>` arrived. The custom-theme CSS now travels with the stamp
  (post-merge review of #716).

- **Dropdown options had no `data-phx-theme`.** The toggle used the stock
  Phoenix contract; the options put the name only in `JS.dispatch` detail.
  phx.new 1.8's script reads `dataset.phxTheme` and falls back to `"system"`,
  so every dropdown click reset the theme on a host that kept that script
  (post-merge review of #716).

- **`mix phoenix_kit.update` skipped the bootstrap on every phx.new 1.8 host.**
  Any `phx:theme` substring was treated as "already done"; that script's
  `"system"` path *removes* `data-theme`. Those layouts now get the bootstrap
  just before `</head>`, after the stock script (post-merge review of #716).

- **Pagination extract missed `media_selector.ex` and
  `Auth.list_users_paginated/1`.** Same unfloored empty-list `1..0` range the
  helper exists to stop (post-merge review of #716).

- **Referral 0.4 backfill used `function_exported?/3` without
  `Code.ensure_loaded?/1`.** Under a release the new `signup_use_exists?`
  looked missing and the users the feature exists to admit stayed parked
  (post-merge review of #716).

- **Accounts that redeemed a code before the satisfied-stamp existed were
  parked at the referral wall.** The gate now asks the installed module and
  stamps on a hit, so each account pays the query at most once (#716).

## 2.5.0 - 2026-08-14

Ten findings from a high-effort review of the recently merged notifications,
fingerprint-logging and JS-compiler work, two of which needed schema support.
Chain moves V169 → **V170**.

### Fixed

- **Two concurrent upserts for the same dedupe key both inserted.** Parallel
  Oban workers or two nodes both read `nil` from `find_collapsible/2` and both
  created a row, so the user got two unseen notifications for one logical key —
  pinned to the top by the unseen-first ordering — and later refreshes folded
  into only one of them, leaving the stale twin until it was dismissed by hand.
  V170's partial UNIQUE index turns the second insert into a constraint
  violation that `insert_collapsible/3` retries as a collapse (#713).

- **`upsert_inapp/3` ignored the `notifications_enabled` kill switch.** It is a
  host-facing entry point, and "off" that quietly did not apply to the newest
  creation path was not off. Returns `{:ok, :skipped}` like `create/1` (#713).

- **Caller metadata could clobber reserved keys.** Metadata now merges *first*
  and reserved keys stamp on top, so a passed-through map can no longer
  overwrite `dedupe_key` — which silently disabled collapsing — or the display
  keys. Caller keys are normalised to strings, so `%{notification_text: …}`
  cannot coexist with the string key and win by adapter ordering (#713).

- **`find_collapsible/2` lacked `catch :exit`.** A dead pool *exits* rather than
  raising, bypassing `rescue` and crashing the caller its comment promised it
  would not — the soft-failure rule this project applies everywhere else. Both
  clauses log now, so a permanent query bug degrading upsert into
  insert-always is diagnosable rather than silent (#713).

- **The inbox ignored `:notification_updated`.** The bell handled it, the inbox
  did not, so an open inbox showed stale rows at exactly the moment an upsert
  refreshed one. A scrape test now holds the whitelist to *every* event the
  library broadcasts, so the next event added fails the test until the inbox
  handles it (#713).

- **One fingerprint mismatch logged three lines, two of them wrong.** The #705
  dedup had only landed in `fetch_phoenix_kit_current_user`; the scope plug still
  carried the old `"(scope)"` warning and an `:error`-level "possible hijacking"
  line for requests that were then served normally — and the shipped
  `:phoenix_kit_admin_only` pipeline runs both plugs. Verification now runs at
  most once per request, with the verdict cached in `conn.private` and shared
  (#713).

- **`session_label` could never match the sessions UI.** The log used a
  truncated sha256 while the UI shows hex of the raw token's first 4 bytes, so
  the promised log↔UI correlation failed every time. Both derivations are now
  the same one, held together by a test (#713).

### Migrations

- **V170** adds two indexes to `phoenix_kit_notifications`:

  - `phoenix_kit_notifications_dedupe_unseen_idx` — **partial UNIQUE** on
    `(recipient_uuid, metadata->>'dedupe_key')` over undismissed, unseen, keyed
    rows. Serves `find_collapsible/2`'s exact predicate *and* is the uniqueness
    backstop above. Rows without a dedupe key — everything the fan-out path
    creates — are outside the predicate and unaffected.
  - `phoenix_kit_notifications_recipient_unseen_first_idx` — matches
    `order_unseen_first/1`'s ORDER BY term-for-term, so the bell's
    `recent_for_user` and the inbox pages come off an index again instead of
    walking a recipient's whole undismissed backlog on every mount.

  Existing duplicates are **dismissed, not deleted** — all but the newest unseen
  row per `(recipient, key)`, the same "newest wins" choice `find_collapsible/2`
  makes. The fold and the index creation share one `SHARE ROW EXCLUSIVE` lock so
  a concurrent insert cannot re-introduce a duplicate in the gap between them.

## 2.4.0 - 2026-08-14

Slug uniqueness gets both halves it was missing — a changeset helper and the
indexes to back it — plus anonymous entity submissions, and an activity log that
is no longer readable by every dashboard-holder. Chain moves V166 → **V169**.

### Added

- **`PhoenixKit.Utils.Slug.put_slug/3`** — the changeset glue between
  `slugify/2` and `ensure_unique/2` that core never owned, so it was hand-rolled
  **14 times across 8 packages** and each copy got a different subset right. It
  distinguishes the three states `get_change(:slug)` conflates: an explicit slug
  wins, an explicitly blanked one regenerates, and *no slug in the changeset*
  means unchanged — which is what every edit form sends, and why saving one
  used to move a live URL. Suffixes `-2`, `-3` … until free, excludes the row
  itself on update, honours a schema prefix, and takes `:scope` for per-owner
  uniqueness. The probe is an allocator, not an integrity boundary — callers
  still declare `unique_constraint/3`, which is what makes it true (#711).

  Adopters must pin **`{:phoenix_kit, "~> 2.4"}`**: `~> 2.0` resolves to a core
  without this function, and the failure lands in the consumer's app.

- **`PhoenixKit.Activity.full_log_access?/1` and `own_entry?/2`** — the shared
  definition of "may read the whole audit log" and "is this entry mine",
  deliberately in one place so the list and the detail page cannot drift (#712).

### Fixed

- **`/admin/activity` crashed on any entry whose metadata held a map.** A
  field-change diff (`%{"qty" => %{"from" => 1, "to" => 2}}`) was interpolated
  straight into the template, raising `Protocol.UndefinedError` for
  `String.Chars` on a Map. Rendered as `1 → 2` now, via
  `Activity.humanize_metadata_value/1`; legacy rows that stored an `inspect`-ed
  Decimal are unwrapped to the number rather than leaking Elixir syntax (#712).

- **The full activity log was visible to every holder of the `dashboard`
  permission.** It is now administrators-only — Admin, Owner, or a `"*"`
  superadmin role; everyone else sees only entries they authored. Enforced
  server-side in the query (the pagination total is scoped too, so it cannot
  leak the existence of hidden entries), and the detail page answers *not found*
  rather than confirming another user's record exists. "Own" means **actor**,
  not target (#712).

- **Anonymous public entity submissions failed on a freshly migrated database.**
  `phoenix_kit_entity_data.created_by_uuid` was NOT NULL while the public entity
  form is deliberately unauthenticated, so every submission raised a
  `not_null_violation` out of an unauthenticated controller. **V169** relaxes the
  column, resolving a split where long-lived installs already measured
  `is_nullable = YES` and fresh ones `NO`. Auto-filling the first Owner was
  implemented first and rejected: it puts a named person in front of every
  anonymous submission and files it in their audit trail (#711, #706).

- **Eleven `foreign_key_constraint/2` declarations could never match.** Ecto
  matches by name and this chain names most foreign keys `fk_<table>_<column>`,
  not the `<table>_<column>_fkey` the bare declaration derives — so violations
  escaped as raw `Ecto.ConstraintError` 500s across storage, admin notes, OAuth
  providers, role assignments and role permissions. Names were taken from a
  migrated database rather than read off the chain, because a renamed column can
  leave a constraint carrying its old name. A new test pins the rule so the next
  schema cannot repeat it (#711).

- **`ensure_unique/2` overflowed a `:max_length` the caller had already
  applied** — `slugify(title, max_length: 20)` plus `-2` is 22 characters, which
  silently defeats an SEO cap and *raises* against `varchar(n)`. It now trims the
  base per candidate, since `-10` needs one more character than `-9` (#711).

- **`V169.down/1` locked a table it never checked existed.** `up/1` guards its
  `phoenix_kit_entity_data` work on table existence; `down/1` reached straight
  for `LOCK TABLE`, which has no `IF EXISTS` form — so rolling back on an install
  without the entity tables aborted with `relation does not exist`, having had
  nothing to undo. Found in post-merge review; `lock_table_guard_test.exs` now
  pins the rule for every `LOCK TABLE` in the chain.

### Migrations

- **V167** — `phoenix_kit_posts_slug_index` becomes unique. It had been a plain
  btree since V135 while its sibling `post_tags.slug` was unique, so `Post`'s
  `unique_constraint(:slug)` had no index to translate and `get_post_by_slug/2`
  (which fetches with `one()`) raised `Ecto.MultipleResultsError` on any shared
  URL. Existing duplicates are suffixed by the same rule `ensure_unique/2`
  applies at runtime, keeping a reachable post over a draft and then the oldest;
  **two live posts on one slug raises instead**, because which one keeps the URL
  is the operator's call.

- **V168** — the remaining two. `phoenix_kit_tickets` had a plain btree;
  `phoenix_kit_post_groups` had no slug index at all while `PostGroup` named a
  composite `[:user_uuid, :slug]` index that existed nowhere. Post-group slugs
  are unique **per user**, so that index is scoped to the owner.

- **V169** — the nullable creator column and the duplicate `prompt_uuid` foreign
  key described above. The **legacy** `phoenix_kit_ai_requests_prompt_uuid_fkey`
  is the survivor, since it is what the installed base carries and what Ecto
  derives by default, so no live database is renamed.

  The `DROP` before each `CREATE UNIQUE INDEX` is load-bearing:
  `CREATE UNIQUE INDEX IF NOT EXISTS` matches on **name**, so building a unique
  index over a non-unique one of the same name skips with a notice and reports
  success while uniqueness stays unenforced.

## 2.3.0 - 2026-08-13

Localized country selects with operator-chosen pinning, two new integration
providers, and a scheduled-jobs sweep that no longer dies at `:debug`. No schema
change — the chain stays at V166.

### Added

- **Country selects follow the active locale, and an operator can pin the
  countries they actually serve.** `countries_for_select/1`,
  `eu_countries_for_select/1` and `get_country_name/2` take `:locale` (defaulting
  to the active Gettext locale, dialects reduced to their base — `ru-RU` → `ru`)
  and `:priority` (alpha-2 codes pinned to the top, defaulting to the new
  `country_select_priority` setting). Names come from
  `BeamLabCountries.Translations` and a locale with no data falls back per
  country, so a host only ever loses the translation, never the entry. Sorting
  moves to the localized name with NFD accent folding — a deliberate
  approximation, not collation; locales that give diacritics their own alphabet
  position (Estonian's Ü, Swedish's Å/Ä/Ö) are sorted into the base letter's
  block instead. Both functions still work with no arguments (#708).

- **A "Main countries" card on Admin → Settings → Organization** to choose that
  pinned list: drag to reorder, keyboard move buttons alongside (SortableJS is a
  CDN fetch a strict CSP can block, and dragging has no keyboard path), a
  searchable picker, and a suggestion derived from the organization's own
  country by great-circle distance rather than from a constant baked into the
  library. Nothing is pinned until an operator stores a list (#708).

- **GitHub and Amazon Bedrock integration providers.** GitHub takes a
  fine-grained read-only PAT, validated against `/rate_limit`. Bedrock takes a
  long-term API key (plain Bearer, no SigV4) plus a region, validated with a new
  `:amazon_bedrock` strategy that lists foundation models in that region — the
  cheapest call proving the key, the region and `bedrock:CallWithBearerToken` at
  once. Bedrock declares `:ai_completions`; both carry step-by-step setup
  instructions (#707).

- **`mix phoenix_kit.doctor` gained "Oban Cron Queues"** — reports crontab
  entries whose queue this node does not run, resolving queues the way
  `Oban.Plugins.Cron` does and staying quiet where a warning would be wrong
  (`queues: false`, `queues: []`, `testing: :inline | :manual`). Its warning says
  what taking the advice will do: configuring the queue releases the whole
  backlog at once (#710).

- `aws_ses` "Test connection" now reports the account id and which management
  APIs the key may use (SES/SQS/SNS), via the same `CredentialsVerifier` sweep
  the Emails settings page runs. Strictly additive — the send-quota probe remains
  the verdict, and enrichment failing can never downgrade it (#707).

### Fixed

- **The scheduled-jobs sweep died before doing any work, at `:debug`.**
  `ProcessScheduledJobsWorker.perform/1` logged `job.id`, but `ScheduledJob`'s
  key is `:uuid`. `Logger.debug` defers evaluation, so at `:info` the
  interpolation never ran and the mistake stayed invisible; at `:debug` it raised
  `KeyError` before reaching `process_pending_jobs/0`, and with `max_attempts: 1`
  Oban discarded the sweep rather than retrying. A host running debug logging
  published nothing at all, silently, for as long as it ran (#710).

- **Upgrading never added the `scheduled_jobs` queue.** The crontab entry entered
  the generated config on 2025-12-28 without it; the fresh-install block was
  fixed in 1.7.63 but the upgrade path had no helper for that queue, so hosts
  installed in between were never repaired — one was found 15 days in with 21,337
  jobs stuck in `available`, growing ~1,440/day, because Pruner deletes terminal
  states only. `ensure_scheduled_jobs_queue/2` fills the gap (#710).

- **Every `ensure_*_queue` helper now shares one hardened implementation.** The
  six that predated `scheduled_jobs` each hand-rolled the same string surgery on
  the host's `queues:` list and reproduced the same defects — worse than the
  missing queue, because a bad insert *corrupts* `config.exs`: `queues: [\n]`
  wrote `queues: [,`, a nested `default: [limit: 10]` swallowed the insert into
  an option Oban rejects at boot, and an Oban block with no `queues:` of its own
  let the scan walk into a neighbouring application's config. Their unanchored
  guards were also satisfied by a key merely *ending* in the queue's name, so a
  host's own `push_notifications: 5` silently suppressed the real
  `notifications` queue.

- **The cron migration claimed to replace the old posts worker and did not.** The
  replacement literal named `PhoenixKit.Posts.Workers.PublishScheduledPostsJob`,
  a module in no repo — the real one is `PhoenixKitPosts.Workers.…`. The guard
  matched, the replace found nothing, and being `cond`'s first clause it shadowed
  every later case, so the core worker was never added either: an upgrading host
  kept the old entry, gained nothing, and was told the opposite. Hosts running
  both entries are now told to remove one rather than silently given a duplicate
  (#710).

- **The editor bundle is pinned to the leaf release we actually resolve.** The
  CDN tag still served v0.3.2 while hex resolved 0.5.1 — almost everything leaf
  adds is a server↔client contract, so the stale bundle rendered an identical
  editor and quietly stopped implementing what the server expected. A test now
  compares the pin against `Application.spec(:leaf, :vsn)` so the two cannot
  drift again (#709).

- The Organization settings page no longer builds country labels by
  concatenating a nilable flag, which would have raised `ArgumentError` in
  `load_settings/1` and taken the whole page down. Every current
  `beamlab_countries` row carries a flag; this stops depending on that.

- **Role rows are no longer a deadlock hotspot.** Every insert into
  `phoenix_kit_user_role_assignments` makes PostgreSQL take a `FOR KEY SHARE`
  lock on the referenced `phoenix_kit_user_roles` row to validate the foreign
  key — and two paths were taking a conflicting plain `FOR UPDATE` on those
  same rows: `Roles.ensure_first_user_is_owner/1` (the Owner row, on *every*
  registration) and `Permissions.lock_role_for_update/2` (the target role row,
  on every grant/revoke/`set_permissions`). Assigning a role therefore blocked
  on unrelated permission edits, and two transactions each holding one role row
  and then referencing the other's deadlocked outright (`40P01`). Both sites now
  use `FOR NO KEY UPDATE`: neither mutates the role's key, so the guard still
  excludes the writers it exists to exclude while leaving FK checks free.

- **Registration no longer serializes app-wide.** `ensure_first_user_is_owner/1`
  held that Owner-row lock on every single registration, so all registrations
  queued behind one row for the life of the install. Once an active Owner
  exists the answer can never flip back to "you are the first user", so the
  count is now read unlocked and the lock is taken only while no Owner exists.
  A missing Owner role row also rolls back cleanly instead of raising.

- Silenced `DBConnection.OwnershipError` in `PhoenixKit.Settings` reads. It is
  the Ecto-sandbox spelling of `repo_available?() == false`, which this module
  already answers with a silent `nil`; it cannot occur outside a sandboxed
  repo, so no production logging changes. It was emitting ~960 lines per
  `mix test` run and burying real failures.

- Fixed a call to the nonexistent `PhoenixKit.repo/0` in the notifications
  inbox-grouping test (`RepoHelper.repo/0`), which had never run.

### i18n

- New msgids for the Main countries card (`et`, `ru`, `en`) (#708).

## 2.2.0 - 2026-08-11

Notification collapsing, an honest fingerprint log, and a compile-time warning
for a silent JS-hook misconfiguration. No schema change — the chain stays at
V166.

### Added

- **`Notifications.upsert_inapp/3`** (#704) — the GitHub-style collapsing
  entry. A repeat event refreshes the row already standing for the same key
  ("3 new comments on earlier chapters") instead of posting another beside it.
  Only **unseen** rows collapse: once someone has read a notification the next
  event is news again and gets its own row, so nothing new can be hidden inside
  something already dealt with. Broadcasts `{:notification_updated, n}` for a
  refresh and `{:notification_created, n}` for a new row, so an open bell keeps
  up without the caller broadcasting anything. Doing this before meant querying
  the schema directly and re-broadcasting by hand — one host that tried it
  schemalessly stringified `metadata` into the jsonb column and 500'd that
  user's bell.

  `create_inapp/2` now also carries `:dedupe_key` and merges a caller's
  `:metadata`; both were dropped silently before.

- **A compile-time warning when installed modules ship JS hooks the host will
  never load** (#703). `js_sources/0` is consumed only by the
  `:phoenix_kit_js_sources` compiler; a host without it in `:compilers` got no
  bundle, no error and no warning, while the module's templates went on
  rendering `phx-hook` names the LiveSocket had never heard of.
  `phoenix_kit_boards` shipped that state twice before anyone traced it. Silent
  when the compiler is present and when nothing declares a bundle.

### Changed

- **The session-fingerprint log says something worth reading** (#705). A
  user-agent change with an unchanged IP is `:info`, not `:warning` — browsers
  rewrite their UA roughly monthly, for every user, and one reporting app
  carried 765 of these in a single log. Every line now names its session (a
  truncated SHA-256 of the token; the raw token is a bearer credential and
  never reaches the log), and the duplicate line in `PhoenixKitWeb.Users.Auth`
  that said only `"for token"`, naming no token, is gone.

- **A mismatch is logged at the level its consequence earns.** Strict mode
  refuses *every* fingerprint mismatch, so under strict mode all of them log at
  `:error` and say `access denied`; otherwise the request is served and the
  line takes its own severity. Logging "possible hijacking attempt" at `:error`
  and then serving the request is what taught people the log was noise — and
  the inverse was just as bad: a strict-mode host logging someone out over a
  browser update recorded it at `:info`, below the default threshold, so there
  was no record at all.

### Fixed

- **`upsert_inapp/3` could silently stop collapsing forever.** When the row
  vanished between the read and the write, the replacement was posted without
  its dedupe key, so it could never be found again and every later event for
  that key opened a new row.

- **`upsert_inapp/3` could lose an event to a row the user had just dealt
  with.** The `update_all` filtered on `uuid` alone, so a comment dismissed or
  read between the read and the write was refreshed anyway: the update reported
  success and the event ended up recorded only on a row that would never be
  shown again. The unseen/undismissed guard now appears in the write as well as
  the read.

- **The JS-hook warning no longer breaks the build.** It was emitted with
  `IO.warn/1`, which registers a compiler diagnostic — so on any host building
  with `--warnings-as-errors` it failed the compile on upgrade, over a mix.exs
  condition that was not a regression in the host's own code.

## 2.1.0 - 2026-08-11

Notification reads sort unseen first. No schema change — the chain stays at V166.

### Changed

- **A user's notifications now sort unseen-before-seen, newest-first within
  each group** (#702), in both `Notifications.list_for_user/2` and
  `recent_for_user/2`. Plain newest-first interleaved the two, so reading a
  notification left it exactly where it was and anything still outstanding
  ended up scattered among things already dealt with. It mattered most in the
  bell: the dropdown shows ten, so an already-read notification could push an
  unread one off the bottom entirely — the badge counted something opening the
  bell did not show.

  `admin_list/1` is deliberately unchanged. "Seen" belongs to the recipient,
  and an admin scanning everybody's notifications is reading a chronological
  record, not working an inbox.

- **Notification ordering is now total.** `inserted_at` is second-granularity,
  so a fan-out writing many rows inside one second tied every one of them, and
  a tie under `LIMIT`/`OFFSET` lets Postgres return a row on two pages or on
  neither. `uuid` is now the final sort key on all three paginated reads; the
  keys are UUIDv7, so descending on it agrees with newest-first.

### Fixed

- **The notifications inbox rendered duplicate day headers.** `grouped/1`
  chunked rows into day buckets on the day alone, which was correct only while
  the list was globally chronological. Under the new order the day sequence
  restarts at the seen block, so an inbox holding read and unread rows across
  more than one day showed "Today" twice, a week of history apart. Sections are
  now keyed on `{unread?, day}` and the unread run is labelled `Unread · <day>`,
  so the outstanding work is named rather than inferred from row tint.

## 2.0.1 - 2026-08-10

Closes the "reports a problem, then exits 0" gaps across `status`, `doctor` and
`update`, and adopts `locale_slug` 0.2.0 so Cyrillic slugs beyond Russian stop
coming back empty. No schema change — the chain stays at V166.

### Added

- **`mix phoenix_kit.status --exit-code`** (#701). The report is identical on
  stdout whether an install is clean or has a module sitting four versions
  behind, so a deploy script had nothing to gate on. Opt-in, because the default
  is load-bearing the other way: pipelines that run the task purely for its log
  line must not start failing on an upgrade. It **fails closed** — an install
  whose core marker reads `Ready` while the module list was never queried exits
  `1`, since the two reads are independent and a connection dropping between them
  produces exactly the silent pass the flag exists to remove.
- **`mix phoenix_kit.doctor` gains a "Module Schema Versions" check** (#701).
  Core's version marker says nothing about a module that owns its own migration
  chain, so an install could pass `status`, pass `doctor`, and still run code
  against tables several versions behind — surfacing as an undefined-column 500
  on that module's admin page, with no visible connection to the upgrade that
  caused it. Fails on a module that is behind; warns, rather than passing, when a
  version cannot be read at all.
- **`mix phoenix_kit.doctor --exit-code`** (#701 post-merge review). Doctor
  printed `N failures` and `Fix the FAIL items above before running migrations.`
  and then exited `0` — including for the new module-version check, whose whole
  purpose is to catch an install nothing else reports on. `status` and `repair`
  both gate; doctor was the only one of the three that could not. Opt-in, same
  reasoning as above. Warnings deliberately do not gate: several fire on healthy
  installs (a pool capped by `update_mode`, an unlocatable `application.ex`), and
  gating on them would put the flag straight back to a signal nobody can act on.

### Changed

- **`locale_slug` adopted at `~> 0.2.0`** (#701). 0.1.0's Cyrillic layer only
  really covered Russian, and against core's `fallback: :empty` passing the
  *correct* locale reproduced the bug the dependency exists to fix:
  `slugify("Київ", locale: "uk")` and `slugify("България", locale: "bg")` both
  returned `""`, which callers read as "not generated yet" and regenerate
  forever. 0.2.0 returns `kyiv` and `bulgaria`. Cyrillic output is the only thing
  that moves — German, Estonian, Greek, `script: :native` and plain accented
  Latin are byte-identical. Stored slugs are never rewritten. The pin stays
  three-segment on purpose: a revised romanization table changes slugs that are
  persisted in URLs and compared for uniqueness, so adopting a minor is a
  deliberate release decision, not something `mix deps.update` should do.
- **`mix phoenix_kit.repair`'s footer groups findings by kind and by table**
  (#701). A severity count does not say what a run is *about*. A few hundred
  findings on a long-lived database become readable the moment they are grouped —
  on one real install the new footer showed 97 of 265 findings concentrated in
  five warehouse tables, the one fact that makes the report actionable, and
  previously reachable only by reading every line.
- **The "comment ahead of schema" message no longer overstates the damage**
  (#701). `highest_fully_present_version/1` is a `take_while`: it stops at the
  first version with a missing object and never looks higher. Reporting that as
  "objects since N..comment are missing or diverged" claimed a range the check
  had not examined — on a real install the headline read **V35..V166** when all
  that had been established was that V35 was incomplete. The message now names
  the boundary and states plainly what it does not mean.

### Fixed

- **Module schema migrations were skipped when the migrate step aborted** (#701).
  A pending core migration raised *before* `run_module_migrations/1`, so no module
  migration file was ever written — and the error message listed `mix ecto.migrate`
  **first**, which applied the core chain, exited 0, and left the module's tables
  where they were. The files are now written before the raise (including when the
  operator answers "no" at the prompt, which the note says plainly), and the
  advice leads with `mix phoenix_kit.update --yes`.
- **`mix phoenix_kit.repair`'s by-table breakdown invented tables out of index
  names** (#701 post-merge review). The table was parsed as "the segment between
  the first `:` and the first following `.` or `:`", which four of the manifest's
  eight object classes satisfy without carrying a table at all —
  `index:idx_calendar_events_owner_starts_at` was tallied as a table of that
  name. Against the manifest that is 616 index ids (plus 6 sequences, 3
  extensions, 2 functions) inventing single-finding rows, versus 161 real tables.
  Since missing tables come with their missing indexes, the `+N more tables` tail
  was inflated worst on exactly the runs where an operator is trying to judge how
  widespread the damage is — the number the feature was added to provide. Only
  the four table-scoped classes now contribute; deriving a table from an index
  *name* would be guessing, and those findings stay visible under `by kind`.
- **The reworded "comment ahead of schema" message named a version that has
  nothing to be missing** (#701 post-merge review). It derived the first gap as
  `lower + 1`, but `highest_fully_present_version/1` returns the *`since` of the
  last consecutive present bucket*, not an ordinal — its own doctest answers `114`
  for a list whose first absent version is `137`, which rendered as "V115 is the
  first version whose objects are not all present". Reachable in practice: the
  bucket list is only contiguous from the migration floor up, and 28 chain
  versions introduce no manifest object. The first genuinely absent bucket is now
  read from the presence list.
- **`mix phoenix_kit.doctor`'s module check dropped unreadable modules when
  another module was behind** (#701 post-merge review). Its `cond` tested
  "behind" before "unreadable", so a run with both reported only the first and
  the unreadable module vanished from the report entirely — the one condition an
  operator cannot discover any other way, and the reason `StatusReport.next_action/3`
  and the status tree both surface it first. Both are now reported; the severity
  stays `:fail`.
- **The doctor moduledoc's "Checks Performed" list was five checks stale**
  (#701 post-merge review) — missing UUID Primary Keys, User Dashboard, Sitemap
  Discoverability, Demo Auth Pages and the new Module Schema Versions. Rebuilt
  against the order `run/1` actually executes.

## 2.0.0 - 2026-08-10

### ⚠️ Upgrade requirement — databases below V135 must stop at 1.7.236 first

**The migration chain is squashed** (#689). `V01`..`V134` are replaced by a
single `V135` baseline, and V135 is now the chain's **floor**: this release no
longer carries the migration modules below it.

- **At V135 or above** (any install kept current through 1.7.x): nothing to do.
  Upgrade normally.
- **Below V135**: `mix ecto.migrate` raises `PhoenixKit.Migrations.BelowFloorError`
  and refuses, rather than migrating. Install **1.7.236** — the migration bridge,
  the last release carrying the full pre-squash chain — run its migrations until
  the reported version is at least V135, and only then upgrade to this release.
  The error message names the bridge and the procedure.

Check where you are with `mix phoenix_kit.status` **before** upgrading.

**This is why the version is 2.0.0.** Refusing a below-floor install rather than
migrating it is a breaking upgrade contract, and a major version is what stops a
host from being carried across the floor by a routine `mix deps.update`: a
`{:phoenix_kit, "~> 1.7"}` requirement does not resolve to 2.0, so reaching this
release is now a deliberate act with a chance to read this section first.

### Feature modules need a widened pin before you move to `~> 2.0`

`phoenix_kit_*` packages pin core at `~> 1.7.x`, which does not accept 2.0. So
`{:phoenix_kit, "~> 2.0"}` alongside a module that has not yet widened its
requirement is an unsatisfiable dependency: `mix deps.get` fails and names the
conflict. Each module needs a widened requirement and a patch release; none of
them call migration internals, so the change is the pin itself.

**If you stay on `{:phoenix_kit, "~> 1.7"}`, nothing changes for you** — that
requirement does not resolve to 2.0, which is the same property that protects
below-floor installs. Move your own pin to `~> 2.0` once the modules you use have
released theirs; until then the failure is a resolver error at `mix deps.get`
time, not a broken build.

Nothing is rolled back through this release either: a below-floor install cannot
`down` through it.

### Added

- **Verify-and-repair for the schema** (#689). `mix phoenix_kit.repair` compares a
  live database against a generated manifest of what the chain should have
  produced (`PhoenixKit.Migrations.ExpectedSchema`) and can restore what is
  missing; `mix phoenix_kit.repair_uuid` is the maintenance-window path for uuid
  primary-key damage, building its unique index `CONCURRENTLY`. Both report
  before they write, and `mix phoenix_kit.doctor` grew checks that use the same
  manifest.
- **`PhoenixKit.Migrations.BelowFloorError`** (#689) — the explicit refusal
  described above, carrying the database's version, the floor, and the bridge
  release to install. Names 1.7.236 rather than "the last 1.7.x" (#690).
- **`dev_mailbox_enabled` setting and its toggle** (#697) on
  `/admin/settings/email-sending` — the section appears only when the resolved
  transport is the local mailbox, and switching it on states the consequence.
- **`PhoenixKit.Mailer.resolved_send_path/0`** (#697) — the one answer to "where
  will this message actually go": `{:integration, uuid}` or
  `{:mailer, module, adapter}`.
- **Upload rate limiting** (#697) — `RateLimiter.check_upload_rate_limit/1`,
  30/min keyed on the **uploading** account (never the attributed owner, which
  would hand an admin a fresh window per victim uuid).
- **`mix prerelease`** (#690) — the release gate: locked deps, a production
  compile, `quality.ci`, `deps.audit`, `hex.audit`, docs, `hex.build`, and
  `mix phoenix_kit.release_check` (CHANGELOG heading, migration/version sync,
  clean tree, branch, tag collision). It catches release-metadata drift that
  `mix precommit` structurally cannot.

- **Cross-module `@` mentions and `#` record links** (#692). `PhoenixKit.Mentions`
  — typing `@` offers people, `#` offers records from every installed module. The
  mention is stored as a self-contained token carrying its own label, so it
  survives copy-paste, export, edit history and a module being uninstalled, and
  degrades to readable text rather than a broken link. Titles are re-resolved per
  viewer at render: a reader who may not open a record never sees a title
  refreshed after the fact, and visibility fails CLOSED for any resource type
  whose module declares no check. Adds `phoenix_kit_mentions` and
  `phoenix_kit_access_requests` (**V165**), the `<.mention_text>` component,
  `use PhoenixKit.Mentions.Live` for the write side, and `mentions` opt-in
  attributes on `<.textarea>` and the multilang textarea. Settings:
  `mentions_enabled` (default on), `mentions_redact_titles` (default off).
- **Frozen comment attribution** (#692, **V166**). `author_display_name`,
  `attribution_mode`, `attributed_project_uuid` and `attributed_label` on
  `phoenix_kit_comments`: a name resolved at render time re-signs every comment
  its author ever wrote, so what the reader was shown is pinned at write.
  `user_uuid` is never cleared — posting as a project changes what the public
  sees and nothing else.
- **`Notifications.fan_out_from_activity/2`** (#692) — routes one committed
  activity entry to many recipients through the same prefs/channel/digest
  machinery, without inserting extra feed rows.
- **`before_user_delete/1` module hook** (#692) — runs for every discovered
  module before a user row is deleted, while their related rows still exist.
  Best-effort: a hook that raises or throws is logged and never aborts the
  deletion.
- **`ImageProcessor.sanitize/3`** (#692) — re-encodes an untrusted upload to
  known-good bytes (detected-and-allowlisted decoder, first frame only, metadata
  stripped, local resource ceilings, declared-pixel-count refusal). A primitive:
  no core upload path calls it yet.
- **User-dashboard route auto-discovery** (#692) — an external module's
  `user_dashboard_tabs/0` entry carrying a `live_view` now gets its route
  generated, mirroring the admin-tab path.

### Changed

- **⚠️ Local dev-mailbox delivery is now opt-in** (#697, issue #687). A stock
  `mix phx.new` app puts `Swoosh.Adapters.Local` in `dev.exs` and forwards
  `/dev/mailbox` with **no authentication** — and PhoenixKit sends password-reset,
  magic-link, confirmation, email-change and invitation mail through it, each
  carrying a single-use token that exists nowhere else (only its SHA-256 hash is
  stored). Anyone who could reach the dev server could read those links.

  New setting `dev_mailbox_enabled`, default **off**. While it is off and the
  resolved transport is the local mailbox, mail is **not** handed to the adapter:
  recipient, subject and body go to the server log, and the call returns
  `{:ok, %{suppressed: true, …}}` so auth flows still succeed. The gate sits
  before the tracking pipeline, so a suppressed message is not recorded as sent.
  Turn it on for a closed environment at `/admin/settings/email-sending`, or
  configure a send integration there.

  **The cost, named:** an upgraded dev install stops filling `/dev/mailbox` until
  someone flips the switch. Every suppressed send says so in the log, the
  development notice changes visibly, and the settings page carries a banner.
- **⚠️ `GET /api/files/:uuid/info` now requires authentication** (#697) and
  answers only for a file the caller owns, or to an Owner/Admin — with an
  identical `not_found` for a foreign and a missing file, so it is no longer an
  existence oracle. This is documented host API: a caller using it anonymously,
  such as a public gallery front-end, must now authenticate.
- **`Config.mailer_local?/0` resolves the way `deliver_email/2` actually sends**
  (#697, issue #687). It read `config :phoenix_kit, PhoenixKit.Mailer` alone, so
  it was wrong in both directions: `false` on a delegation-mode host whose real
  mailer is Local, and `true` on a host with the installer-written Local block
  that delegates to a real mailer. New `PhoenixKit.Mailer.resolved_send_path/0`
  is the single source — default send integration → delegated host mailer →
  built-in — and anything asking "does mail land in the local mailbox?" must go
  through it rather than a raw config read.
- **The development notice no longer links to `/dev/mailbox`** (#697). It was
  rendered to anonymous visitors on the login, registration, forgot-password and
  magic-link pages — a signpost for a developer and a map for everyone else. The
  copy now reflects the gate's state instead.
- **Slug generation moved onto the `locale_slug` package** (#693) — a new required
  runtime dependency, pure Elixir with no dependencies of its own.
  `PhoenixKit.Utils.Slug` keeps its public shape (`slugify/2`, `transliterate/1`,
  `ensure_unique/2`) and delegates the rule. The hand-rolled table could not
  express a locale, and produced `gro-e-fu-ball` for `Größe Fußball`, `caf` for
  `Café`, `n-c-d-t-st` for `Ünïcödé Tëst`, and an **empty** slug for any
  Cyrillic-only title whose caller forgot `transliterate: true` — which callers
  read as "no slug yet" and regenerated forever. Romanization is now always on
  (`:transliterate` is accepted and ignored), `:locale` and `:max_length` are new
  options, and Greek is covered.

  ⚠️ **Stored slugs are not rewritten and existing URLs are unaffected**, but a
  caller that *re-derives* a slug from a title to look up a row now derives a
  different string. This is not confined to Cyrillic content — see the accented
  Latin examples above.

  ⚠️ **`Slug.transliterate/1` now lower-cases its result.** The old table had only
  lowercase Cyrillic keys, so it left case alone and half-mapped uppercase input
  (`Кашпо` → `Кashpo`). Core's only caller downcases first; external callers that
  need the original casing must keep their own copy.
- **`locale_slug` pinned `~> 0.1.0`** (#693 post-merge review), not `~> 0.1`. The
  looser form admits every 0.x, and the exposure is not the API but the OUTPUT: a
  revised romanization table changes the slug a host derives from the same title,
  and slugs are persisted in URLs. Adopting a new minor should be a deliberate
  PhoenixKit release, not a `mix deps.update` side effect.
- **One canonical `User.display_name/1`, and no more published email addresses**
  (#692). Half a dozen private copies of the name chain ended `|| user.email`,
  which is how a public issue board came to print commenters' full addresses next
  to their words. The chain is now organization name → first+last → username →
  the email's **local part** → `"User"`, with every rung trimmed and rejected when
  blank. Never the full address.

### Fixed

- **`admin_update_user_password/3` wrote the password hash for any caller**
  (#690). The rank rule lived only in the admin edit form, which asks
  `can_manage_user_credentials?/2` to hide the UI and refuse the event — the
  context function itself asked nothing. The actor was already threaded through
  `context` for the audit row, so it now authorizes as well as audits: an actor
  present and out of rank is refused, and an absent actor stays the system path
  for seeds, migrations and mix tasks. Not reachable through the shipped UI at
  the time — this closed the second caller before it existed. See also the
  `custom_fields` bypass below, which was the second caller.
- **`POST /api/upload` and `GET /api/files/:uuid/info` required no
  authentication** (#697). Both live in a scope that fetches a user but never
  requires one. Upload took the file owner from `params["user_uuid"]` with the
  check never written, so an anonymous client could attribute a 100 MB upload —
  and the variant-processing job it enqueues — to any account. File-info handed
  out freshly-signed capability URLs for any file uuid to anyone, defeating the
  signing scheme, and its 200/404 split was a file-existence oracle. Upload now
  authorizes before touching the body (401 when unauthenticated, the `user_uuid`
  override honored only for an Owner/Admin, otherwise attributed to the
  uploader) and is rate-limited at 30/min per account.
- **`update_user_status/3` and `toggle_user_confirmation/2` wrote for a malformed
  actor** (#696). Both ended in a catch-all that performed the *unchecked* write.
  That branch exists for callers with no actor — seeds, mix tasks, and
  `Users.Referrals` expiring an account — but it also swallowed an `:actor` that
  was present and the wrong shape: a map decoded from JSON by a host controller,
  a bare uuid string. `toggle_user_confirmation/2` is the serious one, since its
  unchecked path clears `confirmed_at` and locks the target out of every
  confirmation-gated page. Both now use the three-branch shape from
  `admin_update_user_password/3`. An explicit `actor: nil` still takes the system
  path, identically in all three.
- **A never-analyzed table was sized as 0 rows** (#695). `reltuples = -1`
  (PostgreSQL ≥ 14: never vacuumed or analyzed — a `pg_restore`, a
  `CREATE TABLE AS`, logical replication, autovacuum off) was collapsed to `0`,
  so V163's size guard read "small enough, proceed" for a table nobody had ever
  measured. A restored 200k-row table took `ACCESS EXCLUSIVE` for a full rewrite
  mid-deploy — the exact event the guard exists to prevent. `estimated_rows/3`
  now answers `:unknown`, V163 defers on it, and `mix phoenix_kit.repair_uuid`
  prints "size unknown — never analyzed" rather than "~0 rows" to whoever is
  sizing a maintenance window.
- **`mix phoenix_kit.repair --adopt` stamped over a corrupt version comment**
  (#695). `Repair.Probe` collapsed "no comment" and "unreadable comment" into the
  same `nil`, so the operator was told the comment was *missing* while the table
  said `v164`, and adopt overwrote it — destroying the only record of what the
  last person believed. Unreadable is now its own state and refuses instead.
- **One flaky catalog read could abort V164 mid-run** (#695). Its post-ADD
  verification moved to a probe that *raises*, where the check it replaced
  returned false; V164 has no `rescue` and runs with `@disable_ddl_transaction`,
  so a single failed read on one of ~70 constraints aborted with earlier repairs
  already committed and the version comment never stamped, replaying the whole
  version next time. A probe failure is now one `{:failed, …}` summary line.
- **`comments_fk_on_delete/1` read a constraint by name alone** (#695), so a
  CHECK or a foreign key on a different column owning `fk_comments_user_uuid`
  answered for the real one — an impostor's `confdeltype` of `'n'` read as
  "already SET NULL, nothing to do" and the genuinely missing foreign key was
  never created.
- **`mix phoenix_kit.status --verbose` crashed on an unreadable version comment**
  (#695) — the non-verbose path reported the state correctly and the same run
  then died with `CaseClauseError` immediately after printing a correct tree.
- **A comment-less database reported itself as version 1** (#694). A database
  that is current but has lost its `phoenix_kit` version comment — the
  half-installed or adopted state — resolved to version 1, which is below the
  floor, so `mix phoenix_kit.update` answered "install the 1.7.x bridge first":
  the one instruction the migrator refuses to give, because replaying the
  pre-squash chain over a possibly-current database backfills still-NULL tracked
  columns with invented uuids and then deletes the rows that match no user. The
  state is now distinct from both a real version and "not installed", and routes
  to `doctor` + restamp. `mix phoenix_kit.status` reports it instead of crashing.
- **`mix phoenix_kit.repair` crashed on the anomaly it exists to diagnose**
  (#694). `Repair.Probe.read_comment/2` used `String.to_integer/1` eleven lines
  below a docstring promising it never raises, so the exact hand-edits the
  migrator documents (`'v164'`, `' 164'`) ended the run in a bare
  `** (ArgumentError) argument error`.
- **`ensure_uuid_v7_function/1` aborted migrations on DBA-owned functions**
  (#690). Its `insufficient_privilege` rescue was dead code in migration
  context: `Ecto.Migration.execute/1` only *queues* the statement, so the error
  arrives at flush time where no rescue can reach it. That is the topology
  `PhoenixKit.Migration`'s own moduledoc tells a DBA to adopt, and the helper
  runs on every delta upgrade. The un-ownable case is now excluded before the
  statement is queued, via `pg_has_role` — so a function owned by a role the
  migrating role belongs to is still refreshed.
- **V164 warned "reconcile by hand" about the foreign key it then repairs**
  (#690), and **verified that key by name alone** (#694) — a CHECK constraint
  owning the same name read as present, the guarded ADD failed with 42710 into
  an `EXCEPTION WHEN OTHERS`, and the outcome was reported `:created` with no
  foreign key. `contype = 'f'` is now part of the test.
- **V163's size guard is checked before castability** (#694). `castable?/3` is a
  full-table scan, so asking it first made the deferral path pay an unbounded
  sequential scan on exactly the tables the size limit exists to keep out of
  `mix ecto.migrate`.
- **V165 recorded the schema version as `163`** (#692 post-merge review). Every
  other migration in the chain stamps its own number going up; V165's `up/1`
  stamped two behind, so an install migrated to exactly 165 reported 163 — behind
  where it started — and the next `ensure_current/2` re-ran V164 and V165. A full
  run to head hid it, because V166 stamps immediately afterwards.
- **The `@` mention typeahead no longer issues ~128 queries per keystroke**
  (#692 recheck). `Mentions.Users.search/2` over-fetched and then called
  `Scope.for_user/1` per candidate (roles + permissions each), so a full page of
  results paid two round trips per row. The admin-area rule is now one SQL
  `EXISTS` for Owner/Admin and one for any `role_permissions` grant, with the
  `limit` applied in the database.
- **Access requests no longer accept free-form type/uuid payloads unthrottled**
  (#692 recheck). `AccessRequests.request/4` now requires a type registered in
  `ResourceLinks.handlers/0`, a castable uuid, and a per-account rate limit
  (10 / 10 minutes) — the partial unique index only stops repeats for the *same*
  resource.
- **`ExpectedSchema` knew nothing of V165/V166 objects** (#692 recheck). The
  schema manifest was still stamped at V164, so `release_check` blocked the
  release and `repair`/`verify` would have been blind to the two new tables and
  the comment-attribution columns. V165/V166 objects are now hand-declared
  (same post-generation path as V164) and `chain_hash` restamped over the 32
  shipped files.
- **A record's NAME could inject a markdown link into every mention of it**
  (#692 post-merge review). `to_markdown/2` escapes the value it splices into
  `[text](url)` on the reasoning that the token grammar refuses `]` — true of the
  author's stored label, false of the live resolved title, which is the record's
  current name and unconstrained. Renaming a record to
  `Evil](https://evil.example)` turned every markdown-rendered mention of it, for
  every reader, into a link to the attacker's URL. `]` is now escaped, and the
  destination uses the CommonMark angle form so a `)` in a handler-supplied path
  cannot close it either.
- **`<.mention_text>` told hosts to `use PhoenixKit.Mentions.RequestAccess`**
  (#692 post-merge review), which does not exist — the module is
  `PhoenixKit.Mentions.Live`, and it needs `<.access_request_dialog>` rendered
  alongside it or the click sets an assign nothing reads.
- **The credential rank rule was bypassable through `custom_fields`** (#691).
  `Auth.update_user_fields/2` routes a `custom_fields` key whose name matches a
  profile field out of the JSONB column and writes it to the schema — including
  `:email`, with no confirmation-token flow. The admin user form handed it
  `params["custom_fields"]` verbatim, so the `Map.drop` that protects the profile
  params never saw it: an actor holding only the `users` permission could point an
  Owner's address at their own inbox and then take the account through the public
  password-reset page. The form now filters those names out of `custom_fields`
  unconditionally, `admin_update_user_password/3` enforces the rank rule in the
  context rather than trusting its callers, and the refusal no longer reaches a
  clause that expects a changeset (which crashed the LiveView after the profile
  write had already committed).
- **A present-but-malformed `:admin_user` no longer takes the unchecked system
  path** (#691). Only an *absent* actor is a seed/migration/mix-task caller; a
  value of the wrong shape is a caller that meant to supply one, and is refused.
- **The credential refusal path no longer raises instead of refusing** (#691
  post-merge review). `admin_update_user_password/3` takes its target unguarded
  and `can_manage_user_credentials?/2` answers `false` for a non-`%User{}`, so a
  host passing a JSON-decoded map as the *target* reached a refusal branch that
  pattern-matched `%User{}` and interpolated `user.uuid` — `FunctionClauseError`
  and `KeyError` respectively, where the pre-#691 code returned
  `{:error, :insufficient_permissions}`. A fail-closed guard that crashes has
  failed differently, not safely.
- **The form's filter no longer keeps a second hand-maintained copy of the
  field whitelist** (#691 post-merge review). It read a literal list that
  duplicated the one inside `update_user_fields/2`; adding a profile field to the
  context and forgetting the copy would have re-opened the bypass for that field,
  silently and with the existing tests still green. Both now read
  `Auth.updatable_profile_fields/0`, and a new test poisons `custom_fields` with
  every name in it, so coverage grows with the list.

### Changed

- **`Auth.updatable_profile_fields/0`** (#691 post-merge review) — new public
  reader for the fields `update_user_fields/2` writes to the schema, so callers
  filtering untrusted params read the rule instead of restating it.
  `update_user_fields/2`'s docs now state outright that it does not authorize and
  that `:email` / `:username` are credentials.
- **`StatusReport.next_action/3` gained `{:fix_version_comment, message}`**
  (#694 post-merge review) — the state existed in the function but not in the
  `action()` type, so dialyzer proved the consumer clause unreachable and
  `mix precommit` failed. The comment-less guard also now fails **closed**: it
  required an affirmative "the comment reads 1" only after review, having
  previously fallen through to the destructive advice whenever the confirming
  query could not answer.
- **The admin form logs the identity fields it strips from `custom_fields`**
  (#691 post-merge review). The page renders a real input for every one of those
  names, so such a key on the wire means a client composed its own payload — a
  stronger signal than the rank refusal the context already logs, and it was
  being discarded without a word.

## 1.7.236 - 2026-08-08

### Added

- **V163 repairs `phoenix_kit_*` tables whose `uuid` column is not a proper
  primary key** (#688). A production database reached a state the chain claims is
  impossible: `phoenix_kit_email_events` with `uuid` as `character varying(255)`,
  nullable, no default, and **no primary key at all**, while 149 other tables were
  correct. Three migrations each missed it for a different reason — V40's guard
  tests column *existence* rather than *type*, so an older release's Ecto
  `:string` column made V40 skip the table wholesale (backfill, `NOT NULL` and
  index included) despite the table being listed in `@tables_to_migrate`; V56's
  `ensure_all_uuid_columns_native_type/2` was added seventeen days *after* V56
  shipped, and a recorded version never re-runs; V74 then dropped the legacy
  bigint `id` but could not promote a wrong-typed nullable column to primary key,
  and never verified its own documented post-condition. V163 is therefore
  **catalog-driven** — it asks PostgreSQL which tables are actually broken instead
  of consulting a list the table was missing from every time, including the list
  in the migration written to repair its class of problem.
- **`mix phoenix_kit.repair_uuid`** (#688) — the maintenance-window path for
  tables V163 defers. Runs outside a transaction, so it builds the unique index
  `CONCURRENTLY` and attaches it, holding the exclusive lock only for the attach.
  Supports `--dry-run` and `--prefix`.
- **`mix phoenix_kit.doctor` gains a "UUID Primary Keys" check** (#688). The
  existing type check could not see a *missing key*, which is what the varchar
  column actually cost. Its remedy is also corrected: the single `ALTER` it used
  to suggest restores the type but not the `NOT NULL`, the default or the key,
  leaving anyone who followed it literally still broken.

### Fixed

- **V163's per-table isolation could never have fired** (#688).
  `Ecto.Migration.execute/1` *queues* a command, so the statements were flushed
  after `up/1` returned — outside the `rescue` that exists to keep one table's
  failure from aborting the rest of the run. A locked table would still have taken
  down every repair after it *and* skipped the version marker, the worst outcome
  available. `flush/0` runs the pending commands in scope, so the rescue actually
  catches. The concurrent index name is also derived from the catalog name rather
  than parsed back out of the quoted qualified string, which would corrupt any
  name containing a dot or a quote.
- **V163's row-count guard now covers every repair class, not just the type
  rewrite** (#688 post-merge review). The guard deferred a table only when
  `rewrite_needed?/1` was true, so a table that was already `uuid`-typed but had
  **no primary key** skipped it at any size — and then took a full-table `DELETE`
  self-join, a `SET NOT NULL` scan and a unique-index build, all under `ACCESS
  EXCLUSIVE`, during `mix ecto.migrate`. That is exactly the pool-exhaustion
  outage the two-million-row limit exists to prevent, on exactly the class of
  table that prompted the migration.
- **An interrupted `CREATE UNIQUE INDEX CONCURRENTLY` no longer strands
  `mix phoenix_kit.repair_uuid`** (#688 post-merge review). `CONCURRENTLY` leaves
  an `INVALID` index behind when interrupted; `IF NOT EXISTS` then skipped the
  rebuild on the retry and `ADD PRIMARY KEY USING INDEX` failed on the invalid
  index, permanently. The concurrent path now drops any leftover index first
  (`CONCURRENTLY`, schema-qualified per the chain's `DROP INDEX` rule).
- **`mix phoenix_kit.repair_uuid <table>` no longer answers a named table with the
  global all-clear** (#688 post-merge review). A typo, a mismatched `--prefix`, or
  an already-repaired table produced an empty list and printed "✓ Every
  phoenix_kit table has a proper uuid primary key" — an assertion about every
  table, made after checking none. V163's log tells operators to run this command
  with a table name, so the two cases are now distinct.
- **The de-duplicating `DELETE` announces itself** (#688 post-merge review). It is
  the only destructive statement in V163, and neither caller reported how many
  rows it would remove — `--dry-run` printed the SQL, which does not answer that.
  `UUIDIntegrity.duplicate_rows/2` counts them before any DDL runs, and both
  callers log the count.

## 1.7.235 - 2026-08-07

### Security

- **Credential management on the admin user form now answers to rank, not to a
  permission** (#686). `/admin/users/edit/:id` gated the password field on
  `Scope.can_access_admin_area?/1` — true for **any** holder of a single
  permission — while the comment above it said "Admin/Owner only", and nothing
  else in the path checked rank. New `Auth.can_manage_user_credentials?/2`
  decides by role and rank (your own account is yours; the actor must be
  Owner/Admin; an Owner or Admin target may be managed only by an Owner), and it
  gates the password field, the reset-mail button and the **email** field —
  owning the address a reset link is delivered to takes an account just as
  surely as setting the password does. `username` is dropped with them, since
  `get_user_by_email_or_username_and_password/3` accepts it as a sign-in route.
  Every event refuses independently of the template.
- **Deactivation now revokes sessions instead of merely denying them** (#686).
  `update_user_status/3` flipped `is_active` and left the token rows valid for
  their full 60-day life; it now deletes the user's session tokens.
- **Activation, deactivation and email-confirmation toggling are rank-checked in
  the context** (#686). `update_user_status/3` and `toggle_user_confirmation/2`
  take an `:actor` and enforce `Auth.can_manage_user_status?/2`; omitting the
  actor is the system path (`Referrals`). The rule lived only in the edit
  form's markup, so the user-list and user-detail pages reached both functions
  ungated — a role holding only `users` could switch off an Admin, and
  *unconfirming* an account locks it out of the eleven gates that honour
  `require_email_confirmation`.
- **Deleting a user answers to that same rank rule** (#686 post-merge review).
  `can_delete_user?/2` refused only an *Admin* target and never checked the
  actor's role at all, deferring that to a page gate that admits any single
  permission holder. Because an Owner holds only the `Owner` role, an Admin —
  or a `users`-permission role — could delete any Owner who was not the last
  one. It now routes through the same authority check; the self and last-Owner
  rules keep their own messages.
- **Multi-session resolves the root account through the active-user filter**
  (#686). `root_user/1` and `root_authenticated?/1` used a bare token lookup, so
  a deactivated Owner/Admin holding a live cookie could still reach
  `POST /users/session/impersonate/:uuid`. The same filter was added to
  `PhoenixKitWeb.Users.Session`, the OAuth scope resolver and the maintenance
  plug.
- **A deactivated account is refused at the shared sign-in funnel** (#686).
  `log_in_user/3` checks `is_active` itself — the password controller did, but
  magic-link verification, QR-login completion and the OAuth callback called it
  directly and did not.
- **Stored XSS in the auth-page branding settings** (#686).
  `AuthPageWrapper.bg_style_tag/1` built a `<style>` element by string
  concatenation and emitted it with `raw/1`; a `<style>` body is raw character
  data, so `</style>` in the background-colour value closed the element. The
  value is free text on `/admin/settings/authorization` (key `settings`, held by
  Manager as well as Admin) and is served to every **anonymous** visitor of the
  login, registration and reset pages. New `PhoenixKit.Utils.CssValue` is an
  allowlist that fails to `""`, applied on read (neutralising anything already
  stored), in the one function that assembles the stylesheet, and on write.
- **OAuth no longer attaches an external identity on email string equality**
  (#686). `find_or_create_user/3` looked the callback address up locally and, on
  a hit, confirmed that account and issued a session — no verification claim
  read, no prior link required. Resolution is now ordered by the proof each case
  carries: an existing `(provider, provider_uid)` link is decisive and consults
  no email; a pre-existing local account requires the provider's own assertion
  (Google/OIDC `email_verified`, GitHub per-address `verified`, Facebook
  `verified`); a new account is created but auto-confirmed only on an assertion.
  GitHub's strategy is now configured with `default_scope: "user:email"`, without
  which the token cannot read `/user/emails` and the claim is never present.

### Added

- `oauth_require_verified_email` setting (default `"true"`, #686) with a
  checkbox on the authorization settings page — lets a deployment lift the
  verified-address requirement deliberately rather than by accident.

### Fixed

- **A new OAuth account that is left unconfirmed is now sent the confirmation
  mail** (#686 post-merge review). Nothing on the OAuth path ever sent it —
  `Auth.register_user/2` does not, and only the registration controller did — so
  an account the provider did not vouch for was signed in with "Successfully
  signed in!" and then bounced off every gate honouring
  `require_email_confirmation`, with an empty inbox.
- **The confirm/unconfirm menu entry is gated like its status twin** (#686
  post-merge review). Only the status button was hidden for an out-of-rank
  target, so the confirmation button next to it advertised an action the server
  now refuses.
- **The new per-row rank guard no longer queries per row** (#686 post-merge
  review). `can_manage_user_status?/2` in the users-list template asked up to
  four `EXISTS` questions per row — ~200 round trips on a fifty-row page, on
  every sort, filter and PubSub re-render — even though `list_users_paginated/1`
  already preloads `:roles`. The rank rule now reads a preloaded `:roles`
  association when there is one, and the list hands it an actor loaded once.

## 1.7.234 - 2026-08-07

### Added
- **One resolver for every redirect core owns** (#685). `Routes.safe_destination/2`
  replaces eleven hardcoded `"/"` / `Routes.path("/")` destinations across
  `auth.ex`, `session.ex`, `oauth.ex`, the confirmation, referral, QR and
  password LiveViews and the maintenance page. Every candidate is proven to
  resolve in the *host's own* router (`Phoenix.Router.route_info/4`, read off
  `conn.private.phoenix_router` or `socket.router`) before anyone is sent there,
  and the chain terminates on a path core declares **and permits**
  unconditionally — `/admin` for an authenticated visitor, `/users/log-in` for
  an anonymous one. `Routes.path("/")` emits a locale-prefixed root (`/en`)
  whose route belongs to the host, so on any host that never declared one every
  such redirect used to 404; measured before the workaround, `/` answered 200
  while `/en`, `/et` and `/ru` all returned 404.
- **`/admin` is now the guaranteed landing for every authenticated visitor**
  (#685). `:phoenix_kit_ensure_admin` exempts that one view
  (`PhoenixKitWeb.Users.Auth.landing_view?/1`) from the admin-area and per-view
  permission checks — authentication, the account gate, maintenance mode and the
  locale hook still run for everyone. A terminal that rejects its own visitor is
  an infinite redirect rather than a fallback, so the page had to admit them and
  is built for it: a visitor holding no permissions is greeted by name and shown
  nothing else — no cards, no statistics, and not one operator query or PubSub
  subscription on their behalf.
- **`main_page_path` site setting** (#685) — the local path of the site's home
  page, used as the anonymous "home" destination. In general site settings,
  beside Project Title and Site Address. Empty (the default) means core falls
  back to its own `/users/log-in`, which exists in every install and every
  locale; it deliberately does **not** default to `"/"`, which no core route
  serves.
- `PhoenixKitWeb.Users.Auth.can_access_admin_view?/2` (#685) — the same decision
  `:phoenix_kit_ensure_admin` enforces on mount, as a pure boolean, so a link,
  card or nav entry and its destination cannot drift. `PhoenixKit.Admin.Events`
  gains `unsubscribe_from_stats/0`, `unsubscribe_from_sessions/0` and
  `unsubscribe_from_presence/0`.

### Changed
- **The admin dashboard is gated block by block** (#685). Its operator half
  moved to `PhoenixKitWeb.Live.Dashboard.Overview` +
  `PhoenixKitWeb.Components.Core.DashboardOverview`. Each card derives its
  visibility from `can_access_admin_view?/2` on the page it links to, so a
  visible card is never a redirect. Platform Statistics, System Information and
  the Refresh button now require `Scope.holds_all_enabled_permissions?/1` — a
  default Admin still passes (the check compares against the operator baseline,
  opt-in keys excluded), but a narrow custom operator role that used to see the
  whole dashboard now sees only the cards it holds permission for. The gate
  decides *before* it queries, and re-decides on every mid-session permission
  change: nobody is evicted from the landing, so the cards, the statistics and
  the subscriptions behind them appear and disappear in place.
- **The admin shell collapses for a visitor with no permissions** (#685). No
  sidebar column, no burger button, no navigation landmark, no "Admin Panel"
  breadcrumb label, and no "View all" footer on the notifications bell — the
  menu never offers a page that would bounce the visitor on arrival. An
  operator's header and sidebar are unchanged.

### Fixed
- **The home-page fallthrough no longer drops the visitor's language** (post-#685
  review). The resolver offered only the bare `"/"` as its home-page candidate.
  On a multilingual host that declared the locale-prefixed landing core's own
  release notes ask for, a logout, a maintenance eject or a failed password
  reset used to land on `/et` and instead flipped the visitor to the
  default-language home — or, where the host declared **only** `/:locale`,
  skipped the home page entirely and terminated on the sign-in page. Both shapes
  are now offered, locale-prefixed first, and both are probed like every other
  candidate, so this cannot reintroduce the 404 the resolver exists to prevent.

## 1.7.233 - 2026-08-06

### Fixed
- **Host apps that register their own module no longer fail to compile** (#684).
  1.7.232 began emitting a compile-time `mod.__info__(:module)` reference for
  every discovered or configured route module, so that Mix rebuilds a host
  router when one of them changes. The reference was emitted unconditionally,
  and `phoenix_kit_routes()` also expands inside phoenix_kit's own router —
  which is built as a dependency, before any parent-app module exists. A host
  that registers its OWN app module in `config :phoenix_kit, :modules` (or
  `:route_modules`) therefore stopped building at all, with
  `function TheHost.__info__/1 is undefined ... could not compile dependency
  :phoenix_kit`. Registering the host module that way is documented practice,
  not misuse: beam discovery cannot see the host app while the host is still
  compiling, so `admin_tabs/0` on the host module is invisible without it. The
  list is now filtered through `Code.ensure_compiled/1`. Where the module is
  genuinely reachable — inside the host's own router — `ensure_compiled/1`
  blocks on the parallel compiler and returns `{:module, _}`, so the reference
  is still emitted and the recompile tracking added in 1.7.232 is unchanged;
  only the case that cannot be referenced yet is skipped.

## 1.7.232 - 2026-08-05

### Added
- **Entry points for "Sign in as user"** (#683). `MultiSession.impersonate/2`,
  its authority rules, the controller action and the POST route all shipped in
  #672 with nothing in any template reaching them. The action now appears in
  the "..." menu on the Users list (table and card views) and on the user
  detail page, behind `impersonable?/2` / `impersonable_uuids/2` — predicates
  that answer with the same private rule the request enforces, so a menu
  cannot offer what the POST would refuse. The list decides a whole page of
  rows against one actor lookup, reading each target's roles from the `:roles`
  preload rather than a query per row. Nothing about who may impersonate whom
  changed.
- **The Edit action on the user detail page** joins Roles, Confirm Email and
  Deactivate in the actions menu (#683), instead of sitting alone in the
  breadcrumb bar where the header-deduplication sweep parked it.

### Fixed
- **Deactivated accounts are no longer offered for impersonation.** The menu
  predicates asked the authority rules, which decide who may borrow whom; the
  `:inactive` refusal is raised later, by `add_authenticated_user/2`. So every
  deactivated row carried a "Sign in as user" item — next to the badge saying
  the account is deactivated — and every click came back "That account is
  deactivated." `user.is_active` is already on the struct the list renders, so
  respecting it costs no query. `impersonate/2` is untouched and still
  re-decides everything server-side.
- **Doubled required-field markers** on the user, role and registration forms
  (#683). `<.input>` renders the marker itself; six labels also hand-appended
  `" *"`. `Organization Name` had the hand-written asterisk but no `required`
  attribute, while the changeset does require it for organization accounts —
  it gains the attribute, so the browser now agrees with the server.
- **The admin nav role badge named the wrong role** (#683). It derived its
  label from `Scope.can_access_admin_area?/1`, which is true for Owner, Admin
  *or any single permission holder* — so a Client, who holds `client_portal`,
  was labelled "Admin", and every custom role was flattened into three
  buckets. The account list directly below it renders
  `MultiSession.role_label/1` and said "Client" while the header said "Admin".
  Both now share that function, reading the names the scope already loaded in
  `cached_roles` instead of re-querying on a component that renders on every
  admin page.
- **Usernames generated from an email keep their letters** (#683). The cleanup
  pass strips anything outside `[a-zA-Z0-9_]`, so `ülo.kask@` became
  `lo_kask` — the first letter of the name silently gone — and a wholly
  non-Latin local part collapsed to nothing. The address is now transliterated
  first (`Ülo.Kask@` → `ulo_kask`, `Иван@` → `ivan`).

### i18n
- **`Person` → `Personal` as the account-type label.** The old source string
  named a human being where the label names a *kind of account*, the
  counterpart of `Organization`. Each locale takes the idiomatic
  private-individual-vs-legal-entity term rather than a calque — Eraisik,
  Privatperson, Particulier, Particular, Privato, Osoba prywatna, Физическое
  лицо. The stored `account_type` value stays `"person"`.
- **18 strings were in the source but in no `.pot` file**, so the SEO /
  robots.txt settings page, the hex.pm package browser and the referral gate
  ("Enter your referral code", "This site is invite-only…") rendered in
  English in every locale. Extracted and translated in all seven.
- **Four reworded strings were rendering their old translation.** `Continue`,
  `Log out`, `Referral code` and `SEO settings` had matched fuzzily against
  older entries, and fuzzy entries do render — German showed **"online"** on a
  Continue button. Retranslated; no fuzzy entries remain.
- Estonian and Russian repairs beyond those: a batch of entries whose
  translation belonged to a neighbouring msgid ("Failed to delete user" under
  the custom-field failure, "Current time" under "Current page", and ~20
  more).

### Internal
- Post-merge review of #683: `dev_docs/pull_requests/2026/683-admin-ui-i18n-and-impersonation-entry-points/CLAUDE_REVIEW.md`.
- Tests for the impersonation menu predicates — `impersonable?/2` agrees with
  `impersonate/2` target by target, `impersonable_uuids/2` agrees with
  `impersonable?/2` over a mixed list, and `impersonation_actor/1` is the ROOT
  account after a switch — plus a unit suite for
  `generate_username_from_email/1`, which had none.

## 1.7.231 - 2026-08-05

⚠️ **Two new migrations (V161, V162) — run `mix phoenix_kit.update`.** V161
converts `phoenix_kit_users.username` to `citext` and **refuses to run** if
your database already holds usernames differing only by case; it names the
offending value so you can rename or merge the accounts, then re-run.

### Added
- **`PhoenixKitWeb.Live.UrlState` — URL-backed search, filter, sort and page
  for list LiveViews** (#680). Typing in a list's search box filtered the
  table but left the address bar untouched on most admin screens: the result
  could not be shared, did not survive a reload, and Back walked out of the
  page instead of back to the previous query. A workspace audit found 26
  LiveViews with that defect and seven independently hand-rolled fixes on the
  screens that did work — six of which rebuilt the path from a literal, so a
  LiveView reachable at more than one route patched itself to the wrong page.

  Declare the state, implement `handle_url_state/2`, push changes with
  `push_url_state/3`. Params are keyed by **assign name** with `url_key:`
  naming the query key separately, so adopting it touches no templates
  (`users.html.heex`, 700 lines, needed no edit). Values equal to their
  default are dropped from the query, so an unfiltered list stays
  `/admin/users`. `cast:`/`in:` whitelist values and no atom is ever created
  from user input; integer params carry a default ceiling of 1,000,000 so a
  crafted `?page=` cannot reach Ecto as an `OFFSET` that overflows
  PostgreSQL's `bigint`. The path comes from the live `uri`, unknown query
  keys are preserved, and the callback runs only on a real change.

  Converted: `users`, `sessions`, `live_sessions`, `jobs/index`,
  `media_selector`.

  ⚠️ **`mode: :patch` (the default) makes a LiveView un-embeddable.**
  `push_patch` requires `handle_params/3` to be exported, and exporting it —
  whatever its body — makes `live_render/3` raise. The two are mutually
  exclusive in LiveView itself. `mode: :history` sidesteps both by driving the
  address bar from a JS hook (`<.url_state_sync mode={:history} />`) instead
  of touching `handle_params` at all. `MediaBrowser.Embed`'s `url_sync: true`
  has always carried the `:patch` constraint through its injected stub; that
  is now stated in its moduledoc rather than implied.
- **`Utils.Slug` gains opt-in transliteration** (#682). A Cyrillic title
  slugified to an empty string — every character fell outside `[a-z0-9]` and
  was stripped. Callers read empty as "no slug yet", so a Ukrainian shop's CSV
  catalogue could not be matched on re-import and inserted the whole feed
  again on every run. `slugify(text, transliterate: true)` maps Russian and
  Ukrainian Cyrillic to Latin and strips Latin diacritics. Opt-in, so existing
  callers keep today's ASCII-only behaviour and a consumer passing the option
  against an older core gets today's result rather than an error.
- **`PhoenixKit.Install.StatusReport`** — the "what should the operator do
  next" decision behind `mix phoenix_kit.status`, extracted so it can be
  tested without pointing the task at a live database in each of five states.

### Fixed
- ⚠️ **V161: `phoenix_kit_users.username` is now `citext`** (#681). Two
  accounts existed in production as `Pavel` and `pavel`. Nothing prevented it:
  `phoenix_kit_users_username_uidx` was a plain btree on a `varchar` column,
  `unsafe_validate_unique` compared exactly, and `get_user_by_username/1` is a
  bare `Repo.get_by`. The mechanism was systematic rather than a fluke —
  `generate_username_from_email/1` force-downcases while
  `ensure_unique_username/3` checked availability case-sensitively, so a
  username set manually with a capital was invisible to the generator, which
  proposed the lowercase form, found it "free", and added no suffix.

  Once such a pair existed, **login by username 500'd for both accounts**:
  that path already lowercased both sides, so its query matched two rows and
  `Repo.one/1` raised `Ecto.MultipleResultsError`. (An earlier draft of this
  entry described the symptom as landing in the wrong account; the failure was
  a hard error, not a silent cross-account login. `email` was unaffected — it
  has been `citext` since V01.)

  Postgres decides comparison semantics from the **column type**, so one
  `ALTER` fixes uniqueness *and* every lookup, including a bare `Repo.get_by`.
  A functional unique index on `lower(username)` would have fixed only the
  constraint and left every read exact-match. `varchar → citext` is
  binary-coercible, so there is no table rewrite; the column's index is
  rebuilt, which is what makes it start rejecting case variants.
- **Username login no longer sequentially scans the users table.**
  `get_user_by_email_or_username_and_password/3` hand-rolled its case folding
  as `fragment("LOWER(?)", u.username)`, which matches no index in the chain —
  there is no functional index on `lower(username)`. Now that the column is
  `citext`, plain equality is both correct and index-backed via
  `phoenix_kit_users_username_uidx`. This was the only username lookup in the
  codebase still scanning, on the one endpoint reachable without
  authenticating.
- **V162: payment-option linkage on billing orders** (#682). Adds a nullable
  `payment_option_uuid` FK (plus its index) to `phoenix_kit_orders`, pointing
  at `phoenix_kit_payment_options`. An order records *how* it is to be paid
  via `payment_method`, a small closed vocabulary; what the customer actually
  chose is a payment-option **row**, with its own name, instructions, provider
  and billing-profile requirement. Several options can share one
  `payment_method` ("Bank transfer (EU)" and "Bank transfer (UK)" are both
  `bank`), and an option can be renamed or deactivated after the order is
  placed. Without a link the choice was discarded at conversion, so an
  operator processing a bank transfer could not tell which instructions the
  customer had been shown. `ON DELETE SET NULL`: deleting a payment option is
  an ordinary operator action and must neither be blocked by historical orders
  nor destroy them.
- **A tab gated on a sub-permission registers correctly** (#682). A module tab
  may be gated on a sub-permission (`"shop.manage_settings"`). Registration
  pushed that through `register_custom_key/2`, which rejects a dotted key —
  and the raise aborted the rest of the callback, so the view → permission
  mapping the admin gate reads was never cached. The module silently fell back
  to the coarser base key for core's gate, and every boot logged a failure for
  a key that was declared correctly. Sub-permissions are already declared
  through `permission_metadata/0`, so registration now skips them.
- **The automatic view gate requires the base of a dotted key** (#682). With
  the dotted key now cached, the admin mount gate resolves one — and it was
  calling `has_module_access?/2`, direct membership only, which by contract
  leaves the base check to its caller. A scope holding an orphaned
  `"shop.manage_settings"` without `"shop"` would have passed a gate the
  sidebar, `can?/2` and every module's own check all refuse.
- **The `PhoenixKitUrlState` JS hook no longer leaks a callback per remount.**
  `handleEvent` registers on the LiveSocket, not the element, so `destroyed()`
  has to call `removeHandleEvent` — it only removed the `popstate` listener.

### Changed
- **`mix phoenix_kit.status` says "code expects", not "update available".**
  Everything it reports is measured against the version compiled into the
  running release; it never asks Hex what exists, so it cannot tell you a
  newer PhoenixKit is out. A version gap is not an optional upgrade being
  offered — it means the schema disagrees with the code already querying it,
  which surfaces as runtime errors on whatever the newer version added. When
  core and a module are both behind, one command fixes both and both reasons
  are now listed, so re-running does not turn up a second finding that was
  already knowable.
- **The test suite can use a database you already have.** `config/test.exs`
  hardcoded `phoenix_kit_test`, which forces a role with `CREATEDB` — exactly
  what a shared or managed instance withholds. `PGDATABASE` and `PGPOOL` now
  join the `PGHOST`/`PGUSER`/`PGPASSWORD` that were already read. Defaults are
  unchanged.
- **`AGENTS.md` no longer claims `mix precommit` runs the test suite.** It
  never did, and CI is `workflow_dispatch`, so in practice nothing ran the
  Elixir suite automatically. Adding `mix test` to `precommit` was tried and
  reverted — the suite is not green from a clean checkout (~5 "unit" tests
  fail with no database, because `Settings` reads hit the DB on a cache miss),
  and a permanently red gate teaches people to ignore the gate. The docs now
  say running the suite is a manual step, and warn that `mix test` with no
  database excludes every integration test **and still exits 0** — the failure
  mode that matters most when the change is a migration.
- Dependency bumps: `etcher` 0.10.0 → 0.10.2, `spitfire` 0.3.13 → 0.4.0.

### Internal
- Post-merge review of #680/#681/#682 with the findings above:
  `dev_docs/pull_requests/2026/680-682-post-merge-review/CLAUDE_REVIEW.md`.
- `test/phoenix_kit/migrations/v162_test.exs` — V162 shipped with no test.
  Pins the column, the FK target, the index, and `ON DELETE SET NULL`
  specifically: that is the migration's whole design decision, and a later
  refactor reaching for a plain `references/2` would silently make it
  `RESTRICT` with nothing failing.

## 1.7.230 - 2026-08-04

### Fixed
- ⚠️ **`mix igniter.install phoenix_kit` failed on every freshly generated
  Phoenix project.** Core declared `{:igniter, "~> 0.7"}` as a required
  dependency in all environments. A stock `mix phx.new` app declares
  `{:igniter, "~> 0.6", only: [:dev, :test]}`, and Mix refuses to converge the
  two:

  ```
  Dependencies have diverged:
  * igniter (Hex package) — the :only option for dependency igniter
    Remove the :only restriction from your dep
  ```

  The install aborted before writing anything. Igniter is now
  `optional: true`, so the host's own declaration wins and the documented
  install path works on a clean project. The version requirement is unchanged
  (`~> 0.6` and `~> 0.7` both admit igniter 0.7/0.8, so no host is forced to
  move).

  Making it optional means core must compile **without** igniter, which it
  previously could not: `mix/tasks/phoenix_kit.gen.admin.page.ex` and
  `phoenix_kit.gen.user.dashboard.ex` called `use Igniter.Mix.Task` unguarded
  and hard-failed a `MIX_ENV=prod` build. Both now carry the same
  `if Code.ensure_loaded?(Igniter.Mix.Task)` guard `phoenix_kit.install` and
  `phoenix_kit.update` already had, and ten igniter-only `PhoenixKit.Install.*`
  helpers are guarded on `Code.ensure_loaded?(Igniter)` so a production build
  no longer prints a wall of "Igniter.X is undefined" warnings. The two helpers
  that *cannot* be guarded away because their non-igniter half is called from
  plain tasks — `Install.Common` (`mix phoenix_kit.status`) and
  `Install.JsIntegration` (`mix phoenix_kit.assets.rebuild`) — instead use the
  existing `Install.IgniterCompat` `:no_warn_undefined` shim, which grew the
  three modules they reference. No task or helper changed behaviour when
  igniter *is* present.

  ⚠️ **Upgrading from ≤ 1.7.229 and your `mix.exs` does not list `:igniter`?**
  You were getting it transitively from PhoenixKit; an optional dep is not
  installed unless the host declares it, so after `mix deps.update phoenix_kit`
  the code-generating tasks stop working. Add:

  ```elixir
  {:igniter, "~> 0.7", only: [:dev, :test]}
  ```

  `mix phoenix_kit.install` / `.update` / `.gen.*` now say exactly this when
  invoked without igniter rather than vanishing from `mix help` (the two
  `gen.*` tasks, newly guarded, had no fallback at all; `install` and `update`
  had one each, and all four now share `Install.MissingIgniter`).
  `PhoenixKit.Install.IgniterCompat` gained a `__mix_recompile__?/0` keyed on
  igniter's availability, so adding the dep later actually rebuilds the tasks
  instead of needing `mix deps.compile phoenix_kit --force`. Tasks that never
  touch igniter — `phoenix_kit.status`, `.gen.migration`, `.assets.rebuild` —
  are unaffected either way.

- **`mix phoenix_kit.update` could crash when two modules needed migrating in
  the same second.** Generated migration filenames took their version from a
  bare `%Y%m%d%H%M%S` timestamp, so two modules upgraded together produced
  duplicate Ecto migration versions. Timestamps are now offset per file and
  bumped past anything already in `priv/repo/migrations`.

- **`mix phoenix_kit.update` silently skipped modules whose migration
  coordinator raised.** The failure was swallowed and the host saw nothing at
  all, leaving it to assume its tables were current. Unreadable modules are now
  reported by name with the error and an explicit note that they were not
  migrated.

- **`mix phoenix_kit.update` wrote module migrations to a hardcoded
  `priv/repo/migrations`.** On a host whose first `:ecto_repos` entry is not
  `MyApp.Repo`, the file landed in a directory the migrator never scans, so
  `ecto.migrate` exited 0 having done nothing — and the run still printed
  `✅ <module> migrated to V##`. The directory is now taken from the resolved
  repo, and each module's version is **re-read from the database** afterwards
  rather than assumed, so a migration that did not run is reported as a failure
  with the path to check.

- **`mix phoenix_kit.update` could hard-fail on a re-run after an interrupted
  update.** The module path had no "migration already exists" guard (the core
  path has had one all along), so a second run wrote a second file with the
  same migration name and `mix ecto.migrate` refused everything with
  `migration name ... is duplicated`. It now reuses the existing file.

- **One bad module aborted the whole `mix phoenix_kit.update` run.** The
  per-module `try/rescue` was lost in the rework, so a module that raised while
  its migration file was written killed the task *after* core had migrated —
  skipping every remaining module and the UUID repair pass. Each module is
  isolated again.

- **`mix phoenix_kit.status` reported `Next: Ready` directly under a
  `1 unreadable ❌` module row.** An unreadable module is deliberately not
  "pending" (migrating a module whose version cannot be read would be worse),
  but it is not "ready" either. `Next` now names the modules to check.

- **`mix phoenix_kit.status --verbose` claimed "No installed module owns
  migrations" whenever the database was unreachable**, which is a different
  fact from having none and sends anyone debugging a missing table the wrong
  way. Not-queried and none-found are now distinct.

- **A module coordinator reporting a non-integer version read as up to date.**
  Under Erlang term ordering `nil >= 2` is `true`, so a coordinator returning
  `nil` for "no version comment found" was classified `:up_to_date` and its
  migration skipped forever, while both tasks reported everything current.
  `Modules.classify/2` now requires integers and reports anything else as
  `:error`.

- **Soft-failure paths guarded with `rescue` alone now also `catch :exit`.**
  Per the project's own convention, an unreachable database raises on an
  unowned checkout but *exits* on a dead pool — so a dead pool crashed
  `mix phoenix_kit.status` outright and killed the closing summary of an
  otherwise-successful `mix phoenix_kit.update`.

- **The sitemap's `x-default` could be claimed by a sibling-dialect entry**
  (#679). Enabled codes are stored BCP-47 (`en-GB`) while sibling-dialect URLs
  render lowercase (`/en-gb/…`), so the case-sensitive `String.contains?` never
  recognised such an entry as language-prefixed and let it pass as the
  unprefixed default. The default picker now matches case-insensitively, in
  line with the per-entry hreflang extraction that already did.

### Added
- **The locale plug accepts enabled full-dialect URL segments** (#679) instead
  of 301-ing every hyphenated segment to its base code. A segment that
  case-insensitively matches an **enabled** language (`/en-gb/…` with `en-GB`
  enabled) is now served as that locale, with the stored-case code on
  `conn.assigns.current_locale` and its base on `current_locale_base`.
  Disabled dialects, unknown dialects, and an empty enabled list (Languages
  module off) all keep the historical redirect-to-base, so nothing changes for
  an install that does not enable sibling dialects.

  This is what makes two enabled dialects of one base addressable as distinct
  public URLs — `phoenix_kit_publishing` gives the non-primary sibling its own
  URL space and previously had it bounced to the base before its controller
  ever ran. The prefixless-primary canonical redirect deliberately does not
  apply on this branch: only non-primary siblings are addressed by full-code
  URLs, and the primary keeps its base-coded (or prefixless) shape.

- **`mix phoenix_kit.status` now reports the schema version of every module
  that owns its migrations**, not just core. Modules implementing
  `c:PhoenixKit.Module.migration_module/0` (`phoenix_kit_inbox`,
  `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`,
  `phoenix_kit_stats`) each report installed-vs-expected:

  ```
  PhoenixKit v1.7.230
  ├── Installed: V159 ✅
  ├── Database: Connected ✅
  ├── Modules: 2 modules, 1 update available ⬆
  │   ├── Boards: V01 ✅
  │   └── Inbox: V01 → V02 available ⬆
  └── Next: mix phoenix_kit.update (module schema behind: Inbox)
  ```

  `Next` is module-aware: a host whose core is current but whose module tables
  are a version behind previously reported "Ready". `--verbose` adds each
  module's coordinator and exact version numbers. The row is omitted entirely
  when no installed module owns migrations, so a core-only install keeps its
  compact three-line tree.

- **`mix phoenix_kit.update`'s closing summary lists module versions too**, so
  the last thing printed answers "what version is everything at?" rather than
  covering core alone and leaving module versions in scrollback.

### Changed
- **`mix phoenix_kit.update` now writes every pending module migration first
  and runs `ecto.migrate` once**, instead of a full migrator pass per module.
- **New `PhoenixKit.Migrations.Modules`** — the shared read side of the
  module-migration contract, used by both tasks. Discovery previously lived
  inside `update` only, which is why `status` never knew modules existed. A
  module whose coordinator raises, exits, or reports a non-integer version is
  recorded as `:error`, never propagated, so a broken third-party module cannot
  take down `mix phoenix_kit.status`. `classify/2` is public because it is the
  whole read-side decision, and a private one could only be tested through a
  hand-built entry that supplied the answer.
- **New `PhoenixKit.Install.StatusTree`** — the tree layout, extracted from the
  status task so it can be unit tested without a database. It was previously a
  private function writing straight to `IO.puts/1`, so in practice changes to
  it went unverified.

## 1.7.229 - 2026-08-04

### Changed
- ⚠️ **The `leaf` requirement is now `~> 0.4.1 or ~> 0.5`, up from `~> 0.3`.**
  **This raises the floor — hosts resolving leaf 0.3.x will be moved to 0.4.1+.**

  `~> 0.3` spanned leaf 0.3 → 0.9. For a 0.x package, where each minor is
  effectively a major, that claimed a support window core cannot back. It also
  had a concrete cost: it let a resolver reach for leaf 0.5 while
  `phoenix_kit_publishing` still excluded it, and rather than reporting a
  conflict the resolver quietly settled on an older publishing release. Core
  declares `leaf` for the whole tree — `phoenix_kit_comments` renders the
  composer but inherits the dep from here — so this requirement governs every
  host.

  **If you vendor `leaf.js` or pin it from a CDN, update it to match.** leaf 0.5
  is a server↔client contract change and a bundle left behind fails silently
  (0.5.1 logs a console warning when it detects the mismatch). Hosts using the
  documented `import "../../../deps/leaf/priv/static/assets/leaf.js"` move
  automatically.

## 1.7.228 - 2026-08-04

### Removed
- **The installer no longer rewrites the host's `assets/js/app.js` to add a
  `viewport_width` connect param.** `mix phoenix_kit.install` / `mix
  phoenix_kit.update` edited the host's LiveSocket options into
  `params: () => ({_csrf_token: csrfToken, viewport_width: window.innerWidth})`,
  justified by responsive PhoenixKit LiveViews reading the width server-side on
  first render. **No such reader was ever written** — nothing in core or in any
  module package reads `viewport_width`, and `phoenix_kit_dashboards`, the named
  beneficiary, has no viewport logic at all. The producer shipped, the consumer
  never did. Editing a host's application source to send a value nothing reads
  is not something a library should do quietly, so the step and its transform
  (`JsIntegration.inject_viewport_param/1` and helpers) are gone.

  **Existing hosts keep the line** — this removes the step, not what earlier runs
  already wrote. It is inert and safe to leave; delete it by hand if you want the
  diff clean. Reported by a host that found the edit in an unexplained `git diff`.

  Note for the report that prompted this: the edit came from
  `phoenix_kit.install`/`update`, **not** from the `:phoenix_kit_js_sources`
  compiler, which only ever writes `priv/static/assets/vendor/`.

## 1.7.227 - 2026-08-03

Host-app feedback triage (#677) — ~43 reports from AI agents working on apps
built with PhoenixKit (Ratelia, Topp, NordSwitch), plus the post-merge review
fixes. **Migration V160**; run `mix phoenix_kit.update`.

### Added
- **Invite-only is enforced as a post-signup access gate** (#677) — with
  `referral_codes_required` on, an account can be created by any route
  (password, magic link, OAuth) but reaches nothing except `/users/referral` and
  log-out until it is admitted. It was previously enforced on the password form
  only, so OAuth and magic-link signups walked straight past it. Keyed on an
  independent flag, never `confirmed_at` — OAuth auto-confirms, so a gate keyed
  on that would open for the path it most needs to close.
- **`mix phoenix_kit.update --status`** (#677) — lists what upgrading gives you,
  read from the migration moduledoc's per-version headings. Seven of the
  reported "missing features" already existed; that is a delivery problem, not
  seven doc gaps.
- **`PhoenixKit.Test.Fixtures`** (#677) — shared test fixtures for host suites.
- **`config :phoenix_kit, hidden_admin_tabs: [...]`** (#677) — drop a module's
  admin section while keeping its data layer. Applied at registry init, so a
  supervisor restart cannot resurrect a hidden tab.
- **`Referrals.PruneWorker`** (#677) — deactivates (never deletes) accounts that
  were created under invite-only and never satisfied it. Off unless
  `referral_unadmitted_retention_days` is set. `mix phoenix_kit.update`
  backfills its cron entry into existing hosts.
- **Sitemap endpoints at the site root** (#677) — `/sitemap.xml` and friends are
  served at the root as well as under the PhoenixKit prefix, because that is
  where crawlers look. Emitted only for prefix-mounted installs.

### Changed
- **Auth pages no longer render in the host's `Layouts.app`** (#677) —
  ⚠️ **breaking default.** Every install's login page was showing the host
  scaffold's Phoenix Framework branding. Opt back in with
  `auth_uses_host_layout: true`.
- **A user's own notification inbox and preferences need no permission grant**
  (#677) — ⚠️ **breaking.** Notifications are delivered to every user, and
  requiring a grant to read your own meant an account could receive mail it was
  structurally unable to open. The `notifications` key is now reserved for the
  administrative all-users view.
- **Custom sitemap exclude patterns ADD to the built-in defaults** (#677) — a
  saved list used to replace them outright, so adding one pattern of your own
  silently un-excluded every admin and auth route and froze that install out of
  later defaults. Save `"!replace"` as the first entry to opt into replacement.
- **`<.button>` honours `variant`, `size` and `navigate`** (#677) — all three
  were undeclared and silently dropped, including in `table_default`'s own
  documented examples. `variant` now replaces the base colour rather than
  appending to it.
- Dependency bumps: `oban`, `tesla`, `leaf`, `mdex_native`.

### Fixed
- **`GET /api/consent-config` 404'd on every page load without
  `phoenix_kit_legal`** (#677) — the vendored bundle asks for it
  unconditionally, so a conditional route meant a `NoRouteError` and a logged
  exception per request. It answers 204; a `{"enabled": false}` body would have
  *granted* consent on bundles vendored before the feature existed. The
  controller is named `PhoenixKitWeb.Controllers.ConsentConfig` — deliberately
  not the name `phoenix_kit_legal <= 0.1.9` publishes its own copy of, so the
  two are safe in either upgrade order.
- **The invite-only janitor starved itself and deactivated nobody** (post-#677
  review) — grandfathered accounts never gain a satisfied stamp and are, by
  definition, the oldest rows, so on any install with more than a batch (500) of
  pre-existing users they filled every batch and the sweep swept nothing, every
  day, silently. The grandfather predicate is now applied in SQL so exempt rows
  cannot occupy a batch slot.
- **`allow_registration` is enforced where accounts are actually created**
  (post-#677 review) — the magic-link *completion* route honoured only
  `magic_link_registration_enabled`, so closing registration outright still let
  every in-flight token create an account; the password form checked the setting
  in `mount/3` but not on submit, and a LiveView socket outlives the page load
  that opened it.
- **Three soft-failure paths in the access gate could still crash the site**
  (post-#677 review) — `invited?/1`, `fallback_boundary/0` and
  `log_deactivation/1` rescued exceptions but not exits, and an unreachable
  database raises on an unowned checkout while *exiting* on a dead pool. Two of
  the three are on the authentication path.
- **Referral-code validation was an unthrottled guessing oracle** (#677) —
  distinct messages per failure mode confirmed which guesses named a real code.
  One message now, rate-limited per IP and (on the post-login screen) per
  account, checked on submit rather than per keystroke.
- **Magic-link settings hid buttons without closing routes** (#677) — both the
  login and registration routes stayed reachable by URL, and in-flight tokens
  kept working, after an admin switched them off.
- **`send_registration_link/1` had no rate limit at all** (#677) — now limited
  on the same buckets as password registration, *before* the user lookup, so the
  generic copy does not become an account-existence oracle via timing.
- **Sitemap exclusions were a one-way door** (#677) — saving one custom pattern
  dropped every built-in exclusion, and saving them back exceeded `varchar(255)`
  while the changeset allowed 1000. **V160** widens
  `phoenix_kit_settings.value` to `TEXT` (catalog-only; no table rewrite).
- **Users received notifications they had no permission to read** (#677).
- **`mix phoenix_kit.update` exited 0 with a migration pending** (#677).
- **Settings written outside the web node stayed invisible until restart**
  (#677) — `get_settings_cached/2` silently read a cache miss as `nil` instead
  of filling it from the database, which would have degraded site-wide on every
  expiry wave once the cache gained a TTL. Cache expiry also gained up to 10%
  jitter so a batch written together does not fall due together.

## 1.7.226 - 2026-08-01

### Added
- **Audio is a first-class type in the media pickers** (#676) — an audio filter in
  the selector modal (grid query, `accept` list, server-side upload gate, copy and
  the "Audio Only" dropdown option), plus `lock_file_type` on the modal and
  `only_file_type` on `MediaBrowser`, which turn a type filter from a starting
  point into a constraint: the control is hidden, the change event is refused on
  the server, and an off-type upload is refused rather than stored out of sight.
- **`Storage.determine_file_type/2`** — the one classifier behind the `file_type`
  column, now public and documented. It takes the filename as well as the mime
  type, so the extensions browsers report as `application/octet-stream` (`.m4a`,
  `.flac`, `.opus`, `.ogg`) are still classified correctly instead of being
  invited by a picker's `accept` list and then refused by its own type gate.

### Fixed
- **An mp3 was stored as a document, so the audio filter never found it** (#676) —
  `determine_file_type/1` was copied into all four upload paths and the copies
  drifted: only the selector modal's knew about audio, while the media browser
  classified audio as `"document"` and the upload controller and full-page selector
  as `"other"`. Since each copy's result is written straight to `file_type`, and
  both new filters query that column literally, the same file was findable or
  invisible depending on which dropzone it was dropped on. All four now call
  `Storage.determine_file_type/2`. Unknown mime types uploaded through the media
  browser are now `"other"` (in the `File` allowlist) rather than `"document"`.
- **Buttons that didn't look clickable** (#676) — Tailwind v4's preflight stopped
  setting `cursor: pointer` on `button`, leaving the SearchPicker's dropdown rows
  (server- and hook-rendered) and the theme dropdown's options with an arrow
  cursor. `cursor-pointer` also joins the SearchPicker's safelist span, since the
  hook writes the class from JavaScript.
- **`EmailStatusBadge` leaked `format_status/1` and `status_class/1` into every
  LiveView** (#676) — it is blanket-imported by `use PhoenixKitWeb, :live_view`, so
  any consumer with its own `format_status/1` failed to compile pointing at code
  that never mentioned email. The import is narrowed to the component itself.
- **The call-to-action block sat flush left and linked nowhere** (#676) — it now
  renders inside a centring wrapper, drops the `inline-block` that was overriding
  daisyUI's `.btn`, and renders without an `href` when it has no action instead of
  defaulting to `"#"`, which scrolled the reader to the top of the page.

### i18n
- The five new audio strings translated in all seven locales. `gettext.extract
  --merge` fuzzy-matches each of them onto its *video* sibling — so
  "Only audio files can be added here." would otherwise have rendered as the
  translation of "only video files" — and fuzzy entries do render.

### Tests
- `test/modules/storage/determine_file_type_test.exs` — DB-free coverage of the
  shared classifier, including the `application/octet-stream` filename fallback.
- The registration-changeset block that shares a describe-level `setup` now
  registers a unique address per test; it was exhausting the 3-per-hour-per-email
  registration limit, and the refusal landed in `setup` reading as "registration is
  broken". The "explicit username wins" case keeps its saved user — the block is
  about editing one.

## 1.7.225 - 2026-07-31

### Fixed
- **A NULL `custom_fields` column silently swallowed atomic writes** (#675) — the
  column is nullable (V18), and in Postgres `NULL || jsonb` is `NULL` and
  `NULL - key` stays `NULL`. `merge_user_custom_fields/3` and
  `delete_user_custom_field/3` built their UPDATE straight off the column, so on a
  NULL row the merge discarded the additions and returned `{:ok, user}` with
  nothing written. Both fragments now `COALESCE(?, '{}'::jsonb)` first — the same
  idiom V30 already uses — which also restores the old whole-map path's side
  effect of normalizing a NULL column to `{}` on any delete.
- **Saving notification preferences rolled back a concurrently-connected channel
  or locale switch** — `Notifications.Prefs` was the last core writer still
  replacing the whole `custom_fields` map, and it rebuilt it from the `%User{}`
  the caller had been holding since `mount/3`. With a settings page open, a
  Telegram connect (`notification_channel:telegram`) or any language switch
  (`preferred_locale`) landing in between was silently reverted by the next save.
  It now writes only its own key through the atomic merge, which is what
  `ChannelConfig`'s per-channel key layout always assumed. Same-key concurrent
  writes are still last-writer-wins, now documented on `Prefs.merge/2`.
- **Internal UI preferences no longer register themselves as admin custom
  fields** — `ensure_definitions_exist/1` registers every key in the map it is
  handed, and the media browser / canvas viewer passed the whole column, so
  `media_view_mode`, `media_expanded_folders`, `media_sidebar_collapsed`,
  `etcher_colors`, `etcher_line_params` and `media_viewer_info_collapsed` appeared
  in the Custom Fields list and the users-table column customizer. Those five call
  sites now pass `ensure_definitions: false`, matching the users and activity list
  views. Definitions already registered on existing installs stay until removed.

### Changed
- **`update_user_locale_preference/2` gained a `@spec`** documenting its two error
  shapes — `{:error, String.t()}` for a validation failure and the primitives'
  `{:error, :not_found}` for a row deleted concurrently.
- **`Prefs.update/2` and `Prefs.merge/2` specs corrected** to `{:error, :not_found}`;
  they no longer return an `Ecto.Changeset`. Both call sites already matched
  `{:error, _}`.

### Tests
- NULL-column coverage for the merge and delete primitives; the documented
  `{:error, :not_found}` contract for `set_user_custom_field/3`; and a regression
  test that a sibling `custom_fields` key written after a caller's snapshot
  survives a `Prefs.merge/2`.

## 1.7.224 - 2026-07-30

### i18n
- **Every shipped locale is now 100% translated with no fuzzy flags** — `de`, `es`,
  `it` and `pl` were stubs (~2106 untranslated each; es ~1967) and are now
  complete: 0 untranslated, 0 fuzzy across `default` (2182), `errors` (24) and
  `phoenix_kit` (7). Together with ru, et and fr, all seven translated locales are
  at 100%. ~8,500 strings.
- **Terminology follows each catalog's own prior entries** rather than being
  invented — e.g. `pl` already used "zasobnik" for *bucket* where de/es/it keep
  "Bucket", and that split was preserved. daisyUI theme names follow the existing
  `fr` precedent: descriptive names translated (`Winter` → Invierno / Inverno /
  Zima), genre and proper nouns kept (`Nord`, `Cyberpunk`, `Lo-Fi`, `CMYK`).
- **`en` fuzzy flags cleared** — `en` is untranslated by design (empty msgstr ⇒
  Gettext falls back to the msgid, already English), but it carried 512 fuzzy
  flags on those empty entries. They were inert, and they made a fuzzy count
  useless as a signal. **"0 fuzzy anywhere in `priv/gettext`" is now a true,
  checkable invariant**, so any future non-zero count means a reword really
  happened and needs a human.
- **Existing good translations were never clobbered** — writes were filtered to
  each locale's untranslated ∪ fuzzy set, which is what preserved the ~139 entries
  `es` already had.

### Fixed
- **`should be %{count} byte(s)` and friends now exist in de/es/it/pl** — the
  entire `errors` domain was untranslated in de, it and pl, so every Ecto
  validation message fell back to English in those locales.

### Verification
- Bidirectional placeholder audit over all 24 catalog files: 0 extra, 0 dropped.
- `mix gettext.extract --merge` reports `0 new, 0 removed, 0 reworded` for all 24
  files and leaves the tree byte-identical.

## 1.7.223 - 2026-07-30

### Fixed
- **fr carried the same live fuzzy-carryover defects as ru/et** — the sign-out
  control read "S'inscrire" (**Sign up**), `Email Unconfirmed` rendered as "E-mail
  **confirmé**", `Integration added` as "Intégration **supprimée**" (removed),
  `Approve` as "avr." (April), `Restore` as "Rétro" (the theme), `unlimited` as
  "sans titre" (untitled), `Full Access` as "Succès", `Port` as "Trier" (Sort),
  `Custom URLs` as "Rôles personnalisés" (Custom **roles**), `Device` as
  "Service", `Create User` as "Créer un dossier" (Create **folder**),
  `No unread notifications` as "Activer les notifications utilisateur", and both
  `%{n}h ago` and `%{n}m ago` as "il y a %{n} **jours**". The xAI key-setup steps
  had inherited Mistral's URLs here too.
- **Placeholders dropped by a fuzzy carryover** — `Requires %{module}` rendered as
  a bare "Required" in de, es, it, pl (and `Active today at %{time}` as "Activo"
  in es), losing the interpolated value. These are worse than being untranslated:
  an empty msgstr falls back to correct English, while these render wrong text
  with the value silently missing. Fixed in all four locales.

### i18n
- **fr is complete** — 0 untranslated, 0 fuzzy across all three domains
  (`default` 2182, `errors` 24, `phoenix_kit` 7). 301 strings translated and 126
  fuzzy entries reviewed individually, 90 rewritten. ru, et and fr are now all at
  100% with no fuzzy flags.
- **The placeholder audit now checks both directions** — the 1.7.222 version only
  caught msgstrs referencing a binding the msgid never supplies; it now also
  catches ones that *drop* a binding the msgid does supply. Plural entries are
  handled correctly (form 0 against `msgid`, the rest against `msgid_plural`),
  since English singulars routinely hardcode "1" and carry no `%{count}`.
  Result across all 24 catalog files: 0 extra, 0 dropped.
- `de`, `es`, `it`, `pl` remain deliberate stubs and still carry ~463–533 fuzzy
  flags that were **not** audited string-by-string — only the provably-broken
  placeholder cases above were fixed. Promoting any of them to a supported locale
  needs the same pass ru/et/fr got. `en` is untranslated by design.

## 1.7.222 - 2026-07-29

### Fixed
- **Fuzzy translations were serving wrong text in ru and et** — Elixir's Gettext
  compiles and serves entries flagged `fuzzy` (the flag is only a translator
  hint), so every translation gettext had auto-carried from a similar-looking
  msgid was live in the UI. `Approve` rendered as "Апр"/"Apr" (April), `Port` as
  "Sort by", `unlimited` as "untitled", `Full Access` as "Success", `Large` as
  "Target", `Preview` as "Back"/"Previous", `Custom URLs` as "Custom roles",
  `%{n}h ago` and `%{n}m ago` both as "…days ago", and the `Nord`/`Winter`/`Black`
  theme names as "No"/"Enter"/"Back". Worst of the set, both stating the opposite
  of the truth on an auth surface: `Email Unconfirmed` rendered as
  "Email **confirmed**" and `Sign up` as "Sign **in**".
- **Provider setup instructions pointed at the wrong vendors** — the xAI and
  OpenAI key-setup steps had inherited Mistral's and DeepSeek's URLs, telling
  ru/et users to fetch an xAI key from `console.mistral.ai` and an OpenAI key
  from `platform.deepseek.com`.
- **`errors.po` had unresolvable interpolation bindings** — six `validate_length`
  messages in both ru and et carried `%{min}`/`%{max}` while Ecto only ever
  supplies `%{count}`, so every min/max length validation error interpolated a
  binding that does not exist. `should have %{count} item(s)` also said "bytes".

### i18n
- **Catalogs resynced with the source** — `mix gettext.extract --merge` across all
  8 locales: 195 msgids that existed in source but in no catalog were added and 12
  dead entries removed. A full merge is now a **no-op** (`0 new, 0 removed, 0
  reworded`) and byte-idempotent, which is what makes the drift actually gone
  rather than deferred.
- **ru and et are back at 100%** — 0 untranslated, 0 fuzzy across all three
  domains (`default` 2182, `errors` 24, `phoenix_kit` 7). 282 ru / 281 et strings
  newly translated; 304 ru / 305 et fuzzy entries reviewed individually, ~136 per
  locale rewritten and the rest confirmed correct and unflagged. Terminology was
  taken from each catalog's existing non-fuzzy usage rather than invented (ru
  "бакет" for bucket, since "Хранилище" is already Storage; et "dimensioon" and
  "teavitus", both already dominant). daisyUI theme names follow the existing fr
  precedent: descriptive names translated, genre/proper nouns kept.
- **Placeholder audit added over all 24 catalog files** — every `%{…}` in every
  msgstr, including each plural form, is bound by its msgid. 0 problems remaining.
- `de`, `es`, `it`, `pl`, `en` are synced but remain stubs by design. `fr` (~86%,
  126 fuzzy) is maintained but incomplete and still carries the same class of
  fuzzy defect — left for its own pass rather than half-done here.

## 1.7.221 - 2026-07-29

### Added
- **A failed email never renders as merely sent** (#674) — the activity badges
  carry their whole meaning in colour (the text is only ever a timestamp), so a
  log whose `status` says the send failed but whose matching timestamp or event
  is missing rendered as the plain blue "sent" badge, contradicting the detail
  page for the same log. A status-only badge now covers that gap.
- **CRM contact card on the user detail page** (#674) — when the optional CRM
  module is installed and enabled, a user linked to a CRM contact gets a card
  linking straight to it.

### Fixed
- **Spam complaints were left showing as sent** (#674 review) — the new failure
  whitelist spelled the status `complained`, which no writer in the tree sets,
  and omitted `complaint`, which is what `SqsProcessor` actually writes and what
  `Emails.Log`'s changeset validates. Five of the six failure statuses were
  covered and the dead entry made the list look complete.
- **Soft bounces stay amber in the activity column** (#674 review) — the
  status-only badge hardcoded `badge-error` for every failure status, repainting
  a retryable soft bounce red in the list while the detail page showed it amber.
  Colour and label now come from `EmailStatusBadge`, so core holds one status →
  colour/label map instead of two that drift.
- **The CRM card checks the viewer's `crm` permission** (#674 review) — every
  admin route shares one `live_session` gated only by `can_access_admin_area?/1`,
  so a role holding `users` but not `crm` rendered a contact's name and was then
  bounced to `/` by `enforce_admin_view_permission/2` on clicking through. The
  permission check also skips the query for viewers who would never see the card.
- **A contact with no name renders a visible link** (#674 review) —
  `phoenix_kit_crm_contacts.name` is nullable, and the card read `.name` directly
  instead of CRM's own `display_name/1` fallback chain, so such a contact
  rendered the card's only link as empty text.

### Tests
- **`email_activity_badges_test.exs`** (new) — the component had none. Enumerates
  the canonical status list from `Emails.Log`'s changeset and asserts the failure
  subset against it both ways, so a whitelist that invents or drops a status
  fails a test whose message says why. Also pins colour parity with
  `EmailStatusBadge`, the labels, and the no-duplicate path.

### i18n
- **The CRM card's new strings are translated** (#674 review) — `This user is
  linked to a CRM contact.` and `Unnamed contact` reached neither `default.pot`
  nor ru/et, the two locales kept at 100%. Appended by hand for the same reason
  as 1.7.220: a full `gettext.extract --merge` now reports 195 new / 53 fuzzy per
  locale, a repo-wide backlog this PR did not cause. `CRM` needed nothing — it
  already exists as a msgid and is translated in both.

## 1.7.220 - 2026-07-29

### i18n
- **The ten strings #673 newly wrapped in `gettext/1` are translated** (#673
  review) — `Add`/`Edit Storage Bucket`, `Add`/`Edit Storage Dimension`,
  `Update Dimension`, `Create`/`Edit User`, `Create a new user account`,
  `Edit user information`, `Media Detail`. The PR wrapped them without touching
  the catalogs, so ru and et — the two locales kept at 100% — rendered them in
  English. Appended by hand to `default.pot` + `ru` + `et`: a full
  `gettext.extract --merge` reports 246 new / 53 fuzzy across 28k lines, a
  repo-wide backlog #673 did not cause, and the fuzzy re-marks would push ru and
  et off 100% rather than toward it.

## 1.7.219 - 2026-07-29

### Added
- **Admin UI standards sweep** (#673) — the admin area moved onto the
  framework's own components. Page-local `<header>` / `<.admin_page_header>`
  blocks fold into the `LayoutWrapper` breadcrumb (`page_section`,
  `page_section_path`, `page_subtitle`, `page_action`), `container mx-auto`
  width caps are gone, hand-rolled form controls are now
  `<.input>` / `<.select>` / `<.textarea>` / `<.checkbox>`, and list views adopt
  `<.table_default>`, `<.empty_state>`, `<.pagination>`, `<.search_toolbar>` and
  `<.nav_tabs>`.
- **`<.row_link>`** (#673) — new core component making a whole table row or card
  clickable with one real `<a>` and a stretched `::after` overlay. A `<tr>` host
  needs `relative transform-gpu`: WebKit ignores `position: relative` on `<tr>`,
  so without a containing block every row's overlay collapses onto the last row
  and every tap on iOS opens that one. Interactive siblings need `relative z-10`.

### Changed
- **`<.select>` and `<.textarea>` render the required marker** (#673 review) —
  `<.input>` grew a red `*` for `required` fields and the sweep deleted the
  hand-rolled markers it replaced, but the other two components never gained
  one. Country on `/admin/settings/organization` was left reading as optional.
- **`<.textarea field={...}>` renders its validation errors** (#673 review) —
  the `FormField` clause mapped `id`/`name`/`value` but not `field.errors`, so a
  field-bound textarea showed no message and no `textarea-error` however the
  changeset failed. The admin-note box on the user detail page was the fourth
  call site to inherit it.
- **`<.pagination_controls>` uses daisyUI 5 `join`** (#673) — `btn-group` was
  removed in daisyUI 5, so the page buttons had lost their grouping.
- **`<.search_toolbar>` takes an `id`** (#673) — defaults to one derived from the
  change event; without a form id LiveView form recovery is silently disabled.

### Fixed
- **The user detail page no longer 500s on a structured custom field** (#673) —
  `custom_fields` is free-form JSONB, and `to_string/1` raises on a map, so any
  user who had ever used the media browser (`media_expanded_folders`, a list) or
  the etcher (`etcher_line_params`, a map) took the whole page down. Structured
  values now render as JSON, lists join.
- **Organization-members rows are clickable on Safari/iOS** (#673 review) — the
  row used `row-link-host`, a class that lives in one host app's `app.css` and
  exists nowhere in this repo, instead of `transform-gpu`. Every member row's
  overlay collapsed onto the last one.
- **Users list rows stay clickable without the Email column** (#673 review) — the
  `row_link` was rendered only inside the `email` cell, but `email` is
  `required: false` in the column picker. Dropping it left every row wearing
  `cursor-pointer` with nothing to click. The overlay now hosts in the first
  visible non-`actions` column.
- **The custom-field "add option" input fills its row again** (#673 review) —
  `class="flex-1"` lands on the `<input>`, but `<.input>`'s
  `<div phx-feedback-for>` wrapper is the flex item; it needed
  `wrapper_class="contents"`.
- **`focus:input-primary` on `<.textarea>`** (#673) — was the input's focus class,
  never the textarea's, so a focused textarea never took the primary border.

## 1.7.218 - 2026-07-29

### Added
- **Sign in as another user** (#672) — `MultiSession.impersonate/2`, a
  `POST /users/session/impersonate/:user_uuid` action, and the authority layer
  over the existing multi-account stack. The rules are role-based on purpose:
  `Scope.can_access_admin_area?/1` is true for **any** permission holder, so a
  permission check would have let a customer with one self-service grant borrow
  another customer's account. Instead the **root** account decides (never the
  active one, or an impersonated session could chain) and must hold Owner or
  Admin; an Owner is never a target; an Admin cannot take another Admin, while
  an Owner can, because there is nothing above it to escalate to. Requires
  `multi_session_enabled`.

### Changed
- **`MultiSession.add_authenticated_user/3`** (#672 review) — takes the
  activity-feed action to write, defaulting to `session.account_added`. Existing
  `/2` callers are unaffected.
- **`already_intercepted: true` now implies `skip_queue: true`** (#670 review) —
  the opt can only mean "a queue worker is re-sending what it dequeued", so
  leaving the two independent let a worker that set one and forgot the other
  offer its own job straight back to the queue that handed it over.
- **`session.impersonated` and `session.account_added` render as notifications**
  (#672 review) — both are claimed by the `security` preference type (so they
  appear in the preferences UI and can be muted) and both have recipient-facing
  copy instead of the humanized raw action string ("Session impersonated").

### Fixed
- **Impersonation refusals are recorded** (#672 review) — the feed was written
  only on success, and only after the session had already changed, despite the
  documented promise of "every attempt, before the session changes". An Admin
  reaching for the Owner's account, reaching sideways for another Admin, or a
  non-staff user hitting the endpoint directly all left no trace at all. They now
  write `session.impersonation_refused` with the deciding rule in
  `metadata["reason"]`, and carry no `target_uuid` so a refused attempt is a feed
  entry rather than a message sent to the account it named.
- **One activity row per impersonation, saying what happened** (#672 review) — a
  success wrote both `session.account_added` and `session.impersonated`, and the
  first is indistinguishable from a user voluntarily adding an account of their
  own.
- **Impersonation authority is settled before the uuid is resolved** (#672
  review) — checking existence first answered "User not found." for an unused
  uuid and a permission message for a live one, turning the deliberately precise
  operator copy into an account-existence oracle for every signed-in user. New
  `MultiSession.may_impersonate?/1` shares its rule with
  `authorize_impersonation/2` so the two cannot drift.
- **Existing users are no longer renamed when the admin form rebuilds its
  changeset** (#671) — `maybe_generate_username_from_email/1` ran on every
  registration changeset and minted a username whenever the params carried none,
  which is exactly what the admin edit form sends; and the uniqueness walk asked
  the database whether the name was taken without excluding the user it was
  generating for, so `maria`'s own row made `maria` look unavailable to maria.
  Opening a user and saving turned `maria` into `maria_1`, then `maria_2`.
- **A generated username carries its uniqueness constraint** (#671 review) —
  generation runs at the end of `registration_changeset/3`, after
  `validate_username/2` has already decided there was no username change to
  guard, so the generated name reached the database unprotected. Two
  registrations racing on the same local part both settled on it and the loser
  got an `Ecto.ConstraintError` raised out of `Repo.insert/1` instead of an
  `{:error, changeset}`.
- **A queued message is intercepted once** (#670) — `skip_queue: true` skipped
  only the queue offer, so a queued-then-drained message went through
  `intercept_before_send/2` twice and a provider that logs per interception
  recorded every send twice.
- **Out-of-contract `maybe_enqueue/2` returns are logged** (#670) — a provider
  bug returning anything other than `:continue` / `{:queued, ref}` still sends
  (a bug must not eat the message) but no longer does so invisibly.
- Removed seven `Logger.info` calls left in the admin user form from debugging
  the username rewrite (#671).

## 1.7.217 - 2026-07-28

### Added
- **SMTP transport settings** (#668) — five optional setup fields on the `smtp`
  integration provider: `security` (`auto` / `ssl` / `starttls` /
  `starttls_optional` / `none`), `auth` (`if_available` / `always` / `never`),
  `verify_cert` (`verify_peer` / `verify_none`), `ca_cert` (a PEM bundle that
  replaces the system store for that connection) and `timeout` (seconds).
  Blank reproduces the previous port-based rule exactly, so existing connections
  send unchanged; unknown values are **refused** rather than coerced back to
  `auto`, so a typo cannot silently downgrade a connection's encryption. The
  Test Connection probe builds from the same `SmtpTransport.config/1` options as
  the send path.
- **Optional `maybe_enqueue/2` callback on `PhoenixKit.Email.Provider`** (#668)
  — offered right after `intercept_before_send/2` on **both** delivery paths, so
  an email package can take delivery over for every outgoing message, including
  the host application's password resets and confirmations. `{:queued, ref}`
  short-circuits the send and reaches the caller as
  `{:ok, %{id: ref, queued: true}}`; `:continue` sends normally. Guarded by
  `function_exported?/3`, so a package built against an older core is unaffected.
  `skip_queue: true` lets a queue worker ask for the real send.
- **Setup fields render by `:type`** (#668) — `setup_field/1` now honors
  `:select`, `:textarea` and `:number` instead of forcing `type="text"`, with a
  text-input fallback for a type it has never heard of. The website-wide
  integration form uses the shared component instead of a hand-rolled copy, so
  the two forms can no longer drift.
- **Sender-address warning on the Email Sending settings page** (#668) — a
  sender that is not a full address (the built-in default `noreply@localhost`
  among them) is silently refused by the email tracking module's `Log`
  changeset, so mail went out and the log stayed empty with nothing in the UI
  saying why. The page now warns, both in a banner and on save.
- **`Chart` core component** (#669) — server-rendered SVG `line_chart/1`,
  `sparkline/1` and `bar_chart/1`. No JS, no external library; theme-aware via
  `currentColor`, and live by construction (assigns change → SVG re-renders).
  Points may be `{x, y}` tuples or `%{x: _, y: _}` maps, `Decimal` is converted
  automatically, and non-numeric points are dropped rather than crashing the
  page — with an `:empty` slot for "nothing usable left".
- **`StatusDot` core component** (#669) — semantic coloured dot with an optional
  label and `pulse`, plus a screen-reader state name so the state is not carried
  by colour alone.
- **`ConnectAccountButton` core component + `PopupLink` JS hook** (#669) —
  OAuth-popup account linking (distinct from `OAuthProvider`, which is app
  sign-in). A real `<a href>` intercepted only once `window.open` returns a
  window, so a blocked popup, JS being off, or a modifier-click all fall back to
  ordinary navigation.
- **`value_color` on `<.stat_card>`** (#669) — for values whose colour *is*
  information (a price coloured by cheapness). Any `;` is stripped so the value
  cannot append further declarations.
- **`mix test.js`** (#669) — `node --test` over the pure logic in the shipped
  hook bundle, wired into `mix precommit`. Skips itself when node is not
  installed, or when the glob matches nothing.

### Changed
- **`<.stat_card>`'s `rounded` attr is now honored** (#669). It was previously
  declared and ignored — the class was hardcoded `rounded-box`. Two consequences
  for consumers: a caller that already passed `rounded="xl"` now actually gets
  `rounded-xl`, and the attr has a closed `values:` list (`box`, `none`, `sm`,
  `md`, `lg`, `xl`, `2xl`, `3xl`, `full`), so a value outside it emits a
  compile-time warning. The whitelist exists because Tailwind scans source for
  literal class names — an interpolated `rounded-#{@rounded}` produces a class
  with no CSS behind it.
- **SMTP `username` and `password` are no longer required fields.** An internal
  relay that authenticates by IP has no login to give, and `SmtpTransport` has
  always had a credential-less branch — but marking the fields required made it,
  and the new `auth: never` / `security: none` settings, impossible to reach:
  the form refused to submit and `connected?/1` refused to call the connection
  configured, so mail silently fell back to the built-in mailer. `host` and
  `port` remain required. The Test Connection probe stops forcing `auth: always`
  when there is no login to prove, which would otherwise have failed every such
  relay.
- **Personal integrations form clears blanks like the website form does.** It
  dropped blank values for *every* field, so a cleared optional field — an SMTP
  CA bundle, a timeout — kept its old value while the form showed empty. Blanks
  are now dropped for `:password` fields only, matching
  `Settings.IntegrationForm`, and values are trimmed on both paths.

### Fixed
- **`mix precommit` failed on dialyzer** — the sender-address check added in
  #668 had an unreachable catch-all clause (`pattern_match_cov`), which halted
  `mix dialyzer` with exit status 2 and, because aliases run in order, meant the
  new `test.js` step never ran at all.
- **`:type` is read softly on the integration save paths too.** `setup_field/1`
  was hardened to tolerate a provider field map without `:type` (external
  modules contribute providers through `integration_providers/0`), but both save
  paths still did `field.type` — so such a provider rendered fine and then raised
  `KeyError` on submit, after the operator had committed to their input.
- **SMTP `timeout` no longer accepts a number with a unit.** `Integer.parse/1`
  returns `30` for both `"30s"` and `"30 minutes"`, so an operator who typed
  minutes got a 30-second timeout with no complaint. The remainder must now be
  empty.
- **`deliver_via_integration/3`'s documented error list** now names the five
  SMTP transport-setting reasons added in #668.

## 1.7.216 - 2026-07-27

### Fixed
- **Every `phx-change` form now carries an `id`** — LiveView cannot perform form
  recovery on an id-less form, so a crash or reconnect silently dropped whatever
  the user had typed, and host test suites saw an unfixable
  `Detected a form with phx-change but missing id` warning coming out of the
  dep's own templates (the only workaround being
  `config :phoenix_live_view, :test_warnings, missing_form_id: :ignore`, which
  also mutes the host's own genuine cases). 26 forms across core, storage,
  sitemap and maintenance were affected. Ids on LiveComponent-rendered forms are
  derived from the component's `@id` (and, for per-row inline folder rename /
  description editors, the folder uuid) so nothing collides when a page renders
  more than one. `<.form for={%{}}>` call sites were affected too — a bare map
  with no `:as` produces a `nil` id — so `MediaBrowser`'s search, the annotation
  composer, the media selector upload form and the storage media-config form are
  fixed as well.

### Changed
- **`<.sort_selector>` accepts an `id`** — defaults to
  `"pk-sort-selector-#{event}"`; pass an explicit one when a page renders two
  sort selectors that share an `event`.

## 1.7.215 - 2026-07-27

### Fixed
- **Sitemap: `/users/qr-login` and `/robots.txt` no longer land in the sitemap**
  — both were missing from Router Discovery's default exclude patterns. The QR
  device-handoff login is a public route with no auth pipeline and no `on_mount`
  hook, and the existing `"/users/log-in"` pattern does not match it; a
  controller-served `robots.txt` reaches the router the same way (Plug.Static
  installs are unaffected). Note that `sitemap_router_discovery_exclude_patterns`
  *replaces* the defaults when saved, so installs that already customized the
  list must re-copy it from `/admin/settings/sitemap` to pick these up.

## 1.7.214 - 2026-07-27

### Added
- **Notification delivery channels** (PR #665) — a parallel routing layer that
  sends notifications to external destinations alongside the in-app inbox.
  Core ships Email (always available, uses the account address) and Telegram
  (auto-discovers the recipient's personal bot connection and its captured
  chats); feature modules contribute more via the optional
  `notification_channels/0` callback. Per-user, per-type opt-in lives in
  `users.custom_fields` under one `notification_channel:<key>` key per channel,
  so no migration is needed and the inbox path is untouched — "Telegram on,
  inbox off" works. Delivery runs off the hot path on a dedicated
  `:notifications` Oban queue with a permanent/transient error taxonomy (a
  blocked bot soft-disables the channel instead of retry-storming).
- **Notification aggregation** (PR #665) — each type can be routed on a digest
  cadence (hourly / 12h / daily / weekly) per delivery mode instead of pinging
  per event; `PhoenixKit.Notifications.DigestWorker` sweeps one fixed window per
  cadence on cron and sends a single summary, with no per-user last-sent state.
  In-app is a delivery mode too, so a digest cadence collapses the inbox to one
  summary row.
- **Personal (per-user) integrations** (PR #665) — connections now carry an
  owner (`:system | :any | {type, id}`) stored in the existing JSONB
  (`owner_type` / `owner_uuid`, write-once, no migration). Two independent
  admin surfaces share the storage: `/admin/settings/integrations` (personal,
  gated by the new `integrations` permission key) and
  `/admin/settings/integrations/website` (website-wide, gated by
  `integrations_system`). Providers declare which scopes they allow
  (`Providers.scopes_of/1`), enforced at row birth so a crafted event cannot
  create a personal OAuth connection.
- **`"*"` superadmin permission key** (PR #665) — a blanket, drift-immune grant
  that makes a role Owner-equivalent for feature access without enumerating
  keys, honored by `Scope.has_module_access?/2`, `can?/2` and
  `accessible_modules/1`. Owner holds it structurally; a host can grant it to a
  custom role. Role-management safety rails (editing Admin, assigning
  Owner/Admin, the last-Owner guard) stay role-name-based and are NOT unlocked
  by it.
- **Permission audit trail** (PR #665) — `permission.granted` /
  `permission.revoked` / `permission.synced` activity entries for
  user-initiated changes (the boot-time auto-grant sweep passes no actor, so
  startup never floods the feed).
- **Telegram bot client** (PR #665) — `PhoenixKit.Integrations.Telegram`:
  `send_message/4` plus a one-shot `get_updates/2` used purely to discover a
  user's `chat_id` during chat linking.
- **Site-wide Default Editor Mode setting** (PR #664) — `editor_default_mode`
  (Hybrid / Visual / Markdown / HTML) under a new "Content Editor" section on
  `/admin/settings`, plus `PhoenixKit.Settings.get_editor_mode/0` returning the
  mode as an atom ready for Leaf's `mode` attr. No migration: the settings LV
  merges `get_defaults/0` over the stored rows.
- **V159** (PR #665) — publishing categories (hierarchical per-group taxonomy,
  `slug` unique per group, `name_i18n` per-language names), post↔category M:N
  assignment, and per-day post view rollups.

### Changed
- `Scope.admin?/1` is renamed **`Scope.can_access_admin_area?/1`** (PR #665).
  The old name misled — it is true for ANY permission holder, not just the
  Admin role. `admin?/1` remains as a `@deprecated` alias. For a "can do
  everything, like Owner" check use `holds_all_enabled_permissions?/1` or
  `superadmin?/1`.
- **Disabled modules are now blocked for everyone, Owner included** (PR #665),
  uniformly across the LiveView mount hook, the fresh-mount gate and the plug —
  previously Owner bypassed enablement in two of the three, so the same user
  saw a disabled module's page through one gate and a redirect through another.
- **Unmapped admin views now require a full-access scope** (PR #665) rather than
  `system_role?`, so a named Admin whose keys an Owner partially revoked no
  longer reaches them. A default Admin still passes (the baseline is enabled
  keys minus the opt-in ones); a deliberately-stripped role gets blanket access
  via the `"*"` key.
- Every permission mutation path (`grant_permission`, `revoke_permission`,
  `set_permissions`, `revoke_all_permissions`) now takes the **same role-row
  lock first** (PR #665). Previously per-key grants and the whole-role sync used
  disjoint lock objects, so a grant committed mid-`set_permissions` survived a
  strip the Owner intended.
- `leaf` 0.3.2 (PR #664) — hex pin and the CDN pin in
  `priv/static/assets/phoenix_kit.js` moved in lockstep.
- `usage_rules` 1.2.7.

### Fixed
- **`mix phoenix_kit.update` now backfills the notification digest cron
  entries** (post-merge review of #665). `ensure_cron_plugin/2` short-circuits
  as soon as `ProcessScheduledJobsWorker` is in the crontab, so an existing host
  got the new `:notifications` queue but never the four `DigestWorker` entries —
  and `DigestWorker` has no other enqueue site. Because the creation path
  already suppresses the per-event inbox row once a type is on a non-immediate
  cadence, a user picking "Daily" on an upgraded host got no per-event row *and*
  no summary: the notifications were silently lost, in-app and external alike.
  The new `ObanConfig.ensure_digest_cron_entries/2` adds each missing cadence
  independently and anchors the crontab block's closing bracket to the
  `crontab:` keyword's own indentation, so a lazy match cannot land entries
  inside a nested list.
- **The notification settings page no longer persists unvalidated keys from form
  params** (post-merge review of #665). `save_channel_types/2` and
  `save_cadences/2` used raw param keys as storage keys, so a crafted submit
  wrote arbitrary `notification_channel:<anything>` blobs — with arbitrary
  nested type/cadence entries — into the user's `custom_fields` JSONB. Both now
  filter against `Channels.keys()` / `["inapp" | Channels.keys()]` and
  `Types.all_pref_keys()`, matching what the sibling in-app save already did.
- **Module-contributed notification channels are no longer dropped in a
  release** (post-merge review of #665). `Channels.external_channels/0` guarded
  with a bare `function_exported?/3`, which answers false for a module that has
  not been loaded yet — the norm under lazy loading. It now calls
  `Code.ensure_loaded?/1` first, matching the sibling `Types.external_types/0`.
- **A wholly-failed Telegram broadcast is no longer silent** (post-merge review
  of #665). When every chat fails permanently the channel still reports `:ok`
  (one blocked subscriber must not disable a working broadcast), but a revoked
  token or a bot kicked everywhere looked exactly like a successful delivery. It
  now logs a warning naming the target count and the failures.
- **The editor-mode allowlist has a single source** (post-merge review of #664).
  The four modes were written out independently in `editor_mode_options/0`, the
  changeset's `validate_inclusion`, and `get_editor_mode/0`'s coercion clauses —
  while `editor_mode_options/0`'s docstring claimed to be the single source for
  all three. A mode added to two of the three either saves and silently coerces
  back to `:hybrid`, or is offered in the picker and rejected by the changeset.
  All three now derive from one `@editor_modes` list.

## 1.7.213 - 2026-07-26

### Changed
- **Lifeline is now validated by value, not just presence.** 1.7.212 raised the
  shipped `rescue_after` to 60 minutes at every emit site, but both the
  installer and `mix phoenix_kit.doctor` still only asked whether an
  `Oban.Plugins.Lifeline` entry existed. Oban's own docs advertise
  `rescue_after: :timer.minutes(5)` as the "more aggressive period" example, so
  a host copying from them sat squarely in the duplicate-execution window while
  PhoenixKit reported everything as fine.
  - `mix phoenix_kit.doctor` warns when `rescue_after` is at or below the
    longest `timeout/1` PhoenixKit ships (30 minutes,
    `Storage.Workers.SyncFilesJob`). An *unset* `rescue_after` is treated as
    safe — that means Oban's own 60-minute default.
  - `PhoenixKit.Install.ObanConfig.ensure_lifeline_plugin/2` raises a too-low
    `:timer.minutes(N)` literal to 60 instead of no-oping on any existing entry.
    Only that literal form is rewritten; any other expression (raw
    milliseconds, a module attribute, a runtime lookup) is left untouched with
    a notice rather than blind-edited.
  - The value now has a single source (`lifeline_entry/0`) feeding the
    generated template, the backfill and the manual-fallback message, so the
    emit sites cannot drift apart again.
- **V157 `down/1` fails loudly instead of opaquely** (issue #663). Rolling back
  re-adds the narrower `phoenix_kit_annotations_kind_check`, and Postgres
  validates a CHECK against every existing row — so one `kind = 'image'`
  annotation created since `up/1` made the rollback die with a bare `23514`
  partway through. `down/1` now checks first and raises a message naming the row
  count and the two real ways forward (remove/convert the rows, or stay on V157
  — its widened CHECK is a superset of V156's). The check runs before anything
  is queued, so no half-applied DDL is left behind. Deleting user annotations
  from a rollback, and `NOT VALID` (a constraint that lies about the rows
  already present), were both rejected as worse; see the new
  `## down/1 is conditional, by necessity` moduledoc section.

### Fixed
- `mix phoenix_kit.doctor` no longer emits a false-positive Lifeline warning on
  a node running `plugins: false`. 1.7.212 stopped the `length(false)` crash but
  then let `false` fall through as `[]` into the Lifeline branch, so a
  deliberately plugin-less node was told to run `mix phoenix_kit.update` — which
  would rewrite `config.exs` for a node that must not run plugins at all. It now
  reports plugins-disabled and skips the check.

### Added
- `test/phoenix_kit/migrations/v157_test.exs` (issue #663) — V157 was the one
  recent migration with no test of its own. Deliberately narrow:
  `annotations/annotation_kind_test.exs` already pins both layers accepting
  `"image"`, so this file pins the CHECK's *whole* vocabulary, which is what a
  later migration could silently narrow while leaving that file green. Not yet
  executed against a live database — see the investigation doc.
- The Lifeline invariant test now discovers workers at runtime (every
  `Oban.Worker` in `:phoenix_kit` exporting `timeout/1`) instead of hardcoding
  three modules, so a new long-running worker fails the test rather than
  quietly eroding the margin.
- `dev_docs/investigations/2026-07-26-issue-663-post-release-audit.md` — full
  write-up of issue #663's four items, including the two that did **not** hold
  up: the Tessera CDN pin (`tessera@v0.3.1` vs `mix.lock` 0.3.4) is a cosmetic
  mismatch only — `alexdont/tessera` has no `v0.3.4` tag, so the recommended
  bump would 404 the loader, and the asset is byte-identical across v0.3.1,
  v0.3.2 and hex 0.3.4 — and the `#652` host-router note is already satisfied by
  the `:browser` pipeline `mix phx.new` scaffolds.

## 1.7.212 - 2026-07-26

### Added
- **`Oban.Plugins.Lifeline` shipped to host apps** (PR #662). The Oban config
  `mix phoenix_kit.install` generates now carries
  `{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}`, and
  `mix phoenix_kit.update` backfills it into an existing host config via the
  new `PhoenixKit.Install.ObanConfig.ensure_lifeline_plugin/2`. Without it a
  job orphaned in `:executing` by a hard crash (`kill -9`, OOM, node loss) is
  never returned to `:available` — and for a unique worker whose `states:`
  includes `:executing`, that orphan permanently blocks every future insert
  for the worker, not just the crashed job.
- `mix phoenix_kit.doctor` warns when the host's running Oban config has no
  Lifeline plugin, pointing at `mix phoenix_kit.update` as the remedy.

### Changed
- `bandit` 1.12.1 → 1.12.3.

### Fixed
- Post-merge review of PR #662 (`dev_docs/pull_requests/2026/662-oban-lifeline-installer/`):
  - **`rescue_after` raised 30 → 60 minutes.** Lifeline rescues purely by
    elapsed time and never checks whether the executing node is still alive, so
    `rescue_after` must exceed the longest job the host can legitimately run.
    PhoenixKit itself ships a 30-minute worker (`Storage.Workers.SyncFilesJob`),
    and every worker without a `timeout/1` callback has no bound at all — at 30
    minutes a long newsletters-delivery, shop-import or sitemap run would be
    flipped back to `:available` and re-executed *concurrently with the still
    running original* (duplicate emails on the delivery queue). 60 minutes is
    Oban's own default and 2× the longest declared timeout. The invariant is
    now documented in the generated `config.exs` comment and locked by a test
    that asserts the emitted value exceeds every shipped worker's `timeout/1`.
  - `add_cron_plugin_to_plugins/2` no longer matches its plugins-block close
    with the un-anchored `\n[ \t]+\]`, which binds to the first *nested* list's
    bracket — the same corruption PR #662 fixed in `ensure_lifeline_plugin/2`
    but left in its sibling. A host whose `plugins:` list contains an entry with
    a list option (`{Oban.Plugins.Reindexer, indexes: [...]}`, Oban Web's stats
    plugin) would have had its `config.exs` mangled by `mix phoenix_kit.update`.
    It now uses the same indentation-anchored pattern and derives the inserted
    entry's indentation from the block instead of hardcoding four spaces.
  - `mix phoenix_kit.doctor`'s Oban check no longer raises on `queues: false` /
    `plugins: false` — Oban's documented way to disable either, standard in test
    config and on hosts that run jobs from a dedicated node. `length(false)`
    raised `ArgumentError`, surfacing as a bogus `FAIL Exception: ...`.

## 1.7.211 - 2026-07-25

### Added
- **Migration V158** — `attachments JSONB NOT NULL DEFAULT '[]'` on
  `phoenix_kit_newsletters_broadcasts`: an ordered list of Storage file uuids
  attached to every email of a broadcast, guarded by a
  `phoenix_kit_newsletters_broadcasts_attachments_is_array` CHECK
  (`jsonb_typeof = 'array'`). Soft references, no FK into
  `phoenix_kit_files` — same precedent as this table's `crm_list_uuid` (V152)
  and `source_params` (V155), so a file later deleted from Media degrades to
  skipped-at-send rather than blocking the delete. Element-level validation
  (uuid-ness, count cap) lives in the `phoenix_kit_newsletters` `Broadcast`
  changeset. `@current_version` bumped 157 → 158 (PR #661).

### Changed
- `bandit` 1.12.0 → 1.12.1, `plug_crypto` 2.1.1 → 2.2.0.

### Fixed
- Post-merge review of PR #661 (`dev_docs/pull_requests/2026/661-broadcast-attachments-v158/`):
  `v158_test.exs`'s `information_schema.columns` lookup now anchors
  `table_schema = 'public'` — `prefix_migration_test.exs` builds the same table
  in a scratch schema on the same database, so an interrupted run could leave
  two matching rows and fail the suite with an unrelated `CaseClauseError`.
  Added a CHECK-rejection test for a JSON scalar (the object case alone covered
  one of the five non-array `jsonb_typeof` results), and a `## down/1`
  moduledoc section recording that V158 must roll back together with the
  newsletters release that writes the column.

## 1.7.210 - 2026-07-23

### Fixed
- **Issue #652** — `** (ArgumentError) flash not fetched, call fetch_flash/2`
  on every router-rendered LiveView that redirects during mount with a flash
  message set (e.g. `:phoenix_kit_ensure_admin`'s "You must log in to access
  this page." redirect for unauthenticated admin-route hits). The dev/test
  router's `:browser` pipeline had no `fetch_flash`/`fetch_live_flash` plug,
  so `Phoenix.LiveView.Controller.live_render/3` crashed instead of
  redirecting whenever it tried to fold the on-mount flash back onto the
  conn. Added `plug :fetch_live_flash` to `lib/phoenix_kit_web/router.ex`'s
  `:browser` pipeline, plus a regression test. Test-harness-only fix — real
  parent apps generated via `mix phx.new` already carry this plug by
  convention.

## 1.7.209 - 2026-07-23

### Added
- **Etcher image annotation tool** — the media viewer's annotation toolbar
  now exposes Etcher's `:image` tool (fresco `~> 0.10`, etcher `~> 0.9`),
  which inserts an image annotation via the OS file picker as a `data:`
  URL (PR #660).
- **Migration V157** — widens `phoenix_kit_annotations_kind_check` to allow
  the new `"image"` annotation kind, paired with `Annotation.@kinds`.
  `@current_version` bumped 156 → 157.

### Fixed
- The `:image` toolbar tool added by PR #660 shipped without widening the
  annotation kind whitelist/CHECK constraint to match — image annotations
  drew fine client-side but silently failed to persist across a reload
  (same regression class as V130's `"marker"` fix). Closed by V157 above.

## 1.7.208 - 2026-07-21

### Changed
- `<.admin_page_header back={...}>`'s back affordance now renders inline
  beside the title (a circular icon chip aligned to the title's first line)
  instead of as a bare ghost button on its own row above it. When
  `back_label` is set, the chip widens to show the label from the `sm`
  breakpoint up; phones always stay icon-only. A blank `back_label=""` now
  normalizes to absent instead of producing an empty `aria-label`/tooltip.
  No attribute API change — all existing `back`/`back_label` call sites
  render the new anatomy unchanged (PR #659).

## 1.7.207 - 2026-07-21

### Added
- **Migration V156** — migrates legacy `phoenix_kit_newsletters_lists` /
  `..._list_members` into the CRM's `phoenix_kit_crm_lists` /
  `..._crm_list_members` (spec §4.5), re-points
  `phoenix_kit_newsletters_broadcasts` off `list_uuid` onto
  `source_type = 'crm_list'` / `crm_list_uuid`, then drops the legacy tables
  and column entirely. Requires a coordinated release with the newsletters
  module — see the migration's moduledoc warning. `@current_version` bumped
  155 → 156.
- `PhoenixKit.Users.Auth.merge_user_custom_fields/3` — atomically merges keys
  into a user's `custom_fields` JSONB column at the database level
  (`custom_fields || additions` inside the `UPDATE` itself), closing a
  lost-update race where two callers merging *different* keys concurrently
  (e.g. a locale-preference switch and a newsletters opt-out) could silently
  drop one writer's key. `delete_user_custom_field/3` gets the same atomic
  treatment (`custom_fields - key`); `set_user_custom_field/3` and
  `update_user_locale_preference/2` now route through these atomic
  primitives instead of a read-modify-write whole-map replace.
- `PhoenixKit.RepoHelper.update_all/3` — delegate to the configured repo's
  `update_all/3`, needed by the atomic custom-fields primitives above.

### Fixed
- `merge_user_custom_fields/3` and `delete_user_custom_field/3` now bump
  `updated_at` on write (missed in the initial PR since `Repo.update_all/2`,
  unlike a changeset-backed `Repo.update/2`, doesn't auto-stamp timestamps).

## 1.7.206 - 2026-07-20

### Added
- **Migration V154** — `phoenix_kit_og_templates` (reusable OpenGraph canvas
  designs; JSONB `canvas`) and `phoenix_kit_og_assignments` (binds a template
  to a `module_key × scope_type × scope_uuid` scope via a partial-index pair),
  powering the upcoming `phoenix_kit_og` plugin. `@current_version` bumped
  153 → 154.
- **Migration V155** — `crm_contact_uuid` on `phoenix_kit_newsletters_deliveries`
  (soft reference, no FK, matching the `crm_list_uuid` convention), a widened
  `..._recipient_check` CHECK (still requires an addressable recipient, and
  now also forbids a row claimed by both `user_uuid` and `crm_contact_uuid`),
  the first DB-level per-broadcast delivery dedup (three partial unique
  indexes), and `source_params` JSONB on `..._broadcasts` for the new
  `user_group` (core-role) recipient source. `@current_version` bumped
  154 → 155.
- `<.bulk_actions_toolbar>` gained a `:trailing` slot for far-right toolbar
  content (e.g. a view-mode switcher) that should sit apart from the
  left-aligned sort/filter controls.
- `<.search_toolbar>` shows a loading spinner while its debounced search is
  in flight; opt out with `loading_indicator={false}` for client-instant
  filters (pairs with the new `TableLocalSearch` hook).
- `TableLocalSearch` JS hook: client-instant row narrowing for
  `<.search_toolbar>` tables once the full row set is already loaded, without
  waiting on the server round-trip.
- `AdminSidebarScroll` JS hook: the admin sidebar keeps its scroll position
  across live redirects and full reloads instead of resetting to the top.
- `<.tab_item>` sets `aria-current="page"` on the active tab.
- `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` gained `page_action`:
  a compact circular action button rendered next to the breadcrumb title.
- `PhoenixKit.Settings.timezone_options/0` and `get_timezone_label/1`: a cheap
  timezone-label accessor that resolves without building the full
  `get_setting_options/0` map, so callers that only need the timezone string
  no longer pay for a `Roles.list_roles/0` query on every call.

### Changed
- Bumped `etcher` to `0.8.2` (fixes invisible circle annotations on a rotated
  canvas).

## 1.7.205 - 2026-07-19

### Changed
- Bumped `beamlab_ex_aws_sqs` to `~> 5.0`, declared as `{:ex_aws_sqs, "~> 5.0", hex:
  :beamlab_ex_aws_sqs}`. v5.0.0 renamed the compiled OTP app back to `:ex_aws_sqs`
  (only the Hex package name is `beamlab_ex_aws_sqs`), so it can be a drop-in for
  anything depending on `:ex_aws_sqs` directly. No code changes — `ExAws.SQS`'s
  public API is unchanged.

## 1.7.204 - 2026-07-19

### Added
- Media browser: per-file kebab menu gained Rotate left/right (counter-
  clockwise + clockwise), saving `metadata["rotation"]` the same way the
  viewer's rotate button does and refreshing the grid thumbnail live.
- Esc now exits the media browser's select mode, mirroring the toolbar's
  Cancel button.

### Changed
- **New folders default to a small hero header** instead of medium
  (`PhoenixKit.Modules.Storage.Folder.header_size` default flips to
  `"small"`). **Migration V153** flips the DB column default to match and
  backfills existing `'medium'` rows to `'small'` (indistinguishable from
  "never customized"); rows already on `'large'` or `'small'` are left
  alone. `@current_version` bumped 152 → 153.
- **A folder's Trash is now scoped to that folder's own subtree** instead
  of always listing every trashed folder/file across the whole install —
  opening Trash inside a folder no longer shows what was trashed under
  unrelated sibling roots. Applies to the trash view, the trash-count
  badge, and Empty Trash.

### Fixed
- **A folder's own cover/logo files were hidden from that folder's file
  listing.** They're real, re-selectable files (not synthetic assets) and
  now show up like any other file in the folder they decorate.
- Estonian (`et`) translations: several `default.po` entries were mapped to
  the wrong string entirely (e.g. "Header size" read as "Pealkiri"/Title,
  "Documents" read as "Kommentaarid"/Comments) rather than being merely
  untranslated.
- **"Test email" on the Email Sending settings page showed a raw
  `{:incomplete_credentials, [...]}` tuple** when the active send
  integration was missing a required field. Now shows a plain-language
  message naming the missing field(s).
- **Migration V152**: a newsletters delivery row could be saved addressable
  by neither a core `User` nor a snapshotted `recipient_email`, making it
  unreachable by any send path. Added a `CHECK (user_uuid IS NOT NULL OR
  recipient_email IS NOT NULL)` constraint as a DB-level backstop (the Ecto
  insert path already guarded this; the constraint just closes the gap for
  anything that bypasses it).

## 1.7.203 - 2026-07-18

### Added
- **Send Profiles moved from `phoenix_kit_newsletters` into core.**
  `PhoenixKit.Email.SendProfile`/`SendProfiles` are now shared infrastructure
  any module can send through, routed via the profile's `Integrations`
  connection (per-provider `ProviderOptions`, including SES/Brevo
  configuration-set and tag options). App-config transport is now
  detect-and-display only.
- **New Settings → Email Sending page**: transport detection, default-profile
  picker, and a seam (`email_settings_sections/0`) where external modules
  (e.g. the `emails` package) mount their own settings sections as
  live_components instead of owning a separate Settings tab. Send Profiles
  CRUD gets its own nested sidebar entry under Email Sending.
- **Quota/credits surfacing per send profile**: SES `GetSendQuota` and Brevo
  `/account` (plan + credits) are now shown per profile; a validator that
  cannot verify actual sending capability (e.g. SES credentials scoped to
  `ses:SendEmail` alone) says so instead of showing a bare green tick.
- **Migration V152**: `email_send_profiles` created in core (uuid-preserving
  copy from the old newsletters table, which is then dropped); CRM contact
  list groundwork (`phoenix_kit_crm_lists`, `phoenix_kit_crm_list_members`,
  citext member email); broadcasts can now source recipients from a CRM list
  (`source_type`/`crm_list_uuid`, soft reference).

### Fixed
- **A stored email connection with a blank required field (SMTP `host`, SES
  `aws_region`) could crash mail delivery with the plaintext secret embedded
  in the crash message.** A connection's `status` can say "connected" while
  an individual field was blanked out after the last successful validation;
  that reached `Swoosh.Mailer.deliver/2` uncaught, which raises with the
  *entire* adapter config — password/access key included — inlined in the
  exception text. `PhoenixKit.Mailer.swoosh_config_for/1` now validates
  required fields itself and fails closed with
  `{:error, {:incomplete_credentials, [field_names]}}` before any
  secret-bearing config is built.
- **`pagination_range/2` could OOM the whole BEAM.** An unclamped
  `current_page` (e.g. `?page=9999999999`) built a descending
  `9999999997..56` Range — ~10 billion iterations in the component's `for`.
  Now clamps into `[1, max(total_pages, 1)]` with an explicit `//1` step as
  a second guard; `pagination_controls/1` additionally gained a
  `total_pages > 1` outer guard.
- `table_default`'s search toolbar rendered no `<form>` when only
  `on_change` was given — `phx-change` on a formless input dies silently
  client-side. The form is now always rendered.
- Admin view permission map: five settings LiveViews (Integrations,
  IntegrationForm, EmailSending, SendProfiles, SendProfileForm) resolved to
  nil → custom "settings"-scoped roles were denied. Mapped explicitly.
- A plugin module assigning `page_section` was a silent no-op —
  `admin.html.heex` now forwards it (and `page_section_path`) to the layout.
- **The universal `smtp` integration provider could not send at all.** gen_smtp
  supplies no TLS options of its own and OTP's `:ssl` now defaults to
  `verify: :verify_peer` with no CA store, so port 465 died with
  `{:options, :incompatible}` and STARTTLS died with `:tls_failed`. The transport
  now builds the options properly (`PhoenixKit.Mailer.SmtpTransport`), including
  the `depth` gen_smtp otherwise defaults to `0` — which rejects every real
  certificate chain.
- **"Test Connection" verified nothing** for `aws_ses`, `smtp` and `brevo_api`:
  the connection was stamped `"connected"` without a byte leaving the box, so a
  wrong key showed green and then failed at send time. All three now perform a
  real check, bounded by a deadline.
- **A failed connection check could take the operator's page down, or leak a
  socket for twenty minutes.** `:gen_smtp_client.open/1` runs in the calling
  process and waits on a hard-coded 20-minute timeout past `connect`; the checks
  now run in an isolated, linked-and-monitored process
  (`PhoenixKit.Integrations.Probe`) that neither kills its caller nor outlives it.

### Security
- **SMTP no longer sends in plaintext when TLS cannot be established.**
  `tls: :if_available` had been masking the broken TLS configuration above by
  silently falling back to an unencrypted session — with the relay password on the
  wire. A relay that expects credentials now fails closed.

### Changed — may require action on upgrade
- **SMTP sending now stops on images with no CA bundle** (`{:error, :no_ca_store}`)
  instead of proceeding with certificate verification disabled. Slim base images
  (distroless, scratch, some Alpine builds) are affected: install `ca-certificates`.
  A relay configured with no username or password still degrades rather than
  failing — it has no credentials to protect.
- **Configured SMTP relays are no longer MX-resolved** (`no_mx_lookups: true`).
  gen_smtp would otherwise look up the relay's MX records and connect to whatever
  they point at, while SNI and the hostname check stay pinned to the configured
  name — a guaranteed certificate mismatch. If you configured `host` as a bare
  domain and relied on MX resolution, point it at the relay itself.
- **AWS SES credentials scoped to `ses:SendEmail` alone now pass Test Connection
  with a note** rather than a bare green tick. They cannot read the send quota, so
  the check can prove the credentials are valid but not that they can send, and it
  now says so on screen instead of only in the log.

## 1.7.202 - 2026-07-18

### Fixed
- Media rotation now persists for any user, not just admins. The embedded
  `MediaBrowser` popup opts every viewer into `persist_rotation` (previously
  gated on `@admin`) — rotation is the file's shared orientation
  (`metadata["rotation"]`), not a per-user preference, so a non-admin who
  could open and rotate a file in an embedded browser saw the turn but it
  never stuck. The admin detail page already did this unconditionally; the
  popup now matches. The `Details` link stays admin-only.

## 1.7.201 - 2026-07-18

### Fixed
- `/admin/media/:file_uuid` was declared before `/admin/media/selector`,
  so the router matched `selector` as a `:file_uuid` param and the
  dedicated selector route was unreachable — reordered.
- Folder header cover/logo images now render the file's saved rotation
  (previously always unrotated, unlike every other thumbnail surface).
- `MediaSelectorModal`/`MediaSelector` selection is now an ordered list
  instead of a `MapSet`, so pick order survives to `MediaGallery`'s
  "featured image" (first entry) instead of being silently reshuffled.
  Multi-select pickers also gained an optional `max_select` cap with a
  "Maximum N files" indicator instead of the consumer silently truncating
  on confirm.
- Media browser bug sweep: "Select all" now covers files inside expanded
  stacks; download (single + bulk) resolves selections that span pages or
  live inside a stack instead of silently no-oping; permanent delete now
  double-checks `status == "trashed"`; leaving trash view reloads the real
  folder list instead of reusing the stale trashed one; switching between
  trash/normal view clears any carried-over selection; paging in
  controlled mode no longer drops the trash/orphaned views through a URL
  round-trip they can't address; deleting the last item on a page clamps
  back to the last populated page instead of showing an empty grid;
  "Delete folder" copy now correctly says contents are deleted recursively
  (not moved to the parent).
- `MediaDetail` no longer crashes on a malformed `file_uuid` route segment
  (falls back to the "not found" state).
- `MediaSelector`'s `return_to` param is now restricted to same-origin
  paths (rejects `//host` / `/\host` bypasses); `page` no longer crashes
  the mount on a non-numeric value; pagination links use `patch` instead
  of `navigate` so a page change doesn't drop the in-memory multi-select;
  the browse query now excludes trashed/system-managed files; a failed
  upload no longer crashes the LiveView.
- `storage_max_upload_size_mb` setting no longer crashes every media
  surface at mount if the stored value isn't numeric.
- Dependency bumps: `beamlab_countries` 1.0.8 → 1.1.0,
  `beamlab_ex_aws_sqs` 4.0.0 → 4.1.0.

## 1.7.200 - 2026-07-17

### Added
- Media thumbnails (browser grid/list/stacks, gallery, both media-selector
  pickers) now render a file's saved rotation as a CSS transform, matching
  what the popup viewer's canvas shows — no re-encode needed, and baked
  annotated thumbnails stay untouched on disk.
- The media browser's "⋯" overflow menu now also lists Add Media, Cancel
  upload, and Search, so every page action is reachable from one place even
  when the toolbar wraps tight.
- 4 strings (`Failed to save rotation`, `Hide details`, `Rotation saved`,
  `Show details`) translated to et/ru.

### Fixed
- A file's rotation or rebaked annotated thumbnail is now reflected in a
  collapsed stack's pile preview — previously only the grid and open
  viewer picked up the live refresh, leaving the pile stuck on the stale
  thumbnail.
- Clicking a file inside an expanded stack now opens the popup viewer
  (previously a silent no-op, since the lookup only searched the current
  page's file list, not the stack's own); the viewer's prev/next now steps
  through the correct sibling list in both stacked and flat views.
- Select-mode toolbar's exit button now reads "Cancel" instead of "Done" —
  it exits without applying anything, so "Done" read like a confirm it
  never was.

## 1.7.199 - 2026-07-17

### Added
- `MultilangForm.mount_multilang/2` now auto-attaches a `:handle_event`
  hook that intercepts the `"switch_language"` event pushed by
  `<.multilang_tabs>` — consumers no longer need their own
  `handle_event("switch_language", …)` clause (forgetting it used to crash
  the LiveView on the first tab click). Opt out with
  `auto_switch_language: false` to handle the event manually.
- `SearchPicker` gains a `search_on_focus` attr (default `false`) that
  opens the dropdown on focus/click of an empty input — promotes the
  previously JS-only `data-search-on-focus` behavior to a documented,
  first-class attribute (the raw rest attr is still honored).
- Event-based `NavTabs` buttons now pulse (`animate-pulse`) while
  `phx-click-loading` is applied, giving instant feedback for a tab
  switch whose content needs a server round-trip.

### Fixed
- Closed a test-coverage gap on the new `mount_multilang/2`
  switch-language hook (and its `auto_switch_language: false` opt-out).

## 1.7.198 - 2026-07-16

### Added
- Live refresh for the `MediaBrowser` popup viewer: `ProcessFileJob` and
  `AnnotationThumbnailJob` now broadcast completion over PubSub
  (`Storage.subscribe_to_file_events/0`), so a just-uploaded file's
  dimensions/variants and a rebaked annotated thumbnail appear in an open
  browser/viewer without a manual reload. Thumbnail updates refresh the
  grid row only — an open annotator session is never remounted mid-edit.
- Collapsible info sidebar in the popup viewer (filename/Download/
  metadata/comments), toggled from a corner button and persisted per-user
  so it survives prev/next, reopen, and reload.
- Rotation-save confirmation: a transient status pill over the canvas
  confirms each persisted rotation (or surfaces a failure) — previously
  the write was invisible, indistinguishable from a view-only rotation.
- Admin-context `MediaBrowser` clicks now open the same in-place modal
  viewer as everyone else (previously they navigated straight to
  `/admin/media/:uuid`); the viewer sidebar gains an "Open details page"
  link to the full admin page instead.
- Folder view now scrolls as a single region — breadcrumbs, hero header,
  toolbar, and file grid scroll together instead of the grid owning its
  own nested scrollport — fixing the list view's sticky column header not
  pinning correctly against the real scroll area.
- Bumped `etcher` to 0.8.0, `fresco` to 0.9.0, `tessera` to 0.3.3.

### Fixed
- `MarkdownEditor`'s unsaved-changes navigation guard is now opt-in
  (`protect_navigation={true}`), off by default. The old `true` default
  never actually armed the guard — a boolean renders as a bare HEEx
  attribute, which failed the JS hook's `=== "true"` string check — so
  this makes the previously-inert behavior deliberate, and hosts that
  pass `protect_navigation={true}` now get a real (working) guard.

## 1.7.197 - 2026-07-16

### Added
- V151: `supplier_source` (`crm_company | crm_contact | local`, CHECK-backed)
  and `is_primary` (partial-unique, one primary per item) columns on
  `phoenix_kit_cat_item_supplier_info` — completes the V149 junction for the
  merged `phoenix_kit_catalogue` sourcing layer, which reads/writes both on
  every insert/update.
- V151: normalizes `phoenix_kit_crm_contacts.email` /
  `phoenix_kit_crm_companies.email` to `citext`, a prerequisite for
  case-insensitive email matching in the CRM v2 backfill and the
  user↔contact bridge.
- `mix phoenix_kit.doctor` gains three checks: **Schema Drift** (a version
  marker claiming a column that's actually missing at the resolved prefix —
  surfaces an installer/migration-runner drift with no other self-service
  signal), **Child Start Order** (reads the host `application.ex` and fails
  when `PhoenixKit.Supervisor`/`Oban` are listed before the Repo, the boot
  crash class where Oban opens a pool against a database connection that
  doesn't exist yet), and prefix resolution now goes through the same
  `PrefixConfig.resolve_prefix/1` as `phoenix_kit.update --status`, fixing
  doctor reporting "not installed" against a prefixed install it was
  actually diagnosing at the wrong schema.

### Fixed
- Closed an `HtmlSanitizer` stored-XSS bypass: the `href`/`src` scheme
  filter only blacklisted literal `javascript:`/`vbscript:`/`data:`, so
  entity-encoded (`jav&#x61;script:`), whitespace-obfuscated
  (`java&Tab;script:`), and raw-control-char variants slipped through into
  any markdown-rendered rich-text sink. Replaced it with an allowlist
  (`http`/`https`/`mailto`/`tel` + relative/fragment URLs) evaluated over a
  decoded, control-char-stripped, normalized value — the transform only
  ever removes an attribute, never rewrites the visible URL.
- Fixed the admin sidebar's width flipping by ~15px around a modal's
  scroll-lock on long admin pages (the drawer grid's auto-sized sidebar
  column resolves differently depending on whether the page root currently
  has a scrollbar).
- `phoenix_kit.doctor`'s Oban Configuration check reported `0 queues, 0
  plugins` because doctor's own pool-capping zeroed the app-env Oban config
  before the check read it; now snapshotted before capping.
- Silenced a dialyzer false positive (`call_without_opaque`) in
  `QrLogin.location_for/1`'s `Task.Supervisor.async_nolink` +
  `Task.yield`/`Task.shutdown` idiom, matching the existing `auth.ex`
  ignore-list precedent for the same opaque-widening class.

## 1.7.196 - 2026-07-15

### Added
- OpenRouter and xAI now declare the `:image_generation` capability (OpenAI
  already did). Both genuinely have real image-gen models (OpenRouter's
  catalog includes Gemini image/GPT-image-1 style entries; xAI has
  `grok-imagine-image[-quality]`) reachable at the standard
  `/images/generations` path — gates `phoenix_kit_ai`'s new "Image
  Generation" Endpoint model type to providers that can actually serve it.

## 1.7.195 - 2026-07-14

### Added
- V150: nullable `browser`/`os` columns on `phoenix_kit_users_tokens`,
  parsed from the User-Agent at login. Session device names ("Safari on
  iOS") are now available for every session, independent of the
  `new_login_alert_enabled` setting — previously the name only came from
  `known_devices`, which that setting gates. The self-service Active
  Sessions list and the admin all-sessions page (new Device column) both
  use it, falling back to a known-device row for pre-V150 sessions.
- `Sessions.get_session_stats/0` gains `by_os`/`by_browser` breakdowns of
  active sessions (most-common first), rendered as two cards on the admin
  sessions page.
- The user-facing "Active today"/"Active yesterday" session labels now
  include the precise sign-in time ("Active today at 14:32").

### Fixed
- Admin Dashboard LiveView subscribed to the sessions PubSub topic but had
  no `handle_info` clause for `{:session_created, ...}`,
  `{:session_revoked, ...}`, or `{:user_sessions_revoked, ...}` — an
  unmatched message crashed and reconnected the LiveView. Now refreshes
  the session-stats tiles on each.
- `mix gettext.extract --merge` fuzzy-matched several of the above's new
  strings against unrelated old strings in the `ru`/`et` locales (e.g.
  "Device" landed as "Service", "By browser" as "browser tab", and the new
  `%{time}` interpolation was dropped from "Active today/yesterday").
  Corrected all affected `ru`/`et` translations to keep both locales fully
  translated, per project convention.

## 1.7.194 - 2026-07-14

### Added
- xAI provider now declares the `:realtime_voice` capability (in addition
  to `:ai_completions`), gating `phoenix_kit_ai`'s new streaming-voice
  Playground panel (built on the `xai` Hex package's `Xai.Realtime`
  WebSocket client) to xAI endpoints only.

## 1.7.193 - 2026-07-14

### Added
- V148: `phoenix_kit_crm_party_roles` table for the `phoenix_kit_crm`
  module — a polymorphic role edge marking an existing CRM company or
  contact as `supplier`, `client`, or another commercial counterparty role
  (a party can hold several roles at once). No FK on the polymorphic
  `(roleable_type, roleable_uuid)` pair; `valid_from`/`valid_to` lifecycle,
  `is_active` filter, role-scoped `metadata`.

### Fixed
- V148's `uuid` column `DEFAULT` now schema-qualifies `uuid_generate_v7()`
  with the install prefix (matching V138/V144) — the unqualified call
  would have resolved via `search_path` and failed on named-schema
  installs.

## 1.7.192 - 2026-07-14

### Added
- **Self-service Active Sessions** — a `:sessions` section in
  `UserSettings` lists a user's live sessions (device, location, last
  active), flags the current one, and lets them revoke a single session or
  all other sessions. Sessions are enriched from `KnownDevice` history;
  degrades gracefully (no browser/OS/location) for sessions predating
  device fingerprinting.
- **QR sign-in remember-me and return-to** — the desktop QR sign-in page
  gained a "Keep me logged in" checkbox and now carries a sanitized
  `return_to` through the mint → approve → finish handoff, both wired into
  the existing `UserAuth.log_in_user/3` `remember_me`/`user_return_to`
  machinery.
- **In-app notification for new-device sign-ins** — `LoginAlerts` now
  raises a standalone `"security"`-type notification (new core
  notification type) alongside the existing email when a login is seen
  from an unrecognized device.
- V147: persists the resolved `"City, Country"` geo-location on
  `phoenix_kit_user_known_devices` (nullable `location`) so Active
  Sessions doesn't need a live geo lookup per render.

### Fixed
- QR confirm screen no longer shows a bare "unknown" IP when
  `IpAddress.extract_from_socket/1` can't read peer data — treated as
  absent, same as a blank IP.
- The desktop QR page's connected mount no longer blocks showing the QR
  code behind a synchronous, up-to-~10s (two sequential providers × 5s
  each) geolocation lookup. `QrLogin.location_for/1` now bounds the lookup
  to 1.5s via an unlinked, supervised `Task` — a slow/unreachable geo API
  degrades to "no location" instead of stalling the page whose only job is
  showing the code quickly.
- Corrected Russian/Estonian translations for the new session-management
  strings introduced above, including an inverted `"Sign out"` →
  `"Войти"`/`"Logi sisse"` ("Log in") that `mix gettext.merge` fuzzy-matched
  against unrelated existing entries and left uncorrected.

## 1.7.191 - 2026-07-13

### Added
- **xAI as a built-in integration provider** — `:api_key` auth, Grok models
  via the OpenAI-compatible `https://api.x.ai/v1` API. Declares
  `:ai_completions`, so it surfaces automatically in `phoenix_kit_ai`'s
  endpoint picker with no changes needed there (provider discovery has been
  fully registry-driven since 0.9.0). *Test Connection* validates against
  `GET /v1/models` — confirmed live (401 without a key) even though the
  endpoint isn't listed on xAI's published API reference.

## 1.7.190 - 2026-07-13

### Security
- **Integration credentials (AWS SES, SMTP, Brevo API keys, etc.) were
  silently stored in plaintext on real host apps.** `encryption_key/0`
  only read the flat `config :phoenix_kit, secret_key_base:` — a key the
  installer never sets — so encryption was effectively always disabled
  outside of manual, undocumented setup. Now falls back to the host app's
  own Phoenix Endpoint `secret_key_base` (which every Phoenix app has),
  keeping the flat key's precedence so any install that *did* set it
  derives an identical key. Pre-existing plaintext values still read back
  correctly and are transparently re-encrypted on next save. `password`
  fields (SMTP) now encrypt too. The KDF is also correctly documented now
  (a single SHA-256, not PBKDF2 as previously claimed).

### Added
- **Integrations-backed email sending foundation** ("Phase 1" of a
  multi-repo newsletters effort — `phoenix_kit_emails` and
  `phoenix_kit_newsletters` both depend on this release). Adds
  `PhoenixKit.Mailer.deliver_via_integration/3`, which sends through any
  configured `PhoenixKit.Integrations` connection instead of only the
  host's static mailer adapter: `aws_ses` (key/secret), a new universal
  `smtp` provider (one named connection per vendor — Brevo, Mailgun,
  SendGrid, a self-hosted relay, etc.), and `brevo_api` (with a real
  *Test Connection* check against Brevo's account endpoint). SMTP
  transport correctly selects implicit TLS (`ssl: true`) on port 465 vs.
  mandatory STARTTLS elsewhere when credentials are present, failing
  closed rather than risking a plaintext credential leak. Recipients
  blocklisted by the optional `phoenix_kit_emails` package (hard bounces,
  complaints, manual blocks) are now refused before delivery on **every**
  outbound path, not just newsletters — auth mail included. New migration
  V145 adds `phoenix_kit_newsletters_send_profiles` (named send
  configurations, at most one default, partial-unique-indexed) and
  `phoenix_kit_newsletters_broadcasts.send_profile_uuid`.
- **New-login security alerts** ("We noticed a new login to your
  account", the same pattern GitHub/xAI/etc. use). Every login path
  (password, magic link, OAuth, QR) now checks the login's device
  (IP + hashed user-agent) against history for that user; an unrecognized
  device is emailed and logged as `user.new_login_detected`, a recognized
  one is silent. Off by default — enable at Admin → Settings →
  Authorization → "Login Notifications". New migration V143 adds
  `phoenix_kit_user_known_devices`.
- **Manufacturing/warehouse module tables consolidated into core.** Moves
  `phoenix_kit_machines`, `phoenix_kit_machine_type_assignments`,
  `phoenix_kit_machine_operations`, `phoenix_kit_warehouse_transfers`, and
  `phoenix_kit_warehouse_min_stock` out of the `phoenix_kit_manufacturing`/
  `phoenix_kit_warehouse` packages' own migrations and into core's single
  numbered chain (V144), matching the precedent already set for locations
  and other warehouse tables. Upgrade-safe for hosts on published
  `phoenix_kit_manufacturing` 0.2.0.

### Changed
- **Dropped `Jason` in favor of Elixir's built-in `JSON` module (1.18+)**
  everywhere in phoenix_kit's own code — no behavior change; `jason`
  itself stays in the dependency tree (`ecto`, `phoenix`, `ex_aws`, and
  others still require it transitively).
- **`ex_aws_sqs` replaced with the maintained
  [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs)
  fork.** Unblocks Hex publishing itself: upstream `ex_aws_sqs` (archived,
  last released January 2023) pins `hackney ~> 1.9`, which cannot coexist
  with the `hackney ~> 4.0` upgrade below without an `override: true` —
  and Hex refuses to publish any package depending on one. The fork
  declares no hackney dependency at all. SQS now speaks AWS's JSON
  protocol instead of the legacy XML protocol (response shapes changed
  accordingly in `PhoenixKit.AWS.InfrastructureSetup`); fixed a related
  latent bug surfaced by the switch — the "queue already exists" fallback
  checked for AWS error code `QueueAlreadyExists`, but the real SQS API
  error is `QueueNameExists`.
- Ported the multi-session "Accounts" switcher (add/switch/remove
  account, "log out from all accounts") into
  `UserDashboardNav.user_dropdown/1` — previously only the admin top-bar
  dropdown had it, so host apps rendering their own layout via
  `user_dropdown/1` had no multi-session UI at all.

## 1.7.189 - 2026-07-12

### Added
- **QR device-handoff login ("scan to sign in").** A signed-out browser at
  `/users/qr-login` shows a QR code; an already-signed-in phone scans it
  (native camera, no app needed), reviews the requesting device
  (browser/OS/IP), and taps Approve — the desktop signs in with no
  password. Approval always happens on the trusted phone; the desktop
  receives nothing until the phone approves. Built on the new
  [`keyfob`](https://hex.pm/packages/keyfob) library. Off by default —
  enable at Admin → Settings → Authorization → "Enable QR code sign-in".
  Post-merge hardening: the `qr_login_enabled` setting is now enforced as
  an immediate kill switch on the phone-approval and completion paths (not
  just the desktop entry point), and request creation is rate-limited per
  IP (`PhoenixKit.Users.RateLimiter.check_qr_login_rate_limit/1`) to guard
  the public, pre-auth mint endpoint against ETS-table exhaustion.

### Fixed
- **Prefix hardening for low-privilege multi-schema installs**, driven by
  a field report from a hardened install (DBA-pre-created schema, no
  database-level CREATE, PG15+ non-writable `public`, PgBouncer):
  `CREATE EXTENSION`/`CREATE SCHEMA` now check `pg_extension`/
  `information_schema.schemata` before attempting creation (Postgres
  checks the CREATE privilege *before* the IF-NOT-EXISTS short-circuit,
  failing low-privilege roles even when the object already exists); V27
  now threads `create_schema: false` through to Oban's migration so it
  can't re-default to `true` and execute a failing `CREATE SCHEMA`
  mid-chain; `uuid_generate_v7()` is now created inside the install's
  schema (not wherever `search_path` happens to point) with all ~89 call
  sites schema-qualified, including the pgcrypto `gen_random_bytes` call
  inside the function body; the prefix is validated at every entry point.
  New runtime `PhoenixKit.SchemaPrefix` (all 21 table-backed schemas
  adopt it) means prefixed installs no longer depend on the DB role's
  `search_path` for ordinary queries. Install/update/status/gen.migration
  tooling now persists and resolves `--prefix` correctly, distinguishes an
  unreachable database from a genuinely absent install, and warns when an
  existing host Oban config lacks the install's prefix.
  Post-merge: fixed a matching unqualified-call bug the same PR's own
  sweep missed — V26's pgcrypto `digest()` backfill call was still bare
  (same failure mode as the pre-fix `uuid_generate_v7()`, now qualified
  via the new `Helpers.pgcrypto_call/1`) — and fixed the new Oban
  prefix-detection regex to skip commented-out config blocks (it could
  both false-positive on a commented example block and false-negative
  when a commented block happened to mention `prefix:`, masking a
  genuinely unprefixed active block).
- **daisyUI modal scrollbar-gutter compensations removed.** Fixes a
  reported "clicked cancel and a scroll bar showed up" bug on scrolling
  pages: daisyUI ≥ 5.1's own conditional gutter reservation handles both
  scrolling and non-scrolling pages correctly on its own, so core's
  1.7.179 counter-rules and PkDialog's inline override were fighting it
  and causing the reflow. `PhoenixKit.Install.DaisyUI` now declares a
  designed-for minimum (5.6.0) and warns hosts on an older vendored
  daisyUI via `phoenix_kit.install`/`.update`/`.doctor` — advisory only,
  nothing touches host files.
- **The 1.7.188 hackney 4.x upgrade made this package un-publishable**,
  discovered while cutting this release: `mix hex.publish` refuses to
  build any package carrying an `override: true` dependency, which
  `mix.exs` needed because `ex_aws_sqs` (last released Jan 2023, since
  archived upstream) pins `hackney ~> 1.9` — incompatible with `~> 4.0`
  with no override. Switched the SQS dependency to
  [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs), a
  maintained fork with the same public API (`ExAws.SQS`) that declares no
  hackney dependency at all, clearing the conflict — `override: true` on
  both hackney and httpoison is gone, and the now-fully-unused
  `httpoison` dependency itself is dropped. The fork also switches SQS
  from the legacy Query/XML protocol to AWS's JSON protocol, which
  changes response shapes (raw `%{"QueueUrl" => ...}` instead of
  `%{body: %{queue_url: ...}}`); `PhoenixKit.AWS.InfrastructureSetup`
  (SQS/DLQ provisioning) is updated accordingly, including a latent bug
  this surfaced — the "queue already exists" fallback path was checking
  for AWS error code `QueueAlreadyExists`, but the real SQS API error is
  `QueueNameExists` (confirmed against `botocore`'s service definition),
  so idempotent re-runs of setup against a differently-configured
  existing queue likely never hit the intended fallback under the old
  protocol either.

## 1.7.188 - 2026-07-12

### Security
- **hackney upgraded 1.25.0 → 4.5.2 and httpoison upgraded 2.3.0 → 3.0.0,
  clearing all 4 hackney CVEs accepted in 1.7.178 (1 HIGH: `ssl:connect/2`
  post-handshake TLS upgrade with no timeout; 2 moderate CR/LF-injection /
  SSRF-bypass; 1 low CRLF injection).** Both are now pinned via `override:
  true` in `mix.exs`, since two stale transitive constraints still declared
  the old majors: `ex_aws_sqs` (last released 2023) pins `hackney ~> 1.9`,
  and `ueberauth_apple` (last released 2023, now removed — see below) pinned
  `httpoison ~> 1.0 or ~> 2.0`. Verified safe to override: `ex_aws_sqs`
  never calls hackney directly (the pin is vestigial, only listed for its
  own `:test` env); `ex_aws` itself already relaxed to `hackney ~> 4.0,
  optional: true` as of 2.7.0 (our lock was just stale at 2.6.1); hackney
  4.0's release notes confirm the public `hackney:request/5` API is
  unchanged from 1.x (the major bump split HTTP/2 and HTTP/3 into separate
  libraries, `h2` and `quic`, and replaced the built-in metrics subsystem
  with a middleware chain); every real hackney consumer in the tree
  (`ex_aws`, `tesla`, `swoosh`) only touches that stable surface. Full
  investigation: `dev_docs/audits/2026-07-12-hackney-upgrade-resolution.md`
  (supersedes `2026-07-07-hackney-cve-2026-advisories-audit.md`).

### Removed
- **BREAKING: Apple Sign-In removed** (`ueberauth_apple` dependency
  dropped, along with its Settings UI, credential storage, and login/admin
  buttons). `ueberauth_apple` has been unmaintained since its 0.6.1 release
  in 2023 and was the sole reason httpoison — and therefore hackney — could
  not move past the versions above. Hosts with Apple Sign-In configured
  will see the "Apple Sign-In" toggle and credential fields disappear from
  Settings → Authorization; any users who previously linked an Apple
  account keep that link (existing `phoenix_kit_user_oauth_providers` rows
  are untouched and still shown/manageable in account settings), but new
  Apple sign-ins are no longer offered. Plan is to reintroduce this via a
  maintained fork of `ueberauth_apple` in a future release.

## 1.7.187 - 2026-07-12

### Fixed
- **`data-confirm` was silently swallowed on `BulkSelectScope` action buttons.**
  The hook's `_onActionClick` calls `e.preventDefault()` synchronously on
  every `data-bulk-action` click; `phoenix_html`'s own window-level click
  listener (which implements `data-confirm`) bails out early via `if
  (e.defaultPrevented) return;`, so its confirm dialog never fired. Any
  button carrying both `data-confirm` and `data-bulk-action` — most notably
  bulk/permanent delete — executed with no prompt. The hook now checks
  `data-confirm` itself and calls `window.confirm()` before proceeding,
  mirroring `phoenix_html`'s native behavior; cancelling stops the click
  and the LiveView event is never pushed. Found while migrating
  `phoenix_kit_comments`, `phoenix_kit_posts`, and `phoenix_kit_entities` to
  BulkSelect — all three already pair `data-confirm` with a destructive
  bulk action and are fixed retroactively once they pick up this release.

## 1.7.186 - 2026-07-12

### Fixed
- **The 1.7.185 `phoenix_kit.js` self-heal never ran on hosts whose
  `mix.exs` was missing the `:phoenix_kit_js_sources` compiler — exactly the
  older installs that need it most.** Root cause (found by a downstream
  agent bisecting a host stuck on stale JS after upgrading): registering
  `:phoenix_kit_css_sources` and `:phoenix_kit_js_sources` was two SEPARATE
  `Igniter.Project.MixProject.update/4` calls against the same `mix.exs`
  `:compilers` key. The first call, hitting an absent key, has to insert
  `[atom] ++ Mix.compilers()` — a `++` call, not a literal list, since
  `Mix.compilers()` is a live call that can't be flattened at install time.
  The second call then lands on that `++` node instead of a list, and
  `Igniter.Code.List.prepend_new_to_list/2` (which only understands literal
  lists) silently fails into a `{:warning, ...}` easy to miss in the wall of
  `mix phoenix_kit.update`/`install` output — so the second compiler never
  actually got registered even though the run reported success. This is
  exactly what happened in production: a host had `:phoenix_kit_css_sources`
  from the first call but never `:phoenix_kit_js_sources` from the second,
  across many `phoenix_kit.update` runs, so the JS-hooks compiler (and
  therefore 1.7.185's vendoring fix) never ran.
  `PhoenixKit.Install.Common.ensure_compilers_registered/2` now registers
  every PhoenixKit compiler in ONE call — used by both `mix
  phoenix_kit.install` and `mix phoenix_kit.update` — and, for hosts already
  stuck in the broken `[atom] ++ Mix.compilers()` shape, descends into the
  literal list on the left of `++` and repairs it there instead of bailing.
  Covered by a regression test that reproduces the exact broken shape and
  asserts both compilers end up present, not just the notice claiming they
  do.

## 1.7.185 - 2026-07-11

### Fixed
- **`phoenix_kit.js` (core JS hooks — `RowMenu`, drawer/modal toggles, etc.)
  could silently 404 in production, breaking every PhoenixKit JS hook with no
  error anywhere.** It was only ever copied into a host's
  `priv/static/assets/vendor/` by the one-shot `File.cp/2` in `mix
  phoenix_kit.install`/`mix phoenix_kit.update` — a deploy that does `rm -rf
  priv/static` + asset rebuild without re-running `phoenix_kit.update` (true
  of most CI/CD pipelines) shipped the stale or missing file, so a bug fix
  landing in this same JS file could ship correctly in every other respect
  (compiled `.ex`/`.heex` changes apply the moment the dependency bumps) while
  the JS fix itself never reached the browser. The `:phoenix_kit_js_sources`
  compiler — which already regenerated `phoenix_kit_modules.js` (the
  external-module hook bundle) on every `mix compile` — now also vendors
  `phoenix_kit.js` itself the same way: self-healing after any `priv/static`
  wipe, with zero dependency on `phoenix_kit.update` ever running again after
  the initial install.
- **`JsIntegration.update_js_file/0` swallowed copy failures** (`rescue` →
  `Logger.warning` → `{:error, reason}` that its one caller, `mix
  phoenix_kit.update`, never checked) — `mix phoenix_kit.update` could report
  success while the vendored file silently stayed stale or absent. Now raises
  (`Mix.raise/1`) on a resolution/copy failure and verifies the destination
  file exists and is non-empty as a post-condition. `mix
  phoenix_kit.assets.rebuild` — billed as *the* asset-rebuild task — now also
  refreshes `phoenix_kit.js` via the same path, not just the CSS pipeline.

## 1.7.184 - 2026-07-11

### Added
- **`Checkbox` core component extended** (`PhoenixKitWeb.Components.Core.Checkbox`):
  `disabled` (previously silently dropped — not in the allowed globals),
  `wrapper_class` (styles the wrapping `<label>` — spacing, or
  `pointer-events-none` to lock a checkbox *without* excluding it from form
  submission the way `disabled` would), `title` (tooltip on the whole label,
  not just the box), and a `:description` slot for secondary helper text. The
  default slot now doubles as rich label content (badges, icons, conditional
  markup) overriding the plain `label` string when given.
- **`LayoutWrapper.app_layout` gains `page_section`/`page_section_path`** —
  an optional breadcrumb segment between "Admin Panel" and `page_title` (e.g.
  "Admin Panel / Users / Jane Doe" on a user detail page instead of jumping
  straight from "Admin Panel" to the user's name).

### Changed
- **Checkboxes across core migrated to `<.checkbox>`** (settings pages,
  registration/OAuth toggles, storage bucket/dimension forms, org tax
  toggle, `user_form`'s boolean custom field) so future daisyUI syntax or
  style changes are a one-file edit instead of a repo-wide sweep. Left
  hand-rolled where the shape doesn't fit a boolean toggle (role-assignment
  checkboxes and the image-format multi-select use `value={item}` collected
  via `Map.values/1`, not the hidden-false/checkbox-true pattern).
- **Users list/detail naming unified.** The admin page title now reads
  `@page_title` ("Users") instead of a hardcoded "User Management" that had
  drifted out of sync with it; the sidebar subtab is "Users" instead of
  "Manage Users".
- **User detail page now offers the same actions as the Users list's `⋮`
  menu** — Roles, Confirm/Unconfirm email, Activate/Deactivate, and (for your
  own profile) Settings, via the same `table_row_menu` component and
  `Auth`/`Roles` context calls. Delete is now hidden (not just rejected on
  click) when `Auth.can_delete_user?/2` says no, matching the list.
- **Users list's Location column explains itself when empty.** If
  `track_registration_geolocation` is off, every row now says "Tracking
  disabled" with a link to Settings → Users, instead of an unexplained
  per-row "No data" that looked like missing data rather than a disabled
  feature.

### Fixed
- **Row-action `⋮` menus could silently eat clicks on menu items (WebKit —
  i.e. every browser on iOS/iPadOS, plus desktop Safari).** The `RowMenu` JS
  hook portals its floating menu to `<body>` while open so it can escape a
  clipped table container; its "click outside closes the menu" listener only
  checked containment against the trigger's wrapper, not the (now
  elsewhere-in-the-DOM) menu itself. Clicking a menu item was treated as an
  outside click: the capture-phase listener closed and relocated the menu
  mid-dispatch, and WebKit drops an in-flight click when its target moves
  during capture — so the tapped action never ran. Fixed by also checking
  containment against the portaled menu.
- **Checkboxes with hidden-false-fallback markup weren't wrapped in a
  `<label>`** across settings pages (registration, notifications,
  multi-session, magic link, OAuth master/provider switches, storage bucket
  enable, org tax enable), so clicking the adjacent text did nothing —
  only the checkbox square itself was clickable. For the OAuth provider
  switches specifically (locked via `pointer-events-none` while the master
  switch is off), the lock moved from the checkbox to the wrapping label so
  wrapping it in `<label>` couldn't let a text click bypass the lock.

## 1.7.183 - 2026-07-11

### Fixed
- **Prefixed (`--prefix`) installs could fail to migrate.** `CREATE INDEX` was
  being called with a schema-qualified index name (`CREATE INDEX prefix.name ON
  ...`), which Postgres rejects outright — an index always lands in its table's
  schema, so only the table reference may be qualified. Affected
  `add_uuid_unique_indexes`/`drop_uuid_unique_indexes` (`uuid_fk_columns.ex`),
  `V56`, `V57`, and `V95`'s media-folder unique index. (#628)
- **Cross-schema false-positive existence checks on prefixed installs.** Several
  idempotency guards (`pg_constraint` lookups in `V35`, `V102`, `V113`, `V115`,
  `V118`, `V119`; an `information_schema.columns` lookup in `V95`) matched on
  constraint/column name alone, so an identically-named constraint or column
  already present in a *different* schema's table made the guard think it existed
  in the current schema too — silently skipping the `ADD CONSTRAINT`/`ADD COLUMN`.
  Fixed by anchoring each check to the target relation (`conrelid = '<prefix>.
  <table>'::regclass` / `table_schema = '<prefix>'`). Added an integration test
  that runs the full versioned migration chain into a named schema and asserts
  every index and column lands correctly. (#628)

## 1.7.182 - 2026-07-10

### Added
- **Fine-grained sub-permissions.** Modules can declare additive permissions under
  their base key via the optional `sub_permissions` field of `permission_metadata/0`
  (e.g. `"calendar.view_others"`), stored in `phoenix_kit_role_permissions.module_key`
  as composed dotted keys. A sub-permission implies its base: granting a sub
  auto-grants the base, revoking the base cascades its subs off, and every write
  path (`grant_permission/3`, `revoke_permission/3`, `set_permissions/3`) normalizes
  the set so no orphan sub-key row can persist. Modules check sub-grants with
  `Scope.can?/2` (key held **and** module enabled). The permission matrix renders
  subs as indented rows under their module. (#627)
- **`V141` — personal calendar events + participants** for the standalone
  `phoenix_kit_calendar` module: `phoenix_kit_calendar_events` (one implicit
  personal calendar per user, timed/all-day exclusive-end pairs with a CHECK,
  cascade on user delete, loose `location_uuid` link) and
  `phoenix_kit_calendar_event_participants` (loose `kind`/`target_uuid` refs with a
  snapshotted `display_name`, visibility resolved live against staff/CRM tables). (#627)
- **Reusable core UI components.** `SearchPicker` (client-instant typeahead with
  browse-on-focus, per-instance event scoping, `direction=up`, cross-source dedup,
  load-more paging), `PopoverPanel` (anchored rich-content popover, client-side
  open/close with click-away), and the `PkDialogDraft` JS hook (preserves an open
  form's draft across a LiveView reconnect). Both function components are imported
  into `PhoenixKitWeb`. (#627)

### Changed
- **Admin is now genuinely permission-gated.** Only `Owner` is hard-coded as
  all-access; `Admin` (and every other role) is governed by the permission matrix.
  Admin defaults to all keys via seeding/auto-grant, and a boot-time Task
  (`auto_grant_new_keys_to_admin/0`) fills newly-installed module keys — but an
  Owner's revocation now sticks everywhere, including fresh mounts (previously the
  system-role bypass ignored revocations on fresh mounts). The full-access fallback
  keys on **table presence** (`permissions_table_ready?/0`), not row count, so
  stripping a role bare can no longer restore access, and a DB blip fails closed. (#627)
- **`V142`** widens `phoenix_kit_role_permissions.module_key` `VARCHAR(50) → VARCHAR(120)`
  so composed sub-permission keys fit. (#627)
- **Role changes are authorized in the context.** `sync_user_roles/3` takes an
  `:actor` and drops changes the actor isn't allowed to make (a non-Owner can't
  grant or strip Owner/Admin); the last Owner can never be removed. The quick
  role-toggle and the permission-matrix revoke route through the same guards. The
  function now returns `{:ok, %{assignments, roles_before, roles_after}}` so audit
  logs record the delta **actually applied**, not the submitted set. (#627)
- **`Checkbox` `checked` default is now `nil`** ("derive from the field's value") —
  a non-nil attr default defeated the field clause's `assign_new`, so a field-bound
  checkbox always rendered unchecked. (#627)
- **`AdminPageHeader` accepts a `class`** to override its default bottom margin
  (e.g. `"mb-0"` when the page owns spacing). (#627)

### Fixed
- **Role/permission mutations are race-free under concurrent admins.**
  Transaction-scoped Postgres advisory locks + in-transaction re-reads: the last
  Owner can never reach zero (shared lock at `count_remaining_owners`), the matrix
  revoke re-reads the role's held keys under a `(role, base)` lock and rejects
  (`:unauthorized`) if a cascaded sub falls outside the actor's grantable set, and
  `set_permissions/3` locks the `Role` row so two concurrent calls can't leave the
  union of disjoint desired sets. (#627)
- **Post-merge review:** refactored `grant_permission/3` to satisfy
  `credo --strict` (removed a redundant `with` clause and one nesting level) — the
  base-then-sub cascade and rollback behavior are unchanged. (#627)

## 1.7.181 - 2026-07-10

### Changed
- **Admin settings pages modernized.** Replaced ad-hoc `<div class="divider">`
  headings across the General, Authorization, Users, Media, and Instance
  Dimensions pages with a reusable `<.section_header>` (icon + uppercase title +
  rule + optional actions slot). Per-field status echoes ("Selected: X | Saved:
  Y", always visible) are replaced by `<.unsaved_hint>`, which renders only when a
  field diverges from its saved value, so clean fields carry no noise. The four
  hand-copied ~95-line OAuth provider guides (Google/Apple/GitHub/Facebook)
  collapse into one `<.oauth_setup_instructions>` component with a `:steps` slot.
  Both new components live in `Components.Core.FormSection`. (#626)
- **Browser Tab identity group + live preview.** The site-icon and default-tab-
  title fields are merged into one "Browser Tab" group on the General page, with a
  live browser-chrome preview (icon + tab title + address bar) that updates as you
  type. The site icon and project logo now default to each other via
  `Settings.get_site_icon_uuid/0` and `get_logo_uuid/0` — setting either brands
  both the browser tab and the app chrome; the favicon and layout wrappers read
  through these resolvers. (#626)
- **Destructive resets now confirm.** The General "Reset ALL settings" and Instance
  Dimensions "Reset to Defaults" actions gained a `data-confirm` guard. (#626)
- **Dependency bump.** `saxy` 1.6.0 → 1.6.1.

### Fixed
- **Registration dirty-indicator missed two toggles.** The Users-page unsaved-
  changes hint for the registration group compared only `allow_registration` and
  `track_registration_geolocation`, so flipping `registration_show_username` or
  `enable_organization_accounts` left the group looking clean. It now checks all
  four keys. (#626)

### i18n
- **Storage-module flashes and page titles localized.** Every `put_flash` in the
  Media settings and Instance Dimensions LiveViews (bucket toggles, redundancy,
  variants, repair, dimension CRUD/reset) is wrapped in `gettext`/`ngettext` with
  proper `%{}` interpolation and correct pluralization for the redundancy-copies
  message. Full `.pot` re-extract with ru/et translations for all new strings.
  Also dropped a dead drag-drop `<script>`/`<style>` block from the Media settings
  template (targeted element ids that no longer exist). (#626)

## 1.7.180 - 2026-07-09

### Added
- **V140 migration: `phoenix_kit_warehouse` tables.** Creates the six tables backing
  the standalone `phoenix_kit_warehouse` package — `phoenix_kit_warehouse_stock`,
  `_inventory_documents`, `_internal_orders`, `_supplier_orders`, `_goods_receipts`,
  `_goods_issues`. Intra-module FKs are kept (`supplier_orders.internal_order_uuid` →
  `internal_orders`, `goods_receipts.supplier_order_uuid` → `supplier_orders`,
  `goods_issues.internal_order_uuid` → `internal_orders`), as is
  `performed_by_uuid` → `phoenix_kit_users`. The host-specific `sub_order_uuid` FK is
  replaced by a generic `source_refs` JSONB column resolved through a host-registered
  callback, so the package depends on no particular "order" concept. Tables ship
  empty — nothing reads or writes them yet. (#624)

### Fixed
- **V140 `quantity >= 0` check was silently skipped on non-`public` schemas.** The
  constraint-existence guard matched `pg_constraint.conname` alone, but constraint
  names are unique per `(schema, table)` — not globally. A second PhoenixKit install
  into another schema in the same database found the first schema's constraint, took
  the `IF NOT EXISTS` false branch, and created `phoenix_kit_warehouse_stock` with no
  non-negative-quantity check while reporting success. Now scoped with
  `AND conrelid = '<prefixed table>'::regclass`, matching V41/V72/V78.
  (post-merge review)
- **V140 `source_refs` reverse lookups were unindexed.** Dropping the indexed
  `sub_order_uuid` FK column in favour of JSONB removed the index behind "which
  documents reference this order?", turning it into a sequential scan. Added
  `USING GIN (source_refs)` on `internal_orders`, `supplier_orders`,
  `goods_receipts`, and `goods_issues`. (post-merge review)
- **V140 `phoenix_kit_warehouse_stock` could not be queried by location.** Its only
  index was `UNIQUE (item_uuid, location_uuid)`, which a composite btree cannot serve
  for a bare `WHERE location_uuid = $1` — the most natural query against a stock
  table, and one every other warehouse table already had an index for. Added
  `phoenix_kit_warehouse_stock_location_uuid_index`. (post-merge review)

### Changed
- **V140 moduledoc corrected.** It justified `item_uuid` / `location_uuid` /
  `storage_folder_uuid` / `supplier_uuid` as FK-less "cross-package references", but
  all four targets (`phoenix_kit_cat_items`, `phoenix_kit_locations`,
  `phoenix_kit_media_folders`, `phoenix_kit_cat_suppliers`) are created by this same
  core migration set — V122 already declares an FK on `location_uuid`. The doc now
  states the truth: an FK is possible, it is omitted pending a delete-semantics
  decision, and referential integrity for those columns is not enforced by the
  database. Also genericised the private downstream app's table names, which were
  rendering on hexdocs. (post-merge review)
- **Dependency bumps.** `ecto` 3.14.0 → 3.14.1, `postgrex` 0.22.2 → 0.22.3,
  `plug` 1.20.2 → 1.20.3, `mdex_native` 0.2.4 → 0.2.5.

## 1.7.179 - 2026-07-08

### Added
- **V139 migration: per-dashboard `config` column.** Adds a JSONB `config` column
  (`NOT NULL DEFAULT '{}'`) to `phoenix_kit_dashboards` for dashboard-level
  presentation state (layout mode, pixel-mode zoom, home tier, per-tier markers),
  read and written whole like `layout`. Idempotent (`ADD COLUMN IF NOT EXISTS`);
  unblocks the dashboards module's next Hex floor. (#623)
- **Installer wires a `viewport_width` LiveSocket connect param.**
  `mix phoenix_kit.install` / `mix phoenix_kit.update` now add
  `viewport_width: window.innerWidth` to the host's LiveSocket `params:` (rewritten
  into a closure so reconnects re-read the width). Responsive PhoenixKit LiveViews
  (e.g. the dashboards builder) use it to resolve the right layout tier server-side
  on the first render instead of a client-hook round-trip; everything degrades
  gracefully without it. The rewrite is deliberately conservative — it anchors on
  the real `new LiveSocket(` call, only patches a `params:` object at the options'
  top brace depth, blanks string literals and comments before depth counting, and
  refuses every ambiguous shape with a manual-instructions notice rather than risk
  corrupting host `app.js`. Pinned by 13 tests in `js_integration_test.exs`. (#623)

### Fixed
- **daisyUI 5.0.x modal scrollbar-gutter strip.** daisyUI 5.0.x reserves a scrollbar
  gutter while a modal/drawer is open and paints it with a base-100 trick that
  mismatches on non-base-100 pages, so classic-scrollbar users saw an uncovered strip
  at the window's right edge on every admin page. An unlayered
  `:root:has(.modal-open, …) { scrollbar-gutter: auto }` counter-rule in the admin
  `LayoutWrapper` and the core root layout beats the layered original regardless of
  stylesheet order. Documented trade-off: scrollable pages get a small reflow on
  modal open instead of the mispainted strip. Upstream fixed this properly in daisyUI
  5.1.0–5.6.x; an `AGENTS.md` TODO tracks removing the rule once hosts upgrade. (#623)

### Changed
- **Migration-history doc block tracks V139.** `Migrations.Postgres`'s version list
  now carries the `### V139` entry and the `⚡ LATEST` marker, which the merge left
  pointing at V138. (post-merge review)

## 1.7.178 - 2026-07-07

### Added
- **Extensible resource deep-links across the activity feed and notifications.**
  External modules can declare how their resource types link to their pages via the
  new optional `resource_links/0` `PhoenixKit.Module` callback — a
  `resource_type => resolver` map where a resolver is a module implementing
  `resolve_comment_resources/1`, a path-template string (`"/admin/widgets/:uuid"`),
  or a `%{"path" => ..., "title" => ...}` map. Merged into `PhoenixKit.ResourceLinks`
  with a documented precedence (resolver module → module template → host
  `comment_resource_paths` setting). (#621)
- **Integration activities deep-link to their Settings edit page.**
  `Integrations.log_activity` now stamps the connection's storage-row `resource_uuid`,
  and the new `PhoenixKit.Integrations.ResourceLinks` resolves `"integration"`
  resources to `/admin/settings/integrations/:uuid`, titled `provider / name`. (#621)
- **Actor and target identities are now clickable in the activity feed and the
  notifications admin list.** A lightweight `resource_email_link/1` component links
  the who-did-it / who-it's-for emails to those users' admin pages, falling back to
  plain text when unresolved. (#621)
- **"All notifications" overview on the Notifications admin page.** A paginated table
  (via `Notifications.admin_list/1`) shows every notification's recipient, rendered
  text, per-user seen/dismissed state, and date. (#621)

### Fixed
- **Jobs admin scheduled-jobs tab no longer crashes.** The template referenced
  `job.id` / `job.resource_id`, which do not exist on the
  `PhoenixKit.ScheduledJobs.ScheduledJob` schema (`@primary_key {:uuid, ...}`,
  `field :resource_uuid`) — every render raised `KeyError`. Now uses `job.uuid` /
  `job.resource_uuid`, consistent with the `repo.get(ScheduledJob, uuid)` lookup. (#622)
- **Notifications admin pagination no longer renders a runaway button list** for an
  out-of-range `?page=` query param. An explicit `//1` range step makes an
  out-of-range page yield an empty range instead of a descending one. (post-merge review)

### Security
- **hackney 1.25.0 advisory batch (EEF-CVE-2026-47069 / 47071 / 47075 / 47076)
  reviewed and accepted — no code change.** There is no fixed hackney 1.x; the fix
  lives only in hackney 4.x, which the dependency tree cannot reach while
  `ueberauth_apple` pins `httpoison < 3.0` (→ `hackney < 2.0`). Real-world exposure is
  low: hackney is only the default HTTP backend for `ex_aws` and the Apple-OAuth path
  (fixed endpoints, no SOCKS5, no user-controlled URLs/cookies/query strings). Full
  analysis and the eventual upgrade trigger:
  `dev_docs/audits/2026-07-07-hackney-cve-2026-advisories-audit.md`.

## 1.7.177 - 2026-07-07

### Changed
- **Auth form fields now render their leading icon *inside* the input.** The
  email/username/password/organization-name fields on the registration, login,
  and magic-link forms previously showed their icon in a separate label above
  the field; they now follow daisyUI 5's `<label class="input">` wrapper pattern
  so the icon sits inside the field border (text labels are retained above). The
  shared `PhoenixKitWeb.Components.Core.Input` `:icon` slot renders inside the
  field accordingly. The organization account-type `<select>`'s label icon was
  dropped for consistency (daisyUI has no icon-inside variant for selects).
- **Updated phoenix to 1.8.9, phoenix_live_view to 1.2.6, websock_adapter to
  0.6.0, and ex_ast to 0.12.9.**

### Fixed
- **The `auth_seo_no_index` regression test no longer raises at mount and breaks
  `mix test`.** Its stand-in `PublicHostAppLive` mounted through
  `:phoenix_kit_mount_current_scope`, whose `handle_params` hook needs a non-nil
  `socket.router` — which `live_isolated/3` never provides. The test now drives a
  routed, test-only LiveView (`PhoenixKitWeb.Test.PublicHostAppLive`, routed only
  under `Mix.env() == :test`) via a real HTTP request, and asserts against the
  actual rendered `noindex`/`nofollow` meta tags a crawler would see rather than
  the raw `:seo_no_index` assign. (#620)

## 1.7.176 - 2026-07-06

### Added
- **Activity feed entries now deep-link to the resource they acted on.** A new
  shared `PhoenixKit.ResourceLinks` resolver turns an entry's
  `(resource_type, resource_uuid)` into a navigable link to the underlying
  record, reusing the comments-moderation two-tier mechanism (auto-registered
  handler modules for `post`/`file`/`user`, then `comment_resource_paths` string
  templates). A core `<.resource_link>` chip renders the resolved title with a
  thumbnail or type icon on both the Activity index Subject cell and the detail
  page, falling back to the resolved user email and then a truncated uuid.
  Resolution is batched per resource type and fails open to the uuid fallback,
  so a missing or throwing handler never crashes the admin feed. (#619)
- **Image rotation in the media viewer is now persisted.** Rotating an image in
  the admin media viewer saves the angle to the file row's `metadata["rotation"]`
  and restores it on the next open, via fresco 0.8's opt-in `persist_rotation`
  server bridge. Every viewer (including public galleries) seeds the saved
  orientation on first paint, but only admin-context hosts — the `MediaBrowser`
  modal (gated on `@admin`) and the admin-only media-detail page — write back to
  the shared file row. (#618)

### Changed
- **Updated fresco to 0.8.0, etcher to 0.7.2, tessera to 0.3.2.** fresco 0.8's
  new `persist_rotation` bridge backs the media-viewer rotation persistence
  above.

## 1.7.175 - 2026-07-06

### Added
- **Sitemap settings page now exposes Router Discovery exclude patterns,
  protected pipelines, custom URLs, and static routes.** These four settings
  (`sitemap_router_discovery_exclude_patterns`, `sitemap_protected_pipelines`,
  `sitemap_custom_urls`, `sitemap_static_routes`) previously had no admin UI —
  changing them required editing the database directly. They're now editable
  from a new "Advanced" section on `/admin/settings/sitemap`, with the
  exclude-patterns field validated against `Regex.compile/1` before saving
  (an invalid pattern is rejected with an inline error instead of being
  silently dropped later) and pipeline names restricted to identifier-safe
  characters.
- **Sitemap sources can now declare their own settings via
  `PhoenixKit.Modules.Sitemap.Sources.Source.sitemap_settings_schema/0`.**
  This new optional callback lets a source module (built-in or contributed by
  another package, e.g. an Entities module) describe boolean/string/integer
  settings with a label, help text, and default; the sitemap settings page
  discovers and renders them automatically, reading/writing through
  `PhoenixKit.Settings` the same way built-in settings work. No core source
  implements it yet — this is purely an extension point for
  settings that don't already have a home in the core UI.

### Fixed
- **Toggling a source-contributed boolean setting no longer crashes the sitemap
  settings page when the field declares a non-boolean default.** The extension
  toggle handler now reads the current value through the same rescue-protected
  path the render uses, so a source that declares `%{type: :boolean, default: nil}`
  (allowed by the `term()` default type) can't raise `FunctionClauseError` from
  `Settings.get_boolean_setting/2`'s `is_boolean/1` guard on click.

## 1.7.174 - 2026-07-05

### Fixed
- **Host layouts are no longer double-wrapped, and both `{@inner_content}` and
  `render_slot(@inner_block)` work.** PhoenixKit LiveViews used to set their
  native Phoenix `:layout` to the host's configured `config :phoenix_kit, layout:`
  — but every page *also* applies that same host layout itself via
  `LayoutWrapper.app_layout` in its render. So a host layout with visible chrome
  rendered twice (doubled header / nav / footer, body singular), and a host layout
  written in the Phoenix 1.8 idiom (`slot :inner_block` + `render_slot(@inner_block)`)
  crashed with `KeyError: key :inner_block not found` because Phoenix invokes a
  `:layout` with `@inner_content` only.

  The native `:layout` is now a pure passthrough (`PhoenixKitWeb.Layouts.app`,
  which renders only `{@inner_content}`), making `app_layout` the **single owner**
  of the host layout — applied exactly once. `app_layout` hands the host layout
  both a real `inner_block` slot and a lazily-derived `@inner_content`, so a host
  layout renders correctly whether it uses `{@inner_content}` (the documented
  contract) or `render_slot(@inner_block)`. A misconfigured layout function falls
  back to PhoenixKit's own layout instead of 500-ing every page.

  Hosts that previously worked around the double-wrap (e.g. detecting slot vs.
  `@inner_content` in their own layout) can drop that workaround.

## 1.7.173 - 2026-07-05

### Changed
- **DaisyUI theme names are now translatable.** `ThemeConfig`'s `@labels` map
  (System, Light, Dark, and 34 other theme names) was hardcoded without gettext
  wrapping, so it rendered in English regardless of locale. Adds
  `translated_label/1` and `translated_label_map/0`; the theme-switcher dropdown
  and the layout wrapper's client-side JS label map now use them.
- **User dashboard nav gains an `:authenticated_links` attribute.**
  `PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1` now accepts
  `authenticated_links` (default `[:admin, :dashboard, :settings, :logout]`),
  mirroring the existing `:guest_links` narrowing. Lets a host app hide menu
  entries its own navigation already covers (e.g. `:dashboard`). Narrowing-only:
  `:admin` still requires `Scope.admin?/1`, so it can never grant access.
- **Dependency bumps:** `ex_ast` 0.12.5 → 0.12.7, `mdex` 0.13.2 → 0.13.3,
  `mdex_native` 0.2.3 → 0.2.4, `swoosh` 1.26.2 → 1.26.3 (lockfile).

### Fixed
- **V80 migration could corrupt email-template data on a retried multi-version
  run.** V80 was the only version module that never recorded its own
  `COMMENT ON TABLE phoenix_kit IS '80'` checkpoint. Because update migrations
  run with `@disable_ddl_transaction` (each step auto-commits individually), a
  failure in a later version would cause a subsequent `mix ecto.migrate` to
  resume from V80 and re-run its `ALTER COLUMN ... TYPE jsonb USING
  jsonb_build_object('en', ...)` against already-converted columns,
  double-wrapping the values (`{"en": {"en": "..."}}`). V80 now writes its
  checkpoint like every other version and guards the conversion on the column's
  current type so it's idempotent. (#612)

### i18n
- **French UI strings translated.** French was ~5% translated (1688 of 1776
  msgids blank in `default.po`, all 8 blank in `phoenix_kit.po`) despite most
  strings being reachable from public-facing pages (theme switcher, "Log in",
  etc.). All ~1782 blank entries across `default.po` / `phoenix_kit.po` /
  `errors.po` are now translated to idiomatic French (formal register, plural
  forms per entry).
- Localized three previously-hardcoded labels in the user dashboard nav
  ("Dashboard", "Settings", "Log Out") via `gettext/1`, matching the rest of the
  component; new msgids extracted across all locale catalogs.

### Internal
- Ignore a `Gettext.Backend`-generated `call_without_opaque` Dialyzer false
  positive (Expo's opaque `PluralForms` struct passed into
  `Gettext.Plural.plural/2`) so `mix precommit` passes on Erlang 28 / Elixir
  1.19. Already on the latest `gettext` 1.0.2 / `expo` 1.1.1; no user code is
  involved.

## 1.7.172 - 2026-07-03

### Changed
- Added the `rustler` dependency as optional (lockfile). `mdex_native` builds
  from source (instead of downloading a precompiled NIF) when
  `MDEX_NATIVE_BUILD=1` is set in the environment; that path requires rustler
  itself, not just `rustler_precompiled`.

### Fixed
- **Gettext locale falling back to default on publishing content routes.**
  `process_locale/1` only matched `path_params["locale"]`, but the internal
  routes `phoenix_kit_publishing` generates for localized content
  (`get "/:language/:group"`) bind the segment as `"language"` instead. The
  mismatch meant `Gettext.put_locale/1` was never called on those requests, so
  translations silently rendered in the site default locale regardless of the
  URL prefix (e.g. `/en/articles` rendering Russian nav text).

## 1.7.171 - 2026-07-03

### Changed
- **`RouterDiscovery` sitemap source compiles exclude/include-only patterns
  once per collection instead of once per route per pattern.** Same behavior,
  fewer `Regex.compile/1` calls; invalid patterns (e.g. a bare `"*"`, which is
  not a valid regex) are now logged instead of silently swallowed. Two more
  default excludes: `^/__` (internal/technical routes, e.g. Publishing's
  dispatch catch-all scope) and `^/maintenance$` (PhoenixKit's reserved
  maintenance page) — both mainly load-bearing for installs with a non-default
  `url_prefix`. (#614, #615)
- **New optional `reserved_route_prefixes/0` module callback** +
  `PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0`. Lets a module
  declare top-level route path segments it owns (e.g. `["legal"]`), so a
  database-driven dispatcher (e.g. Publishing's `/:language/:group/*path`
  catch-all) can avoid swallowing another module's route just because a
  same-named record happens to exist in its own data. Iterates all installed
  modules (not just enabled ones), since the guarded route is normally
  compiled into the host router independent of the module's runtime
  enabled/disabled toggle. Declaring a prefix is passive on its own — it
  changes nothing until a dispatcher consults it. (#614)
- Bumped `phoenix_live_view` 1.2.4 → 1.2.5, `plug` 1.20.1 → 1.20.2, `makeup`
  1.2.1 → 1.2.2 (lockfile).

### Fixed
- **V70 migration crash on installs missing the legacy `email_log_id` /
  `matched_email_log_id` integer FK columns.** The re-backfill guards checked
  that the UUID companion columns existed but not the legacy integer columns
  the raw SQL actually joins on, so an install where those legacy columns were
  already dropped hit an `undefined column` error. (#613)
- **Sitemap no longer advertises URLs while the SEO module's `noindex`
  directive is active.** `/sitemap.xml` (XML and HTML) now publishes an empty
  but schema-valid `<urlset>` instead of the full URL list whenever
  `seo_no_index` is enabled, and toggling the directive invalidates + triggers
  regeneration of the cached sitemap so it doesn't keep serving a stale file.
  (#614)
- **Sitemap `RouterDiscovery` no longer masks richer entries from other
  sources.** `RouterDiscovery` enumerates every GET route generically; when a
  content source (Publishing, Entities, …) emitted a richer entry (priority,
  `canonical_path`, hreflang alternates) for the same URL, the old
  `loc`-based dedup kept whichever entry was listed first — always the
  generic `RouterDiscovery` one — silently dropping priority and hreflang
  alternates from the sitemap. Dedup now always prefers the richer,
  non-`RouterDiscovery` entry regardless of source order. (#615)
- **`seo_no_index` now reaches a host application's own public LiveViews.**
  Previously only `LayoutWrapper.app_layout_inner/1` (PhoenixKit's own
  admin/plugin views) set the `:seo_no_index` assign that `root.html.heex`
  reads for the `noindex,nofollow` meta tags, so a host app's own public
  LiveView — mounted through PhoenixKit's `on_mount` chain for
  `current_user`/locale support but rendered with its own layout — never got
  the directive even with it enabled. The assign is now set from the
  `handle_params` hook shared by every PhoenixKit `on_mount` variant. (#616)

## 1.7.170 - 2026-06-29

### Added
- **Audio playback in the media viewer.** Opening an audio file (in the in-place
  modal or `/admin/media/:uuid`) now renders an interactive WaveSurfer waveform
  with a play/pause button and click-to-seek instead of a document placeholder.
  WaveSurfer is lazy-loaded via a dynamic CDN import only when audio is opened (no
  npm/hex dependency, no cost on other pages); the hidden native `<audio>` is the
  playback source and the fallback (native controls) if the library can't load.
  Audio is detected by mime, `file_type`, **or** extension, so mp3s stored with a
  generic `application/octet-stream` mime are still recognised. Grid, list, and
  stack views show a music-note icon and an "AUDIO" label. (#611)

### Changed
- **Folder sidebar handles deep names.** Deeply nested folders keep their full
  names and the tree scrolls horizontally instead of truncating to a few
  characters; the root→current active path is drawn bolder (4px, was 2px) and
  centred on the axis so the branch you're on stands out. (#611)

### Fixed
- **Media browser display dropdown label.** The display dropdown now reads
  "Stacks" in Stacks mode (was stuck on "Grid"), driven by a lookup over the view
  options instead of a two-way grid/list assumption. (#611)
- **Notifications dropdown overflow.** A tall notifications list now scrolls
  vertically instead of wrapping into extra columns — daisyUI `menu`'s
  `flex-wrap: wrap` is replaced with a plain `flex flex-col flex-nowrap` list. (#611)
- **Users table actions menu.** The `…` actions menu is pinned to the far-right
  edge so it no longer drifts into a wide auto-width cell when columns are
  hidden. (#611)
- **Account switcher overflow.** Long emails are truncated (with a hover tooltip)
  and the role badge is pinned, fixing horizontal overflow in the user
  dropdown. (#611)

## 1.7.169 - 2026-06-28

### Added
- **V138 migration — CRM v1 interaction-tracker tables.** Five `phoenix_kit_crm_*`
  tables laying down the CRM module's first data model: `contacts` (profile with an
  **optional** `user_uuid` login link, partial-unique so it's 1:1 only among linked
  rows), `companies`, `company_memberships` (M:N contact↔company with free-form
  `role_in_company` + `department` + `is_primary` on the edge), `interactions`
  (logged interaction: type/when/subject/body + subject contact + owner user), and
  `interaction_parties` (flat resolvable "who was involved" — `raw_name` always
  kept, `contact_uuid`/`staff_person_uuid` resolve under an exclusive-arc CHECK,
  `party_snapshot` JSONB freezes the party's profile as-of-then). `staff_person_uuid`
  is a soft ref (no FK) so the optional staff module stays optional. Migration-only;
  idempotent up/down. (#610)
- **Optional description slot on `Core.Checkbox`.** Passing an inner block renders a
  muted helper line under the now-bold label and switches the row to top alignment;
  with no slot the checkbox renders exactly as before. (#610)

### Fixed
- **`delete_folder_completely` no longer destroys a file shared into a folder
  outside the deleted subtree.** A file also linked (via `FolderLink`) into an
  external folder is now re-homed there — consuming that link — instead of being
  hard-deleted, which previously cascaded the file's external links away and
  silently stripped it from the unrelated folder. Files confined to the subtree are
  still permanently deleted. Covered by two new integration tests. (#610)

## 1.7.168 - 2026-06-27

### Changed
- **Sharper non-full-res thumbnails for grid/stack media cards.** Added a `:card`
  size mode to `MediaThumbnail` and switched the grid card, stack card, and
  stacks-view grid card to it. Cards now prefer the 400px baked Etcher thumbnail /
  300px `small` variant instead of the blurry 150px `thumbnail`, so media piles
  render crisply at 2× DPI. (#609)

### Fixed
- **`:card` thumbnails no longer load a full-res `original` when intermediate
  variants are missing.** A file with a `thumbnail` but no `small`/`medium` (partial
  variant generation, legacy upload, or admin-disabled dimensions) now falls back
  to the light 150px `thumbnail` before the multi-megabyte `original` — keeping the
  card payload light as intended. Reconciled the `MediaThumbnail` moduledoc and
  `attr` docs with the actual `:card` priority chain. (#609 follow-up)
- Added pure-function unit tests for `MediaThumbnail.resolve_url/2` covering every
  size mode and the `:card` fallback chain.

## 1.7.167 - 2026-06-26

### Added
- **Basecamp-style "stacks" view for the MediaBrowser.** A third view mode
  (alongside grid/list) renders top-level folders as photo "piles" with loose
  files under "Everything else". Clicking a pile opens its grid inline (multiple
  open at once, newest on top) with a FLIP fly-out/fly-back animation that fires
  only on explicit open/close — restores on refresh/navigate-back are instant and
  flash-free (`prefers-reduced-motion` respected). Open stacks persist across
  refresh/navigation in `localStorage` (`StackMemory` hook), scoped per
  virtual-root. Each stack paginates independently (`load_more_stack`, one page at
  a time) so a folder with thousands of files stays fast, and supports drag-drop
  of media between stacks / "Everything else" with the drop outline tinted to the
  folder's own colour. Per-file kebab menu (Download / Move / Trash) on stack
  cards mirrors grid view. (#608)
- **`ViewportPopover` JS hook.** Clamps the folder Edit-header popover to the
  viewport (flips it to open upward when there's more room above, pins Save/Done
  as a non-scrolling footer), so Save stays reachable when the browser is embedded
  low in a page. (#608)

### Changed
- Bumped the `:ex_ast` dependency 0.12.0 → 0.12.1 (lockfile).

### Fixed
- **`Created by %{name}` ru/et translation.** The folder-header creator label was
  added to the Estonian/Russian catalogs as a `fuzzy` auto-fill that both
  mistranslated it ("Create" imperative) and dropped the `%{name}` placeholder —
  inert today (gettext falls back to English for fuzzy entries) but a latent
  landmine if the flag were ever cleared. Corrected to `Создал %{name}` /
  `Loonud %{name}` and de-fuzzed so the proper translation is active.

### i18n
- Estonian + Russian translation of the newly-surfaced MediaBrowser strings (and
  other recent additions); previously-empty catalog entries dropped from 14 to 1
  in both locales. `%{...}` placeholders, markdown links and arrows preserved.
  (#608)

## 1.7.166 - 2026-06-25

### Added
- **Annotated media thumbnails baked from Etcher shapes.** A file's Etcher
  annotation shapes (rectangles, circles, marker/freehand strokes) are baked into
  a single deterministic `thumbnail_annotated` PNG variant (ImageMagick, with the
  geometry→draw mapping delegated to `Etcher.Raster`), so the markup is visible in
  the MediaBrowser grid without rendering shapes live for every viewer. The
  `AnnotationThumbnailJob` Oban worker debounces regeneration in the background;
  its unique constraint is computed from the installed `Oban.Job.states/0` minus
  the terminal states (robust across Oban 2.20/2.23) and excludes `:completed`, so
  a finished regen never throttles the next edit. The grid prefers the baked
  variant with a checksum-based cache-bust and falls back to the plain thumbnail.
  Gated behind a project-wide media setting (`storage_annotated_thumbnails_enabled`,
  off by default) — an "Annotated Thumbnails" toggle in Media Settings → Media
  Configuration. Bumps the `:etcher` dependency to `~> 0.7`. (#607)
- **`VariantGenerator.store_prepared_variant/5`.** Stores an already-rendered
  variant file (produced outside the resize pipeline, e.g. the baked annotated
  thumbnail) through the existing stats / bucket-storage / `FileInstance` /
  file-location tail. (#607)

### Changed
- **Referrals extracted into the standalone `phoenix_kit_referrals` module.** The
  referral-codes feature (schemas, business logic, admin UI) leaves core for the
  auto-discovered package, mirroring how posts and user_connections are
  structured; core keeps the database tables (migrations untouched). A new
  runtime-dispatch facade, `PhoenixKit.Users.Referrals`, resolves the installed
  module by its `PhoenixKit.Module` key and dispatches via `apply/3`, so core has
  **no compile-time dependency** on the package. With the module absent every call
  degrades safely: the system reads as disabled, lookups return `nil`, and
  `use_code/2` is a no-op (the referral field disappears from signup). The
  module's admin tab and routes now flow through generic module discovery
  (`admin_tabs/0`, `settings_tabs/0`, `route_module/0`) instead of the removed
  hardcoded subtab and route injection. (#607)

## 1.7.165 - 2026-06-24

### Added
- **`sitemap_sources/0` module callback for zero-config sitemap source
  registration.** External modules can contribute their own
  `Sitemap.Sources.Source` modules (e.g. Entities) to the generated sitemap with
  no host-app configuration, mirroring route / CSS / JS auto-discovery. Collected
  via `ModuleRegistry.all_sitemap_sources/0` from **enabled** modules and appended
  to the base source list (deduplicated, order-preserving). A host
  `config :phoenix_kit, sitemap: [sources: [...]]` now acts as a base list that
  module sources extend rather than fully replace. (#603)
- **Migration V137 — email event deduplication + `aws_message_id` backfill.**
  Backs the `Emails.Event` schema's declared unique constraints with real partial
  unique indexes (one per `(email_log_uuid, event_type)` for single-occurrence
  types; one per `(email_log_uuid, event_type, occurred_at)` for open/click),
  removing pre-existing duplicates first. Backfills the indexed `aws_message_id`
  column from the legacy `headers` JSONB (conflict-safe via `DISTINCT ON` +
  `NOT EXISTS`). Adds pg_trgm substring-search indexes for the admin email list,
  per-template open/click analytics composites, and an archiver body-compression
  partial index. Host apps pick this up via `mix phoenix_kit.update`. (#604)
- **`user` comment-resource handler.** A comment attached to a user resolves to
  the user's display name, `/admin/users/view/:uuid`, and avatar thumbnail in the
  comments moderation admin instead of a bare uuid. (#605)
- **`notification_default_link` setting.** A catch-all destination for
  notifications that have no link of their own. Defaults to `/dashboard`
  (authenticated-only; guarded to a no-op when the user dashboard is disabled);
  clear the field to make such notifications non-clickable. Built through
  `Routes.path/1`, so it carries the URL prefix and the recipient's locale. An
  opt-in `config :phoenix_kit, warn_unlinked_notifications: true` logs how to wire
  a link when a clicked notification has neither. (#605)

### Changed
- **Link-less notifications read as informational.** The notifications bell shows
  a default cursor (not a pointer) for a notification with no effective target,
  and clicking it still clears its unread state rather than appearing broken.
  (#605)

### Fixed
- **A disabled module's source no longer leaks into the flat sitemap.**
  `all_sitemap_sources/0` now aggregates from **enabled** modules only, so a
  disabled module contributes nothing even in flat-sitemap mode — where the
  generator force-collects sources and bypasses each source's own `enabled?/0`.
  The previous `all_modules/0` aggregation relied solely on that per-source gate,
  which flat mode skips. (#603)
- **Comment `file` resource links no longer double-prefix under a non-root
  `url_prefix`.** Comment-resource handlers must return a raw path (the comments
  module applies `Routes.path/1` once); the `file` handler pre-applied it. Both
  the `file` and new `user` handlers now return raw paths, matching `post`. (#605)
- **Notifications bell reads its default-link setting from cache.**
  `default_link/1` used the uncached `Settings.get_setting/2` on a hot path (the
  sticky bell's `refresh/1` runs on mount and on every notification PubSub event);
  it now uses the ETS-backed `get_setting_cached/2`. (#605)

## 1.7.164 - 2026-06-22

### Fixed
- **`user.email_unconfirmed` notifications regained their settings link.** PR #602
  replaced the broad `"user." <> _` link rule with an explicit `@account_actions`
  whitelist but omitted `user.email_unconfirmed` — the toggle-sibling of
  `user.email_confirmed`, emitted from the same admin code path and declared an
  `"account"` notification type. Its notification lost its `/dashboard/settings`
  click-through. It is now in the whitelist, so the whole account toggle is
  consistent.

### Changed
- **`user.email_unconfirmed` now renders dedicated icon/text.** Previously it fell
  through to the generic `hero-bell` + humanized-action display while
  `user.email_confirmed` showed a tailored message. It now renders
  `hero-exclamation-circle` + "Your email is no longer confirmed.", matching its
  sibling.

## 1.7.163 - 2026-06-22

### Fixed
- **Notification click-through links.** `Render.link_for/1` mapped only
  `"user." <> anything` → `/dashboard/settings` (wrongly catching `user.followed`)
  and everything else → `nil`, so social notifications (`post.*`, `comment.*`)
  navigated nowhere and follow notifications opened the settings page. The
  account-action → settings mapping is now an explicit whitelist;
  `user.followed` / `post.*` / `comment.*` / `user.deleted` / unknown actions
  return `nil` so the emitter's `notification_link` metadata drives the deep-link.
- **Notification links now carry the recipient's locale prefix.**
  `Render.render/2` accepts a locale that is threaded into `Routes.path`; the
  notifications bell receives `"locale"` in its session (from `LayoutWrapper`)
  and passes it at click time. Previously the link was built in the sticky bell's
  process with no locale, so it used the default locale instead of the user's.

## 1.7.162 - 2026-06-18

### Added
- **`MarkdownEditor` `:prompt_insert` action** — a host can trigger a client-side
  `window.prompt` (e.g. a video URL) and insert the result by substituting
  `%{value}` in a template, via
  `send_update(..., action: :prompt_insert, prompt:, template:)`, with no inline
  script of its own. (#601)

### Changed
- **`Components.Core.MarkdownEditor` is now driven by a LiveView hook**
  (`window.PhoenixKitHooks.MarkdownEditor` in `phoenix_kit.js`) instead of an
  inline `<script>` plus inline `onclick`/`onmousedown` handlers. The old
  approach broke under a strict Content-Security-Policy (a nonce never authorizes
  inline event handlers; an absent nonce blocks the `<script>`) and failed on
  LiveView navigation (a patched-in `<script>` never re-executes), so the toolbar
  and image insertion only worked after a full page refresh. Toolbar buttons now
  carry `data-md-action` attributes; server commands (`insert-at-cursor`,
  `set-content`) arrive via `handleEvent` filtered by `global_id` so multiple
  editors on one page don't cross-fire; toolbars ship hidden and the hook reveals
  them, with a `<noscript>` hint when JS is off. The public component API
  (`:insert_at_cursor`, the `{:editor_content_changed}` host message, the attrs)
  is unchanged. (#601)
- **`confirm_modal` confirm button gains `phx-disable-with`** so a fast
  double-click can't fire `on_confirm` twice (e.g. double-enqueue an AI
  translation). Applies to every confirm modal; no behavior change beyond the
  in-flight disable. (#601)

### Fixed
- **`Utils.Geolocation` now uses `Req`** instead of calling Finch directly
  against a `PhoenixKit.Finch` pool that nothing starts (not PhoenixKit's empty
  supervisor, not the installer, which only starts `Swoosh.Finch`). Every lookup
  previously raised "unknown registry", was swallowed by the rescue, and
  registration fell back to IP-only — so `registration_country` / `region` /
  `city` were never populated. IP geolocation now works with no host supervisor
  setup (`Req` rides its own auto-started pool). `retry: false` keeps the lookup
  single-shot on the registration path.
- **`MarkdownEditor`'s unsaved-changes `beforeunload` prompt no longer fires
  after a successful save** — the hook's local dirty flag now resets when the
  server reports `save_status` `"saved"`, instead of staying armed for the page's
  life after the first keystroke (most hosts never push the `changes-status`
  event that previously cleared it).

### Removed
- **`MarkdownEditor` `script_nonce` attr** — unused now that the editor is
  hook-driven. (#601)
- **Orphaned `priv/static/assets/phoenix_kit_markdown_editor.js`** — the old
  standalone inline-script implementation, superseded by the `MarkdownEditor`
  hook in `phoenix_kit.js` and referenced by nothing (the installer copies only
  `phoenix_kit.js`).

### i18n
- Gettext-wrapped the `MarkdownEditor` heading-button title (`Heading %{level}`,
  previously a hardcoded string) and refreshed the JS-disabled `<noscript>` hint
  copy. Both are translatable; the translation catalogs pick them up on the next
  resync. (#601)

## 1.7.161 - 2026-06-18

### Changed
- **`Components.Core.Markdown` now renders via `MDEx`** instead of `earmark`.
  The `<.markdown>` component consolidates onto the same Rust-NIF renderer
  already shared across the dependency tree (`leaf`, `phoenix_kit_comments`) —
  completing the migration begun in 1.7.158. Output is preserved: GFM
  (strikethrough/table/autolink/tasklist), smart typography,
  `<code class="language-…">` fenced code blocks, and raw-HTML passthrough on
  `sanitize={false}` (the default path still runs `HtmlSanitizer`).
- Updated the publishing format guide to name MDEx as the markdown renderer.

### Removed
- **`earmark` direct dependency.** It was retained only for
  `Components.Core.Markdown`; with that component on `MDEx`, the dep and its
  `mix.lock` entry are removed. `earmark_parser` remains transitively via
  `ex_doc` and is unaffected.

## 1.7.160 - 2026-06-17

### Fixed
- **V122 migration on pre-locations databases** (issue #598) — `V122` creates
  `phoenix_kit_location_spaces` with a required FK to `phoenix_kit_locations`,
  a table created only in `V91`. Because the locations tables were added to an
  already-released `v91.ex`, any database that passed V91 *before* that addition
  never received the parent table, so V122 aborted the whole migration
  transaction with `42P01 undefined_table`. `V122.up/1` now
  `create_if_not_exists`-backfills `phoenix_kit_locations` (mirroring V91's
  final shape) before building the FK — an idempotent no-op where V91 already
  created it, and a repair where it was missing.

## 1.7.159 - 2026-06-17

Staff-support core changes (V136 employment history, Activity per-resource
filter, media picker hardening, embedded-LiveView identity) plus follow-up
review fixes. These changes landed on `main` after 1.7.158 without a version
bump; recorded here.

### Added
- **V136 migration** — `phoenix_kit_staff_employments`, a per-person history of
  employment spans (employment type, translatable `job_title`, department/team
  snapshot, date range, `work_location`, `notes`). A partial unique index
  enforces one open (current) span per person; the matching
  `phoenix_kit_staff_people` columns are kept as a denormalized mirror of the
  current span (not dropped). Backfills one open span per existing person
  (guarded, retry-safe). `@current_version` → 136.
- **`PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2`** — reconstructs
  `:phoenix_kit_current_user` / `:phoenix_kit_current_scope` on an off-router
  embedded LiveView mount from a host-supplied `session["current_user_uuid"]`.
  No-ops on a router mount, degrades to anonymous for an absent/unknown/inactive
  uuid, and reconstructs identity (not authorization). Reference consumer:
  `phoenix_kit_projects`.
- **Upload-only media picker** — `MediaSelectorModal` gains a `browse: false`
  mode that hides the library grid/search/filter, leaving a pure uploader
  (uploaded files auto-select).
- `update_user_custom_fields/3` gains `:broadcast` and `:ensure_definitions`
  options (both default `true`, so existing callers are unchanged).

### Changed
- `PhoenixKit.Activity.list/1` (and `count/1`) now honour a `:resource_uuid`
  filter, and the admin Activity page (`/admin/activity`) reads a `resource_uuid`
  URL param — so a module can deep-link a per-resource feed. Previously
  `:resource_uuid` was silently ignored, leaking every same-type resource's
  events into a per-resource view.
- `MediaSelectorModal` constrains uploads to the active type filter, shows
  filter-aware copy, excludes trashed / system-managed files from the browse
  list, and gives each instance a unique `<dialog>` id so two pickers on one
  page don't collide.
- Admin **Activity page** UI follow-ups (PR #600): the filter toolbar fits one
  row on mobile (Module / Mode / Action / Type as compact dropdowns), a
  persisted grid/list Display toggle, and a mobile-friendly list view. The
  user form's Cancel / primary buttons are reordered (Cancel left, primary
  right) to match the rest of the admin UI.

### Fixed
- The manage-users **and** activity grid/list view toggles no longer register
  their internal `users_view_mode` / `activity_view_mode` preference as a
  user-facing custom-field definition (it was leaking into the Customize Columns
  modal) and no longer broadcast a `user_updated` event — so toggling the view
  stops re-querying the users list for every connected admin.
- The Activity page's new filter dropdowns preserve the `resource_uuid`
  deep-link scope (a per-resource feed no longer reverts to all activity when a
  filter is picked).
- The media picker now rejects off-type uploads server-side. The client `accept`
  list is fixed when the upload is first allowed and can't track the in-modal
  type dropdown, so an image/video picker could still store an off-type file;
  `MediaSelectorModal` re-checks the type on upload and rejects mismatches.
- The accepted-types hint is shown in the upload-only media picker (it was
  hidden in `browse: false` mode, the one place it's most useful).

### i18n
- Internationalized the full-page media selector and the Jobs / Languages admin
  page headers; added the new picker copy strings (et, ru).

## 1.7.158 - 2026-06-17

Centralize the MDEx (markdown) dependency in core.

### Changed
- **`mdex` is now a direct dependency of `phoenix_kit`** (`~> 0.13`), so every
  module shares one resolved version through the core dependency tree instead of
  each declaring its own and risking version mismatches — the same arrangement
  already used for `leaf`. Modules that render markdown (e.g.
  `phoenix_kit_comments`) call `MDEx` directly and should rely on it being
  provided transitively via `phoenix_kit` rather than declaring their own
  `mdex` dep.

## 1.7.157 - 2026-06-17

Core support for the `phoenix_kit_comments` admin work — file-comment resolution
and an annotation deep-link — plus admin navbar/MediaBrowser layout fixes and a
dependency refresh.

### Added
- **File-comment resource resolution.** `PhoenixKit.Annotations.resolve_comment_resources/1`
  maps `"file"` comment resources (including annotation discussions anchored via
  `metadata.annotation_uuid`) to the file's display name and admin media path, plus a
  signed `"thumbnail"` URL for images — so the comments moderation admin can link a
  thumbnail chip instead of showing a bare uuid. Registered as the `"file"` handler by
  `phoenix_kit_comments`, gated on this module being loaded.
- **Annotation deep-link.** `MediaDetail` reads `?annotation=<uuid>` and pushes
  `etcher:select-shape`; a new `phoenix_kit.js` bridge retries `layer.selectShape(uuid)`
  until the Etcher canvas layer is ready, so a comment's chip lands on the file with its
  shape selected. (No-ops on readonly shapes and on the static mount.)
- **Plugin admin pages can forward `page_title`/`page_subtitle` to the navbar.** The plugin
  admin layout now passes them through to `app_layout`, so plugin pages can drop their
  in-content header and show the title/subtitle in the navbar breadcrumb (matching the core
  media page).

### Changed
- **Dependency refresh:** `finch` 0.22 → 0.23, `phoenix_live_view` 1.2.1 → 1.2.3,
  `sourceror` 1.12.0 → 1.12.2, `tailwind` installer 0.5.0 → 0.5.1, and `req` pinned to
  0.5.17.
- **MediaBrowser admin-page layout.** Always show the sidebar "Folders" header, align the
  breadcrumb row flush with it, and drop the page padding so the browser fills the admin
  media page.

### Fixed
- **Mobile admin navbar breadcrumb.** When a page has a title, the `Admin Panel /` prefix
  is hidden below `sm` (and the title truncates) so it no longer overlaps the
  theme/notifications controls.
- **Media browser hero header z-index.** The hero's `z-30` (and the toolbar dropdowns'
  `z-20`) are confined to the card's own stacking context via `isolate`, so they no longer
  paint over the mobile drawer/navbar.
- **Media list view tablet columns.** The Type/Size columns now cross over to the folded
  mobile meta line at the same `md` breakpoint as Date, so they're no longer double-rendered
  (column + meta line) in the `[sm, md)` tablet band.

## 1.7.156 - 2026-06-16

MediaBrowser folder UX polish (folder-aware search, a name-it modal, an
active-branch sidebar highlight, and a clean mobile layout) plus dependency
upgrades.

### Added
- **Folder results in media search.** A name search in the MediaBrowser now
  surfaces matching *folders* alongside the matching files, scoped exactly like
  the file search (a folder's direct children when inside one, the whole subtree
  at a scope root, everything at the real root). Backed by a new
  `PhoenixKit.Modules.Storage.search_folders/3`.
- **New-folder name modal.** Creating a folder opens a modal to name it — with
  an `"untitled"` / `"untitled N"` placeholder default when left blank — instead
  of immediately dropping an inline-rename `"untitled"` folder into the sidebar.
  Cancel adds nothing. The `FolderExplorer`'s create button now emits
  `open_new_folder_modal` (was `create_untitled_folder`).
- **Active-branch highlight in the folder sidebar tree.** The guide-line
  connectors from a root folder down to the current folder are darkened (same
  hue, bolder alpha) so you can trace the branch you're inside. Suppressed in
  trash view.

### Changed
- **Cleaner MediaBrowser mobile layout.**
- **Dependency upgrades:** `leaf` 0.2 → 0.3 (its markdown backend swapped from
  `earmark` to the `mdex` Rust NIF — transparent to PhoenixKit, which keeps its
  own direct `earmark` dep for `Components.Core.Markdown`), `tailwind` installer
  0.4 → 0.5, `floki` 0.38.4.

### Fixed
- **Folder rename now updates the hero header title.** Renaming a folder from
  the sidebar keeps the hero header (and an open Edit-header panel) in sync when
  the renamed folder is the one being shown — it no longer kept the pre-rename
  name.
- **Media sidebar active-turn corner.** Sharp for a mid-branch turn, rounded for
  the last child.

## 1.7.155 - 2026-06-15

Makes the integration provider registry capability-discoverable, so consumers
(e.g. `phoenix_kit_ai`) can build provider lists dynamically instead of
hardcoding them.

### Added
- **`PhoenixKit.Integrations.Providers.with_capability/1`** — returns all
  providers (built-in + external-module) that declare a given capability, in
  `all/0` order. An AI module can render its provider picker from
  `with_capability(:ai_completions)` so a newly-registered chat provider
  surfaces automatically, with no hardcoded list.
- **`PhoenixKit.Integrations.Providers.base_url/1`** — returns a provider's
  primary REST API base URL (or `nil`). The `:ai_completions` providers
  (OpenAI, OpenRouter, Mistral, DeepSeek) now declare a `:base_url`, letting
  consumers derive a default endpoint base from the registry.

### Changed
- `@type provider` now documents the optional `:base_url`, `:validation`, and
  `:instructions` keys that real provider maps already carry (typespec accuracy
  only — no runtime change).

### Added
- **OpenAI integration provider** (`PhoenixKit.Integrations.Providers`). A new
  built-in `api_key` provider for OpenAI, alongside OpenRouter / Mistral /
  DeepSeek / ElevenLabs. It appears automatically in the admin Integrations UI —
  no migration or host changes needed. Connect with a single API key from
  platform.openai.com → API Keys; **Test Connection** validates it against
  `GET https://api.openai.com/v1/models` using standard `Authorization: Bearer`,
  so the generic `authenticated_request/4` helper works for consumers too.
  Declared capabilities cover OpenAI's range: `:ai_completions`,
  `:ai_embeddings`, `:image_generation`, `:text_to_speech`, `:speech_to_text`.

## 1.7.153 - 2026-06-15

Adds **ElevenLabs** as a built-in integration provider for text-to-speech and voice generation.

### Added
- **ElevenLabs integration provider** (`PhoenixKit.Integrations.Providers`). A new
  built-in `api_key` provider for ElevenLabs' audio AI, alongside OpenRouter /
  Mistral / DeepSeek. It shows up automatically in the admin Integrations UI — no
  migration or host changes needed. Connect with a single API key from
  ElevenLabs → Settings → API Keys; **Test Connection** validates it against
  `GET https://api.elevenlabs.io/v1/user` using ElevenLabs' custom `xi-api-key`
  header (not `Authorization: Bearer`). Declared capabilities span the full audio
  range: `:text_to_speech`, `:speech_to_text`, `:sound_effects`,
  `:music_generation`. Consumers reference the connection by uuid and set the
  `xi-api-key` header themselves (via `get_credentials/1`) — the generic
  `authenticated_request/4` helper is Bearer-only and does not fit ElevenLabs'
  scheme.

## 1.7.152 - 2026-06-15

Fixes two user-menu language-switcher bugs on locale-prefixed / default-locale pages.

### Fixed
- **`user_dropdown` / guest dropdown no longer crash on a bare `/:locale`
  path.** `remove_locale_from_path/1` fed the post-strip remainder to
  `Path.join/1`, which raised `FunctionClauseError` on an empty list — so
  rendering the in-menu language switcher on a path that is *only* a locale
  segment (e.g. `/ru`, `/fr`, `/en-GB`) 500'd the page. A path that reduces to
  just a locale now returns `/`, so the switch links resolve correctly (`/ru`,
  `/fr`, …). Surfaced by hosts adopting locale-prefixed landings (1.7.150+).
  Locale detection stays narrow (2-char base or 5-char dialect) so a real 3-char
  page segment like `/faq` isn't mistaken for a locale.
- **Current language now highlights on the default locale.** The in-menu list
  compared the enabled dialect against `@current_locale` with full-dialect
  equality, so on the default page (where the active locale resolves to a fixed
  dialect like `en-US` while English is enabled as `en-GB`) nothing matched and
  the active language wasn't marked. Highlighting now compares **base codes**
  (`en`/`en-GB`/`en-US` all match), matching `Core.LanguageSwitcher`, and works
  whether the caller passes a base or a dialect.
- **Guest dropdown trigger matches the authenticated avatar shape.** The
  logged-out trigger was a round `hero-user-circle`; it's now a rounded-rectangle
  placeholder (`w-10 h-10 rounded-lg`) with a person silhouette, consistent with
  the signed-in avatar.

## 1.7.151 - 2026-06-15

Anonymous (guest) state for the user-menu widget, so one dropdown serves both signed-in and logged-out visitors and always offers a language switcher.

### Added
- **Guest dropdown in `UserDashboardNav.user_dropdown/1`.** The anonymous
  state, previously a bare "Login" button, now renders the same dropdown shape
  as the authenticated state: a generic "not signed in" trigger
  (`hero-user-circle`) opening a menu with guest links — **Log in**, **Sign up**,
  **Forgot password**, **Magic link** — plus the shared language switcher. A host
  can now rely on this single widget for everyone and drop a separate standalone
  switcher. Guest links are gated by the `allow_registration` /
  `magic_link_login_enabled` settings (log in and forgot-password always show).
- **`:show_language_switcher` attr** (default `true`) on `user_dropdown/1` —
  hides the in-menu language list in both states, for hosts that keep a
  standalone switcher and want to avoid a duplicate.
- **`:guest_links` attr** (default `[:login, :register, :reset, :magic_link]`) —
  narrows which guest links may appear; the per-feature settings gates still
  apply, so it can only narrow, never force-enable a disabled feature.

### Changed
- The authenticated and guest dropdowns now share one internal
  `language_menu_section` component, so both states render an identical
  language list. The guest switcher reuses the same URL logic, so locale links
  resolve correctly on locale-less pages (`/` → `/ru`, building on 1.7.150).

## 1.7.150 - 2026-06-15

Fixes locale-prefixed root URLs so anonymous visitors can switch language on a parent app's `/:locale` landing page.

### Fixed
- **`Routes.path("/", locale: x)` no longer emits a trailing slash.** The
  locale-prefixed root was built as `/{locale}/` (e.g. `/ru/`); Phoenix routers
  don't match a trailing slash, so a parent app's `/:locale` landing route 404'd
  and the language switcher's link on `/` led nowhere for anonymous visitors.
  Core now emits `/{locale}` (e.g. `/ru`) for the bare root while every other
  path is unchanged. The standalone
  `LanguageSwitcher.language_switcher_dropdown` routes through this primitive, so
  its anonymous-landing links resolve correctly. phoenix_kit keeps its
  URL-as-truth locale model (no session/cookie locale) — the parent app declares
  a `/:locale` landing and the switcher's link now reaches it.

## 1.7.149 - 2026-06-15

Structured staff skills: the V135 migration (PR #594) replaces the free-text staff `skills` column with a first-class, translatable skill entity.

### Added
- **V135 migration — structured staff skills.** Replaces the free-text
  `phoenix_kit_staff_people.skills` column with a first-class, translatable
  `phoenix_kit_staff_skills` entity (globally unique by `lower(name)`) and a
  `phoenix_kit_staff_person_skills` many-to-many join. Each skill carries its
  own per-skill, translatable proficiency levels (`levels` JSONB array of
  `{id, name, translations}`) plus an `allow_multiple_levels` boolean; the
  join's `proficiency_levels` JSONB array holds the selected level ids. The
  comma-separated free-text is split, trimmed, case-insensitively de-duplicated
  into skill rows, linked to each person, and the column is dropped — guarded on
  the column's existence so a partial re-run is a safe no-op. Lossy by design:
  per-locale `translations["skills"]` overrides don't map to structured skills
  and are stripped (structured skills carry their own translations going
  forward). `down/1` is a lossy rollback (re-adds an empty `skills` column).
- **Partial birthday index** on `phoenix_kit_staff_people(date_of_birth)`
  (active + non-null DOB only) so `Staff.upcoming_birthdays/1` scans a small
  index instead of the full people table.

### Fixed
- **V135 data migration caps skill tokens at 255 chars.** The source
  `skills` column is unbounded `TEXT` but `phoenix_kit_staff_skills.name` is
  `VARCHAR(255)` (the `Skill` changeset's max), so a >255-char token would raise
  `value too long` and wedge the migration on every host. Both the skill INSERT
  and the link-INSERT join now truncate with `LEFT(trim(tok), 255)` so a long
  token stores and links on the same truncated form.

## 1.7.148 - 2026-06-14

Follow-up to 1.7.147: scopes the embedded-`MediaBrowser` header fix and adds `URLSigner.put_dzi_url/3` test coverage.

### Fixed
- **Scoped `MediaBrowser` header fallback** — an embedded browser scoped to a
  customized folder was rendering that folder's header customizations
  (description / logo / cover / creation-info) under the all-files / orphaned /
  trash / search views as well as at its root, so the `<h2>` title ("All Files" /
  "Trash" / …) disagreed with the metadata below it. The scope folder's header
  now shows only at the effective root. `header_folder_target/6` is the single
  source of truth shared by the nav data path and the template, and the hero
  cover-image arm is gated so the scope-folder cover can't bleed into those views
  either. The header stays read-only at the scoped root.

## 1.7.147 - 2026-06-14

Media viewer deep-zoom: progressive resolution + DZI tile streaming via Tessera 0.3.

### Added
- **Progressive resolution + DZI tile streaming** in the media canvas viewer
  (`/admin/media/:uuid`, the in-place modal, and the lightbox), backed by the
  rewritten **Tessera 0.3.1** (now a Fresco peer layer, no OpenSeadragon). The
  viewer opens on the cheap **medium** variant and swaps **medium → large** on
  zoom; past the sharpest raster it streams **DZI tiles of the original** (only
  the visible region) for images over 4K, or shows the full **original** raster
  for ≤4K. Tiles ride Fresco's stage transform so they stay glued to the image
  during pan/zoom; tile generation respects EXIF orientation.

### Changed
- `URLSigner.put_dzi_url/3` is now the single source of truth for the signed
  `"dzi"` manifest URL, shared by the media browser, detail page, and lightbox
  (previously only the browser produced it, so deep zoom was missing on the
  other two). Built in the non-localized route scope so it resolves on any
  locale.
- `{:tessera, "~> 0.3"}` (was `~> 0.2`); the jsDelivr hook pin tracks `v0.3.1`.

## 1.7.146 - 2026-06-14

### Added
- **`js_sources/0`** — a zero-config mechanism for external PhoenixKit modules to
  ship LiveView JS hook bundles into the host app, mirroring `css_sources/0`. A
  module declares `%{app:, file:, global:}` entries; the new
  `:phoenix_kit_js_sources` compiler resolves each bundle via `:code.priv_dir/1`
  (Hex + path deps), IIFE-wraps and concatenates them into
  `priv/static/assets/vendor/phoenix_kit_modules.js`, and folds each
  `window.<Global>` into `window.PhoenixKitHooks` (already spread into the host's
  `LiveSocket`). One stable `<script>` tag is added by `mix phoenix_kit.install`;
  `mix phoenix_kit.update` backfills it on existing installs. The compiler fails
  loudly on a missing bundle, a duplicate global, or a non-identifier global.
  Hook **names** must also be namespaced to stay unique across modules and the
  core hooks (documented on the callback) — the merge is last-write-wins.

### Changed
- PhoenixKit self-doc links now point at `phoenix-kit.hexdocs.pm` instead of the
  `hexdocs.pm/phoenix_kit` path form (install/update task footers, the
  not-installed warning, and the per-module-i18n guide).

### Fixed
- Media sidebar tree-state persistence no longer clobbers other `custom_fields`
  keys. `persist_tree_state/1` re-reads the user fresh from the DB before
  writing (matching `persist_user_view_mode/2`), because
  `update_user_custom_fields` replaces the entire `custom_fields` map with no
  server-side merge. The 1.7.145 version wrote from the stale in-socket copy, so
  expanding/collapsing a folder could silently revert a `custom_fields` value
  saved elsewhere since the browser loaded (e.g. notification preferences).
- The CSS/JS source compilers are now **prepended** to `Mix.compilers()` instead
  of replacing the list when a host has no `compilers:` key yet (the `css_sources`
  analogue had the same latent bug), in both install and update.
- `seed_modules_js_file/1` surfaces a seed-write failure as an installer warning
  instead of swallowing it (the file is still recreated on the next compile).

## 1.7.145 - 2026-06-13

Media browser overhaul: folder hero header + full customization, unified
toolbar, a shared folder-tree component, persisted tree state, and selection UX.

### Added
- **Folder hero header**: the folder header is now a hero block with a cover
  image background (or a soft folder-color gradient, neutral on non-folder
  views), faded to the page at the bottom, with the title, description,
  created-by avatar + name, date, and file count overlaid. New
  `cover_file_uuid` column on `phoenix_kit_media_folders` (migration **V134**).
- **Folder header customization** (V134, same migration): a **logo/icon**
  (`logo_file_uuid`, transparent-PNG aware), a **header size** (`header_size`:
  small / medium / large), and independent per-element visibility toggles —
  title, icon, **creator**, **date created**, **file count**, description, and
  background (`header_show_*` columns). Creator / date / file-count are separate
  toggles so users show only the pieces they want.
- **Edit header** panel to edit a folder's name + description together (muted,
  clickable "No description — add one" placeholder when empty), plus **logo** and
  **cover image** selectors that open the shared media picker scoped to the
  folder — pick an existing image or upload a new one; **Remove** clears it (the
  image stays in the folder). Opens as a popover dropping from the Edit header
  button (not a centered modal), ordered name/description → logo/background →
  size → toggles.
- **Display / Sort / Filter toolbar**: Display switches grid/list, Sort orders
  by newest/oldest/name/size, Filter narrows by file type. Each trigger shows
  the current selection with a chevron; sort + filter run through
  `list_files_in_scope`.
- **Long-press to multi-select**: holding a file/folder card ~450ms (without
  moving) enters select mode and selects it (subtle vibrate where supported);
  the trailing click is swallowed. Via `setupLongPress` on the `MediaDragDrop`
  hook + a `long_press_select` server handler.
- Media settings **Quick Actions** gained info icons + hover tooltips, plus a
  **Find Orphaned Files** and **Repair Media Module** action.

### Changed
- **Unified header/toolbar**: the toolbar, search, Add Media, Select and folder
  meta all live inside the hero. Layout is view-controls-left / actions-right,
  with secondary actions (Select, New folder) in a ⋯ overflow; the redundant
  result count and the standalone grid/list toggle were dropped. Add Media
  toggles in place to a fixed-width **Cancel** (toolbar doesn't shift), search is
  an inline expand-on-click field, and the list view has a sticky column header.
- **Media page header moved into the admin topbar** as a breadcrumb
  (`{ProjectName} Admin Panel / Media · subtitle`) via a new `page_subtitle`
  attr on the app layout, freeing the full content area for the browser. Generic
  — any admin page that sets `page_title` gets the breadcrumb.
- **Shared folder-tree node**: the sidebar and the Move modal now render the same
  parameterized `FolderExplorer.folder_tree_node` (config: navigate/toggle event,
  rename, drag, hover), so guide-line and structure changes stay in sync. The
  duplicate `move_folder_option` was removed.
- **Sidebar tree state persists server-side**: expanded folders + collapsed flag
  are stored in user meta and rendered on first paint (like the grid/list view
  mode), removing the collapsed-then-jump-open flash after connect.
- **Select-mode toolbar** reworked: it stays inside the header (no jump on
  toggle), with a clear **Done** exit button + count + Select all / Clear on the
  left and bulk Move / Download / Delete (Delete red) on the right, shown only
  when something is selected.
- **Folder tree guide lines** (sidebar + Move modal): per-row connectors with a
  `├` tee and a rounded `└` curl on the last row, elbows that reach the item,
  and 50% line opacity via an inheriting `--pk-tree-line` variable.
  `tree_connector_class/2` + `tree_line_color/1` are shared helpers.
- Media folder sidebar rows are fully clickable to open a folder (chevron still
  toggles, rename pencil still renames).
- Decluttered the media settings page: top banners folded into the
  subtitle/Quick Actions and the stale "Advanced Features Coming Soon" card
  removed.

### Fixed
- Edit header popover click-away routed its event to the parent LiveView and
  crashed with a `FunctionClauseError`; it now targets the component.
- Transparent-PNG logos render transparently (`object-contain` + drop shadow)
  instead of as a black/white box.
- Colored folders now show the blue selection highlight (the inline folder color
  was outranking the tint; it's now `!important`).
- Uncolored tree guide lines no longer render solid black (daisyUI-5 renamed
  `--bc`; replaced with a valid `currentColor`-based color).
- The orphaned-files view no longer mixes in folder cards (files only).
- The folder-header description no longer shows a large top blank line
  (`whitespace-pre-line` preserved the HEEx-indented expression's newline).
- A folder's chosen cover/logo no longer appears as a loose file in that
  folder's grid/list — `list_files_in_scope/2` excludes the folder's own
  `cover_file_uuid`/`logo_file_uuid` (the design intent the schema documented but
  didn't enforce). They remain real files, re-selectable from the header picker.
- Header media (creator avatar, cover, logo) is loaded only when its
  `header_show_*` toggle is on, dropping up to three queries + two signed-URL
  builds per folder navigation; the Edit-header previews still load them on open.
- `cover_file_uuid` / `logo_file_uuid` are now FK columns to
  `phoenix_kit_files(uuid)` with `ON DELETE SET NULL`, so deleting a referenced
  file self-heals the header reference; `header_size` is now `NOT NULL` (V134).
- Media file sort is case-insensitive for name and carries a stable `uuid`
  tiebreaker so equal sizes/names/timestamps can't shuffle across pages.
- Sidebar tree state persists from the in-socket user instead of re-reading the
  user from the DB on every expand/collapse; toolbar sort/filter/size handlers
  ignore out-of-whitelist values instead of crashing the component.

## 1.7.144 - 2026-06-10

### Added
- `table_row_menu_link/1` now accepts `target` and `rel` attributes directly
  (via its `:global` include list), so host apps can render external links that
  open in a new tab — e.g. `target="_blank" rel="noopener noreferrer"` — without
  tripping the "undefined attribute" compile warning under
  `--warnings-as-errors`.

## 1.7.143 - 2026-06-11

### Changed
- Media browser header now reads top-to-bottom in a logical order: breadcrumb →
  title → folder description → toolbar. The contextual title (folder name, or
  "All Media" / "Trash" / "Orphaned Files" / "All Files" at the roots) moved out
  of the action toolbar and above the folder-description block, so the title sits
  directly under the breadcrumb and the description reads as belonging to it.

## 1.7.142 - 2026-06-10

### Fixed
- Media browser breadcrumb now always renders in the same place (no
  disappearing row / layout jump when navigating to the root). At the root it
  shows "All Media" (or the scope folder name) as the current, non-link crumb
  instead of vanishing; inside a folder it stays the clickable path.

## 1.7.141 - 2026-06-10

### Added
- Media detail page (`/admin/media/:file_uuid`) now has a back arrow to the
  left of the title. It does a browser **history back**, returning the user to
  exactly where they were before opening the file — the folder grid they came
  from (the MediaBrowser keeps the open folder in the `?folder=` query) rather
  than always the media root. Falls back to `/admin/media` for a direct/shared
  load with no history.

## 1.7.140 - 2026-06-10

### Changed
- Bump `leaf` 0.2.22 → **0.2.23** (dep min in `mix.exs` + the jsDelivr CDN pin
  in `phoenix_kit.js`, `@v0.2.22 → @v0.2.23`). 0.2.23 is a large, default-
  preserving Leaf release: GFM task lists & callouts, custom/unknown tag
  round-trip preservation, an expanded host-integration/authoring API, RTL +
  symbol/date inserts, and an Obsidian-style hybrid live preview for list
  markers and checkboxes. Stored markdown and existing usage are unchanged.

## 1.7.139 - 2026-06-10

### Fixed
- External module CSS auto-discovery is now deterministic at compile time.
  `PhoenixKit.ModuleDiscovery` scanned `:application.loaded_applications/0`, so on
  a cold build (`rm -rf _build && mix compile`) a dep whose app hadn't been loaded
  yet was invisible — `_phoenix_kit_sources.css` was generated **empty**, and under
  Tailwind v4 `@import "tailwindcss" source(none);` the dep's classes (e.g.
  responsive `sm:/md:/xl:table-cell` columns) were never compiled, silently
  breaking admin UI in the host. Discovery now walks dependency `ebin` directories
  on the code path (reading each `<app>.app` + the persisted `@phoenix_kit_module`
  beam attribute via `:beam_lib.chunks/2`) independent of load state, matching the
  module's documented "no module loading required" contract.

### Added
- The `:phoenix_kit_css_sources` compiler now emits a loud build warning when it
  generates zero `@source` lines while phoenix_kit-dependent deps are present on
  disk, turning a hard-to-diagnose missing-CSS mystery into a one-line warning.

## 1.7.138 - 2026-06-09

### Fixed
- Media browser: removed the dead client-side view-mode persistence left over
  from the 1.7.136 server-side switch. The `MediaDragDrop` hook no longer writes
  the now-unread `phoenix_kit_media_view_mode` localStorage key (or the
  `data-view-mode` button attrs / `dataset.mediaView`) — view mode is persisted
  per-user in `custom_fields` and rendered on first paint.
- Media browser: the current-folder header description editor now cancels on
  Escape, matching the grid-card and list-row editors.

### Changed
- Media browser: folder-description textareas are debounced
  (`phx-debounce="300"`) so editing no longer round-trips on every keystroke,
  and the description editor resolves the folder from already-loaded assigns
  instead of issuing a redundant query on open/save.

## 1.7.137 - 2026-06-09

### Fixed
- Bump `leaf` 0.2.21 → **0.2.22** (dep min in `mix.exs` + the jsDelivr CDN pin
  in `phoenix_kit.js`, `@v0.2.21 → @v0.2.22`) for the markdown-link round-trip
  fix: editing rich-text content with a link no longer doubles it into
  `[[label](url)](url)` on each save (affected comments/posts editors).

## 1.7.136 - 2026-06-08

### Fixed
- Media browser no longer flashes grid view before switching to the user's
  saved list view on load. The grid/list preference is now persisted per-user
  in `custom_fields["media_view_mode"]` and rendered on first paint (dead +
  connected render), instead of being restored from localStorage via a
  post-connect `set_view_mode` push. The `MediaDragDrop` hook's localStorage
  restore was removed; the toolbar toggle still drives `set_view_mode`, which
  now persists server-side.

## 1.7.135 - 2026-06-08

### Added
- **Folder descriptions** — media folders can now carry an optional free-text
  description that admins can add/edit/clear. Surfaced in three places in the
  Media browser, all sharing one save path:
  - Inside a folder: a prominent "Add a folder description" button / info box
    under the breadcrumb, with an inline editor.
  - Grid view: a clamped description line under each folder card + an
    "Add/Edit description" entry in the card's ⋯ menu (inline editor on the card).
  - List view: a new **Description** column after Path + the same ⋯ menu entry
    (inline editor in the row).
- **V132** migration adds the `description TEXT` column to
  `phoenix_kit_media_folders` (`ADD COLUMN IF NOT EXISTS`, idempotent), and
  `Folder`'s changeset casts it with a 2000-char cap.

## 1.7.134 - 2026-06-08

### Changed
- The `/admin/media` page now fills the full content width and viewport height
  instead of floating in a width-capped, fixed-height card. The page wrapper
  drops `container mx-auto` for `w-full` + `h-[calc(100dvh-4rem)]`, and the
  browser's file grid scrolls internally rather than the whole page growing.

### Added
- `PhoenixKitWeb.Components.MediaBrowser` gains a `fill_height` attr (default
  `false`). When `true`, the browser grows to fill its parent (`flex-1`)
  instead of the bounded `h-[72vh] max-h-[48rem]` card — used by the full-page
  admin media view; modal/gallery embeds keep the bounded default.

## 1.7.133 - 2026-06-08

### Removed
- **AI translation pipeline moved out of core into the `phoenix_kit_ai` plugin** (PR #586).
  Core keeps only the `phoenix_kit_ai_endpoints` / `_prompts` table migrations (the single
  versioned chain) and the generic, AI-agnostic `ai_translate` attr on
  `Components.Core.LanguageSwitcher`. Removed from core:
  - `PhoenixKit.Modules.AI` + `.Translatable` / `.Translations` / `.TranslateWorker` /
    `.Translation` (the whole pipeline) — re-homed to `PhoenixKitAI.*`.
  - The optional `PhoenixKit.Module.ai_translatables/0` callback and its
    `PhoenixKit.ModuleRegistry.all_ai_translatables/0` / `find_ai_translatable/1` discovery —
    discovery now lives in `PhoenixKitAI.Translatables` as a duck-typed scan over
    `ModuleRegistry.all_modules/0`.
  - `PhoenixKitWeb.Components.AITranslate{,.Embed,.FormBinding,.FormGlue}` (the AI-translate
    modal UI), and the `Utils.Routes.ai_path/0` helper (now `PhoenixKitAI.Routes.ai_path/0`).

  **Breaking for direct consumers of these APIs.** Feature modules
  (publishing / catalogue / projects) now depend on `phoenix_kit_ai` and implement
  `PhoenixKitAI.Translatable`; they float to this core release via `~>` minimums. Hosts that
  used the in-core `Modules.AI.*` / `AITranslate.*` modules must switch to the plugin.

## 1.7.132 - 2026-06-07

### Added
- **`PhoenixKitWeb.Components.AITranslate.Embed`** — a `use`-able macro that
  wires the host side of the AI-translate modal so consumers stop hand-copying
  it. Via `attach_hook` lifecycle hooks it injects the six `ai_*` `handle_event`
  clauses (`ai_toggle_modal`, `ai_select_endpoint`, `ai_select_prompt`,
  `ai_select_scope`, `ai_generate_prompt`, `ai_translate_lang`) and the
  `{:ai_translation, …}` `handle_info` clause, composing with the host's own
  handlers (non-AI events/messages pass straight through). Form re-sync defaults
  to assigning both `:changeset` and `:form`; hosts whose sync differs override
  `ai_translate_assign_form/2`. Because lifecycle hooks run before the host's
  own callbacks and `:halt` on the events they own, a host clause for those AI
  events is shadowed — the moduledoc documents this so the AI clauses aren't
  re-implemented in the host.
- **V131** migration adds a generic `metadata JSONB NOT NULL DEFAULT '{}'`
  column to `phoenix_kit_staff_people` (mirrors the `entity_data` shape). The
  first consumer is staff soft-delete, which stashes the prior lifecycle status
  under `metadata["trashed_from_status"]`; the column is general-purpose so
  future per-person metadata needs no new migration. Idempotent
  `ADD COLUMN IF NOT EXISTS`; `@current_version` → 131.

### Fixed
- Media detail comments: forward Leaf editor events to the embedded
  `CommentsComponent`. The Leaf rich-text composer reports its content to the
  host LiveView via a `{:leaf_changed, …}` process message; `media_detail`
  wasn't forwarding it, so "Post Comment" silently posted empty content. Adds
  the runtime forward (resolved against the optional `phoenix_kit_comments` dep)
  plus a `handle_info` catch-all so unmatched messages don't crash the LV.

### Changed
- Extract `PhoenixKitWeb.CommentsForwarding.forward_leaf_changed/2` — the
  `{:leaf_changed, _}` forwarding contract (optional-dep guard + runtime
  `apply/3` + `:pass`/contract-drift handling, logging unexpected returns) now
  lives in one module. `MediaBrowser.Embed` and `MediaDetail` both delegate to
  it instead of carrying near-verbatim copies, so a future
  `forward_leaf_event/2` contract change touches one call site. As a side
  effect the `MediaBrowser.Embed` macro no longer injects `require Logger` into
  every host (the only `Logger` use moved into the shared module).
- Document required host wiring on the callback-message components
  `MediaSelectorModal`, `MarkdownEditor`, and `MediaGallery` — loud
  "required host wiring / silent failure otherwise" moduledoc contracts. These
  stay docs-only by design (per-consumer handling, not uniform boilerplate, so
  no Embed macro). `MediaSelectorModal` also documents the `:notify` alternative
  for LiveComponent consumers.
- Dependency bumps (`mix.lock`): `bandit` 1.11.1 → 1.12.0, `etcher`
  0.6.5 → 0.6.6, `fresco` 0.6.3 → 0.7.1, `spitfire` 0.3.12 → 0.3.13, `tesla`
  1.18.3 → 1.20.0.

## 1.7.131 - 2026-06-05

### Added
- Per-user Etcher line params ("ink") saved to user meta, mirroring the color
  palette. `MediaCanvasViewer` wires Etcher 0.6.5's new
  `etcher:line-params-changed` hook: the global stroke defaults (width /
  opacity / dash for new shapes) are one set per user shared across every
  viewer, seeded fresh from `custom_fields["etcher_line_params"]` on mount and
  persisted back via `update_user_custom_fields/2` on every slider edit. The
  payload is sanitized on both write and read — width clamped 1..40, opacity
  0..1, dash restricted to `solid`/`dashed`/`dotted`, merged over the default —
  so a partial or garbage client payload can never reach
  `<Etcher.layer line_params={…}>`.
- Expose the full Etcher 0.6.5 toolset in the Media viewer: add `:grabber`
  (pan) and `:marker` (highlighter) to `MediaCanvasViewer`'s `tools` list,
  which previously omitted them. Marker is pure marking for now — it persists
  like any shape (via `annotations-changed`) but skips the annotation composer,
  so highlighting doesn't prompt for a title/comment; it's just a line.
  Its tooltip shows a byline instead: the drawing user's display name (stamped
  into `metadata` server-side at creation, not the spoofable client wire) over
  the creation date — filled instantly via the patch-shape push and identical
  after a reload.
- **V130** migration widens `phoenix_kit_annotations_kind_check` to allow
  `'marker'`, and `Annotation`'s `@kinds` adds it too. Without both layers the
  marker insert was rejected and silently dropped, so a marker vanished on
  reload.

### Changed
- Upgrade `etcher` 0.5.5 → 0.6.5 (adds the line-params hook + API) and bump the
  matching jsDelivr CDN pin in `phoenix_kit.js` (`@v0.5.5 → @v0.6.5`) so the
  lazy-loaded browser JS is the same version — a stale pin silently serves an
  old `etcher.js` and the new hook never fires. Also bump `credo`
  1.7.18 → 1.7.19 and `owl` 0.13.0 → 0.13.1.

### Fixed
- **V129** migration adds the missing `subscription_type_uuid` UUID column to
  `phoenix_kit_subscriptions`. The column the billing `Subscription` schema uses
  was only ever *renamed* in V65 (`plan_uuid` → `subscription_type_uuid`), never
  added, and `plan_uuid` never existed — so on a fresh `ensure_current/2` build
  the column was absent and every subscription insert / the billing
  Subscriptions LiveView raised `undefined_column`. Idempotent throughout:
  nullable UUID FK to `phoenix_kit_subscription_types(uuid)` `ON DELETE SET NULL`
  plus a partial index, every step guarded.
- AI translation now retries a bare HTTP 429 surfaced as `{:api_error, 429}`
  instead of discarding it on the first attempt. The built-in OpenRouter client
  already maps 429 → `:rate_limited` (snoozed), so this is defense-in-depth for
  a custom/future provider that returns the raw status — 429 is the canonical
  retry-after. Also corrected the worker's `:timeout` retry-clause comment
  (`PhoenixKitAI.Completion` remaps transport timeouts to `:request_timeout`
  before they reach the worker).
- Core `<.select field={...}>` now renders changeset validation errors. The
  component already had the rendering side (`select-error` class + the `<.error>`
  loop) but its `FormField` clause never populated `@errors` from
  `field.errors`, so `<.select>` silently swallowed validation errors while the
  sibling `<.input>` showed them. Mirrors `Input` exactly.

## 1.7.130 - 2026-06-04

### Added
- Generic AI-driven translation pipeline in core, so feature modules plug in
  via a small adapter instead of re-implementing the whole stack:
  - `PhoenixKit.Modules.AI.Translatable` behaviour (`fetch/2`, `source_fields/2`,
    `put_translation/4`, optional `pubsub_topics/1`), exposed by a module via the
    optional `ai_translatables/0` callback on `PhoenixKit.Module` and discovered
    through `PhoenixKit.ModuleRegistry.all_ai_translatables/0` /
    `find_ai_translatable/1`. `resource_type` strings must be globally unique;
    on a collision the first registered module wins.
  - `PhoenixKit.Modules.AI.Translations` orchestration — availability,
    endpoint/prompt defaults, idempotent shared prompt provisioning,
    `enqueue/1` + `enqueue_all_missing/2` (app-level de-dup, fail-open),
    per-resource + global PubSub topics, and `missing_languages/3`.
  - `PhoenixKit.Modules.AI.TranslateWorker` — generic one-job-per-language Oban
    worker: retry classification (transient errors incl. `:timeout` retry, 5xx
    retry, deterministic discards), `{:snooze, 30}` on rate-limit so a burst
    backs off without consuming attempts, and an `ai.translation_added` audit
    entry on success.
- Shared AI-translate UI for multilang form LiveViews:
  - `PhoenixKitWeb.Components.AITranslate` — render-only trigger button, modal
    (endpoint/prompt selectors, scope picker, generate-default-prompt), inline
    progress bar, and a "taking a while, runs in the background" stall hint.
  - `PhoenixKitWeb.Components.AITranslate.{FormGlue,FormBinding}` — the shared
    LiveView state machine (modal events, scope dispatch, live progress, the
    stall timer with a per-arm token guard) behind a 3-callback binding, so a
    consumer wires a tiny adapter + binding and delegates.

### Changed
- AI-translation broadcasts keep translated **content** off broad topics: the
  full payload (with `:fields`) goes only to the per-resource topic the form
  consumes; the global + adapter topics receive a content-free summary, so
  resource text is never fanned out to topics a monitor/dashboard might watch.

### Fixed
- Sanitize the per-user Etcher color palette on both write and read.
  `MediaCanvasViewer` now filters the client-supplied `etcher:colors-changed`
  payload to short, color-shaped strings (deduped, capped at 24) before
  persisting into `custom_fields`, ignoring the event when nothing valid
  survives; `load_user_colors/1` runs the same sanitization on read, so a
  palette stored before the guard shipped — or written by any other path — can
  never reach `<Etcher.layer colors={…}>` untrusted.

## 1.7.129 - 2026-06-03

### Added
- Per-user Etcher color palette in the media viewer. `MediaCanvasViewer`
  passes the user's saved palette to `<Etcher.layer colors={…}>` and
  persists edits from the `etcher:colors-changed` event into the user's
  `custom_fields` ("etcher_colors"), so a user's annotation colors follow
  them across files. Falls back to a default 5-color palette.

### Changed
- Pin the Etcher lazy-load CDN to `v0.5.5` (`phoenix_kit.js`) and the hex
  `etcher` dep to `~> 0.5.5`. 0.5.5 ships the per-user colors API plus the
  reworked annotation toolbar: the color `[⋯]` is an always-visible
  palette-icon hue-picker entry, toolbar overflow splits ~50/50 between
  the tools and the color swatches, undo/redo collapse as a single unit,
  and color slots that don't fit inline appear in the picker popup above
  the presets. The per-user palette **injection** (the `:colors` attr →
  `data-colors`) needs the 0.5.4+ layer component; the picker UI itself
  works from the CDN bump alone.

## 1.7.128 - 2026-06-01

### Added
- Sub-projects and project assignees (core schema support for the
  `phoenix_kit_projects` module). A sub-project is an assignment row that
  points at a child project instead of a task template, so it lives in the
  parent's task timeline with dependencies + drag-reorder for free; a whole
  project (or sub-project) can also be assigned to a Department / Team /
  Person, exactly like a task. The schemas, context, and UI ship in the
  external `phoenix_kit_projects` package — this release adds the migrations.

### Migrations
- **V127** — sub-projects as tasks: adds `child_project_uuid`
  (FK `phoenix_kit_projects(uuid) ON DELETE RESTRICT`) to
  `phoenix_kit_project_assignments`, drops `NOT NULL` on `task_uuid`, and adds
  a `task_uuid`-XOR-`child_project_uuid` CHECK. A partial UNIQUE index on
  `(child_project_uuid) WHERE NOT NULL` enforces one parent per child and also
  serves child-link lookups (an equality predicate implies `IS NOT NULL`).
- **V128** — assignee on projects (and sub-projects): adds
  `assigned_team_uuid` / `assigned_department_uuid` / `assigned_person_uuid`
  (FKs to the staff tables, `ON DELETE SET NULL`) to `phoenix_kit_projects`
  with a `num_nonnulls(...) <= 1` single-assignee CHECK + a partial index per
  FK. `@current_version` → 128.

### Fixed
- Notifications kill-switch (`Notifications.enabled?/0`) reads the setting
  uncached again. The `:settings` cache is node-local with no cross-node
  invalidation or TTL, so a cached read let a disable on one node go unseen on
  others until restart; the uncached read keeps the switch immediate and
  cluster-wide.
- `Notifications.admin_stats/0` now runs a single
  `count(...) FILTER (WHERE ...)` query (one table scan) instead of three
  separate `COUNT(*)` aggregates, and `get_config/0` skips it entirely when the
  module is disabled — it's called for every module on each Modules-page render.

## 1.7.127 - 2026-06-01

### Added
- Standalone notifications — a notification no longer has to come from an
  activity. `PhoenixKit.Notifications.create/1` inserts an
  activity-less notification carrying its own display content:

      Notifications.create(%{
        recipient_uuid: user.uuid,
        text: "Your export is ready.",
        icon: "hero-arrow-down-tray",
        link: "/exports/123"
      })

  `:text` / `:icon` / `:link` fold into a new `metadata` JSONB column as
  the `notification_text` / `notification_icon` / `notification_link`
  keys `Render` already honors; `Render` reads them off the notification
  itself when there's no activity. Honors the `notifications_enabled`
  kill-switch.
- `Notifications.create/1` takes an optional `:type` (notification type
  key) or `:action` (action string) to opt the standalone send into the
  recipient's per-type **preference filter** (fail-open) — omit both for
  an unconditional app-driven send.
- `Notifications.create_many/2` — the multi-recipient fan-out primitive:
  one standalone notification per recipient uuid (caller supplies the
  list, e.g. an author's followers), de-duped, each filtered
  independently by `:type`/`:action` prefs. Returns `{:ok, created_count}`.
- `Notifications.Prefs.user_wants_type?/2` — type-keyed preference check
  (vs the action-keyed `user_wants?/2`), backing the `:type` filter above.
- Notifications is now a toggleable core **module** (`use PhoenixKit.Module`):
  it appears as a card on the admin Modules page (enable/disable flips the
  existing `notifications_enabled` kill-switch) and contributes a
  `/admin/notifications` overview page + admin nav tab. The overview is a
  simple read-only page — enabled state, retention window, and aggregate
  counts (total / unread / dismissed via `Notifications.admin_stats/0`).
- The `NotificationsBell` (sticky nested LiveView) is now embedded in the
  admin header, to the right of the theme switcher — shown only when the
  Notifications module is enabled and a user is logged in. `app_layout`
  gained an optional `socket` attr (threaded from the admin call sites +
  `admin.html.heex`); the bell renders via `live_render(@socket, …)` and
  isn't rendered when no socket is threaded (e.g. public/auth pages).

### Migrations
- **V126** — `phoenix_kit_notifications.activity_uuid` is now nullable
  (standalone notifications) and a `metadata JSONB NOT NULL DEFAULT '{}'`
  column is added. The `(activity_uuid, recipient_uuid)` unique index
  still holds (Postgres treats NULLs as distinct). `@current_version` → 126.

## 1.7.126 - 2026-05-30

### Added
- `MediaBrowser.Embed` gains an opt-in `url_sync` option so any embedding
  LiveView gets shareable, deep-linkable folder URLs with one line:

      use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: true
      # or, for a non-default component id / multiple browsers:
      use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "my-browser"]

  It provides the full controlled-mode round-trip the host previously had
  to hand-write (~50 lines), via LiveView lifecycle hooks attached in
  `on_mount` (not injected `handle_params`/`handle_info` clauses) so it
  **composes with a host that already defines its own** — e.g. an
  `…/orders/:id/edit/files` page that loads the order in its own
  `handle_params`. `on_mount` parses `:initial_params` from the URL, a
  `:handle_params` hook feeds them to the component, and a `:handle_info`
  hook intercepts the component's `{:navigate, …}` and `push_patch`es
  folder / search / page / view onto the current path (every existing
  segment — locale, parent ids, sub-tab — preserved). Folder is tracked
  by uuid (stable across renames; unknown/out-of-scope falls back to
  root); base path is taken from the live URL so router prefixes are
  respected. Reusable `parse_nav_params/1` + `build_nav_query/1` helpers
  are public. The host template passes `on_navigate={:navigate}` +
  `initial_params={@initial_params}`. A `push_patch` issued from a
  `handle_info` hook makes LiveView call `view.handle_params/3`
  unconditionally, so the macro injects a trivial `handle_params/3` stub
  when (and only when) the host defines none — a host with its own keeps
  it. (Note: changing the macro requires recompiling the host;
  `mix deps.compile phoenix_kit --force` in a parent app after updating.)
  The `:handle_params` hook only re-syncs the component when the parsed
  folder / search / page / view actually changed, so unrelated host
  navigation on a multi-purpose page doesn't trigger a needless reload.
- Installer: the `catalogue_pdf` Oban queue (concurrency 2) is now added
  to the host Oban config on `mix phoenix_kit.install` /
  `mix phoenix_kit.update` (and to the fresh-install default queues).
  `phoenix_kit_catalogue` enqueues a `:catalogue_pdf` job per uploaded PDF
  (`pdfinfo` + `pdftotext` text extraction); Oban only runs listed queues,
  so without this entry the jobs sat `available` forever — uploads looked
  fine but text search silently never worked. Added unconditionally (an
  idle queue costs nothing) so a host that later adds the catalogue module
  is already wired.

### Changed
- `/admin/media` (`Live.Users.Media`) now uses `url_sync` instead of its
  bespoke `handle_params`/`handle_info`/`initial_params` plumbing —
  behavior unchanged, ~45 lines lighter.
- MediaBrowser Move modal: the destination picker is now a collapsible
  directory tree (chevron expand/collapse + colored folder icons),
  matching the left-sidebar experience, instead of a flat fully-expanded
  dump of every folder in the project. It **opens seeded from the
  sidebar's current expansion** (`expanded_folders`), so the picker shows
  the same open directories you already see on the left, then tracks its
  own `move_expanded` independently (drilling in the picker doesn't move
  the sidebar). The picker is a plain full-width `<ul>` (not a daisyUI
  `menu`, which laid the custom tree rows out horizontally and spilled
  past the box); names truncate and horizontal overflow is clipped so it
  fits the modal.

### Fixed
- MediaBrowser: the grid/list view toggle and the item count no longer
  vanish in an empty folder (or a folder that has subfolders but no
  files). They were gated on `@total_count > 0` (file count only); now
  shown whenever there are files, folders, or you're inside a folder.
- `<.pagination_info>` renders "No results" at `total_count == 0` instead
  of the nonsensical "Showing 1 to 0 results".
- MediaBrowser: the bulk **Move** button is disabled in Select Mode until
  at least one item is selected (matching the Download/Delete actions,
  which already hide with an empty selection). The `show_move_modal`
  handler is guarded too, so it can't open an empty modal.

### Migrations
- **V125** — project workflow statuses (entities-backed, cement-at-start).
  New `phoenix_kit_project_statuses` table (the cemented per-project status
  snapshot: `project_uuid` FK `ON DELETE CASCADE`, `label` / `slug` /
  `position`, `data` + `translations` JSONB, `source_entity_data_uuid`
  provenance with no FK; index on `(project_uuid)`, unique on
  `(project_uuid, slug)`). New columns on `phoenix_kit_projects`:
  `status_entity_uuid` (FK → `phoenix_kit_entities` `ON DELETE SET NULL`),
  `current_status_slug`, a generic `settings` JSONB, and a free-form
  `external_id VARCHAR(255)` for tying a project to an external system
  (not unique, not an FK; partial-indexed `WHERE NOT NULL`, set
  programmatically). Idempotent; `down/0` reverses to 124.
  `@current_version` is now 125.

## 1.7.125 - 2026-05-29

### Fixed
- `<.load_more infinite>` no longer over-fetches or wedges. The
  `InfiniteScroll` JS hook now re-fires only when its `data-cursor`
  changes (not on every unrelated LiveView diff), guards against stacked
  in-flight pushes, and carries a 2s watchdog so a load that resolves
  without advancing the cursor (empty/no-op page, stale `total`, or a
  replace-in-place list with a constant `loaded`) can never permanently
  disable auto-scroll — worst case is a brief stall that the next scroll
  or the manual button recovers.
- `MediaBrowser.Embed`'s injected `:leaf_changed` forwarder no longer
  crashes the host LiveView if `PhoenixKitComments.Web.CommentsComponent.forward_leaf_event/2`
  returns an unexpected value — an `other ->` branch logs a warning and
  degrades to `{:noreply, socket}`.
- Inline annotation-title edits from the comments sidebar now log a
  `Logger.warning` when the underlying `Annotations.update/2` write fails
  (previously the error was discarded, making a failed write
  indistinguishable from a no-op). UX is unchanged — still no flash.

### Changed
- `<.load_more>`: in `infinite` mode, `data-cursor` defaults to `@loaded`
  (so most callers can omit `cursor`), and the component raises a clear
  `ArgumentError` when `infinite` is set without an `id`. `resolve_cursor/1`
  is now nil/type-safe and computed only for the infinite variant.
- Bump the lazy-load `etcher` CDN pin in `phoenix_kit.js` `v0.5.2 → v0.5.3`
  to match the resolved `etcher` hex dependency.


### Merged
- Merged upstream `dev`, which added **V122** (`phoenix_kit_location_spaces`
  + staff `translations` JSONB + staff `Person.name`) and **V123**
  (catalogue folders: `phoenix_kit_cat_folders` + `cat_catalogues.folder_uuid`),
  plus the `<.load_more>` infinite-scroll option.

### Migrations
- **V124** — the media-folder partial unique index (previously authored
  as V122 on this fork) is **renumbered to V124** because upstream
  claimed V122/V123. Content is unchanged: restricts
  `phoenix_kit_media_folders_name_parent_idx` to `WHERE trashed_at IS NULL`.
  `@current_version` is now 124.

## 1.7.123 - 2026-05-29

### Added
- `/admin/media/:file_uuid` (MediaDetail) now renders the image through
  the Fresco canvas + Etcher annotation layer instead of a plain
  `<img>`, reaching parity with the in-place modal: draw / edit / delete
  annotations, the composer popover, and persistence all work on the
  standalone page. Implemented via a new `viewer_only` mode on
  `MediaCanvasViewer` that suppresses its close button + sidebar so a
  page host can supply its own chrome.
- A comments thread (annotation-aware) on MediaDetail, above the Storage
  Locations card — mirrors the modal sidebar's embed. Promotes
  `MediaCanvasViewer.load_annotations_for/1`,
  `build_comment_decorations/1`, and `comments_enabled?/0` to public so
  page hosts reuse them.

### Changed
- Bump leaf 0.2.20 → 0.2.21 (hex dep + `phoenix_kit.js` CDN pin).

### Fixed
- MediaDetail's embedded canvas now receives the file's intrinsic
  `width` / `height`, so the Fresco canvas matches the source image
  aspect instead of falling back to a 1000×1000 square (which letterboxed
  the image and stranded annotations on the dotted background).

## 1.7.122 - 2026-05-28

### Fixed
- `pagination_info` drops the redundant `of N` suffix when the result set
  fits on one page (`total_count <= per_page`) — e.g. "Showing 1 to 4
  results" instead of "Showing 1 to 4 of 4 results". The media browser
  toolbar reads cleaner; multi-page views are unchanged.
- New folder creation at the root of a scoped media browser no longer fails
  silently when a trashed "untitled" folder still occupies the unique
  index slot. V124 restricts `phoenix_kit_media_folders_name_parent_idx`
  to `WHERE trashed_at IS NULL`, so trashed folders no longer reserve
  names from the user's perspective.
- `MediaBrowser.Embed` now forwards `{:leaf_changed, _}` events from
  sidebar comment Leaf editors to `PhoenixKitComments.Web.CommentsComponent`
  via runtime `Code.ensure_loaded?` + `apply/3` (sibling deps with no
  compile-order guarantee). Without this, typed content in those editors
  never reached the server. User-defined `:leaf_changed` clauses still win
  because the injected clause is appended last.

### Changed
- The inline rename input for the auto-created "untitled" folder now
  selects all of its value on mount instead of just focusing — type
  immediately replaces the placeholder name without reaching for the
  mouse. Implemented via a new tiny `SelectOnMount` JS hook in
  `phoenix_kit.js` (reusable for any "type-to-replace" inline edit).

### Migrations
- **V124** — `phoenix_kit_media_folders_name_parent_idx` is now a partial
  unique index `WHERE trashed_at IS NULL`. Active siblings are the only
  rows the constraint sees, matching what `Storage.list_folders/2`
  returns. (Renumbered from V122 after the upstream merge — see 1.7.124.)

## 1.7.121 - 2026-05-25

### Added
- Core list-UI toolkit for admin tables, all in
  `lib/phoenix_kit_web/components/core/` (PR #568):
  - `BulkSelect` — `<.bulk_select_scope>` + `<.bulk_select_header_cell>` +
    `<.bulk_select_cell>` + `<.bulk_actions_toolbar>`. Selection lives
    client-side via the `BulkSelectScope` JS hook (per-checkbox toggles feel
    instant — no LV round-trip); the server only receives the selected uuids
    at action time as `%{"uuids" => [...]}`. The selection survives LV
    re-renders (reorder / load_more / sort).
  - `Sortable` — `<.sortable_tbody>` + `<.sortable_row>` wrap the
    `SortableGrid` hook wiring; `enabled={false}` cleanly omits the hook so
    drag turns off when sorting by a non-position field. Pair with
    `<.drag_handle_cell>` / `<.drag_handle_header_cell>` on `<.table_default>`.
  - `<.reorder_modal>` — strategy-picker dialog for bulk reorder; the consumer
    LV owns the strategy whitelist.
  - `<.load_more>` pagination footer (in `core/pagination.ex`) for embeddable /
    DnD-aware lists where rows append rather than navigate away.
- `<.modal keep_in_dom>` mode — renders the `<dialog>` regardless of `@show`
  and flips visibility via `data-show` + the `PkDialog` hook, enabling instant
  client-side open without a server round-trip (PR #568).
- `PhoenixKit.boot/1` hook so late-loaded modules can register after app start
  (PR #569).

### Changed
- `<.modal>` now renders a native `<dialog>` in the browser top layer
  (`PkDialog` hook + `showModal()`) instead of `<div class="modal">`. It is
  immune to ancestor stacking contexts / z-index and covers the full visual
  viewport (PR #568).
- `<.sort_selector>` is now race-free: the field select sends only `sort_by`
  and the direction arrow sends only `sort_dir`; the LV handler derives the
  missing half from assigns. Manual-order mode hides the direction toggle
  entirely (PR #568).
- `<.table_default>` rows carry a named `group/row` Tailwind marker (not a bare
  `group`) so the drag-handle hide-until-hover reveal stays keyed to row hover
  without clobbering unnamed `group-hover:` utilities nested in cells (PR #568).
- Activity feed renders dates with locale-aware formatting (PR #569).
- `redirect_invalid_locale/2` reads `prefixless_primary?()` once instead of
  twice, removing a torn-read window on a concurrent setting flip
  (PR #554 follow-up).
- Annotation storage adapter no longer accepts `:creator_uuid` from event
  payloads — authorship is resolved server-side from the actor, so a forged
  payload can't claim it (PR #550 follow-up).

### Fixed
- PkDialog top-layer leak: a `<dialog>` opened via `showModal()` stayed in the
  top layer (still capturing all clicks) after Phoenix LV's DOM patcher
  stripped the browser-added `open` attribute on re-render, while CSS rendered
  it `display: none` — visually closed but blocking the rest of the page.
  `PkDialog` now uses the `:modal` pseudo-class as the truth source and
  restores the stripped attribute before `close()` (PR #568).
- The "Reorder N selected" bulk-toolbar label was rendered untranslated: it
  used `gettext_noop/1` (extraction-only) and the JS hook does no translation,
  so it stayed English in every non-default locale. Now translated at render
  time while preserving the `%{count}` placeholder for client-side interpolation
  (PR #568 post-merge review).
- `<.drag_handle_cell>`'s default title now renders (the `default: nil` attr was
  shadowing `assign_new`) (PR #568).
- Registration and magic-link registration fieldsets unified to
  `class="fieldset min-w-0"` (dropped redundant `w-full`) (PR #559 follow-up).
- Combined the split revoke-all-sessions confirmation sentence into one
  translatable string (PR #569).
- Guard `stat.label` against non-binary values in the modules overview
  (PR #569).

### i18n
- Broad i18n coverage sweep across the user-facing admin pages — Users
  management, Session management, Live Sessions, User Settings, the General
  settings sidebar tab, and the Modules overview — with ru/et catalogs brought
  back to 100% and fuzzy msgids / mistranslations corrected (PR #569).
- Translate the stranded "Last updated:" label in Live Sessions (PR #569).

## 1.7.120 - 2026-05-24

### Changed
- Ecommerce admin i18n is now owned by the `phoenix_kit_ecommerce` module
  instead of PhoenixKit core. The `PhoenixKitWeb.EcommerceGettextManifest` shim
  that re-emitted ecommerce strings into core's POT for extraction is gone, and
  ~1,750 ecommerce-only msgids are dropped from `default.pot` and every locale
  catalog — ecommerce translations now live in the module's own gettext (PR #567).
- Dependency bump: `etcher` 0.4.9 → 0.4.10.

### Removed
- `PhoenixKitWeb.EcommerceGettextManifest` — ecommerce translation extraction
  moved into the `phoenix_kit_ecommerce` module (PR #567).

### Fixed
- Mobile horizontal overflow on card surfaces. `PhoenixKitWeb.Components.Core.ModuleCard`
  and the `TableDefault` card views are now shrink-safe — `min-w-0` + `break-words`
  on the flex/grid children keep a long unbreakable token (email, username) from
  forcing a card wider than its grid track — and the module admin-links row wraps
  via `flex-wrap` instead of overflowing (PR #567).

### i18n
- Completed `ru` / `et` translations for newly-extracted core strings
  (sort-selector direction tooltips, "URL Behavior" language settings, annotation
  toolbar hint), restoring both locales to 100%.
- Fixed fuzzy msgids and `ru` / `et` mistranslations swept in by the ecommerce
  i18n extract (PR #567).

## 1.7.119 - 2026-05-22

### Changed
- `PhoenixKitWeb.Components.Core.TableDefault` — `:class` attr widened from
  `:string` to `:any` on all 7 `table_default*` components, so the
  Phoenix-idiomatic `class={[if(...), ...]}` list form compiles without an attr
  warning. The components already wrap `@class` in a flattened list, so there is
  no rendered-output change for existing string callers (PR #565).
- `PhoenixKitWeb.Components.MultilangForm` — the standalone info alert is now a
  hover/focus tooltip on an info icon beside the "Content Language" header, and
  the default loading skeleton uses `bg-base-content/15 animate-pulse` instead of
  daisyUI's near-invisible `.skeleton`, so the loading state is visible on
  `bg-base-100` cards (PR #565).
- `Translation.handle_ai_response/2` extracts the OpenAI-shaped completion
  content inline rather than via `PhoenixKitAI.Completion.extract_content/1`,
  dropping the cross-module dependency on the optional AI plugin — works whether
  the plugin is present, absent, or stubbed (PR #565).
- Dependency bumps: `etcher` 0.4.8 → 0.4.9, `fresco` 0.5.5 → 0.5.8,
  `floki` 0.38.2 → 0.38.3.

### Fixed
- AI translation parser no longer leaks an unrequested marker's content into the
  preceding field. A field capture now terminates at any line-anchored
  `\n---<NAME>---` marker, not just the requested-field markers — so a model
  emitting an extra `---TITLE---` (e.g. from an unbound `{{title}}` template
  variable) no longer rolls that block into the prior `---NAME---` field. The
  newline anchor keeps literal mid-paragraph `---WORD---` tokens (technical docs,
  API examples) inside the capture (PR #565).
- AI translation empty sections resolve consistently to `""`. A present-but-empty
  trailing marker now records `""` instead of failing the whole response with
  `{:parse_error, {:missing_fields, ...}}`, matching how an empty middle section
  already resolved. A genuinely absent marker still reports `missing_fields`, so
  the "model forgot a marker" signal is preserved (follow-up to PR #565).

## 1.7.118 - 2026-05-21

### Added
- `card_grid_class` attr on `PhoenixKitWeb.Components.Core.TableDefault` —
  overrides the card-view grid layout (column density, gaps) without touching
  the component. Default unchanged. Must be layout-only (no `display` utility —
  the component sets `grid`/`hidden` per view-mode branch) and a literal in a
  Tailwind-scanned source so the classes compile (PR #561).
- Responsive `cols` on `PhoenixKitWeb.Components.Core.DraggableList` (and the
  `MediaGallery` passthrough) — `:cols` now accepts a string of Tailwind
  grid-column classes (e.g. `"grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"`) for a
  responsive thumbnail grid, in addition to an integer 1..6. Any other value
  (out-of-range integer, atom, …) falls back to `grid-cols-4` (PR #561).

### Changed
- `MediaGallery` now hides the Add tile entirely once the selection reaches
  `max_count` (or 1 in `:single` mode), instead of rendering it disabled and
  greyed. Supersedes the disable-at-limit behavior shipped in 1.7.117 (PR #561).
- Magic-link registration request sends the email via `start_async`, so the
  submit is non-blocking and the in-flight spinner renders, matching the
  password-less magic-link login flow. Replaces the prior `phx-disable-with`
  (follow-up to PR #559).
- Dependency bumps: `etcher` 0.4.6 → 0.4.8, `fresco` 0.5.4 → 0.5.5,
  `ex_doc` 0.40.2 → 0.40.3.

### Fixed
- AI translation no longer fails on every real request.
  `Translation.translate_fields/6` was treating `PhoenixKitAI.ask_with_prompt/4`'s
  OpenAI-shaped response map (`%{"choices" => [...]}`) as `:unexpected_response`
  and erroring out. The success branch now routes map responses through
  `PhoenixKitAI.Completion.extract_content/1` (the helper publishing's
  `TranslatePostWorker` already uses), with a raw-binary fallback so test stubs
  and older plugin versions keep working (PR #560).
- `Translation.translate_fields/6` rejects an empty `fields` map up front with
  `{:error, {:parse_error, :no_markers}}` instead of rendering a field-less
  prompt and spending an AI request that only fails downstream in the parser
  (PR #558).
- Auth-form submit buttons no longer overflow their card.
  `<fieldset>`'s browser-default `min-width: min-content` let the fieldset — and
  its `w-full` submit button — grow past the form width; `min-w-0` is now applied
  to the six remaining auth-form fieldsets. Also dropped `phx-disable-with` on
  the magic-link login form, where it collided with the `@loading` branch and
  made LiveView's diff merger inject a stray SVG into the button (PR #559).

## 1.7.117 - 2026-05-21

### Added
- `PhoenixKit.Modules.AI` — core-side conveniences for the optional
  `PhoenixKitAI` plugin. `available?/0` is a module-loadability check (loaded
  AND exports `ask_with_prompt/4`); gate AI-driven UI on it so apps without the
  plugin fall back to non-AI behavior automatically (PR #557).
- `PhoenixKit.Modules.AI.Translation` — shared AI-translation orchestration
  reused by every feature module that wants AI translation. `translate_fields/6`
  takes a `%{field_name => text}` map and returns the same shape, or a
  normalized `{:error, atom_or_tuple}` covering every failure mode (missing
  endpoint/prompt, plugin absent, duplicate/partial markers, AI exception/exit).
  `parse_response/2` is the public, case-insensitive `---FIELD_NAME---` parser.
  Each dispatch writes one `core.ai_translation.requested` activity entry for a
  unified token-spend audit trail (PR #557).
- `ai_translate` attr on `LanguageSwitcher.language_switcher_dropdown` — opt-in
  affordance that renders a per-missing-language sparkle button plus a bulk
  "translate all missing" CTA. The component is pure event-emit (no
  `PhoenixKitAI` reference): it fires the host's `phx-click` event and the host
  enqueues its own translation worker. `nil`/`enabled: false` = today's behavior
  (PR #557).
- `max_count` attr on `PhoenixKitWeb.Components.MediaGallery` — caps the number
  of selected images in `:multiple` mode and disables the Add button at the
  limit (defence-in-depth: `apply_selection` also clamps). `nil` = unlimited;
  `:single` mode implies a limit of 1 (PR #556).
- `card_media` slot on `PhoenixKitWeb.Components.Core.TableDefault` — optional
  media region (thumbnail / cover image / document preview) rendered above the
  card body in card view; the slot owns its own padding/background (PR #556).
- Controlled `view_mode` (+ `view_event`) on `TableDefault` — pass
  `view_mode="card"|"table"` to take the card⇄table toggle from assigns instead
  of the default JS hook + localStorage. The component then renders only that
  view and the toolbar buttons emit `view_event` with `phx-value-mode`, so the
  view choice can be URL-backed (`push_patch`) or survive LV navigation (PR #556).
- `class` attr on `TableDefault.table_default_header` — override the header
  styling per call site (PR #556).

### Changed
- `TableDefault.table_default_header` default changed from
  `bg-primary text-primary-content` to `bg-base-300` — a calmer, theme-neutral
  header that reads as a subtle separator from `<tbody>`. This affects every
  `<.table_default_header>` that does not pass an explicit `class`. Pass
  `class="bg-primary text-primary-content"` to restore the previous look, or
  `class=""` for a bare header (PR #556).
- `MediaGallery` in `:single` mode now disables the Add button once an image is
  selected; replace the image via the per-thumbnail Remove (✕) then Add. The
  selection cap of 1 is unchanged (PR #556).

## 1.7.116 - 2026-05-20

### Added
- `Languages.prefixless_primary_safe?/0` — boot- and mix-task-safe wrapper
  around `default_language_no_prefix?/0`. Returns `false` during mix-task
  context (via the same `:phoenix_kit_config_status` sentinel `Routes.path/1`
  uses) and rescues any other lookup exception to `false`. Use from
  boot/middleware contexts where the Settings table may not be reachable;
  `default_language_no_prefix?/0` remains the runtime entry point.
  `Routes.path/1` and `PhoenixKitWeb.Users.Auth` now both delegate to this
  canonical implementation (PR #554).
- `PhoenixKit.Modules.Sitemap.LocalePath` — shared `emit_prefix?/2`
  decision rule for the three sitemap sources (`publishing`, `static`,
  `posts`). Each source still owns its segment formatting (display code
  with hreflang awareness for publishing, base code for static + posts);
  the module owns only the decision so the policy stays consistent across
  sources (PR #554).
- `DialectMapper.group_dialects_by_base/1` — counts sibling dialects per
  base language code. Used by the language switcher and admin/user nav
  dropdowns to decide whether to show a country qualifier (PR #555).
- `LanguageSwitcher.dedupe_names/1` + `extract_base_language_name/1` —
  public helpers called from `AdminNav` and `UserDashboardNav` so all
  language menus share one country-qualifier dedup rule (PR #555).

### Changed
- Frontend language switcher (`PhoenixKitWeb.Components.Core.LanguageSwitcher`'s
  dropdown + continent-grouped views) now drops the country qualifier from
  rendered labels when only one dialect of a given base language is enabled.
  `English (United States)`, `Estonian (Estonia)`, `French (France)` render
  as `English`, `Estonian`, `French` whenever no sibling dialect is
  configured; enabling a second dialect of the same base (e.g. `en-US` +
  `en-GB`) causes those entries to reacquire the country qualifier so they
  remain distinguishable. Same rule applies in the admin top-bar dropdown
  and user dashboard nav. Continent-grouped views compute sibling counts
  globally across all enabled languages, so a base split across continents
  keeps its qualifier in both groups. Restores the bare-label rendering
  that was lost when commit `d1c2d577` rewrote the switcher to
  one-row-per-dialect (PR #555).
- Sitemap sources `publishing`, `static`, and `posts` share one
  `LocalePath.emit_prefix?/2` decision rule instead of three byte-identical
  copies; three near-identical private `single_language_mode?/0` helpers
  collapse into one defensive lookup on `LocalePath` (PR #554).
- `redirect_invalid_locale/2` honors the site-wide
  `default_language_no_prefix` setting. With the setting OFF (default), an
  invalid locale segment is swapped for the primary base code so the
  redirect lands on the canonical prefixed shape; with the setting ON, the
  segment is stripped entirely. Previously the plug always emitted the
  prefixless shape, which was inconsistent with how the rest of the app
  emits primary-language URLs when the setting is OFF (PR #554).
- Dependency bumps: `etcher` 0.3.0 → 0.4.0, `fresco` 0.5.2 → 0.5.3.

### Fixed
- Login (and any other primary-language POST) no longer fails with the
  default `default_language_no_prefix` setting. `process_valid_locale/2`
  was unconditionally 301-redirecting `/<default>/...` → `/...` for
  non-admin requests, discarding the POST body. The redirect is now gated
  on `Languages.prefixless_primary_safe?/0` so the canonical primary shape
  matches whichever setting state the site is in (PR #554).
- Sitemap sources `static.ex` and `posts.ex` honor the site-wide
  `default_language_no_prefix` setting for the primary language. Both had
  the same `_is_default` ignored bug that PR #552 fixed in the publishing
  source — they previously emitted `/en/about` and `/en/blog/post` in
  multilang mode regardless of the setting (PR #554).

## 1.7.115 - 2026-05-19

### Added
- Site-wide `default_language_no_prefix` setting on the Languages admin page
  (`/admin/settings/languages`) controls whether the primary language emits
  its locale segment in URLs. When on, `/admin/users` and `/blog/post`
  replace `/en/admin/users` and `/en/blog/post` across admin pages, public
  pages, sitemap, and redirects; other languages always keep their prefix.
  Default is off, matching the historical publishing default, so existing
  installs' indexed URLs stay stable on upgrade. Installs that previously
  toggled `publishing_default_language_no_prefix` get auto-migrated to the
  new key on the next boot via `Languages.migrate_legacy/0` (PR #552).
- `@type t/0` on `PhoenixKit.Settings.Setting` schema. Lets consumers spec
  setting-returning functions (`{:ok, Settings.Setting.t()} | {:error, …}`)
  without tripping dialyzer's `unknown_type` warning.

### Changed
- Admin URL emission for the primary language now follows the new site-wide
  `default_language_no_prefix` setting (default off), restoring the
  `/en/admin/users` shape that 1.7.114 had emitted prefixless
  unconditionally. Both URL shapes still resolve at the router level via the
  dual-scope admin emission, so existing bookmarks and external links keep
  working (PR #552).
- Dependency bumps: `ecto` 3.13.6 → 3.14.0, `ecto_sql` 3.13.5 → 3.14.0,
  `fresco` 0.5.0 → 0.5.2, `hammer` 7.3.0 → 7.4.0.

### Fixed
- Publishing sitemap honors `default_language_no_prefix` for the primary
  language. Previously the sitemap always emitted `/en/blog/post` in
  multilang mode regardless of the setting, drifting away from the URLs
  publishing actually served at request time (PR #552).
- `Languages.default_language_no_prefix?/0` docstring no longer references
  the nonexistent `PhoenixKit.Migration.migrate_default_language_no_prefix/0`
  — points at the real entry point `migrate_legacy/0`.
- `Routes.admin_path/2` `## Examples` no longer mixes setting-dependent
  cases with deterministic ones inside `iex>` doctest prompts, so adding
  `doctest PhoenixKit.Utils.Routes` later won't fail. Setting-dependent
  shapes are still shown, just outside the executable doctest block.

## 1.7.114 - 2026-05-19

### Added
- `module_assigns` attribute on `LayoutWrapper.app_layout` — a single map
  whose keys are merged into the assigns passed to a host's parent layout,
  letting feature modules thread arbitrary host-consumable data (e.g.
  `phoenix_kit_publishing_translations`) across the layout boundary without
  core having to declare each key (PR #551).

### Changed
- Locale resolution is now URL-authoritative. The `phoenix_kit_locale_base`
  session value and `user.custom_fields["preferred_locale"]` are no longer
  read for routing — the URL's locale segment (or its absence) is the only
  source of truth across both the LiveView mount and the HTTP plug. Fixes a
  sticky-locale bug where visiting one locale-prefixed URL pinned that locale
  onto every later prefixless URL (PR #551).
- Admin URLs drop the locale segment for the primary language, matching
  non-admin behaviour. Both `/<prefix>/admin/*` and
  `/<prefix>/:locale/admin/*` remain routable, so legacy prefixed links keep
  working (PR #551).
- Admin, public, and authenticated-dashboard LiveView routes are each served
  from a single unified `live_session` (`:phoenix_kit_admin`,
  `:phoenix_kit_public`, `:phoenix_kit_authenticated`) spanning both the
  primary-language (`/<prefix>/...`) and locale-prefixed
  (`/<prefix>/:locale/...`) URL shapes. Switching locale now stays on the
  WebSocket via `push_navigate` instead of forcing a full-page reload —
  previously each surface was split across two sessions and every locale
  change crossed a `live_session` boundary.
- `DialectMapper.resolve_dialect/2` collapsed to `resolve_dialect/1`: dialect
  resolution is URL-driven and no longer consults a user's
  `custom_fields["preferred_locale"]`. Removed the now-unused
  `User.preferred_locale_changeset/2` and `User.get_preferred_locale/1`.

### Fixed
- Table RowMenu dropdown is portaled to `<body>` while open so its
  `position: fixed` coordinates escape any `<dialog>` or `transform`/`contain`
  containing block — previously the menu could render far off-screen inside
  modals (PR #551). It also no longer leaves a duplicate menu element behind
  when a server-side LiveView update re-renders the row while the menu is
  open.
- Publishing route dispatch threads the workspace `url_prefix`, so it keeps
  working when PhoenixKit is mounted under a non-root path (PR #551).

## 1.7.113 - 2026-05-18

### Added
- `line` annotation kind — a two-endpoint line tool alongside `dimension`
  (same geometry, no arrowheads, no inline numeric label). V121 migration
  widens the `phoenix_kit_annotations_kind_check` constraint to accept it.
- `PhoenixKitWeb.Components.MediaCanvasViewer` — shared LiveComponent owning
  the per-file canvas + Etcher annotation layer + composer popover + comments
  thread. Embedded by both `MediaBrowser` and `MediaViewer`, so files opened
  via `MediaGallery` → `MediaViewer` get the full pan/zoom + annotation
  experience (PR #550).
- `Storage.folder_subtree_uuids/1` is now public — walks a folder tree and
  returns every descendant uuid including the root (PR #549).

### Changed
- `MediaBrowser` migrated to Etcher 0.3 + Fresco 0.5: per-op annotation events
  collapse into a single bulk `etcher:annotations-changed` diff; `fresco` and
  `etcher` deps flipped from local path deps to hex pins (`~> 0.5` / `~> 0.3`)
  (PR #550).
- Annotation composer now positions itself above its shape and drops the
  shape entirely when dismissed via Cancel (PR #550).
- Deleting an annotation now hard-deletes its linked comments instead of
  leaving `[removed]` placeholders in the file's thread (PR #550).
- Activity and Users/Sessions filter panels relocated into the
  `<.table_default>` toolbar row; tables render unconditionally with the
  empty state as a table-body row so filters/search stay visible on a
  zero-result filter (PR #549).

### Fixed
- Users/Sessions search regression — form-less `<input>`s no longer delivered
  `phx-change`; search inputs are wrapped in `<form phx-change="search">`
  again (PR #549).
- Folder-scoped media picker now includes images in nested subfolders, not
  just files directly in the scope folder (PR #549).
- V120 migration tolerates a missing `phoenix_kit_doc_template_presets` table
  on hosts that never installed the Document Creator module — the index
  rebuild is guarded on table existence (PR #550).
- V121 migration adds the kind-check constraint unconditionally after
  `DROP CONSTRAINT IF EXISTS`; the previous `pg_constraint` existence guard
  was not schema-scoped and would skip the add on multi-prefix installs.
- Annotation updates no longer cast `:uuid`, closing a path where a stray
  payload uuid could rewrite an annotation's primary key.
- `MediaCanvasViewer` annotation sync skips no-op `UPDATE`s — Etcher
  re-broadcasts the full annotation list on every mutation, so untouched
  rows are now diffed out and a zero-net-change re-broadcast does no DB work.
- Users role-filter dropdown reflects the active filter again (`<option
  selected>` instead of an ignored `<select value>`); the empty-state
  "Clear Filters" button resets all filters via a dedicated handler.
- Activity empty state distinguishes "No activities match the current
  filters" from "No activities recorded yet".

## 1.7.112 - 2026-05-18

### Added
- `PhoenixKitWeb.Components.MediaGallery` — reusable LiveComponent for selecting,
  ordering, previewing and removing a set of images.
- `PhoenixKitWeb.Components.MediaViewer` — standalone image lightbox LiveComponent
  (prev/next, keyboard, download). Extracted from `MediaGallery`; usable independently.
- `Storage.get_files/1` — batch file fetch preserving input order.
- `FolderExplorer` component — folder tree extracted from `MediaBrowser` as a
  reusable component (PR #544).
- `<.table_default>` sort + drag-to-reorder primitives (PR #548)
  - New `:sort_bar` slot rendered above the toolbar, visible in both card and table views.
  - `<.table_default_body>` accepts `:global` attrs so consumers can wire the
    `SortableGrid` hook (`phx-hook`, `data-sortable-*`) directly onto `<tbody>`.
  - `<.table_default_header_cell>` `:inner_block` is now optional — empty `<th>`
    cells for drag-handle / selection columns no longer need a placeholder.
  - `:card_body` slot for fully-custom card content; `:card_class` accepts a string
    or `(item) -> string` function; `:above_cards` slot; `2xl:grid-cols-4` card grid.
- `<.sort_selector>` core component — field-picker select + direction toggle, with a
  `manual_field` mode that swaps the toggle for a drag-handle hint (PR #548).
- `<.bulk_actions_bar>` core component — selection counter + action-button slot +
  Clear button; `wrapper_class` covers the inline-card and sticky/blurred shapes (PR #548).
- `<.empty_state>` core component — `compact` / `card` / `featured` "no rows" panels
  with optional icon, description, and CTA slot (PR #548).
- `<.form_section>` and `<.form_actions>` core components — card-wrapped titled form
  sections and a Cancel + Submit footer bar (PR #548).
- New `PhoenixKit.Utils` helpers (PR #548)
  - `Reorder.reorder/4` — two-phase index-rewrite primitive for drag-to-reorder list
    views; schema-agnostic, UUID-filtered, payload-capped, returns `{:ok, count}`.
  - `Values.blank_to_nil/1` and `Values.presence/1` — canonical `"" → nil` helpers
    (the latter trims first); previously duplicated across 7+ modules.
  - `Format.bytes/2` — single human-readable byte formatter with `:decimals` /
    `:unknown` / `:base` (1024 vs 1000) options; replaced 8 private copies.
- V120 migration — document-creator category / type taxonomy (PR #545).

### Changed
- `MediaSelectorModal` accepts an optional `notify: {module, id}` to deliver the
  selection via `send_update` instead of a process message.
- `MediaGallery` delegates its inline lightbox to `MediaViewer` — no behavior
  change for existing consumers.
- `<.draggable_list>` gains an optional `target` attr (CSS selector). When set,
  the `SortableGrid` hook routes the reorder event via `pushEventTo` so it
  reaches a LiveComponent rather than the host LiveView.
- `<.sort_header_cell>` polish — inactive-column up/down hint, in-flight loading
  spinner, and atom-or-string `sort.dir` tolerance (PR #548).
- `admin_page_header` — `back` / `back_click` are now deprecated no-ops; the back
  arrow no longer renders. Retained so existing call sites compile (PR #548).
- `MediaBrowser` folder management overhaul (PR #544)
  - Recursive folder trash + drag-to-trash; instant "untitled" folder creation.
  - Folders draggable across grid / list / sidebar; drop-into-current-folder via
    the main content area; whole-selection drag in select mode.
  - Per-file and per-folder kebab menus migrated to `TableRowMenu` (fixes clipping).
  - Folder rename made more apparent; click-away cancels.
- etcher / fresco dependency requirements tightened to `~> 0.2.6`.
- Upgraded library dependencies.

### Fixed
- `MediaGallery` drag-to-reorder no longer pushes `reorder_images` to the host
  LiveView (where it had no handler and crashed the page). The grid now passes
  `target` to `<.draggable_list>` so the event reaches the component's own
  `handle_event/3`.
- `MediaBrowser` breadcrumbs no longer duplicate the current folder or ignore
  scope; move-to-root now works under scope; `update_folder/3` guarded against
  `parent_uuid: nil`; N+1 in session breadcrumb work eliminated (PR #544).
- `admin_page_header` no longer carries an unused `Icon` import left by the
  back-button removal — restores a clean `mix compile --warnings-as-errors`.
- `Utils.Values.blank_to_nil/1` and `presence/1` no longer raise on non-string
  input (e.g. a list from a `key[]=` query param) — they fall back to pass-through
  and `nil` respectively.
- V120 migration review fixes — primary-key defaults, multi-prefix guards, exact
  legacy category mapping, `uuid_generate_v7()` per house convention (PR #545).
- Avatar dropdown overflow, scroll, hover, and click-feedback fixes.

### i18n
- Ecommerce gettext manifest + `ru` / `et` translations; fixed 91 fuzzy ecommerce
  translations (PR #547).
- Projects + comments gettext manifests with `et` / `ru` translations (PR #542).
- Global Gettext locale synced alongside the backend-specific one.

## 1.7.111 - 2026-05-14

### Added
- V118 migration: callout + text annotation kinds + optional `title` column on `phoenix_kit_annotations` (PR #541)
  - Widens `phoenix_kit_annotations_kind_check` to include `"callout"` (leader-line annotation: anchor point + line to a labeled bbox) and `"text"` (freestanding click-drag text label). Both new tools shipped in Etcher 0.2; the CHECK update is folded into a single `DROP + ADD` so we don't take two trips over the same constraint
  - Adds nullable `title varchar(200)` column. Every kind can carry a short label — renders inline on the shape (above the bbox for rect/circle/polygon, at the leader endpoint for callout, inside the bbox for text). Length matches the schema-side `validate_length(:title, max: 200)`. Lives in its own column so it stays queryable outside the JSONB blob
  - `Annotation` schema gains `:title` field + the two new kinds in `@kinds`; `@cast_fields` allows it through the changeset
- `PhoenixKit.Annotations.restore_linked_comments/3` (PR #541)
  - Undo-of-delete support: when an annotation deletion is reversed via Etcher's undo stack, the original uuid is gone but the soft-deleted comments still reference it through `metadata.annotation_uuid`. The function flips matching `status: "deleted"` comments back to `"published"` and rewrites their `metadata.annotation_uuid` to point at the recreated row. Returns count restored. No-ops cleanly when PhoenixKitComments isn't installed
- `AnnotationComposer` title input (PR #541)
  - Optional title field above the comment textarea. Title-only annotations are now allowed (skips the comment-thread create entirely; the row gets only its `title` column set). `update_draft` accepts both `comment` and `title` keys, debounced 500ms each. Title persistence threaded through `:annotation_composer_posted` → `MediaBrowser.finalize_annotation_compose/3`
- `MediaBrowser` etcher 0.2 wiring (PR #541)
  - `etcher:updated` now accepts any combination of `geometry / style / metadata / title` in one payload (previously geometry-only). In-memory annotation list mirrors writes so the tooltip reflects the new title without waiting for a `load_annotations_for/1` round-trip
  - Composer popover suppressed for `kind == "text"` (content arrives inline via etcher's foreignObject editor) and `restore: true` (recreated row already has its title/metadata; user wasn't trying to create a new annotation)
  - On `restore: true` + `restore_from_uuid`, walks soft-deleted comments via `restore_linked_comments/3` and refreshes the comments sidebar
  - Tool list extended: `[:rectangle, :circle, :polygon, :freehand, :callout, :text, :eraser]`
  - Etcher overlay now attaches to the Fresco viewer even when Tessera has no sources (pre-PR: an empty `tessera_sources(f)` fell back to a plain `<img>` with no annotation overlay at all). Annotations now work on fresh uploads that haven't been through the variant generator
- `ViewerKeydown` JS hook (PR #541)
  - Replaces `phx-window-keydown="viewer_keydown"` on the viewer modal. Two filters the stock binding couldn't express: (1) only `Escape` / `ArrowLeft` / `ArrowRight` reach the server (letter keys no longer spam LV logs), (2) navigation keys suppressed while focus is in `<input>` / `<textarea>` / contenteditable so arrow keys move the text caret instead of flipping the modal to the next image while typing
- Post-merge review doc in `dev_docs/pull_requests/2026/541-v118-callout-text-etcher-0.2/CLAUDE_REVIEW.md` with finding disposition table

### Changed
- `{:etcher, "~> 0.1"}` → `{:etcher, "~> 0.2"}` — adds callout / text / eraser tools, undo/redo, satellite titles, and a complete `window.Etcher.layerFor(id)` programmatic control surface (PR #541)
- `AnnotationComposer` textarea `phx-debounce` 150 → 500ms — quieter LV logs at typical typing speed, no perceived input lag (PR #541)
- `priv/static/assets/phoenix_kit.js` strips 584 lines of inlined fresco / tessera / etcher hooks. Parent apps now import each lib's own `priv/static/` bundle ahead of `phoenix_kit.js`, and phoenix_kit adopts `window.{Fresco,Tessera,Etcher}Hooks` into `window.PhoenixKitHooks`. Eliminates drift between the inlined snapshot and the hex packages (PR #541)

### Hygiene
- Lockfile updates: `fresco 0.1.1 → 0.1.2`

## 1.7.110 - 2026-05-13

### Added
- V117 migration: document composition tables for `phoenix_kit_document_creator` (PR #539)
  - Adds nullable `category :: varchar` column + index to `phoenix_kit_doc_templates` so templates self-classify (financial / technical / etc.) and the template grid can filter by scope
  - Creates `phoenix_kit_doc_document_sections` — join table snapshotting `(document_uuid, template_uuid, position, variable_values, image_params)` for every section of every composed document. `document_uuid → :delete_all` cascades sections with their parent; `template_uuid → :nilify_all` lets sections outlive the template (regenerate-required state). Unique `(document_uuid, position)` + lookup index on `(document_uuid)`
  - Creates `phoenix_kit_doc_template_presets` — named reusable section recipes scoped via `(scope_type, scope_id)` and optionally categorized. `sections` is a JSONB array of `[%{template_uuid, position, variable_values, image_params}]`. Index on `(scope_type, scope_id, category)`
  - Legacy `Document.template_uuid` column retained: composed docs leave it `NULL`, legacy single-template docs continue to use it

### Fixed
- Fixed ungrouped `handle_event/3` clauses in `MediaBrowser` by relocating `creator_attrs/2` helper to private-helpers block
- Restored sitemap dynamic `<lastmod>` for homepage and group listing pages (`Sources.Static`, `Sources.Publishing`)
  - PR #539's merge silently re-removed `static_lastmod/1` and `latest_post_date/2` (a zombie revert that came back via merge conflict and got cut again from a behind-the-base fork). Result: every static URL was reporting `lastmod: <today>` on every crawl (a known false-freshness signal Google de-prioritizes), and every group listing was shipping without `<lastmod>` at all
  - Homepage `<lastmod>` now uses a new lightweight `Publishing.latest_post_date_global/0` helper — single pass over each group's posts to take max `published_at`. Replaces the prior shape that called `Publishing.collect/1` and threw away everything except the `:lastmod` field (which triggered ~3× redundant `list_posts/2` calls per group inside `collect/1`)

### Hygiene
- Routine lockfile updates (`mix.lock`)
- Precommit: `compile --force` replaced with `compile --warnings-as-errors --all-warnings`, added `deps.unlock --check-unused`, switched from `quality` to `quality.ci` (format-check)
- Dialyzer: removed 5 unused ignore filters (css_integration, process_scheduled_jobs_worker, duplicate conn_case/data_case, integrations guard_fail)
- Removed stale `:phoenix_kit` self-entry from `mix.lock`

## 1.7.109 - 2026-05-12

### Added
- V114 migration: Integrations storage switched to uuid-only `key` column on `phoenix_kit_settings` (PR #536)
  - Collapses the per-row `key` from the composite `integration:<provider>:<name>` shape to just the row's UUIDv7. Lifts both name restrictions baked into the old shape: the regex `[a-zA-Z0-9][a-zA-Z0-9\-_]*` and per-provider uniqueness are gone. Any non-empty string (after trim) is now a valid connection name; duplicates within a provider coexist (uuids disambiguate). Names with spaces, punctuation, "My Company Drive (US)" — all allowed
  - `add_connection/3`: generates UUIDv7 up-front, embeds it in both the `uuid` and `key` columns; provider + name live purely in `value_json`. `rename_connection/3` rewrites only the JSONB `name` field — storage key is the row uuid, untouched across renames, so consumer modules pinning to uuid keep working
  - Read sites (`get_integration_by_uuid/1`, `list_connections/1`, `load_all_connections/1`) source provider + name from JSONB; the list helpers expose `:date_added` so UI callers render "Created N ago" without a second lookup
  - `provider:name` string lookups now first-match by case-insensitive name sort (names aren't unique anymore). Read-shim contract preserved for legacy `migrate_legacy/0` callsites
  - `log_activity` takes explicit `(provider, name)` so audit rows carry human-readable names — parsing the key would have stamped a uuid string into `metadata.connection`
  - Migration walks every `integration:%`-keyed row in a single UPDATE, backfills missing `value_json -> 'name'` / `'provider'`, ensures `module = 'integrations'`, and rewrites `key = uuid::text`. Legacy V0-shape keys without `:name` fold to `name = "default"`. `down/1` rewrites back to composite shape with `-<8-char>` suffix from UUIDv7's random tail on duplicate `(provider, name)` pairs
- V115 migration: `phoenix_kit_annotations` table for drawn-on-image shapes via the Etcher overlay (PR #537)
  - Stores rectangle / circle / polygon / freehand shapes tied to a `phoenix_kit_files` row in image-pixel coordinates. Geometry is JSONB; shape kinds enforced via DB-level CHECK constraint matching Etcher 0.1's four-tool set
  - `file_uuid` FK `ON DELETE :delete_all` — annotations vanish with their host image. `creator_uuid` nullable + `ON DELETE :nilify_all` so user deletion preserves their annotations as anonymous
  - Discussion threads attach via the existing comments convention: comments anchored to the **file** (`resource_type = "file"`, `resource_uuid = file_uuid`) with `metadata.annotation_uuid` carrying the back-reference. Annotation-rooted comments appear in the file's main thread alongside non-annotated discussion
  - Indexes: `(file_uuid)` for per-file listing, partial `(creator_uuid) WHERE creator_uuid IS NOT NULL` for author lookups
- V116 migration: nullable self-FK `parent_uuid` on `phoenix_kit_entity_data` (PR #538)
  - Each entity-data row can point at another row of the same entity as its parent. System field — always present, optional, never user-removable (does not appear in `entities.fields_definition`). Existing rows stay `parent_uuid = NULL` and become roots; no backfill
  - No `ON DELETE` cascade — parent/child linkage and same-entity scope are managed by the `PhoenixKitEntities.EntityData` context inside a transaction. A DB-level cascade would bypass the soft-delete machinery and the activity log
  - Same-entity enforcement is a context-layer responsibility. B-tree index on `(parent_uuid)` covers the "list children" query for the WordPress-style indented tree
- `PhoenixKit.Annotations` context + `PhoenixKit.Modules.Storage.EtcherAdapter` (PR #537)
  - Context handles CRUD against `phoenix_kit_annotations` plus `list_for_file_with_previews/1` that pulls every file comment in a single bulk query and groups by `metadata.annotation_uuid` for the tooltip preview
  - `Annotations.delete/1` runs comment cascade + annotation row delete in a `Repo.transaction/1` so a failure between the two doesn't leave the annotation alive with its discussion thread destroyed
  - `Annotation.adapter_writable_fields/0` exposes the schema's `@cast_fields` (minus `file_uuid`, which the adapter sets server-side from `target_uuid`) as the source of truth for the adapter whitelist — the adapter's `@schema_keys` derives from it so a future schema field can't drift silently
  - `EtcherAdapter` implements the `Etcher.Storage` behaviour, dispatching to the context. Adapter explicitly whitelists payload keys before reaching `String.to_existing_atom` — guards against forward-compat with Etcher's payload shape growing new client-side keys
- `PhoenixKitWeb.Components.AnnotationComposer` LiveComponent (PR #537)
  - Focused composer for attaching the first comment to a newly-drawn annotation. Explicit Post / Cancel control flow owns the annotation lifecycle: Post commits comment + solidifies annotation, Cancel rolls the annotation back. Communicates with the parent MediaBrowser via LC-to-LC `send_update/2`, no host-LV plumbing required
  - Scope: text + file uploads (image / video / audio / pdf / archive) + Giphy picker. Audio recording (which the full `CommentsComponent` supports) intentionally skipped for v1
- MediaBrowser integration with the Etcher overlay (PR #537)
  - `Etcher.layer` mounted alongside `Fresco.viewer` in the modal. New `etcher:created` / `:updated` / `:deleted` / `:selected` handlers wire the JS overlay into the storage backend
  - Lifecycle: `open_viewer/2` preloads annotations + rolls back any pending compose; `finalize_annotation_compose/2` reloads annotations and pokes the file's `CommentsComponent` to refresh; `refresh_file_comments/1` flips the component's `loaded?` to false to trigger a sidebar reload
  - `creator_uuid` is set server-side from the scope — client-supplied `creator_uuid` in the payload is overridden, preventing author spoofing
- `IntegrationPicker` rewrite (PR #536)
  - Card subtitle: priority `external_account_id` → masked credential tail (first 8 + `…` + last 4 for any of `api_key` / `bot_token` / `access_key`; `•••` for keys under 14 chars)
  - Age line under subtitle using shared `<.time_ago>`
  - Status badge: distinct label + colour for each of the four canonical statuses (`connected` → green "Connected", `error` → red "Auth failed" with `validation_status` tooltip, `configured` → yellow "Not tested", `disconnected` → grey "Not connected")
  - Provider icon + display name auto-resolve via `Integrations.Providers.get/1` — callers no longer pre-attach a `:provider` struct
  - Provider-name badge hidden when picker is filtered to a single provider (both real callsites do this)
  - Click feedback: `phx-click-loading` dims the clicked card + blocks rapid re-clicks during the LV round-trip; daisyUI `loading-spinner` swaps in for the status badge during the same window
  - `provider_def` memoized in a `Map.new(connections, ...)` shared between `filter_by_search/3` and the render path — drops `Providers.get/1` calls from 2N to N per render
  - 33 new component spec tests covering subtitle priority + masked credential + age + provider auto-resolve + status branches + filter-by-provider + search threshold + empty state + deleted-card warning + click-action dispatch
- `<.draggable_list>` `:sortable_handle` attribute (PR #538)
  - Optional CSS selector (e.g. `".pk-drag-handle"`) that restricts drag initiation to elements matching the selector inside each item. When set, the item wrapper drops `cursor-grab` styling — the caller renders their own handle. Backward-compatible: default `nil` preserves whole-item drag. Mirrors `<.table_default>`'s `:on_reorder` + `.pk-drag-handle` convention. JS hook (`SortableGrid`) already supported `data-sortable-handle`; this PR wires the Elixir-side knob through
- Etcher tooltip JS slot overrides (PR #537)
  - `window.Etcher.tooltipSlots` `.header` / `.footer` / `.body` translate `metadata.comment_*` keys into the rich tooltip (author header, date · count subheader, thumbnail + quoted text body). `window.Etcher = window.Etcher || {}` guards against load order
- `AnnotationComposerPosition` JS hook keeping the MediaBrowser's floating annotation-composer popover inside the viewer bounds via re-clamping on mount + updates + window resize
- Dep adds: `:fresco ~> 0.1` (OpenSeadragon viewer wrapper, now a direct dep since Tessera 0.2 split it out), `:etcher ~> 0.1` (annotation overlay)
- Three post-merge review docs in `dev_docs/pull_requests/2026/`: `536-integrations-v114-uuid-keys-picker-ux/`, `537-annotations-v115-etcher-overlay/`, `538-v116-parent-uuid-draggable-handle/` — each with finding disposition tables tracking which items were addressed in follow-up commits and which were deferred to the original PR author

### Changed
- `Integrations.validate_connection/2` rescue narrowed to `[DBConnection.OwnershipError, Postgrex.Error, Req.TransportError]` so genuine logic bugs (`KeyError`, `ArgumentError`, `MatchError`) bubble up to the supervisor instead of being swallowed under a generic "validation failed". `validate_credentials/2` mirrored the narrowing post-merge for parity (PR #536)
- `Integrations.authenticated_request/4` docstring spells out the URL-trust contract: the integration's Bearer token is attached to every request, so callers must pin URLs to a domain allowlist before invoking. Internal callers (`OpenRouterClient`, OAuth refresh, userinfo) build URLs from the Providers registry which is hardcoded and safe; new callsites taking URLs from elsewhere need their own guard (PR #536)
- `phx-disable-with` on Save / Test Connection / Disconnect / Delete buttons on `integration_form.html.heex` plus the OAuth Connect Account button. Pre-fix, a double-click + slow network could submit two save requests or spawn parallel HTTP probes (PR #536)
- IntegrationForm `create_connection` + `save_form_with_rename` error branches preserve `:new_name` + `:form_values` on error so a failed `:empty_name` submit doesn't wipe the api_key the operator just typed. Dropped the dead `:already_exists` / `:invalid_name` error branches (those tuples no longer fire post-V114). Template: removed the now-incorrect "Letters, digits, hyphens, and underscores. Must be unique per provider." name-rules hint (PR #536)
- `PhoenixKit.Users.Permissions.module_label("db")` / `module_icon` / `module_description` pin `db` in `@core_*` maps so the display is correct even when the external `phoenix_kit_db` module isn't loaded (PR #536)
- `MediaBrowser.format_date/1` strftime format string wrapped in `gettext(...)` so locales can reorder date components (`%d %b %Y` for en-GB / fr / de) without code changes
- `AnnotationComposer.first_error/1` routes through `PhoenixKitWeb.Components.Core.Input.translate_error/1` — gettext-aware helper that interpolates `%{count}` and other opts properly
- `AGENTS.md` CHANGELOG-ownership instruction corrected — entries are written by agents against the bumped `@version` heading, matching the project's actual workflow

### Fixed
- Post-merge fixes folded from review of PR #536:
  - V114 docstring drift after rebase rename: moduledoc references "V113" but the module is V114; "Stamp the table comment with '113'" while code stamps '114'; "post-V113 regression / invariant" in tests and picker comment. All swept to V114
  - `Permissions.module_label("db")` was falling through to `String.capitalize("db")` = `"Db"` when the external `phoenix_kit_db` module isn't loaded; test asserts `"DB"`. Folded in to keep the post-rebase baseline green
  - Test fixture rows in `storage/scope_test.exs`, `media_browser_scope_test.exs`, `media_browser_test.exs` violated V113's `phoenix_kit_files_user_or_parent_check` CHECK constraint; each `create_file!/1` now stamps `user_uuid` via a memoised `ensure_user!/0` helper
  - `IntegrationPicker.filter_by_search/3` had a shadowing `name` variable in the inner case pattern match; renamed to `provider_name`
  - `String.slice` negative-bound range pinned with explicit step (`-4..-1//1`) to silence Elixir 1.16+ range-step warning
  - Credo cleanup: `get_integration/1` 2-branch `cond` with `true` arm → `if/else`; inline `PhoenixKit.Settings.Queries.get_setting_by_uuid/1` calls aliased as `SettingsQueries` in `integrations_test.exs`; three test files (`storage/scope_test.exs`, `media_browser_scope_test.exs`, `media_browser_test.exs`) alias `PhoenixKit.Users.Auth` for their `ensure_user!` helpers
- Post-merge fixes folded from review of PR #537:
  - `Annotations.delete/1` deleted linked comments outside a transaction — if the comment cascade succeeded and the annotation row delete then failed (FK violation, DB transient), comments were gone but the annotation remained with its discussion permanently destroyed. Wrapped in `Repo.transaction/1` via an extracted `delete_in_transaction/1` helper
  - `resource_type = "annotation"` claim in three moduledocs (`annotation.ex`, `v115.ex`, `etcher_adapter.ex`) contradicted the actual implementation, which anchors comments to the **file** (`resource_type = "file"`) with `metadata.annotation_uuid`. All docs swept to match reality
  - `Annotations.delete_linked_comments/1` bare `rescue _ -> :ok` swallowed every exception class including logic bugs. Narrowed to `[DBConnection.OwnershipError, Postgrex.Error, ArgumentError]` so logic bugs surface
  - `AnnotationComposer.normalize/1` reinvented what `Ecto.Changeset.cast/3` already does (accepts both atom- and string-keyed maps) AND silently passed the original map through when `String.to_existing_atom` failed, hiding typo'd field names from the user as "geometry: can't be blank" rather than "unknown field" — function deleted
  - In-repo `Code.ensure_loaded?(PhoenixKit.Annotations)` guard in `MediaBrowser.load_annotations_for/1` was needless defensive code — `Annotations` is in the same compilation unit
  - `@compile {:no_warn_undefined, [PhoenixKit.Modules.Storage, ...]}` would have shadowed legitimate compile errors on a core module rename — `Storage` removed from the suppression list
  - `AnnotationComposerPosition.destroyed` cleanup conditional was a never-falls-through guard — simplified
  - Etcher slot-preservation JS comment misstated the mechanism — corrected to "PhoenixKit owns the tooltip layout; downstream consumers must load AFTER phoenix_kit.js"
  - Credo cleanup: `Annotations.first_attachment_thumbnail/1` single-clause `with` → `case`; aliased `Annotations`, `Storage`, `EtcherAdapter`, `Storage.File` so six "nested modules could be aliased" findings clear
  - PhoenixKitComments dialyzer ignores added for `annotations.ex` + `annotation_composer.ex` (optional sibling package, guarded at runtime)
- V114 down SQL collision-suffix source: `substring(uuid::text from 1 for 8)` extracted UUIDv7's timestamp prefix — same-millisecond rows produced identical suffixes ⇒ duplicate "uniquified" keys when two+ rows collided on `(provider, name)`. Switched to `substring(uuid::text from 25 for 8)` (random tail, 32 bits of entropy). Mirrored in `run_down!` in the V114 test (PR #538 follow-up)
- 3-row collision test added to V114 test suite covering N ≥ 3 case (exactly one plain key, N-1 distinct suffixed keys, all keys unique)
- IntegrationPicker click feedback was missing: clicking a card showed no visual response during the 100-500ms LV round-trip — operators would click again and submit a second request. Added `phx-click-loading:opacity-60 phx-click-loading:pointer-events-none` + status-badge → spinner swap during the in-flight window (PR #536)

### i18n
- AnnotationComposer user-facing strings wrapped in gettext (flash messages + heex literals + ARIA labels — ~17 strings)
- MediaBrowser `format_date` strftime pattern wrapped in gettext so locales reorder date components
- IntegrationPicker status labels (`Connected` / `Auth failed` / `Not tested` / `Not connected`) and search placeholder + empty-state strings wrapped in gettext
- IntegrationForm flash messages, button labels, name placeholder, danger-zone copy, OAuth step labels, redirect-uri instructions wrapped in gettext


## 1.7.108 - 2026-05-11

### Added
- V112 migration: `phoenix_kit_projects*` schema evolution (PR #533)
  - `archived_at TIMESTAMP(0)` on `phoenix_kit_projects` so the admin dashboard can soft-hide projects without flipping a status enum. Mirrors the workspace convention used by `phoenix_kit_publishing`'s `posts.trashed_at` and `phoenix_kit_files.trashed_at` — null = visible, non-null = soft-hidden, with the timestamp doubling as audit metadata. Existing `status = 'archived'` rows backfilled into `archived_at` so the dashboard filters keep working transparently
  - `phoenix_kit_projects_visible_idx` partial index on `(inserted_at DESC) WHERE archived_at IS NULL` — one partial covers both project-list and template-list dashboard reads (neither view shows archived rows)
  - `translations JSONB NOT NULL DEFAULT '{}'` on `phoenix_kit_projects`, `phoenix_kit_project_tasks`, `phoenix_kit_project_assignments` for per-language overrides on user-input content (name / description / title). Primary stays in dedicated columns; JSONB only carries non-primary overrides
  - `position INTEGER NOT NULL DEFAULT 0` on `phoenix_kit_projects` and `phoenix_kit_project_tasks` so the drag-and-drop reorder API can persist manual ordering. Existing rows fold into the `0` bucket and the schema's secondary order-by-`inserted_at` kicks in until a user actually drags
  - `scheduled_start_date` retyped from `DATE` to `TIMESTAMP(0)` so scheduled-overdue detection honors time-of-day (a project scheduled for today 09:00 flips to `:overdue` at 09:01, not at midnight). Column name kept — lying name + honest type beats the churn of renaming every call site
  - Drops the three remaining unique-name indexes — `phoenix_kit_projects_name_template_index`, `phoenix_kit_projects_name_project_index`, `phoenix_kit_project_tasks_title_index`. Name uniqueness is now policy, not schema — editing or duplicating names no longer trips a stale index, and future renames don't need migration coordination
  - Bumps migrator `@current_version` 111 → 112 — without this V112 was dead code
  - All steps idempotent (column-existence, index-existence, USING coercion clauses); `down/1` reverses each change so a rollback restores the V111 shape. `down/1` restores the V105/V101 unique indexes **first**, before dropping any V112 columns, so a duplicate-name conflict at rollback aborts cleanly rather than leaving a half-rolled schema
- `test/phoenix_kit/migrations/v112_test.exs` — pins every V112 addition (archived_at column + type + nullability, visible-index existence AND predicate shape, translations JSONB on the three tables, scheduled_start_date retype, position columns) plus the four dropped indexes and the duplicate-name behavior. The predicate test refutes any `is_template` mention, closing the docs-drift loop
- `dev_docs/pull_requests/2026/533-v112-projects-schema-evolution/CLAUDE_REVIEW.md` — post-merge review with finding dispositions
- V113 migration: system-managed media flag for Tessera deep-zoom tiles + comments↔files junction (PR #534)
  - `system_managed BOOLEAN NOT NULL DEFAULT false` on `phoenix_kit_files` — marks internally-generated media (DZI tile pyramids + per-tile chunks) so the MediaBrowser excludes them from user listings and the variant generator skips them (tile chunks don't need small / medium / large — just an `"original"` FileInstance)
  - `parent_file_uuid UUID` nullable FK to `phoenix_kit_files(uuid)` ON DELETE CASCADE — system-managed tile rows cascade away when their source image is hard-deleted
  - `user_uuid` drops NOT NULL — system-managed rows belong to a parent File, not a user. The DB-level CHECK `phoenix_kit_files_user_or_parent_check` enforces "`user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL`" so raw inserts can't violate the invariant
  - `phoenix_kit_files_system_dedup_index` partial unique index on `(parent_file_uuid, file_name) WHERE system_managed = true` — concurrent lazy-generation requests for the same uncached tile dedupe at the DB level via the changeset's `unique_constraint`; `Storage.store_system_file/3` recovers the winner's row on conflict
  - Two more partial indexes — `phoenix_kit_files_parent_uuid_index` (per-source lookup + cascade-cleanup) and `phoenix_kit_files_system_managed_index` (keeps the MediaBrowser's "user files only" sort cheap as the tile catalog grows)
  - `phoenix_kit_comment_media` junction table letting the comments module attach core File rows to comments with position + caption. Cascade on `comment_uuid`, RESTRICT on `file_uuid` (a file can't hard-delete while attached). Consumer code lands in a later PR
  - Bumps migrator `@current_version` 112 → 113; all DDL idempotent via `IF NOT EXISTS` / DO-blocks
- Deep Zoom Image viewer in MediaBrowser via Tessera (OpenSeadragon wrapper, PR #534)
  - New `Tessera.Viewer.viewer` replaces the static `<img>` in the file modal; `tessera_sources/1` builds the progressive layer list (medium → optional large → DZI manifest)
  - `<Tessera.Storage>` adapter (`PhoenixKit.Modules.Storage.TesseraAdapter`) lands tile writes in the storage pipeline (multi-bucket via `Manager.store_file/2` + a system-managed File row via `Storage.store_system_file/3`)
  - Two new public endpoints — `/tiles/:token/:dzi_filename` and `/tiles/:token/:files_segment/:level/:tile_filename` — generate the DZI manifest and individual tiles **lazily** on first request, then serve from storage. Signed `URLSigner` token in the URL path (not query) so OpenSeadragon's tile-URL derivation preserves it across manifest → tile fetch. The "dzi" variant name is distinct from storage variants so a leaked file-serving token can't grant tile access. Unauthorized requests return 404 to prevent UUID enumeration
  - Per-`file_uuid` `:global.set_lock` mutex + double-checked locking around the generators serializes concurrent cold-path requests for the same image; different images stay parallel. Lock timeout surfaces as 503 + `Retry-After` header
  - Tempfile lifecycles wrapped in `try/after` so `Tessera.generate_tile/4` or `Manager.retrieve_file/2` exceptions don't leak files into `System.tmp_dir!()`
  - New storage setting `storage_tile_generation_enabled` (default `"false"`) is the kill switch — when off, MediaBrowser emits no manifest URLs and the tile endpoints return 404
- `Storage.store_system_file/3` — context helper for system-managed media (tiles, manifests). Idempotent: check-then-insert with unique-violation recovery via the new dedup index, so two concurrent writers for the same key both end up with the same row
- `Storage` query helper `exclude_system_managed/1` — applied to every `list_*` / `count_*` / orphan / trash query so system-managed rows are invisible in the MediaBrowser regardless of how the query is composed
- `test/phoenix_kit/migrations/v113_test.exs` — pins every V113 addition (system_managed column shape, parent_file_uuid FK with cascade verification, user_uuid nullability change, three indexes including the partial-unique dedup, CHECK constraint with a raw-SQL test that double-null inserts are rejected, comment_media table + its two indexes)
- `dev_docs/pull_requests/2026/534-media-browser-tessera-tiles/CLAUDE_REVIEW.md` — review with finding dispositions; CRITICAL + HIGH items fixed in the same release

### Changed
- `<.translatable_field>` in `PhoenixKitWeb.Components.MultilangForm` — wrapper now `flex flex-col gap-1` and base input/textarea classes carry `w-full` (commits `52856738`, `0412beaf`). daisyUI 5's `.label` is `inline-flex` and `.input`/`.textarea` are `inline-block`, so without forcing column direction here label and field sat on the same row. Aligns the multilang form's layout with the regular `<.input>` core component
- `test/phoenix_kit/migrations/v106_test.exs` — dropped the "schema state (verified at boot)" `describe` block (its assertions pinned V112's drops, not V106's adds — moved to `V112Test`). File now scoped to V106's `down/1` cross-mode duplicate pre-check, matching its filename

### Fixed
- V112 `down/1` rollback ordering (post-merge review fix, commit `0cde04a8`). Original `down/1` dropped columns before restoring unique indexes; if post-V112 work introduced any duplicate names (V112's whole purpose), the `CREATE UNIQUE INDEX` would raise mid-rollback after columns were already gone. Reordered so index restoration runs first
- V112 visible-index predicate docs/code alignment — migrator moduledoc claimed `WHERE archived_at IS NULL AND is_template = false` but actual index only filtered on `archived_at IS NULL`. Docs updated to match the emitted SQL with rationale (one partial covers both visible projects and visible templates)
- MediaBrowser i18n — list-view dropdown duplicates of the folder menu (Color heading, delete data-confirm, Delete button) were missed in the original sweep; wrapped so list view matches grid view. Three flash/confirm messages embedded two independent counts in a single `gettext` call which made correct pluralization impossible in Russian (3 forms) and Estonian (2 forms); each composed from two `ngettext` calls injected into the surrounding `gettext` template (PR #532)

### i18n
- MediaBrowser UI strings wrapped in gettext + Russian and Estonian translations (PRs #532, plus earlier commits `c717c9d0` / `d44bf95c`)
- `/admin/modules` page strings wrapped in gettext + ru/et translations (PR #530)
- Core sidebar tabs wired to `PhoenixKitWeb.Gettext` for ru/et (PR #529, commits `43e528ac` / `c5fd5bae`)
- Sitemap settings UI strings wrapped in gettext (commit `afcc281a`)
- General Settings widened + `/admin/modules/languages` strings wrapped (commit `24ceec90`)
- Core `badge.ex` + `time_display.ex` status strings wrapped (commit `1fe0ad78`)
- 9 new tab-label msgids + complete Estonian translation in `default.po` (commit `373478f5`)
- Bare `Active` badge in `users.html.heex:278` wrapped (commit `8a341e90`)

### Layout
- Admin settings pages widened for wide screens (commit `3ea70ec1`)
- Module settings pages — sitemap, storage, referrals — widened for wide screens (commit `d867cb57`)

### Hygiene
- `mix format` reflow of long-line `gettext` / `ngettext` / `put_flash` calls in `media_browser.ex` and `media_browser.html.heex` (commit `9841ac31`). Surfaced when `mix precommit` ran during V112 review-followup work; no semantic changes
- New Hex dep: `{:tessera, "~> 0.1"}` — OpenSeadragon wrapper used by the Deep Zoom viewer

## 1.7.107 - 2026-05-10

### Added
- Two opt-in stateless helpers on `PhoenixKitWeb.Components.Core.TableDefault` (PR #528)
  - `sort_header_cell/1` — clickable `<th>` with `hero-chevron-up-mini`/`-down-mini` icon when active, inert label-only `<th>` when `sort` attr is `nil`. Configurable `event` (default `"toggle_sort"`), `target`, `align` (`:left`/`:right`/`:center`). The `align` is applied to the `<th class>` (`text-right` / `text-center`) so non-sortable columns honour it consistently with the sortable ones
  - `sort_header_cell/1` emits `aria-sort="ascending"|"descending"|"none"` on the `<th>` when sortable, omitted when inert. Pinned by 4 regression tests covering all three states + omitted
  - `search_toolbar/1` — daisyUI `input-sm` with `hero-magnifying-glass` icon and `phx-debounce` (default 300ms). Optional `<form>` wrap when `on_submit` is set. Placeholder defaults to `dgettext("default", "Search...")`. `phx-target` propagates to both the `<form>` and `<input>` so submit-on-Enter retargets correctly when embedded in a `LiveComponent`
  - `test/phoenix_kit_web/components/core/table_default_test.exs` — new directory + 18 component tests; closes part of the standing `core/` test-coverage TODO from `CLAUDE.md`
- `change_page` event handler in `PhoenixKitWeb.Live.Users.LiveSessions` — pagination on `/admin/users/live-sessions` was bound to `phx-click="goto_page"` with no matching `handle_event/3` clause, so clicking any page number raised `FunctionClauseError` and crashed the LV (PR #528 follow-up). Renamed the binding to `change_page` and added the handler mirroring the sibling `users.ex:121` convention

### Changed
- `PhoenixKitWeb.Live.Users.LiveSessions` — collapsed `:sort_by` + `:sort_order` assigns into a single `:sort = %{by, dir}` map; renamed event `"sort_by"` → `"toggle_sort"` with `"by"` param. First click on a new column sorts ascending (was descending); subsequent clicks toggle. `flip_dir/1` tightened from `flip_dir(_)` catch-all to explicit `:desc` clause so unintended values surface as a crash rather than silent coercion (PR #528)
- `lib/phoenix_kit_web/live/users/live_sessions.html.heex` and `lib/phoenix_kit_web/live/users/users.html.heex` — both call sites of `<.search_toolbar>` dropped the redundant `on_submit="search"`. The input's debounced `phx-change="search"` already covers the same event; keeping both made Enter fire `"search"` twice (immediate submit + 300ms-later debounced change) (PR #528 follow-up)

### Fixed
- `lib/phoenix_kit_web/live/users/users.html.heex` — replaced bare search form (every keystroke hit the server) with `<.search_toolbar>` carrying the 300ms `phx-debounce` (PR #528)
- `<.search_toolbar>` form variant double-bound `phx-change` on both `<form>` and `<input>`, doubling work per keystroke. `phx-change` is now bound only on the `<input>`; the `<form>` carries `phx-submit` only. `phx-target` now propagates to both so LiveComponent embedding works end-to-end. Two regression tests pin both behaviours (PR #528, commit `dfc91238`)

### i18n
- `mix gettext.extract --merge` resync — adds `"Search..."` msgid + `et` / `ru` translations and surfaces accumulated drift from prior commits where extract wasn't run (PR #528, separate commit `a7c1d35b`)

### Hygiene
- `.gitignore` — adds `/priv/static/assets/vendor/` so `mix phoenix_kit.install` runs against `/app` itself don't leave an outdated copy of the source JS in tree (PR #528)
- `mix.lock` — `db_connection` 2.10.0 → 2.10.1, `igniter` 0.7.9 → 0.8.0 (pulls in `ex_ast` 0.11.0 as new transitive). Routine patch bumps

## 1.7.106 - 2026-05-08

### Added
- V111 migration: PDF library tables for the upcoming catalogue PDF subtab (PR #516)
  - `phoenix_kit_cat_pdfs` — thin per-upload row. `file_uuid` FK to `phoenix_kit_files(uuid)` ON DELETE RESTRICT (catalogue manages the file lifecycle; core prune can't remove files referenced by a live catalogue row). Soft-delete via `status` sentinel (`active` / `trashed`) + `trashed_at`. Two uploads of identical content (different filenames) → two rows sharing one `phoenix_kit_files` row + one extraction
  - `phoenix_kit_cat_pdf_extractions` — keyed by `file_uuid` PK. Worker state machine (`pending → extracting → extracted | scanned_no_text | failed`) + `page_count` + `extracted_at` + `error_message`. Cascades on file hard delete
  - `phoenix_kit_cat_pdf_page_contents` — content-addressed dedup cache. PK on `content_hash` (SHA-256 hex of normalized page text). Same page text across multiple PDFs is stored once. GIN trigram index lives here so the search index doesn't grow with cross-PDF duplication
  - `phoenix_kit_cat_pdf_pages` — composite PK `(file_uuid, page_number)`; `content_hash` FK to the dedup cache (RESTRICT — orphaned content rows GC'd by a catalogue-side helper, not by FK cascade)
  - Enables `pg_trgm` extension; `@current_version` 110 → 111
- `PhoenixKit.KnownPackages` — live catalog of known external PhoenixKit packages, replacing the previously hardcoded list in `ModuleRegistry.known_external_packages/0` (PR #523)
  - Fetched on demand from `https://hex.pm/api/packages?search=phoenix_kit_&sort=name` and cached for 10 minutes in an ETS named table (`:phoenix_kit_known_packages_cache`)
  - Stale-while-revalidate with cap: on Hex failure, serves cached data up to `:max_stale_age_ms` (default 24h); beyond that, drops the cache and falls back to `:extra_known_packages` config entries only
  - `:warning` log on stale-served and empty-cache-extras-only; `:error` log when cache exceeds max stale age — operationally distinct alert levels
  - `Link`-header pagination with a 20-page cap (`@max_pages`) so a malformed `Link` header pointing back to the same page can't loop forever
  - `extra_known_packages` config knob — parent apps with private/forked packages declare them inline and they take precedence over Hex entries on the `package` dedup key (`source: "config"` baked in)
  - `hex_docs_icon_name: hero-<name>` convention — package authors append the marker to their Hex package description and the catalog UI picks it up; default is `hero-puzzle-piece`
- Per-module gettext support on Dashboard sidebar labels and tooltips (PR #522)
  - `PhoenixKit.Dashboard.Tab` gains `gettext_backend: module() | nil` (default `nil`) and `gettext_domain: String.t()` (default `"default"`) fields, plus `localized_label/1` and `localized_tooltip/1` resolvers that call `Gettext.dgettext/3` when a backend is set and fall back to the raw label otherwise
  - `PhoenixKit.Dashboard.Group` gains the same two fields plus `localized_label/1`
  - `Tab.divider/1` and `Tab.group_header/1` accept the new opts; `Tab.new/1` round-trips both via `get_attr/2`
  - 14 render sites in `Sidebar`, `AdminSidebar`, `TabItem` swap `tab.label` → `Tab.localized_label(tab)` and equivalents — mechanically uniform, no shape changes
  - Hot-reload safety via `Map.get/2` (not pattern matching) on the new fields — old-shape `%Tab{}` cached in ETS or `:persistent_term` from before the upgrade falls through as if `gettext_backend` were `nil` rather than raising `FunctionClauseError`. Pinned by an explicit `Map.delete(:gettext_backend)` regression test
  - `guides/per-module-i18n.md` — public guide for module developers (setup checklist, `mix.exs` / backend / `.po` flow, `dynamic_children/2` locale handling, dividers and group headers, tooltips, greenfield template, retrofitting checklist, smoke test pattern, common pitfalls including the hot-reload safety contract)
  - `dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md` — internal operational procedure capturing every gotcha hit during the Newsletters pilot (skip-worktree on mix.exs, path-dep workflow during local dev, conditional CI skip pattern for graceful degradation)
- `:per_translation_urls` attr on the three `LanguageSwitcher` variants — `language_switcher_dropdown/1`, `language_switcher_buttons/1`, `language_switcher_inline/1` (PR #525)
  - Each entry is `%{code: <display_code>, url: <full_url>}`. Both atom-keyed and string-keyed entries accepted (useful when the list comes from JSON/JSONB rather than Elixir code)
  - Resolves each language's `base_code` against the list via `DialectMapper.extract_base/1` so `"en-US"` and `"en"` both resolve cleanly. Falls back to the locale-rewrite default when no entry matches OR the matched entry has a `nil` URL (e.g. an unpublished draft)
  - Useful when a feature module has computed canonical URLs that the simple locale-rewrite default can't reproduce — for example publishing's per-language URL slugs where `/en/blog/my-post` and `/fr/blog/mon-article` aren't related by segment swap. Pass `assigns[:phoenix_kit_publishing_translations]` from the layout
  - 7 new tests in `test/phoenix_kit_web/components/core/language_switcher_test.exs` pin the contract (atom-keyed, string-keyed, full-dialect normalization, per-language fallback, nil/empty/missing-attr pass-through)
- Drag-handle scoping + sortable feedback infrastructure (PR #525)
  - `<.table_default>` emits `data-sortable-handle=".pk-drag-handle"` when `@on_reorder` is set; only the `.pk-drag-handle` element gets `cursor-grab` styling. Click-to-expand / button-press / text-selection on a card no longer fights with SortableJS drag detection
  - `SortableGrid` JS hook: new `sortable:flash` LV→client event handler. The host LV pushes `{uuid: "...", status: "ok" | "error"}` after each `reorder_items` attempt; the hook applies `pk-sortable-flash-{ok,err}` class for ~1.2s, idempotent via reflow trigger. Queries every `[data-id]` element so table-view + card-view both animate. Defensive status-validation guard — unknown values bail rather than falling into the err-class branch
  - `<tr>` cell-width preservation via `onChoose` / `onUnchoose` — SortableJS's `forceFallback: true` + `fallbackOnBody: true` clones the dragged `<tr>` to `document.body`, where it loses its `<table>` ancestor and `<td>`s collapse to content width. The hook now snapshots computed widths and pins them inline before the drag preview renders; `onUnchoose` restores them
  - `data-sortable-handle` attr threads to SortableJS's `handle` option for any caller; `moved_id` always included in the `reorder_items` payload (was only on cross-container moves) so the LV can push back a `sortable:flash` keyed to the just-moved row
- MediaBrowser modal viewer becomes the default click target for non-admin / non-select_mode browsers, with read-only image / video / PDF / icon preview, metadata sidebar, Download button, prev/next chevrons (and ←/→ keyboard shortcuts), and Esc / backdrop close (PR #519)
  - Mobile-fullscreen layout via `position: fixed; inset: 0` — bypasses daisyUI's grid + iOS Safari's 100vh/100dvh quirks. Desktop reverts to `95vw × 90vh` centered modal with rounded corners. The `!`-prefix utility chain on `.modal-box` is required because daisyUI v5's defaults win the cascade over plain Tailwind utilities
  - `MediaImageZoom` JS hook lazy-loads Panzoom 4.6.0 from jsDelivr when the modal opens; image supports wheel/pinch/double-tap zoom and drag-pan. Listener attaches to the parent so the cursor doesn't have to land on the image; `destroyed` cleanup removes the wheel listener and destroys the Panzoom instance
  - Bulk-select still reachable — clicking the toolbar's Select button flips `select_mode` on, and from then on clicks toggle selection instead of opening the modal
- LiveView login redirect now carries the original request path as `?return_to=` (PR #519)
  - New `login_path_with_return_to/1` private helper in `PhoenixKitWeb.Users.Auth` reads `Phoenix.LiveView.get_connect_info(socket, :uri)`, encodes `path?query` via `URI.encode_www_form/1`, and threads it into the redirect target. Wired into the four `redirect_require_login` paths in `on_mount` hooks
  - Trailing-slash self-loop guard: `String.trim_trailing(path, "/")` on both sides of the equality check, so `/users/log-in` and `/users/log-in/` are treated as the same path and no return-to round-trips back to itself
  - Pairs with the existing `?return_to=` flow in `login.ex` (`sanitize_return_to/1` → `:user_return_to` session → `log_in_user/3`)
- `PhoenixKit.ModuleRegistry.get_module_key_for_namespace/1` — symmetric with the existing `get_by_key/1`. Resolves a top-level Elixir namespace string (e.g. `"PhoenixKitEntities"`) to the registered plugin's `module_key/0` (PR #521)
  - Iterates `all_modules/0`, matches on `Module.split(mod) == [top_namespace]` (exact, single segment), returns the key string or `nil` for unmatched
  - Reads from `:persistent_term` so there's no GenServer roundtrip on the hot path
- Microsoft 365 OAuth tenant override + generic `interpolate_url/3` helper in `PhoenixKit.Integrations.OAuth` — providers can now substitute `{key}` placeholders in `auth_url` / `token_url` from per-row `integration_data`, falling back to a provider-level `:url_defaults` map (PR #516)
  - Closes the previously hardcoded `/common/` Microsoft tenant — single-tenant operators got AADSTS50194 errors. New `tenant_id` setup field with `common` default; multi-tenant remains the default behavior. Three pinning tests in `test/phoenix_kit/integrations/oauth_test.exs`
  - Wired into `authorization_url/5`, `exchange_code/4`, `refresh_access_token/2`. URLs without `{` pass through unchanged (zero impact on Google / OpenRouter / Mistral / DeepSeek)
- "Resolve a LiveView module to its permission key" block-comment on `PhoenixKitWeb.Users.Auth.permission_key_for_admin_view/1` documenting the four-step resolution order (static map → custom-tabs → `PhoenixKit.Modules.<X>.Web.*` namespace → registered-plugin namespace) and the fail-closed nil default

### Changed
- DB module extracted from core into the standalone `phoenix_kit_db` Hex package (PR #518)
  - Removed `lib/modules/db/` (`db.ex`, `listener.ex`, `web/{activity,index,show}.{ex,html.heex}`) — ~2010 lines across 8 files
  - `module_registry.ex` — dropped `PhoenixKit.Modules.DB` from `internal_modules/0`
  - `integration.ex` — dropped the three hand-registered `live "/admin/db…"` declarations (auto-discovery via `admin_tabs/0` picks them up once the package is installed)
  - `modules.html.heex` — dropped the hardcoded DB module card; auto-render via `<.module_card>` based on `admin_tabs/0` discovery
  - `dev_docs/guides/2026-02-24-module-system-guide.md` — moved `lib/modules/db/db.ex` from the Internal examples section to External as `phoenix_kit_db/`, between hello_world and document_creator
- `PhoenixKit.ModuleRegistry.not_installed_packages/0` switches from `Code.ensure_loaded?(pkg.module)` to OTP-app-name MapSet membership (PR #523) — the more correct semantics, since module-loading state and OTP-app-installed state aren't the same: an extracted-but-not-yet-installed module fragment could pass `Code.ensure_loaded?` but isn't actually a dep
- `PhoenixKit.Integrations.OAuth.verify_oauth_state/2` missing-state branch tightened from lenient `:ok` to `{:error, :state_mismatch}` (PR #516, closes a CSRF-relevant gap from PR #511's review NIT #10) — every `connect_oauth` event saves state via `save_oauth_state/2` before redirect post-2026-05, so a missing state at callback time means either bypass or row-mutated-mid-flow; both are CSRF-relevant
- `IntegrationPicker` drops the `conn.name == "default"` substitution that contradicted PR #511's own moduledoc ("Names are pure user-chosen labels with no system semantics") — always renders the user-chosen name + provider badge (PR #516, closes PR #511 NIT #6)
- `<.file_upload>` `full_upload/1` variant entry-progress label reads `Uploading… {entry.progress}%` instead of the bare percentage — `entry.progress` is always client→server upload progress per Phoenix LV convention, so the wording is universally accurate (PR #516)
- `LanguageSwitcher` resolves the per-language URL once per iteration via inline `<% url = ... %>` and reuses it for `href` and `phx-value-url` — halves the per-render `resolve_url/3` cost and pins both call sites to the same URL (post-merge triage)
- `KnownPackages` moduledoc grew an "Operational signals" section enumerating the three log levels (`:warning` stale-served / no-cache / `:error` exceeded max stale age) and what each signals operationally (post-merge triage)

### Fixed
- Publishing routing-strategy collision: any host route shaped `/:locale/<literal>/...` declared after `phoenix_kit_routes()` was silently shadowed by publishing's `/:language/:group/*path` catch-all (PR #524)
  - `phoenix_kit_routes/0` now emits a publishing-specific dispatch shim when `PhoenixKitPublishing.RouterDispatch` is loaded — internal-prefix scope at `/<url_prefix>/__phoenix_kit_publishing_dispatch` with `/localized` and `/root` discriminator sub-scopes, plus a `def call/2` override that calls `RouterDispatch.maybe_rewrite/1` on every request and only rewrites publishing-bound URLs onto the internal prefix. Host routes get a fair shot at every URL
  - `restore_path/2` runs after route binding (via the new `:phoenix_kit_publishing_internal` pipeline) so canonical-URL generation reads the URL the client sent — without it, publishing's `default_language_no_prefix` redirect would spin on the internal prefix forever
  - Compile-time gated on `Code.ensure_loaded?(PhoenixKitPublishing.RouterDispatch)`; installs without publishing in the dep tree get `quote do end` (no-op AST). The `__mix_recompile__?/0` mechanism injected by `phoenix_kit_routes/0` forces a host-router recompile when publishing is added or removed from deps — handles the dep-cache staleness case
  - Browser-smoke verified across 8 URL classes: localized + canonical publishing posts, host's `/:locale/services/view/...` routes (was 404 pre-fix), admin redirects, plain home, genuine 404s. HTML body sweep confirmed zero leakage of the internal prefix in canonical / og / links / JS / headers
- Custom-role users with explicit plugin permissions (`entities`, `billing`, `ai`, …) were silently locked out of plugin admin pages because `infer_permission_key_from_module/1` only resolved the core `PhoenixKit.Modules.*` namespace. External plugins (`PhoenixKitEntities.*`, `PhoenixKitBilling.*`, …) returned `nil` from all three resolution paths, collapsing onto the "no permission" branch in `enforce_admin_view_permission/2` (PR #521)
  - New `[top | _rest] -> ModuleRegistry.get_module_key_for_namespace(top)` clause on `infer_permission_key_from_module/1`. Old `_ -> nil` fallback removed (unreachable post-`Module.split/1`). Owner / Admin behaviour and the fail-closed default for genuinely unknown views are preserved
  - Initial implementation used `[^top_namespace | _]` which matched any registered module whose `Module.split` *starts with* the segment; live repro on a parent app showed `get_module_key_for_namespace("PhoenixKit") => "db"` because `PhoenixKit.Modules.DB` happened to be the first registered module beginning with `"PhoenixKit"`. Tightened to `[^top_namespace]` (exact, single segment) and pinned with a regression test
  - `permission_key_for_admin_view/1` exposed as `@doc false def` (was `defp`) so 4 new unit tests in `test/phoenix_kit_web/users/auth_test.exs` can exercise the resolution layers without LiveView mounting machinery; 3 new tests in `test/phoenix_kit/module_registry_test.exs` pin `get_module_key_for_namespace/1` (uses `Module.create/3` with explicit top-level fixture names to avoid test-module auto-nesting)
- `PhoenixKitWeb.PagesHTML` removed (PR #518) — the module had no controller, no routes, no callers. The `embed_templates "pages_html/*"` directive plus `pages_html/show.html.heex` plus the `integration.ex` docstring described a markdown-page-rendering feature that was never wired up. Publishing module covers actual CMS-page rendering. `ast-grep --lang elixir --pattern 'PhoenixKitWeb.PagesHTML'` confirms zero structural references remain
- `MediaBrowser` chevron-button positioning: daisyUI's active-state CSS replaces `transform` with `scale(0.97)` on click, which would clobber a `-translate-y-1/2` on the button itself and make it jump down 50% of its height. Chevron positioning now sits on a wrapper `<div>`, not the button (PR #519)
- `media_browser.html.heex` modal-viewer leading comment referenced the now-removed `viewer={true}` attr; rewritten to describe the new default click behaviour (post-merge triage)
- Dead `defaults[String.to_atom(key)]` fallback in `OAuth.interpolate_url/3` — no provider in `Providers.providers/0` ships an atom-keyed `url_defaults`, so the path was unreachable. Removed; comment documents that provider authors must use string keys (post-merge triage)
- `KnownPackages.fetch_hex_page/3` recursion grew an explicit `@max_pages 20` cap so a malformed `Link` header pointing back to the same page can no longer loop forever; `ensure_table/0` rescue now carries an explanatory comment about the `:ets.whereis/1` → `:ets.new/2` race window (post-merge triage)
- `KnownPackages` test_helper.exs: the `System.cmd("psql", ...)` DB-existence check now `try/rescue ErlangError` so environments where `psql` isn't on PATH fall through to the connect-direct branch instead of crashing the test boot (PR #523)
- Pre-existing credo `Refactor.Apply` opportunities on the three `apply/3` calls in `compile_publishing_routing/1` silenced with inline `# credo:disable-for-next-line` annotations and an empirically-verified comment explaining why the variable-indirection alternative (`mod = ModuleName; mod.fun()`) doesn't shield the compiler's static-resolution warning either. `mix credo --strict` now reports zero issues across the tree (post-merge triage)

### Removed
- `PhoenixKit.Modules.DB` and the entire `lib/modules/db/` directory — extracted to the standalone `phoenix_kit_db` Hex package; companion repo TBA (PR #518)
- `PhoenixKitWeb.PagesHTML` and its `pages_html/show.html.heex` template — dead code, never wired up to a controller or route (PR #518)
- `MediaBrowser`'s `:viewer` attr — the four-mode click handler collapsed to three modes (`select_mode` → `admin` → modal viewer); pickers reach `select_mode` via the toolbar's Select button. The default click action is now the modal viewer, so callers that previously passed `viewer={true}` see no behaviour change. Callers that depended on the old picker-by-default (no `admin`, no `viewer` → click toggles selection) need to instruct users to click the toolbar's Select button instead (PR #519)

## 1.7.105 - 2026-05-05

### Added
- `PhoenixKit.Migration.ensure_current/2` — re-runnable analog of `mix ecto.migrate` for test helpers and any boot path running against a long-lived database (PR #515)
  - Passes a fresh wall-clock version (`:os.system_time(:microsecond)`) to `Ecto.Migrator.up/4` on every call so Ecto sees a "new" migration each time and invokes the inner runner; PhoenixKit's own marker (the comment on the `phoenix_kit` table) short-circuits internally if there's nothing new to apply
  - Forwards `:prefix` from the Ecto.Migration runner context inside the new private `PhoenixKit.Migration.Runner` wrapper so callers passing `prefix: "auth"` aren't silently routed to `"public"`
  - Microsecond precision keeps the collision and clock-skew windows small enough that an NTP correction would have to rewind the clock by µs at exactly the wrong moment to hide a newly-shipped migration; bigint-safe (Postgres covers ~292 years)
  - The `schema_migrations` table accumulates one row per call — cosmetic noise acceptable for the test-DB use case; production migrations via `mix ecto.migrate` / `mix phoenix_kit.update` remain unchanged
- V110 migration: nullable `language VARCHAR(10)` column on `phoenix_kit_doc_templates` so each Document Creator template can be tagged with a single locale (PR #515)
  - Full locale codes (`en-US`, `et-EE`, `ja`) — matches `PhoenixKit.Module.Languages.get_enabled_languages/0` output; lossless, consumers that want bare base codes can derive them via `DialectMapper.dialect_to_base/1`
  - Existing rows survive without a backfill; the form (landing in `phoenix_kit_document_creator` separately) pre-selects the project's primary language when creating new templates
  - Documents intentionally do not get a language column — they inherit from `template_uuid → templates.language`
  - `@current_version` 109 → 110; ⚡ LATEST tag moved off V109 onto V110
- `PhoenixKit.Migration.Runner.runner_opts/1` — pure transform of the runner-context prefix into opts threaded to `PhoenixKit.Migration.up/1` / `down/1` (PR #515 review follow-up)
  - Split out of the previous closure-style `runner_opts/0` so the prefix-forwarding behaviour can be regression-tested without spinning up a real `Ecto.Migration.Runner` process (which conflicts with the Ecto sandbox)
  - Three new unit assertions in `test/phoenix_kit/migration_test.exs` pin the contract: `nil → []` (drop, so `with_defaults/2`'s `"public"` default isn't clobbered), `"auth" → [prefix: "auth"]`, arbitrary tenant prefix forwarded verbatim. If someone "simplifies" `runner_opts` to always return `[]`, CI now fails
- "Return contract" section in the `ensure_current/2` moduledoc clarifying that failures (advisory-lock contention, migration crashes, connection errors) raise from `Ecto.Migrator.up/4` rather than being wrapped in `{:error, _}` (PR #515 review follow-up)

### Changed
- `test/test_helper.exs` switched from path-form `Ecto.Migrator.run(repo, migrations_path, :up, all: true)` to `PhoenixKit.Migration.ensure_current/2` (PR #515)
  - Deletes the now-redundant wrapper migration `test/support/postgres/migrations/20260316000000_add_phoenix_kit.exs`
- `AGENTS.md` test-infra section updated: `test_helper.exs` is now the canonical migration application point, with a **Do not** warning against the stale tuple form `Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)` (PR #515)

### Fixed
- Documented test-helper migration patterns silently went stale after the first run (PR #515)
  - Both the tuple form (`Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)`, documented in `dev_docs/migration_cleanup.md`) and the path form (used by core's own test_helper via the `20260316000000_add_phoenix_kit.exs` wrapper) hit the same trap: Ecto.Migrator records the version in `schema_migrations` after the first call and filters that entry out of pending on every subsequent boot. `PhoenixKit.Migration.up/1` was never re-invoked, so newly-shipped Vxxx migrations didn't apply on subsequent boots even though PhoenixKit's own marker was idempotent. Symptom: `column ... does not exist` after `mix deps.update phoenix_kit` brought in new migrations but the test DB stayed at the old marker
  - Verified empirically — core's own `phoenix_kit_test` was at marker 107 even though Hex 1.7.103 shipped V108 + V109; first boot after switching to `ensure_current/2` advanced the marker through V108 / V109 / V110 correctly

## 1.7.104 - 2026-05-04

### Changed
- Customer Service module extracted from core into the standalone `phoenix_kit_customer_support` Hex package — companion repo: [BeamLabEU/phoenix_kit_customer_support](https://github.com/BeamLabEU/phoenix_kit_customer_support) (PR #514)
  - Removed `lib/modules/customer_service/` (~6 KLOC, 22 files) and `lib/phoenix_kit_web/routes/customer_service.ex`; the module is now an external optional dependency
  - `module_registry.ex` — dropped `PhoenixKit.Modules.CustomerService` from `internal_modules/0`, added the corresponding `phoenix_kit_customer_support` entry to `known_external_packages/0`
  - `integration.ex` — replaced inline `/dashboard/customer-service/tickets` route blocks with `Code.ensure_loaded?(PhoenixKitCustomerSupport.Web.UserList)` guards so absent-package = no routes
  - DB tables (`phoenix_kit_tickets`, `phoenix_kit_ticket_*`) stay in core under their existing names — they're domain-shaped, not module-shaped, and the prior migrations (V35/V51/V53/V58/V72/V74/V75/V77) remain in core's migration history
- Renamed "Customer Service" → "Customer Support" across the public surface (PR #514)
  - Module: `PhoenixKitCustomerService` → `PhoenixKitCustomerSupport`
  - OTP app: `:phoenix_kit_customer_service` → `:phoenix_kit_customer_support`
  - Hex package: `phoenix_kit_customer_service` → `phoenix_kit_customer_support`
  - Settings keys: `customer_service_*` → `customer_support_*` (7 keys)
  - URL paths: `/customer-service/*` → `/customer-support/*` (admin + user-facing, both base and locale-prefixed routes)
  - Permission key: `customer_service` → `customer_support`
  - Dashboard module card and admin nav target updated to match

### Added
- V109 migration: rename Customer Service module identifiers in-place so existing installs migrate cleanly (PR #514)
  - Renames 7 settings keys from `customer_service_*` → `customer_support_*` in `phoenix_kit_settings`
  - Renames `auto_granted_perm:customer_service` → `auto_granted_perm:customer_support`
  - Renames `phoenix_kit_role_permissions.module_key` from `customer_service` → `customer_support`
  - Idempotent (`IF EXISTS` guards on every rename); reversible `down/1` for emergency rollback
  - `@current_version` 108 → 109; ⚡ LATEST tag moved off V107 onto V109

### Fixed
- `PhoenixKit.Users.Auth.anonymize_user_tickets/1` was a no-op since the original Tickets → CustomerService rename — `Module.concat([PhoenixKit, Modules, Tickets, Ticket])` resolved to a never-loaded module so the `Code.ensure_loaded?` guard always failed and ticket anonymization silently skipped on user deletion. Now points at `PhoenixKitCustomerSupport.Ticket` (PR #514)
- V108 (drag-and-drop position columns, shipped in 1.7.103) was missing from the `lib/phoenix_kit/migrations/postgres.ex` per-version docstring catalog. Backfilled in this release alongside the V109 entry (PR #514 review)
- `lib/phoenix_kit/migrations/postgres/v109.ex` `rename_role_permission/4` carried an unused `_prefix` arg — the table name is already prefix-qualified at the call site. Trimmed to `/3` (PR #514 review)

## 1.7.103 - 2026-05-02

### Added
- V107 migration: pin AI endpoints to a specific integration row via `integration_uuid` + add the missing unique index on `lower(name)` (PR #511)
  - Nullable `integration_uuid uuid` column on `phoenix_kit_ai_endpoints` with btree index
  - Backfill maps existing `provider` strings to integration rows: exact `"provider:name"` matches get the corresponding storage row; bare `"provider"` gets the most-recently-validated `integration:provider:*` row, tiebreaking on `uuid ASC` (UUIDv7 time-ordered). Unresolvable endpoints stay NULL
  - Unique index `phoenix_kit_ai_endpoints_name_index ON (lower(name))` — the `unique_constraint(:name)` declaration in the changeset has been dead code since V34 created this table without the index
- V108 migration: `position integer DEFAULT 0` on three admin list surfaces — `phoenix_kit_entities`, `phoenix_kit_cat_catalogues`, `phoenix_kit_cat_items` — so drag-and-drop reordering can persist user-driven order (PR #512)
- Strict-UUID Integrations public API (PR #511)
  - Write-side APIs now take only the integration row's uuid — no more deriving storage keys from JSONB fields
  - `Integrations.resolve_to_uuid/1` — dual-input lookup primitive that accepts a uuid or a `provider:name` string (for `migrate_legacy/0` callbacks)
  - `migrate_legacy/0` optional callback on `PhoenixKit.Module` — each module owns its legacy data shape; core provides primitives. Orchestrated by `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`
  - Mistral, DeepSeek, and Microsoft 365 added to the built-in providers registry
  - `integration_picker` updated: no auto-select on single-provider, toggle-to-deselect support
- Drag-and-drop core infrastructure (PR #512)
  - `<.draggable_list>` new `:draggable` boolean attr (default `true`) — when false, renders without SortableJS hook and grab-cursor styling
  - `<.table_default>` new `:on_reorder`, `:reorder_scope`, `:reorder_group`, `:item_id` attrs — wire the card-view container as a SortableGrid hook target for cross-container drag
  - `SortableGrid` hook (JS): `data-sortable-group` for cross-container drag, `readScope/1` helper for `data-sortable-scope-*` attrs, cross-container `onEnd` detection with `from*` scope prefix, `try/catch` wrapping
  - `TableCardView` hook (JS): `updated()` callback re-applies saved view mode after LV re-renders so card/table toggle survives SortableJS drops
- Media viewer modal on `MediaBrowser` (PR #513)
  - New `viewer={true}` attr — clicking a file opens an in-place modal with image/video/PDF/icon preview, metadata sidebar (filename, type, MIME, size, uploaded date), and Download button. Closes via X / Esc / backdrop
  - Prev/next chevrons and ArrowLeft/ArrowRight keyboard shortcuts step through the current page's files; arrows hide at boundaries
  - `PhoenixKitComments.Web.CommentsComponent` embedded in the sidebar when the Comments module is installed and enabled (optional-dep wiring: `@compile {:no_warn_undefined}` + `Code.ensure_loaded?` + `@dialyzer :nowarn_function`)
- Arity-2 `dynamic_children_fn` `@typedoc` + test-only delegate for the admin sidebar dispatcher (PR #506 follow-up in #512)

### Changed
- `handle_event("click_file", …)` in MediaBrowser refactored from two-mode `if/else` to four-clause `cond`: `select_mode` → `admin` → `viewer` → picker default (PR #513)
- `connected_at` semantics clarified in AGENTS.md — rewritten on every successful re-test (not one-shot); `last_validated_at` rewritten unconditionally on every validation attempt, success or failure
- Bumped `leaf` editor dependency `~> 0.2.10 → ~> 0.2.11` and the matching CDN URL (PR #513)

### Fixed
- AGENTS.md doc drift: `PhoenixKit.Modules.run_all_legacy_migrations/0` corrected to `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`; V107 moduledoc tiebreak clarified as `uuid ASC` not `inserted_at ASC` (PR #511 review)
- V107 unique-name index verified with three new integration tests: index exists, duplicate names rejected, case-only differences collide (PR #511 review)
- Media viewer modal: `String.starts_with?/2` guarded with `is_binary(f.mime_type)` so nil mime_type falls through to the icon fallback instead of crashing (PR #513 review)
- Media viewer modal: PDF iframe hardened with `sandbox="allow-same-origin"` to block embedded JavaScript in same-origin deployments (PR #513 review)
- `<.draggable_list>` `data-id` now always emitted regardless of `:draggable` attr so click-to-select handlers and test selectors work in both modes (PR #512 review)
- `:reorder_scope` attr doc on `<.table_default>` now documents the camelCase round-trip (`:category_uuid` → `"categoryUuid"` in the LV handler payload) (PR #512 review)

## 1.7.102 - 2026-04-29

### Added
- V105 migration: CRM tables for the upcoming `phoenix_kit_crm` plugin (PR #507)
  - `phoenix_kit_crm_role_settings` — one row per role with `enabled BOOLEAN NOT NULL DEFAULT false` so existing roles stay opted out until explicitly enabled. PK on `role_uuid`; FK → `phoenix_kit_user_roles(uuid)` ON DELETE CASCADE
  - `phoenix_kit_crm_user_role_view` — per-user, per-scope view preferences (column selection, ordering, filters). UUIDv7 PK; unique `(user_uuid, scope)`; index on `(user_uuid)`; FK → `phoenix_kit_users(uuid)` ON DELETE CASCADE. `scope` is a string like `"role:<uuid>"` or `"companies"`
- V106 migration: split `phoenix_kit_projects.name` uniqueness across templates and real projects (PR #510)
  - Replaces V101's single global unique index on `lower(name)` with two partial unique indexes: `phoenix_kit_projects_name_template_index WHERE is_template = true` and `phoenix_kit_projects_name_project_index WHERE is_template = false`
  - Lets a template `"Onboarding"` and a real project `"Onboarding"` coexist, unblocking `Projects.create_project_from_template/2` for the common reuse-the-template-name path
  - `down/1` recreates V101's single global index; lossy if a template and a real project share a name post-V106 — resolve duplicates before rolling back
- Legal module i18n — translations across `de/fr/it/pl` plus refreshed `ru/es`. New `de/fr/it/pl` POs created via `mix gettext.merge --locale` with proper `Plural-Forms` headers (German `n != 1`, French `n > 1`, Italian `n != 1`, Polish 3-form rule). Pre-existing non-empty `msgstr` values preserved (PR #509)
- `lib/phoenix_kit_web/legal_gettext_manifest.ex` — re-emits the 50 translatable strings used by `phoenix_kit_legal` so the gettext extractor (which doesn't walk into deps) records them into core's POT. Never called at runtime; pure extraction target with refresh procedure documented in the moduledoc (PR #509)
- `css_sources/0` accepts string entries — `@callback css_sources()` widened from `[atom()]` to `[atom() | String.t()]`. Strings flow through `format_source/2` → `source_for_path/1` (absolute paths emit `@source "<abs>";` verbatim, relative get the standard `../../` prefix); atoms continue to resolve via parent app's mix.exs deps. Lets modules mix OTP-app atoms with literal path strings — first known consumer is `phoenix_kit_legal`, which ships a path-dep absolute fallback alongside its OTP-app entry so both Hex and path-dep installs work without parent-app toggles. Backwards compatible: existing `def css_sources, do: [:phoenix_kit_my_module]` keeps working unchanged (PR #509)

### Changed
- Bumped `leaf` editor dependency `~> 0.2.6 → ~> 0.2.10` and the matching CDN URL in `priv/static/assets/phoenix_kit.js` so the runtime loader pulls the same version. Includes `min-width: 0` + toolbar-wrap fixes so the editor stops claiming an unbounded intrinsic width on mount (PR #508)
- `priv/gettext/default.pot` cleanup — dropped ~900 phantom msgids left over from modules extracted to standalone packages (billing, publishing, entities, etc.) (PR #509)

### Fixed
- `application/pdf` uploads in MediaBrowser. `determine_file_type/1` returned `"pdf"`, but the `File` changeset validates `file_type` against `["image", "video", "audio", "document", "archive", "other"]` — every PDF upload silently failed validation and never reached any bucket. Now maps `application/pdf` → `"document"`, matching how form-upload integrations already classify PDFs (PR #507)
- V106 `COMMENT ON TABLE` version values were off by one (`up` wrote `'105'` instead of `'106'`, `down` wrote `'104'` instead of `'105'`). The migration framework reads this comment as the source of truth for the migrated version, so on the incremental V105 → V106 upgrade path the comment never advanced past `'105'` — V106.up would replay on every deploy and the admin dashboard / `mix phoenix_kit.status` would report a stale version. Fresh installs masked the bug because `handle_version_recording/4` stamps the final version on multi-step runs and overrode V106's bad write. Caught in review of PR #510 and amended in place since V106 had not yet shipped to Hex

## 1.7.101 - 2026-04-24

### Added
- **Notifications module** — per-user inbox driven by the activity log. When `PhoenixKit.Activity.log/1` records an entry with `target_uuid != actor_uuid`, a row is inserted into `phoenix_kit_notifications` for the target user. Independent `seen_at` / `dismissed_at` per row, per-user PubSub topic (`"phoenix_kit:notifications:<user_uuid>"`), global kill-switch via `notifications_enabled` setting (default `"true"`). Admins still audit via `/admin/activity` and don't receive notifications (PR #505)
  - V104 migration: `phoenix_kit_notifications` with UUIDv7 PK, FKs to `phoenix_kit_activities` and `phoenix_kit_users` (both `ON DELETE CASCADE`), unique `(activity_uuid, recipient_uuid)` index, partial `(recipient_uuid, inserted_at DESC) WHERE dismissed_at IS NULL` index for the inbox read path
  - `PhoenixKit.Notifications` public API: `maybe_create_from_activity/1`, `list_for_user/2`, `recent_for_user/2`, `count_unread/1`, `mark_seen/2`, `mark_all_seen/1`, `dismiss/2`, `dismiss_all/1`, `get_notification/2`, `enabled?/0`, `retention_days/0`, `prune/1`
  - `PhoenixKit.Notifications.Render.render/1` — maps action → `%{icon, text, link, actor_uuid}`; honors metadata overrides (`notification_text`, `notification_icon`, `notification_link`) before falling back to the action lookup
  - `PhoenixKit.Notifications.Types` registry — three core types (`account`, `posts`, `comments`) plus extension point for external modules via the new optional `notification_types/0` callback on `PhoenixKit.Module`
  - `PhoenixKit.Notifications.Prefs` — per-user preferences persisted in `custom_fields.notification_preferences` (reuses V18 JSONB column; no migration). Fail-open on any ambiguity
  - `PhoenixKit.Notifications.PruneWorker` — daily Oban cron at `"0 4 * * *"`; retention via `notifications_retention_days` (falls back to `activity_retention_days`, default 90)
  - `PhoenixKitWeb.Live.NotificationsBell` — sticky nested LiveView for the bell + dropdown. Not mounted by default; parent apps render it where they have a user-facing header via `Phoenix.Component.live_render(..., sticky: true, session: %{"user_uuid" => ...})`. Badge + recent list refresh live via PubSub
  - Notification preferences section in `PhoenixKitWeb.Live.Components.UserSettings` — one toggle per registered type; unknown submitted keys dropped at the call site
  - `notifications_enabled` toggle on `/admin/settings`
- Arity-2 `dynamic_children_fn` for admin sidebar tabs — callbacks can now be `(scope, locale -> [tab])` in addition to the existing `(scope -> [tab])`. Backwards-compatible extension: the sidebar dispatches on arity, every existing 1-arity callback keeps working unchanged. Lets plugins render locale-aware child labels without reading `Gettext.get_locale/1` at render time (PR #506)

## 1.7.100 - 2026-04-22

### Added
- V103 migration: nullable self-FK `parent_uuid` on `phoenix_kit_cat_categories` with b-tree index on `(parent_uuid)` for arbitrary-depth category trees. Existing rows stay `NULL` and become roots — no backfill. No DB-level `ON DELETE` cascade (subtree cascades are owned by the context layer so they go through soft-delete + activity log) (PR #503)
- `scope_folder_id` attr on `PhoenixKitWeb.Live.Components.MediaSelectorModal` — filters the browse query to the given folder plus any files reached via `FolderLink`, and assigns newly-uploaded files into that folder (adopt as home if orphan, else add a `FolderLink`). Plugins scoping the picker to a single domain object (e.g. a catalogue item) pass this after lazy-creating their folder (PR #503)
- `PhoenixKit.Settings.Setting.optional_settings/0` accessor exposing `@optional_settings` for invariant tests
- Invariant test (`test/phoenix_kit/settings/setting_test.exs`) asserting every empty-string default in `PhoenixKit.Settings.get_defaults/0` is also in `@optional_settings`, to prevent the class of bug fixed in PR #502 from recurring

### Changed
- `PhoenixKit.Modules.Storage.File` changeset `file_type` allowlist widened from `["image", "video", "document", "archive"]` to include `"audio"` and `"other"` so non-image/video uploads bucket cleanly (PR #503)
- `MediaSelectorModal.load_files/2` refactored into four composable `scope_files_by_{user,folder,type,search}` helpers — credo cyclomatic-complexity fix from adding the new scope branch (PR #503)

### Fixed
- Settings batch save no longer rolls back when `site_icon_file_uuid` or `default_tab_title` is left empty on the General Settings form. Both keys added to `@optional_settings` in `PhoenixKit.Settings.Setting` and seeded with empty-string defaults in `PhoenixKit.Settings.get_defaults/0` (PR #502)
- `MediaSelectorModal.maybe_set_folder/2` errors (from the `folder_uuid` update or `FolderLink` insert) now log a warning via `warn_on_folder_error/3` instead of being silently discarded by `_ =`. Previously, a failed scope assignment after a successful upload left no trace

## 1.7.99 - 2026-04-20

### Added
- V100 migration: staff tables — `phoenix_kit_staff_departments`, `phoenix_kit_staff_teams`, `phoenix_kit_staff_people`, `phoenix_kit_staff_team_memberships` (PR #498)
- V101 migration: projects tables — `phoenix_kit_project_tasks`, `phoenix_kit_project_task_dependencies`, `phoenix_kit_projects`, `phoenix_kit_project_assignments`, `phoenix_kit_project_dependencies`; polymorphic assignee with `CHECK (num_nonnulls(...) <= 1)` (PR #498)
- V102 migration: smart catalogues + per-catalogue/item discount (PR #500)
  - `phoenix_kit_cat_catalogues.discount_percentage` (NOT NULL DEFAULT 0) and `kind` (`'standard' | 'smart'`) columns with CHECK constraints
  - `phoenix_kit_cat_items.discount_percentage`, `default_value`, `default_unit` override columns
  - new `phoenix_kit_cat_item_catalogue_rules` table with unique `(item_uuid, referenced_catalogue_uuid)` and ON DELETE CASCADE on both FKs
  - partial index on `kind = 'smart'`
- `PhoenixKitWeb.Components.MediaBrowser.Embed` — one-line `use` macro that injects `on_mount` upload setup, the `"validate"` upload-channel stub, and the MediaBrowser `handle_info` delegator (PR #499)
- MediaBrowser selection menu with bulk download (staggered `<a download>` dispatch via `MediaDragDrop` hook) (PR #499)
- MediaBrowser `admin` attr to gate detail-page `push_navigate` — picker mode (default) vs admin mode (PR #499)
- MediaBrowser drag-drop file-to-folder move (PR #499)
- MediaBrowser toggleable search bar in the header (PR #499)
- MediaBrowser drag-drop upload at any folder level (PR #499)
- Site icon + default tab title settings, logo moved to main settings page (PR #499)
- MultilangForm debounce flow: `mount_multilang/1` attaches a hidden `:handle_info` hook via `Phoenix.LiveView.attach_hook/4`; `handle_switch_language/2` schedules a 150 ms trailing debounce via `Process.send_after` (timer ref stored in `socket.private` to avoid render+diff cycles); `switch_lang_js/2` toggles skeleton/fields `hidden` classes client-side at t=0 (PR #500)
- `<.input>` gains a `wrapper_class` attr for the outer `phx-feedback-for` div (PR #500)
- `test_load_filters` / `test_ignore_filters` in `mix.exs` for Elixir 1.19 `mix test` hygiene (PR #500)
- AGENTS.md: Core Form Components section, Multilang Form Components section, and CHANGELOG-ownership rule (entries written by the maintainer, not agents)

### Changed
- MediaBrowser sidebar and content unified into a single card (PR #499)
- Scope-root new-folder form aligned with sibling folder rows (PR #499)
- Core form components (`<.input>`, `<.select>`, `<.textarea>`, `<.checkbox>`) now merge the `class` attr onto the styled element itself — matches the Phoenix 1.7 generator convention. No in-tree caller used the old wrapper-class behavior; external consumers should switch to `wrapper_class` on `<.input>` (PR #500)
- `compile.phoenix_kit_css_sources` emits absolute dep paths verbatim instead of prefixing `../../` (PR #500)

### Fixed
- MediaBrowser list view broken by stale view-toggle CSS (PR #499)
- Credo `AliasUsage` warning inside `MediaBrowser.Embed`'s quoted block silenced (PR #499)

## 1.7.98 - 2026-04-16

### Added
- V99 migration: `trashed_at` column on `phoenix_kit_files` with partial index for soft-delete (PR #497)
- Media trash bucket: soft-delete files with restore/empty/permanent-delete actions and sidebar count badge
- `PhoenixKit.Modules.Storage.Workers.PruneTrashJob` — daily Oban cron (3 AM) that permanently deletes files older than `trash_retention_days` (default 30)
- Drag-drop upload: drop device files directly onto the folder content area (`FolderDropUpload` JS hook)
- URL-param hydration on first mount so reloads don't flash the root view

### Fixed
- Scope guard on `restore_selected` in MediaBrowser — a scoped embed could previously restore files outside its scope via a crafted `toggle_select` payload
- Trash view, permanent-delete, and `empty_trash` now respect `scope_folder_id` via recursive CTE
- `list_files/1` excludes trashed files
- Breadcrumb and search bar moved inside card body so padding matches grid/list content

## 1.7.97 - 2026-04-15

### Added
- V97 migration: per-item `markup_percentage` override on catalogue items (PR #493)
- V98 migration: `alternative_formats` column on storage dimensions
- `PhoenixKit.Modules.Shared.Components.ImageSet` — responsive `<picture>` component with AVIF/WebP/JPEG `<source>` entries
- `PhoenixKit.Modules.Storage.VariantNaming` — format-suffix parsing utility
- Multi-format variant generation (WebP/AVIF alongside primary format per dimension)
- Variant dimensions and file sizes shown on media detail page
- UUID search support on media page search bar

### Changed
- V95 migration made truly idempotent for `folder_uuid` column (raw SQL `IF NOT EXISTS` block)
- Dimensions table format cell renders as `JPEG + WEBP, AVIF` (fixed stray `" +"` separator)

### Fixed
- Long text overflow in media detail sidebar
- Missing original file size in variant download buttons

## 1.7.96 - 2026-04-13

### Added
- Sortable languages in admin (drag-and-drop reorder)
- hide_source option on DraggableList component
- Wiggle animation for reorder mode with prefers-reduced-motion support

### Changed
- Dedup language codes in reorder, use MapSet for lookup
- Extract wiggle CSS to JS-injected styles with pk- prefix

## 1.7.95 - 2026-04-11

### Added
- V95 migration: media folders and folder links tables
- V96 migration: catalogue_uuid FK on catalogue items for direct catalogue membership

## 1.7.94 - 2026-04-10

### Added
- Media folder system with sidebar, select mode, list/grid view, drag-drop file moving
- Folder colors, inline rename, select folders, and context menus
- Search bar and folder path column to media page
- Media Health page for redundancy monitoring
- Sync with progress tracking, pause/resume/stop controls, real-time sync log
- Media sync moved to Oban worker for persistence and reliability
- Multipart S3 uploads
- Tigris storage provider support
- Test Connection button to bucket form
- Configurable max upload size setting
- Reusable SearchableSelect LiveComponent
- Provider-specific labels for B2, R2, and S3 bucket configuration
- AWS regions dropdown via `aws_regions` hex package

### Changed
- Rename Storage to Media, use thumbnail variant for media grid
- Redesign media sidebar with proper file explorer conventions
- Migrate bucket and dimensions tables to `table_default` component
- Restyle bucket/dimension forms with card sections and DaisyUI 5 fieldset/legend
- Persist folder tree expand state and sidebar collapsed in localStorage
- Remove LLMText module (preserved in feature/llmtext branch)
- Remove CDN URL field from bucket configuration form

### Fixed
- Fix #478: register CSS sources compiler and create stub file on install
- Fix integration activity logs always having nil actor_uuid
- Fix S3 upload failures and false file location records
- Fix folder card hover lag (use `transition-colors` instead of `transition-all`)
- Fix folder name truncation, rename animation, and input autofocus
- Fix select mode content jump and improve render performance
- Fix mix tasks: `Routes.path` unavailable, `ecto.migrate` skips host repo
- Fix OAuth users getting signed out after ~1-2 hours

## 1.7.93 - 2026-04-08

### Fixed
- Fix installer to auto-inject PhoenixKitHooks into app.js
- Fix decrypt after legacy integration migration
- Improve OAuth login with remember_me by default

### Added
- Activity logging for Integrations (setup, connect, disconnect, token refresh, validation)
- Cookie max_age set to 60 days

### Changed
- Simplify integration status: `configured` removed, now `connected` or `disconnected`
- Validate connection checks provider exists before credentials

## 1.7.92 - 2026-04-07

### Fixed
- Fix Google token refresh for named integration connections (e.g. google:work)
- Add resolve_provider_lookup_key/2 and resolve_storage_key/2 helpers

### Added
- Add V94 migration for Document Creator sync (google_doc_id, status, path, folder_id columns)

## 1.7.91 - 2026-04-06

### Added
- Add centralized Integrations system for external service connections (OAuth, API keys, bot tokens)
- Add AES-256-GCM encryption at rest for stored credentials
- Add OAuth 2.0 CSRF state parameter protection
- Add `required_integrations/0` and `integration_providers/0` callbacks to PhoenixKit.Module
- Add IntegrationPicker reusable component
- Add Integrations admin settings tab
- Add provider registry with Google and OpenRouter built-in

### Fixed
- Fix password field overwrite bug when editing integrations
- Fix duplicate line in `maybe_set_userinfo/2`
- Consolidate validation logic into Integrations context
- Make validation URL provider-configurable (no more hardcoded Telegram URL)

## 1.7.90 - 2026-04-04

### Added
- Add organization accounts support with person/organization user types
- Add organization invitations system with token-based invite flow
- Add V91 locations migration: location types, locations, and type assignments tables
- Add V92 organization accounts migration (invitations, user type fields)
- Add JS hooks integration for parent app install and update workflows
- Add LLMText module for AI/LLM-friendly content generation
- Add auth logo from settings to admin header
- Add billing tabs component

### Changed
- Move tax rate and CountryData from Billing to core PhoenixKit
- Remove hardcoded Billing and E-Commerce module cards in favor of auto-discovery
- Update AGENTS.md with severity level definitions and JS hooks documentation

### Fixed
- Fix double sidebar for core modules and improve struct compatibility
- Hide hamburger menu button when sidebar is permanently visible
- Fix token security, gettext, and validation issues in organization invitations
- Fix tax data loss, invitation status guard, and IbanData safety

## 1.7.88 - 2026-04-02

### Changed
- Migrate select elements to daisyUI 5 label wrapper pattern (#472)

### Fixed
- Fix negated condition in maintenance toggle flash message
- Fix dialyzer warnings for CSS sources compiler, clean up 6 stale ignore entries

## 1.7.87 - 2026-03-31

### Added
- Add V89 migration: catalogue pricing with base_price and markup_percentage
- Add status_badge component and wrapper_class attr to table_default
- Add inline and auto display modes to table_row_menu
- Add show_toggle attr to table_default and sync TableCardView instances
- Add continent grouping to language switcher for many languages
- Add language system tests, docs, error handling, and group_by_continent option

### Changed
- Unify admin and frontend language systems into single source of truth
- Unify status badge components into single status_badge
- Remove deprecated select-bordered class for daisyUI 5 compatibility
- Disable automatic CI triggers, switch to manual-only

### Fixed
- Fix language switcher URL generation for prefixed admin paths
- Fix dialyzer warnings in language switcher URL generation

## 1.7.86 - 2026-03-30

### Changed
- Update Shop module references from `PhoenixKit.Modules.Shop` to `PhoenixKitEcommerce` namespace
- Update Billing module references from `PhoenixKit.Modules.Billing` to `PhoenixKitBilling` namespace
- Restore LayoutWrapper in core module templates (not auto-applied to bundled modules)
- Document `extra_applications` requirement for external module auto-discovery

### Fixed
- Fix missing `url_path` assign in referrals LiveViews causing runtime crash after LayoutWrapper restoration
- Fix media selector modal mobile responsiveness (header overflow, button sizing, padding)

## 1.7.85 - 2026-03-30

### Added
- Add user-scoped media selector for avatar and fix custom fields position bug

### Changed
- Remove Pages module from core and clean up all references
- Extract Connections module into external `phoenix_kit_user_connections` package
- Remove unused Storage alias from user settings

## 1.7.84 - 2026-03-28

### Added
- Add missing cookie consent widget to dashboard layout
- Add user dashboard routes for billing profiles

### Changed
- Remove Legal module from core (extracted to `phoenix_kit_legal` package)
- Remove LayoutWrapper from remaining storage and maintenance templates
- Remove duplicate LayoutWrapper from admin module templates

### Fixed
- Fix core modules misclassified as external plugin views causing double admin chrome

## 1.7.83 - 2026-03-27

### Added
- Add V88 migration: Publishing schema V2 restructure
- Add user dashboard generator with LiveView templates and standardize layout
- Add `--index` flag to user dashboard generator for overriding default dashboard
- Add Estonian to backend languages, fix Chinese code zh-CN → zh
- Add CountryData to core utils for billing extraction
- Add sitemap scheduler startup recovery

### Changed
- Extract Comments module into external `phoenix_kit_comments` package
- Remove Shop module from core (extracted to `phoenix_kit_ecommerce` package)
- Remove Billing module from core (extracted to `phoenix_kit_billing` package)
- Replace hardcoded external module stats with generic `module_stats` callback
- Remove hardcoded module cards for extracted packages
- Rename and simplify admin page generator
- Update Leaf dependency to v0.2.6

### Fixed
- Fix V88 migration: index prefix and partial re-run safety
- Fix orphan files query to use `publishing_versions` table
- Fix post-review issues from PR #453: Shop.Cart guard, consent attrs, language naming
- Fix shop modules: remove billing struct patterns and fix nil clause ordering
- Fix double navbar on comments admin pages
- Fix auth page background breaking footer and page layout

## 1.7.82 - 2026-03-24

### Added
- Add V86 migration: Document Creator tables (headers_footers, templates, documents)
- Add V87 migration: Catalogue tables (manufacturers, suppliers, catalogues, categories, items)
- Add `system_prompt` field to AI prompts and AI Playground page
- Add database connection check to install and update tasks
- Add AdminEditHelper for universal admin edit links in public views
- Add email provider behaviour, refactor Mailer and UserNotifier
- Add lastmod to sitemap group listings and homepage
- Enrich external module cards with config stats, settings link, and `module_card` component

### Changed
- Extract Emails module from core to standalone `phoenix_kit_emails` package
- Extract Publishing module to standalone `phoenix_kit_publishing` package
- Extract Entities module to standalone `phoenix_kit_entities` package
- Extract AI module to standalone `phoenix_kit_ai` package
- Remove hardcoded Emails block from Modules page — now rendered as external package
- Guard all Publishing references behind `Code.ensure_loaded?` for external module support
- Guard EntityForm render call with `Code.ensure_loaded?` check in Pages renderer
- Suppress warnings for optional external modules with `@compile :no_warn_undefined`
- Exclude external module namespaces from Credo alias usage check
- Make module registry and permissions tests count-independent after module extractions
- Document `ensure_compiled` vs `ensure_loaded?` choice in integration route collection
- Update Leaf dependency to v0.2.5

### Fixed
- Fix V86/V87 migrations to use `uuid_generate_v7()` instead of `gen_random_uuid()`
- Fix post-merge issues from Emails extraction
- Fix `extract_admin_links`: skip parent tabs, deduplicate paths
- Fix `external_plugin_view?` to recognize `PhoenixKit.Modules.*.Web` as external packages
- Fix DbConnectionCheck: correct spec, naming, and remove hard exit from status task
- Fix media selector modal z-index to appear above all overlays
- Fix `module_card` to render `hero-*` icons properly
- Fix cookie consent: dynamic legal links, theme-aware backdrop, daisyUI toggle

## 1.7.81 - 2026-03-21

### Changed
- Extract Posts module to standalone `phoenix_kit_posts` package
- Update Comments module to conditionally load Posts handler via `Code.ensure_loaded?/1`
- Update scheduled jobs worker with extracted catch-up helpers for optional Posts dispatch

## 1.7.80 - 2026-03-20

### Added
- Add `uuid` type to custom fields system
- Add auto-registration of custom field definitions on save with type inference

### Changed
- Extract Sync module to standalone `phoenix_kit_sync` package
- Move custom fields domain logic to `CustomFields` module, deduplicate UUID regex, add error logging
- Fix permissions table style — replace manual zebra striping with daisyUI `table-zebra`, use primary-colored header

### Fixed
- Fix avatar upload handling and `custom_fields` preservation in UserSettings
- Fix admin page and user dashboard styles
- Fix plugin reference name in module system guide

## 1.7.79 - 2026-03-20

### Fixed
- Fix UserSettings regressions from PR #436 redesign:
  - Restore timezone selector (timezone select, mismatch warning, browser detection)
  - Restore Apple OAuth provider icon (`hero-device-phone-mobile`)
  - Restore OAuth-only password warning for users without passwords
  - Restore provider email display in connected accounts list
  - Fix custom field `select` using index-based values instead of actual option values (data compatibility break)
  - Restore all custom field input types (`textarea`, `number`, `email`, `url`, `date`) — were collapsed to plain text
  - Restore `required` attribute on custom field inputs
  - Restore unique `id` attributes on password/email form hidden inputs
  - Restore profile/avatar success and error messages in template
  - Fix `shadow-xl` → `shadow-sm` for card styling consistency
  - Fix divider placement — move out of username field, add "Additional Information" heading for custom fields
  - Extract `extract_custom_fields/1` and `merge_custom_fields/3` helpers to DRY duplicated logic

## 1.7.78 - 2026-03-18

### Added
- Add Tailwind/daisyUI class injection for markdown rendering — replaces inline `<style>` block with classes injected during Earmark post-processing (works without `@tailwindcss/typography` plugin)
- Add blank line preservation in markdown content — intentional double blank lines render as visible spacing
- Add translation worker retry resilience — on retry, already-translated languages are skipped by checking content timestamps against job `inserted_at`
- Add dynamic timeout scaling for translation worker (~1.5 min per language, minimum 15 minutes)
- Add structured logging with consistent prefixes (`[Sync.Notifier]`, `[Sync.API]`, `[Sync.Connections]`) throughout Sync connection flow
- Add connection event logging on both sender and receiver sides for debugging

### Changed
- Rename Sync "Sender/Receiver" terminology to "Outgoing/Incoming" across UI
- Allow editing incoming Sync connections (previously restricted to outgoing only)
- Remove "with permanent connections" from Sync index page subtitle
- Bump markdown render cache version to v2 to invalidate stale cached HTML

### Fixed
- Fix Sync sender URL resolving to `localhost:4000` — now checks DB `site_url` setting before falling back to endpoint config
- Fix `auth_token_hash` logged in full — truncate to first 8 characters in Sync connection logs
- Fix double `get_our_site_url()` call per notification — pass resolved URL instead of recomputing
- Fix Sync crash on non-UTF8 binary data — base64-encode raw binaries during serialization, decode on import
- Fix Sync pull error responses silently ignored — add `Logger.error` to all failure paths (401, 404, HTTP errors, offline, invalid response)
- Fix Sync completion UI not showing skipped/errored records — track and display per-table import counts with warning state

## 1.7.77 - 2026-03-17

### Added
- Add Open Graph and Twitter Card meta tags for public publishing pages (og:title, og:description, og:image, og:url, og:locale, canonical link, and Twitter Card tags)
- Add `og:site_name` meta tag using project title
- Add `resolve_language_key/2` helper to `LanguageHelpers` for base code to dialect code matching in language maps
- Add Tailwind Typography prose overrides using daisyUI theme variables (oklch(--bc), oklch(--p), oklch(--b2), oklch(--b3)) for theme-aware markdown styling
- Add automated scheduled jobs cleanup to prevent table bloat (deletes completed jobs older than 7 days)
- Add `lastmod` (last modified) to sitemap entries for SEO — router-discovered routes use beam file mtime, static entries use current date

### Changed
- Replace inline markdown CSS with centralized prose overrides in `app.css` using `@layer base` (removes 323 lines of duplication)
- Update publishing preview template to show full public interface with working language switcher
- Move `MarkdownContent` component to use Tailwind prose classes instead of custom inline styles
- Extract duplicated `resolve_language_key/2` from `listing.ex` and `html.ex` to shared `LanguageHelpers` module
- Extract `update_post_from_form/3` from publishing editor to reduce cyclomatic complexity (from >10 to <10)
- Update Leaf content editor dependency from v0.1.0 to v0.2.0

### Fixed
- Fix `mix phoenix_kit.status` showing V01 instead of actual migration version — properly start Repo with parent app config when using `--no-start`
- Fix language map lookup when canonical URL uses base code (e.g., "en" → "en-US" matching)
- Fix `absolute_url/2` to use stricter URL protocol checking ("http://" or "https://" instead of just "http")
- Fix preview language links to conditionally include version parameter only when version is non-nil
- Fix translation reload showing primary language content instead of translated content
- Fix PubSub subscription mismatch for translation and version events on timestamp-mode posts (slug vs uuid topic mismatch)
- Fix email template seeding failing on fresh install (wrap string fields in i18n maps)
- Fix whitespace in slug format examples on publishing group pages

## 1.7.76 - 2026-03-16

### Fixed
- Fix `mix phoenix_kit.status` port conflict when app is already running (use `--no-start` to avoid booting the HTTP endpoint)
- Add self-healing version comment detection — automatically corrects V83 comment bug where migrations ran but version stayed at V82

## 1.7.75 - 2026-03-16

### Added
- Add `custom_fields` support to `registration_changeset/3` for atomic user creation with custom metadata
- Add entity data view extension documentation and route override pattern

### Fixed
- Fix mobile overflow issues in email module UI (queue, blocklist, metrics, template editor)
- Fix early validation in template editor — errors only shown after first user interaction
- Fix Send Test Email modal overflowing on mobile (max-w-4xl → max-w-2xl)
- Fix V83 migration missing `down/1` version comment rollback
- Fix V83 migration prefix_str inconsistency in version comment
- Fix dialyzer `guard_fail` warnings from upstream publishing merge
- Fix remaining doc warnings for delegated hidden functions

## 1.7.74 - 2026-03-16

### Fixed
- Remove dead `should_regenerate_cache?/1` from Shared module (uncalled function returning `true` in every branch)
- Remove obsolete `bulk_operation_topic` test referencing deleted PubSub function
- Fix missing trailing newline in `shared.ex`

## 1.7.73 - 2026-03-13

### Changed
- Move module access guards from individual mount functions to centralized `enforce_admin_view_permission` hook
- Disabled modules now block all roles (including Owner/Admin) at the `on_mount` level, covering all ~50 admin LiveViews automatically
- Remove per-LiveView `enabled?()` mount guards from AI, Entities, Publishing, Sitemap, Billing, Customer Service, Emails, Email Tracking, Legal, Referrals, Shop settings

## 1.7.72 - 2026-03-13

### Added
- Add module access guards — disabled modules now hide action buttons and block mount on settings/endpoints
- Add error flash auto-dismiss after 8 seconds
- Add `enabled?()` mount guards to AI, Media, Entities, Publishing, Sitemap endpoints
- Add error logging in Legal `list_generated_pages` instead of silent rescue

### Fixed
- Fix Legal module broken connection with DB-backed Publishing (`post.path` → `post.uuid`, `updated_at` → `published_at`)
- Fix Legal module Configure button guard when module is disabled
- Fix Sitemap RouterDiscovery including routes from disabled modules
- Fix DB.Listener missing `{:eventually, _ref}` case for auto_reconnect

### Changed
- Remove duplicate enable/disable toggles from 7 module settings pages (Emails, Email Tracking, Legal, Referrals, Billing, Customer Service, Shop)
- Simplify primary_language lookup in Publishing.DBStorage

## 1.7.71 - 2026-03-12

### Fixed
- Fix mixed atom/string key error in `EntityData.maybe_add_position/1` when auto-assigning position to string-keyed params
- Fix same mixed key error in `EntityData.maybe_add_created_by/1`
- Fix `FOR UPDATE` with aggregate function error in `EntityData.next_position/1` (PostgreSQL `0A000 feature_not_supported`)

## 1.7.70 - 2026-03-12

### Added
- Add PhoenixKitGlobals component for JavaScript globals injection
- Add metadata JSONB field to comments schema (V82 migration)
- Add reply indicators to admin comments page
- Add test comments seed script for visual verification
- Add admin page generator category index pages with automatic route registration
- Add duplicate validation (ID, URL, label) to admin page generator
- Add compile-time warning for unresolved legacy admin LiveView modules
- Add `phoenix_kit_app_base/0` helper to Routes utility

### Fixed
- Fix dimension form inputs clearing each other on change
- Fix MarkdownEditor toolbar not working on LiveView navigation
- Fix CommentsComponent crash on post details page (`resource_id` → `resource_uuid`)
- Fix credo alias ordering in integration module
- Fix WebP transparency loss in center-crop image processing
- Fix 304 Not Modified support in FileController

### Changed
- Update admin page generator to use flat `admin_dashboard_tabs` config with `live_view` field
- Deprecate legacy `admin_dashboard_categories` config format (warning on use)
- Auto-infer LiveView modules from URL paths for legacy admin categories
- Add `attr :rest, :global` to `phoenix_kit_globals` component

## 1.7.69 - 2026-03-10
- Add responsive multi-column card grid to `table_default` component: 1 col on mobile, 2 cols on md, 3 cols on lg breakpoints
- Style card view cards with `bg-base-200` and `shadow-sm` to visually distinguish them from the page background

## 1.7.68 - 2026-03-10
- Merge upstream changes: publishing editor rework, AI translation, bulk group actions, V77/V78 migration fixes, scheduled jobs queue, Settings.Queries module, plugin migration callbacks

## 1.7.67 - 2026-03-10

### Breaking Changes (requires manual steps in parent app)
- V79 migration rewritten in-place: drops `phoenix_kit_mailing_*` tables, creates `phoenix_kit_newsletters_*`
- Oban queue renamed: `mailing_delivery` → `newsletters_delivery` (update `config/config.exs`)
- Settings keys changed: `mailing_enabled` → `newsletters_enabled`, `mailing_default_template` → `newsletters_default_template`, `mailing_rate_limit` → `newsletters_rate_limit`
- Email template category value changed: `"mailing"` → `"newsletters"` (existing templates need DB update)
- URL paths changed: `/admin/mailing/*` → `/admin/newsletters/*`, `/mailing/unsubscribe` → `/newsletters/unsubscribe`

### Changed
- Rename `PhoenixKit.Modules.Mailing` → `PhoenixKit.Modules.Newsletters` and all submodules
- Rename DB tables: `phoenix_kit_mailing_lists/list_members/broadcasts/deliveries` → `phoenix_kit_newsletters_*`
- Rename Elixir modules: `Mailing.List`, `Mailing.Broadcast`, `Mailing.Delivery`, `Mailing.ListMember`, `Mailing.Broadcaster`, `Mailing.Workers.DeliveryWorker` → `Newsletters.*`
- Rename web modules: `Mailing.Web.*` → `Newsletters.Web.*`
- Rename route module: `PhoenixKitWeb.Routes.MailingRoutes` → `NewslettersRoutes`
- Rename dashboard tabs: `:admin_mailing` → `:admin_newsletters`

## 1.7.66 - 2026-03-09
- Clean up publishing module: fix UUID routing bugs (slug vs UUID in version creation, PubSub broadcasts, translation status), remove dead code and filesystem path references
- Optimize publishing DB queries: batch loading, ListingCache for dashboard, bulk UPDATE for translation statuses, debounced PubSub updates
- Rework editor to two-column layout with content-first design (title + editor left, metadata right)
- Rework AI translation: integrate AI prompt system, modal UI replacing slidedown, translation progress recovery across page refreshes
- Replace primary language banner with compact tooltip on language switcher
- Add skeleton loading UI for language switching in publishing editor
- Fix collaborative editing: spectator initial sync, lock promotion JS updates, lock expiration timer
- Fix admin sidebar highlighting for publishing group pages
- Fix custom fields card hidden when no field definitions are registered
- Add bulk "Add to Group" action on posts index with dynamic group filter dropdown

## 1.7.65 - 2026-03-08
- Fix V77 migration crash: role_id column renamed to role_uuid in UUID migration

## 1.7.64 - 2026-03-08
- Remove legacy filesystem paths from publishing module — strip all `.phk` virtual path references from mapper, editor, listing, and preview
- Switch all event handlers and navigation from path-based to UUID-based routing
- Fix timestamp-mode posts returning 404: normalize post_time to zero seconds, with hour:minute-only fallback query for legacy data
- Add collision prevention for same-minute timestamp posts (auto-bump to next minute, max 60 attempts)
- Add unique_constraint on (group_uuid, post_date, post_time) to schema
- Render empty listing page instead of 404 when group exists but has no published posts
- Show Primary Language banner during new post creation
- Add missing PubSub handlers to publishing Index view (version_created, version_live_changed, version_deleted) with catch-all
- Fix primary language migration using removed path field — now uses UUID/slug directly
- Remove cache management UI from listing page (accessible via settings only)
- Add safety guards to URL builders: raise ArgumentError on nil UUID instead of producing broken URLs

## 1.7.63 - 2026-03-06
- Remove filesystem storage from publishing module — delete Storage, DualWrite, and all storage/* submodules (~7k lines removed)
- Add LanguageHelpers and SlugHelpers as standalone modules, simplify to DB-only throughout
- Fix slug conflict clearing bug: `clear_url_slugs_for_conflicts` passed wrong slug to DB cleanup
- Fix ngettext interpolation in primary language migration modal (literal `%{count}` in UI)
- Clean up stale filesystem references in comments, docs, and user-facing strings
- Fix V77/V78 migration crashes when UUID columns are missing (tables created after V56 ran)
- Simplify V77/V78 migrations — remove over-engineered column detection, rely on idempotent patterns
- Fix email tracking bug: `handle_delivery_result` used `get_log!` (raises) in a nil-matching branch; add `get_log/1` non-bang wrapper and remove unused public functions
- Add `migration_module/0` callback to plugin module system — `mix phoenix_kit.update` auto-discovers and runs plugin migrations
- Add `Settings.Queries` module for database operations
- Add dedicated queue and 1-day pruner for scheduled jobs cron worker
- Fix user dashboard navigation links
- Fix ueberauth providers configuration format in installer

## 1.7.62 - 2026-03-05
- Fix UnicodeConversionError crash in integration plug when response body contains non-UTF8 binary data
- Fix DB browser rendering of raw binary values (e.g. UUID bytes) in table and activity views
- Add V78 migration: backfill missing AI module columns skipped by V41 conditional checks
  - Add `reasoning_enabled`, `reasoning_effort`, `reasoning_max_tokens`, `reasoning_exclude` to `phoenix_kit_ai_endpoints`
  - Add `prompt_uuid`, `prompt_name` to `phoenix_kit_ai_requests` with index and FK constraint

## 1.7.61 - 2026-03-04
- Replace `plug_cowboy` with `bandit ~> 1.0` as HTTP adapter (Phoenix 1.8 default)
- Remove stale deps from lock: `cowboy`, `cowlib`, `cowboy_telemetry`, `plug_cowboy`, `combine`, `dns_cluster`, `phoenix_live_dashboard`, `poolboy`, `timex`, `tzdata`
- Remove deprecated `fetch_live_flash` plug
- Add audit_log query limits
- Fix atom table exhaustion risk and remove duplicate function
- Update excluded_apps list in route resolver to match current deps
- Update HTML comments to EEx format in templates and components
- Clean up stale dep spec and dead commented-out code

## 1.7.60 - 2026-03-03
- Remove legacy FS→DB migration modules: `DBImporter`, `MigrateToDatabaseWorker`, `ValidateMigrationWorker`
- Remove `JsIntegration` install/update module (JS setup is now manual)
- Remove all "Import to DB" / "Migrate to Database" UI buttons from publishing pages
- Remove DB import/migration PubSub broadcast functions and LiveView handlers
- Simplify publishing listing: drop `fs_post_count`, `needs_import`, `db_import_in_progress` assigns
- Move post title field into the editor content column with larger styling
- Simplify editor save button logic (always clickable unless readonly/autosaving)
- Add `enrich_with_db_uuids/2` to ListingCache for UUID-based admin links in filesystem mode
- Refine Sync module: migrate `connection_id` references to `connection_uuid`
- Update publishing README to reflect DB-only storage model

## 1.7.59 - 2026-03-03
- Fix V75: use CASCADE when dropping `phoenix_kit_id_seq` (meta table `phoenix_kit.id` DEFAULT depends on it)

## 1.7.58 - 2026-03-03
- Add V75 migration: fix uuid column defaults and cleanup
  - Set `DEFAULT uuid_generate_v7()` on 27 tables missing it (Category A tables — V72 rename dropped old sequence DEFAULT)
  - Fix 4 tables using `gen_random_uuid()` (UUIDv4) → `uuid_generate_v7()` (UUIDv7)
  - Drop orphaned `phoenix_kit_id_seq` sequence

## 1.7.57 - 2026-03-03
- Fix V74 migration: skip tables without bigint `id` (e.g. publishing tables created with UUID PKs)
- Fix V74: use `DROP COLUMN id CASCADE` to handle dependent FK constraints in one statement

## 1.7.56 - 2026-03-03
- Add V74 migration: drop integer `id`/`_id` columns, promote `uuid` to PK on all tables
  - Drop all FK constraints referencing integer `id` columns (dynamic discovery)
  - Drop ~95 integer FK columns across all tables (sourced from uuid_fk_columns.ex + extras)
  - Drop bigint `id` PK + promote `uuid` to PK on 47 Category B tables
  - After V74, every PhoenixKit table uses `uuid` as its primary key — no integer PKs remain
- Remove `source: :id` from `webhook_event.ex` schema (DB column now matches field name)

## 1.7.55 - 2026-03-03
- Fix scheduled_job.ex `source: :id` regression — PR #383 reintroduced mapping to dropped DB column
- Add V73 migration: pre-drop prerequisites for Category B UUID migration
  - SET NOT NULL on 7 uuid columns (`ai_endpoints`, `ai_prompts`, `consent_logs`, `payment_methods`, `role_permissions`, `subscription_types`, `sync_connections`)
  - CREATE UNIQUE INDEX on 3 tables (`consent_logs`, `payment_methods`, `subscription_types`)
  - ALTER INDEX RENAME on 4 indexes to match renamed columns (`post_tag_assignments`, `post_group_assignments`, `post_media`, `file_instances`)
- Add `RepoHelper.get_pk_column/1` — queries `pg_index` for PK column name, falls back to `"id"`
- Fix DB explorer to use dynamic PK column in `fetch_row`, `table_preview`, and notify trigger
- Fix Sync API controller to use dynamic PK column in `fetch_filtered_records` and `build_where_clause`
- Fix Sync connection notifier to use dynamic PK column in `insert_record` and `build_update_clause`
- Update 4 schema constraint names to match V72 column renames (`post_id` → `post_uuid`, `file_id` → `file_uuid`)
- Remove dead `:user_id` from OAuth `replace_all_except` list

## 1.7.54 - 2026-03-03
- Add V72 migration: rename PK column `id` → `uuid` on 30 Category A tables (metadata-only, instant)
- Add 4 missing FK constraints: `comments.user_uuid`, `comments_dislikes.user_uuid`, `comments_likes.user_uuid`, `scheduled_jobs.created_by_uuid`
- Remove `source: :id` mapping from 29 Category A Ecto schemas — DB column now matches field name directly

## 1.7.53 - 2026-03-02
- Add `mix phoenix_kit.doctor` diagnostic command — detects migration version vs `schema_migrations` discrepancies, stale COMMENT tags, and common DB issues
- Add `update_mode` to `mix phoenix_kit.update` — skips heavy DB components (Oban, cache warmers, settings queries) and caps Ecto pool at 2 during migrations to prevent DB saturation
- Run `ecto.migrate` in-process instead of `System.cmd` for better error reporting and reliability
- Fix three migration hang root causes: NULL UUIDs causing infinite backfill loop, orphaned FK references blocking constraint creation, varchar uuid columns crashing Ecto schema loader
- Fix migration hang: disable DDL transaction in generated migration wrapper — prevents entire multi-version migration from running in a single transaction holding AccessExclusiveLock
- Fix V50 migration hang: add `lock_timeout` for `phoenix_kit_buckets` ALTER TABLE and check column existence before ALTER
- Fix settings cache race: warm synchronously in `init/1` when `sync_init: true`; fix `warm_critical_data` inserting `{key, value, nil}` 3-tuples when TTL is nil
- Fix cache `sync_init` blocking supervisor for 60s when DB is overloaded
- Fix startup DB timeout: defer `Dashboard.Registry` init and reorder supervisor children
- Silence cache warmer spam and auto-grant warning when `role_permissions` table doesn't exist yet
- Fix `gen.migration` task: generate UUID primary keys and `user_uuid` FK instead of integer-based
- Fix broken GDPR anonymization: remove leftover `user_id: nil` from `update_all` calls
- Rename `_id` → `_uuid` across all remaining application code: billing, shop, storage, entities, sync, emails, tickets, permissions, roles, connections, publishing, and user_notifier
- Rename function names: `find_role_by_id` → `find_role_by_uuid`, `parse_id` → `parse_uuid`, `import_id` → `import_uuid`
- Fix Dialyzer warning: remove unreachable pattern match in cache warming
- Fix V56/V63 migration crash: `email_log_uuid` backfill fails with `datatype_mismatch` when `phoenix_kit_email_logs.uuid` is `character varying` instead of native `uuid` type
- Fix UUIDFKColumns: replace broken Elixir `rescue` with PostgreSQL `EXCEPTION` handler inside DO blocks — prevents outer transaction abort on backfill failure
- Add `::uuid` explicit cast in all UUIDFKColumns backfill SQL to handle varchar source columns gracefully
- Fix V56: add pre-step to convert varchar `uuid` columns on all FK source tables to native `uuid` type before `UUIDFKColumns.up` runs
- Fix V63: wrap `matched_email_log_uuid` backfill in DO block with EXCEPTION handler and `::uuid` cast
- Add V70 migration: re-backfills `email_log_uuid` and `matched_email_log_uuid` for installs where V56/V63 silently skipped the backfill; resets stale random UUIDs written by the V56 NULL-fill fallback
- Add investigation doc: `dev_docs/investigations/2026-03-01-varchar-uuid-migration-bug.md`

## 1.7.52 - 2026-02-28
- Add translatable `title` field to posts and fix timestamp-mode post handling
- Add V69 migration: make role table integer FK columns nullable
- Add `mix precommit` alias (`compile → format → credo --strict`) to `mix.exs`
- Update AGENTS.md with pre-commit instructions, replacing old minimal checklist
- Rename `Scope.user_id` → `Scope.user_uuid` for consistency
- Rename `user_id` → `user_uuid` across event handlers, templates, and messages
- Rename `user_id` → `user_uuid` in emails rate_limiter; `log_id` → `log_uuid` in emails interceptor, SQS processor, and sync task
- Rename `user_id` → `aws_user_id` in AWS credentials verifier
- Rename `resource_id` → `resource_uuid` in scheduled jobs
- Rename `_id` → `_uuid` in billing, shop, AI, entities, legal, posts, tickets, storage, scheduled jobs, and permissions
- Rename `_id` → `_uuid` across metadata, forms, helpers, and tests
- Replace `DateTime.utc_now()` with `UtilsDate.utc_now()` across codebase
- Remove redundant `connection_id` parameter from sync `connection_notifier`
- Fix crash bugs: `.user_id` struct access → `.user_uuid` in billing events and order_form
- Fix UUID field references for webhook_events and post images
- Fix duplicate map keys left from UUID migration in hooks and rate_limiter
- Fix alias ordering Credo violations across 18 files
- Fix timestamp-mode post lookups, migration ordering, and admin UI (PR #376 review follow-up)
- Fix `tab_callback_context` missing clause; demote double-wrap log to debug
- Add dialyzer ignore for unused `tab_callback_context` clause
- Update integration guide, making-pages-live guide, dashboard README, and usage-rules to use UUID terminology

## 1.7.51 - 2026-02-26
- Add V64 migration: fix login crash by replacing `user_id` check constraint with `user_uuid` on user tokens table
- Add V65 migration: rename `SubscriptionPlan` to `SubscriptionType` (table, columns, indexes, constraints)
- Rename `SubscriptionPlan` schema, context functions, events, routes, LiveViews, and workers to `SubscriptionType`
- Add orphaned media file cleanup system
  - `mix phoenix_kit.cleanup_orphaned_files` task with dry-run and `--delete` modes
  - `DeleteOrphanedFileJob` Oban worker with 60s delay and orphan re-check before deletion
  - Orphan filter toggle and "Delete all orphaned" button in Media admin UI
- Add Delete File button with confirmation modal to Media Detail page
- Add secondary language slug uniqueness validation via JSONB query in entity data
- Rename `seed_title_in_data` to `seed_translatable_fields` in entity data form
- Unify slug labels to "Slug (URL-friendly identifier)" across entity forms
- Standardize dev_docs file naming convention (`{date}-{kebab-case}-{type}.md`)
- Fix orphan detection crash: remove references to non-existent `phoenix_kit_shop_variants` table
- Fix `String.trim(nil)` crash in SQS workers when AWS credentials not configured
- Fix default preload `:plan` to `:subscription_type` in `list_subscriptions/1` and `list_user_subscriptions/2`
- Fix `auth.ex` storing integer `file.id` instead of `file.uuid` for avatar custom field
- Fix `create_subscription/2` dead code and key mismatch — now accepts `:subscription_type_uuid` as preferred key
- Fix `change_subscription_type/3` reading stale `subscription_type_id` instead of `subscription_type_uuid`
- Fix AWS Config returning empty string instead of nil when credentials unconfigured
- Fix email log `Access` behaviour error when called with `EmailLogData` struct
- Fix `Interceptor` using deprecated `log.id` instead of `log.uuid` in header and event
- Fix shop billing cascade: check `disable_system()` result and log on failure
- Replace `defp` proxy wrappers with `import` in 4 shop LiveViews (cart, catalog, checkout)
- Rename `post_id` to `post_uuid` in 5 private post functions
- Remove legacy integer ID function clauses from posts and billing modules
- Remove accidentally committed `.beam` files, add `*.beam` to `.gitignore`
- Remove empty legacy `subscription_plan_form.ex` and `subscription_plans.ex`
- Add doc notes about performance for `all_admin_tabs/0` and `get_config/0`
- Remove dead `_plugin_session_name` variable from integration routes

## 1.7.50 - 2026-02-25
- Fix `defp show_dev_notice?` CLAUDE.md violation: replace private helper with `<.dev_mailbox_notice>` Phoenix Component
  - New component at `lib/phoenix_kit_web/components/core/dev_notice.ex` with `message` and `class` attrs
  - Removed from `login.ex`, `registration.ex`, `magic_link.ex`, `forgot_password.ex`, `dashboard/settings.ex`
  - Updated all corresponding HEEX templates to use `<.dev_mailbox_notice>`
- Fix duplicate route alias compilation warnings in `phoenix_kit_authenticated_routes/1`
  - Split module-scope routes into `authenticated_live_routes/0` and `authenticated_live_locale_routes/0`
  - Locale variants now use `_locale` suffix (e.g. `:shop_user_orders_locale`)
- Fix undeclared `sidebar_after_shop` attr in `shop_layout/1` component
- Fix `maybe_redirect_authenticated/1` hardcoded `"/"` redirect — use `signed_in_path(socket)` consistently
- Fix double `Map.from_struct` in `Emails.Interceptor.create_email_log/2` — redundant call removed

## 1.7.49 - 2026-02-24
- Add V63 migration: UUID companion column safety net round 2
  - Add `uuid` identity column to `phoenix_kit_ai_accounts` (missed by V61 due to wrong table name)
  - Add `account_uuid` companion to `phoenix_kit_ai_requests` (backfilled from ai_accounts)
  - Add `matched_email_log_uuid` to `phoenix_kit_email_orphaned_events` (backfilled from email_logs)
  - Add `subscription_uuid` to `phoenix_kit_invoices` (backfilled from subscriptions)
  - Add `variant_uuid` to `phoenix_kit_shop_cart_items` (nullable, no variants table)
  - Update Invoice, AI Request, and CartItem schemas with new uuid companion fields

## 1.7.48 - 2026-02-24
- Add V62 migration: rename 35 UUID-typed FK columns from `_id` suffix to `_uuid` suffix
  - Enforces naming convention: `_id` = integer (legacy/deprecated), `_uuid` = UUID
  - Groups: Posts module (15 renames), Comments (4), Tickets (6), Storage (3), Publishing (3), Shop (3), Scheduled Jobs (1)
  - No data migration — columns already held correct UUID values, pure rename
  - All DB operations idempotent (IF EXISTS guards) — safe on installs with optional modules disabled
  - Update all Ecto schemas, context files, web files, and tests to use new field names

## 1.7.47 - 2026-02-24
- Fix V13 migration down/0 to use `remove_if_exists` instead of `remove` for idempotency
  - Fixes "column aws_message_id does not exist" error when rolling back V13

## 1.7.46 - 2026-02-24
- Add plugin module system with `PhoenixKit.Module` behaviour, `ModuleRegistry`, and zero-config auto-discovery
  - 5 required + 8 optional callbacks with sensible defaults via `use PhoenixKit.Module`
  - Auto-discovers external modules by scanning `.beam` files for `@phoenix_kit_module` attribute
  - All 21 internal modules now implement the behaviour, removing 786 lines of hardcoded tab enumeration
  - External module admin routes auto-generated at compile time from `admin_tabs` with `live_view` field
- Add live sidebar updates via PubSub when modules are enabled/disabled
- Add server-side authorization on module toggle events (prevents crafted WebSocket bypass)
- Add startup validation: duplicate module keys, permission key mismatches, duplicate tab IDs, missing permission fields
- Add compile-time warnings for route module and LiveView compilation failures
- Standardize AI, Billing, and Shop to use `update_boolean_setting_with_module/3` (consistent with all other modules)
- Fix billing→shop cascade: shop now disabled after billing toggle succeeds (prevents orphaned state)
- Fix `Tab.permission_granted?/2` to handle atom permission keys instead of silently bypassing checks
- Fix `static_children/0` to catch module `children/0` failures instead of crashing the supervisor

## 1.7.45 - 2026-02-23
- Fix auth forms mobile overflow on small screens (px-4 added to all form containers)
- Fix daisyUI v5 compliance: remove deprecated `input-bordered` from `<.input>` component and all auth templates
- Fix `<.header>` hardcoded `text-zinc-*` colors replaced with semantic `text-base-content` for dark theme support
- Convert forgot_password, reset_password, confirmation, confirmation_instructions to unified card layout
- Add missing `LayoutWrapper.app_layout` wrapper to confirmation form
- Fix V40 migration silently skipping V32-V39 tables due to Ecto command buffering
  - Root cause: `repo().query()` (immediate) couldn't see buffered table creation commands
  - V31's `flush()` was the last flush before V40, creating a clean V31/V32 split
  - Add `flush()` to V40 and V56 to prevent recurrence on new installations
- Add V61 migration: uuid column safety net for 6 tables missed by V40
  - Tables fixed: admin_notes, ai_requests, subscriptions, payment_provider_configs, webhook_events, sync_transfers
  - Also adds `created_by_uuid` FK column to phoenix_kit_scheduled_jobs

## 1.7.44 - 2026-02-23
- Add Publishing module: DB storage, public post rendering, and i18n support
- Add unified `admin_page_header` component, replace all per-page admin headers
- Add try/rescue to all form save handlers to prevent silent data loss on validation errors
- Add skeleton loading placeholders for entity language tab switching
- Add "Update Entity" submit button at top of entity form for quicker saves
- Add responsive card view to entities listing, remove stats/filters
- Memoize `IbanData.all_specs/0` with compile-time module attribute for performance
- Auto-register built-in comment resource handlers
- Make entity slug translatable and move it into Entity Information section
- Move multilang info alert above language tabs with improved explanation
- Tighten language tab spacing, replace daisyUI tab classes with compact utilities
- Remove hardcoded category column, filter, and bulk action from data navigator
- Fix CommentsComponent crash on post detail page
- Fix Entity update crash from DateTime microseconds in `:utc_datetime` fields
- Fix `email_templates` schema/migration mismatch breaking fresh installs
- Fix locale disappearing from admin URLs on sidebar navigation
- Fix badge component height on mobile devices
- Fix cached plan error spam during migrations with column type changes
- Fix CSS specificity debt and inline styles replaced with Tailwind classes
- Fix mobile responsiveness across admin panel
- Replace remaining `DateTime.utc_now()` with `UtilsDate.utc_now()` in all DB write contexts

## 1.7.43 - 2026-02-18
- Standardize all schemas to `:utc_datetime` and `DateTime.utc_now()` across 73 files
  - Replace `:utc_datetime_usec` with `:utc_datetime` and `NaiveDateTime` with `DateTime`
  - Add V58 migration to convert all timestamp columns across 68 tables from `timestamp` to `timestamptz`
  - Fix UUID FK backfill to handle NULL UUIDs before applying NOT NULL constraints
- Fix DateTime.utc_now() microsecond crashes in 19 files after `:utc_datetime` schema migration
  - Add `DateTime.truncate(:second)` to all `DateTime.utc_now()` calls in contexts
  - Affected: settings, billing, shop, emails, referrals, tickets, comments, auth, permissions, roles
- Fix Language struct Access error on admin modules page and all bracket-access-on-struct bugs
- Add 20 typed structs replacing plain maps across billing, entities, sync, emails, AI, and dashboard
  - Billing: CheckoutSession, SetupSession, WebhookEventData, PaymentMethodInfo, ChargeResult, RefundResult, ProviderInfo
  - Other: AIModel, FieldType, EmailLogData, LegalFramework, PageType, Group, TableSchema, ColumnInfo, SitemapFile, TimelineEvent, IbanData, SessionFingerprint
- Fix `register_groups` to convert plain maps to `Group` structs, preventing sidebar crashes
- Fix CastError in live sessions page by using UUID lookup instead of integer id
- Fix guest checkout flow: relax NOT NULL on legacy integer FK columns, fix transaction error double-wrapping
- Add return_to login redirect support for seamless post-login navigation (e.g., guest checkout)
- Add cart merge on login for guest checkout sessions
- Fix shop module .id to .uuid migration in Storage image lookups and import modules
- Fix hardcoded "PhoenixKit" fallback in admin header project title
- Fix admin sidebar submenu not opening on localized routes
- Fix 2 dialyzer warnings in checkout session and UUID migration
- Add multi-language support for Entities module
  - New `Multilang` module with pure-function helpers for multilang JSONB data
  - Language tabs in entity form, data form, and data view (adaptive compact mode for >5 languages)
  - Override-only storage for secondary languages with ghost-text placeholders
  - Lazy re-keying when global primary language changes (recomputes all secondary overrides)
  - Translation convenience API: `Entities.set_entity_translation/3`, `EntityData.set_translation/3`, `EntityData.set_title_translation/3`, and related get/remove functions
  - Multilang-aware category extraction in data navigator and entity data
  - Non-translatable fields (slug, status) separated into their own card
  - Required field indicators hidden on secondary language tabs
  - Title translations stored as `_title` in JSONB data column (unified with other field translations)
  - Slug generation disabled on secondary language tabs
  - Validation error messages wrapped in gettext for i18n
  - 124 pure function tests for Multilang, HtmlSanitizer, FieldTypes, FieldType
- Fix entities multilang review issues
  - Unify title storage in JSONB data column, fix rekey logic for primary language changes
  - Add `seed_title_in_data` for lazy backwards-compat migration on mount
  - Replace `String.to_existing_atom` with compile-time `@preserve_fields` map
  - Fix 7 remaining issues from PR #341 permissions review
  - Add catch-all fallback clauses to Scope functions to prevent FunctionClauseError
  - Sort `custom_keys/0` explicitly instead of relying on Erlang map ordering

## 1.7.42 - 2026-02-17
- Use PostgreSQL IF NOT EXISTS / IF EXISTS for UUID column operations
  - Replace manual column_exists? checks with native DDL guards in V56 and UUIDFKColumns
  - Makes migrations more robust and idempotent

## 1.7.41 - 2026-02-16
- Fix FK constraint creation crash when UUID target tables lack unique indexes
  - Ensure unique indexes on all FK-target uuid columns before adding FK constraints
  - Fixes `invalid_foreign_key` error on `phoenix_kit_ai_endpoints` and other tables

## 1.7.40 - 2026-02-16
- Remove redundant mb-4 wrapper div around back buttons in 4 admin pages
- Add V57 migration to repair missing UUID FK columns
- Update language filter to use languages_official instead of languages_spoken

## 1.7.39 - 2026-02-16
- Complete UUID migration (Pattern 2) across all remaining modules
  - Migrate posts, tickets, storage, comments, referrals, and connections schemas to UUID-based user references
  - Migrate posts like/dislike/mention functions to accept UUID user identifiers
  - Fix stale `.id` access across posts, storage, tickets, email, connections, and image downloader
  - Fix ProcessFileJob and media_detail to use user_uuid instead of deprecated user_id
  - Replace legacy `.id` access with `.uuid` across mix tasks and admin presence
  - Remove legacy integer fields from RoleAssignment schema
  - Fix 10 Dialyzer warnings across comments, connections, referrals, and shop modules
- Harden permissions system with security and correctness fixes
  - Fix security and correctness issues in permissions system
  - Add permission edit protection for own role and higher-authority roles
  - Add Owner protection to `can_edit_role_permissions/2` and standardize UUID usage
  - Fix edge cases, silent failures, and crash risks in permissions and roles
  - Fix dual-write in `set_permissions/3` and cross-view PubSub refresh
  - Fix permissions summary to count only visible keys
  - Fix multiple bugs in custom permission keys and admin routing
  - Add auto-grant of custom permission keys to Admin role
  - Add defensive input validation to custom permission key registration
  - Fix `unless/else` to `if/else` for Credo compliance
- Add gettext i18n to roles and permissions admin UI
- Add Level 1 test suite for permissions, roles, and scope (156 tests)
- Fix responsive header layout across all admin pages
  - Add responsive text classes (`text-2xl sm:text-4xl` / `text-base sm:text-lg`) to all page headers
  - Fix missed responsive text classes in storage, media selector, and publishing pages
- Replace dropdown action menus with inline buttons in table rows
- Fix require_module_access plug to check feature_enabled like LiveView on_mount
- Fix admin sidebar wipe when enabling/disabling modules
- Add `get_role_by_uuid/1` API and update integration guide
- Restore admin edit button in user dropdown and add product links in cart
- Fix selected_ids to use MapSet for O(1) lookups
- Fix Dialyzer CI failure for ExUnit.CaseTemplate test support files
- Fix Credo nesting and Dialyzer MapSet opaque type warnings
- Update Permissions Matrix page title and section labels

## 1.7.38 - 2026-02-15
- Fix Ecto.ChangeError in entities by using DateTime instead of NaiveDateTime
- Fix infinite recursion risk in category circular reference validation
- Add DateTime inconsistency audit report with phased migration plan
- Add custom permission key auto-registration for admin tabs
  - Custom admin tabs with non-built-in permission keys now auto-register with the permission system
  - Custom keys appear in the permission matrix and roles popup under "Custom" section
  - Owner role automatically gets access to custom permission keys
  - Custom LiveView permission enforcement via cached `:persistent_term` mapping
  - New API: `Permissions.register_custom_key/2`, `unregister_custom_key/1`, `custom_keys/0`, `clear_custom_keys/0`
  - Key validation: format check (`~r/^[a-z][a-z0-9_]*$/`), `ArgumentError` on built-in key collision

## 1.7.37 - 2026-02-15
- Fix UUID PR review issues: aliases, dashboard_assigns, and naming issues
- Fix V56 migration: add subscription_plans to uuid column setup lists
- Add admin edit buttons and improve shop catalog UX
- Add registry-driven admin navigation system
- Fix localized field validation in Shop forms
- And bunch of bugs and optimizations

## 1.7.36 - 2026-02-13
- Add storefront sidebar filters, category grid, and dashboard shop integration
  - New `CatalogSidebar` component: reusable sidebar with collapsible filter sections and category tree navigation
  - New `FilterHelpers` module: filter data loading, URL query string building, price/vendor/metadata filtering
  - Storefront filter configuration in admin settings: enable/disable filters, edit labels, add metadata option filters
  - Auto-discovery of filterable product metadata options (e.g., Size, Color) with one-click filter creation
  - Price range filter with min/max inputs and range display
  - Vendor and metadata option filters with checkbox selection and active count badges
  - Filter state persisted in URL query params for shareable filtered views
  - "Show Categories in Shop" setting: displays category card grid above products on main shop page
  - Sidebar category navigation always visible in sidebar (decoupled from grid setting)
  - Dashboard layout integration: shop filters and categories rendered in dashboard sidebar for authenticated users
  - `sidebar_after_shop` slot in dashboard layout for injecting custom sidebar content
  - Product detail page updated to use shared sidebar and filter context for consistent navigation
  - Mobile filter drawer with toggle button and active filter count badge
  - Category page filters scoped to category products
  - Fix `phx-value-value` collision on filter checkboxes: renamed to `phx-value-val` to avoid HTML checkbox `value="on"` overwrite
  - **Known issue**: metadata option filters (e.g., Size) may not filter correctly in all cases; needs further investigation
- Add file upload field type to Entities module
  - New `file` field type with configurable max entries, file size, and accepted formats
  - `FormBuilder` renders file upload UI with drag-and-drop zone (admin entity forms, placeholder)
  - New `:advanced` field category
- Fix 3 remaining UUID migration bugs in billing forms
- Fix 8 UUID migration bugs found in PR #330 post-merge review
- Add UUIDv7 migration V56 with dual-write support

## 1.7.35 - 2026-02-12
- Rewrite Sitemap module to sitemapindex architecture with per-module files
  - `/sitemap.xml` now returns a `<sitemapindex>` referencing per-module files at `/sitemaps/sitemap-{source}.xml`
  - Dual mode support: "Index mode" (per-module files, default) and "Flat mode" (single urlset when Router Discovery enabled)
  - New `Source` behaviour callbacks: `sitemap_filename/0` and `sub_sitemaps/1` for per-group file splitting
  - New `Generator.generate_all/1` and `generate_module/2` with auto-splitting at 50,000 URLs
  - FileStorage rewrite with `save_module/2`, `load_module/1`, `delete_module/1`, `list_module_files/0`
  - Cache rewrite supporting `{:module_xml, filename}` and `{:module_entries, source}` keys
  - Per-module stats stored as JSON in Settings with `get_module_stats/0`
  - Per-module regeneration via `SchedulerWorker.regenerate_module_now/1` (Oban)
  - Settings UI overhaul: per-module sitemap cards with stats, regeneration buttons, mode indicators
  - Publishing source: per-blog sub-sitemaps via `sitemap_publishing_split_by_group` setting
  - Entities source: per-entity-type sub-sitemaps
  - Static source: login page excluded, registration conditionally included
  - Router Discovery default changed to `false` (index mode is new default)
  - Removed "cards" XSL style; added `sitemap-index-minimal.xsl` and `sitemap-index-table.xsl`
  - Sitemap routes no longer go through `:browser` pipeline (public XML endpoints)
- Add PDF support for Storage module
  - New `PdfProcessor` module using `poppler-utils` (`pdftoppm`, `pdfinfo`)
  - First page rendered to JPEG thumbnail at configurable DPI
  - PDF metadata extraction (page count, title, author, creator, creation date)
  - `VariantGenerator` extended for document/PDF MIME types
  - Media UI: inline PDF viewer on detail page, PDF badges on thumbnails, metadata display
  - New system dependency checks for poppler in `Dependencies` module
- Fix option price display for options with all-zero modifiers
  - New `has_nonzero_modifiers?/1` filters out option groups where all price modifiers are zero
  - Price modifiers displayed as badges on option buttons (e.g., "+$5.00")
  - Cart saves all selected specs including non-price-affecting options (e.g., Color)
  - `build_cart_display_name/3` includes all selected specs in display name
- Fix category icons fallback to legacy product images
  - `Category.get_image_url/2` falls back to `featured_product.featured_image` (legacy URL)
  - Product detail respects `shop_category_icon_mode` setting for category subtab icons
  - Guard clauses tightened for Storage vs legacy URL handling
- Add ImportConfig filtering at CSV preview stage
  - Config filters applied during CSV analysis/preview, not just during import
  - Import wizard shows skipped product count with warning badge
  - Category creation uses language normalization for consistent JSONB slug keys
  - Imported option labels use `_option_slots` metadata for proper display names
- Fix admin sidebar full-page reload after upstream merge
  - Comments and Sync routes merged into main admin `live_session`
- Add runtime sitemaps directory to gitignore

## 1.7.34 - 2026-02-11
- Extract Comments into standalone reusable module (V55 migration)
  - New `PhoenixKit.Modules.Comments` context with polymorphic `resource_type` + `resource_id` associations
  - New tables: `phoenix_kit_comments`, `phoenix_kit_comments_likes`, `phoenix_kit_comments_dislikes`
  - Reusable `CommentsComponent` LiveComponent that can be embedded in any resource detail page
  - Threaded comments with configurable max depth and content length
  - Like/dislike system with atomic counter cache
  - Moderation admin UI at `{prefix}/admin/comments` with filters, search, and bulk actions
  - Module settings page at `{prefix}/admin/settings/comments`
  - Resource handler callback system for notifying parent modules (e.g., Posts) of comment changes
  - "comments" permission key added (25 total permission keys, 20 feature modules)
  - Posts module refactored to consume Comments module API instead of inline implementation
  - Legacy `phoenix_kit_post_comments` tables preserved for backward compatibility
- Add shop enhancements, sitemap sources, and admin navigation fix
  - Shop module improvements: product options toggle, import configs, drag-and-drop reordering, catalog language redirects
  - Sitemap module: shop source (categories, products, catalog), data source toggles in settings UI
  - Admin sidebar seamless navigation (consolidate live_sessions)
  - Migration fixes and V54 addition
- Fix preview-to-editor round-trip state and data loss bugs
  - Fix 8 bugs in the preview_token handle_params path that had diverged from the other editor entry points as features were added over time
  - Merge disk metadata into preview post to prevent silent data loss when saving after a preview round-trip
  - Add error logging to enrich_from_disk for observability
- Add module-level permission system for role-based admin access control
  - Custom roles can now be granted granular access to specific admin sections and feature modules. Permissions are managed through a new interactive matrix UI, enforced at both route and sidebar level, and update in real-time across all admin tabs via PubSub.

## 1.7.33 - 2026-02-04
- Add module-level permission system (V53 migration)
  - `phoenix_kit_role_permissions` table with allowlist model (row present = granted)
  - 24 permission keys: 5 core sections + 19 feature modules
  - Owner bypasses all checks; Admin seeded with all 24 keys by default
  - Custom roles start with no permissions, assigned via matrix UI or API
  - `PhoenixKit.Users.Permissions` context for granting, revoking, and querying role permissions
  - Interactive permission matrix at `{prefix}/admin/users/permissions`
  - Inline permission editor in Roles page with grant/revoke all
  - Route-level enforcement via `phoenix_kit_ensure_admin` and `phoenix_kit_ensure_module_access`
  - Sidebar nav gated per-user based on granted permissions
  - Real-time PubSub updates: permission changes reflect across all admin tabs
  - Backward compatible: pre-existing Admins retain full access before V53 migration
- Add PubSub events for real-time updates in Tickets and Shop modules
  - Tickets.Events module with broadcast for ticket lifecycle (created, updated, status changed, assigned, priority changed)
  - Comment and internal note events for ticket discussions
  - Shop.Events extension with product, category, inventory events
  - LiveViews subscribe to events for real-time UI updates
- Add User Deletion API with GDPR-compliant data handling
  - delete_user/2 with cascade delete for related data (tokens, OAuth, billing profiles, carts)
  - Anonymization strategy for orders, posts, comments, tickets, email logs, files
  - Protection: cannot delete self, cannot delete last Owner
  - Admin UI with delete button, confirmation modal, and real-time list updates
  - Broadcast :user_deleted event for multi-admin synchronization
- Fix compilation errors in auth.ex (pin operator with dynamic Ecto queries)
- Update core PhoenixKit schemas and Referrals to new UUID standard
- Update Shop module with localized slug support and unified image gallery
- Add PubSub events for Tickets and Shop modules, User Deletion API
- Added support for uuid to referral module
- Add markdown rendering and bucket access types
- Update Sync module to new UUID standard pattern
- Update billing module to use DB-generated UUIDs
- Update entities module to UUID standard matching AI module

## 1.7.32 - 2026-02-03
- Storage Module: Smart file serving with bucket access types (V50 migration)
  - Add `access_type` field to buckets: "public", "private", "signed"
  - Local files are now served directly without temp file copying (performance improvement)
  - Public cloud buckets redirect to CDN URL (faster, reduces server load)
  - Private cloud buckets proxy files through server (for ACL-protected storage)
  - Add retry logic for bucket cache race conditions during file access

  **⚠️ BREAKING CHANGE: Cloud Bucket Access Type**

  Cloud buckets (S3, B2, R2) now default to `access_type = "public"`, which redirects
  users directly to the bucket's public URL instead of proxying through the server.

  **If you have private/ACL-protected buckets:**
  - Go to Storage → Buckets → Edit your bucket
  - Set "Access Type" to "Private"
  - Files will be proxied through the server using credentials (previous behavior)

  **If you have public buckets (redirect mode):**

  For redirect to work, your bucket must be publicly accessible:

  1. **Enable Public Access** in your cloud provider settings:
     - AWS S3: Disable "Block all public access" and set bucket policy
     - Backblaze B2: Set bucket to "Public"
     - Cloudflare R2: Configure public access or use Custom Domain

  2. **Configure CORS** if serving files cross-origin (required when your site
     domain differs from bucket domain):

     AWS S3 / R2 CORS configuration example:
     ```json
     [
       {
         "AllowedHeaders": ["*"],
         "AllowedMethods": ["GET", "HEAD"],
         "AllowedOrigins": ["https://yourdomain.com"],
         "ExposeHeaders": ["ETag", "Content-Length"],
         "MaxAgeSeconds": 3600
       }
     ]
     ```

     Replace `https://yourdomain.com` with your actual domain, or use `"*"` for
     any origin (less secure but simpler for testing).

  See AWS documentation: https://docs.aws.amazon.com/AmazonS3/latest/userguide/enabling-cors-examples.html

## 1.7.31 - 2026-01-29
- Refactor publishing module into submodules and improve URL slug handling
  - Storage module refactoring:
    - Split storage.ex into specialized submodules: Paths, Languages, Slugs, Versions, Deletion, and Helpers for better organization and maintainability
    - Move controller logic into submodules: Fallback, Language, Listing, PostFetching, PostRendering, Routing, SlugResolution, Translations
    - Move editor logic into submodules: Collaborative, Forms, Helpers, Persistence, Preview, Translation, Versions
  - Listing page improvements:
    - Show live version's translations and statuses instead of latest version
    - Fetch languages from filesystem when version_languages cache is empty
    - Fix paths to point to live version files when clicking language buttons
    - Add "showing vN" badge that combines with version count display
    - Fix public URL to always use post's primary language
  - URL slug priority system:
    - Directory slugs now have priority over custom url_slugs
    - Prevent setting url_slug that conflicts with another post's directory name
    - Auto-clear conflicting url_slugs instead of blocking saves
    - Show info notice when url_slugs are auto-cleared due to conflicts
    - Clear conflicting url_slugs from ALL translations, not just current one
    - Clear conflicting custom url_slugs when new post is created

## 1.7.30 - 2026-01-28
- Posts Module
  - Add likes and dislikes system for post comments (V48 migration)
  - Post body field is no longer required
- User Management
  - Add dropdown field type support for user custom fields
- Shop Module (E-commerce)
  - Fix JSONB search queries and add defensive guards for robustness
  - Fix JSONB localized fields consistency across product/category operations
  - Add shop import enhancements with V49 migration
  - Fix image migration robustness and catalog display issues
  - Add language selection dropdown to CSV import for localized content
  - Add variant image mapping support for Shop products
  - Add legacy image support for backward-compatible variant mappings
- Bug Fixes
  - Fix UUID column error for auth tables during upgrade - Users upgrading from PhoenixKit < 1.7.0 no longer get "column uuid does not exist" error when logging in. Added auth tables (users, tokens, roles, role_assignments) to UUIDRepair module.

## 1.7.29 - 2026-01-26
- Add primary language improvements and AI translation progress tracking
  - Real-time translation progress - Added progress bars to editor and listing pages showing AI translation status
  - Primary language improvements - Posts now store their primary language for isolation from global setting changes
  - Language handling fixes - Fixed base code to dialect mapping (e.g., en → en-US) across public URLs and editor
  - UI polish - Updated language switcher colors, modal text, and added prominent primary language display in editor
  - Documentation - Added comprehensive README for the Languages module

## 1.7.28 - 2026-01-24
- Major improvements to the Publishing module's multi-language workflow: renamed "master" to "primary" terminology, fixed URL routing with locales, added language migration tools, improved cache performance, and fixed several UI/UX issues in settings and admin pages.
  - Multi-Language System Improvements
    - Rename master to primary terminology - Updated all references from "master language" to "primary language" for consistency and clarity
    - Fix language in URL breaking navigation - Resolved issues where locale prefixes in URLs caused routing problems
    - Isolate posts from global primary_language changes - Posts now store their own primary language, preventing drift when global settings change
    - Add "Translate to This Language" button - Quick translation action for non-primary languages in the editor
    - Sort languages in dropdowns - Consistent alphabetical sorting across all language selectors
  - Migration Tools
    - Add version structure migration UI - Visual indicators and migration buttons throughout the publishing module
    - Fix legacy post migration - Resolved "post not found" errors when migrating from legacy to versioned structure
    - Handle dual directory structures - Fixed migration when both publishing/ and blogging/ directories exist
    - Add primary language migration system - Tools to migrate posts to use isolated primary language settings
  - Performance
    - Improve listing performance - Read from cache when possible, reducing database/filesystem hits
    - Language caching with WebSocket transport - Faster language resolution with proper cache invalidation
    - Add Create Group shortcut - Quick access button on publishing overview page
  - Settings & Admin UI Fixes
    - Fix General settings content language glitch - Resolved weird UI behavior when changing content language
    - Fix settings tab highlighting - General and Languages tabs now properly highlight on child pages
    - Fix admin header dropdowns - Theme and language dropdowns in admin header now work correctly
    - Update Entities module description - Clearer description on the Modules page
- Updated the languages module added front and backend tabs for languages
- Add localized routes for Shop module
  - Add locale-prefixed routes (/:locale/shop/...) for multi-language Shop module support
  - Add language validation to only allow enabled languages in URLs
  - Add language preview switcher for admin product detail page


## 1.7.27 - 2026-01-19
- Changed / Added
  - Added prefix-aware navigation helpers and dynamic URL prefix support across dashboard, tabs, auth pages, and project home URLs, fixing issues when locale or prefix is nil.
  - Introduced comprehensive dashboard branding and theming:
    - Configurable branding, title suffix, and logo handling.
    - Shared theme controller with daisyUI integration, color scheme guide, and improved theme switcher placement.
  - Enhanced dashboard navigation:
    - Configurable subtab styling, redirects, highlights, and mobile subtab support.
    - Multiple context selectors with dependency support.
    - Reserved additional locale path segments for dashboard and users.
  - Added context-aware features:
    - Context-aware badges with update helpers, guards for nil contexts, and improved preservation during tab refresh.
    - Consistent context-aware merge behavior.
  - Improved authentication and user setup:
    - Added fetch_phoenix_kit_current_user to the auto-setup pipeline.
    - Fixed auth pages and titles to use centralized Settings/Config branding.
  - Performance and quality improvements:
    - Optimized Presence and Config modules to reduce repeated checks and lookups.
    - Added dashboard_assigns/1 helper to prevent unnecessary layout re-rendering.
    - Fixed hardcoded branding and paths to rely on configuration fallbacks.
  - Documentation updates:
    - Added guides for dashboard theming, tab path formats, subtab behavior, and context selectors.
    - Added prominent built-in features section and reduced overall documentation size.
- Maintenance:
  - Fixed Credo/Dialyzer issues, formatting problems, and test failures.
  - Cleaned up unused Dialyzer ignores and added ignores for test support files.

## 1.7.26 - 2026-01-18
- Language switcher fix

## 1.7.25 - 2026-01-16
- Bug fix - Added check for nil on language_swithcer on log-in page

## 1.7.24 - 2026-01-15
- Add Shop module with products, categories, cart, and checkout flow
- Add user billing profiles for reusable billing information
- Add payment options selection in checkout (bank transfer, card payment)
- Add user order pages with UUID-based URLs
- Add PubSub broadcasts to Billing module for real-time updates
- Add automatic default currency for orders
- Add Billing and Shop tabs to user dashboard tab system
- Add automatic dashboard tabs refresh when modules are enabled/disabled
- Fix user dashboard layout sidebar height calculation
- Fix OAuth avatar display in admin navigation

## 1.7.23 - 2026-01-14
- Added user functions, language switcher on login page (also support for Estonian and Russian on login)
- Removed logs spamming about oban jobs

## 1.7.22 - 2026-01-13
- Add AWS config module with centralized credential management
- Add context selector for multi-tenant dashboard navigation
- Add comprehensive user dashboard tab system with CLI generator
- Consolidate Publishing module into self-contained structure
- Publishing Module: Versioning, AI Translation, Per-Language URLs & Real-time Updates
- Fixed referralcodes to referrals for more universal code


## 1.7.21 - 2026-01-10
- Publishing Module: Versioning, AI Translation, Per-Language URLs & Real-time Updates
- Fixed referralcodes to referrals for more universal code
- Consolidate OAuth config through Config.UeberAuth abstraction

## 1.7.20 - 2026-01-09
- Fix user avatar fallback when Gravatar is unavailable
- Fixed issues with phx_kit install
- Add scheduled job cancellation when disabling modules
- Fix race condition in file controller for parallel requests

## 1.7.19 - 2026-01-07
We are doing code cleanup and refactoring to move forward with more new modules and more features:
- Moved referral_codes module to correct location lib/modules and fixed issue with install not working
- Standardize admin UI styling and add reusable components
- Move Emails module to lib/modules/emails with PhoenixKit.Modules.Emails namespace
- Migrate Entities, AI, and Blogging modules to lib/modules/ with PhoenixKit.Modules namespace
- Updated the javascript usage to not create userspace javascript files
- Move Sitemap and Billing modules to lib/modules/ with consolidated namespace
- Move DB and Sync modules to lib/modules/ with PhoenixKit.Modules namespace
- Moved posts module files to lib/modules folder
- Add DB Explorer module 

## 1.7.18 - 2026-01-03

- Blog Versioning, Caching System, and Complete Programmatic API
- Add Cookie Consent Widget (Legal Module Phase 2)
- Add Legal module improvements and cookie consent enhancements

