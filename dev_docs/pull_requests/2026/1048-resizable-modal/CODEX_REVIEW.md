# PR #1048 — Resizable modal

Reviewed the component, its imports, and the public browser hook at `08fc7df`.

- **BUG - MEDIUM.** Dragging a dimension to exactly zero skipped clamping and could discard the saved size. A configured minimum larger than the viewport also let the dialog extend off screen. The hook now clamps every supplied dimension, with the available viewport taking precedence.
- **BUG - MEDIUM.** A second pointer pressing a grip replaced the first drag, and cleanup cleared the host page's inline text selection style. The hook now keeps the original pointer until release and restores the style it found. Destroying an idle modal leaves the page's selection style alone.

Regression coverage drives a corner to exactly zero in a short window and presses a second grip while the first pointer is dragging. The hook tests use a simulated DOM. Keyboard resizing remains outside this component's documented behavior.

Validation passed with `mix precommit` (933 JavaScript tests) and `mix test test/phoenix_kit_web/components/core` (838 tests and 10 doctests).
