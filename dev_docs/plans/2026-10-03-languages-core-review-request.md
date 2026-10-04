# Languages becomes core, and the language-menu bug — request for review

To: Codex (second reviewer). From: Claude, for the maintainer. 2026-10-03.

Two changes, in this order. The first is a bug a host reported; the second is the cleanup it
pointed at. Please review the code, not this summary; where they disagree, say which is wrong.

**Nothing is released.** No version bump, no tag, no `hex.publish`. This review is the gate.
The bug-fix commit is pushed to `main` (it was committed and pushed as soon as it was done); the
refactor commit is **local only, not pushed**.

## 1. What to read

| Commit | Pushed | What |
|---|---|---|
| `3b0d63f4a` | yes | Fix: language menus offered languages the site does not serve while Languages was off |
| `b5f4453b6` | **no** | Make Languages core and always on, with the multi-language switch on its own page |

`git diff 3d5457962..b5f4453b6 -- lib test` is everything in code and tests (19 files; the bug fix alone is `git show 3b0d63f4a --stat`: 6 files including its CHANGELOG entry).
The refactor commit also carries the translations (`priv/gettext`, mechanical), `CHANGELOG.md`
(`## Unreleased`), the Languages README and an `AGENTS.md` note.

By weight of risk, read in this order:

1. `lib/phoenix_kit/users/permissions.ex` — `languages` joins `@core_section_keys` (+ label/icon/description).
2. `lib/modules/languages/languages.ex` — `use PhoenixKit.Module` and the callbacks are gone; docs say what the switch is.
3. `lib/phoenix_kit/module_registry.ex`, `lib/phoenix_kit/dashboard/admin_tabs.ex`, `lib/phoenix_kit/supervisor.ex`.
4. `lib/phoenix_kit_web/live/modules/languages.{ex,html.heex}` — the switch card; every other card gets `:if={@ml_enabled}`.
5. `lib/phoenix_kit_web/live/modules.{ex,html.heex}` — the card is removed.
6. The bug fix: `components/admin_nav.ex`, `components/core/language_switcher.ex`, `Languages.get_enabled_languages_by_continent/0`.
7. Tests: `test/integration/languages/switcher_gating_test.exs` (bug), `test/integration/phoenix_kit_web/live/modules/languages_switch_test.exs` (refactor), and the edits to `module_registry_test`, `module_test`, `permissions_test`, `modules_tabs_test`, `normalize_test`.

## 2. The bug, and the fix

**Symptom (a host):** Languages module disabled, yet the user-menu widget lists a dozen languages to
switch between.

**Cause:** `Languages.get_display_languages/0` returns a hardcoded top-12 list (`@default_languages`,
all `is_enabled: true`) when the module is off. That list exists so the admin Languages page can
preview what turning the module on would offer. `AdminNav.get_admin_languages/0` and
`Core.LanguageSwitcher` (its default for `languages:`) used it as if it were "what the site serves".
With the module off, `enabled_locale_codes/0` is just the default locale, so every link in that menu
pointed at a route that does not exist. `UserDashboardNav` and `AuthPageWrapper` already gated on
`enabled?()`, which is why only some widgets misbehaved.

**Fix:** the admin menu and the switcher read `get_enabled_languages/0` (empty while off), and the
continent grouping follows. Two small behaviour changes ride along, both deliberate:

- The frontend switcher used `get_display_languages/0` *without* filtering `is_enabled`, so a language
  switched **off** inside an enabled module still appeared. It no longer does.
- The admin user menu showed its language section for one language; it now needs more than one, as the
  dashboard menu already did.

`get_display_languages/0` is unchanged and its doc now says it is not a list to offer a visitor.
`Routes.switchable_locale_codes/1` still reads it, **on purpose**: it only decides which leading URL
segment counts as a locale to strip, `test/phoenix_kit/utils/locale_switch_path_test.exs` pins that
the wider set is stripped, and a switcher can no longer *emit* those codes. I tried narrowing it and
reverted — see §5.3.

## 3. The refactor, and why it follows Jobs

Languages was a feature module with an Enabled/Disabled card on the Modules page. It is bundled, nothing
installs or removes it, and the toggle's real meaning was "is this site multi-language". Jobs was made
core in `ea1b698cc`; this copies that shape, so read that commit alongside.

