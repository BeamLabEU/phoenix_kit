---
name: PR 488 follow-up review
description: Second-round review of Jason's advanced-user-dashboard PR after WIP push addressing blockers
type: project
---

# PR #488 — Advanced user dashboard (follow-up review)

**Author:** @mithereal (Jason Clark) · **Branch:** `main` → `main` · **Files:** 15 (+1789 / −30) · 8 commits

## Context

This is the second-round review. Author pushed 6 follow-up WIP commits ("fix: blockers", several "wip: blockers") attempting to address the first review at `dev_docs/pull_requests/2026/488-advanced-user-dashboard/CLAUDE_REVIEW.md`. Author is working through significant personal hardship (disclosed in PR thread) and we should be kind and concrete about what's needed next. Goal per screenshot: a drag-and-drop grid dashboard that auto-discovers widgets from enabled modules.

## Overall verdict

**Request changes — still not mergeable, but there has been real progress.**

Fixed since last round: schema↔table name alignment, migration uses the right table, `phoenix_kit_current_scope` is now read for access control, `.iml` was the original blocker — still present though, see below — `module_discovery` used in the loader, CSS partially de-hardcoded. The shape of the solution (Widget struct + per-user layout table + GridStack hook + mix task generator) is reasonable.

Still blocked by: a broken template that won't compile, a migration `down/0` that doesn't roll anything back, a schema with missing fields, test files pointing at modules that don't exist, warnings-as-errors compile failures that will fail CI, and several cross-file name/shape mismatches. Each one is small individually; together they mean the feature can't be exercised end-to-end yet.

## Resolved from first review (good)

- ✅ V97 no longer drops unrelated media tables — now correctly scoped to `phoenix_kit_dashboard_widget_layouts`.
- ✅ Schema/table name aligned (`phoenix_kit_dashboard_widget_layouts` used consistently in schema and migration).
- ✅ `Dashboard.Index.mount/3` now reads `socket.assigns[:phoenix_kit_current_scope]` for the auth check (was `{:error, :not_authenticated}`).
- ✅ `Widgets.Loader` replaced by `PhoenixKit.Utils.Widget` using `PhoenixKit.ModuleDiscovery.discover_external_modules()`.
- ✅ `Routes.path("/admin")` used instead of hardcoded path in access-denied branch.
- ✅ Widget struct has `enabled` flag and filter.

## Still broken — BUG — CRITICAL (blocks merge)

1. **Generated template has multiple compile/runtime errors** — `priv/templates/user_dashboard_advanced_page.ex`. After EEx string substitution this file is what users will get when they run `mix phoenix_kit.gen.user.dashboard.advanced`. Issues:
   - Line 33: `page_title: @page_title,` inside `assign(...)`. After `<%= @page_title %>` → `tab_title` replacement this becomes bare atom/identifier rather than a string — e.g. `page_title: Example,` won't compile. Same problem on line 113 `subtitle={@description}` (no `@description` assign exists).
   - Lines 20, 49: `get_session(socket, ...)` / `put_session(socket, ...)` — those are `Plug.Conn` functions, not valid for a `LiveView.Socket`. They will raise. LiveView needs session values threaded through `mount(_params, session, socket)` or stored in a different channel.
   - Lines 124–127: `gs-x={w.Widget.x}` etc. — `w.Widget.x` is not valid field access on a `%Layout{}`. Should be `w.x`, `w.y`, `w.w`, `w.h`. This syntax isn't Elixir at all.
   - Line 39 (index.ex): `title="Welcome, {@current_user.email}"` — the `{@...}` interpolation is a raw string, not HEEx. Use `title={"Welcome, " <> @current_user.email}` or a HEEx attribute expression.
   - `handle_event("save_grid", %{"items" => items}, socket)`: builds `layouts` but never uses it (passes raw `items` to `Layout.save_grid/2`), references an undefined `user` on line 69, and has two `{:noreply, socket}` returns making the tail unreachable.
   - `handle_event("drop_widget", ...)` calls `Widget.widgets_for(user)` — that function doesn't exist on `PhoenixKit.Utils.Widget`. `Widget.available_widgets(user)` is also undefined.
   Net: the generator will emit a file the parent app cannot compile.

