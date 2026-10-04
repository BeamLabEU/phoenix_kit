# PR #901: Core-owned sidebar order for module tabs, host `:admin_tab_order`, id tie-breaks

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `2710c9620` and earlier (merge `4a1d5b589`)
**Date**: 2026-10-03 (merged 2026-10-04)

## Goal

Module tabs picked their own priorities: the daily-work modules ended up at the bottom of the
sidebar and many tabs tied (650 ×7, 645 ×4 …), so their order followed an ETS set. Core now owns
the order of known module tabs, a host can override it with `config :phoenix_kit, :admin_tab_order`,
and ties break by id. A second fix: parents with `dynamic_children` were drawn last in their
group whatever their priority.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit/dashboard/admin_tabs.ex` | `@module_tab_order` (31 ids → priority, optional group), `module_tab_order/0`, `apply_module_tab_order/1` used by `module_tabs/0` (top-level tabs only) |
| `lib/phoenix_kit/dashboard/registry.ex` | `admin_tab_order/0` (defensive config parsing), `apply_admin_tab_order/1` on defaults, `register/2`, host `:admin_dashboard_tabs`, legacy categories and subsections; unknown group → warning + dropped; `sort_tabs/1` ties by `to_string(id)` |
| `lib/phoenix_kit_web/components/dashboard/admin_sidebar.ex` | `expand_dynamic_children/3` keeps parents in place (`tabs ++ dynamic_children`) |
| `ADMIN_README.md`, 3 test files | docs; table invariants; registry end-to-end through a started registry; dynamic-children order |

## Verification

- **Table ids exist.** Every id in `@module_tab_order` was matched against the sibling packages'
  `%Tab{id: …}` (catalogue, warehouse, manufacturing, projects, document_creator, crm, staff,
  billing, newsletters, ecommerce→`:admin_shop`, entities, db, posts, comments, publishing,
  emails, user_connections→`:admin_connections`, referrals, customer_support, ai, sync, boards,
  calendar, inbox, stats, dashboards, bookings, open_graph→`:admin_phoenix_kit_og`,
  web_analytics, locations). A typo would be a silent no-op; none found. `:admin_notifications`
  is core's own.
- **Priorities are unique inside the table** and the `:admin_main` entries (151–157, 210) fall
  between Dashboard (100)/Users (200) and Media (300); `admin_sidebar` finds subtabs by
  `parent` id across all tabs (`get_subtabs_for(tab.id, all_tabs)`), so moving a parent to
  `:admin_main` while its subtabs keep `:admin_modules` does not orphan them.
- **No deadlock.** `known_group_only/2` calls `get_groups/0` from inside `handle_call({:register…})`;
  it is an ETS read behind `:ets.info/1`, not a `GenServer.call`. Good.
- **Hot path unchanged.** All application happens when tabs enter the registry; the sidebar
  render only gained a stable sort key.
- **Config is read at registry (re)build time** via `Application.get_env/3`, so `runtime.exs` works
  too (unlike `admin_path`, which is compile-time); the README states "applied on every rebuild".
- **Test state.** Both suites are `async: false` and restore every touched env key in `on_exit`;
  the registry suite starts and stops its own registry (`start_supervised!`) and refutes an
  already-running one.
- `expand_dynamic_children/3` now returns `tabs ++ dynamic_children`; the children were already
  last before, only the parents' position changed — what the commit message claims.

## Findings

No bugs.

- **IMPROVEMENT - MEDIUM** — a host's own sidebar group cannot be targeted by `:admin_tab_order`.
  `known_group_only/2` accepts only the three default groups plus whatever `get_groups/0` holds at
  that moment; at boot (`handle_continue(:initialize_tabs)`) host groups registered later through
  `Registry.register_groups/1` (which also *replaces* the `:groups` row,
  `registry.ex` `handle_call({:register_groups…})`) are not there yet, so
  `%{admin_x: %{group: :my_group}}` is dropped with the "not a sidebar group" warning for every
  boot-time path, and works only for tabs the host registers at runtime after its groups. The
  registry test hints at it (comment about "a core group is known at boot") but `ADMIN_README.md`
  does not. Fix: say so in the README ("only the three core groups at boot; a custom group is
  honoured for tabs registered after it"), or accept an unknown group when the host also lists it
  under its configured admin groups.
- **IMPROVEMENT - MEDIUM** — the order lives in a hardcoded table keyed by sibling-module tab id, so
  every new module needs a core release to be placed, and an unlisted tab keeps the module's own
  priority and can tie again (the example module `phoenix_kit_hello_world` is at 640, the same as
  `admin_ai`'s table value; ties now at least resolve by id). The test asserting "no two top-level
  tabs share a priority" runs against what core's test env loads (core tabs only), so it cannot
  see collisions with real sibling tabs. Consider a note in `external-module-development.md` that
  new modules should choose a priority not in `module_tab_order/0`, and/or a test that enumerates
  the table's own priorities against each other and against the core tabs' (partly done) plus a
  module-side CI check.
- **NITPICK** — `apply_module_tab_order/1` overrides a listed tab's priority/group
  unconditionally, so a module that later changes its own number is silently ignored. This is the
  intended "core owns it" design, documented in the moduledoc comment, but worth one sentence in
  the README for module authors.
- **NITPICK** — `Registry.sort_tabs/1` was `defp`, now `@doc false def` only so tests can call it;
  `admin_sidebar.ex` adds a second `__…_for_test__` delegate. Consistent with the file's existing
  habit.
- **NITPICK** — `level: :all` tabs are not touched by `:admin_tab_order` (only `level: :admin`);
  the docs say "admin tabs", and the test covers `:user`, but `:all` is unstated.

## Verdict

Approve as merged. The design is sound and well tested (registry round-trip through every
entry path, rebuild survival, defensive config parsing). The two MEDIUMs are documentation /
maintainability gaps, not defects.

## Resolution (2.52.0)

No bugs; no code change. The documentation items (custom groups cannot be targeted for boot-time tabs, the hardcoded
priority table needs a core release for a new module) stay on record. CHANGELOG entry added under 2.52.0 Added.
