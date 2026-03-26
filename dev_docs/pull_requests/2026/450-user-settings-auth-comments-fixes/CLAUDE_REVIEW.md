# PR #450 Review: UserSettings Split, Auth Layout Fix, Comments Double Navbar

**Reviewer:** Claude (Anthropic)
**PR:** [#450](https://github.com/BeamLabEU/phoenix_kit/pull/450)
**Author:** Sasha Don (@alexdont)
**Base:** dev ← dev (3 commits)
**Scale:** 4 files changed, +521 / -502

## Overview

Three independent fixes bundled in one PR:

1. **UserSettings `:profile` section split** into `:identity` and `:custom_fields` with backward-compatible `:profile` alias
2. **Auth page background layout fix** — replaced `fixed` positioning with normal document flow so footers render correctly
3. **Comments admin double navbar fix** — removed `LayoutWrapper.app_layout` wrapper from comments templates that already receive admin chrome via `admin.html.heex`

**Verdict: Approve.**

All three fixes are targeted and correct. The UserSettings refactor maintains backward compatibility via the `:profile` → `[:identity, :custom_fields]` expansion. The auth and comments fixes address real layout bugs with minimal changes.

---

## Commit-by-Commit Analysis

### Commit 1: Split UserSettings `:profile` into `:identity` and `:custom_fields`

**File:** `lib/phoenix_kit_web/live/components/user_settings.ex`

| Change | Detail |
|--------|--------|
| Default sections | `[:profile, :email, :password, :oauth]` → `[:identity, :custom_fields, :email, :password, :oauth]` |
| Legacy alias | `:profile` expands to `[:identity, :custom_fields]` via `Enum.flat_map` |
| Custom fields form | Extracted into standalone `<.simple_form>` with own submit button |
| Dividers | Now conditional — only render when adjacent sections are both present |

**Strengths:**

- **Backward compatible** — Existing code passing `sections: [:profile, :email]` continues to work unchanged.
- **Granular control** — Parent apps can now show identity fields without custom fields, or vice versa. Useful for apps that want a simpler profile page.
- **Conditional dividers** — Smart approach using `Enum.any?([:custom_fields, :email, :password, :oauth], & &1 in @sections)` to avoid orphaned dividers when sections are hidden.

**Notes:**

- The custom fields section reuses `@profile_form` and submits to `"update_profile"` — same handler as identity. This is correct since both sections modify the same user record, but means the two forms share validation state.
- The heading adapts based on context: shows a divider with "Additional Information" when identity section is present, falls back to an `<h2>` heading when identity is hidden.

### Commit 2: Fix Auth Page Background Breaking Footer

**File:** `lib/phoenix_kit_web/components/auth_page_wrapper.ex`

| Before | After |
|--------|-------|
| `fixed inset-x-0 top-16 bottom-0 z-10` | `min-h-[calc(100vh-4rem)] -mx-[calc(50vw-50%)] w-[100vw] -my-8` |

**What this fixes:** The `fixed` positioning took the auth card out of document flow, so the footer rendered behind it (or not at all). The new approach keeps the element in normal flow using `min-h` for full-viewport appearance and negative margins for edge-to-edge background.

**The viewport breakout pattern** (`-mx-[calc(50vw-50%)] w-[100vw]`) is a well-known CSS technique for making a child element span the full viewport width while staying in flow. Clean solution.

Also removed the z-index comment that's no longer relevant.

### Commit 3: Fix Double Navbar on Comments Admin Pages

**Files:** `lib/modules/comments/web/index.html.heex`, `lib/modules/comments/web/settings.html.heex`

Both templates were wrapped in `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>`, but as external plugin pages they already get admin chrome via the `admin.html.heex` layout. This caused duplicate navigation bars.

**Fix:** Remove the outer `LayoutWrapper.app_layout` wrapper, keeping just the inner content. The diff is large (+521/-502) but is purely an indentation change — no logic or markup was modified, only the wrapping element removed and content unindented by 2 spaces.

---

## Summary

Three well-scoped fixes. The UserSettings refactor is the most significant — it adds granularity without breaking existing callers. The auth and comments fixes are straightforward layout corrections. No issues found.
