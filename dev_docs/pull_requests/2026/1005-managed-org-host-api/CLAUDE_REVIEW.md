# PR #1005 — Add host_* entry points for managed organizations and their managers

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one improvement applied

`ManagedOrganizations.host_create/3`, `host_convert_to_managed/3`, `host_convert_to_independent/3` and
`OrganizationManagers.host_add/3`, `host_remove/3`, `host_update_contact/3`: the same operations as the
`Actor` functions for a host application that has no browser session, with `created_by` recorded (not
authorized) through `Actor.host!/1`.

## Checked and sound

- **Lock order.** Every `host_*` function takes the order of its `Actor` twin: the person's advisory
  lock, the organization row (`FOR NO KEY UPDATE`), the person rows, then `created_by` under
  `FOR KEY SHARE` (`host!/1` in place of the actor's row lock). Only the function form of
  `host_convert_to_managed/3` takes the new person's advisory lock after the organization, and the
  moduledoc says why that is safe (an unknown uuid; the 32-bit `hashtext` collision is the residual).
- **`created_by` is re-read**, not trusted: `host!/1` locks the row and matches an active person that
  is neither managed nor `api_only`, so a struct loaded before a deactivation is refused (tested), and
  `nil` or a non-`%User{}` is `:forbidden`.
- **The shared bodies read only what `host!/1` returns.** Every `authority.` read in both modules is
  `kind`, `person_uuid`, `actor_uuid`, `scope.user` or `granted_by_uuid`; the plain map has all five.
  `override?/2` matches `kind: :admin` only, so `host_remove/3` cannot remove the last active manager.
- **Inside a host transaction.** `Revocation.transaction/2` sees `repo.in_transaction?()` and hands the
  disconnects to the observer, which waits for the outer commit and re-checks that the tokens are gone,
  so no socket is told before the host commits. The activity broadcast that does go out early is
  documented in both moduledocs.
- **The "new person" check.** `phoenix_kit_users.inserted_at` is `timestamp with time zone` (V135), so
  the plain `now()` of 112eaffc9 compares correctly in any session zone; the earlier
  `now() AT TIME ZONE 'UTC'` would not have, for this column type. `make_managed!/3` always rewrites
  the organization row just before `write_stamp!/1`, so its `xmin` is the current transaction's and
  its `cmin` a valid lower bound. Ecto's nested transactions open no savepoint, so a creation function
  that calls core code which opens its own `Repo.transaction` still passes.
- **`enable_organization_accounts`.** The host forms check it in the transaction; the `Actor` forms
  rely on the page (`ManagedOrganizationNew`, line 88). The asymmetry is the page's gate, not a gap.

## Findings

### IMPROVEMENT - MEDIUM — the obvious first-manager function was refused (fixed)

The function form exists so a host can create the person who will take over the organization's old
email. The natural function is `fn -> Auth.admin_create_user(attrs, created_by) end`: its
`{:error, changeset}` is exactly what the moduledoc promises to hand back for the host's form. But its
success is `{:ok, %User{}}`, which `UUIDUtils.valid?/1` refused, so the call answered
`{:error, :invalid_first_manager}`, the same answer as the heuristic refusing an existing person. Every
test inserted the person with a bare `Repo.insert!` and returned the uuid, so nothing exercised a real
creation function.

`create_first_manager!/2` now also accepts `{:ok, %User{uuid: uuid}}`. The moduledoc and the
`host_convert_to_managed/3` doc name both shapes. New test, "Auth.admin_create_user/2 can be the
function as it is": the core's real creation path (`do_register_user/2` →
`Roles.ensure_first_user_is_owner/1`, a nested transaction) passes the `xmin`/`cmin`/`inserted_at`
check, `created_by_uuid` is recorded, the grant exists, and a changeset error comes back unchanged.

### NITPICK — `host!/1` sets `granted_by_uuid` to `person_uuid` (not changed)

`insert_locked/3` already falls back to `person_uuid` when the key is absent. Redundant but explicit;
left as is.

## Gate

`mix precommit` green (see the #1006 review for the two credo fixes it needed on `main`). The test
database was in crash recovery for the whole session, so the integration suite, which includes this
file, could not run. The new test compiles (`test.compile`) but has not been run against PostgreSQL;
run `mix test test/integration/users/host_managed_organizations_test.exs` before the release.
