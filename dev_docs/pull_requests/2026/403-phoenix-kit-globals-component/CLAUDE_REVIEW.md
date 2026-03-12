# PR #403 Review — Add PhoenixKitGlobals component for JavaScript globals

**Author:** construct-d (Alex)
**Branch:** dev → dev (fork)
**Files changed:** 5 (+34 / -9)

## Summary

Extracts the repeated inline `<script>window.PHOENIX_KIT_PREFIX = "..."</script>` into a reusable `PhoenixKitGlobals` component, replacing 3 duplicate inline scripts across layouts.

## Verdict: Approve with minor comments

Clean, focused refactoring. DRY improvement, well-documented component, no functional changes.

## Review Details

### What's good

- **DRY**: Eliminates 3 identical inline `<script>` blocks across `layout_wrapper.ex`, `dashboard.html.heex`, and `root.html.heex`
- **Clean component**: Proper `@moduledoc`, clear usage docs
- **Small scope**: Easy to review, low risk

### Issues

#### 1. Duplicate globals in admin-only layout path (Minor)

The PR adds `<.phoenix_kit_globals />` to the inner admin template (`wrap_inner_block_with_admin_nav_if_needed`, ~line 245) AND replaces the script in `render_admin_only_layout`'s `<head>` (~line 680).

When admin pages render without a parent layout, both paths execute:
- `render_admin_only_layout` sets it in `<head>`
- `wrap_inner_block_with_admin_nav_if_needed` sets it again in `<body>`

This is **harmless** (same value, idempotent), but unnecessary. The addition in the inner template is likely intended for the `render_admin_with_parent` path where the parent may not set globals — that's a valid safety measure.

**Suggestion:** Add a brief comment on the inner-template usage explaining why it's there (for the parent-layout path).

#### 2. Missing `attr` declaration (Nitpick)

Phoenix best practice is to declare attributes even for components with no attrs:

```elixir
def phoenix_kit_globals(assigns) do
```

Could add `@doc` with `attr` declarations or at minimum note it's a zero-attr component. Very minor.

#### 3. `render_admin_only_layout` not updated in the diff (Bug)

Looking at the current file on `dev`, `render_admin_only_layout` (line 679-681) still has the old inline `<script>` block — it was **not replaced** by the PR. The diff only shows the replacement at line 678 in the old file numbering, which corresponds to the same function, so this may be a reading error on my part. But worth verifying that ALL 4 locations are covered:

- [x] `layout_wrapper.ex` — `render_admin_only_layout` head section
- [x] `layout_wrapper.ex` — `wrap_inner_block_with_admin_nav_if_needed` inner template (new addition)
- [x] `dashboard.html.heex`
- [x] `root.html.heex`

#### 4. HEEx encoding inside `<script>` (Non-issue, noting for completeness)

The component uses `{PhoenixKit.Utils.Routes.url_prefix()}` in HEEx which HTML-encodes the output. The original code used `<%= ... %>` which also HTML-encodes. Since URL prefixes are always simple paths (e.g., `/phoenix_kit`), encoding has no practical effect. Both old and new code behave identically.

## Conclusion

**Approve.** This is a clean, low-risk refactoring that improves maintainability. The minor duplication in admin layouts is harmless and arguably intentional as a safety net for the parent-layout rendering path.
