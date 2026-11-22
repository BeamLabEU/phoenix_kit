# PR #1053 — Browser push notifications: review record

Reviewer seats: codex (GPT-6.1), zai (GLM-5.3), vibe (Mistral Medium 3.5), gemini (round 3), plus Claude's own read. Each finding was checked against the code before it was fixed; each fix has a test where one could be written.

## Round 1

| Severity | Finding | Seat | Outcome |
|---|---|---|---|
| BUG - HIGH | A known endpoint could be re-subscribed with other keys. Whoever learnt another browser's endpoint could swap its keys, and the `auth` that `resubscribe/3` asks for, and take its pushes. | codex | Fixed: a known endpoint is joined only with the keys it already has (`FOR UPDATE` + `secure_compare`); test. |
| BUG - HIGH | The payload's text was capped by graphemes. Emoji-heavy text exceeded the 3993-byte plaintext limit, and the push was silently dropped after its notices were taken. | zai | Fixed: cut by bytes, then measured as sent (JSON-escaped) and shortened until it fits; control characters stripped; tests. |
| BUG - MEDIUM | `same_site_link` didn't go through `Routes.local_path?/1`: `/\evil`, control characters, no size limit. | Claude, codex | Fixed: the guard plus a 1 KB cap; tests. |
| BUG - MEDIUM | GroupWorker deleted the waiting notices, then a failed send insert lost them. | zai | Fixed: take and queue in one transaction, rolled back on a failed insert. |
| BUG - MEDIUM | Deleting an account left its devices' endpoints and keys stored forever. | zai | Fixed: `Push.forget_account/1` from `Auth.delete_user/2`; test. |
| BUG - MEDIUM | Pushes were in English for readers without a saved language. | zai | Fixed: `RecipientLocale.for_rendering/1`, as email. |
| BUG - MEDIUM | V235 set `lock_timeout` without resetting it. | zai | Fixed; chain hash restamped. |
| BUG - MEDIUM | A 410 for a subscription rotated mid-send deleted the new one. | codex | Fixed: delete only the row still holding the endpoint and keys the push went to; test. |
| BUG - MEDIUM | The device label could overflow `varchar(160)` and crash the card. | zai | Fixed: byte cap; test. |
| BUG - MEDIUM | `push_vapid_key` wasn't a restricted setting (`SettingsSecretPerimeterTest`). | suite | Fixed. |
| BUG - LOW | The device cap could be exceeded by concurrent subscribes. | zai | Fixed: an advisory lock per account, the check inside. |
| BUG - LOW | `drop_if_unbound` checked, then deleted. | zai, codex | Fixed: lock the installation, then check. |
| BUG - LOW | The VAPID `aud` kept an uppercase host. | codex | Fixed. |
| IMPROVEMENT - MEDIUM | A click before the service worker was registered did nothing. | vibe | Fixed: it waits for the registration after the prompt. |
| IMPROVEMENT - LOW | An iPhone Safari tab could be told "blocked" instead of "add to Home Screen". | vibe | Fixed. |
| IMPROVEMENT - LOW | A non-string grouping value raised in the settings event. | vibe | Fixed. |
| IMPROVEMENT - LOW | No forged-event tests for the card. | vibe | Added. |

## Round 2 (on the fixes)

| Severity | Finding | Seat | Outcome |
|---|---|---|---|
| BUG - MEDIUM | The byte cap ran before JSON escaping: quotes and control characters still exceeded the limit. | codex, zai | Fixed: measured as sent. |
| BUG - LOW | `one!` after `ON CONFLICT DO NOTHING` could raise if a clean-up removed the row. | codex, zai | Fixed: `{:error, :try_again}`. |
| BUG - LOW | A rotation keeping the endpoint with new keys could still be deleted by a stale 410. | codex | Fixed: the delete also matches the keys. |
| BUG - LOW | `forget_account` could race a subscribe of the same account. | zai | Fixed: the same per-account lock. |
| BUG - LOW | `subscribe` could return a changeset. | zai | Fixed. |
| BUG - LOW | `cut_bytes` returned more than asked for a tiny limit. | codex | Fixed; test. |

