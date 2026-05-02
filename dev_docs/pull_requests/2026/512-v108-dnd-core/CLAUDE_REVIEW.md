---
pr: 512
title: Add V108 + drag-and-drop core + PR #506 review follow-up
author: mdon
merged_at: 2026-05-02T08:12:42Z
reviewer: claude
verdict: APPROVE
---

# Review — PR #512

Four commits, four independent concerns:

1. **V108 migration** — `position integer DEFAULT 0` on three list
   tables (`phoenix_kit_entities`, `phoenix_kit_cat_catalogues`,
   `phoenix_kit_cat_items`) so admin lists can persist user-driven
   order.
2. **DnD core infra** — `<.draggable_list>` `:draggable` opt-out,
   `<.table_default>` `:on_reorder` / `:reorder_scope` /
   `:reorder_group` / `:item_id` attrs, `SortableGrid` cross-
   container drop + scope spread, `TableCardView.updated()`.
3. **AGENTS.md TODOs** — flags the
   `test/phoenix_kit_web/components/core/` coverage gap C12 surfaced.
4. **PR #506 follow-up** — closes both NITPICKs from the merged
   arity-2 `dynamic_children` review (test-only delegate +
   `@typedoc`).

The schema add is straightforward and copies V107's pattern verbatim
(prefix-aware, `IF NOT EXISTS`, marker-comment flip on up/down). The
DnD changes are purely additive — every new branch is gated on a new
attr that defaults to "off"/`true`-keeping-prior-shape, so existing
call sites are untouched. The PR #506 follow-up is the most
substantive correctness improvement: the previous test invoked
anonymous functions and asserted Elixir's call semantics; the new
suite reaches the actual private dispatcher via a `@doc false`
delegate and pins the four real contracts (arity-1, arity-2, nil
locale, return propagation).

`@current_version` correctly bumps 107 → 108 in
`postgres.ex:800`. Test migration wrapper
(`test/support/postgres/migrations/20260316000000_add_phoenix_kit.exs`)
calls `PhoenixKit.Migrations.up()` which auto-includes V108, so the
schema add is implicitly verified by every DB-touching test on every
run — same convention as V107.

## Findings

### NITPICK — `:reorder_scope` key transformation isn't documented

`build_sortable_scope_attrs/1` in `table_default.ex:283` lower-cases
the key and replaces underscores with dashes, then writes
`data-sortable-scope-<dashed>`. On the JS side
(`phoenix_kit.js:248`), `readScope` strips the `sortableScope`
prefix and lowercases the first letter of the remaining DOMStringMap
key. Net effect:

| Elixir map key   | DOM attr                           | JS payload key  |
|------------------|------------------------------------|-----------------|
| `:category_uuid` | `data-sortable-scope-category-uuid`| `categoryUuid`  |
| `:user_id`       | `data-sortable-scope-user-id`      | `userId`        |

Consumers writing the LV handler will receive **camelCase** keys, not
the original snake_case Elixir keys they passed in. This is a real
gotcha for anyone who follows `params["category_uuid"]` instinct,
and the current `:reorder_scope` doc just says "Map of scope values
exposed on the card-view container as data-sortable-scope-* attrs"
— silent on the camelCase round-trip.

**Suggestion:** add one line to the attr `:doc` covering it. E.g.
"Keys are lowercased and dasherized for the DOM attr; the JS hook
sends them back as camelCase (`category_uuid` → `categoryUuid`).
Pattern-match accordingly."

### NITPICK — `<.table_default>` footer DOM shape changes for non-DnD callers

The `card_actions` slot used to render directly inside
`<div class="card-actions justify-end ...">`. Now it's wrapped one
level deeper inside `<div class="card-actions justify-between ...">
  <div class="flex gap-2 ml-auto">{slot}</div>`. Visually equivalent
(`ml-auto` keeps actions right-aligned), but:

- Any consumer with CSS like `.card-actions > button { ... }` loses
  the descendant match because the buttons are now grandchildren.
- The new wrapper adds `gap-2` on top of daisyUI's `card-actions`
  default `gap: 0.5rem` — same `gap-2` value, but now compounded by
  the inherited `.card-actions` setting on the outer container. In
  practice the wrapper's `gap-2` wins (closest ancestor flex
  container), so spacing is unchanged.
- Testing selectors via `Floki` / `:test-id` that walked the DOM
  with `> .btn` would need to switch to `.btn` (descendant).

This is a non-DnD callers' side-effect of unifying the footer
layout. Probably zero in-tree impact, but it's a DOM-shape change
introduced by an attr opt-in. Worth a code comment near the footer
row, or the description in the moduledoc.

### NITPICK — `:on_reorder` only wires the card view; table-view's tbody is the consumer's job

The `:doc` calls this out: *"The table-view's tbody is owned by the
inner_block — wire that side separately."* Sound design — the
component can't synthesize a `<tbody>` it doesn't own. But it
creates an asymmetry: a desktop user toggled into the table view
gets **no** drag-and-drop unless the consumer also attached
`SortableGrid` to the `<tbody>` themselves. Mobile (cards) works,
desktop (table) doesn't.

Possible improvements (out of scope for this PR):
- A second component, `<.table_default_body :sortable=...>`, that
  internally renders `<tbody phx-hook="SortableGrid">` with the same
  scope/group attrs.
- A `:tbody_id` attr that the consumer uses to opt their table-side
  in.

For now: a sentence in the moduledoc near the existing card/table
toggle doc explaining the asymmetry would save consumers the
discovery time.

