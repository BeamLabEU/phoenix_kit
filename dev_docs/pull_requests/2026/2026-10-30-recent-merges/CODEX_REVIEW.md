# Recent merged PR review — 2026-10-30

**Reviewer:** Codex · **Baseline:** `716bce14e` on `main`.

Reviewed the eleven recently merged PRs after the prior batch ended at #991. Existing GPT/Codex review records count as prior OpenAI reviews. Work stayed in core; no version bump, changelog edit or release is part of this review.

- [#992 — Add personal API keys](../992-personal-api-keys/CODEX_REVIEW.md)
- [#996 — Fix /sitemap.html answering 500 on a site mounted at the root](../996-sitemap-html-redirect/CODEX_REVIEW.md)
- [#997 — Upgrading to 3.0: old host migration history on an empty database](../997-upgrading-3-fresh-db/CODEX_REVIEW.md)
- [#998 — Stop repair reporting wrong_shape for a CHECK that only nests its AND differently](../998-check-expression-normalization/CODEX_REVIEW.md)
- [#1000 — 3.0 guide: say exactly which lower databases are refused](../1000-upgrade-below-floor-wording/CODEX_REVIEW.md)
- [#1001 — Add editable library access, safe backup storage and live progress](../1001-library-access-backup-storage/CODEX_REVIEW.md)
- [#993 — Add an external picker option to MediaGallery](../993-media-gallery-external-picker/CODEX_REVIEW.md)
- [#994 — Add a picker mode to the media browser](../994-media-browser-picker/CODEX_REVIEW.md)
- [#995 — Add a viewer to the media browser's picker](../995-media-browser-picker-viewer/CODEX_REVIEW.md)
- [#999 — Add a removal guard and server-side confirmation to the media browser](../999-media-browser-removal-guard/CODEX_REVIEW.md)
- [#1002 — Update etcher to 0.24](../1002-update-etcher-024/CODEX_REVIEW.md)

Five behavioral findings fixed: one HIGH authorization gap (#1001), and four MEDIUM defects in embedded personal-key context (#992), picker confirmation (#994), concurrent viewers (#995) and folder removal confirmation (#999). Also corrected stale wording in the upgrade example (#997). The other five PRs needed no additional change.

## Validation

- Full PostgreSQL run: `PGDATABASE=pk_review_20261030_codex PGPOOL=10 mix test --max-cases 8` — **89 doctests, 13,528 tests, one stale assertion failure**, 38 skipped and one excluded; 1,504 seconds. The sole failure was corrected, the complete affected UI module passed (25 tests), and `mix test --failed --max-cases 8` on the full-run database then passed **one test, zero failures**. No known failing case remains.
- Initial focused coverage of the merged features: **345 tests, zero failures**.
- Media picker, viewer, removal dialog, embedded API-key context and initial library authorization regressions: **160 tests, zero failures**.
- Final library permission refresh, active-role restrictions, anonymous scopes, own-storage creation and storage UI: **80 tests, zero failures**, on a separate scratch database.
- `mix precommit` passed after the main fixes: compile with warnings as errors, unused dependency check, compilation of all Elixir test files, format check, strict Credo, Dialyzer (no new suppressions), and **505 JavaScript tests, zero failures**. The final pass also passed with the finished runtime changes and all test edits.
- Real-image canvas isolation: **one focused integration test, zero failures**, confirming distinct canvas IDs and matching burn-hook targets for the same image in two viewers.
- Existing user-library UI suite after correcting its stale storage label assertion: **25 tests, zero failures**.
- `git diff --check` — passed.

The regression-first run reproduced blocked-owner and demoted-admin writes, duplicate viewer IDs, changed empty-folder confirmation reuse, and out-of-scope picker confirmation.

The full suite ran with a reachable PostgreSQL server and integration tests enabled. The database account lacks `CREATEROLE`, so those tagged cases are excluded. Task-created scratch databases isolated the full and focused runs; both were removed after verification. The default database was untouched. Final library authority refinements were verified separately while the broad run was active.

The broad run exposed an older assertion for "The site's storage". Follow-up direct commit `dc31f0a065` changed the label to the configured project name. The test now configures a title and verifies the storage text on the specific library row; no runtime behavior changed for this correction.

No real-browser visual inspection or live cloud-storage probe was performed.
