# PR #659 — Move admin_page_header's back affordance inline beside the title

**Author:** mdon (Max Don)
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-21
**Verdict:** ✅ APPROVE — no fixes needed.

---

## Summary

`<.admin_page_header back={...}>` previously rendered the back arrow as a
bare ghost button on its own row above the title/subtitle cluster. This PR
moves it inline, as a circular icon chip aligned to the title's first line,
inside the same flex row as the title (`items-start`, not `items-center`,
since the icon now needs to align to line one of a potentially
multi-line/rich title rather than vertically center against it).

- Icon-only (no `back_label`): plain `btn-circle` chip, always.
- Labeled (`back_label` set): circle only below the `sm` breakpoint
  (`max-sm:btn-circle`), where the label `<span>` is `hidden sm:inline` —
  so mobile never shows a stretched pill.
- A blank string `back_label=""` is normalized to `nil` before render — Elixir
  treats `""` as truthy, so without this guard a blank label would flip the
  component into "labeled" mode with an empty `aria-label`/`title`.
- `aria-label` and a `title` tooltip are set unconditionally
  (`@back_label || gettext("Back")`), so icon-only mode still has an
  accessible name and a hover hint.
- The container uses `gap-x-2`, deliberately not `gap-2` — the moduledoc/inline
  comment documents a real, verified gotcha: core's shipped `app.css` carries
  an unlayered mobile rule (`.flex.gap-2 > .btn { width: 100% }` at ≤768px)
  that would stretch the new inline chip full-width on phones. Layered
  Tailwind utility classes can't win against an unlayered rule, so the fix is
  to keep `gap-2` off the selector's reach entirely rather than try to
  override it. This is pinned by a dedicated test
  (`refute result =~ ~s(class="flex items-start gap-2 min-w-0")`).
- No public API change — `back`/`back_label`/`back_click` attrs are unchanged;
  all 8 existing call sites (`user_details`, `media_detail`,
  `integration_form`, and the 5 storage-module pages) render the new anatomy
  as-is, several of them exercising the `back` + rich `inner_block` title
  combination the test suite also covers.

## Files Changed (2)

| File | Change |
|---|---|
| `lib/phoenix_kit_web/components/core/admin_page_header.ex` | +37/−13 — inline layout, `""`→`nil` normalization, doc updates |
| `test/phoenix_kit_web/components/core/admin_page_header_test.exs` | +75 (new) — 8 render tests |

## Review Notes

- Verified against all 8 real call sites in `lib/` (`rg -n "admin_page_header"`)
  — every one passes only `back`/`back_label`/`title`/`subtitle`/`inner_block`,
  none depends on the old standalone-row DOM shape or on `gap-2` on the
  wrapper div, so nothing breaks silently.
- The `gap-x-2` legacy-CSS workaround is exactly the kind of undocumented
  landmine that's easy to reintroduce by "simplifying" back to `gap-2` in a
  future edit; the inline comment + the dedicated `refute` test both guard
  against that regression, which is the right amount of defense for a footgun
  that isn't visible from the Tailwind classes alone.
- New tests are well-targeted and actually pin behavior (DOM position of the
  back link relative to the title row via `:binary.match` offsets, circle vs.
  labeled class variants, the blank-`back_label` edge case) rather than just
  asserting the happy path.
- No functional/security/correctness issues found. This is a scoped,
  well-tested visual/layout change with no data-path or access-control
  surface.

## Gate

`mix precommit` (format + compile --warnings-as-errors + credo --strict +
dialyzer) — clean, no issues.
