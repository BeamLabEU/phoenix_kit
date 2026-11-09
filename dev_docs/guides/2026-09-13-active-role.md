# Active role and the role switcher

A user holding several roles acts as **one of them at a time**, and their
access is narrowed to that role. An Admin who also holds "Seller" can switch to
Seller, see the app exactly as a seller does, and has no admin access until they
switch back.

The choice is **per session**: Admin on the laptop and Seller on the phone at
the same time. It is stored on the session token
(`phoenix_kit_users_tokens.active_role_uuid`, V190).

Design and decision record: `dev_docs/plans/2026-09-13-active-role.md`.

## Turning it on

`/admin/settings/users` → **Roles** tab. All three settings are public keys in
`Settings.get_defaults/0`:

| Setting | Values | Default | Meaning |
|---|---|---|---|
| `role_switcher_enabled` | `"true"` / `"false"` | `"false"` | Off = every user has the union of their roles, exactly as before the feature existed. |
| `role_switcher_location` | `"menu"` / `"header"` | `"menu"` | Where the switcher shows. `header` = a header control from `sm` up, the account menu below it. |
| `role_switcher_always_on_roles` | comma-separated role uuids | `""` | Custom roles that are never a mode; they apply whichever role is active. |

**Role order** is set on `/admin/users/roles` (drag a row, or the arrows).
It decides the default role of a new session and the order the switcher lists
roles in. Seeded Owner, Admin, User, then custom roles by creation.

## Semantics

- **Switchable** roles are modes. Owner and Admin are always switchable (or
  narrowing could never remove admin access). Custom roles are switchable
  unless listed as always-on.
- **User** is always on.
- The scope is narrowed only when the switcher is on **and** the user holds
  **two or more** switchable roles. With zero or one there is nothing to
  choose, the scope is the union, and no switcher renders.
- Narrowed scope = active role + every always-on role held.
- No "All roles" entry: while narrowed, a multi-role user is always exactly one
  role.
- **Default role** = the first switchable role the user holds, in role order.
  Every new session starts there: a sign-in, a second multi-session account, an
  impersonation. Nothing is written until the session switches.
- **Per session, not per user.** Switching on the laptop changes nothing on the
  phone. An impersonation session has a role of its own and can switch freely;
  the borrowed account's own sessions never see it.
- A stored role the session's user no longer holds is ignored: the default
  applies. Nothing is written on read.
- **Removing a role from a user signs out the sessions acting as it.** They
  start over and land in whatever they still hold. Sessions in another role
  keep going and refresh in place.
- A user loaded **without** a session (`Auth.get_user/1`, a background job, an
  admin list) acts as their default role — never the union.

## For host apps and modules

Everything that goes through the scope already follows the active role —
`Scope.has_role?/2`, `owner?/1`, `can_access_admin_area?/1`,
`has_module_access?/2`, `can?/2`, dashboard tab `permission:` / `visible:`
filters, the admin gates.

```elixir
Scope.active_role(scope)       # %{uuid: "...", name: "Seller"} | nil
Scope.narrowed?(scope)         # acting as one role?
Scope.held_roles(scope)        # every role REALLY held: ["Admin", "Seller", "User"]
Scope.switchable_roles(scope)  # [%{uuid, name}] the switcher offers, in role order ([] unless narrowed)
Scope.for_user(user, narrow: false)  # the full union, ignoring the active role
```

Building a role-specific UI (e.g. a seller portal): gate it on a permission key
granted to that role, or on `Scope.has_role?(scope, "Seller")` in a tab's
`visible:` function. Both read the narrowed scope, so an Admin acting as Seller
sees the seller UI and an Admin acting as Admin does not (unless Admin also
holds the key).

**Re-checking on a switch.** Core evicts a LiveView from the admin area or an
admin module the new role cannot reach. A host page gated in its own `mount`
is not evicted by core; implement `phoenix_kit_scope_changed/1` on the
LiveView — core's refresh hook calls it with the socket after
`phoenix_kit_current_scope` is replaced — and re-run your gate (or
`push_navigate`) there.

