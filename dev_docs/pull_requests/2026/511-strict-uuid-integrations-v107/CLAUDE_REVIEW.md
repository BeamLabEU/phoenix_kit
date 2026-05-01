---
pr: 511
title: "Tighten Integrations to strict-UUID + V107 endpoint UNIQUE index + V106 follow-up + provider registry expansion"
author: mdon (Max Don)
base: dev
merged_at: 2026-05-01T18:58:23Z
url: https://github.com/BeamLabEU/phoenix_kit/pull/511
---

# CLAUDE_REVIEW.md

## Summary

Nine commits on dev, +3813 / −960 across 36 files. The PR is a coherent step in the same direction as PR #510 — pulling more of the integrations system onto a stable uuid axis — plus a tail of polish, new providers, and the V106 follow-up that closes out the previous review.

What's actually in here:

1. **Strict-UUID Integrations API.** Every mutating / OAuth / HTTP / validation function on `PhoenixKit.Integrations` now takes the storage row's uuid. Storage-key construction (`integration:{provider}:{name}`) is confined to `add_connection/3` (row birth) and module-side `migrate_legacy/0` migrators. Read shims (`get_integration/1`, `get_credentials/1`, `connected?/1`) stay dual-input for legacy data walks.
2. **V107.** New nullable `phoenix_kit_ai_endpoints.integration_uuid` column with a backfill from the existing `provider` column, plus a `UNIQUE (lower(name))` index that has been an unenforced changeset claim since V34.
3. **`migrate_legacy/0` module callback + orchestrator.** Each module owns its own legacy-data migrator; `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` walks every registered module. Robust against per-module crashes — boot can't be taken down by a flaky module.
4. **Picker policy: never auto-pick.** `IntegrationPicker` no longer auto-selects when only one connection exists; single-mode now emits `select`/`deselect` so consumers can clear pinning.
5. **Provider registry expansion.** Mistral, DeepSeek, Microsoft 365 (OAuth2). Each definition has gettext'd labels, setup_fields, and instructions panels.
6. **PR #510 follow-up.** V106 `down/1` gains a cross-mode duplicate pre-check that raises an actionable named error before dropping the partial indexes; moduledoc rewritten; 12-test V106 spec.

`mix test`: 1040 + 11 doctests pass per the PR description; one pre-existing intermittent flake unrelated to this PR. Migration suite at 18/18.

Overall verdict: high quality, well-motivated, and the test coverage on the new primitives is strong. The strict-uuid pivot is a significant invariant tightening with low risk because the read shims preserve every previous lookup shape. Findings below are mostly documentation drift and one hardcoded Microsoft tenant that will surface for single-tenant operators.

---

## Findings

### IMPROVEMENT — MEDIUM

**1. `connected_at` semantics changed mid-PR but AGENTS.md / CLAUDE.md still document the old behavior.**

The first commit (`3f3afabc`) introduced one-shot `connected_at` ("first successful connection wins; subsequent successes update only `last_validated_at`"). The fifth commit (`524445e9`) reversed that decision: `connected_at` now tracks the last successful connection, matching the OAuth `exchange_code/4` path. The reasoning in the commit body is sound — a stuck "Connected 35 minutes ago" after a fresh `:ok` reads as "didn't update."

What was missed: the project-level docs were not updated to reflect the final state.

- `AGENTS.md:207` (and the identical `CLAUDE.md:207`) still says: *"Successful validation flips `status` to `"connected"` and stamps `connected_at` (one-shot — first successful connection wins; subsequent successes update only `last_validated_at`)."*
- `lib/phoenix_kit/integrations/integrations.ex:976-989` (`record_validation/2`) bumps `connected_at` on every `:ok` result, with a clear comment explaining why.

These two places now describe opposite behaviors. AGENTS.md is the file Claude / agents read first; future agents will reason from the stale text. Worth a one-line fix to drop the "(one-shot — …)" parenthetical.

