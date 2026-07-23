# PR #660 — Update fresco/etcher to 0.10/0.9 and add the image annotation tool

**Author:** alexdont
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-23
**Verdict:** ⚠️ APPROVE with one fix applied post-merge — see below.

---

## Summary

Bumps `fresco` `~> 0.6` → `~> 0.10` and `etcher` `~> 0.7` → `~> 0.9`
(`mix.exs`/`mix.lock`), refreshes the pinned jsDelivr CDN tags in
`priv/static/assets/phoenix_kit.js` (`fresco@v0.6.3` → `v0.10.0`,
`etcher@v0.6.5` → `v0.9.0`), and adds `:image` to the toolbar's `tools`
list in `media_canvas_viewer.html.heex`. Etcher's `:image` tool (new in
0.9, `CHANGELOG.md` entry "**`image` shape kind**") is a one-shot action
that inserts an image annotation via the OS file picker as a `data:` URL —
`image_source` is left at its default (`:file_picker`), so this needed no
new event handler or host-side uploader wiring.

## Files Changed (4)

| File | Change |
|---|---|
| `mix.exs` / `mix.lock` | fresco `~> 0.10`, etcher `~> 0.9` |
| `priv/static/assets/phoenix_kit.js` | pinned CDN tags refreshed to match |
| `lib/phoenix_kit_web/components/media_canvas_viewer.html.heex` | `:image` added to `Etcher.layer`'s `tools` list |

## Bug found and fixed

**BUG - HIGH: new `"image"` annotation kind not added to the schema
whitelist or the DB CHECK constraint — image annotations silently failed
to persist.**

Etcher 0.9 introduces a new shape kind for the `:image` tool:
`{kind: "image", geometry: {x, y, w, h, href}}` (etcher `CHANGELOG.md`).
`PhoenixKit.Annotations.Annotation.changeset/2` validates `kind` against
a hardcoded `@kinds` whitelist via `validate_inclusion/3`, backed by a DB
`phoenix_kit_annotations_kind_check` CHECK constraint — and `"image"` was
in neither. This is exactly the regression the repo has hit (and fixed)
four times before for other new Etcher tools (V115 `freehand`, V118/V119
`callout`/`text`/`dimension`, V121 widening, **V130 `marker`**) — each
time pairing the toolbar exposure with a migration widening the CHECK
constraint and the schema attribute. `test/phoenix_kit/annotations/annotation_kind_test.exs`
even documents this exact failure mode in its moduledoc ("`'marker'`
(V130) was the regression that motivated this test") — the same test
file has no coverage for `"image"`, confirming the pairing PR was never
added.

Effect: a user clicking the new `:image` toolbar button, picking a file,
and having it inserted onto the canvas would draw fine client-side, but
the `etcher:annotations-changed` persistence sync would reject the insert
(changeset invalid + CHECK constraint violation) — the image annotation
vanishes on reload. `sync_annotations`'s own inline comment in
`media_canvas_viewer.ex` calls out that persist failures are logged
rather than silently dropped, but the annotation itself is still lost.

**Fix applied:**
- `lib/phoenix_kit/migrations/postgres/v157.ex` — new migration widening
  `phoenix_kit_annotations_kind_check` to include `'image'`, same
  DROP-then-ADD idempotent shape as V130.
- `lib/phoenix_kit/annotations/annotation.ex` — `@kinds` widened to
  include `"image"`.
- `lib/phoenix_kit/migrations/postgres.ex` — `@current_version` bumped to
  157, moduledoc entry added.
- `test/phoenix_kit/annotations/annotation_kind_test.exs` — extended with
  the same coverage pattern used for `"marker"`: changeset acceptance,
  `kinds/0` membership, and a DB-level assertion that the CHECK constraint
  text includes `'image'`.

## Other things checked, no issue found

- **`image_source` default (`:file_picker`).** The PR didn't set this
  attr, so the tool opens the OS file picker and inserts the file as an
  inline `data:` URL entirely client-side — no LiveView event handler or
  MediaBrowser wiring needed for this to function. `:custom` mode (which
  would route through the host's own uploader via
  `etcher:image-insert-requested`) wasn't used and isn't required here.
- **Composer/title-prompt behavior.** `handle_event("etcher:shape-drawn",
  ...)` only skips the annotation composer popup for `"text"` and
  `"marker"` kinds; `"image"` falls through to the default branch and
  opens the title/comment composer after insert. This is a reasonable
  default (captioning an inserted image) and not a functional bug — left
  as-is.
- **CDN pin bump.** `fresco@v0.6.3` → `v0.10.0` and `etcher@v0.6.5` →
  `v0.9.0` in `phoenix_kit.js` match the new `mix.lock` pins exactly; no
  stale/mismatched tag.
- **No other Etcher/Fresco call sites** reference `:image` or need
  updating — `rg -n "Etcher.layer"` shows `media_canvas_viewer.html.heex`
  is the only consumer.