### NITPICK — `__invoke_dynamic_children_for_test__/3` is a public API

```elixir
@doc false
def __invoke_dynamic_children_for_test__(fun, scope, locale),
  do: invoke_dynamic_children(fun, scope, locale)
```

`@doc false` keeps it out of ExDoc but doesn't make it private — any
runtime caller can invoke it. The `__name__` convention (used in
Elixir stdlib for compile-time-only helpers like `__info__/1`) is a
defensible signal, but a strict reading would prefer:

- Coverage via the public render path (`render_component/2` against
  `admin_sidebar/1` with a known scope), or
- `:erlang.apply/3` over a function captured from the module's
  `__info__(:functions)` (gross, requires loosening
  `mix credo`'s `Credo.Check.Warning.UnsafeExec` if applicable).

The current trade-off is fine: it keeps the test fast and DB-free,
and the `@doc false` + comment block above documents intent. NITPICK
because someone strict about the runtime API surface might want
this hidden behind compile-time gating (e.g.
`if Mix.env() == :test, do: def …`) — and that comes with its own
trade-offs.

### NITPICK — `<.draggable_list>` strips `data-id` when `@draggable=false`

```heex
data-id={if @draggable, do: @item_id_fn.(item)}
```

When `@draggable` is false, `data-id` is omitted entirely. That
matches the "no DnD" intent on the SortableJS side, but `data-id`
can be useful even without DnD — for click-to-select UIs, integration
test selectors, JS that reads the source-of-truth id off the
element. Stripping it on the falsy path is more aggressive than
needed.

**Suggestion:** keep the `data-id`, drop only the `class` and
`phx-hook`. Alternatively, document that `data-id` requires DnD —
which is currently true but not stated.

### IMPROVEMENT-LOW — V108 sort stability before any drag

All three new `position` columns default to `0`. Until a user drags,
every row in a list shares the same position. `ORDER BY position`
returns rows in PG-implementation-defined order (i.e., undefined and
not stable across query plans). The PR body says *"the LV reorder
handlers re-index the visible group to 1..N on the first user drag,
so the default is only ever observed transiently"* — true for users
who actually drag, but every fresh deploy and every newly inserted
row sit at `0` until they're touched.

The downstream LV consumers should be sorting `ORDER BY position
ASC, inserted_at DESC` (or `, uuid ASC`) so that ties resolve to a
stable, user-friendly order pre-reorder. This is a downstream
concern — V108's job is just the column — but worth verifying when
you wire up the actual list LV (catalogue / entities). Flagging
because the migration's "stable on identical timestamps" claim
isn't actually backed by anything in the schema.

## Things done well

- **Idempotent V108.** `ADD COLUMN IF NOT EXISTS` matches V107; safe
  to re-run mid-migration. `down/1` reverses columns in opposite
  order (cat_items → cat_catalogues → entities), which is good
  practice when there are no FK dependencies but better to follow
  the convention anyway.
- **`:draggable` defaults to `true`.** Every existing
  `<.draggable_list>` call site is unchanged.
- **`:on_reorder` defaults to `nil`.** Every existing
  `<.table_default>` call site renders the same footer (justification
  changes from `justify-end` to `justify-between`, but visual output
  via `ml-auto` is identical).
- **`try/catch` around `onEnd`.** Defensive against the exact
  failure modes the inline comment describes (corrupt scope attr,
  fast unmount). Prevents SortableJS from getting wedged.
- **`TableCardView.updated()`.** Catches a real bug — without it,
  any LV diff that re-renders the wrapper resets the card/table
  toggle's runtime `md:hidden` classes back to template defaults.
  This was almost certainly a SortableJS-drop-causes-view-snap
  regression observed during catalogue work.
- **Cross-container scope payload.** `from*` prefix for the source
  container's scope is a clean convention for distinguishing source
  vs destination context; the destination container owns the event
  routing.
- **PR #506 follow-up tests.** Four assertion-pinned tests using
  `assert_received` actually exercise the dispatcher — replacing the
  half-tautological `:counters` setup that just verified Elixir's
  call semantics. The `@typedoc` replacement is exactly the right
  fix for the inline `#` comment.
- **AGENTS.md TODOs.** Surfacing the component-coverage gap as a
  workspace TODO instead of either (a) skipping it silently or
  (b) shoehorning a single fixture into an empty test dir alongside
  a feature PR is the right call.

## Out of scope (worth tracking)

These came up while reading the diff but don't belong in this PR:

- **Component test coverage** — already in the new TODOs section.
  When that sweep happens, the `:reorder_scope` round-trip docs
  finding above is a perfect candidate for a rendered-HTML
  assertion: `assert html =~ "data-sortable-scope-category-uuid="`.
- **Documentation for the camelCase scope round-trip.** Independent
  doc tweak; could land as a follow-up commit on `dev`.
- **List sort stability tiebreakers.** Verify the LV consumers
  (catalogue / entities / cat_items) sort with a deterministic
  tiebreaker after `position`. This is a behavior issue surfacing
  in the consumer LVs, not a V108 problem.

## Verdict

**APPROVE.** The schema add is mechanical and follows the established
versioned-migration pattern. The DnD primitives are well-scoped (one
opt-in per feature, defaults preserve current behavior), and the
SortableGrid hook changes solve real cross-container needs without
breaking single-container consumers. The PR #506 follow-up genuinely
upgrades the test from "I called a function" to "I exercised the
dispatcher and pinned the contract."

The findings above are all NITPICKs / LOW improvements — none gate
the merge.
