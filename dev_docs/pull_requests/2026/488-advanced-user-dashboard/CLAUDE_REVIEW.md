# PR #488 — Advanced User Dashboard

**Author:** @mithereal · **Branch:** `main` → `main` · **Files:** 16 (+2064 / −18)

## Summary

Adds a widget-based user dashboard: a `PhoenixKit.Widgets` namespace (loader/registry/widget struct), a `PhoenixKit.Dashboard.Layout` Ecto schema + v97 migration, a GridStack LiveComponent, a placeholder billing widget, a 650-line stylesheet, a mix generator `phoenix_kit.gen.user.dashboard.advanced`, and an unrelated guide + IntelliJ project file.

## Overall verdict

**Do not merge as-is.** The concept (module-contributed widgets on a draggable grid) is a reasonable addition, but the implementation has a data-loss-level migration bug, multiple files that don't compile or don't integrate with existing PhoenixKit systems, and significant scope creep. Most of this reads as an early prototype / AI-assisted scaffold rather than production code.

## Findings

### BUG — CRITICAL

- **`lib/phoenix_kit/migrations/postgres/v97.ex` `down/0` is catastrophically wrong.** It drops `phoenix_kit_files`, `phoenix_kit_media_folder_links`, `phoenix_kit_media_folders` and resets the schema comment to `'94'`. These tables belong to the media/v94 migration and have nothing to do with dashboard layouts. Running a rollback would destroy user media data. This looks copy-pasted from another migration and was never edited.
- **Schema/table name mismatch.** `PhoenixKit.Dashboard.Layout` has `schema "dashboard_layouts"` but the migration creates `phoenix_kit_dashboard_layouts`. The schema cannot query the table as written.
- **`lib/phoenix_kit_web/live/dashboard/index.ex` returns `{:error, :not_authenticated}` from `mount/3`.** That is not a valid `mount` return shape — LiveView will crash for unauthenticated users. Should redirect via `Routes.path/1` or rely on the existing `phoenix_kit_current_scope` assign already set by the on-mount hook (which this code ignores in favor of reading `session["phoenix_kit_current_user"]`, a key that doesn't exist in PhoenixKit's session).

### BUG — HIGH

- **`Layout` schema violates project convention.** Project rule: `@primary_key {:uuid, UUIDv7, autogenerate: true}`. This schema uses the default integer `:id` primary key, has a stray `widget_uuid` `:binary_id` column, and declares `belongs_to :user_uuid, ..., type: :binary_id` (wrong association name and wrong type — should be `UUIDv7`). No `timestamps()`. No unique constraint on `(user_uuid, widget_uuid)`. No index on `user_uuid`. FK is `on_delete: :nothing` — layouts will orphan when users are deleted.
- **Migration primary-key shape is wrong.** `create table(..., primary_key: false)` + `add :widget_uuid, :uuid, primary_key: true` makes `widget_uuid` the PK, so a user can only ever have one layout row for a given widget globally — not per-user. The PK needs to be either a synthetic `uuid` PK or the composite `(user_uuid, widget_uuid)`.
- **Hardcoded `/admin/modules` path in dashboard index** violates the explicit CLAUDE.md rule to use `Routes.path/1` / `<.pk_link>`.
- **`Widgets.Loader` hardcodes `@known_modules`** and ignores the existing `PhoenixKit.ModuleDiscovery` beam-scanning infrastructure that everything else in the project uses. New external modules will silently not contribute widgets. The `user_can_access_module?/2` helper also always returns `true` — permission check is a stub.
- **`Widgets.Registry` GenServer is never started** (not added to any supervision tree) and never called from anywhere. Dead code that will crash on first use.
- **`RevenueComponent` renders an empty `<div>`.** The PR description claims "updated the billing module to reflect the changes" but no billing logic is wired up.
- **`GridStackDashboardComponent` contains `IO.inspect` calls** in `handle_event/3` with placeholder comments instead of persistence — save + remove are no-ops that log to stdout.

### BUG — MEDIUM

