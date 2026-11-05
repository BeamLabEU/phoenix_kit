# PR #1013 — Add a linked Telegram chat as a read-only actor of the Executor

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve with fixes; three bugs fixed, one
improvement open for a decision

A chat linked to the site bot can now read through `PhoenixKit.API.Executor` as the user, through a second
kind of reference, `{:telegram_link, user_uuid, connection_uuid, chat_id}`. That turns the link from a
notification route into a standing credential, so the PR also drops it on account recovery. A host can run a
resident updates reader and hand its batches to `Linking.handle_updates/3`.

The Executor side is sound. What this review found is in the other half: the promise that a revoked link
stays revoked. The link lives in `custom_fields`, next to code that was written when losing it cost a
notification preference. All three bugs below were reproduced with a failing test before they were fixed.

## Checked and sound

- **A chat cannot write.** `link_reads_only!/2` raises for anything but `allow: :read`, before the state is
  built, and `redeem_as/6` goes through the same `session_state/4` with `allow: :all`, so it raises too.
- **The link is re-read on every call.** `session_actor/1` matches `%User{uuid: ^user_uuid}` against a fresh
  `Linking.linked_user/2`, so an unlinked, relinked or two-account chat is refused even for a reference built
  earlier. A malformed reference and a 5-tuple both end refused, never raised.
- **Service users and managed organizations are refused twice.** `linked_user/2` filters them in the query, and
  `SessionRef.scope_for_user/2` refuses them again. `scope_for_session/2` correctly skips that second check, as a
  manager's session on a managed organization is a session.
- **The scope cannot widen.** The struct from `linked_user/2` has `active_role_uuid: nil`, so `narrow: true` gives
  the default role, as the docs say. No session or assign feeds it.
- **`chat_for_update/1` is strict.** The repeated `id` in the pattern is an equality check, so a group, a channel
  or another sender is `:error`, for messages and for button presses alike.
- **The reader rule fails closed.** Both `getUpdates` callers (`poll/1`, the personal form) ask
  `resident_reader?/1` first, and `:noproc` is the only exit that reads.
- **The password paths are all covered.** `update_user_password/4`, `admin_update_user_password/3` and
  `reset_user_password/2` all go through `password_update_multi/2`. The one other password write is
  `make_independent!/3`, see the second bug.
- **Impersonation.** `impersonated` comes from `MultiSession.impersonated?/1` in the mount of the one page that
  hosts the card, and anything but `false` refuses `connect` on the server. The card's `save_types` always read
  the row first; the page next to it did not (first bug).
- **The role-change worry is unfounded.** The comment on `log_out_user_from_all_sessions/1` names role changes
  among its callers, which would have dropped links on a routine role edit. It has no caller in `lib/`.

## Findings

### BUG - HIGH — a stale write put a dropped link back (fixed)

`drop_links/2` removes `site_chat_id` from `custom_fields`. Three writers then wrote the old value back from a
struct loaded before the drop, and `linked_user/2` read it as a live link:

- **`Notifications.Settings`, `save_cadences`:** `ChannelConfig.update/3` read the channel's map off
  `socket.assigns.user`, loaded at mount, and wrote the whole map back.
- **`DeliveryWorker.soft_disable/3`:** the same call, with the user loaded before a send that can take seconds.
- **`Auth.update_user_fields/2`:** `maybe_update_custom_fields/2` replaced the whole map from the caller's struct.
  That is the avatar save in `UserSettings`, and the admin user form, whose own profile write keeps the struct's map.

No race is needed. Someone suspects their Telegram is compromised and presses **Sign out other sessions** on the
profile page. That keeps this session, `drop_links/2` broadcasts nothing, and the page's tabs are patches of one
LiveView, so `socket.assigns.user` keeps the old map. They move to the Profile tab and set a new avatar: the chat
they cut off is reconnected, and nothing says so. **Disconnect** followed by a cadence change does the same.

A password change does not lead here from the person's own tabs: it disconnects the others and the submitting one
logs in again, so they remount fresh. But an administrator's user form, open at that moment, is not one of their
sessions, and undoes the drop for any cause.

The settings page's plain Save is not affected, by luck rather than design: `Prefs.merge/2` runs first and
returns the fresh row. The tests pin that too.

Fixed at the two roots rather than the call sites. `ChannelConfig.update/3` reads the row under
`FOR NO KEY UPDATE` and treats `user` as a name only, which covers all six of its callers and also closes the
read-then-write gap of the callers that were already careful. `maybe_update_custom_fields/2` merges onto the row
the same way, with the definition registration kept outside the lock because it writes a setting. As a side
effect it no longer loses a key another writer added in between.

### BUG - HIGH — a chat survived the conversion of an organization (fixed)

