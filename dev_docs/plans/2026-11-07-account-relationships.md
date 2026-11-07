# Account relationships

**Status:** scope only, not started. Design agreed: WoodMatrix accepted it and
answered both open questions on 2026-11-07 (see
[Decided with WoodMatrix](#decided-with-woodmatrix)).
**Requested by:** WoodMatrix, 2026-11-06. Brief and our reply:
`woodmatrix/dev_docs/2026-11-06-brief-phoenix-kit-account-relationships.md`.
**Builds on:** [Acting for an organization](2026-10-29-act-as-organization.md),
whose §6 decided "one manager level" for v1. This plan replaces that decision.

## Problem

A person acting for a company gets all of the company's roles, and every
manager can invite more managers and edit the contact address. So there is no
ordinary staff level, and no way to say "Anna is only a buyer here". Apps also
want their own kinds of link between accounts (employee, agent, reseller,
`client_of`) without a core release for each.

## Decision

1. **Relationship types are data**, defined by the app or an admin, in a new
   table shared by every kind of link.
2. **Acting links stay in `phoenix_kit_organization_managers`.** The table gains
   a type, an `all_roles` flag and a list of roles. Every row in it still means
   "this person may act for this company".
3. **Links that grant no access go in a new table** (Phase 2). They never enter
   the table the session code reads.
4. **Roles on a link narrow.** While acting, a person has the company's roles
   that are also on their link, and never more.

The role table stays the only list of what people may do, so the permission
matrix, sidebar and role switcher keep working.

### Rejected

- **One table for every link, as the brief suggested.** 13 places read the
  grants table, and the entry checks only ask whether a row exists
  (`managed_organizations/sessions.ex:173`, `auth/user_token.ex:213`). One missed
  type filter would let a non-acting row open a full session, which is the same
  failure the brief gives for a company column on role assignments. Rule 3 could
  not be a database constraint either: `can_act` lives on the type, and a partial
  unique index cannot see it. `remove_locked`, `insert_locked` and both
  `lock_grant` functions also assume one row per pair and would raise on a second.
- **A role assignment with a company column.** Every reader of
  `phoenix_kit_user_role_assignments` treats it as global, so any reader not
  updated would make "Buyer at one company" read as "Buyer everywhere".
- **Moving acting links to a new table.** Tokens, locks and revocation are built
  around the current one, and nothing here needs them moved.
- **Renaming the table.** With only acting rows in it, the name still fits well
  enough. A rename would touch `organization_manager_uuid` on tokens, constraints
  and the manifest for no change in behaviour. The word users and hosts see is
  "link".
- **A blank role list meaning "all roles".** See rule 1.
- **Roles that apply whether or not the company holds them.** A link could exceed
  the company, and `require_permitted_roles!` and the managed ceiling's assignment
  guards read only the company's role rows, so they would never see those roles.

## Decided with WoodMatrix

Answered on 2026-11-07, at the end of the brief.

1. **Phase 1 has no non-acting person-to-company types.** Everyone WoodMatrix
   links acts for the company; people who don't log in live in the CRM. Phase 1
   only grows the existing table, and `RelationshipTypes` refuses `can_act: false`
   until Phase 2.
2. **A person without `can_manage` cannot edit the company's profile.** Other
   parties see its name in emails, and its country sets date and number formats.
   Today the Account tab has no gate, and `profile_params/2` passes
   `organization_name` through to `User.profile_changeset/3`, so a forged
   `update_profile` event can rename the company as well. See
   [Staff level](#staff-level).
3. **`held_roles` stays the company's roles in an acting session.** WoodMatrix
   asked for this to be decided and documented. See [Scope](#scope).

## Data model

All in V229, core tables, listed in `ModuleOwnedTables`' core list. New schemas
`use PhoenixKit.SchemaPrefix`; SQL follows the prefix-safe rules.

### `phoenix_kit_relationship_types` (new)

| Column | Notes |
|---|---|
| `uuid` | `uuid_generate_v7()` default |
| `key` | Unique, fixed at creation, never translated |
| `data` | JSONB: name and inverse name per language, the shape of `PartyRoleType.data` |
| `from_kind`, `to_kind` | `person` or `organization`, fixed at creation |
| `can_act` | Fixed at creation |
| `can_manage` | Fixed at creation |
| `status` | `active` or `archived` |
| `position`, `built_in` | As in `PartyRoleTypes` |

Checks: `NOT can_manage OR can_act`, and
`NOT can_act OR (from_kind = 'person' AND to_kind = 'organization')`.

The migration seeds one built-in type, `manager`, with `can_act` and `can_manage`
on and a fixed uuid, so the column default below can name it.

**The access flags are fixed at creation.** `can_act` decides which table a link
lives in. Turning off `can_manage` on `manager` would leave every company with no
manager, past rule 8, with nobody asked. A wrong unused type is deleted and made
again; a used one is replaced by a new type and its links moved. This needs no
locking between type edits and link writes, because there are no such edits.

### `phoenix_kit_organization_managers` (grows)

```sql
ADD COLUMN relationship_type_uuid uuid NOT NULL DEFAULT '<manager uuid>'
  REFERENCES phoenix_kit_relationship_types(uuid) ON DELETE RESTRICT,
ADD COLUMN all_roles boolean NOT NULL DEFAULT true,
ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}'
```

The unique index on `(organization_uuid, user_uuid)` stays, and it is rule 3.

### `phoenix_kit_organization_manager_roles` (new)

`uuid`, `organization_manager_uuid` (`ON DELETE CASCADE`), `role_uuid`
(`ON DELETE RESTRICT`), `inserted_at`. Unique on the pair, index on `role_uuid`.

### `phoenix_kit_organization_invitations` (grows)

```sql
ADD COLUMN relationship_type_uuid uuid REFERENCES ... ON DELETE RESTRICT,
ADD COLUMN all_roles boolean NOT NULL DEFAULT true,
ADD COLUMN role_uuids uuid[] NOT NULL DEFAULT '{}'
```

Backfill `manager` for `kind = 'manager'`, then check that a `manager` invitation
has a type and a `member` one has none. `kind` stays `:manager` for every acting
type, so the pending unique index does not change.

`role_uuids` is a snapshot, not a join table: at acceptance it keeps the roles
that still exist, so a role deleted meanwhile leaves the person with less.

### `phoenix_kit_account_links` (Phase 2)

`uuid`, `from_uuid`, `to_uuid` (users, `ON DELETE CASCADE`),
`relationship_type_uuid` (`RESTRICT`), `created_by_uuid` (`SET NULL`), `metadata`,
timestamps. Unique on `(from_uuid, to_uuid, relationship_type_uuid)`, check
`from_uuid <> to_uuid`.

## Rules

The brief's numbering; changes are marked.

1. **Changed. An explicit `all_roles` flag, not a blank list.** A blank list
   meaning "all" fails open: unticking someone's last role would give them every
   role, a cascading foreign key would do the same, and a per-role grant check
   passes an empty list because there is nothing to check. So `all_roles = true`
   is every role the company holds, which is what every existing row defaults to.
   `all_roles = false` is exactly the listed roles, and an empty list means none.
2. **Extended. Narrowing,** with the managed ceiling on top. The `User` system
   role survives narrowing, as it survives the role switcher: companies hold it
   by default and it is a baseline, not something to tick. Custom always-on roles
   do not survive; a link beats the switcher's setting.
3. **One acting link per person and company.** The existing unique index.
4. **Only `can_act` types open a session.** By construction: no other type can
   have a row in this table.
5. **Links between companies grant no access.** By construction: the access code
   never reads `phoenix_kit_account_links`.
6. **Extended. Removing a link ends the session at once; removing a role from a
   link ends the sessions acting as that role.** Core signs a session out when
   its active role is taken away, rather than quietly continuing in another role
   (`Sessions.revoke_user_sessions_in_role/2`). That function matches on the
   company, so it would sign out everyone there in that role. A link change needs
   a version limited to `token.organization_manager_uuid == link.uuid`. Other
   sessions refresh through `ScopeNotifier.broadcast_roles_updated(org.uuid)`,
   after the commit. Open pages already subscribe to the company's uuid and reload
   from their own token.
7. **Extended. Handing out roles.**
   - Every listed role must be held by the company.
   - Someone acting: each listed role passes `Roles.can_manage_role?/2` on the
     person's link scope built with `narrow: false`, so a manager switched to Buyer
     does not lose what their link allows. Only a person whose own link is
     `all_roles` may set `all_roles`.
   - An Admin from their own account: each role passes `can_manage_role?/2`, and
     `all_roles` needs that for every role the company holds. An Owner always passes.
   - A non-Owner never changes their own link (`:cannot_modify_own_roles`).
     `own_roles_refused?` cannot catch this, because in an acting session it
     compares the company's uuid with the person's.
   - `host_*` calls skip the rank check, because the host decides. `Actor.host!`
     returns a plain map, so `can_manage_role?/2` would refuse everything there.
8. **The last-manager rule counts `can_manage` links.** It also runs when an
   update moves a link to a type without `can_manage`.
9. **A role on a link counts as in use.** `role_has_assignments?` also checks the
   join table. `RESTRICT` is the backstop, so `delete_role/2` deletes through a
   changeset with `no_assoc_constraint`, or a race raises instead of answering
   `{:error, :role_in_use}`.

Also:

- **Archiving a type stops new links only.** Existing links and sessions continue.
  An invitation of an archived type cannot be accepted.
- **A company that loses a role keeps it on the link.** Narrowing ignores it, and
  it applies again if the company regains the role.

## Code changes

### Types

`PhoenixKit.Users.RelationshipType` and `PhoenixKit.Users.RelationshipTypes`,
modelled on `PhoenixKitCRM.PartyRoleTypes`: `list_types/1`, `get_type/1`,
`get_type_by_key/1`, `create_type/2`, `update_type/3`, `archive_type/2`,
`restore_type/2`, `delete_type/2`, `ensure/3`.

The update changeset casts only `data`, `position` and `status`. `ensure/3`
returns an existing type untouched, but answers `{:error, :type_conflict}` when
the flags or kinds asked for differ from the stored ones: a host must not boot
believing a type is safer than it is. The built-in type cannot be archived or
deleted.

### Scope

`Scope.for_user/2` (`auth/scope.ex:172`):

- `eligible_roles/2` applies the ceiling, then the link. One query, only when
  `organization_manager_uuid` is set, reads the link, its type and its role uuids.
- A new `acting_link` field holds `%{uuid, type_key, can_manage?, all_roles?,
  role_uuids}`. It is built in `for_user/2`, so no new session field has to pass
  through `preserve_session_fields`, `password_update_multi` or
  `Events.broadcast_user_updated`.
- `held_roles` keeps reading the raw `held` list.
- New helpers: `Scope.acting_link/1`, `Scope.can_manage_organization?/1`.

**`held_roles` in an acting session means the company's roles**, including those
outside the person's link and above the managed ceiling. It says nothing about
what the person may do: that is `user_roles/1`, `has_role?/2` and `can?/2`. The
link is a filter like the ceiling, and core already leaves the ceiling out of
`held_roles` (the comment at `roles.ex:1372`). Its readers:

| Reader | In an acting session |
|---|---|
| `Permissions.can_edit_role_permissions?/2` (`permissions.ex:1638`) | The reason for this choice. A person with only Supplier whose role holds `users` still cannot edit Buyer, a role of the company they act for. With the link's roles in `held_roles`, they could |
| `Roles.actor_context/1` (`roles.ex:1379`) | Not reached: managed organizations take the clause above it |
| `Scope.to_map/1` | Reports it unchanged |
| `PhoenixKitWebAnalytics.Tracking.current_roles/1` | An internal-traffic flag, not access. Someone acting for a company that holds a listed role counts as internal |
| Role switcher | Does not read it. `switchable_roles` comes from the eligible roles, so it follows the link. The moduledoc at `scope.ex:92` says otherwise: correct it |

The trap is a host reading it as "what this person has".
`Onboarding.active_business_role/1` in WoodMatrix did, and put a Supplier-only
person in Buyer mode. So state this meaning in the `held_roles/1` doc, the `Scope`
moduledoc, `AGENTS.md` and `dev_docs/guides/2026-09-13-active-role.md`.

**Fails closed.** A managed organization with no `organization_manager_uuid`, or
whose link cannot be read, holds no roles. It has no session of its own, so such a
scope is not a person's, and this keeps `ActiveRole`'s promise of "never wider
than a session could be". The audit of the `Scope.for_user` callers found:

| Caller | Effect |
|---|---|
| `lib/modules/storage/library_operations.ex:235` | Reloads by uuid and copies only the active role. Must carry the acting fields too, or acting people lose library access |
| `PhoenixKit.API.Access.fresh_scope/2` | Also by uuid, but refused already: the ceiling keeps `api` keys off a company |
| `Referrals.satisfied_by_account?/1` (`%User{}` form) | `marked_satisfied?` answers first for managed organizations |
| `test/integration/users/managed_organization_policy_test.exs:112` | Builds a scope from a bare organization and asserts it holds `users`; it needs an acting session instead |
| `test/phoenix_kit/users/referral_access_gate_test.exs:141` | Also a bare organization, but passes unchanged: `marked_satisfied?` answers before any role is read |

The other callers receive a user from a token loader, and the embedded path
already special-cases managed organizations (`embedded_session_user/2`).

### ActiveRole

`effective_role_names/1` (line 187) and `switch/3` (line 248) read
`Roles.get_user_role_records/1` directly. All three callers move to one shared
function, or the switcher and the scope disagree. `session_role_names/1`
(line 207) is the batch form for the session lists: it selects
`organization_manager_uuid` and applies the same rule. That one is display only.

### Authority

`Actor.authority/4` gives `kind: :manager` only when the link's type has
`can_manage`. `lock_grant/2` already reads the row, so it returns the row with its
type. This covers all five callers of `Actor.authorize/2`: `details/2`,
`update_contact/3`, `remove/4`, invitation `create/3` and `cancel/3`. The brief
listed three.

`SessionRef.scope_for_session/2` hard-codes `narrow: true`. Add a `/3` taking
`narrow:` for rule 7.

### Link lifecycle

`OrganizationManagers`:

- `add/4` and `host_add/4` take `type:`, `roles:`, `all_roles:`, `metadata:`.
  `add/3` and `host_add/3` stay and mean the built-in `manager` with all roles.
- `update/4` and `host_update/4` are new, and take the locks `add/3` takes.
- `insert_locked/3` stays for first managers (`managed_organizations.ex:152`), who
  always get `manager`, and `insert_locked/4` takes the options.
- `ensure_can_lose!` joins the type and counts `can_manage` only.
- A second link: `/3` stays idempotent and returns the existing row, as today.
  `/4` returns the existing row when every value matches, else
  `{:error, :already_linked}`. Changes go through `update`.
- `details/2` and `search/3` keep their arity. `PhoenixKitCRM.ManagedMirror`
  feature-detects `details/2` and `search_for_creation/2`.
- Activity: type and roles on `organization.manager_added` and
  `organization.manager_removed`, and a new `organization.manager_changed`.

As `Activity.log/1` already does, the `ScopeNotifier` broadcast of a `host_*` call
inside a host's own transaction goes out before that transaction commits. State
this in the moduledoc beside the existing warning.

### Invitations

`Invitations.create/4` takes type and roles, and `create/3` stays. Rule 7 runs at
creation.

- An email whose person already has a link at this company:
  `{:error, :already_linked}`.
- A pending invitation with other values: `{:error, :invitation_pending}`, so the
  manager cancels it first. With the same values it returns the existing one, as
  `pending/2` does now. Today a new role list would be silently dropped.
- A link made between invitation and acceptance: the existing link stands, the
  invitation is marked accepted, and the activity entry says so.
- The inviter's rights are not re-checked at acceptance, the same as today.

Mail: `organization_manager_invitation` says "invited to manage" and "become a
manager", which is false for staff. `can_manage` types keep it, and other types
get a new template (`organization_link_invitation`) naming the type. It needs a
`CoreTemplates` entry and an update to `test/phoenix_kit/email/catalog_test.exs`.

### Reads for hosts

No `Actor`; the caller decides who sees what. Public, on `OrganizationManagers`:

- `people_of/2`: active people linked to a company, optionally by type.
- `organizations_of/1`: a person's companies, with type and roles.

Phase 2 adds `AccountLinks.linked/2` (by type and direction).
`ManagedOrganizations.Sessions.list_for/1` stays internal.

### Staff level

- `ProfileSettingsTabs.visible?("managers", …)` also needs
  `Scope.can_manage_organization?/1`.
- `UserSettings.allowed_sections` drops `:identity` and `:custom_fields` while
  acting without `can_manage`.
- A first `handle_event` clause, like the `@credential_events` one, refuses
  `update_profile` and the avatar events, including the `:set_avatar` update. It
  reads the link afresh rather than trusting the scope in assigns.
- An admin editing the company from the users area is unaffected.

Preferences stay open to everyone acting (`update_start_page`, the viewer toggles,
`update_notification_prefs`), though they are stored on the company and shared.

### Admin UI

- **Types screen:** `/admin/users/relationship-types`, `users` permission, a tab
  beside Roles, shown while `enable_organization_accounts` is on. Create, edit
  names, reorder, archive, restore, delete when unused. Flags are read-only after
  creation.
- **`Components.OrganizationManagers`:** type and roles per person, an edit form,
  and type and roles on invite and add. Roles offered are those the company holds
  that the actor may hand out; roles the actor may not manage render locked and
  stay in the form as hidden inputs, as the role modals do, or the omission reads
  as a removal. "All roles" is a separate checkbox, not an empty selection.
- Server checks repeat in the context. Forms need unique ids.

## Phase 1 steps

1. V229, schemas, `ModuleOwnedTables`, `ExpectedSchema` (new objects need a real
   manifest entry, not only a restamp), `test/phoenix_kit/migrations/v229_test.exs`,
   and the prefix migration test.
2. `RelationshipTypes` and its tests.
3. Scope, `ActiveRole`, `library_operations.ex:235`, the fail-closed rule, and the
   `held_roles` docs.
4. Authority and the last-manager rule.
5. Link lifecycle, rule 7, `Revocation` and the session change for rule 6, and
   `role_has_assignments?`.
6. Invitations and mail.
7. `host_*`, reads, and the `Scope` helpers.
8. Staff level, types screen, and the managers component.
9. Gettext with the full extract and merge round-trip, then hand-fix fuzzy entries.
10. `AGENTS.md`, moduledocs, a pointer in §6 of the act-as-organization plan,
    CHANGELOG, minor version bump.
11. WoodMatrix tracks core from GitHub `main`, so it trials Phase 1 once this is
    pushed, before the publish.

`mix precommit` does not run the suite, and a run with no database excludes every
integration test but still exits 0. This touches the schema and access, so run the
full `mix test` against a scratch database and check the excluded count.

## Phase 2

After WoodMatrix confirms the need (1-2 months):

- `phoenix_kit_account_links`, `PhoenixKit.Users.AccountLink` and `AccountLinks`:
  `host_add/4`, `host_update/4`, `host_remove/4`, `linked/2`.
- `RelationshipTypes` accepts `can_act: false`.
- A links section on the organization details page, and activity entries.
- Ends need only match the type's kinds; the to end need not be managed.
- The unique index is the only concurrency control needed, because no access
  decision reads this table.

No change to `Scope`, `Actor`, `Locks`, `Revocation`, or the session query.

## Tests

Existing: the 19 test files touching grants must pass unchanged, apart from the
policy test above. That is the proof of rule 1.

From the brief:

- A person with Buyer on their link, at a company holding Buyer and Supplier, gets
  only Buyer's permissions and no switcher. With both, they get the switcher.
- A role on the link that the company no longer holds has no effect.
- One person acting for two companies gets each link's roles, in separate sessions.
- `Scope.for_user/2`, `effective_role_names/1` and the role switch agree.
- A link without `can_manage` cannot invite, cancel an invitation, remove someone,
  edit the contact address or reach the Managers tab, and does not count for the
  last-manager rule.
- A person cannot hand out a role above their own, or one the company lacks.
- Removing a link ends the session. Changing roles refreshes an open page.
- A type in use cannot be deleted, only archived. `ensure/3` keeps an admin's edits.
- A second link with different values is refused.

Added by this plan:

- `all_roles: false` with no roles gives no roles beyond `User`, and `all_roles`
  cannot be set by a narrowed manager (forged event).
- A narrowed manager cannot change their own link.
- A manager switched to one role can still hand out the rest of their link.
- `update_type/3` cannot change a flag, whatever the params.
- `ensure/3` with different flags answers `{:error, :type_conflict}`.
- Removing a role from a link signs out only that link's sessions acting as it.
- Moving the last `can_manage` link to a staff type is refused.
- `delete_role/2` on a role in use on a link answers `:role_in_use`.
- A managed organization with no link in the session holds no roles.
- WoodMatrix's case: a person with only Supplier on their link, at a company
  holding Buyer and Supplier. `user_roles/1` has Supplier and User, `active_role/1`
  is `nil`, `held_roles/1` still has Buyer, and `can_edit_role_permissions?/2`
  refuses Buyer with `:self_role`.
- Library operations keep narrowing and still work for an acting person.
- `host_add/4` needs no rank from `created_by` but refuses a role the company lacks.
- Re-inviting with other roles is refused; an invitation with a deleted role leaves
  the person with less.
- Forged `update_profile` and avatar events are refused for staff.
- The losing-rights-mid-session case for every new event.
- Concurrency alongside `organization_enter_concurrency_test.exs`: a link changed
  or removed while a person enters.

## Risks

- **Rollback widens access.** V229 `down` drops the roles, so every narrowed link
  returns to the company's full authority. Say so in the migration's moduledoc:
  roll the code back with the schema, and end acting sessions first.
- **One extra query per scope build for an acting session.** Only acting sessions
  pay it. Measure before caching anything, and keep any cache out of the access
  decision.
- **Fail-closed changes a by-uuid read.** Host code that builds
  `Scope.for_user(org)` itself gets no roles after this. Call it out in the
  CHANGELOG.

## Not in scope

As in the brief: removing `organization_uuid` or `:member` invitations; chains or
trees of links; access or reporting from company links; a history table beyond the
activity log; limits on links per account. Also a way for a staff person to leave
a company on their own: a manager removes them, for now.
