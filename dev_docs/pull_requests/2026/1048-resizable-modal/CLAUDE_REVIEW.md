# PR #1048 — Add a modal the person can resize by its edges and corners

**Author:** timujinne · **Merged:** 2026-11-19 (`8bac7ae14`) · **Reviewed on main:** `a5111808e`

Read `Core.ResizableModal`, the `Core.Modal` helper change, the `PhoenixKitWeb` import change,
the `PkResizable` hook in `phoenix_kit.js` and its tests, after Codex's follow-up (clamping at
zero, second pointer, restored `user-select`).

**Verdict:** no open bug. Nothing changed in this pass.

## Checked, fine

- **Hook placement.** `PkResizable` is in the public bundle. That is right: the component is a
  generic primitive like `<.modal>`/`PkDialog`, so any host page can render it. The
  `admin_split.test.cjs` lists and `guides/public-and-admin-javascript.md` agree.
- **Patch survival.** The kept size lives in inline styles, which morphdom strips whenever the
  server renders a different `style` on the box. `updated()` re-applies it. The server's own
  `height` is a custom property, never inline, so letting go of the kept size restores it.
- **Import narrowing.** `import Core.Modal, except: [max_width_class: 1, max_height_style: 1]`
  takes `max_height_style/1` out of every LiveView's namespace. No caller in the workspace
  uses either one unqualified, so nothing breaks.
- **Drag lifecycle.** A press below the 4 px threshold writes nothing, a second pointer is
  ignored, capture loss ends the drag, and `destroyed/0` restores `user-select` only while
  dragging.

## Findings

- **NITPICK — the kept size is keyed by the bare dialog `id`.** `pk:resizable:<id>` is shared by
  every page (and every module) that renders a resizable modal with the same id, such as
  `"compose"`. The moduledoc says "one entry per dialog `id`", so this is documented. A module
  that wants its own size picks a distinctive id. Not changed.
- **NITPICK — `aria-labelledby` points at `<id>-title` even without a `:title` slot.** The
  reference then names nothing. `<.modal>` does the same, so the two stay consistent. If one
  of them changes, change both.
- **NITPICK — a window narrowed below 640 px during a drag.** The drag keeps tracking, nothing
  is drawn (narrow screens show the full-screen sheet), and the release still saves the
  bounded size. That size then applies when the window is wide again. This needs a resize in
  the middle of a drag, so it was left as is.
- **Not covered (documented):** keyboard resizing. The grips are `aria-hidden` and pointer-only.
