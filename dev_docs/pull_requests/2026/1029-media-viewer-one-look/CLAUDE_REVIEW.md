# PR #1029 — Update the media viewer: one dark bar, a View | Annotate switch, Export as PDF (fresco 0.16, etcher 0.25)

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; one bug fixed

The three picture canvases of `MediaCanvasViewer` get Fresco 0.16's `nav_style={:bar}`, `pdf_export` and
`export_filename`; the annotator's nav button becomes Etcher 0.25's `:modes` (View | Annotate) in place of the
pencil. `build_viewer_canvas/3` gives the image an `export_src` — the original's URL — so the PDF is not the
screen-sized rung the stage happens to show. Floors move: fresco `~> 0.16.0`, etcher `~> 0.25.0`, tessera
`~> 0.3.11`, and leaf admits `~> 0.12.0` (mention chips, off by default; `phoenix_kit.js` still only looks up
`window.LeafHooks.Leaf`). The follow-up "libs" commit (51438e7e5) locks fresco 0.16.0, etcher 0.25.0, tessera
0.3.11, leaf 0.12.0.

Checked and fine: the original in `file.urls` is already signed for this viewer (private files carry the
time-window token), and after an image edit it is the edited picture, never the hidden backup. The burned canvas
needs no `export_src` (its picture already has the drawing in it); the plain canvas is the live one minus the
extension, so it inherits `export_src`. Fresco caps the composed long side at 4000px.

## Findings

### BUG - MEDIUM — Export as PDF failed for HEIC, TIFF and camera-raw originals (fixed)

Storage accepts originals no browser decodes onto a canvas (`image/heic`, `image/heif`, `image/tiff`, camera raw;
`Storage` `@raster_mimes` / `CameraRaw`). The viewer shows those through their JPEG/WebP variants, but `export_src`
pointed the export at the original unconditionally. Fresco's `exportPdf` then fails to load it, warns in the console,
and the nav handler swallows the rejection (`exportViewerPdf().catch(function() {})`) — the button does nothing. A
raw original is also a large download for nothing.

Fixed: `export_src/2` uses the original only for `image/jpeg`/`pjpeg`/`jpg`/`png`/`gif`/`webp`; anything else
exports `large` (the ladder's top rung), and with neither the image keeps no `export_src` (the stage's own picture
is exported, as before). Test added in `media_canvas_viewer_eye_test.exs` for HEIC, TIFF and CR2.