2. **`V97.down/0` doesn't roll back.** `lib/phoenix_kit/migrations/postgres/v97.ex:45-52`:
   - `drop_if_exists index(:phoenix_kit_dashboard_widget_layouts, [])` — empty column list is a no-op at best.
   - The table itself is never dropped.
   - Comment is reset to `'97'` instead of `'96'` — so rollback leaves the schema stamped as the current version. Running down + up again would short-circuit.
   Needed: `drop_if_exists(table(...))` and `COMMENT ... IS '96'`.

3. **`phoenix_kit.iml` (IntelliJ project file, 278 lines) is still committed.** First review flagged this and the author's "fix: blockers" commit didn't remove it. Add to `.gitignore` and `git rm` the file.

## BUG — HIGH

4. **Schema has no `timestamps` but migration declares `timestamps(type: :utc_datetime)`**. `lib/phoenix_kit/dashboard/layout.ex:6-17` — without `timestamps()` in the schema, Ecto inserts will not populate `inserted_at`/`updated_at` and the NOT NULL constraint (Ecto default) will raise. Add `timestamps(type: :utc_datetime)` to the schema.

5. **`widgets_for/1` returns wrong data.** `lib/phoenix_kit/dashboard/layout.ex:84-90`:
   ```elixir
   repo().get_by!(PhoenixKit.Dashboard.Widget.Layout, uuid: user.uuid)
   ```
   Queries by `uuid` (primary key of Layout) with the *user's* uuid — will always return nil (rescued to `[]`). Should be:
   ```elixir
   from(l in Layout, where: l.user_uuid == ^user.uuid) |> repo().all()
   ```

6. **`upsert_layout/2` conflict target doesn't match any unique index.** Schema has unique index on `[:user_uuid, :uuid]` but upsert passes `conflict_target: [:user_uuid]`. PostgreSQL will raise `there is no unique or exclusion constraint matching the ON CONFLICT specification`.

7. **Unique-constraint name mismatch.** Changeset at line 27 uses `name: :dashboard_layouts_user_uuid_index`, but migration creates `:phoenix_kit_dashboard_widget_layouts_unique_index`. The `unique_constraint/2` won't convert errors; user gets a raw DB error.

8. **Tests reference nonexistent modules.** `test/phoenix_kit/widgets/loader_test.exs`:
   ```elixir
   alias PhoenixKit.Widgets.Loader
   alias PhoenixKit.Widgets.Widget
   ```
   Neither module exists — the real module is `PhoenixKit.Utils.Widget`. The test file will fail to compile in CI.

9. **CI will fail on `--warnings-as-errors`** (per CLAUDE.md: "compilation (warnings as errors)"). Current state introduces at least 7 warnings I saw when compiling locally:
   - `lib/phoenix_kit/utils/widget.ex:122` — `user`/`module_name` unused
   - `lib/phoenix_kit/utils/widget.ex:20` — `alias PhoenixKit.Utils.Widget` self-aliasing, unused
   - `lib/phoenix_kit/dashboard/layout.ex:64` — `user` unused in `save_grid/2`
   - `lib/mix/tasks/phoenix_kit.gen.user.dashboard.advanced.ex:47` — `import Plug.Conn` unused
   - `…:184` — `hooks_imports/0` unused
   - `…:450` — `parse_int/2` unused
   Fix each before the pipeline will pass.

10. **`user_can_access_module?/2` still hardcoded to `true`.** `lib/phoenix_kit/utils/widget.ex:122-125`. The first review flagged this; it's unchanged, just commented next to the real implementation:
    ```elixir
    defp user_can_access_module?(user, module_name) do
      ## PhoenixKit.Users.Permissions.user_can_access_module?(user, module_name)
      true
    end
    ```
    Either wire the real check or at minimum fail closed (`false`) for admin-only modules. A logged-in non-admin currently gets every widget.

11. **Version bump in `mix.exs` to `1.7.96` conflicts with main** — main is already at `1.7.96` (commit `9c013de9`). Rebase onto main and remove.

## BUG — MEDIUM

