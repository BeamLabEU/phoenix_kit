# PR #1053 — review of merged push notifications (through `acdd7b1ac`)

Reviewed the full push notification stack on `main` (`7c1d81e07..acdd7b1ac`),
including the follow-up fixes in `acdd7b1ac` (`update_settings_batch`,
prefixed URLs, and `WebPush.request_options/1`).

## Confirmed from `acdd7b1ac`

- `NotificationMessages` saves `push_enabled`, `push_show_line`, and
  `push_group_seconds` via `Settings.update_settings_batch/2` with
  `module: "notifications"`: rows lock in sorted key order, history rides in
  the same `Ecto.Multi`, cache invalidation and change broadcasts run only
  after commit, and any non-`{:ok, _}` return flashes `"Failed to save settings"`.
- `WebPush.request_options/1` merges `retry: false, redirect: false` last, so
  host `:push_req_options` cannot re-enable redirects or retries.
- `PushOpenController`'s Stay link, `PushController.manifest/2` (`scope`,
  `start_url`, `id`), `PushController.install/2` (`settings`), and
  `pk_push_sw.js`'s `appHome()` all respect the configured mount prefix and
  omit locale segments where required.

---

## New findings

### BUG - HIGH — Logging out a secondary account in multi-session mode leaves its push binding active

**Files:** `lib/phoenix_kit_web/users/multi_session.ex:1020-1052`,
`lib/phoenix_kit_web/users/session.ex:158-183`

`UserAuth.log_out_user/1` drops bindings via `forget_push_on_logout/2` and
`MultiSession.remove_account/2` drops the removed account via
`forget_push(conn, token)`. However, when an active secondary account clicks
**Log out** (`DELETE /users/log-out` without `all=true`), `Session.delete/2`
calls `MultiSession.log_out_active/1` → `log_out_to_root/5`. That path deletes
the active session token (`Auth.delete_user_session_token(active)`) and
switches back to the root account **without calling `forget_push(conn, active)`**.

**Impact:** On a shared browser, a secondary account that explicitly logged
out (and is no longer in the switcher) keeps sending browser push
notifications — including notification text when `push_show_line` is enabled —
to the root user's browser.

**Fix:** Call `forget_push(conn, active)` in `log_out_to_root/5` before
`Auth.delete_user_session_token(active)` (matching `remove_account/2` at
line 952), and add an integration test.

---

### BUG - HIGH — Deactivation, sign-out-everywhere, password reset, pre-registrant takeover, and org conversion never revoke push bindings (nor does delivery check account eligibility)

**Files:**
- `lib/phoenix_kit/users/auth.ex:1678-1682` (`delete_all_user_session_tokens/1`,
  used by deactivation at line 3285 and `WebAuth.log_out_user_from_all_sessions/1`)
- `lib/phoenix_kit/users/auth.ex:1845` (`confirm_user_from_external_proof/1`)
- `lib/phoenix_kit/users/auth.ex:2120` (`password_update_multi/3` — password
  change and password reset)
- `lib/phoenix_kit/users/sessions.ex:386` (`revoke_other_user_sessions/2`) and
  `622` (`do_revoke_user_sessions/2`)
- `lib/phoenix_kit/users/managed_organizations.ex:366` (`revoke_credentials!/2`)
- `lib/phoenix_kit/notifications/push.ex:472-476` (`take_pending/1`) and
  `lib/phoenix_kit/notifications/push/workers.ex:115-126` (`SendWorker.perform/1`)

Every one of those six revocation paths explicitly calls
`PhoenixKit.Integrations.Telegram.Linking.drop_links/1` so a revoked,
deactivated, recovered, or converted account stops receiving external
notifications — yet **none of them calls `Push.forget_account/1`**.

In addition, while `Push.subscribe/3` rejects inactive accounts, managed
organizations, and service users (`allowed_account/1`), neither
`Push.take_pending/1` nor `SendWorker.perform/1` (nor `DeliveryWorker`)
re-checks `user.is_active` / `managed_by_members` / `api_only` at delivery time.