**File:** `AGENTS.md:207`, `CLAUDE.md:207`
**Suggested fix:** *"Successful validation flips `status` to `"connected"` and stamps `connected_at` (rewritten on every successful re-test — same as the OAuth exchange path)."*

---

**2. Microsoft 365 provider has no tenant override; single-tenant apps will fail at OAuth time.**

`providers.ex:389-390` hardcodes `common` into both `auth_url` and `token_url`:

```elixir
auth_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
```

The instructions panel at `providers.ex:444-447` calls this out:

> "If you picked a single-tenant audience, replace `common` in the OAuth URLs with your tenant ID — the provider definition uses `common` by default which only works for multi-tenant + personal apps."

…but there's no UI affordance to do so. `setup_fields` exposes `client_id` and `client_secret` only. A single-tenant operator who follows the Azure registration path picking *Accounts in this organizational directory only* will:

1. Save `client_id` / `client_secret` successfully.
2. Click Connect Account → redirected to `login.microsoftonline.com/common/...` → Microsoft surfaces *AADSTS50194: This app is not configured as a multi-tenant app* (or similar 50128 / 700016 errors depending on the audience picked).

To fix, either:
- Add a `tenant_id` setup field (default `common`, accept GUID or special values like `consumers` / `organizations`) and templated `auth_url` / `token_url` strings (e.g. `"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/authorize"`) resolved at `authorization_url/4` and `exchange_code/4` time. The OAuth module already reads `oauth_config[:auth_url]` / `oauth_config["auth_url"]` (`oauth.ex:55`), so this is a per-row interpolation, not a behavior change.
- Or, if scope-mismatched here, add to `dev_docs/pull_requests/2026/511-.../FOLLOW_UP.md` so it doesn't get lost.

The same pattern (single-tenant) is the most common deployment for any business-app integration with Microsoft 365 — internal tools at a single org. It's not a niche case.

**File:** `lib/phoenix_kit/integrations/providers.ex:389-403`

---

### IMPROVEMENT — LOW

**3. V107 moduledoc says `inserted_at ASC` tiebreaker; the SQL uses `uuid ASC`.**

`v107.ex:24-26`:

> "For `provider = "openrouter"` (bare) → pick the most-recently-validated `integration:openrouter:*` row, breaking ties on `inserted_at ASC` (oldest first — stable on identical timestamps)."

The actual SQL at `v107.ex:88` uses `uuid ASC`, with a comment explaining UUIDv7's time-ordering. The inline comment is correct; the moduledoc above contradicts it. Practical effect is the same (UUIDv7 ordering ≈ insertion order), but a future maintainer who reads the moduledoc and greps for the `inserted_at` field on `phoenix_kit_settings` will be confused.

**File:** `lib/phoenix_kit/migrations/postgres/v107.ex:25`
**Suggested fix:** Replace `inserted_at ASC` with `uuid ASC` in the moduledoc (or expand: *"breaking ties on `uuid ASC` (UUIDv7 is time-ordered, so this approximates insertion order)"*).

---

**4. `PhoenixKit.Module` moduledoc references nonexistent `PhoenixKit.Modules.run_all_legacy_migrations/0`.**

`lib/phoenix_kit/module.ex:209`:

> "Host apps call `PhoenixKit.Modules.run_all_legacy_migrations/0` from `Application.start/2`; that walks every enabled module and invokes this callback."

The actual entry point is `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`, which is what every other reference in the codebase uses (`integrations.ex:92`, `:1281`, `:1296`; `module_registry.ex:618`). Just a typo — `Modules` vs `ModuleRegistry`.

**File:** `lib/phoenix_kit/module.ex:209`

---

### NITPICK

**5. `list_connections/1` still privileges `"default"` for sort order.**

`integrations.ex:586`:

```elixir
Enum.sort_by(connections, fn %{name: name} -> if name == "default", do: "0", else: name end)
```

