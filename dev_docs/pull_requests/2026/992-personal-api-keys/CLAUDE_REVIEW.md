# PR #992 — Add personal API keys

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve, no code changes; two items for the maintainer

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

### IMPROVEMENT - HIGH — a borrowed session can still mint ordinary keys on Settings → API (DECISION NEEDED)
Pre-existing; the PR kept it on purpose and pins it with a test ("in a borrowed session it is refused; an
ordinary key rotates as before"). `create_key`, `confirm_rotate` of an ordinary key and
`create_service_user` never look at `socket.assigns.impersonated`, and `Keys.create_key/3` / `rotate/4`
check impersonation only for personal keys. An Admin without `api` who impersonates a user holding `api`
(through a custom role) can create a key with owner "self" — a bearer token acting as that user that
outlives the impersonation, logged with the user as actor. The guide's sentence "Nobody mints a token in
the name of the person they are impersonating" reads as general.
Not changed here because it is a policy call: `MultiSession.impersonated?/1` is also true for an account
added to the session with its own password, so refusing would lock such users out of managing keys in
that account. Options: refuse key creation/rotation/service users on Settings → API when impersonated
(and flip that test), or keep it and narrow the guide's sentence to personal keys.

### IMPROVEMENT - MEDIUM — personal keys and V226 shipped without a CHANGELOG entry (for the next release)
`f58f986fb` set `@version "3.2.0"` with this merge in it, but the 3.2.0 entry lists only storage and
integration changes; the file never mentions personal keys, V226 (`api_keys.personal`), the
`api_personal_keys` permission, `/profile/settings/api-keys` or the `api_personal_key_max_*` settings.
Hosts are not told to run `mix phoenix_kit.update` (without the column every `Key` query fails). Not
edited here (CHANGELOG belongs to the release commit): add a late note when the next release is cut.

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
