# Recent merged PR review — 2026-10-29

**Reviewer:** Codex · **Baseline:** `38a116bc4` on `main`.

Reviewed recent merged PRs without an OpenAI review after #981, in merge order. Earlier `GPT_REVIEW.md` records count as existing OpenAI reviews. The documentation-only #989 is included to make the boundary explicit.

- [#982 — Avatar crop gestures](../982-avatar-crop-pan/CODEX_REVIEW.md)
- [#983 — Activity resource index and notification translations](../983-activities-resource-index/CODEX_REVIEW.md)
- [#984 — Role, settings and session permission boundaries](../984-permission-sweep/CODEX_REVIEW.md)
- [#986 — Folder cover picker viewer scope](../986-cover-picker-viewer-scope/CODEX_REVIEW.md)
- [#987 — Media event and bulk selection library boundaries](../987-media-uuid-scope/CODEX_REVIEW.md)
- [#988 — Linked copies and managed libraries](../988-linked-copies-managed-library/CODEX_REVIEW.md)
- [#989 — Neutral database names in review notes](../989-neutral-test-database-names/CODEX_REVIEW.md)
- [#991 — Media selection and drag and drop](../991-media-selection-drag-drop/CODEX_REVIEW.md)

Four behavioral findings fixed: one HIGH session authorization defect in #984, and three MEDIUM selection gesture defects in #991. Also corrected a MEDIUM gate failure caused by type inference in #991. Six PRs required no additional code changes. Existing post-merge fixes and documented ingestion contracts were considered against current main.

## Validation

- `mix precommit` — **passed**: compile with warnings as errors, unused dependency check, compilation of all Elixir tests, format check, strict Credo, Dialyzer (no new suppressions), and **480 JavaScript tests, zero failures**.
- `PGDATABASE=pk_review_20261029_final PGPOOL=10 mix test --max-cases 8` — **89 doctests, 12,871 tests, zero failures**, 38 skipped and one excluded; 1,251 seconds. PostgreSQL was reachable and integration tests ran. The account lacks `CREATEROLE`, so that tag was excluded.
- The two new session regressions failed before the fix, then all nine session authority tests passed. Two JavaScript regressions likewise failed before the fix; all four current selection tests pass, including overlay/listener cleanup on destruction.
- `git diff --check` — passed.

The initial gate found four unsuppressed MapSet opaque-type warnings in #991. The selection-filter refactor fixes the reported call sites without an ignore rule.

The first broader run exposed a timing-sensitive existing `MediaFiltersTest`: after clicking a shape filter it inspected the stack badge before the asynchronous navigation/URL patch had completed. Added an explicit `assert_patch` before checking the new count; all ten media filter cases and the final full suite passed. This is a test synchronization improvement, not an extra runtime behavior change.

The default database was still at V224, below the core 3.0 floor V225. Used separate scratch databases and left that database intact. Initially, broad and focused suites inadvertently shared the first scratch database; a destructive doctor test deadlocked on `phoenix_kit_user_roles` while the other process wrote roles. This was a verification setup error. Stopped the superseded runs and ran the final full suite alone against `pk_review_20261029_final`, eliminating the contention. Both task-created scratch databases were removed after use.

No real browser visual inspection was performed; the JavaScript gesture tests execute the shipped listeners and hook in an event/DOM harness.

No schema, version or changelog change belongs to this review.
