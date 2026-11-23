# PR #1058 — Cross-domain handoff (sign-in + module state between a host's domains)

**Author:** timujinne · **State:** merged 2026-11-23 (`0b428a8a8`, branch rebased onto main
first, see "Merge mechanics" below) · **Reviewed:** 2026-11-23

Reviewed at the PR head before the rebase (`3113d31b2`) and again after it. The feature had
already been through four review rounds on the branch; this pass re-checked the
load-bearing security invariants against the merged code and ran the suites.

**Verdict:** merged. No new code findings. One process finding (below) caused a broken
catalog on the first merge attempt; fixed on main in `a78de00a2`.

## Checked, fine

- **Token discipline.** `mint/1` stores only the SHA-256 of the 32-byte token; `redeem/4`
  consumes the row in ONE `UPDATE … WHERE token_hash/host/nonce-hash/UA/unused/unexpired`
  (`update_all` returning `{1, [row]}`), so a wrong host, browser or User-Agent does not
  burn the token and two racers cannot both win. Raw token never in a log line:
  `RequestLog`'s primary filter rewrites `/handoff/<token>` (repeated-slash spellings
  included, step names `start|prepare|mint` left readable) in the request line and
  `RequestTimer`; routes are `log: false` and `metadata: %{sitemap: false}`.
- **Redirect targets are never request values.** `valid_to/1` runs every `to` through
  `Routes.local_path?/1` (the one redirect guard: rejects `//`, `/\`, control chars); hosts
  come only from `allowed_host/2` over the resolver's `allowed_hosts/0`, matched by host
  name; scheme from `Handoff.scheme/0` (site setting), never from the request.
- **Browser binding.** Source cookie is a signed `__Host-` cookie (60 s); its SHA-256
  travels `start → prepare → mint` as `s` and is spent server-side by the partial unique
  index on `source_proof_hash` (plus per-proof and per-IP buckets in front); the target
  nonce lives only in the target's cookie, only its hash is stored. `prepare`/`mint`/
  `redeem` require `Sec-Fetch-Dest: document` when sent; `start` additionally requires
  `Sec-Fetch-Site` in `same-origin|none` (absent header allowed, documented); prefetch/
  preview/`HEAD` answer 204 with no side effects. Refused requests never delete the
  visitor's cookies.
- **Session continuation.** `source_session_uuid` (no FK, by design) is re-checked at
  redeem (`Auth.get_live_session/2`) and again by the controller after the module hooks,
  right before `log_in_user/4` with `:inherit_session`, so the new session keeps the source
  session's `inserted_at` and active role; `build_session_token/2` guards a foreign user or
  a future `inserted_at`. `Sessions.Revocation` deletes the account's unused rows in the
  same transaction, with a savepoint + `undefined_table` tolerance for hosts that deploy
  code before V236.
- **Module hooks.** Only enabled modules, dispatched in supervised tasks under one shared
  deadline (2 s snapshot / 5 s apply), `$callers` and locale carried, nothing else. The
  hook context drops `auth_session_keys/0` + `auth_cookie_names/1`; without a readable
  session-cookie name modules get NO cookies and may set NONE. Snapshot output must be
  JSON-safe and ≤ 64 KB; apply output is validated (cookie name/value/path regexes,
  whitelisted option keys, `SameSite=None` requires `Secure`, defaults `secure/http_only/
  SameSite=Lax`) and capped (5 notices × 300 B, 600 B total; 10 cookies). Module output
  cannot break the redirect (`put_module_effects/4` rescues).
- **Migration V236.** Prefix-safe per the guide: `validate_prefix!/1`, qualified tables,
  bare index names on CREATE, `uuid_v7_call/1`, `SET/RESET lock_timeout`, version
  `COMMENT ON TABLE`, re-runnable (`IF NOT EXISTS` + `ADD COLUMN IF NOT EXISTS` for drafts
  of this branch), table registered in `ModuleOwnedTables`' core list, expected-schema and
  squash-reference files regenerated, cron entry added in all three places of
  `oban_config.ex` (tests `oban_config_test`/`oban_cron_insertion_test`/`api_flow_cron_test`
  cover the agreement).
- **Routes.** `/handoff/*` is literal-rooted ahead of every `/:locale` scope in
  `Integration`, in the `:browser` pipeline with no login plug, token route last.

## Merge mechanics (process finding, fixed)

Merging #1059 first made GitHub report #1058 CONFLICTING — both PRs touch the same gettext
regions. The conflict was purely mechanical (reference lines + one added msgid), so the
branch was rebased onto main resolving `priv/gettext/*` to main's side, then the catalogs
were regenerated (`mix gettext.extract`, `mix gettext.merge priv/gettext`) and the handoff
msgid's translations re-applied from the branch; pushed to the PR head
(`maintainerCanModify`) and merged with `gh pr merge --merge`.

**What went wrong:** the catalog regeneration ran in the working tree but was pushed
*before* being committed, so the merged main lost `msgid "You are signed in as %{email}."`.
Caught by `grep` on `origin/main`; fixed on main in `a78de00a2` (re-extract + re-merge +
re-apply translations; diff vs `origin/main` is purely additive — the one msgid, no removed
msgstr). `mix gettext.extract --check-up-to-date` exits 0 and
`test/phoenix_kit_web/handoff_translations_test.exs` passes with the fix.

## Verification

- `mix precommit` on merged main: exit 0 (compile warnings-as-errors, format, credo
  --strict, dialyzer, deps check, test compile, JS tests).
- Handoff-related suites on the rebased branch and on main: `handoff_test`,
  `handoff_controller_test` (integration, DB available), `redeem_concurrency_test`,
  `prune_worker_test`, `v236_test`, `request_log_test`, `rate_limiter_test`,
  `revocation_handoff_table_test`, `user_token_inherit_test`, `handoff_translations_test` —
  300+ tests, 0 failures. Full `mix test` was running at review time; see the sweep report.

## Known limits (accepted, from the PR body)

- Session list shows the handed-over session with the original sign-in date.
- A DB that ran an earlier draft of V236 needs the two added columns (the migration is
  re-runnable for exactly that).
- Header-less clients pass the `start` check; the browser-bound token still applies.
- Hooks run in a task: no process dictionary (no per-request dynamic repo/prefix, no
  request Logger metadata).
