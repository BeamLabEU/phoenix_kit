# Follow-up Items for PR #506 (Support arity-2 dynamic_children callback with locale)

PR #506 extended `Tab.dynamic_children_fn` from `(scope -> [tab])` to
also accept `(scope, locale -> [tab])`. Merged 2026-04-24. The
CLAUDE_REVIEW.md verdict was APPROVE with two NITPICKs; both are
closed in this batch.

## Fixed (Batch 1 — 2026-05-02)

- ~~**Test coverage half-tautological**~~ — the original
  `"invoke_dynamic_children/3 dispatch"` describe block defined two
  anonymous functions and called them with `.(%{})` and
  `.(%{}, "en-US")`, asserting the counters incremented. As the
  reviewer noted, that tested Elixir's function-call semantics, not
  the sidebar's dispatch.

  Fix: added a `@doc false` test-only delegate
  `AdminSidebar.__invoke_dynamic_children_for_test__/3` that calls
  the private `invoke_dynamic_children/3` so the test exercises the
  actual dispatcher. Rewrote the describe block with four
  assertion-pinned tests:

  - arity-1 callback receives only the scope (`assert_received`
    confirms the scope reaches the function),
  - arity-2 callback receives both scope and locale,
  - arity-2 callback handles a nil locale,
  - the callback's return value is propagated to the caller.

  Files: `lib/phoenix_kit_web/components/dashboard/admin_sidebar.ex`,
  `test/phoenix_kit_web/components/admin_sidebar_dynamic_children_test.exs`.

- ~~**Add `@typedoc` to `dynamic_children_fn`**~~ —
  `lib/phoenix_kit/dashboard/tab.ex:120` had an inline `#` comment
  that wasn't picked up by ExDoc / `h Tab`. Replaced with a
  `@typedoc` block covering the two arities, the explicit-locale
  rationale, and the `nil` semantic.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit/dashboard/tab.ex` | Inline `#` comment on `dynamic_children_fn` promoted to `@typedoc` |
| `lib/phoenix_kit_web/components/dashboard/admin_sidebar.ex` | Added `@doc false` `__invoke_dynamic_children_for_test__/3` delegate |
| `test/phoenix_kit_web/components/admin_sidebar_dynamic_children_test.exs` | Rewrote the dispatch describe block with four assertion-pinned tests via the new delegate |

## Verification

- `mix format --check-formatted` clean
- `mix compile --warnings-as-errors` clean
- `mix credo --strict` (over the touched files): 116 mods/funs, 0
  issues
- `mix test test/phoenix_kit_web/components/admin_sidebar_dynamic_children_test.exs`:
  **6 tests, 0 failures** (2 from the original `dynamic_children_fn
  type` describe + 4 new dispatch tests)

## Open

None.
