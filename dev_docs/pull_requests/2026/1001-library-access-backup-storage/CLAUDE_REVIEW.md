# PR #1001 — Add editable library access, safe backup storage and live progress

**Author:** ddon · **Reviewer:** Claude · **Verdict:** approve with fixes; follow-ups listed

Reviewed against current `main` (656923f7b's `Preferences` fixes for Codex's HIGH are in place, and the
later membership-history commits were read where they touch this code).

## Checked and sound

- **Connection lock coverage.** Every credential write and every bucket create/update takes the
  settings-row lock; probes run outside it and the fingerprint (identity, attrs, dependent buckets with
  `updated_at`) is re-checked under it. `storage_concurrency_test.exs` exercises attach vs. remove,
  disconnect and rotation.
- **`Libraries.add_user_storage/4`** re-checks owner, permission and trash under a row lock, detects
  duplicates by physical destination (site rows included), re-compares connection snapshots under sorted
  locks; `Profiles.add_user_backups` enforces the bucket cap and copy limit and queues the reconciler.
- **Endpoint and owner scoping.** Probes of an owned bucket use the `:personal` endpoint policy;
  `validate_bucket_connection` checks `{:user, owner}` vs `:system`; no user bucket enters `list_buckets`,
  `list_enabled_buckets` or `list_profiles`.
- **`Preferences.update`** locks the row, intersects a fresh scope with the session's rights, rotates
  `access_revision` on every access change, and refuses members, `trashed` and `system` kinds.
- **FileController audience** covers `show`, `info`, `unedited` and tiles; login-required files are never
  redirected to a bucket and are sent private/no-store.
- **Live progress** reads only the viewer's owned libraries; subscriptions are made when connected.

## Findings

### BUG - MEDIUM — "Signed-in users" admitted accounts the app itself does not (fixed)
`authenticated_reader?/1` (and so `audience_allows?/2`, `can_read_library?/2` and the `/file` and `/tiles`
gate) accepted any active account. A session is minted for an unconfirmed account too, and `/file` runs no
`require_*` plug, so with open registration "Signed-in users — account required" meant "anyone who types
an email" — against the AGENTS.md rule that every new gate honours `require_email_confirmation`.
**Fix:** the reader must also have a confirmed email while `require_email_confirmation` is on, and satisfy
`Referrals.access_satisfied?/1` — the same two conditions as the web layer's account gate, applied in the
domain the way `Keys.active_user/1` does. Test: `library_audience_test.exs` "an account whose email is not
confirmed is not a signed-in reader" (DB-free); the existing scopes now carry `confirmed_at`.

### BUG - MEDIUM — key rotation refused for good when one sampled object was missing (fixed)
`check_existing_object/1` HEADed the single oldest active `FileLocation` and required `true`; a 404 (`false`)
— an object removed by a lifecycle rule or out of band — failed every rotation of that connection, with the
same row sampled each time ("New credentials could not access bucket…"), possibly while replacing a leaked
key. **Fix:** up to five active locations are sampled; the first object found settles it, a refusal (403
raises in the provider → `Probe.run/1` error) still fails, and only when every sample is missing is the key
taken as able to see the bucket. (A 404 proves the key authenticated with list rights, not read rights;
accepting it only after five misses keeps that hole narrow.) No new test: rotation tests need the database,
which was down for this review.

### IMPROVEMENT - MEDIUM — a bucket whose connection keys turned unreadable could not be disabled (fixed)
`do_update_bucket/3` re-validated the connection on every update, through `usable_storage_connection?/2`,
which needs both keys to decrypt. Mid `secret_key_base` rotation the admin could not even switch the broken
bucket off. **Fix:** an update validates the connection only when `integration_uuid` changes or the bucket
is being enabled (`validate_changed_bucket_connection/1`); creation still always validates. Ownership
cannot drift on update (`owner_uuid` is never cast from params).

### IMPROVEMENT - MEDIUM — the profile Media tab reloads everything every 3 s, for every user (OPEN)
`refresh_storage_timer/2` re-arms unconditionally while the tab is open, and each tick runs the whole
`LibrarySettings.load/1` (~12 queries: libraries, trash, content stats, decrypted connections, profiles,
`Reconciler.progress_by_library/1` with a `file_locations × file_instances × files` aggregate). The PR also
removed the `Libraries.may_use_libraries?/1` gate from `profile_settings.html.heex` (the comment in
`profile_settings_tabs.ex` still cites it), so it runs for users without libraries too; 6460fa988 makes
each tick reload `LibraryActivity` as well. Not changed: the "Updates automatically" activity feed depends
on the tick, and reshaping it (arm only while something is pending, refresh only `:storage_progress`,
prefer the reconciler's `{:job_run, …}` broadcast) needs a browser check this review could not do.

### IMPROVEMENT - MEDIUM — uncached library reads on the `/file` and `/tiles` hot path (OPEN)
`login_required?/1` (`Libraries.get_library/1`, uncached) runs three times per `/file` request for every
file on the site, Media included; tiles add ~3 queries each; `access_revision_suffix/1` adds a query per
private URL minted or verified. Load the library once per request and pass it down; batch or cache the
revision (invalidated by `Preferences.update`).

### IMPROVEMENT - MEDIUM — the PR's strings are not in the catalogs (OPEN, part of a larger gap)
Dozens of the PR's msgids ("Library settings saved", "Signed-in users — account required", "Storage and
backups", …) are in no catalog. Measured on this tree, `mix gettext.extract` adds **282 msgids** to
`default.pot` (45 obsolete) across this and other recent work. Needs the full extract/merge round trip and
translation into the nine locales (0 fuzzy) as its own pass before the next release.

### NITPICKs (not changed)
- `previous_slugs` is written on every slug change and read nowhere; it grows without bound.
- `Preferences.update` writes neither `storage.library.renamed` nor `slug_changed`, and its Activity has no
  `target_uuid`, so an owner is not told when an admin publishes or restricts their library.
- The "Storage and backups" dialog shows the site's bucket names to users in backup mode.
- `create_on_own_storage` has no `@creating` double-submit guard (unlike `add_storage`).
- Three copies of `fresh_scope` (`Preferences`, `LibraryOperations`, `API.Access`).
- **PLAUSIBLE:** a leftover user bucket row with locations (left by `finish_purge`) keeps blocking its
  connection's removal, and the user has no UI to delete it.
