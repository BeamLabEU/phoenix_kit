# Claude Review — PR #1038

**Reviewer:** Claude Opus 5.5, with codex (GPT-6.1)
**PR:** Fix gallery thumbnails downloading full-width images and cropped tiles stretching wide pictures (mdon)
**Reviewed:** 2026-11-16

The author's own review before opening. An error report from a project using cropped image
tiles: the media gallery gave `image_set` no `sizes` (default `100vw`), and an honest `sizes`
alone makes landscape pictures cropped into square or portrait tiles blurry. The diff went to
codex with numbered questions.

## Findings

### BUG - LOW — a candidate could claim more width than it covers (fixed)
`round(h * aspect)` advertised a 200×101 variant as `51w` in a 0.5 box it can cover only 50 px
wide, so the browser could take it and stretch it by one pixel. Widths are rounded down now.

### IMPROVEMENT - LOW — of two files covering the same box, the larger was kept (fixed)
A 2560×1080 and a 1920×1080 variant both cover a 1080-px square; the dedupe kept the 2560 one.
It keeps the smaller now (the extra width is cropped away).

### BUG - LOW — an extreme `box_aspect` raised (fixed)
`box_aspect={1.0e308}` overflowed in `h * aspect`. The aspect is accepted between 1:100 and
100:1, anything else is ignored.

## Checked and not changed

- **The advertised widths are not the files' natural widths** (codex, from the HTML standard):
  the deliberate trade-off of this approach, harmless while CSS sizes the box (the gallery's
  `w-full h-full object-cover`). Documented in the moduledoc. The alternative, rewriting
  `sizes` per picture, needs a parser for media conditions.
- **Arbitrary or `max-*` grid classes** (`sm:grid-cols-[repeat(3,1fr)]`, `max-lg:grid-cols-2`)
  fall back to a wider `sizes`: an over-estimate, never an undersized download; `thumb_sizes`
  overrides it.
- Callers without `fit` are unaffected (`cover_width(variant, nil)` returns the variant).

## Verification

- `mix precommit`: exit 0.
- Every test touching the gallery or `image_set`: 2 doctests, 157 tests, 0 failures.