12. **`Dashboard.Index.mount/3` still reads `session["phoenix_kit_current_user"]`** (line 19). That key isn't set by PhoenixKit's auth pipeline — use `socket.assigns[:phoenix_kit_current_user]` or derive from the scope already fetched at line 12. Currently `current_user` will be `nil` and the render's `@current_user.email` reference will crash.

13. **`has_module_access?(scope, "dashboard")`** — there's no `"dashboard"` module registered via the Module behaviour, so the permission check may always return `false` (or always `true` — depends on the fallback in `Scope.has_module_access?/2`). Confirm the intended permission key; if the dashboard is meant to be universally available to authenticated users, use `Scope.authenticated?/1` instead.

14. **`context_menu.js` vs `dashboard_context_menu_remove.js`** — there are two context-menu JS files with different names; the generator writes `context_menu.js` but `priv/static/assets/js/hooks/dashboard_context_menu_remove.js` is committed separately. Pick one source of truth.

15. **Grid hook uses `n.el.dataset.id` but markup uses `data-uuid={w.uuid}`** — the grid change event will push `{id: undefined}` for every item, and the server's `save_grid` key lookup fails silently. Either emit `data-id` or read `dataset.uuid`.

## IMPROVEMENT — MEDIUM

16. **Generator prints manual setup instructions** (gridstack npm install, add imports to `app.js`). Follow the `phoenix_kit.install` pattern and do the asset wiring via Igniter (see the CSS-sources compiler in `compile.phoenix_kit_css_sources.ex` and the `phoenix_kit.js` copy pattern in `phoenix_kit.install`).

17. **`load_all_widgets/0` filters by `module_enabled?` which calls `module_name.enabled?()` — but that's `PhoenixKit.Module.enabled?/0`**, which checks settings, not discovery state. Document the distinction or use `ModuleDiscovery` consistently.

18. **`Dashboard.Widget.Layout.changeset/2` allows `:user_uuid` in cast but also does `belongs_to :user` with foreign_key `:user_uuid`** — redundant. Prefer `put_assoc(:user, user)` in the context function, or keep it but explicit.

## NITPICK

19. Double-alias and extra whitespace in `index.ex:8` (`alias  PhoenixKit.Users.Auth.Scope` has two spaces).
20. `dashboard/layout.ex` has two `import` statements in the middle of the module (line 42: `import Ecto.Query`) — move to the top with `@doc` boundaries preserved.
21. Trailing comma after `h: Map.get(attrs, :h, 2),` on line 60 inside a struct literal — will compile, but unusual style.
22. Empty `priv/templates/test_*.ex` files with a handful of lines — purpose unclear; if they're fixtures for future tests, add a README or remove.

## GOOD

- Progress from first review is real and in the right direction.
- The Widget struct with `order`, `enabled`, `module`, and `component_props` is a clean discovery contract.
- Using `ModuleDiscovery.discover_external_modules()` is the right plug-in seam.
- GridStack choice is sensible — widely used, MIT-licensed, well-suited to this UX.
- The mix task scaffolds most of what a user needs (live view, hooks, config update).

## Recommended next steps (in priority order)

Given the author's situation, here's the tightest path to a mergeable PR:

1. **Just make it compile.** Fix the template string-replacement bugs (quote `@page_title`), remove `get_session`/`put_session`, and resolve the warnings. That alone gets CI green.
2. **Fix V97.down and the schema's missing `timestamps()`** — these are 3-line fixes that unblock rollback and CRUD.
3. **Fix `widgets_for/1` to query by `user_uuid`** and align the `conflict_target` + unique index name with the changeset.
4. **Delete `phoenix_kit.iml` and add it to `.gitignore`.**
5. **Delete or rewrite the tests** in `test/phoenix_kit/widgets/loader_test.exs` to reference `PhoenixKit.Utils.Widget`.
6. **Revert the `mix.exs` version bump** (main is already at 1.7.96).

After that, the remaining HIGH items (access control, grid `data-id`/`data-uuid` mismatch, duplicate hook file) can go in a follow-up PR. If pairing would help, happy to do that — ping in the thread.
