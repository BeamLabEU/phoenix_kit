# PR #1004 — Fix the avatar menu's account row running past the menu's edge

**Author:** mdon · **Reviewer:** Claude · **Verdict:** approve, one test hardened

`admin_nav.ex` and `user_dashboard_nav.ex`: the account-row `<li>` gets `min-w-0 flex-nowrap`, the row
`w-full`. New source-level test `test/phoenix_kit_web/components/account_menu_row_test.exs`.

## Checked and sound

- **Diagnosis.** daisyUI 5's `.menu li` is a wrapping column flex; a wrapped flex line is as wide as its
  widest item, so `truncate`/`min-w-0` inside the row could not shrink it. `flex-nowrap` + `w-full`
  constrains the line to the menu's width. Both copies of the markup are changed identically.
- **Other rows.** The language list (`!p-0 block w-full … overflow-x-hidden`) was already constrained.
  The organization switcher (`Core.OrganizationSwitcher`, added later on main) renders plain wrapping
  text in a `w-full` button, so it wraps rather than overflows.
- **Tailwind classes** are ordinary utilities the host's scan of `deps/phoenix_kit` already emits.

## Findings

- **NITPICK — the test matched the exact indentation (fixed).** It asserted
  `~s(<li ...>\n                <div ...)` with sixteen literal spaces, so re-indenting the template
  (a wrapper added around the `for`, or `mix format` of a HEEx change) would fail it with no change in
  behaviour. Now a regex with `\s*` between the two tags.