`revoke_credentials!/2` runs in both `make_managed!/3` and `make_independent!/3`, under the comment "No old
password, provider or key returns". It left the stored link alone, and `linked_user/2` only hides it while
`managed_by_members` is true. So: an independent organization links a staff member's chat, it becomes managed, and
it is later handed over as independent with new credentials. The moment the flag clears, the old chat reads the
account's data as the new owner (once the new address is confirmed, where the gate asks for that).

Fixed by `Linking.drop_links/2` in `revoke_credentials!/2`, so both directions drop it. A link already stored on a
managed account is dropped on the way out, which is what makes the "inert" in the moduledoc true for good.

### BUG - MEDIUM — a link in flight deadlocked with a password change (fixed)

The `drop_links/2` doc said the tokens go first "so a racing link transaction and a drop take the rows in the same
order". That holds for `drop_links/2` alone, not for its callers. `password_update_multi/2` and
`confirm_user_from_external_proof/1` lock the user's row and only then delete the tokens, while `link_one/4` spent
the token and then wrote the user. Opposite orders on the same two rows: Postgres kills one with
`deadlock_detected` (40P01). If it picks the password change, the person gets a 500 and the password is unchanged.
The window is narrow, a Start press landing during a password change, but the reproduction is deterministic.

Fixed by `lock_token_owner/2`: the link reads the token's owner, locks that row, then spends the token, so every
path is users then tokens. A credential change in flight is now waited for, and `consume_token/2` then finds the
token gone, which is the right answer. Outside a transaction `drop_links/2` holds nothing between its two
statements, so it cannot join a cycle. The doc now says all this.

### IMPROVEMENT - MEDIUM — seven preference writers still replace the whole map (open)

`media_canvas_viewer.ex` (3), `media_browser.ex` (2), `activity/index.ex` and `users/users.ex` read
`Auth.get_user/1` and then call `update_user_custom_fields/3` with the whole map. They read fresh, so this is the
one-statement gap, not the stale struct above: a drop committing between those two statements would be undone by
a view-mode toggle of the same user. Not fixed here: the pattern predates this PR, the window is a millisecond, and
the code has nothing else to do with it.

The fix is mechanical if wanted, `Auth.merge_user_custom_fields(fresh, %{key => value}, opts)` at each site, with
the same options. It would leave `update_user_fields/2` as the only whole-map writer.

### NITPICK — a stranger's link can blind a chat (left, by design)

A deep link pressed in a chat links that chat to whoever minted it. If the chat is already its owner's link, two
accounts now hold it, and `linked_user/2` answers nobody, so the owner's chat stops reading until one of them
disconnects. No data moves either way, so the worst case is one tap of social engineering costing a nuisance. It
follows from "a chat linked by two accounts names nobody", which is the right way to fail. Left as designed.

### NITPICK — `warn_now_and_then/2` writes `:persistent_term` (left)

Replacing a `persistent_term` value makes the VM scan every process. Bounded here to once a minute per kind, and
only while a reader is down, so it is left.

### BUG - MEDIUM — this review's own lock-order test left an orphan activity row (fixed)

`telegram_link_lock_order_test.exs` commits for real, and its cleanup deleted only the user. The `telegram.linked` entry
stayed, naming a user who no longer exists, and `phoenix_kit_activities` has no foreign key to stop that. The doctor's
destructive tests add that foreign key, so three of them then failed with `23503` on every later run against the same
database. The full suite showed those failures, and they first read like the known orphaned-FK flake. The row they named
was this test's: a `telegram.linked` entry committed before that run began. It reproduces on a clean database (0 orphans
and 4 of 4 passing, then 1 orphan and 3 of 4 failing after this test alone). The cleanup now deletes the user's activity
first.

The known flake is real as well, and stays. After a full run on a fresh database 37 orphans remain, all `organization.*`
and `api.key_*`, which by their actions are the older no-sandbox concurrency tests of managed organizations and API keys.
They fail the same three tests whenever they run first, so those tests are still seed-dependent. Left: those tests are
not part of this PR, and each needs the same cleanup.

## Tests added

- `test/integration/integrations/telegram_link_stays_dropped_test.exs`: the stale writers through the real page
  and functions, `update/3`'s contract, both conversions, and the regressions a whole-map writer could cause (keys
  written since, session fields, the avatar crop).
- `test/integration/integrations/telegram_link_lock_order_test.exs`: real sessions, no sandbox. One transaction
  holds the row as `password_update_multi/2` does, the real `handle_updates/3` runs against the real `drop_links/2`.
  Before the fix it fails with `deadlock_detected`.

## Validation

See the commit for the gate. All 7 failing reproductions pass after the fixes, with the existing Telegram suites
(140 tests). Telegram itself is stubbed: none of this ran against a real bot.