**Impact:**
- Deactivating a departing or compromised user (`is_active: false`) or
  converting an account into a managed organization leaves every bound browser
  and phone receiving pushes indefinitely.
- Password reset, password change, and "Sign out everywhere" / "Sign out other
  sessions" leave compromised browsers subscribed to pushes.
- A pre-registrant who subscribed a browser before an external-proof
  confirmation (`confirm_user_from_external_proof/1`) keeps receiving the real
  owner's pushes.

**Fix:**
1. Call `Push.forget_account(user.uuid)` alongside `Linking.drop_links/1` on
   these revocation paths. (For `Ecto.Multi` paths — `password_update_multi`,
   `confirm_user_from_external_proof`, `revoke_credentials!` — run it after
   commit or as a non-rescuing `Multi` step; `forget_account/1`'s `rescue _ -> :ok`
   would swallow errors and leave an outer PG transaction aborted if anything
   failed.)
2. Gate `Push.take_pending/1` on `allowed_account(user) == :ok` so an
   inactive, managed, or service account never emits a push even if a job
   races cleanup.

---

### BUG - MEDIUM — `GET /push/sw.js` and `GET /push/manifest.webmanifest` remain behind `:phoenix_kit_api` (`plug :accepts, ["json"]`)

**File:** `lib/phoenix_kit_web/integration.ex:496-507` (noted in `GROK_REVIEW.md`
under `Left`, still unfixed)

Both routes serve non-JSON media types (`text/javascript` and
`application/manifest+json`), yet sit behind `plug :accepts, ["json"]`. Any
client or proxy sending a strict `Accept: application/manifest+json` or
`Accept: text/javascript` without `*/*` receives `406 Not Acceptable` — and
in `PkPush`, a failed service worker registration permanently reports
`"unsupported"`. Twenty lines below (`integration.ex:525-529`), `/_pdfjs`
already documents why script/asset routes must not use `:phoenix_kit_api`.

**Fix:** Serve `GET /push/sw.js` and `GET /push/manifest.webmanifest` through
a scope without `:accepts` (e.g. `:phoenix_kit_api_v1` or no pipeline),
keeping `POST /push/resubscribe` on `:phoenix_kit_api`. Add controller tests
with strict `Accept` headers.

---

### BUG - MEDIUM — `PkPush.enable()` turns transient failures and VAPID key rotation (`InvalidStateError`) into `"unsupported"`

**File:** `priv/static/assets/phoenix_kit_admin.js:10376-10451`

1. In `enable()` (`L10448-10450`), `.catch(function () { self.report("unsupported", null); })`
   maps every failure of `pushManager.subscribe(...)` (offline network, push
   service error, `InvalidStateError`) to `"unsupported"`. The card hides the
   **Turn on in this browser** button and tells the user *"This browser can't
   show notifications from websites."* with no retry path until reload.
2. `web_push.ex:12-15` documents break-glass VAPID key rotation where existing
   browsers re-subscribe on their next visit. If a browser already holds a
   subscription made with the **old** `applicationServerKey`,
   `pushManager.subscribe({ applicationServerKey: newKey })` rejects with
   `InvalidStateError` unless the mismatched subscription is unsubscribed
   first.
3. In `mounted()` (`L10402-10404`), a transient `serviceWorker.register(...)`
   error also resolves `this.ready` with `this.registration = null` and reports
   `"unsupported"`.

**Fix:**
- Distinguish feature-detection `"unsupported"` from a transient setup/subscribe
  failure (show an error message while keeping the **Turn on** button active
  for retry).
- Before subscribing (or on `InvalidStateError`), compare
  `existing.options.applicationServerKey` against `self.key()`; only if the
  keys differ, unsubscribe the stale key-mismatched subscription and
  re-subscribe with the new key (leaving shared-browser accounts on the same
  key untouched).

---

### BUG - LOW — `Push.take_pending/1` sorts only by 1-second `inserted_at`, making `"latest"` non-deterministic in bursts

