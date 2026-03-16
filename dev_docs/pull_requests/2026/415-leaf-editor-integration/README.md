# PR #415 — Integrate Leaf editor into PhoenixKit

**Author:** Sasha Don (alexdont)
**Base:** dev
**Stats:** +2,070 / -14 across 5 files, 1 commit

## What

Replace the MarkdownEditor component with the Leaf dual-mode editor (visual + markdown) in the Posts module. Bundles the full leaf.js source inline into `phoenix_kit.js`.

## Why

Leaf provides a richer editing experience with visual (WYSIWYG) mode alongside markdown, replacing the markdown-only editor. Visual mode is set as the default for content authors who prefer it.

## Key Changes

- **`mix.exs`**: Add `{:leaf, "~> 0.1.0"}` dependency
- **`edit.ex`**: Add Leaf message handlers (`leaf_changed`, `leaf_insert_request`, `leaf_mode_changed`), rename content assign to `live_content`, broaden editor_id pattern match
- **`edit.html.heex`**: Switch from `MarkdownEditor` to `Leaf` component, update media insertion JS for visual/markdown dual mode
- **`phoenix_kit.js`**: Inline full leaf.js source (~2,000 lines)

## Related PRs

- Follow-up: #416 — Replaces inlined JS with ES6 import
