# PR #506 — Support arity-2 dynamic_children callback with locale
**Author:** Max Don (mdon)
**Reviewer:** Claude
**Date:** 2026-04-24
**Verdict:** ✅ APPROVE

---

## Summary

Extends `PhoenixKit.Dashboard.Tab.dynamic_children_fn` from `(scope -> [tab])` to also accept `(scope, locale -> [tab])`. The admin sidebar dispatches on arity at render time, threading `assigns[:locale]` into the 2-arity variant. Backwards-compatible: every existing 1-arity callback keeps working unchanged.

Motivation: plugins like `phoenix_kit_entities` render translated plural labels in sidebar children. With the 1-arity callback they had to read `Gettext.get_locale(PhoenixKitWeb.Gettext)` at render time — implicit state pulled from the process dictionary. Passing locale explicitly makes the contract clearer and decouples plugins from Gettext process state.

## Files Changed (3)

| File | Change |
|------|--------|
| `lib/phoenix_kit/dashboard/tab.ex` | +9 / -1 — `dynamic_children_fn` type union |
| `lib/phoenix_kit_web/components/dashboard/admin_sidebar.ex` | +15 / -5 — arity dispatch in `invoke_dynamic_children/3` |
| `test/phoenix_kit_web/components/admin_sidebar_dynamic_children_test.exs` | +86 — new test file |

## Green flags

- **Zero-risk extension.** The type is a union: `(scope -> [tab]) | (scope, locale -> [tab]) | nil`. Every call site using the 1-arity form stays valid. The `Enum.split_with` gate matches both arities with `is_function(fun, 1) or is_function(fun, 2)`, and `invoke_dynamic_children/3` dispatches on arity via `is_function/2` guards. No hidden coupling.
- **Explicit over implicit.** Replacing `Gettext.get_locale/1` at render time with an explicit parameter is the right direction — process-dictionary reads are exactly the "implicit state" the elixir-thinking skill flags.
- **Nil-safe.** The 2-arity path passes `assigns[:locale]`, which can be `nil` (the component declares `attr :locale, :string, default: nil`). The `dynamic_children_fn` type reflects this with `String.t() | nil`. Consumers need to handle a `nil` locale, which is fine for the documented use case (Gettext-driven label lookup falls back to the default locale).
- **Error path preserved.** The existing `try/rescue` in `expand_dynamic_children/3` still wraps the invocation, so a broken 2-arity callback is logged and returns `[]` — same safety as the 1-arity path.
- **Useful WHY comments.** The "Dispatches on arity so modules can opt in…" comment above `invoke_dynamic_children/3` captures the intent succinctly without restating WHAT the code does.

## Findings

### NITPICK — Test coverage is half-tautological

File: `test/phoenix_kit_web/components/admin_sidebar_dynamic_children_test.exs`

The first `describe` block ("dynamic_children_fn type") is load-bearing: it proves `Tab.new!/1` accepts both arities. Good.

The second `describe` block ("invoke_dynamic_children/3 dispatch") admits up front it can't reach the private helper, then defines two anonymous functions, invokes them directly with `.(%{})` and `.(%{}, "en-US")`, and asserts the counters incremented. That doesn't test the sidebar's dispatch at all — it tests Elixir's function-call semantics. Per the elixir-thinking skill: *"Test your code, not the framework."*

Two ways to make it test the actual code:
1. Render the sidebar component with both 1- and 2-arity `dynamic_children` callbacks (via `Phoenix.LiveViewTest.render_component/2` + counter in process dictionary) and assert each receives the correct args.
2. Make `expand_dynamic_children/3` public — it's effectively a pure function — and call it directly with a fixture list of tabs.

As-is, the block gives a false sense of coverage; the PR description lists "New unit tests pass" as a test-plan item, but the dispatch test proves nothing new. Small gap given the tiny surface area, but worth a follow-up.

### NITPICK — Add `@typedoc` to `dynamic_children_fn`

`dynamic_children_fn` is documented purely in an inline comment above the `@type`. Adding a `@typedoc` surfaces the contract in ExDoc and `h Tab`:

```elixir
@typedoc """
A callback that produces the children of a parent tab at render time.
Arity 1 receives the current scope; arity 2 also receives the locale so
modules can render translated labels without reading Gettext process state.
"""
@type dynamic_children_fn ::
        (map() -> [t()])
        | (map(), String.t() | nil -> [t()])
        | nil
```

## Red flags

None.

## Verdict

**APPROVE.** Clean, narrowly-scoped API extension with full backwards compatibility. The test weakness is a minor follow-up, not a merge blocker. The change pairs naturally with the `phoenix_kit_entities` companion PR that actually consumes the 2-arity form.
