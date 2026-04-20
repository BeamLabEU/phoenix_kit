# PR #495 — Add MediaBrowser live_component with scope_folder_id

**Author:** @timujinne (Tymofii Shapovalov) · **Branch:** `dev` → `dev` · **Files:** 20 (+4491 / −2319)
**Commits:** `ffda72f0` globe-switcher removal · `1d09f49b` table_default toolbar slots · `5d169b14` MediaBrowser extraction · `f27e5fb1` upstream merge + `?view=all` port · `cabc80b1` event routing + asset serving hotfixes

## Summary

Extracts the 1158-LOC `/admin/media` LiveView into a reusable `PhoenixKitWeb.Components.MediaBrowser` live_component with optional `scope_folder_id` (hard-scoped embedding). Adds scope-aware recursive-CTE query helpers on `Storage`, scope guards on all mutators (`create_folder/update_folder/delete_folder/move_file_to_folder/create_folder_link`), ports upstream `?view=all`, adds 52 new tests, and bundles two small unrelated admin UI refactors (globe switcher removal; `table_default` toolbar slots). Parent LV shrinks to a ~75-LOC wrapper. Controlled-mode URL-sync uses a parent-notify round-trip (`{MediaBrowser, id, {:navigate, params}}` → `push_patch` → `handle_params` → `send_update(nav_params: ...)`).

## Overall verdict

**Approve / merge.** Large refactor, but architecturally clean and well-tested. Scope enforcement is correct across all mutation paths; event routing is complete (all 62 server-event bindings have matching `phx-target={@myself}` — verified mechanically); controlled/uncontrolled dual-mode separation is sound; backward compatibility preserved via default `scope_folder_id \\ nil` args. No blocking findings. A couple of medium improvements and nitpicks noted below.

## Findings

### GOOD