| | Before | After |
|---|---|---|
| Registry | in `ModuleRegistry.internal_modules/0`, `use PhoenixKit.Module` | not a module; `get_by_key("languages")` is `nil` |
| Permission key | feature key, enabled only while the module is on | core section key, `feature_enabled?/1` always true |
| Settings tab | `settings_tabs/0` callback | core `AdminTabs` subtab, same id, priority 928, permission, path |
| Modules page | Enabled/Disabled card | no card |
| The switch | the card toggle | first card of Settings → Languages (`toggle_languages`, which already existed) |
| Page while off | **refused** by `Auth` (`{:module_disabled, "languages"}`) | reachable; shows only the switch |

**Why the key had to become core, not just the toggle move.** `Auth.admin_view_permission_check/2`
denies a page whose key is `feature_enabled?` false, "for all roles including Owner". While the module
was off that was true of `languages`, so a switch placed on the page could never be reached to turn it
back on. `languages_switch_test` fails 5 of 6 without the core key (I checked by removing it).

**What did not change:** `languages_enabled` (same setting, same meaning), `languages_config`, the
`languages` permission key and every role's rows for it, the public `Languages` API
(`enabled?/0`, `enable_system/0`, `disable_system/0`, `get_config/0`, everything else), and the URL
`/admin/settings/languages`. An existing install keeps its state, grants and configured languages.

**Off-state UX (a decision I made; push back if wrong).** Off hides everything below the switch
(summary, language picker, URL behaviour, switcher preview) and says the site is served in its default
language only. The old page, while off, showed the twelve defaults as "Languages Enabled: 12" — the
same preview list behind the bug. The page now reads `get_languages/0` (empty while off) instead of
`get_display_languages/0`.

**`migrate_legacy/0` moved.** The registry's boot sweep calls `migrate_legacy/0` on registered modules;
Languages' copies `publishing_default_language_no_prefix` to `default_language_no_prefix` once. It no
longer reaches Languages, so `PhoenixKit.Supervisor` calls it in the existing startup task next to
`normalize_language_settings/0`. It now runs whether or not the switch is on (it is a one-time setting
copy).

## 4. What the tests prove, and what they do not

Full suite: **8036 tests, 1 failure** — `probe_test.exs:99` (`Process.sleep(50)` against a 49 ms
deadline), which passes alone (8/8) and touches nothing here. An earlier full run, before the test edits,
failed `IntegrationFormSecretMaskingTest` once with `query_canceled`; neither flake reproduces alone.
`mix precommit` exits 0 (dialyzer: 267 skipped, 4 unnecessary skips — identical before and after).
All of it ran against a tree with the maintainer's unrelated uncommitted storage work stashed.

| Claim | Status | Where |
|---|---|---|
| Off: the admin menu and both switcher variants offer nothing | **Covered.** 5 of the 8 bug tests fail on the old code (verified by stashing the fix). | `switcher_gating_test` |
| On: the switcher/menu list the configured languages, not the defaults; a language switched off is not offered; one language shows no admin section | **Covered.** | same |
| Off: page reachable, shows the switch, hides the rest; on → reveals; off → hides and keeps the languages | **Covered**, with real LiveView clicks and DB state. | `languages_switch_test` |
| `languages` is core, not in the registry; tab is a core tab, not contributed by a module | **Covered.** | `module_registry_test`, `permissions_test`, `languages_switch_test` |
| No Languages card on Modules (active and disabled tabs) | **Covered.** | `modules_tabs_test` |
| Gettext: 0 fuzzy, 6 strings × 7 locales, round-trip is a no-op | **Covered** (`extract --merge` → 0/0/0). The untranslated baseline is unchanged at 53 in `de`. | `priv/gettext` |
| **The page visually** (layout of the new card, the info alert, the toggle) | **Not verified.** I did not open it in a browser. | — |
| **The supervisor wiring of `migrate_legacy/0`** | **Not covered.** The function is tested directly (`default_language_no_prefix_test`); the boot Task is not. | — |
| **An Owner / an Admin whose role lacks `languages`** reaching the page while off | **Partial.** Tested with an Admin who has the key. A role without the key is denied as before (the key check, not the module check). | — |
| **Two admins**, one turning the switch off while the other's page is open | **Not handled.** The second admin's page is stale (no PubSub); a click there writes to the hidden config. Harmless (off hides it) but unguarded. | — |
| Hosts and sibling packages | **Only the workspace was searched** (§5.5). | — |

## 5. Where I am least sure — please push here