This is benign (UI ergonomics — keeping `default` at the top is reasonable), but the moduledoc at line 11 says *"Names are pure user-chosen labels with no system semantics — they can be renamed or removed freely"*. The sort is a small contradiction. Either the moduledoc could acknowledge the listing-order convenience explicitly, or the sort could be by inserted_at to match the "no semantics" claim. Low-priority — not worth churning unless someone is touching the listing logic.

**File:** `lib/phoenix_kit/integrations/integrations.ex:586`

---

**6. `integration_picker.ex` still substitutes provider name when `conn.name == "default"`.**

`integration_picker.ex:173-179` renders provider name (e.g. "Google") in place of the literal `default`, while the integrations list page now renders names verbatim (`integrations_test.exs:50-58` pins this). The picker's behavior is intentional UX (shows users the provider they're picking, not a meaningless "default" label), and the list page is the management surface where verbatim is correct. The two are inconsistent on purpose — but the inconsistency is undocumented in either component's moduledoc. A one-liner in the picker noting *"`default` rendered as the provider name in the picker for display ergonomics; the management list shows it verbatim"* would prevent confusion.

**File:** `lib/phoenix_kit_web/components/core/integration_picker.ex:173-179`

---

**7. V107 / V106 tests replicate the migration SQL verbatim.**

