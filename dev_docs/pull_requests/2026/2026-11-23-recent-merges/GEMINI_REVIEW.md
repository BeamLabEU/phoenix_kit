# Review since PhoenixKit 3.7.0 — 2026-11-23

**Reviewer:** Gemini · **Range:** `v3.7.0` (`a5111808e`)..`78dd35a0b` on `main` · **Fixes landed:** `51d9e5311`

Reviewed every PR and follow-up commit merged since `v3.7.0`:

- **PR #1054** (`e3acfecc5`) — `NavTabs` `in_menu` tab key + follow-up `aria-disabled` / focus polish (`a674578e2`)
- **PR #1055** (`2192e2840`) — `MediaBrowser` `:comments` and `:show_path` options; `:own_files_only` extended to annotations + follow-up (`a674578e2`)
- **PR #1056** (`f37a52a13`) — `MediaBrowser` host-defined `:mark` + gettext refresh (`96a5337ff`) and follow-up (`a674578e2`)
- **PR #1057** (`f1f412d01`) — `MediaViewer` / `MediaCanvasViewer` embedding options (`:can_annotate`, `:annotate_only`, `:own_files_only`, `:write_scope`, `:comments`, `:details`, `:authors`) + anonymous/readonly annotation fixes (`520291354`, `a674578e2`)
- **PR #1058** (`0b428a8a8`) — Cross-domain handoff (`PhoenixKit.Handoff`, `HandoffController`, `PruneWorker`, V236, `RequestLog`, `RateLimiter`, `Sessions.Revocation`) + catalog restore (`a78de00a2`)
- **PR #1059** (`24dc30fa7`) — `MediaCanvasViewer` `"Other versions"` dropdown label
- **Follow-up `a674578e2`** — `OAuthAvailability.configured_providers_cached/0` display-path caching (#1050)
- **Docs** — `CONTRIBUTING.md` (`a1835df4c`), prior review notes (`c5d2fbfd1`, `78dd35a0b`)

## Findings fixed (in `51d9e5311`)

### BUG - MEDIUM — Cross-domain handoff (#1058): `start` failed for enabled dialects or base codes and `host_languages/0` duplicated / leaked fallback hosts

**Files:** `lib/phoenix_kit/handoff.ex`, `lib/phoenix_kit_web/controllers/handoff_controller.ex`

1. `Handoff.host_languages/0` iterated `language <- Enum.uniq([code, DialectMapper.extract_base(code)])` unconditionally for every enabled code. When a resolver answered for both a dialect and its base code (e.g. `def host("de" <> _)`), `host_languages/0` emitted duplicate `{code, host}` entries. Worse, when an enabled dialect had its own host (`"de-AT"` → `"shop.at"`) while the base code fell back to a different host (`"de"` → `"shop.de"` for a disabled dialect), `host_languages/0` emitted both and leaked `"shop.de"` into `allowed_hosts/0`.
2. `HandoffController.do_start/2` resolved the site via `resolve_site(conn)` and then called `Routes.canonical_host(lang)` a second time without consulting `site(conn).languages`. Calling `Handoff.start_path("de-DE", "/shop")` (an enabled locale code, e.g. `@current_locale` or `language_for_host/1`) silently failed with `302 /` whenever the resolver only mapped base codes (`"de"` → `"shop-de.test"`, as in `HandoffResolver` and the guide); conversely, calling `Handoff.start_path("de", "/shop")` failed whenever the resolver only mapped full dialect codes (`"de-DE"`). Valid requests also queried the resolver twice for `lang`.

**Fix:** `host_languages/0` now resolves exact enabled codes first and only queries base codes for entries whose exact lookup returned `nil` (one `{code, host}` per enabled code, exact dialect preferred). Added `Handoff.host_for_language/2` (case-insensitive exact match on enabled code first, then bare base-code match with resolver tie-breaking when multiple enabled dialects share a base) and wired `do_start/2` to use it. Added unit and integration regressions in `handoff_test.exs` and `handoff_controller_test.exs`.

---

### BUG - MEDIUM — Cross-domain handoff (#1058): `handoff_apply/2` ran outside the target domain's Gettext locale and hook tasks dropped `PhoenixKitWeb.Gettext`

**Files:** `lib/phoenix_kit/handoff.ex`, `lib/phoenix_kit_web/controllers/handoff_controller.ex`, `guides/cross-domain-handoff.md`, `lib/phoenix_kit/module.ex`

1. `Handoff.call_hooks/2` propagated only the process-global `Gettext.get_locale()` into supervised hook tasks and dropped `Gettext.get_locale(PhoenixKitWeb.Gettext)` (unlike `MediaBrowser.Removal.call/3`, which copies both).
2. Because `/handoff/:token` has no `:locale` URL segment, the browser pipeline leaves Gettext at the site default. `HandoffController.do_redeem/2` resolved `locale = Handoff.language_for_host(...)` and applied it to `signed_in_line/2` via a hand-rolled private `in_locale/2` (which only set `PhoenixKitWeb.Gettext` on `extract_base/1`, skipping `RecipientLocale.gettext_locale/1`), while `Handoff.apply_payload/4` ran outside that locale entirely — so module notices translated with Gettext rendered in English next to a localized sign-in flash.

**Fix:** Propagated both process-global and `PhoenixKitWeb.Gettext` locales in `Handoff.call_hooks/2`, wrapped both `Handoff.apply_payload/4` and `signed_in_line/2` in the canonical `PhoenixKit.Utils.RecipientLocale.in_locale/2`, updated the module callback docs and guide, synced gettext line references across `priv/gettext/default.pot` and the 10 `.po` files, and added unit and integration tests.

---

### BUG - MEDIUM — Cross-domain handoff (#1058): post-hook session check discarded the fresh `source_session`

**Files:** `lib/phoenix_kit_web/controllers/handoff_controller.ex`, `lib/phoenix_kit/handoff.ex`

After module `handoff_apply/2` hooks returned (up to 5 s), `HandoffController.do_redeem/2` called `source_session_alive?(row)` → `Auth.get_live_session/2`, checked `!= nil`, discarded the fresh row, and passed the pre-hook `row.source_session` to `land/4`. Any `active_role_uuid` change made on the source session during the hooks was lost.

**Fix:** Replaced `source_session_alive?/1` with `fresh_source_session/1` (sharing `Handoff.inherited_session/1` so `@source_session_keys` has one definition) so the fresh session is inherited at zero extra query cost. Added an integration test using `HandoffScriptedModule`.

---

### IMPROVEMENT - MEDIUM — `OAuthAvailability` (`a674578e2`): avoid caching transient errors and redundant DB queries in `status/0`

**File:** `lib/phoenix_kit/users/oauth_availability.ex`

1. `configured_providers_cached/0` called `configured_providers/0`, which caught exceptions and `:exit` (e.g. a transient DB pool checkout timeout) and returned `[]`. Caching that `[]` into the 5-minute `:settings` cache could hide all OAuth buttons on login/register/account-menu surfaces until expiry or a settings write.
2. `status/0` called both `configured_providers/0` and `oauth_available?/0` (which calls `configured_providers/0` a second time).

**Fix:** Split out `fetch_configured_providers/0` returning `{:ok, providers} | :error`, skipping `Cache.put/4` on `:error`, and reused `providers` in `status/0`.

---

### IMPROVEMENT - LOW — `NavTabsOverflow` (#1054), `MediaViewer` (#1057), and Elixir 1.18 + OTP 28 test compilation

- **`priv/static/assets/phoenix_kit_admin.js`**: added `"data-nav-in-menu"` to `NavTabsOverflow`'s `MutationObserver` `attributeFilter` alongside `"class"` and `"data-nav-active"`.
- **`lib/phoenix_kit_web/components/media_viewer.ex`**: corrected the `update/2` cache-recompute comment (removed references to stepping and `current` changes, which do not recompute via `update/2`).
- **`test/support/api_key_test_support.ex`**: changed `@expected_cache_warnings` from a list-of-regexes module attribute to `defp expected_cache_warnings/0` so `mix test` compiles cleanly on Elixir 1.18.4 + Erlang/OTP 28 (where PCRE2 regex NIF references inside collection attributes fail escaping).

## Checked, no additional issues found

- **PR #1054 (`NavTabs` `:in_menu`)**: server/hook agreement on `in_menu?/2` and `forced`, `aria-disabled` cleared on every `sync()`, focus handoff on hiding `"⋯"`, `admin_split` boundary intact.
- **PR #1055 (`MediaBrowser` `:comments`, `:show_path`, `:own_files_only`)**: server-side `annotation_reply` and title-update gates, `build_comment_decorations/2` read-only `on_save: nil`, colspan math in `list_view.html.heex`.
- **PR #1056 (`MediaBrowser` `:mark`)**: `toggle_mark` guarded by library/`viewer_uuid`/`foreign_reference?`, picker exclusion (`@picker_file_write_events` and picker locked to `"grid"` view), `normalize_mark/1` validation, `type_badge_offset/4` corner placement.
- **PR #1057 (`MediaViewer` / `MediaCanvasViewer` embed options) & `520291354`**: anonymous and readonly annotation lockout, `comment_preview_author` split preserving stored `comment_author` across drags under `authors={false}`, `wire_metadata/2` on initial canvas and every `patch_shape/3` push, `servable?/1` and private-library time-window URL signing.
- **PR #1058 (`V236`, `RequestLog`, `RateLimiter`, `Sessions.Revocation`, `PruneWorker`, `UserToken`)**: single-statement atomic `redeem/4`, `source_proof_hash` unique index + savepoint handling inside/outside transactions, `Sec-Fetch-*` and `HEAD`/prefetch guards, `RequestLog` repeated-slash token redaction, prefix-safe V236 migration and manifest/cron registration.
- **PR #1059 (`"Other versions"`)**: single `Download` button, valid Heroicon, all 10 gettext catalogs translated and in sync.

## Verification

- **PostgreSQL test setup:** created local `phoenix_kit_test` DB and migrated through V236 via `test_helper.exs`.
- **Elixir unit + integration suites (against PostgreSQL):**
  - Broad sweep across all post-`v3.7.0` suites: **613 tests, 0 failures**
  - Final pass after formatting and gettext sync (`handoff_test`, `handoff/*`, `handoff_controller_test`, `handoff_translations_test`, `oauth_availability_test`, `media_viewer_embed_options_test` unit + integration, `v236_test`, `revocation_handoff_table_test`, `user_token_inherit_test`, `request_log_test`): **313 tests, 0 failures**; `handoff_translations_test.exs`: **12 tests, 0 failures**
- **JavaScript suite (`node --test test/js/*.test.cjs`):** **966 tests, 0 failures**
- **Static & catalog checks:** `mix compile --warnings-as-errors`, `mix test.compile`, `mix format --check-formatted` (on all edited files), `mix credo --strict` (0 issues), `mix gettext.extract --check-up-to-date` (0 drift, 0 fuzzy).
- **Dialyzer:** 0 warnings in any touched or post-`v3.7.0` file (8 pre-existing OTP 28 `call_without_opaque` warnings remain in unrelated files under Elixir 1.18.4 + OTP 28).
