# Acting for an organization

**Status:** implementation complete (phases 1–4), verified 2026-10-30. Core and
CRM changes are committed locally; release core before CRM. Design reviewed by Codex on 2026-10-29
and by Grok on 2026-10-29 (first pass folded in; second pass on Claude's
recheck folded in; see
[Review (Codex)](#review-codex-2026-10-29),
[Review (Grok)](#review-grok-2026-10-29),
[Review (Grok, second pass)](#review-grok-second-pass-2026-10-29) and
[Implementation readiness](#review-codex-implementation-readiness-2026-10-29)). All
decisions are made.
**Requested by:** Andi's project (2026-10-29).

## Problem

Some people own several companies and use one email address for all of them.
Today an organization is a `User` row (`account_type: "organization"`) with its
own login email, and `phoenix_kit_users.email` is unique (`phoenix_kit_users_email_index`).
So a person who wants five companies needs five mailboxes, or five
plus-addresses (`me+acme@…`), and five passwords.

## Decision

**One email = one login stays.** Instead, an organization can be a
**managed** account: it has no login of its own, and the people allowed to act
for it enter it from their own session, through the account menu.

Rejected:

- **A setting that allows duplicate emails, login by username.** Username
  login already works (`Auth.get_user_by_email_or_username_and_password/3`), but
  everything else that resolves an email does not: magic link, forgot password,
  email confirmation, OAuth matching, email change, organization invitations,
  the rate limits keyed on email, and ~30 `get_user_by_email` call sites in core
  plus `phoenix_kit_crm` and host apps, each assuming one result. The unique
  index cannot follow a runtime setting either: it would be dropped for every
  install, uniqueness would become a racy app-level check, and switching the
  setting back off cannot restore the index once duplicates exist.
- **A nullable email.** `email` is `NOT NULL` since V1 and typed `String.t()`;
  every reader (mailers, display names, admin search, the CRM mirror, hosts)
  would need a `nil` branch. A placeholder address (§2) changes one changeset
  instead.
- **One membership table replacing `users.organization_uuid`, with the person
  staying signed in as themselves and an "active company" in the scope** (the
  first proposal). See the next section.
- **The acting organization stored on the person's own token** (like
  `active_role_uuid`), with the token loader returning the organization. One
  token would then resolve to a user it does not belong to, and every
  token-by-user path (the Sessions page, revoke, logout, `SessionRef`, login
  alerts) would have to learn about it.

## How this differs from the first proposal

| | First proposal | This plan |
|---|---|---|
| Person ↔ company link | `organization_uuid` replaced by a membership table (backfill, every reader changed, CRM changed) | `organization_uuid` ("works at") untouched; a NEW table says who may act for which organization |
| Who the session is | the person, with an active company in the scope | the organization's own account, entered by the person |
| Company-owned data | every core table and module must key on, and filter by, the active company | whatever an account owns today (files, libraries, orders, settings, notifications, roles) is the organization's, because the session IS the organization |
| "Who really did it" | the session user | the organization, with the person in the activity metadata (§8) |
| Size | core users/auth + CRM + every module that owns company data | core users/auth + the account menu + mail recipient + CRM mirror option; no module data changes |

What this plan gives up: the person and the company are separate accounts. A
person acting for Acme sees Acme's inbox, Acme's files, Acme's roles, not their
own; switching back is one click.

"No module data changes" is about ownership, not a promise that nothing
outside `lib/phoenix_kit/users` is touched: the mailer, the embedded-LiveView
identity, the API key paths and the CRM mirror all change (below).

**v1 limitations** that follow from "the session is the organization" (decision
3, the ceiling, and one `contact_email`):

- Authorship is the organization everywhere a human sees it (comments, files,
  orders, presence, mentions). The person is only in activity metadata, and
  the activity UI has to show it (§8).
- In-app notifications are the organization's, visible only while acting.
  Email goes to one `contact_email`. Managers share one preference matrix on
  the org row. There is no fan-out to each manager's personal inbox.
- `MultiSession.impersonated?/1` is true while acting, so the AI assistant,
  header widgets that refuse a borrowed account, and `Executor.execute_as`
  stay off. The ceiling also keeps `api` out: no machine API as the
  organization.
- Public org signup (`registration_account_type: "organization"`) still
  creates unmanaged orgs with their own mailbox. Managed is an admin-created
  alternative, not a replacement.

## Design

### 1. Data model (V227)

```
phoenix_kit_users                      (existing table)
  organization_uuid         existing, untouched: "works at" (one)
  managed_by_members        NEW boolean NOT NULL DEFAULT false
  contact_email             NEW citext, nullable, NOT unique

phoenix_kit_organization_managers      NEW table: who may act for which organization
  uuid                      uuid v7, PK
  organization_uuid         → phoenix_kit_users ON DELETE CASCADE
  user_uuid                 → phoenix_kit_users ON DELETE CASCADE   (the person)
  granted_by_uuid           → phoenix_kit_users ON DELETE SET NULL
  inserted_at, updated_at
  UNIQUE (organization_uuid, user_uuid); INDEX (user_uuid)

phoenix_kit_users_tokens               (existing table)
  acting_session_uuid       NEW → phoenix_kit_users_tokens(uuid) ON DELETE CASCADE
  organization_manager_uuid NEW → phoenix_kit_organization_managers(uuid) ON DELETE CASCADE

phoenix_kit_organization_invitations   (existing core table)
  kind                      NEW varchar NOT NULL DEFAULT 'member'
                            CHECK (kind IN ('member', 'manager'))
```

- `managed_by_members = true` is allowed only with `account_type =
  'organization'` (check constraint).
- `acting_session_uuid` and `organization_manager_uuid` are set **together**,
  and only on a `"session"` token of a managed organization (check constraint:
  both null, or both set **and** `context = 'session'`).
  `acting_session_uuid` is the person's own session token row (the root of the
  browser's stack); `organization_manager_uuid` is the grant that let them in.
  The person is that token row's `user_uuid`; no third column. The minting
  path is the only writer: if these columns are set on a **person's** token,
  `session_user_query/1` would look for a manager row whose organization is
  that person, find none, and the person would read as anonymous.
- **Indexes on the new token columns.** Postgres does not index the
  referencing side of a foreign key. `ON DELETE CASCADE` from a person
  session (or a manager row) seq-scans `phoenix_kit_users_tokens` without
  indexes on `acting_session_uuid` and `organization_manager_uuid`.
- **The cascades are the revocation guarantee.** Deleting the person's session
  (log out, "sign out other devices", password reset, an admin revoke) or the
  manager row (removal) deletes the organization token in the same statement.
  Nothing has to remember to do it. Re-granting creates a new manager row, so
  an old token cannot come back to life.
- Manager rows: the person must be `account_type = "person"`, not `api_only`,
  not the organization itself. Checked in the changeset and in the context.
  A person who has manager rows cannot change `account_type` to
  `"organization"` or become `api_only` while those rows exist (the insert
  check is not enough).
- **Pending uniqueness includes `kind`.** Today's unique index is
  `(organization_uuid, email) WHERE pending`
  (`phoenix_kit_org_invitations_pending_unique_idx` in V135). V227 drops
  it and creates `(organization_uuid, email, kind) WHERE pending`, so a
  pending member invite and a pending manager invite for the same address
  can coexist. Leaving the old index in place would make a pending member
  invite for `bob@x` fail (or, under the generic answer, silently no-op)
  a manager invite for `bob@x`, and Bob would still join as a member.
  `kind` is an `Ecto.Enum` (`:member | :manager`) like `status`.
  `OrganizationInvitation.create_changeset/2` currently only
  `unique_constraint`s `:token`; it must also map the pending index **by
  name** so a race is a changeset error, not a raw DB error, and manager
  invites can collapse that error into the generic answer (§9a).
- New core table → `ModuleOwnedTables` core list. New schema uses
  `PhoenixKit.SchemaPrefix`. Prefix-safe rules apply (`uuid_v7_call/1`, bare
  index names on CREATE, schema anchors on existence checks). The new columns
  and table go into the generated manifest and reference
  (`dev_docs/squash/README.md`, "Manifest & reference policy"), not only a
  chain-hash restamp. V227 follows the published personal-key migration V226 (V225 is
  `phoenix_kit_files.short_code`).

### 2. The placeholder login email

A managed organization's `email` is generated, `org-<uuid>@organization.invalid`
(RFC 2606: `.invalid` never resolves). Same pattern as service users
(`PhoenixKit.API.ServiceUsers`, `api-<id>@service.invalid`). It keeps the
column `NOT NULL` and unique, so no email-resolving code changes. Nobody types
it; the UI shows `contact_email` (or the organization name) instead.

**Never authenticate via `contact_email`.** Login, magic link, OAuth matching
(`found/1`, `attach_to_existing_user/2`) and `get_user_by_email` stay on
`users.email`. `contact_email` is delivery and display only. Public
registration of `@organization.invalid` and `@service.invalid` is refused
(defense in depth; service users already use the second).

`contact_email` is validated like an email (format, max 160) and is not
`.invalid`. It is not unique: several orgs, and a person's login, may share
one inbox.

A managed organization is created with `confirmed_at` set **and** referral
satisfied (`Referrals.mark_satisfied/2`). `account_gate/1` also runs
`Referrals.access_satisfied?/1`; a new managed org is none of marked
satisfied, grandfathered, `*`/`Owner` (the ceiling forbids those), or invited
(placeholder email). With `referral_codes_required` on, acting as Acme would
park the browser on `/users/referral`, which the org cannot complete. Same
treatment as confirmation: an admin made it, there is no person to enter a
code.

**`hashed_password` stays `NOT NULL`.** It has been `NOT NULL` since V1.
Convert-to-managed and create set a random unknown hash, the service-user
pattern (`ServiceUsers` `random_password_hash/0`). They never write `NULL`.
`valid_password?/2` still refuses. Convert-back sets a new password; it never
restores the old one.

Create goes through a **dedicated insert**, not `Auth.admin_create_user/2` /
`register_user/2`: those call `Roles.ensure_first_user_is_owner/1` and send
confirmation mail. The dedicated path: placeholder email, random password
hash, `confirmed_at`, referral satisfied, default `User` role, no welcome or
confirmation mail. Extra roles are assigned afterwards on the details page,
inside the ceiling.

### 3. A managed organization never signs in

Every door that refuses `api_only` refuses `managed_by_members` too:
`Auth.log_in_user/3` (web), `User.valid_password?/2`, magic link (request and
verify), OAuth (`found/1`, `attach_to_existing_user/2`), QR login (approval
**and** completion, `QrLoginComplete`), password reset (the token lookup **and**
the reset mutation, which works on an already-loaded struct:
`PhoenixKitWeb.Users.ResetPassword`), `UserToken.verify_email_token_query/2` and the
email-change verifier next to it, `MultiSession.add_account/3`,
`add_authenticated_user/3`, `impersonable?/2`. Guard the mutations, not only
the first lookup.

**The one way in is a session token minted by §4**, and
`UserToken.session_user_query/1` accepts a managed organization's token only
when all of these hold, in the query itself:

- `acting_session_uuid` names a `"session"` token row that has not expired;
- that row's user is an active `person`, not `api_only`;
- `organization_manager_uuid` names a manager row whose `organization_uuid` is
  this token's user and whose `user_uuid` is that person.

An unmanaged account's token is unaffected. A managed organization's token
without both columns (one minted before a conversion, or by a door nobody
guarded) reads as "nobody is signed in". Raw-token and token-uuid lookups
share `session_user_query/1`, so this one guard covers ordinary requests,
remember-me recovery, the mirrored multi-session accounts, socket reconnects
and `SessionRef`.

**Paths that do NOT go through the session query** and must handle a managed
organization on their own:

- **Embedded LiveViews** rebuild the identity from `current_user_uuid`
  (`PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2`). For a
  **managed organization** uuid they load the organization only when the
  LiveView session's own `user_token` (the cookie session is merged into every
  LiveView session) resolves through `session_user_query/1` to that same
  organization; otherwise anonymous. That keeps the admin home dashboard
  (`Live.Dashboard` passes `current_user_uuid` into `phoenix_kit_dashboards`)
  and comment composers working while acting (Grok: anonymous blanks them),
  and still refuses an embed whose grant has ended (Codex: a uuid alone
  reconnects without consulting the grant, e.g. an embed in a host's
  controller-rendered page, which has no parent LiveView to re-check it).
  Every other uuid keeps today's behaviour. One extra token lookup, only for
  managed organizations.
  Use the **user (and then `Scope.for_user/1`) returned by
  `session_user_query/1`**, not a second `Auth.get_user/1`: that query is
  what fills `acting_user_uuid` and `active_role_uuid` onto the user, so
  `Actor.opts/1` in an embed (comment composers) still names the person.
  Also set `phoenix_kit_session_token` from `session["user_token"]`.
  `reload_session_user/2` falls back to `Auth.get_user/1` when that assign
  is missing, which skips the grant.
- **API keys** (`PhoenixKit.API.Keys.verify/2` loads the key's owner directly).
  A managed organization owns no keys and no service users in v1: refused in
  `Keys.create_key/3` (including a key for itself, which `owner_allowed/2`
  allows today for one's own account) and `ServiceUsers` creation, refused at
  `Keys.verify/2` too (fail closed if a row exists anyway), and conversion to
  managed revokes the organization's existing keys. The permission ceiling (§6)
  also keeps the `api` key out of a managed organization's scope, so Settings
  -> API and `API.Access.fresh_scope/1` never open for it.

### 4. Entering an organization: the multi-session stack

`PhoenixKitWeb.Users.MultiSession` already lets a browser hold several
accounts' session tokens, with the root (the original login) deciding and one
token active, and `impersonate/2` already adds an account without its password
on the root's authority. Entering an organization is the same move with a
different authority check. All of it lives in one context function and its
twin for leaving, so entry, validation and revocation are not spread out.

The organization token is a **first-class exception** in every stack helper,
not only in `act_as_organization` / leave:

- `MultiSession.act_as_organization(conn, org_uuid)`: the **root** decides,
  never the active account (otherwise a person could act for Acme and, from
  inside Acme, enter something Acme manages). The root must be an active,
  confirmed (when confirmation is required) `person` with a manager row for
  `org_uuid`, and the organization must be active and managed. Mints a session
  token for the organization with `acting_session_uuid` = the root token's row
  and `organization_manager_uuid` = the grant, appends it to the stack, makes
  it active, logs `organization.entered` (§8) with **no `target_uuid`** (a
  feed row, not an inbox notification). Rate-limited per root user
  (authenticated enumeration of org uuids).
- **At most one organization token per stack, outside the account limit.**
  Entering another organization replaces (and deletes, and disconnects) the
  previous one. Entering the same one is a no-op. The organization token does
  not count toward `@max_accounts` (5): `add_account/3` /
  `add_authenticated_user/3` measure `length(stack)` **excluding** it, so a
  full stack of added accounts still lets the person enter a company, and
  seven companies never fill it.
- **`list_accounts/1` omits the organization token.** Otherwise the existing
  multi-session switcher renders `org-<uuid>@organization.invalid` as an
  account. The org switcher (§5) is the only UI for it.
- **Switching away leaves.** `switch_to/2`, `remove_account/2` and
  `log_out_active/1` delete and disconnect the organization token when the
  browser leaves it (same as the dedicated leave route). A live org token
  must not sit unused in the stack: `impersonated?/1` would go false on the
  root while the grant was still valid.
- **Add-account and impersonation are refused while an organization token is
  in the stack.** Otherwise an Owner acting as Acme can impersonate Bob into
  `[owner, acme, bob]`. Root still decides, so the authority check alone does
  not prevent it.
- **Mirrored, in its own slot.** The persisted mirror cookie carries the
  organization token next to `accounts` (a new `organization` key), not in the
  list `write_persisted/4` trims to `@max_accounts - 1`. Today's helpers
  would drop that slot: `write_persisted(conn, root, [], _)` forgets the whole
  cookie, and `active` is stored only when `active in kept`. They must write
  an org-only mirror, accept the org token as `active`, and keep old cookies
  without the key decoding. A lost session resumes inside Acme when
  remember-me was used (the mirror never outlives the remembered identity).
  Mirror recovery today forgets the whole mirror when `multi_session_enabled`
  is off (`restore_persisted_accounts/2`); it must keep the organization slot
  regardless of that setting, and still drop the extra accounts.
- **Own routes, not the multi-session ones.** `POST
  /users/session/organizations/:uuid` (enter) and `DELETE
  /users/session/organization` (back to my account: switch to the root,
  delete the organization token, disconnect it). Wired in **both** scopes in
  `PhoenixKitWeb.Integration` (bare and `/:locale`), next to
  `/users/session/role`. The existing `set_active_account/2` is behind the
  multi-session gate (`with_gate/3`), and enabling ordinary "add account" must
  not be the price of using companies.
- **Landing.** Enter redirects to `Routes.post_auth_path/1` (tail `/admin`):
  staying on the current URL would open the person's profile, settings or
  files as the organization. Leave redirects to a path the **root** can open
  (`post_auth_path` if the current URL is not one, otherwise stay).
- **Log out while acting.** `log_out_active/1` already means "drop the
  non-root active token, stay as root", so the menu's Log out would leave
  Acme and keep Dmitri signed in, with the flash "Logged out. Now signed in
  as …". The account menu offers **Back to my account** (the DELETE above)
  and **Log out**, which full-logs-out the person (the existing "log out all"
  path, `UserAuth.log_out_user/1`, already drains the stack).
- **Reads as a borrowed account** (decided). `MultiSession.impersonated?/1`
  stays true while acting: callers that refuse a borrowed account, such as the
  AI assistant spending an account's limits, refuse an organization session too.
- **Support impersonation of a managed organization is refused in v1**
  (decided). `impersonable?/2` answers false for it; an impersonation token
  would carry no manager grant and the session query would refuse it anyway.
  A later support mode needs its own authorization and provenance, not an
  impersonator uuid standing in for a grant.
- **No login alert.** Entering is not a sign-in (the person already signed in,
  and their own login alert covered that); it is an activity row instead.
- **Master switch off.** `enable_organization_accounts` today only hides UI;
  existing unmanaged org logins still work. Same here: the switcher hides and
  **new enters are refused**; live acting sessions continue until they leave
  or the grant ends. `session_user_query/1` does not read the setting.

### 5. The account menu (the switcher)

In the user dropdown (`PhoenixKitWeb.Components.AdminNav` used from
`layout_wrapper`, and `UserDashboardNav` while it still exists), a section
above the role switcher:

```
Acting as
  ● Dmitri Don          (my account)
    Acme OÜ
    Beta Holdings
    Gamma Trade
```

- Shown when organization accounts are on (`Auth.organization_accounts_enabled?/0`)
  and the **root** manages at least one active managed organization.
  Independent of `multi_session_enabled`.
- Built as its own component (`Core.OrganizationSwitcher`, like
  `Core.RoleSwitcher`) so both navs share it. The header role switcher in
  `layout_wrapper` (when `role_switcher_location` is `"header"`) stays as it
  is; the org switcher lives in the dropdown.
- Each row is a form to the routes in §4: full page loads, same reasoning as
  `set_active_role/2` (the scope changes under every LiveView on the page).
- While acting, the dropdown identity shows who you are ("Acme OÜ · via
  Dmitri Don"), so nobody forgets which company they are in. That string is
  `User.display_name/1` (already prefers `organization_name`) plus the
  person's display name. Flashes on switching name the organization, never an
  email (the switch flash today prints `user.email`, which would be the
  placeholder).
- **One display helper for an address a human should see:** `contact_email`
  for a managed organization, `email` otherwise. Used by the nav
  (`Scope.user_email/1` in `AdminNav`, `UserDashboardNav`, dashboard
  presence), the admin users list and search, admin sessions
  (`list_user_sessions/1` selects `user.email`), mentions search, and mail
  template variables. Login lookups stay on `users.email`.
- Data: one indexed query on `organization_managers` by the root's uuid, run
  only when the master switch is on; it rides on the scope next to
  `multi_session_accounts` (`scope.acting_organizations`). The scope already
  resolves the root for multi-session; reuse that read.
- Strings go into `default.pot` and the nine `.po` files (switcher, flashes,
  admin managers UI, manager-invitation banner / mail / registration copy).

### 6. What an organization may do (the permission ceiling)

The session is the organization, so `Scope.for_user/1` gives the
organization's roles and the role switcher works per session as usual. One
manager level (decided): a manager acts with the organization's full
authority; there is no "may act, but only as role X" in v1.

A managed organization's authority has a ceiling, **applied when the scope is
built** (`Scope.for_user/1`), not only when a role is assigned, because a
role's permissions can be edited after the organization got it:

- never Owner or Admin, never the `"*"` superadmin key, never `api`;
- the role inserts refuse them too, at the common insertion point
  (`Roles.assign_role_internal/4`, which `assign_role/4`, `sync_user_roles/3`,
  promotion and the bootstrap/backfill paths all reach), with fresh state;
- converting an organization that holds one of them is refused until it is
  removed.

A new managed organization gets the default new-user role (`User`). Extra
roles (shop, CRM, media, a custom "Company admin") are assigned on the
details page, inside the ceiling.

While acting, the account settings hide and server-reject the credential
sections (password, login email, OAuth links, sessions of the organization).
The hide and the reject live in `PhoenixKitWeb.Live.Components.UserSettings`
(the LiveComponent hosts embed), not only `ProfileSettings`. They would fail
anyway (the forms ask for the active account's current password, which a
managed organization does not have); hiding them makes that a rule rather
than an accident.

**`can_manage_user_credentials?/2` is true for self** (rule 1: "your own
account is always yours"), and while acting the actor *is* the organization.
So manager changes and conversion must **not** use it as is: they use the
same role-and-rank rule **without** the self clause (Owner or Admin by role,
never the organization itself). Otherwise any context call reached while
acting would pass the check for the organization's own row. (Reaching
`/admin/users/view/<org>` additionally needs the `users` permission, which a
managed organization holds only if an admin gave one of its roles that key.)
Convert either way stays admin-only in every case: a manager must not give
the organization a real login and cut the other managers out.

Managers **may** add and remove managers themselves (decision 7, §9a), but
not through this rule: the context checks the acting grant, never "the actor
is the organization".

`TimeZoneAlert.observe/2` and any auto-save of `user_timezone` are skipped
while `Scope.acting_user_uuid/1` is set. The detector would otherwise write
`custom_fields` and notify the organization from the person's browser.

### 7. Mail

- **One recipient helper** decides where mail for an account goes:
  `contact_email` for a managed organization (none = not sent), `email` for
  everyone else. Login lookups keep using `email`; only delivery uses the
  helper. Every sender goes through it: `UserNotifier.deliver_*`, the
  notification email channel (`PhoenixKit.Notifications.Channels.Email.deliver/2`),
  `DigestWorker`, and any newsletter path that today reads `user.email`.
  Template variables (`user_email`) use the helper too, so a body never
  prints the placeholder.
- Organization notifications are in-app (whoever acts for the organization
  sees them) and also mailed to `contact_email` when it is set. There is no
  fan-out to each manager's personal inbox in v1.
- **Safety net in the mailer:** drop any `.invalid` recipient in `to`, `cc`
  and `bcc`, at delivery time (so queued Oban sends and integration delivery
  are covered). Nothing in core does this today; service users are simply
  never mailed. Covers both placeholders.
- No welcome or confirmation mail on managed create (there is no mailbox to
  confirm; `contact_email` is not asked to confirm an account it does not
  own).

### 8. Attribution

**Decided:** the organization is the activity actor, the person is in
`metadata["acting_user_uuid"]`.

This is not free: `PhoenixKitWeb.Actor.opts/1` passes only `actor_uuid`, and
`Activity.log/3` never sees the scope, so the person cannot be inferred
there. And it must never be inferred from the organization uuid (several
people manage one organization). So:

- the scope carries the acting person (`Scope.acting_user_uuid/1`, filled from
  the token's `acting_session_uuid` → user, by the same loader as everything else);
- `Actor.opts/1` adds `acting_user_uuid:` when the source is acting, and
  `Activity.log/1,3` writes it into the metadata;
- direct writers that build `actor_uuid` themselves (e.g. `ActiveRole` on a
  switch) are audited and passed it explicitly;
- an Oban job enqueued while acting carries it in its args if it logs.

The activity UI today prints `entry.actor.email` (`activity_list`,
`activity/index`, `activity/show`). It shows `User.display_name/1` of the
organization and, when `metadata["acting_user_uuid"]` is set, the person's
display name next to it ("Acme OÜ · via Dmitri Don").

### 9. Admin UI and creating organizations

- **Creation is admin-only** (decided). A person never creates an organization
  from their own account settings. Public org signup still creates unmanaged
  orgs with their own mailbox.
- **Organization details page** (`Live.Users.UserDetails`): a "Managed by
  members" section — managers list (add by person search, remove), contact
  email. Person search excludes `api_only`, organizations, and inactive
  users. The users list search includes `contact_email` and
  `organization_name` (`maybe_filter_by_search` today is email / username /
  first / last) and shows a managed badge; the email column uses the display
  helper (§5).
- **Member vs manager stay two relationships.** `organization_uuid` is "works
  at", at most one. A manager of five companies cannot "work at" all five.
  Adding a manager does not write `organization_uuid`. Organization
  invitations still create members, not managers, unless the admin UI offers
  both.
- **Who may change managers or convert:** adding a manager hands over the
  organization, so it is decided like credential management, by role and rank
  (`Auth.can_manage_user_credentials?/2`), not by the `users` permission that
  opens the page, and without the self clause (§6). **Convert is admin-only
  even when the actor is the organization.** Managers also manage managers
  from inside the organization (§9a). Checked in the context on every call,
  with fresh state, and in the event handler; forged-input tests for each
  event.
- **New managed organization:** name, contact email, first manager (required),
  dedicated insert (§2). Default role `User`.
- **Convert an existing organization to managed:** its login email moves to
  `contact_email` only when `contact_email` is empty (otherwise
  `contact_email` is kept and the login email is abandoned), `email` becomes
  the placeholder, a first manager is required, and **everything that could
  sign it in is revoked**: sessions, remember-me and email-token contexts,
  OAuth identities, `google_email`, API keys. The password hash is replaced
  with a random unknown hash (`hashed_password` is `NOT NULL`).
- **Convert back:** asks for a new unique login email and goes through the
  normal set-password / confirmation path. All acting sessions are revoked
  first (otherwise, with the flag cleared, they would read as ordinary
  organization sessions), and nothing old (password, OAuth identity) comes back.
  Delete the manager grants and cancel pending **manager** invitations in
  the same transaction. A later conversion to managed starts with fresh
  grants. Acceptance re-checks that the organization is active and managed;
  an invitation read before conversion cannot grant access afterwards.
- **The last manager.** Removing, deactivating or deleting the last *active*
  manager of a managed organization is refused unless the admin explicitly
  leaves it without managers (a checkbox; the organization then stays
  reachable by nobody until a manager is added). That includes **deactivating
  or deleting the person** who is the last manager (`ON DELETE CASCADE` on
  `user_uuid` would otherwise skip the checkbox, same shape as last-Owner).
  Manager changes on one organization are serialized with a row lock on the
  organization (`FOR NO KEY UPDATE`, not `FOR UPDATE`: the row is referenced
  by foreign keys).
- **CRM mirror** (decided): `PhoenixKitCrm.Companies` gets an explicit
  "create as managed organization" option, chosen by the admin with a first
  manager. Never an automatic fallback when the company's email is taken:
  email equality never grants management. For a managed organization the
  mirror maps the company's email to `contact_email` in creation, diff and
  reverse mirroring (`PhoenixKitCrm.Mirror`). A separate CRM release, after core.

### 9a. Managers manage managers (decision 7)

A person acting for an organization can add and remove its managers, without
a site admin. They are managers after all.

- **Where:** a "Managers" section in the account settings
  (`/profile/settings/<tab>`, `ProfileSettingsTabs` and the `UserSettings`
  LiveComponent), shown only while `Scope.acting_user_uuid/1` is set for a
  managed organization. Not the admin user page: that needs the `users`
  permission. The section is **not hideable** (same idea as `:identity`: it
  is not in `ProfileSettingsTabs` `@hideable`). `visible?/2` offers it only
  while acting. The invite form has a unique `id` derived from the
  LiveComponent `@id`. A host that sets `user_settings_path` away from
  `/profile/settings` does not get this UI unless it embeds the section —
  kit's `ProfileSettings` is the self-service surface.
- **Adding is by invitation, never by search.** The manager types an email;
  core sends a manager invitation. A person search would let any manager
  enumerate the site's accounts; the invitation also gets the invitee's
  consent. An email with no account yet: the invitee registers as a person
  (`account_type_mode/1` already forces `"person"` when an invitation is
  in the URL), then accepts.
  - **Arity.** Keep `Invitations.create_invitation/3` (admin member form
    and existing tests). Add an optional 4th argument / opts,
    `kind: :member | :manager`, default `:member`. `user_form.ex`
    `invite_member` stays a `/3` call.
  - **`invited_by` is the acting person**, `Scope.acting_user_uuid/1`,
    never the organization row. Today's `user_form.ex` passes
    `phoenix_kit_current_user`, which while acting *is* the org.
  - **Refuse `.invalid` invitee addresses** (placeholder /
    `api-*@service.invalid` mailboxes). Format validation is not enough;
    `.invalid` is a valid-looking address.
  - **Generic HTTP answer.** The answer to "invite" is the same whether or
    not an account exists for that email. Today `validate_invitation_allowed/2`
    answers "This user already belongs to an organization", an
    account-existence oracle; manager invitations skip that rule (managing
    is not "working at") and give one generic answer. Duplicates (already a
    manager, already invited as manager) collapse into the same answer,
    including the pending-unique race mapped by name in the changeset
    (§1). A pending *member* invite for the same address is a different
    row (the unique index includes `kind`) and does not no-op the manager
    invite.
  - **Accept branches on `kind`.** Today's `do_accept_invitation/3` always
    calls `Auth.set_organization/2`. A manager invitation never writes
    `organization_uuid`; it inserts the manager row. Accepting needs a
    `person` account, not `api_only`, not acting. The same branch applies
    to auto-accept from `pending_invitation_uuid` in `registration.ex`
    (`maybe_accept_invitation_without_confirmation/1`) and
    `confirmation.ex` (`maybe_accept_pending_invitation/1`) — both call
    `accept_invitation_by_uuid/2` today with no kind check.
  - **Accept from your own account.** `InvitationHook.confirmed_person?/1`
    requires `account_type: "person"`, so while acting (current user is
    the org) the hook does not attach and the banner is hidden. The
    invitee switches back, then accepts. `invitee?/2` already fails if
    the acting org tries to accept (placeholder email ≠ invitation
    email); the context still refuses a non-person / acting caller.
  - **After a manager accept, rebuild `scope.acting_organizations`.** The
    hook today only assigns `phoenix_kit_current_user`. The switcher
    reads the scope from mount; without a rebuild or navigate, Acme does
    not appear until the next remount.
- **The banner and the mail have to actually exist.**
  - **`InvitationHook` is not on any kit `live_session`**
    (`PhoenixKitWeb.Integration`: admin, authenticated, public). Install
    does not add it. Hosts may opt in; out of the box the banner never
    renders on `/admin` or `/profile/settings`. Attach the hook to every
    kit session that mounts a user (it already no-ops for nil /
    non-person). Kind-aware copy in `InvitationBanner` (today: "invited
    you to join their organization."), the registration alert, the
    accept flash ("You joined the organization!"), and the mail
    templates.
  - **Mail.** `maybe_send_invitation_email/3` currently skips existing
    users, and `UserNotifier.deliver_organization_invitation/3` always
    sends a **registration** URL (`/users/register?invitation=`). Member
    invitations keep that split once the hook is on kit sessions (banner
    for existing users, registration mail for new). **Manager
    invitations always send mail:** registration URL if no account; a
    **login** URL if there is one — never the register URL, which would
    fail on the unique email. The inviter's HTTP answer stays generic;
    only the invitee's mailbox differs. New gettext / template copy for
    the manager kind.
  - **Rate limit** through `PhoenixKit.Users.RateLimiter`, keyed on the
    acting person **and** the organization. Applied to no-ops too, or
    timing leaks the generic answer.
  - **Cancel is authorized.** Today's `cancel_invitation/1` takes only a
    uuid: no org scope, no actor. The admin form lists that org's rows;
    a manager who learns another org's invitation uuid would cancel it.
    Cancel takes the caller, and refuses unless the row belongs to this
    organization and the grant (or admin rank, without the self clause)
    still holds. Pending manager invitations can be cancelled by any
    manager of that org.
- **Admins** add a manager directly on the organization's details page
  (person search there is fine: admins already see the users list). That
  insert is the manager row, not an invitation; it logs
  `organization.manager_added` immediately.
- **Removing:** any manager may remove any other manager, or themselves
  ("Leave"). Removing yourself ends your organization session (the cascade)
  and lands you back in your own account. The last manager cannot remove
  themselves or be removed by a manager; only an admin can leave an
  organization without managers (§9).
- **Authority, checked in the context with fresh state on every call:** the
  caller is (a) an Owner or Admin by role, acting from their own session, or
  (b) a session acting for **this** organization whose grant still exists
  (the token's `organization_manager_uuid` row, re-read, for this
  organization and this acting person). Never "the actor is the organization"
  (§6). Managers cannot convert, deactivate or delete the organization.
  The admin branch must prove **own session**, too: a bare `User` or `Scope`
  cannot distinguish an Admin's login from a support impersonation of that
  Admin (`MultiSession.impersonated?/1` derives this from the signed cookie's
  stack). Carry current and root session references from that trusted session
  into the manager context; never construct them from event params. The
  acting-manager branch rechecks the token-bound grant and parent session.
- **Accepted risk:** a manager can remove every other manager. Every add and
  remove is an activity row (`organization.manager_added`,
  `organization.manager_removed`), logged on **row create / delete** (accept
  or admin add / remove), not on sending the invitation — a not-yet-registered
  invitee has no user uuid to target. Actor the organization, the acting
  person in metadata, target the affected person, so they get a notification.
  Register both actions on the `account` notification type
  (`PhoenixKit.Notifications.Types`) and in `Notifications.Render`; unknown
  actions notify with the raw action string. An admin can restore a removed
  manager.

### 10. Ending sessions and open pages

Deleting a token ends a session for the next request; a connected LiveView
keeps its assigns until it re-mounts (`Sessions.disconnect_tokens/1` moduledoc).
So every path that ends organization access deletes **and** disconnects:

- manager removal, conversion either way, organization deactivation or
  deletion, person deactivation;
- every revoke of the person's own sessions: the database cascade deletes the
  dependent organization tokens, but cannot broadcast, so the revoke paths in
  `Sessions` (`revoke_user_session/2`, `revoke_other_user_sessions/2`,
  `revoke_session/2`, `revoke_user_sessions/2`, `revoke_user_sessions_in_role/2`)
  and every token-deletion / credential-rotation path in `Auth`
  (`delete_user_session_token/1`, `delete_all_user_session_tokens/1`,
  user and admin password changes, password reset and external-proof
  confirmation) collect the dependent organization tokens
  **before** deleting, then disconnect them after commit. One shared helper,
  so a new revoke path cannot forget it.

Collection and deletion happen in one transaction under locks that also
serialize organization-token minting. Lock the referenced session / manager
rows before collecting dependents: a concurrent insert must either finish
before collection or fail after the parent is deleted. A read followed by
an unlocked delete can cascade away a newly minted token that was not in the
disconnect list. Manager removal, person deactivate/delete and conversion
also share the organization lock; operations spanning several organizations
take those locks in uuid order. Re-check authority and the last-active-manager
count under those locks, not before acquiring them.

A person deleted outright cascades too; collect the dependent tokens first
there as well. Deleting or deactivating the last manager's person goes
through the last-manager rule (§9) first.

The person's own Sessions page lists their acting sessions under the session
they came from ("Acme OÜ, from this browser"); revoking that session ends both.
The admin sessions list uses the display helper (§5), not the placeholder.

## Phases

1. **Core model + doors** — V227, schema/changeset changes (including
   `kind`, the kind CHECK, dropping the old pending-unique index and
   creating `(organization_uuid, email, kind) WHERE pending`, mapping
   that index in the changeset), placeholder email, dedicated create
   path, every login door, the session-query guard, embedded identity
   (session-query user + `phoenix_kit_session_token`), API-key refusals,
   the permission ceiling, the recipient helper and `.invalid` guard,
   referral satisfied, display helper.
2. **Switching** — `act_as_organization` and leaving, routes in both scopes,
   every stack helper treating the org token as an exception, the mirror slot
   (org-only and old cookies), the switcher component in both navs, the
   "acting as" header, attribution (including the activity UI), revocation
   with disconnects, the Sessions page entry, enter/leave landing, log-out
   copy.
3. **Admin UI and self-service managers** — managers on the details page,
   the "Managers" settings section while acting (not hideable), manager
   invitations (`create_invitation/3` default `kind: :member`, accept
   branches on kind including registration/confirmation auto-accept,
   generic answers, unique-index race, `invited_by` the acting person,
   authorized cancel, rate limit on no-ops too), `InvitationHook` on kit
   live sessions, kind-aware banner / mail / registration copy, login
   mail for existing-user manager invites, notification type + render
   for `organization.manager_added` / `manager_removed`, create, convert
   either way, the last-manager rule (including person deactivate/delete),
   users-list search and badge, i18n.
4. **CRM** — the managed-organization mirror option (`phoenix_kit_crm`).

Foundation code can ship incrementally. Creating or converting managed
organizations stays unavailable until switching, attribution, revocation,
credential guards and last-manager protection from phases 1–3 are complete
and tested together. Keep the dedicated creation path internal until then;
the phase boundaries are work packages, not independent feature releases.

## Implementation progress (2026-10-29)

Current status (2026-10-30): all four implementation phases are complete.
Core switching, attribution, creation/conversion and manager administration are
verified together. The CRM's explicit managed mirror option is implemented and
verified against local core, with compatibility checked against published core.
Both packages' project gates passed. Release core before CRM; publication and
deployment are separate work from this implementation.

First foundation batch (part of phase 1):

- [x] V227: managed-account policy and contact email, manager grants,
  cascading token provenance and indexes, invitation kind and pending index.
- [x] Catalog-generated manifest overlay and SQL reference, preserving the
  historical baseline; regeneration script in `dev_docs/squash/`.
- [x] Schemas, contact-address validation, manager eligibility and the
  person-to-organization guard for people holding manager grants.
- [x] Session-query validation and provenance for token and token-uuid reads;
  embedded managed identity requires its own matching live token.
- [x] Independent-login refusals: password, common web login, magic link,
  OAuth, QR approval/completion, reset, confirmation/email-change tokens,
  add-account and impersonation. Reset re-reads account policy so a form
  loaded before conversion cannot write a managed account's password.
- [x] Scope ceiling and assignment guards; API key/service-user refusals.
- [x] Shared display/delivery helper, core notifier and email notification
  routing, and `.invalid` recipient filtering at both mail transports.
- [x] Dedicated internal creation/conversion contexts and referral satisfaction
  (fourth batch below).
- [x] Reusable credential-settings guards and automatic timezone suppression
  for managed organizations (third batch below).
- [x] Transactional dependent-token collection, disconnects and concurrent
  lifecycle tests; these must precede exposing managed-account creation.
- [x] Switching, attribution, core display audit and switching translations (phase 2).
- [x] Managers UI/invitations, creation/conversion controls and their translations (phase 3).
- [x] CRM integration (phase 4).

No public managed-account creation, conversion or acting-session minting is
exposed by these foundation batches. The first batch proved database
cascades; the second batch below adds post-commit socket disconnects and
the real concurrent-transaction tests.

Validation of this batch:

- `mix precommit` passed (compile, test-file compilation, formatting, Credo,
  Dialyzer and all 480 JavaScript tests).
- Full suite against a fresh PostgreSQL database:
  `PGDATABASE=<scratch-test-db> PGPOOL=10 mix test --max-cases 8` —
  **89 doctests, 12,905 tests, 0 failures, 38 skipped, 1 excluded**.
  The excluded test requires `CREATEROLE`, which the test role lacks.
- V227's 27 generated manifest objects match the real catalog in `public`
  and in the named-prefix full-chain test. Migration rerun, down/up,
  constraint enforcement and an empty `search_path` are covered.

Second batch — session revocation (complete):

- [x] Shared token/grant drain locks the source rows before collecting
  dependent sessions, and deletes exactly that locked set.
- [x] All `Sessions` revoke functions and `Auth` token drains / credential
  rotations use it; person/organization deletion collects before cascades.
- [x] Disconnects are deferred to commit and discarded on rollback. Core
  transaction wrappers share one collector; a call inside a host-owned repo
  transaction observes that transaction's outcome from another connection.
  Before broadcasting, re-check that the tokens are absent, so a rolled-back
  savepoint cannot disconnect a restored session. No raw token goes into a
  database notification, job argument or log.
- [x] Real-connection tests cover commit/rollback, nested transactions,
  savepoints, and token insert racing a person-session or manager-grant revoke.

Implementation: `PhoenixKit.Users.Sessions.Revocation`. Core-owned
transactions share a collector. For host-owned transactions, a task polls
`pg_xact_status` on an independent connection, without holding a connection
between polls; raw tokens remain only in memory. Both paths check token
absence before broadcasting, including after a savepoint rollback.

Validation:

- Broader authentication regression run: **153 tests, 0 failures** (passwords,
  OAuth, role removal, session authority, deletion and multi-session flows).
- Final targeted run: **54 tests, 0 failures**, including 17 lifecycle/drain
  tests and 11 real-connection transaction/race cases. It also covers a full
  task supervisor and captures debug SQL logs to check token secrecy.
- `mix precommit` passed, including all **480 JavaScript tests**.
- These runs used a fresh PostgreSQL test database. The full-suite result
  above belongs to the first foundation batch; this batch ran the relevant
  regression suites rather than repeating the full suite.

Last-manager protection, creation/conversion and the account switcher remain
pending; completing the drain alone does not expose managed accounts.

Third batch — implementation review follow-up (complete):

- [x] Bound the observer to 30 consecutive unavailable database checks.
  A reachable transaction resets the failure count, regardless of how long
  it stays open. Exhaustion logs the failure count and batch size, never
  tokens, and stops without guessing that a transaction committed.
  Deleted tokens still fail validation; sockets can remain connected until
  their next authorization check or reconnect if observation is exhausted.
- [x] Document host-owned transaction behavior under the SQL sandbox in the
  external-module guide, including how to test real commit/disconnects.
- [x] `UserSettings` removes email/password/OAuth/session sections even for
  host embeds and rejects their events before parsing input. Crafted profile
  saves cannot change login or Google email. Security/session tabs are not
  offered to managed accounts.
- [x] Layout and settings timezone detectors are suppressed for managed
  accounts; server-side alerts and browser-timezone events also no-op.
  An explicitly selected organization timezone remains editable.
- [x] PostgreSQL regression tests and `mix precommit` passed.

Validation:

- Fresh PostgreSQL test database, with integration tests enabled: **50 tests,
  0 failures**, covering revocation lifecycle/concurrency, observer exhaustion
  and recovery, managed settings, ordinary profile tabs and timezone alerts.
- Additional existing embedded-settings and registered-tab regressions:
  **18 tests, 0 failures**. Final focused observer/settings rerun after the
  explicit-section test and log wording changes: **7 tests, 0 failures**.
- `mix precommit` passed (compile, test-file compilation, format, Credo,
  Dialyzer and all **480 JavaScript tests**). No migration changes in this batch.

At the end of the third batch, creation/conversion and manager lifecycle locking
were still pending; the fourth batch below implements them. No public
managed-account creation or acting-session minting is exposed by these batches.

Fourth batch — remaining phase 1 and manager lifecycle (2026-10-30, complete):

- Dedicated internal creation and conversion contexts are implemented, with
  first-manager requirements, default User role, unknown password hash,
  confirmation/referral admission and no registration/bootstrap path.
- Conversion drains every token context, provider link, Google address and API
  key; conversion back requires new validated credentials, clears confirmation,
  removes grants and cancels pending manager invitations atomically. No routes
  or UI expose these operations yet.
- Both conversion directions refuse forbidden staff/API roles. Converting back
  cannot lift the managed ceiling over an illicit direct Owner/Admin assignment
  or API-bearing custom role left on the account.
- Manager mutations take a per-person advisory lock before organization locks;
  person lifecycle discovers the person's grant set under that advisory lock,
  then locks organizations in uuid order. Organization rows use `FOR NO KEY
  UPDATE`, followed by user locks and fresh session/eligibility checks.
  The advisory key uses the canonical UUID, so differently cased input cannot
  split the topology lock and let deactivation miss a concurrently added grant.
- Administrative authority carries current/root session references from the
  trusted signed session. Bare users/scopes and borrowed admin sessions cannot
  authorize creation, conversion or direct grant additions. Acting managers
  can remove grants for their organization, with no last-manager override.
- Last-active-manager checks now cover grant removal and person deactivation
  and deletion. An override requires an explicit boolean plus a live own-admin
  session reference. Deletion checks before module hooks and rechecks before
  the actual delete.
- Password/profile writes now recheck and lock current managed-account policy,
  so a form loaded before conversion cannot restore credentials. Role grants
  share conversion's user-row lock and recheck the permission ceiling.
- OAuth linking and API-key creation/rotation also lock the account before
  minting credentials. Conversion therefore drains a writer that commits
  first, or the writer waits and sees the converted policy. Rotation locks
  the owner before the key, avoiding the inverse lock order with conversion.
- Manager added/removed activities and account-notification copy are wired to
  actual row changes, including conversion back and person deletion; direct
  additions/removals are idempotent.

Internal entry points (no routes/UI yet):

- `ManagedOrganizations.Actor.from_session/1` takes the trusted signed session;
  its references must never be taken from event/request params. Contexts recheck
  live tokens, root identity, confirmation/admission and effective staff roles.
- `ManagedOrganizations.create/3`, `convert_to_managed/3` and
  `convert_to_independent/3` take that actor. Conversion back returns an
  unconfirmed account with validated new email/password; the later UI uses the
  ordinary confirmation flow after commit. No mail is sent inside conversion.
- `OrganizationManagers.add/3` is admin-only; `remove/4` also accepts a live
  acting-manager credential for that organization. Manager additions by email
  still await the invitation acceptance path (no direct person search).
- Person status/deletion keeps the existing actor/rank API. An explicit
  `allow_managerless: true` additionally requires `manager_actor:` from the
  own-admin session, matching `actor:` / `current_user:` when supplied. System
  callers without that credential cannot bypass the last-manager check.
- Lock order: per-target-person advisory lock, affected organizations in uuid
  order, person rows, actor user `KEY SHARE`, then parent session, grant and
  current session `KEY SHARE`. The actor user lock precedes token locks so a
  concurrent user deletion cannot hold that row while waiting for the token.
  The last-manager lifecycle wrapper locks its user/override-actor rows together
  in uuid order; outright user deletion uses `FOR UPDATE` to block FK inserts.

Validation:

- PostgreSQL regression run: **2,953 tests, 0 failures** (`integration/users`,
  unit `users` and `api`, managed web-auth doors, admin password and managed
  settings). These tests ran with integration enabled on a fresh scratch DB.
- Latest focused run: **130 tests, 0 failures**, including **15 real-connection
  lifecycle races** (remove/deactivate, multi-organization deactivation,
  account-type vs grant, password/role vs conversion, session revocation and
  both orderings of OAuth/API creation/API rotation vs conversion). Invite-only
  admission is tested with the referral gate actually enabled.
- Final person-deletion audit regression: **53 tests, 0 failures**. Password
  mutation freshness/provenance regression: **45 tests, 0 failures**. The final
  lifecycle/conversion run after the conversion-back role guard: **34 tests,
  0 failures**, including all 15 lifecycle concurrency cases.
- UUID-case regression rerun: **16 real-connection concurrency tests,
  0 failures**. The final case exercises a grant insertion using an uppercase
  UUID against a lowercase-UUID deactivation and proves the last-manager guard
  still applies after the first transaction commits.
- Final `mix precommit` passed after the canonical-UUID lock change: compile,
  test-file compilation, format, Credo, Dialyzer and all **480 JavaScript tests**.
  No migrations changed. The broad suite was followed by focused regression
  runs for the final changes; the entire repository suite was not repeated.

Next batch: phase 2's enter/leave context and routes, with the root-session,
grant and organization locks, then the multi-session/cookie exception and
switcher UI. Public creation/conversion still awaits those pieces and phase 3's
admin/self-service managers and invitation acceptance flow.

Fifth batch — phase 2 switching (2026-10-30, complete):

- Enter/leave context and both route scopes are implemented. Entry is limited
  per root user before target lookup and locks organization, parent user/session
  and manager grant before rechecking authority and minting provenance.
- One organization token sits outside the five-account limit and is omitted
  from ordinary account lists. Replacement/switch-away/leave revoke it; add and
  impersonation refuse while acting. The logout controller ends the full stack.
  Entry takes `FOR NO KEY UPDATE` on the root session and replaces its existing
  child sessions from the database, so concurrent requests or stale cookies
  cannot leave multiple live organization tokens for one browser. Concurrent
  requests for the same organization reuse one token/activity. Logout/grant
  revocation still take stronger source locks and collect the committed child.
- The durable mirror has a separate organization slot, root binding and live
  grant/session validation. Org-only mirrors survive with multi-session off;
  ordinary additions are dropped on recovery when that switch is off. Writes
  track their latest state inside the request to avoid restoring stale cookie
  contents during composed switch/leave operations.
  A revoked organization slot falls back to the still-live root on the next
  HTTP request. A managed token can never be used as a multi-session root, even
  if malformed session data omits the organization marker.
- Scope carries root-person organizations and acting identity. Both dropdowns
  use `Core.OrganizationSwitcher`; headers show organization/person provenance.
- `Actor.opts/1` supplies the person explicitly; activity logging merges it into
  metadata and activity lists/details resolve people in a batch. Role/profile
  writers carry provenance. The source browser's Sessions entry lists acting
  organizations. User listings/details/search, session projections, presence,
  mentions and other human-facing account labels use managed contact addresses.
- Custom-field mutation responses preserve the caller's token-loaded session
  metadata; shared user-update broadcasts strip it. Profile Settings reloads
  its own token on updates, so one manager's identity cannot become another's.
- Switcher/flash/session-row strings are in the catalog and all nine locales.
  The admin users list now has a managed badge and searches contact/name.
- PostgreSQL regression: **1,844 tests, 0 failures** across users, web-auth,
  activity, mentions, profile settings and legacy session flows. Final focused
  run: **188 tests, 0 failures**, including **11 real-connection races** for
  enter vs root/grant/person/org revocation, simultaneous same/different-company
  entry, and rollback of replacement. It also checks cookie recovery/replay,
  root authority, rate limiting, session provenance and debug-log token secrecy.
- Final switching/legacy/concurrency verification: **58 tests, 0 failures**,
  including explicit route checks in both locale scopes, early OAuth add-account
  refusal, clearing the remembered active account on return to My account, and
  rendering a managed organization without a contact address.
- `mix precommit` passed with all **480 JavaScript tests**. No creation/conversion
  UI is exposed; phase 3 interfaces/invitations remain next.

Sixth batch — phase 3 interfaces and invitations (2026-10-30, complete):

- Implementing kind-aware manager invitations with locked acceptance, live
  administrator/acting-manager authorization, scoped cancellation, generic
  invite responses and per-person/organization rate limits.
- InvitationHook is attached to all kit user surfaces, idempotently for hosts
  that also attach it. Banners travel through the mounted scope into the layout;
  acceptance re-reads the current session and refreshes the organization switcher.
- Shared admin/self-service manager controls, contact editing, administrator-only
  person search, conversion forms and dedicated managed creation are implemented.
  Creation requires the organization switch and an own-account administrator;
  person deactivation/deletion include the explicit last-manager override.
- The manager kind accepts only active ordinary people, with current email and
  confirmation policy checked under locks. A person's employment is unchanged.
  Conversion back and person lifecycle changes cannot race a stale acceptance;
  acceptance/decline/cancel status changes serialize. Expired pending invites
  can be replaced; duplicates consume the rate limit and return generic copy.
- New manager mail is registered in the template editor and all interface,
  invitation and notification copy is in the catalog and all nine locales
  (**49 entries**, with interpolation keys verified across locales).
- Contact/conversion saves refresh their parent. Profile Settings reloads its
  own token to preserve browser provenance; shared references never carry raw
  tokens. Raw-token lookup SQL is excluded from debug logging and tested.
  Managed organizations cannot be unconfirmed, including through stale forms.
- PostgreSQL broad regression: **1,912 tests, 0 failures**. Final verification
  after scope-refresh, contact-refresh and token-log refinements: **144 tests,
  0 failures** across new/legacy invitation, switching, creation, settings and
  tab contracts, including **18 real-connection race/rollback cases** (7 for
  invitations and 11 for switching). The dedicated new manager/lifecycle UI
  run passed **47 tests** before the final token-log assertion was added.
- `mix precommit` passed: warnings-as-errors compile, test-file compilation,
  formatting, Credo strict, Dialyzer and all **480 JavaScript tests**.
- Core safety and UI paths now work together, satisfying the creation gate.
  No version bump, publication or deployment is part of these implementation
  batches. The separate CRM mirror work remains phase 4.

Seventh batch — phase 4 CRM mirror (2026-10-30, complete):

- Implemented in the separate `phoenix_kit_crm` package. The managed option is
  explicit and requires an own-account administrator plus a first manager;
  it never becomes an automatic fallback for a company whose email is taken.
- Managed addresses map to `contact_email` in creation, diff/resolution and
  reverse creation/adoption. Panels, pickers and organization lists never show
  the login placeholder. The existing read-only rule for claimed mirror-account
  profiles remains; those details are edited through core settings. Linking a
  CRM record never grants management.
- The company is re-read under a row lock before creation. A real PostgreSQL
  race verifies that simultaneous requests create/link one account, and stale
  forms cannot orphan another. Rollback, invalid contacts, shared-email collisions,
  grant eligibility and forged/stale/borrowed browser authority are covered.
- CRM full suite against local core: **1,038 tests, 0 failures**, **15 excluded**
  (catalogue-dependent tests). Local-core `mix precommit` passed. Its owner-marker
  subprocess test now clones this run's configured test database; previously it
  used a stale default database even when `PGDATABASE` selected a fresh scratch.
- New CRM copy is translated in all three package locales (en/et/ru). Published
  core compatibility: **1,038 tests, 0 failures, 20 skipped**, **15 excluded**;
  only the managed-feature cases skip when that older core lacks the API.
- Both local-core and published-core `mix precommit` gates passed. The published
  dependency audit found an existing Bandit 1.14.0 advisory; Bandit is patched to
  **1.14.1** and the audit is green. Other unrelated dependency pins are preserved.
- Final managed-address display audit also covers role lists and the interaction
  composer's own-account shortcut. Focused verification after these changes:
  **36 tests, 0 failures**, including the managed role-page rendering test,
  fresh authority/eligibility, rollback, concurrency and legacy components.
  The final local-core project gate passed on that source. Isolated scratch
  databases used for these checks have been removed.
- The CRM remains compatible with its existing core floor: the new option is
  offered only when the complete managed-organization API is available.
- Checkpoints: core `21813586d` (switching/attribution), core `fcd900fc3`
  (manager interfaces/invitations), CRM `5f5e8c7` (managed mirrors). No package
  version bump, publication or deployment was performed.

## Tests

- Every login door refuses a managed organization, one test each: password,
  magic link (request, verify), OAuth (sign-in, attach), QR (approve,
  complete), password reset (lookup, mutation), email confirm, email change,
  add account, impersonation.
- Session query: a managed organization's token with no grant columns; with a
  removed manager; with an expired or deleted person session; with a
  deactivated, `api_only` or non-person person; with a grant for another
  organization → nobody signed in. An unmanaged account's token still works.
- Removal then re-grant: the old token stays dead.
- `act_as_organization` decides on the root: a person acting for A cannot
  enter B that only A manages; a non-manager, an inactive organization and an
  unmanaged organization are refused; refusals are logged.
- One organization token per stack, outside the account limit (a full stack
  of 5 people can still enter); entering a second replaces and disconnects the
  first; entering the same one is a no-op.
- `list_accounts/1` omits the organization token.
- `switch_to/2`, log out of the active account, and `remove_account/2` all
  leave (delete + disconnect). Log out all ends person + org.
- Add-account and impersonation while acting are refused.
- Works with `multi_session_enabled` off: enter, leave, lost session resumes
  in the organization from the mirror. Org-only mirror is kept;
  `accounts: []` does not forget the cookie; old cookies without the org key
  still decode.
- Routes exist at both `/users/session/organizations/:uuid` and
  `/:locale/users/session/organizations/:uuid`.
- Enter lands on `post_auth_path`; leave from an org-only URL lands on a path
  the root can open.
- Master switch off: new enter is refused; an already-acting session still
  resolves.
- Enter is rate-limited per root user.
- Revocation: each `Sessions` revoke path, password reset, person
  deactivation/deletion, manager removal, conversion and organization
  deactivation end the organization session **and** disconnect its socket.
- The same cascade + disconnect checks cover `Auth` single/all-session
  deletion, user/admin password changes and external-proof confirmation.
- Real concurrent transactions: enter vs session revoke, enter vs grant
  removal, conversion vs enter / invitation accept, two last-manager
  removals, and manager removal vs person deactivation. No surviving socket,
  revived grant, or unintentionally managerless organization.
- Convert-back deletes manager grants and cancels pending manager invites;
  an old invite cannot be accepted afterwards or after converting to managed
  again. Member invitations keep their existing semantics.
- Embedded LiveView with a managed organization's uuid: loads it when the
  session's token resolves to that organization; anonymous when the grant has
  ended or the token is another account's. Any other uuid: unchanged. The
  loaded user carries `acting_user_uuid` from the session query (not a
  second `get_user`); `phoenix_kit_session_token` is set so a later
  refresh still consults the grant.
- API: a managed organization cannot get a key or service user; an existing
  key row for one fails `Keys.verify/2`; conversion revokes keys.
- Ceiling: a managed organization never gets Owner/Admin/`"*"`/`api`, also
  when a role it holds is edited to include `"*"` afterwards. Dedicated
  create does not call `ensure_first_user_is_owner/1`.
- Invite-only: acting as a new managed org is admitted (`mark_satisfied`).
- `hashed_password` is a random hash after create and after convert-to-managed,
  never `NULL`. Public registration of `@organization.invalid` is refused.
- Never authenticate via `contact_email` (magic link, OAuth).
- Activity rows written while acting carry the organization as actor and the
  person in metadata; a job enqueued while acting too. The activity UI shows
  the organization name and the acting person, not the placeholder.
- Mailer drops `.invalid` in `to`/`cc`/`bcc`; the recipient helper uses
  `contact_email` for a managed organization; `UserNotifier` template
  variables do too. No confirmation mail on managed create.
- Display helper: nav, admin users list/search (`contact_email`,
  `organization_name`), admin sessions, presence — no placeholder.
- `UserSettings` email/password/OAuth event while acting is rejected.
  Convert while acting is rejected even though "self" passes
  `can_manage_user_credentials?/2`; manager changes while acting pass only
  through the grant check (§9a).
- `TimeZoneAlert` does not write the organization.
- Last-manager rule: manager-row remove, **and** deactivating or deleting the
  person who is the last manager. A person with manager rows cannot become
  `account_type: "organization"`.
- Managers managing managers: a manager invites by email and the answer is
  identical for an existing account, a missing one, an existing manager and a
  pending *manager* invitation; a pending *member* invite for the same
  address does not block or no-op the manager invite (unique index includes
  `kind`); accepting requires the invitee's own session (not acting, a
  person, the invited email) and creates a manager row, not
  `organization_uuid`; auto-accept on register/confirm of `kind: :manager`
  does the same; `create_invitation/3` still inserts `kind: :member`;
  `invited_by` is the acting person while acting; a manager removes another
  and themselves; the last manager cannot; a session acting for org A cannot
  change org B's managers; a session whose grant was removed mid-session is
  refused on its next event; cancel is org- and grant-scoped (a uuid from
  another org is refused); `.invalid` invitee addresses are refused; the
  unique-index race maps to the generic answer; invitations are rate-limited
  including no-ops.
- Manager invitation mail and banner: existing-user manager invite sends a
  login URL, not `/users/register?invitation=`; new-user manager invite
  still sends a registration URL with manager copy; `InvitationHook` is on
  kit admin and authenticated (and public-with-user) live sessions;
  banner / flash / registration copy distinguish member vs manager; after
  accept the switcher lists the org without a full reload.
- Notifications: `organization.manager_added` / `manager_removed` are on
  the `account` type and `Notifications.Render` (readable copy, not the raw
  action); they fire on row create/delete, not on send; the affected person
  gets an inbox row. `organization.entered` has no `target_uuid` and creates
  no inbox row.
- Managers UI: forged-input tests (`render_submit` with a person, organization
  or role the form never offered); a `users` holder without credential
  authority cannot add a manager. The Managers settings section is absent
  when not acting, and is not in `@hideable`.
- Prefix migration test covers V227 (kind column, kind CHECK, pending-unique
  index now includes `kind`); module-owned-tables test sees the new core
  table; both new token columns are indexed.

## Decisions (2026-10-29)

1. **Creation:** admin-created only; no self-serve "Add a company".
2. **Attribution:** the organization is the actor, the person is in
   `metadata["acting_user_uuid"]`.
3. **`MultiSession.impersonated?/1`** stays true while acting for an
   organization (the safe default): it reads as a borrowed account.
4. **Support impersonation of a managed organization:** refused in v1.
5. **CRM mirror:** an explicit, admin-chosen "managed organization" option
   with a first manager; never an automatic fallback on an email collision.
6. **Manager rights:** one level, the organization's full authority.
7. **Managers may add and remove managers** themselves while acting, by
   invitation, never by person search (§9a).

Design defaults proposed in the Grok review (not maintainer decisions;
adopted because they follow from the decisions above or from existing
behaviour, change them if wanted):

- **Invite-only:** a managed organization is born referral-satisfied
  (`Referrals.mark_satisfied/2`), same as `confirmed_at`.
- **Enter/leave landing:** enter → `Routes.post_auth_path/1`; leave → a path
  the root can open.
- **Master switch off:** refuse new enters; live acting sessions continue
  until they leave or the grant ends (today the switch only hides UI too).
- **Embedded identity:** load the organization only when the session's token
  resolves to it (§3; a middle ground between the two reviews).
- **Convert `contact_email`:** login email moves to `contact_email` only
  when `contact_email` is empty; otherwise `contact_email` is kept.
- **Default role** for a new managed organization: `User`; extra roles on
  the details page, inside the ceiling.
- **Person-delete / deactivate of the last manager:** same checkbox as
  manager-row remove (last-Owner shape).
- **Pending-unique index includes `kind`:** a member invite and a manager
  invite for the same address can both be pending.
- **`InvitationHook` on kit live sessions** that mount a user, so the
  banner exists without a host opt-in.
- **Manager invitations always mail;** existing users get a login URL.
- **`invited_by` is the acting person** while acting.
- **Managers settings section is not hideable;** offered only while acting.

## Review (Codex, 2026-10-29)

Codex reviewed the first version of this plan against the code (read-only).
Verdict: the approach is sound; the authentication lifecycle needed
tightening. What changed because of it:

- The acting token is bound to the person's **session row** and the **manager
  row** by cascading foreign keys, instead of a bare `acting_user_uuid`. Before,
  signing the person out (other devices, password reset, admin revoke) left
  their organization session alive, and removal followed by re-grant revived
  an old token.
- Revocation now also **disconnects** sockets (§10); deleting rows alone left
  connected LiveViews serving the organization.
- **API keys** and **embedded LiveViews** bypass the session query; both now
  refuse a managed organization on their own (§3).
- **Conversion** in either direction revokes every credential (§9); converting
  back used to turn acting sessions into ordinary ones.
- **Manager changes** need credential-level authority, not the `users` page
  permission (§9).
- The **permission ceiling** is applied when the scope is built and also
  covers `"*"` and `api` (§6); blocking Owner/Admin roles at `assign_role/4`
  alone missed the `"*"` key and the internal insertion paths.
- Corrected claims: working with `multi_session_enabled` off needs its own
  routes and a mirror slot (§4); attribution needs the scope to carry the
  person and `Actor.opts/1` to pass it, it is not free (§8); the schema change
  needs the generated manifest, not only a restamp (§1).
- Added: confirmation of new managed organizations (§2), credential sections
  hidden while acting (§6), one mail recipient helper (§7), acting sessions on
  the person's Sessions page (§10), the last-manager rule (§9), the full-stack
  case (§4), and Codex's recommendations for decisions 4–6.

## Review (Grok, 2026-10-29)

Grok reviewed the Codex-folded plan against the current code (read-only).
Verdict: the approach still holds; the org token has to be a real exception
in `MultiSession` and every `user.email` display, and two auth gates the
plan did not name will fire on the first invite-only install and the first
manager who opens their own user page.

What changed because of it:

- **`hashed_password` is `NOT NULL` since V1.** Convert-to-managed and create
  set a random unknown hash (the service-user pattern); they never write
  `NULL`. Dedicated create, not `admin_create_user/2` (`ensure_first_user_is_owner/1`
  and confirmation mail).
- **Invite-only.** `account_gate/1` also runs `Referrals.access_satisfied?/1`.
  A new managed org would park on `/users/referral`. Born `mark_satisfied`,
  same as `confirmed_at`.
- **`can_manage_user_credentials?/2` is true for self.** Manager changes and
  convert use the rule without the self clause; convert is admin-only.
  Grok's proposal that managers manage managers was accepted (decision 7, §9a).
- **Last manager vs person lifecycle.** Deactivating or deleting the person
  who is the last manager went through user status/delete and skipped the
  checkbox (`ON DELETE CASCADE` on `user_uuid`). Same rule as manager-row
  remove. A person with manager rows cannot become
  `account_type: "organization"` or `api_only`.
- **The org token vs every stack helper, not only enter/leave.**
  `list_accounts/1` omits it; `length(stack)` excludes it; `switch_to` /
  `remove_account` / `log_out_active` leave; add-account and impersonation
  are refused while it is in the stack; log-out copy vs "Back to my
  account"; enter/leave landing.
- **Mirror helpers as they are written.** `write_persisted(conn, root, [], _)`
  forgets the cookie; `active` is stored only when `active in kept`. Org-only
  slot, org as `active`, old cookies still decode.
- **Routes in both scopes** in `PhoenixKitWeb.Integration` (bare and
  `/:locale`). Enter rate-limited per root user. Master switch off refuses
  new enters and leaves live sessions alone.
- **Indexes** on `acting_session_uuid` and `organization_manager_uuid`. Pair
  CHECK also requires `context = 'session'`.
- **Never authenticate via `contact_email`.** Display helper for every human
  `user.email` (nav, activity UI, admin list/search, sessions, presence,
  mail templates). Activity UI shows organization name + acting person.
- **Embedded LiveViews:** Grok proposed loading the org user from the uuid
  (anonymous blanks `phoenix_kit_dashboards` home and comment composers),
  reversing Codex. Adopted as a middle ground instead: load it only when the
  session's own token resolves to that organization (§3). A bare uuid is
  not enough: a host can embed from a controller-rendered page, where no
  parent LiveView re-checks the session on reconnect.
- **Mail:** every `UserNotifier.deliver_*`, digest, newsletters, template
  variables; no welcome/confirmation on create; block public `@*.invalid`
  registration.
- **Member vs manager stay two relationships**; adding a manager does not
  write `organization_uuid`. Public unmanaged org signup stays.
- **`UserSettings` LiveComponent** hides and server-rejects credentials
  (hosts embed it). `TimeZoneAlert` skipped while acting.
- **v1 limitations** written down: authorship is the org, notifications are
  org-centric, AI / machine API off while acting.
- Grok's proposals recorded as design defaults, not decisions; managers
  managing managers became decision 7.

## Review (Grok, second pass, 2026-10-29)

Grok re-read Claude's recheck against the invitation and LiveView-session
code (read-only). Verdict: the embeds middle ground and §9a
invitation-not-search are right; the invitation *path as it is written
today* would ship manager invites as member joins, with no working accept
UI for existing users.

What changed because of it:

- **Pending unique index.** V135's
  `phoenix_kit_org_invitations_pending_unique_idx` is
  `(organization_uuid, email) WHERE pending`. V227 replaces it with
  `(organization_uuid, email, kind) WHERE pending`, plus a CHECK on
  `kind`. The changeset maps that index by name so a race is the generic
  answer, not a raw DB error. Today's changeset only constrains `:token`.
- **Accept branches on `kind`.** `do_accept_invitation/3` always
  `Auth.set_organization/2`. Registration and confirmation auto-accept
  (`pending_invitation_uuid`) go through that too. Manager accept inserts
  the manager row and never writes `organization_uuid`.
  `create_invitation/3` stays, default `kind: :member`.
- **`InvitationHook` is not on any kit `live_session`.** Install does not
  add it. `maybe_send_invitation_email/3` skips existing users;
  `deliver_organization_invitation/3` always sends a registration URL.
  Hook attached to kit sessions that mount a user; manager invites of
  existing users get a login-URL mail; member invites keep banner-only
  for existing users once the banner actually renders. Kind-aware copy
  on banner, flash, registration, templates.
- **`cancel_invitation/1` takes only a uuid.** Cancel is org- and
  grant-scoped.
- **`invited_by` while acting is the org** if the caller passes
  `phoenix_kit_current_user`. Store `Scope.acting_user_uuid/1`.
- **After manager accept, `scope.acting_organizations` is stale** (the
  hook only assigns `current_user`). Rebuild it so the switcher updates.
- **Banner hidden while acting** (`confirmed_person?` requires a person).
  Accept from your own account; document it.
- **Embeds:** use the session-query user (so `acting_user_uuid` is
  present) and set `phoenix_kit_session_token`; otherwise
  `reload_session_user/2` falls back to `get_user/1` and skips the grant.
- **Activity / notifications.** `organization.manager_added` /
  `manager_removed` on row create/delete, registered on the `account`
  type and in `Notifications.Render`. `organization.entered` has no
  `target_uuid`. `.invalid` invitee addresses refused. Rate limit
  through `RateLimiter` on acting person and org, including no-ops.
  Managers section not hideable, offered only while acting.

## Review (Codex, implementation readiness, 2026-10-29)

Ready to begin implementation. The architecture and decisions stand. Four
requirements were tightened before starting:

- Revocation covers the `Auth` token drains and every credential rotation,
  not only `Sessions` and password reset. Cascades alone do not disconnect
  the dependent organization's LiveView sockets.
- Token collection and deletion share a transaction and locks with token
  minting. Add actual concurrent-transaction tests for enter/revoke and
  last-manager races.
- Conversion back removes manager grants and cancels pending manager
  invitations; acceptance checks the current organization state.
- Phases are implementation work packages. Managed creation/conversion is
  exposed only after the safety requirements from phases 1–3 work together.

Start with V227, the schema, session-query guard and authentication doors.
Validate against real PostgreSQL, including a named prefix. Add switching
and UI after the foundation is verified.

## Review (Claude, implementation, 2026-10-29)

Claude reviewed the two foundation commits (`88d197fd6`, `e42cc7ebf`) against
this plan. Verdict: the session-query guard, the doors, the migration and the
revocation drain match the plan, and the tests exercise them for real
(targeted suites 92/92, `test/integration/users` 797/797, unit `users`
344/344 against PostgreSQL). Fixed in this review:

- **CHANGELOG.** The entries went under `## 3.0.0`, which is already tagged
  and published. Moved to `## Unreleased`.
- **The ceiling did not reach role authority.** `Roles.can_manage_role?/2`
  and the other `actor:` checks take `owner?` from `Scope.held_roles/1` (or
  the DB roles for a bare `%User{}`), which the scope ceiling does not filter.
  A managed organization holding an Owner row (inserted directly, or left by
  a buggy future conversion) was an Owner there. Both `actor_context/1`
  clauses now answer `owner?: false` for a managed organization; regression
  assertion in `managed_organization_policy_test.exs`.
- **One ceiling definition.** `Scope` and `Roles` each spelled the forbidden
  roles and keys. Now `Scope.managed_ceiling_role?/1` and
  `Scope.managed_ceiling_key?/1`, which also cover any future `api.*` sub-key.
- **AGENTS.md** gained two landmines: managed organizations never sign in on
  their own (with `User.delivery_email/1` for addresses), and session tokens
  are deleted only through `Sessions.Revocation`.

Follow-up status:

- **Observer retry limit — resolved in third batch.** Thirty consecutive
  unavailable checks stop observation; reachable open transactions reset the
  failure count. Exhaustion logs counts only and never assumes commit.
- **Host test suites — documented in third batch.** A sandbox's outer
  transaction rolls back at cleanup, so a drain inside a host-owned transaction
  cannot produce a commit/disconnect assertion there. The external-module
  guide now explains the real-connection test setup.
- **Grant eligibility locks — resolved in fourth batch.** The schema changeset
  still performs ordinary validation reads, but all context mutations lock and
  recheck the organization/person in their transaction. Account-type changes
  share the per-person advisory lock and current user-row lock. Real PostgreSQL
  tests cover both orders of grant insertion versus account-type conversion.
- **Cost per logout.** Every token drain is now lock, dependents, delete and
  a post-commit absence check in a transaction (was one `DELETE`). Fine at
  current scale; noted in case session churn grows.
- **Plan length.** The four review sections restate design text that §1–§10
  already carry. Once phase 1 ships, fold them into a short history.