Both `v106_test.exs` and `v107_test.exs` document this explicitly (the migration helpers can't run outside an `Ecto.Migrator` runner) and the helpers literally copy the migration SQL into the test. That works for "does this query do what we expect," but it's worth flagging the failure mode: if a future edit to `V107.up` changes the backfill SQL but doesn't change the test helper, the test will pass against the old SQL while the migration runs different SQL. The moduledoc on `V107Test` explains the boot-time schema verification covers the *schema additions*, but not the backfill semantics.

A more robust pattern would be to extract the backfill SQL to a private function the test can call directly — but that's a refactor for a future PR. Documented limitation rather than a bug.

**Files:** `test/phoenix_kit/migrations/v106_test.exs`, `v107_test.exs`

---

**8. V107 test coverage doesn't exercise the new UNIQUE name index.**

`v107.ex:104-107` adds `UNIQUE (lower(name))` on `phoenix_kit_ai_endpoints` — fixing the long-running silent-acceptance bug that the moduledoc calls out. `v107_test.exs` asserts the column and the integration_uuid index exist, but does NOT verify that duplicate endpoint names get rejected (or that case-only differences collide). That's exactly the behavior change end users will see, and it's the only behavior the changeset's `unique_constraint(:name)` was claiming for years. Two short tests (one for case-sensitive duplicates, one for case-only differences) would lock the contract — same pattern as `v106_test.exs:108-133`.

**File:** `test/phoenix_kit/migrations/v107_test.exs`

---

**9. `add_connection/3` doesn't dedupe against the legacy bare `integration:{provider}` key.**

`integrations.ex:658` checks `Settings.get_json_setting(settings_key(storage_key), nil) != nil` to detect existing rows, but uses the named-shape key (`integration:google:default`). If a host has a legacy `integration:google` row sitting around (no `:default` suffix), `add_connection("google", "default", ...)` will succeed alongside it, leaving an orphan bare-key row that `list_connections/1` only surfaces when no `default` named row exists (`:569-585`).

`migrate_legacy/0` callbacks are supposed to clean this up at boot, but if a module's migrator hasn't been written yet (or fails silently), the orphan persists. Not a regression — same risk existed pre-PR — but the strict-uuid pivot didn't address it. Worth a sentence in the moduledoc and possibly a `:already_exists_legacy` return so the form can prompt a delete.

**File:** `lib/phoenix_kit/integrations/integrations.ex:646-684`

---

**10. `verify_oauth_state/2` is permissive when no state was stored.**

`integration_form.ex:626-642`: if `oauth_state` is missing or empty in the integration data, the function returns `:ok` to allow the callback. This handles the "legacy flow / state not required" case the comment describes, but in the post-PR world every `connect_oauth` event calls `save_oauth_state/2` first (`:227`) — so a missing state means either someone bypassed the form or the row was modified between authorize and callback.

The CSRF risk is low because an attacker would need to forge a callback hitting a row with no stored state — but in the new flow that should be a stable condition (state always saved before redirect). Tightening to `{:error, :state_mismatch}` on missing state would close the door without affecting any post-PR usage.

**File:** `lib/phoenix_kit_web/live/settings/integration_form.ex:626-642`

---

## Things done well

- **The strict-uuid pivot is well-staged.** Reads stay dual-input for legacy data walks; writes flip to uuid-only. This is the right tradeoff — corrupted JSONB can't leak into new storage keys, but every existing caller still has a working lookup path while modules write their `migrate_legacy/0` migrators.
- **`resolve_to_uuid/1` is a clean primitive.** Centralizing the dispatch over uuid-vs-`provider:name` removes the dup that two consumer modules (`phoenix_kit_ai`'s `openrouter_client.ex` and `phoenix_kit_ai.ex`) had grown independently. The split rationale — `find_uuid_by_provider_name/1` doesn't handle the uuid-passthrough case — is well-reasoned and pinned by 6 tests.
- **V106 down/1 pre-check is the right shape.** `LIMIT 1` instead of surfacing all duplicates eagerly is the correct call for an ops tool — operators resolve duplicates one at a time and re-run. Raising before the DROPs is the load-bearing detail.
- **Orchestrator robustness.** `do_run_legacy_migration/1` rescues both `raise` and `:exit`, validates return shapes (`:ok` / `{:ok, _}` / `{:error, _}`), and warns on unexpected returns. The host app boot can't be taken down by a flaky module migrator. `safe_call/3` follows the same pattern for every other optional callback — consistent.
- **`apply_save_outcome/2` handles the `error` status case correctly.** A connection in error state is the most common case where the operator wants to re-test after fixing credentials. Auto-firing the test for `error` (alongside `configured` / `connected`) is the right behavior, and the comment at `:550-569` explains the visibility-guard sync requirement.
- **Provider definitions are well-researched.** Mistral's billing-required gotcha, DeepSeek's credits-required gotcha, Microsoft's `offline_access` requirement for refresh tokens, and the `Value`-vs-`Secret-ID` Azure copy-paste trap are all called out in the instructions panels with named gettext strings — operators get the right warnings inline rather than discovering them via an opaque error from the provider.
- **Test infrastructure improvements.** Endpoint-once-at-suite-level (vs. per-test) fixes the ETS race the previous setup had, `lazy_html` adds proper HTML assertion ergonomics, and the `render_errors` config surfaces real errors instead of "no 500 template." These were folded in incidentally but they're the kind of plumbing fixes that pay back on every future test.

---

## Out of scope (noted, not requested)

- **CHANGELOG.md / @version.** Per AGENTS.md convention, the maintainer owns CHANGELOG entries and the @version bump for releases. `mix.exs` still says `1.7.102` (the last shipped release on 2026-04-29) and the CHANGELOG hasn't grown new entries since. Both V106 (PR #510) and V107 (PR #511) are unreleased pending the next rollup. Not a finding — just flagging the gap exists, as the convention requires.
- **Microsoft 365 capabilities map.** `capabilities: [:microsoft_outlook, :microsoft_onedrive, ...]` are declared but no consumer module currently reads them. They're forward-looking — fine as-is.

---

## Verdict

**APPROVE on merit; address findings 1, 2, 4 in a follow-up.** Everything else is documentation polish or future-PR territory.

The strict-uuid invariant is now well-pinned by both the storage-key invariant fuzz tests (referenced in commit `524445e9`) and the orchestrator/primitive coverage. The PR is structurally sound. The merged state is safe to ship.