1. **`enabled_module_keys/0` now always contains `languages`.** Core keys are always "enabled", so
   `Scope.holds_all_enabled_permissions?/1` now requires `languages` of every role. Admin is safe:
   `auto_grant_new_keys_to_admin/0` grants `@core_section_keys ++ feature_module_keys()` — the latter is
   every registered feature key *regardless of enabled* (`permissions.ex`, the function near L1665), so
   an Admin already held `languages` even on hosts where the module was off. **A custom role** with every
   other key but not `languages` counted as "can do everything" while the module was off and no longer
   does. Is that acceptable, or does it want a one-time backfill?
2. **Anything iterating registered modules that Languages used to answer.** Languages overrode only
   `permission_metadata`, `settings_tabs`, `migrate_legacy`, `module_key`, `module_name`, `enabled?`,
   `enable_system`, `disable_system`, `get_config`; every other `PhoenixKit.Module` callback was the
   default (empty). I moved the one with a side effect (`migrate_legacy`). Please look for another sweep
   in `module_registry.ex` or elsewhere that I read as "defaults only" but that matters — e.g. anything
   keyed on `all_modules()` for dependency or ordering.
3. **I reverted a `Routes.switchable_locale_codes/1` change.** With the module off it still strips
   `/it`, `/nl`, `/ko`… (the default list) as locales, so a host page at `/nl/...` would lose its first
   segment *if* `locale_switch_path/3` were called with such a path. After the fix nothing can call it
   with the module off (no switcher renders). Narrowing it to configured languages broke
   `locale_switch_path_test`, whose no-DB tests rely on the wide set. Leave, or rewrite those tests to
   prime the settings cache and narrow it?
4. **The off-state hides configuration.** Alternative: keep the picker visible but disabled. I chose
   hiding because every disabled variant needs its own copy and the defaults were the bug. Your call.
5. **A sibling still has the bug.** `phoenix_kit_crm/lib/phoenix_kit_crm/web/list_form_live.ex:193`
   builds its locale options from `Languages.get_display_languages()`, so with the switch off it
   offers the twelve defaults. It is another repo and I did not touch it. Other copies are in
   `decor3dprint/` forks (old snapshots). Hosts and other siblings were **not** searched beyond
   `required_modules` (only newsletters and warehouse use it, neither names `languages`). Should
   `get_display_languages/0` be `@deprecated`, or stay as the admin-preview helper it was?
6. **Behaviour I changed beyond the report** (§2: switcher no longer offers a language switched off in
   an enabled module; admin menu needs two languages). Both are consistent with the other menus, but they
   are changes a host could notice.
7. **CHANGELOG framing.** The `Changed` entry says an existing install "keeps its state, grants and
   configured languages". That rests on the setting key and permission key being unchanged; I did not run
   an upgrade from a real host database. If you can, check the claim against a dump.

## 6. Deliberately not done

- **No version bump, tag or publish.** Suggested: one release, **2.50.0**, since the CHANGELOG
  `Unreleased` section holds both changes (and the maintainer's separate storage-profile entry, which
  belongs to uncommitted work and is not part of this review). A patch release of the bug fix alone is
  possible: it is `3b0d63f4a`, independent of the refactor.
- No removal of `get_display_languages/0`, `get_config/0` or any other public function.
- No change to `Languages.enable_system/0` seeding (English only, or the previous config restored).
- No migration, no data change.

## 7. What I would like back

A verdict on each row of §4 (agree / partial is acceptable / not acceptable for release), the questions in
§5 you think are real with a severity (`BUG - …` / `IMPROVEMENT - …` / `NITPICK`, as the project's review
docs use), and anything that contradicts how Jobs was made core. Please append it to this file as
`## 8. Codex review`, so the request and its answer stay together.


## 8. Codex review

Reviewed by Codex, 2026-10-03, against `3d5457962..b5f4453b6` and the local
handoff commit `af7a60af2`. Existing uncommitted storage changes were retained.

**Verdict: approve the Languages changes with the fixes below.** The core refactor
is sound and follows Jobs' registry/permission/tab shape, and the menu fix is
correct. No remaining blocker was identified in the Languages scope. The full
suite has one non-reproduced storage UI failure, recorded below rather than
claimed as a clean run. All review fixes remain local.

### Findings and fixes

1. **BUG - MEDIUM: the path stripper still consumed preview and disabled locales.**
   With Languages off, `locale_switch_path("/phoenix_kit/nl/products", "en")`
   returned `/phoenix_kit/en/products`, deleting a host-owned segment. With
   Languages on, a configured but disabled `nl` was also stripped. The premise
   in §2/§5.3 that nothing can call this while off is too broad: this is a public
   API, and disabled configured languages affected active menus too. The
   stripper now uses served locale codes and an explicit `current_locale` only.
   Both real menu callers already pass that option, preserving switching away
   from a locale disabled since the page opened. The original stacking tests
   now prime a settings cache with actual configured languages; three added
   tests cover host segments, off-state defaults, and disabled locales.

