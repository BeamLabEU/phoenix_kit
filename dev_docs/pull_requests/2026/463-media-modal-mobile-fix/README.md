# PR #463: Fix media selector modal mobile responsiveness

**Author**: @alexdont
**Branch**: `dev` -> `dev`
**Status**: In Review
**Date**: 2026-03-30

## Goal

Fix the media selector modal to be usable on mobile screens. The modal header buttons previously overflowed on small viewports.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_web/live/components/media_selector_modal.html.heex` | Mobile-responsive header layout, padding, and button sizing |

### Changes

1. **Header layout**: Changed from horizontal `flex justify-between items-center` to vertical `flex flex-col gap-3` — title and buttons stack on mobile
2. **Close button**: Added dedicated X button (top-right, `btn-ghost btn-square`) for quick dismiss; removed the X icon from the Cancel text button
3. **Button sizing**: Cancel and Confirm buttons use `flex-1 sm:flex-none` — full width on mobile, auto-sized on desktop, right-aligned via `sm:justify-end`
4. **Reduced padding**: Modal container, header, and content area use smaller padding on mobile (`px-2 py-2` / `px-3 py-3`) scaling up at `sm:` breakpoint
5. **Responsive text**: Title reduced from `text-2xl` to `text-xl sm:text-2xl`
6. **Shortened label**: "Confirm Selection" -> "Confirm" to save horizontal space
7. **Drop zone padding**: `p-3 sm:p-6` for upload area
