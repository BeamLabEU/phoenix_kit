# PR #1059 — Media viewer: "Other versions" instead of a second "Download"

**Author:** timujinne · **State:** merged 2026-11-23 (`24dc30fa7`) · **Reviewed:** 2026-11-23

**Verdict:** merged, no findings. Small, correct, complete.

## Checked, fine

- The change is one `<summary>` in `media_canvas_viewer.html.heex:688`: the dropdown of the
  other variants now reads `gettext("Other versions")` and carries `hero-arrow-down-tray`
  (a real heroicon, `PhoenixKit.Utils.HeroIcons`), so the primary `Download` button
  (`:684`) is the only one with that word. The PR's own test asserts exactly one visible
  `>Download<` with an original plus one more variant present.
- `download_variants/1` gates the dropdown as before; the list itself is unchanged.
- The new msgid is in `default.pot` and all ten catalogues with translations, reference line
  `media_canvas_viewer.html.heex:689`; `mix gettext.extract --check-up-to-date` passes on the
  merged main. The remaining catalog churn is reference-line shifts only.
- No permission, serving or routing surface touched.

## Note for the next sweep

Merging #1059 before #1058 made GitHub report #1058 as CONFLICTING: both PRs edit the same
gettext catalog regions. The conflict was reference lines plus one added msgid only, and was
resolved by rebasing #1058 onto main and regenerating the catalogs (`mix gettext.extract` +
`mix gettext.merge`, then re-applying the handoff msgid's translations), verified by
`mix gettext.extract --check-up-to-date` and `handoff_translations_test.exs`. Follow-up fix
commit on main: `a78de00a2` (the first merge attempt dropped the new msgid because the
resolution was pushed before the catalog regeneration was committed — see
`1058-cross-domain-handoff/VIBE_REVIEW.md`).
