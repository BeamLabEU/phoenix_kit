# PR #1025 — Annotated thumbnails with text pick a font that is installed

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no changes

Merged into `main` as 5c9d245f9.

A text or callout annotation is drawn with `-draw "text …"`. Without `-font`, ImageMagick asks for its default
(Helvetica). On a slim host that name points to ghostscript `.pfb` files that are not installed, so `convert` exited 1
and the annotated thumbnail was never baked. `AnnotationThumbnail.font_args/1` now puts `-font <name>` before the draw
args, but only when the draw contains text. The font is `config :phoenix_kit, :annotation_font` (a name or a file),
else the first installed of DejaVu-Sans / Liberation-Sans / Helvetica / Arial, else any installed font that is not a
symbol set. "Installed" means the `glyphs:` file from `convert -list font` exists. The answer is kept in
`:persistent_term` once per node (`nil` included); a failed listing is not kept.

Checked and fine:
- **Binary name.** `convert` matches every other ImageMagick call in `ImageProcessor`, so an IM7-only host is no
  worse off than before.
- **Text detection.** Etcher's raster output emits text draws as `"text x,y '…'"`
  (`deps/etcher/lib/etcher/raster.ex:91`), which `text_draw?/1` matches. An outline-only draw gets no `-font`.
- **Listing parser.** The leading `Path:` chunk and blocks with no `glyphs:` line are dropped. The listing is passed
  as argv, not through a shell, so a font name cannot inject anything.
- **Tests.** The `PATH=""` test changes global env, but it is in an `async: false` module, and ExUnit runs sync modules
  only after the async ones. The integration test runs here (IM6 with fonts present).

## Findings

### NITPICK — A failed font listing is retried on every text render (not changed)

When `convert -list font` fails, `resolve_font/0` keeps nothing, so every later text render spawns the listing again.
That only happens when `convert` itself is broken or missing, and then the render that follows fails anyway. Caching
the failure would hide a fix (installing ImageMagick) until a restart. Left as is.

## Validation

PR tests (unit + integration) on a fresh scratch DB: green. `mix precommit`: green.