- **Scope guards are comprehensive** — `within_scope?/2` is called in every mutator path: `create_folder/2`, `update_folder/3`, `delete_folder/2`, `move_file_to_folder/3`, `create_folder_link/3` all return `{:error, :out_of_scope}` on violation. ✅
- **Recursive CTE in `list_files_in_scope/2`** correctly walks descendants from the scope root and filters files to the resulting folder set. Parameters are passed via Ecto param binding, no SQL-injection risk. ✅
- **`within_scope?/2` three-clause logic is correct** — nil scope → always true, self-scope → true, else ancestor walk via `ancestor_of?/2`. Real root (nil folder_uuid) is correctly outside any non-nil scope. ✅
- **Breadcrumb truncation** — `folder_breadcrumbs/2` uses `drop_while` to cut the chain at the scope root; scope itself is not rendered as a crumb (it's the virtual root). Tested in `media_browser_scope_test.exs`. ✅
- **`update/2` first-mount guard using `Map.has_key?(socket.assigns, :uploaded_files)`** — correct, avoids the strict-`not`-on-nil pitfall that would raise. `cond` fall-through to `{:ok, socket}` is safe. (`media_browser.ex:68-82`) ✅
- **`assign_new(:scope_folder_id, fn -> nil end)`** at the top of `update/2` means parent can omit the attr without template KeyError. ✅
- **Controlled-mode parent-notify pattern** — component emits `{MediaBrowser, id, {:navigate, params}}`, parent handles via `push_patch` → `handle_params` → `send_update(nav_params: ...)`. Round-trip is clean and keeps URL as single source of truth. ✅
- **`phx-target={@myself}` coverage is complete** — verified all 62 server-event bindings (`phx-click`/`change`/`submit`/`keydown`) in `media_browser.html.heex` have `phx-target` on the same element (or on a parent form carrying multiple events). `phx-mounted={JS.focus()}` correctly omits target (JS command, not server event). ✅
- **Scope-invalid detection** — when `scope_folder_id` points to a deleted folder, `init_socket` flags `scope_invalid: true` and UI shows a banner; upload/nav paths are disabled. ✅
- **Orphan filter hidden under scope** — `<%= if is_nil(@scope_folder_id) do %>` block wraps the orphan toggle in the template; `count_orphaned_files/1` short-circuits to 0 when scope is set. ✅
- **Upload fallback** — `maybe_set_folder/1` falls back to `scope_folder_id` when `current_folder` is nil so scoped uploads land at the virtual root, not system root. ✅
- **Backward compatibility** — all new `scope_folder_id` arities default to `\\ nil`. Existing `/admin/media` unscoped call sites are unchanged. ✅
- **Parent LV shrank cleanly** — `media.ex` is now a 42-LOC wrapper that delegates to the component. No leftover state management; `handle_params` forwards via `send_update(..., nav_params: ...)`. ✅
- **Test coverage is substantial** — 519 LOC in `scope_test.exs` (CRUD + within_scope + list_files_in_scope + breadcrumbs), 233 LOC in `media_browser_scope_test.exs` (scope_invalid, orphan visibility, truncation), 295 LOC in `media_test.exs` (URL sync, deep links, malformed params), 167 LOC in `media_url_test.exs` (pure URL-builder unit tests). Plus `conn_case.ex` extended for LiveView testing (sandbox + endpoint supervision). ✅
- **`AssetsController` change is safe** — the try/rescue over `Application.app_dir/2` with `ArgumentError` is the correct exception (raised when an unknown app is asked for its dir). Parent apps without `:phoenix_kit_legal` installed simply get a 404 on `phoenix_kit_consent.js` (same as before), not a crash. The tuple widened from `{content_type, filename}` to `{content_type, app, filename}` consistently across all three entries. ✅
- **Two unrelated admin UI refactors are non-breaking** — globe-switcher removal (`admin_nav.ex` -89 LOC) is additive-remove only; `table_default` gains `toolbar_title`/`toolbar_actions` slots as optional additions; three pages (roles, activity, integrations) migrated consistently. ✅

### IMPROVEMENT — MEDIUM

- **Missing `attr` declarations on the live_component** (`media_browser.ex`). The component accepts `scope_folder_id`, `on_navigate`, `phoenix_kit_current_user`, `nav_params`, etc. but doesn't declare them with `attr :name, :type, default: ...`. The module docstring documents them, but declaring via `attr` gives compile-time checks and better IDE support. Not a blocker — the PR author listed this as out-of-scope/follow-up, which is reasonable for a refactor this size.
- **`folder_breadcrumbs/2` may issue N+1 `get_folder/1` queries** walking up the chain (`lib/modules/storage/storage.ex`). Each ancestor lookup is a separate query. Only matters on deep trees rendered per navigation — not on file-grid hot path — but worth batching into a single CTE query if breadcrumbs become a perf issue.
- **Globe-switcher removal**: locale switching presumably moves to the user avatar menu per the PR description, but worth a quick check that the avatar dropdown actually exposes a language picker in the admin. If not, a follow-up PR should add it before this becomes visible to admins.

### NITPICK

- **Silent `ArgumentError` rescue in `AssetsController`** — returning `nil` without logging when `phoenix_kit_legal` isn't installed is correct behavior but makes "why isn't my consent banner loading?" harder to debug. Consider `Logger.debug("Asset #{file} requested but app #{app} not loaded")` in the rescue. Not critical.
- **`phx-change="rename_folder_input"` on a `<form>` that also has `phx-submit="rename_folder"`** — both handlers fire on the same form element; `phx-target={@myself}` is declared once on the form which correctly covers both. Fine as-is, just noting the pattern for readers: one `phx-target` per element, not per event.

## Verification performed

- `git fetch pr-495` and diff against `dev`
- Mechanically checked all 62 `phx-(click|change|submit|keydown|keyup|drop-target|blur|focus|window-keydown|click-away)=` bindings in `media_browser.html.heex` — each has `phx-target={@myself}` on the same element or its enclosing form. Two apparent misses at `:488` and `:752` were false positives (forms carrying submit+change+keydown share one `phx-target`).
- Inspected `update/2` guard, `assign_new` usage, `AssetsController` try/rescue, scope-mutator logic.
- Confirmed `scope_folder_id \\ nil` is the default on all new arities (no breaking call sites).

## Recommendation

Merge. The author's "out of scope / follow-up" list is honest about the known gaps (`attr` declarations, bulk-mutator error aggregation, extracting URL helpers) and none of them are blockers. Recommend a follow-up ticket to add `attr` declarations and verify the admin language-switching path after the globe removal.

---

## Follow-up review (commit `4a7057d5` — "Fix scope enforcement in delete_selected and navigate_to_folder")

Two defense-in-depth holes closed. Both required crafted WebSocket events (admin-only, client-supplied `selected_files`/`folder_uuid`), so the impact was bounded, but the scope contract should hold uniformly across all code paths. My original review missed these — good catch by the author's verifier agent.

### What changed

1. **`handle_event("delete_selected", ...)`** (`media_browser.ex:883-898`). Previously `scope = scope_folder_id(socket)` was read but never consulted for files — `Storage.delete_file_completely(file_uuid)` was called unconditionally. A crafted `delete_selected` event carrying out-of-scope file UUIDs would delete them. The fix looks up each file via `repo.get(Storage.File, file_uuid)` and guards the delete with `Storage.within_scope?(file.folder_uuid, scope)`. ✅
2. **`handle_event("navigate_to_folder", ...)`** uncontrolled-mode branch (`media_browser.ex:1056-1069`). Previously `Storage.get_folder(folder_uuid)` was called with no scope check — a crafted `navigate_folder` event with an out-of-scope UUID would render sibling folder names and file lists outside the scope. The fix verifies the resolved folder is `within_scope?` and falls back to `{nil, nil}` (scope virtual root) on violation, consistent with other out-of-scope fallbacks in the component. ✅

### Notes on the fix

- **`selected_folders` was already safe** — it goes through `Storage.delete_folder(folder, scope)`, and the mutator-level guard returns `{:error, :out_of_scope}` internally. The fix didn't need to touch this branch.
- **Repo lookup pattern is correct** — `PhoenixKit.Config.get_repo().get(Storage.File, file_uuid)` matches the rest of the codebase for repo resolution.
- **Silent skip on out-of-scope delete** — files outside scope are quietly ignored with no flash. Defensible for defense-in-depth (crafted events shouldn't get diagnostic feedback), but the success flash still reads `"#{file_count + folder_count} item(s) deleted"` using the *selected* count, not the *actually deleted* count. Pre-existing and minor; worth fixing in a follow-up to report actual counts.
- **Controlled mode of `navigate_to_folder`** — sends a message to the parent LV (`push_patch` round-trip) rather than fetching directly, and the parent's `handle_params` → `send_update(:nav_params)` path flows through `apply_nav_params/2` → `resolve_folder/2` which already scope-checks. So controlled mode was never vulnerable.

### Verdict (updated)

**Approve — ready to merge.** The scope enforcement contract now holds uniformly across mutators, controlled/uncontrolled navigation, bulk delete, and pagination. No new issues in `4a7057d5`.
