# PR #1053 — recheck after the codex and vibe reviews (merged `f190f80c9`)

The seven fixes in `CODEX_REVIEW.md` are in the merged code and behave as
described. `VIBE_REVIEW.md` rechecked them and named three nitpicks. This
pass confirmed those, and found one bug both reviews missed.

## Confirmed from the earlier reviews

Removing a device deletes only that account's binding, and the installation
is dropped only while it is locked and unbound. The VAPID key is created
under `pg_advisory_xact_lock` inside `repo.transact`, stored through
`Setting.changeset`, and refused unless `Encryption.encrypted?/1` says the
value is ciphertext. Push routes sit in the non-localized scopes; the
service worker, manifest, install, resubscribe and click URLs go through
`Routes` with `locale: :none`; the `PkPush` hook waits on its own worker.
`resubscribe/3` is one conditional update, and a late 410 matches the
endpoint hash and both keys. `Push.queue/1` uses `repo.transact`, so a
failed schedule rolls the pending notice back; `SendWorker` re-reads
`Push.enabled?/0`. The card's `save_push_types` is gated and key-restricted,
and email types are seeded with `Map.put_new` inside the subscribe
transaction. `push_vapid_key` is an optional restricted setting.

The accepted residuals in `CLAUDE_REVIEW.md` still stand.

## BUG - MEDIUM — the push settings form announced each write before the commit

`push_settings` wrapped three `update_setting_with_module/4` calls in
`repo.transact`. Each of those calls has its own `repo.transaction`
(`Queries.with_history/3`). Nested, that is a savepoint. On success the
savepoint is released and `announce_committed/1` runs at once: it drops the
settings cache and broadcasts the new value, while the outer transaction is
still open.

Two consequences:

- A reader between the release and the outer commit sees the old row
  (read committed) and can store it. The settings cache keeps that value
  for its five-minute TTL, so "Saved" can leave `push_enabled` unchanged
  for everyone else.
- If a later key fails, the outer transaction rolls the rows back, but
  subscribers were already told the earlier keys changed. The history
  moduledoc says nobody hears of a change that rolled back.

Fixed by saving the three keys through `Settings.update_settings_batch/2`,
which announces only after the transaction commits. `module: "notifications"`
on that call stamps the rows the same way the three writes did. The batch's
failure shape is `{:error, operation, value, changes}`; the form treats
anything but `{:ok, _}` as "Failed to save settings", which the old
`{:error, _}` clause would not have matched.

## BUG - MEDIUM — hardcoded root under a mount prefix

The test config mounts the kit at `/phoenix_kit`.

- The switch page's Stay link was `href="/"`, so it left the kit. The
  generic page already used `Routes.path("/")`. Stay now uses the same
  path (`@home`).
- The web manifest's `scope` was `"/"`, so an installed app claimed the
  whole origin. Scope is now `Routes.path("/", locale: :none)`. `start_url`
  and the install page's settings link also pass `locale: :none`; they had
  been left on the process locale. The manifest `id` is still
  `Routes.path("/push/app", locale: :none)`. A manifest id is an identity
  URL. It sits inside the new scope, and nothing fetches it.
- The service worker's fallback for a missing or foreign click URL was the
  origin root. It now opens the directory above `/push/` on its own script
  URL, which is the kit's root when the worker is served at
  `<prefix>/push/sw.js`.

## BUG - LOW — `push_req_options` could undo `redirect: false`

`WebPush.send/3` merged `config :phoenix_kit, :push_req_options` after
`redirect: false, retry: false`, so a host list could turn both back on.
A redirect would POST the body to an address `endpoint_ok?/1` never
checked. Host options still override timeouts and the adapter (the test
plug). `redirect` and `retry` are applied last. The payload is encrypted
and the VAPID private key is not in the request; the risk was the
redirect target, not the body.

## Left

A browser that fetches the service worker or the manifest with a strict
`Accept` other than `*/*` or `application/json` can get 406: both routes
use the `:phoenix_kit_api` pipeline (`plug :accepts, ["json"]`). Chrome's
script and manifest fetches send `*/*` or include `application/json`, and
the suite's conn sends no Accept header, so this does not show up in
tests. Not changed here.
