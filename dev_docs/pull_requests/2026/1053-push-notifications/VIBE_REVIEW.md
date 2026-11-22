# PR #1053 — recheck of the codex review (merged `f190f80c9` against `7c1d81e07`)

Every claim in `CODEX_REVIEW.md` was re-verified against the merged code and by
re-running the suites. All seven fixes are present and behave as claimed.

| Claim | Recheck result |
| --- | --- |
| Removing one account's device deletes only its binding | Confirmed: `Push.remove_device/2` deletes only the caller's binding; `drop_if_unbound/1` locks the installation `FOR UPDATE` and deletes only when no binding remains. Test asserts the other account's binding survives and no unsubscribe event fires. |
| VAPID init under an advisory lock; rotation through the restricted changeset | Confirmed: `initialize_vapid_key/0` takes `pg_advisory_xact_lock` inside `repo.transact` and re-reads the winner; `create_vapid_key/1` stores through `Setting.changeset` (restricted → encrypted) and refuses a non-encrypted result. `integrations_key_rotation_test.exs` passes on a fresh DB. |
| Controller URLs use the mount prefix, omit the locale; the hook waits for its own worker | Confirmed: the push routes sit in the non-localized scopes of `integration.ex`; sw/manifest/install/resubscribe/click URLs go through `Routes.path/url(..., locale: :none)`; the `PkPush` hook resolves `registration.active` or waits on the worker's `statechange`, and `enable/0` awaits `this.ready` after the in-click permission prompt. |
| Rotation conflicts keep both subscriptions; a late 410 checks keys | Confirmed: `resubscribe/3` is one conditional update (optimistic locks on `auth`/`endpoint_hash`/`p256dh` + `unique_constraint(:endpoint_hash)`) answering `:conflict`; `SendWorker.same_subscription/1` matches uuid + endpoint hash + both keys before update/delete. Both tests present and green. |
| Notice + grouping job commit together; delivery rechecks the site switch | Confirmed at the semantics level: Ecto 3.14's `Repo.transact/2` rolls back on a returned `{:error, _}` (read in `deps/ecto`), so `Push.queue/1` cannot strand a pending row; `GroupWorker.perform` takes notices and enqueues sends in one transaction, and Oban 2.24 joins the surrounding transaction when its repo is the one in transaction (`Oban.Repo.with_dynamic_repo`/`in_transaction?`, read in `deps/oban`); `SendWorker.perform` re-reads `Push.enabled?()`. |
| The card edits per-type choices; initial preferences commit with the binding | Confirmed: `save_push_types` is gated on `allowed?`/`enabled?`/`any_device?` and takes only `Types.all_pref_keys()`; `start_with_email_types/1` runs inside the subscribe transaction via `Map.put_new`. |
| The settings form's three writes share a transaction; VAPID satisfies the empty-default invariant | Confirmed: `push_settings` wraps all three writes in `repo.transact` and reports failure; `push_vapid_key` is in `Setting`'s `@optional_settings` and in the restricted defaults. `settings_secret_perimeter_test.exs` green. |

## Verification re-run (fresh database `phoenix_kit_review_1053`, PostgreSQL 16)

- `mix test` full suite: 99 doctests, 16,295 tests, 0 failures, 34 skipped
  (1 excluded) — identical to the numbers in `CODEX_REVIEW.md`.
- Push slices: `push_test.exs`, `push_web_test.exs`, `web_push_test.exs`,
  `v235_test.exs` (38 tests), `test/integration/notifications/` (109),
  settings unit + secret-perimeter (121), key rotation, prefix migration,
  module-owned tables, schema prefix — all green.
- JS: `node --test test/js/*.test.cjs` — 938 pass, including the `PkPush`
  admin-split inventory.
- `mix compile --warnings-as-errors`, `mix format --check-formatted` on all
  changed files, `mix credo --strict` on the 24 changed lib files — clean.
- One failure seen on the shared `phoenix_kit_test` DB
  (`managed_organization_creation_test.exs`, the empty-query picker list) is a
  pre-existing isolation artifact: the file passes on a fresh database, and
  this PR touches nothing in that path.

## New findings (nitpicks; nothing blocking)

- `push_open_controller.ex:163` — the switch page's "Stay" link hardcodes
  `href="/"` instead of `Routes.path("/")`; under a mount prefix it leaves the
  app. The generic page's Home link correctly uses `Routes.path("/")`.
- `push_controller.ex` manifest — `scope: "/"` is hardcoded (under a mount
  prefix the standalone scope should be the kit's prefix root), and `id`
  points at `/push/app`, which has no route.
- `WebPush.send/3` merges `config :phoenix_kit, :push_req_options` over the
  fixed `redirect: false, retry: false`, so a host override could re-enable
  redirect-following on a send to a capability URL. Low risk (host-owned
  config, payload is encrypted, the VAPID private key never leaves), but the
  security-fixed options arguably should not be overridable.

Left as recorded by the earlier rounds: the accepted residuals in
`CLAUDE_REVIEW.md` still stand (mid-send logout push, `push_show_line` inside
the grouping window, a foreign-repo Oban, the DNS TOCTOU, endpoint squatting
as denial-not-takeover, Firefox `pushsubscriptionchange` without
`oldSubscription`).