**Files:** `lib/phoenix_kit/notifications/push.ex:475`,
`lib/phoenix_kit/migrations/postgres/v235.ex:84`

`phoenix_kit_push_pending.inserted_at` is `timestamp(0) without time zone`
(1-second resolution), while `uuid` is a time-ordered `UUIDv7`. Because
`DELETE ... RETURNING *` does not guarantee row order and `take_pending/1`
sorts only by `& &1.inserted_at`, notifications queued within the same second
have tied sort keys, so `List.last(rows)` can pick an earlier notification as
`"latest"` (affecting `push_show_line` summary text and fallback link).

**Fix:** Sort by `{&1.inserted_at, &1.uuid}` (or `& &1.uuid`).

---

### BUG - LOW — `PushOpenController.switch/2` shows the generic error page if already switched to `target`

**File:** `lib/phoenix_kit_web/controllers/push_open_controller.ex:74-103`

`switchable/2` requires `not entry.active?`. If a user double-clicks **Switch
and open** or switches to the target account in another tab before submitting
the form, `switchable/2` returns `nil` and `switch/2` renders *"This
notification can't be opened here / Sign in"* even though the target account
is already active.

**Fix:** If `match?(%User{uuid: ^target}, conn.assigns[:phoenix_kit_current_user])`,
redirect straight to `destination(conn.assigns[:phoenix_kit_current_scope], opened)`
(matching `show/2`).

---

### IMPROVEMENT - LOW — `SendWorker` drops `WebPush`'s parsed `Retry-After`

**Files:** `lib/phoenix_kit/notifications/push/web_push.ex:347-360`,
`lib/phoenix_kit/notifications/push/workers.ex:149-150`

`WebPush.result/1` parses `Retry-After` on `429`/`5xx` into `{:retry, ms}`,
but `SendWorker.send_to/3` matches `{:retry, _after} -> {:error, :push_service_busy}`
and ignores it (unlike `DeliveryWorker`, which returns `{:snooze, seconds}`).
`retry_after/1` also accepts negative integers (`Integer.parse("-5")`).

**Fix:** Guard `seconds > 0` in `retry_after/1`, clamp to a sensible ceiling
(e.g. 300 s), and consider honouring it with bounded snoozing or backoff so a
rate-limiting push service isn't retried ahead of its window.

---

### Minor notes

- **iOS PWA scope under a mount prefix (`push_controller.ex:61`):** Setting
  `scope: Routes.path("/", locale: :none)` (e.g. `"/phoenix_kit/"`) cleanly
  avoids claiming the host's root origin, but note that on an iOS Home Screen
  PWA, clicking a push notification whose target link is a host route outside
  the prefix (e.g. `/admin/projects/ACME`) leaves the manifest scope and opens
  an in-app Safari bar instead of staying in standalone mode. Worth noting in
  `dev_docs/guides/2026-07-27-notifications.md`.
- **`Push.forget_browser/2` (`push.ex:312-319`):** When `ids == []`, it still
  runs a no-op `DELETE` on `phoenix_kit_push_bindings` on every logout for
  browsers that carry the `pk_push_browser` cookie. Guarding `if ids != []`
  skips the unnecessary write query.
- **`GroupWorker.perform/1` (`workers.ex:38-54`):** Does not check
  `Push.enabled?()` before taking pending rows, encrypting click handles, and
  enqueuing `SendWorker` jobs (which then immediately discard on
  `Push.enabled?()`). Checking `Push.enabled?()` in `GroupWorker` avoids
  pointless job churn when push is turned off.
- **`pk_push_sw.js:103`:** Base64 decoding of `config.key` omits `=` padding
  (unlike `phoenix_kit_admin.js:10455`). Modern browsers accept unpadded
  87-char keys under forgiving-base64, so not broken, but matching the hook's
  padding logic keeps both consistent.
- **`Push.upsert_installation/5` (`push.ex:183,187`):** Computes
  `hash(endpoint)` twice instead of reusing `hash`.