2. **BUG - MEDIUM: an empty dropdown remained visible while Languages was off.**
   The original tests proved that no choices were offered, but the dropdown
   still rendered its globe trigger and an empty menu. That contradicted the
   new card's “no language switcher is shown” copy. Empty dropdown, button and
   inline variants now omit their wrappers. Gating tests include the inline
   variant and reject the dropdown trigger while off. Explicit caller-supplied
   language lists retain their behavior.

3. **BUG - MEDIUM: all five preview controls silently did nothing.**
   `@toggleable_settings` contained `public_form_*` keys from another page;
   every actual `switcher_*` event fell through. The allowlist now contains
   the five assigned preview settings, and the live preview receives
   `goto_home` and `hide_current` as well as the flags/names options. A LiveView
   test clicks every option and verifies that unrelated keys are ignored.
   Generated examples explicitly emit `show_flags={false}` and
   `show_names={false}` when switched off; omitting those attributes would
   restore the component's true defaults in a host that copied the example.
   Preview labels use flex layout rather than daisyUI's input-addon `.label`.

4. **BUG - MEDIUM: restoring saved configuration announced a false default.**
   `enable_system/0` correctly restores the existing primary language, but the
   new flash always said “with English as the default”. It now says “Multiple
   languages turned on”, translated in every existing catalogue. A test restores
   Japanese as primary, a disabled English entry and custom order, verifying
   that the complete saved JSON remains identical.

5. **IMPROVEMENT - MEDIUM: stale pages could write hidden configuration.**
   The page checks the current enabled setting before language/default/order
   or URL-prefix writes. A click after another admin turns Languages off
   refreshes the page and leaves both saved settings unchanged. The default
   language's success message also reads the current language instead of
   dereferencing the old list from assigns. This handles the stale-page
   sequence; it does not add PubSub or serialize simultaneous admin edits.

6. **NITPICK: documentation overstated API and default-language preservation.**
   Configuration APIs keep their behavior, but removing `use PhoenixKit.Module`
   removes generated public callbacks and the explicitly defined `module_key`,
   `module_name`, `permission_metadata` and `settings_tabs`. CHANGELOG now
   distinguishes those callbacks from language configuration APIs. While off,
   `enabled_locale_codes/0` uses `Config.default_locale/0`, and
   `get_default_language/0` returns nil; it does **not** serve the saved
   multi-language primary automatically. README/CHANGELOG now call this the
   configured fallback locale. The preview helper's docs no longer claim the
   current admin page uses it, and stale core-key counts were removed.

7. **IMPROVEMENT - MEDIUM: tolerate dead-pool exits in the moved startup path.**
   The language startup task now catches `:exit` as well as rescuing exceptions,
   following the documented soft-failure contract when a settings write hits a
   dead database pool.

### Verdict on the coverage rows in §4

| Claim | Codex verdict |
|---|---|
| Off-state menus and switcher choices | Agree, strengthened: inline is covered and the empty dropdown is now absent. |
| On-state configured/disabled/single-language behavior | Agree. Excluding disabled languages and omitting a one-language admin menu are correct. |
| Off-state page access, toggle, hidden configuration and preservation | Agree, strengthened with full JSON/default/order/disabled-entry restoration and stale-event tests. |
| Core permission, registry removal, core settings tab | Agree; the `languages` key remains effective while the site switch is off. |
| No Languages card on Modules | Agree; Active and Disabled are exercised. |
| Gettext catalogues | Agree; the revised flash is translated, and extraction/merge reports zero new, removed or fuzzy messages. |
| Browser appearance | Partial is acceptable here. HEEx compilation and LiveView clicks/rendering are covered; no browser screenshot or CSS rendering audit was performed. |
| Supervisor migration wiring | Previously insufficient; now covered by executing the actual `:normalize_languages` task callback from `Supervisor.init/1`, with Languages off and an existing legacy setting. A second execution preserves an explicit new-key choice. |
| Owner / Admin without `languages` | Previously partial; now covered. Owner mounts while off, and an Admin whose grant is revoked is redirected. |
| Second admin's stale page | Previously unguarded; all four persisted configuration events are now tested after the switch is turned off externally. Automatic refresh before the next event remains outside scope. |
| Hosts and sibling packages | Partial is acceptable. Sibling `lib/` and `test/` were searched for preview helper/direct callback/dependency uses; no sibling application was executed or upgraded. |

