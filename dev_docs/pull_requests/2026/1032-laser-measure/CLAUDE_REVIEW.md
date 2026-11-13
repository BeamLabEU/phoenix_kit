# PR #1032 — Media viewer: Etcher 0.26 laser measure, opt-in (config :phoenix_kit, laser_measure: true)

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; test follow-up applied

Merged into `main` as 22e98327e. It merged cleanly, and `mix.lock` resolves `etcher` 0.26.0.

`MediaCanvasViewer.laser_measure_tools/0` returns `[:measure]` only when `config :phoenix_kit, laser_measure: true`
(a literal `true`). It is appended to both annotator tool lists, the viewer's and the board view's. Those are the
only two places an Etcher tool list is built (`rg ':eraser' lib`). The etcher requirement goes from `~> 0.25.0` to
`~> 0.26.0`.

Checked and fine:
- **Read-only viewers.** Both lists sit in the `can_annotate` branch, so a viewer never gets the tool.
- **Web Bluetooth and Permissions-Policy.** Core sets no `Permissions-Policy` header, so it does not block
  Bluetooth. A host that sets its own header must allow `bluetooth`. That is the host's call, and the button says
  so when it is unavailable.
- **Runtime config.** The flag is read when the viewer renders, not at compile time, so `runtime.exs` works too.

## Findings

### BUG - MEDIUM — The tests flipped application env inside an `async: true` module (fixed)

The new `describe "the laser measure"` lived in `MediaCanvasViewerEyeTest` (`async: true`) and called
`Application.put_env(:phoenix_kit, :laser_measure, true)`. App env is global to the VM. While it was set, any viewer
rendered at the same moment by another async file got `:measure` too. Its `on_exit` also deleted the key outright,
which would wipe a value set in `config/test.exs`.

Fix: the tests moved to `MediaCanvasViewerLaserMeasureTest` (`async: false`). Its `on_exit` restores the earlier
value instead of deleting it. A new test pins that only a literal `true` turns the tool on (`"true"`, `1` and `:yes`
don't). The viewer fixture (`image/1`, `viewer_canvas/0`, `render_assigns/1`, `render_html/1`) moved from the eye
test into `test/support/media_canvas_viewer_fixtures.ex`, so both modules share it instead of keeping a copy each.