- **`Logger.warn/1` is deprecated** (`loader.ex:90`). Use `Logger.warning/1`.
- **`Enum.flat_map(fn w -> List.wrap(w) end)` after `List.wrap/1`** in `loader.ex` is redundant.
- **HEEx `id={"gridstack-dashboard-#{@id}"}`** — string interpolation inside HEEx attrs works but is discouraged in recent LV; prefer `id={"gridstack-dashboard-" <> @id}` or `{@id}` interpolation conventions used elsewhere in this repo.
- **Dashboard index loses gettext and the existing `<.user_dashboard_header>` component**, regressing i18n and header consistency.

### IMPROVEMENT — HIGH

- **Scope creep:** the PR ships three unrelated artifacts that should be separate PRs or dropped:
  1. `guides/landing-page-unauthenticated.md` — AI-generated advice doc with emoji checkmarks, unrelated to the dashboard feature and partly incorrect (raw `get_session(conn, "user_token")` instead of using the documented scope).
  2. `phoenix_kit.iml` — IntelliJ/RubyMine module file. Should be gitignored, not committed.
  3. `scripts/install_dashboard.sh` — overlaps the mix generator; unclear which is canonical.
- **`priv/static/assets/dashboard_widgets.css` (650 lines)** uses hardcoded hex colors (`#0066cc`, `#fafbfc`, gradients) and bypasses daisyUI 5 theme tokens that the rest of PhoenixKit is built on. Breaks dark mode and custom themes. Should use daisy/Tailwind utility classes.
- **Mix task `phoenix_kit.gen.user.dashboard.advanced`** is fragile:
  - Patches the user's `assets/js/app.js` by string-concatenation (not idempotent across updates, no import ordering guarantee).
  - Runs `npm install gridstack` unconditionally as a side effect of `mix`.
  - Injects into the parent router via line-scanning regex — will mis-inject on any non-trivial router shape.
  - **Targets `live_session :authenticated`, but PhoenixKit's session is `:phoenix_kit_admin` (and user routes use other named sessions).** The injection will never match in a real PhoenixKit-hosted app, so the generated route never gets wired up.
  - Generated registry template scans `:code.all_loaded()` and calls `function_exported?/3` on every module — slow, duplicates `ModuleDiscovery`.
  - `return_ok()` helper is a workaround for an `if/else` with mismatched return types — just return `:ok` in both branches.
  - No tests for the task.

### IMPROVEMENT — MEDIUM

- The PR introduces `PhoenixKit.Widgets.*`, `PhoenixKit.Dashboard.*`, and `PhoenixKitWeb.Widgets.*` namespaces without clarifying the boundary with the existing `lib/phoenix_kit/dashboard/` (which already has README.md documented in CLAUDE.md).
- `load_all_widgets/0` recomputes on every mount. Consider `:persistent_term` or compile-time cache given the module list is static.
- `Widget.enabled` defaults to `true` while layout `enabled` defaults to `false` — confusing dual meaning.
- `test/phoenix_kit/widgets/loader_test.exs` exists (unread here) but there's no test for the mix task, the migration, the schema, or the GridStack component.

### NITPICK

- Migration's `prefix_str/1` helper is duplicated across v-migrations; there's likely a shared helper already.
- `lib/phoenix_kit_web/live/widgets/billing/revenue_component.ex` — `mount/1` and `update/2` without `@impl true`.
- `dashboard_widgets.css` uses `background: linear-gradient(...#c3cfe2)` as a page background — overrides whatever theme the parent app picked.
- PR opened from the author's `main` branch to upstream `main`; branch hygiene suggests a feature branch.

## Recommendation

Request changes. Minimum to land:

1. Rewrite `V97.down/0` to only drop `phoenix_kit_dashboard_layouts` and restore comment to `'96'`. **(blocker — data loss risk)**
2. Fix schema/table name mismatch and PK shape; conform to UUIDv7 convention; add indexes + FK `on_delete: :delete_all`.
3. Fix `mount/3` return and use `phoenix_kit_current_scope` + `Routes.path/1`.
4. Replace hardcoded module list with `PhoenixKit.ModuleDiscovery`; implement real permission check or delete the stub.
5. Either wire up the `Registry` GenServer or delete it.
6. Remove `phoenix_kit.iml`, the landing-page guide, and decide between shell script vs mix task.
7. Replace custom CSS with daisyUI/Tailwind, or gate it behind an opt-in flag.
8. Fill in `RevenueComponent` or drop it.
9. Replace `IO.inspect` with real persistence in GridStack component.

Once those land, this becomes a reasonable second pass on the user dashboard.