## Round 3 (Gemini, on `acdd7b1ac`)

Each finding checked against the code; every fix has a test that fails without it.

| Severity | Finding | Outcome |
|---|---|---|
| BUG - HIGH | Logging out an added account (`log_out_to_root/5`) deleted its session but kept its binding, so its pushes kept arriving in the browser. | Fixed: `forget_push(conn, active)`, as `remove_account/2`; test. |
| BUG - HIGH | The six credential-ending paths dropped the Telegram link but not the push devices, and delivery didn't check the account again. | Fixed: `Push.forget_account/1` on deactivation, after the commit of every password change, reset and external-proof confirmation (`after_credentials_revoked/3`), on sign-out everywhere and sign-out of the others. `Push.forget_account!/1` (raises) runs inside an organization's conversion transaction. `take_pending/1` builds nothing for an account `subscribe/3` would refuse. Tests for each path, and one showing a failed password change keeps the devices. |
| BUG - MEDIUM | `GET /push/sw.js` and the manifest sat behind `plug :accepts, ["json"]`: a strict `Accept` got a 406. | Fixed: their own scope without `accepts`; the resubscribe POST stays; test. |
| BUG - MEDIUM | `PkPush` reported any failed attempt as "unsupported", which hid Turn on until a reload. A subscription held under another VAPID key made `subscribe()` throw `InvalidStateError`. | Fixed: a failed registration at mount leaves the button, and the click tries the registration again. A failed turn-on reports `failed` ("couldn't be turned on… Try again", 9 locales) and keeps the button. A subscription with another key is unsubscribed first. Card test. |
| BUG - LOW | `take_pending/1` sorted by a 1-second `inserted_at`, so "latest" was arbitrary within a burst. | Fixed: `{inserted_at, uuid}`; test. |
| BUG - LOW | Switch and open, clicked twice (or after switching in another tab), showed the generic page. | Fixed: already that account goes straight to the notification; test. |
| IMPROVEMENT - LOW | `retry_after/1` accepted a negative `Retry-After`. | Fixed: positive only. |
| NITPICK | GroupWorker queued sends with push off; `forget_browser/2` ran an empty `DELETE`; `upsert_installation/5` hashed twice. | Fixed. |

### Left, recorded

- **Sign-out of the other sessions and a password change end push in this browser too.** A binding names no session, so the browser that acted can't be told apart. Telegram does the same. Turn on again to restore it.
- **The old-key subscription a key change unsubscribes** stays bound for the browser's other accounts until its next 410. They turn push on again.
- **`SendWorker` still ignores the parsed `Retry-After`** and keeps Oban's backoff. A snooze would raise `max_attempts` with no bound against a service that always answers 429.
- iOS Home Screen scope under a mount prefix and the unpadded base64 in `pk_push_sw.js`: as Gemini says, not broken.

## Left, recorded (accepted)

- A push already on its way when the account logs out in that browser still arrives (one push, at most).
- With `push_show_line` on, a reader who loses access inside the grouping window still gets the saved line. Off by default.
- A host whose Oban uses another repo falls outside GroupWorker's transaction.
- **DNS:** checked before each send, so a host-configured push host whose DNS answer changes between the check and the connection isn't covered. The built-in hosts are the big push services.
- Whoever subscribes an endpoint first fixes its keys: someone who learnt an endpoint could make its owner's later subscribe fail. That's denial, not takeover, and it needs a capability the browser doesn't hand out.
- A borrowed session for the account a notification is for is redirected to the notification's path. It can already open that account's pages.
- Firefox's `pushsubscriptionchange` without `oldSubscription` can't prove itself. The device is removed at the next 410, and the card offers Turn on again.
