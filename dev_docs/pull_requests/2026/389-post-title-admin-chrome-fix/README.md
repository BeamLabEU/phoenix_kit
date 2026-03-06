# PR #389 — Move post title to full-width and fix admin chrome re-render bug

**Author:** Max Don
**Base:** dev
**Files changed:** 2 (+26, -22)

## What

1. **Editor title relocation:** Moves the post title `<input>` from inside the right-hand content column to a full-width position above the two-column layout in the publishing editor.

2. **Admin chrome re-render fix:** Prevents the `phoenix_kit_admin_chrome_rendered` process dictionary flag from being incorrectly set by the layout's own call to `app_layout`, which caused plugin LiveViews to lose admin chrome on subsequent re-renders.

## Why

1. The title is the most prominent metadata field and deserves full visual width rather than being constrained to one column of the editor layout.

2. For plugin LiveViews (which don't call `app_layout` directly), only the layout calls `wrap_inner_block_with_admin_nav_if_needed`. Previously, the layout's call would set the process dictionary flag, which then persisted across LiveView re-renders (since layouts don't re-render in connected mode). On the next event-triggered re-render, `Process.delete` would find the stale flag and short-circuit, stripping admin chrome.

## How

1. **Editor template** (`editor.html.heex`): Cut the title block from line ~953 (inside `flex-1` column) and paste it at line ~642 (above the `flex` container), adding `mb-4` spacing.

2. **Layout wrapper** (`layout_wrapper.ex:222`): Added `unless assigns[:from_layout]` guard before `Process.put(:phoenix_kit_admin_chrome_rendered, true)`, so only core views (which call `app_layout` directly) set the flag.
