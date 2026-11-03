# PR #992 — Add personal API keys

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; borrowed-session minting refused and CHANGELOG entry added (follow-up of 2026-11-03)

Reviewed against current `main` (the managed-organization commits since added `lock_mint_users`, refused
managed organizations in `active_user` and put `api_personal_keys` under `managed_ceiling_key?`). Codex's
one finding (an explicit `scope: nil` keeping the old scope) is fixed in `user_settings.ex`.

## Checked and sound

- **One owner check on every request path.** `verify/2` and `active_owner/1` share `checked_owner/1`
  (active owner; for a personal key, the right held on a `narrow: false` scope); `actor/3` and
  `effective_scopes/1` apply `personal_allowed?`; `Confirm.live_actor/1` goes through both. Nothing else in
  `lib/` builds a `%Actor{kind: :key}`.
- **The cap holds under concurrency.** Creation counts and inserts under the user-row lock
  (`FOR NO KEY UPDATE`) plus a per-person advisory lock; a rotation with grace takes the same advisory lock
  before the key row; a key in grace counts as live. Lock order (user row → advisory → key row) is the same
  in creation, rotation and the managed-organization conversion, so they cannot deadlock.
- **Owner rules on the locked row.** `can_manage?` on a personal key is its owner only; an Owner may only
  narrow (`:scopes_not_narrowing`) or revoke it, never rotate.
- **Borrowed sessions.** `create_personal_key/3` and `rotate/4` require an explicit `impersonated:`; the
  component refuses every changing event in a borrowed session on the server.
- **Service users and managed organizations** get no personal keys (`personal_owner/1`,
  `lock_mint_users`, the managed ceiling, `UserSettings` dropping `:api_keys`); `api_personal_keys` stays
  opt-in for Admin.
- **The token** lives only in `:new_token` as a `%DisplayToken{}` (inspect hides it), in an unnamed input
  outside any form; `secret_hash` is `redact: true`; the debug-log test checks the token and secret.
- **LiveView.** Every changing event re-reads rights (`Access.fresh_scope/2`); keys are found only through
  `list_personal_keys(fresh)`; confirm events use the uuid the server stored; forms have unique ids.
- **V226** uses `prefix_str` and `ADD COLUMN IF NOT EXISTS`; the manifest declares the column.
  Every new string is in the pot and all nine `.po` files.

## Findings

### IMPROVEMENT - HIGH — a borrowed session could still mint ordinary keys on Settings → API (fixed)
Pre-existing; the PR kept it on purpose and pinned it with a test. `create_key`, `confirm_rotate` of an
ordinary key and `create_service_user` never looked at `socket.assigns.impersonated`, and `Keys` checked
impersonation only for personal keys: an Admin without `api` impersonating a user who holds it could
create a bearer token acting as that user that outlives the impersonation.
**Decision (maintainer, 2026-11-03): refuse.** Settings → API refuses `open_create_key`, `create_key`,
`request_rotate`, `confirm_rotate`, `open_service_user_form` and `create_service_user` in a borrowed
session (one clause ahead of the others, so a forged submit is refused too) and shows a notice in the
keys card; `Keys.create_key/4` and `Keys.rotate/4` answer `{:error, :impersonated}` to
`impersonated: true` for every key (omitted, nothing is assumed — mix tasks and seeds). Editing scopes
and revoking stay allowed. The pinning test is replaced by three: no rotation (personal or ordinary,
forged submit included), no creation of a key or a service user, and the `Keys` refusal. This also
refuses a person who added a second account with its own password — the trade-off accepted.

### IMPROVEMENT - MEDIUM — personal keys and V226 shipped without a CHANGELOG entry (fixed)
Added under 3.2.0 (marked as missing when that version was cut): V226 and `mix phoenix_kit.update`,
the opt-in `api_personal_keys` permission, "My API keys", the two limits and the owner rules.

### IMPROVEMENT - MEDIUM — an Owner's revoke or narrowing of someone's key does not notify them (OPEN)
`Keys.log/4` sets no `target_uuid`, so `Notifications.maybe_create_from_activity/1` creates nothing; the
key owner's program starts getting 401/403 with no word why. Pass `target_uuid: key.user_uuid` when the
actor is someone else.

### NITPICKs (not changed)
- `Keys.actor/3` does not check that the given owner owns the key; its one caller passes the right owner.
  Matching `%Key{user_uuid: uuid}` against `%User{uuid: uuid}` would make it safe to reuse.
- `PersonalApiKeys.update/2` reads keys, statuses, the registry and settings on both renders and every
  parent update, and `create_form_changed` re-reads the scope on every debounced keystroke — the same
  pattern as Settings → API.
- The `api` permission is described as "Manage all API keys…"; only an Owner manages all, others the ones
  they created.