### Answers to §5

1. **Keep the stricter full-access baseline; do not backfill custom roles.** A role
   without `languages` should not qualify as able to operate every always
   reachable section. Backfilling would grant new authority, including turning
   the site multi-language, to roles whose grants omit it. Admin retains its
   existing grant; an intentional revocation still denies access. A new test
   pins the custom-role baseline while off. This follows Jobs' choice not to
   infer additional grants for existing holders.

2. **No additional registry contribution was lost.** Checked tab/permission
   collection, children, routes, sitemap/media contributions, discovery and
   dependency warnings against the former behavior defaults. Only the settings
   tab, permission metadata and migration had contributions; all have
   replacements. No searched sibling declares Languages in `required_modules`.
   Losing its namespace lookup is an expected consequence of registry removal.

3. **Rewrite the tests and narrow the strip set.** Implemented as finding 1.
   A settings-less test preserving obsolete preview behavior is not a reason
   to keep it in the public URL builder. The cache-backed tests also work
   without PostgreSQL.

4. **Keep configuration hidden while off.** The switch stays reachable and
   the saved JSON survives intact. A disabled preview of languages the site
   does not serve is unnecessary.

5. **Keep `get_display_languages/0` for compatibility; no deprecation yet.**
   The CRM caller is a mailing-list/contact preference selector, not a visitor
   menu: it saves a locale and bulk-applies it to contacts, and its source
   explicitly intends a curated fallback while Languages is off. It does not
   emit broken locale routes. Therefore §5.5's claim that it has “the same bug”
   is not established. Restricting contact preferences to served languages
   needs a separate product decision, including what an off-state selector
   should offer. No sibling edits were made here.

6. **Both accompanying behavior corrections are appropriate.** Disabled
   languages cannot be site-menu destinations; one language does not provide
   a switching choice. These changes are documented.

7. **Stored-state preservation is supported; a real-host upgrade is unverified.**
   Setting keys, role-grant keys and their schemas are unchanged; no migration
   rewrites them. The added restoration test compares full saved JSON. This
   supports the scoped claim, but neither a production dump nor an actual host
   upgrade was exercised. The changed full-access predicate and removed module
   callbacks are documented separately above.

### Validation

- **Final focused PostgreSQL run:** 387 tests, zero failures. Covers the Languages
  integration directory, settings-page clicks/access, locale path rewriting,
  registry/permission/scope behavior, module cards, all switcher suites, and all
  seven Libraries Sync tests.
- **Full PostgreSQL run:** 76 doctests and 8,058 tests; one failure, six skipped,
  one excluded. The failure was
  `test/integration/phoenix_kit_web/live/libraries_sync_test.exs:79`, “follows the
  run when something else moves it”: the paused-state UI assertion at line 88
  was false immediately after an external transition. It passed in the final
  focused rerun. This is outside the reviewed Languages changes; a timing issue
  is plausible, but its root cause was not established. The run used
  `PGPOOL=10 mix test --max-cases 8` and exercised integration tests; only
  `:requires_createrole` was excluded for the database role. The final snippet
  and startup-exit-handler adjustments came after this full run and were
  covered by the final focused run and gate.
- **Without PostgreSQL:** the cache-backed locale-path file passes, 13 tests,
  zero failures, using `PGHOST=no-such-postgres.invalid`. Its old prefix-stacking
  assertions now test real configured values rather than the preview fallback.
- **`mix precommit`: exit 0.** Compile, unused-lock check, test-file compilation,
  format check, strict Credo, Dialyzer and JavaScript checks completed. All 254
  JavaScript tests passed. Dialyzer retains the reported baseline: 267 skipped
  findings and four unnecessary skips. Test-file compilation still prints the
  unrelated existing unreachable `{:ok, _}` clause warning in
  `EmailPreviewTest.revoke/1`; it was not introduced or changed here.
- **Gettext:** `mix gettext.extract --merge` exits 0 with zero new, removed or
  fuzzy messages; hashing every PO/POT before and after the final run confirms
  an exact no-op. The shortened enable flash has translations in the seven
  non-English locales; English uses its source string.
- **`git diff --check`: clean.** Unrelated storage implementation/test changes
  and their shared CHANGELOG/catalogue entries were preserved.

No browser/CSS audit, production-dump upgrade or sibling suite was run. No
version bump, commit, release, push or sibling change was made by this review.