**Your own layout.** The switcher renders in the kit's admin and dashboard
layouts. A host with its own layout must render
`PhoenixKitWeb.Components.Core.RoleSwitcher.role_switcher/1` (or a form `PUT`
to `Routes.path("/users/session/role")` with `role_uuid` and an optional
`return_to`) somewhere every role can reach — an Owner acting as Seller has no
admin page to find it on. From code:
`PhoenixKit.Users.ActiveRole.switch(user, session_token, role_uuid)`.

**Background jobs** that build `Scope.for_user/1` from a user loaded by uuid
run as that user's default role. Pass `narrow: false` deliberately if a job
must act with the union.

**Settings changes** (turning the switcher on or off, changing always-on roles)
take effect on each session's next page load; open LiveViews keep their
current scope until then.

## Landmines

- ⚠️ **The active role lives on the session token and nowhere else.** It
  reaches `Scope.for_user/1` through `%User{active_role_uuid: _}`, a virtual
  field that only `UserToken.verify_session_token_query/1` fills. The scope is
  rebuilt from the token in plugs, every LiveView mount and the role-change
  refresh (`refresh_scope_assigns/1` reloads through
  `phoenix_kit_session_token`, never by uuid). A copy held in a session key or
  an assign is dropped by each of them.
- ⚠️ **Access decisions read the scope; rules protecting against a user's real
  roles read `held_roles/1`.** Example: "you cannot edit a role you hold"
  (`Permissions.can_edit_role_permissions?/2`) uses `held_roles`, so acting as
  Seller does not make the user's Buyer role editable by them. Never ask it what
  someone may do: in a session acting for an organization it is the organization's
  roles, including ones outside the person's link. `user_roles/1` answers that.
- ⚠️ **Code that reads roles straight from the database ignores the active
  role.** `Roles.user_has_role_owner?/1`, `Roles.get_user_roles/1`,
  `User.get_roles/1` return real roles. Use the scope for access decisions.
  Known sibling sites still to move: phoenix_kit_comments
  (`user_is_admin?`), phoenix_kit_posts (`user_is_admin?`),
  phoenix_kit_projects (`Grants.role_subjects`).
- ⚠️ **Internal `custom_fields` keys are written with
  `Auth.merge_user_custom_fields/3`**, never by replacing the map from a
  struct held in assigns: a stale replace silently restores every other key's
  old value (`TimeZoneAlert.remember/2` is the worked example).
- **Impersonation** authority judges the root account's roles *in effect for
  the root session*: an Admin whose root session acts as a custom role cannot
  impersonate. Targets are judged by their real roles.
- **Switch redirect:** `return_to` is followed only when the new scope can
  mount it — admin-area paths are resolved through the router to their
  LiveView and asked the mount gate's own question
  (`Session.reachable_return_to?/3`), every role alike.

## Events

- Activity: `session.role_switched`, metadata `from` / `to` role names (actor =
  target, so no notification).
- PubSub: `ScopeNotifier.broadcast_active_role_changed/1` sends
  `{:phoenix_kit_scope_roles_updated, user_uuid, :active_role_changed}` on the
  user's scope topic. Core's LiveView hook refreshes the scope — each session
  from its own token, so only the session that switched actually changes —
  with switch-specific eviction copy. A process subscribing to that topic
  directly must handle the 3-tuple.
- The sessions lists (`/admin/users/sessions`, the user's own devices) show
  the role each session acts as (`Sessions.*` rows carry `active_role`).

## Testing

The settings cache is not started in the test suite, so settings writes stay in
the sandbox transaction and tests can run `async: true`. Put a **session** into
a role without the HTTP switch by writing the token row:

```elixir
Settings.update_boolean_setting("role_switcher_enabled", true)
token = get_session(conn, :user_token)
Repo.update_all(from(t in UserToken, where: t.token == ^token), set: [active_role_uuid: role.uuid])
```

For a scope without a conn, set the virtual field the token loader would:
`Scope.for_user(%{user | active_role_uuid: role.uuid})`.

Reference suites: `test/phoenix_kit/users/active_role_test.exs` (pure rules),
`test/integration/users/active_role_scope_test.exs`,
`test/integration/users/role_order_test.exs` (order, revocation, sessions
lists), `test/integration/phoenix_kit_web/users/active_role_{gate,switch}_test.exs`,
`test/phoenix_kit_web/components/core/role_switcher_test.exs`.
