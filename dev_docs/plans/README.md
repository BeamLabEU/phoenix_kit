# Plans

Implementation plans and refactor summaries. These documents were created **before or during** a significant change to guide the work. Most are fully executed — the code has been changed and the plan is now historical context explaining why things are the way they are.

## When to Add a File Here

- Step-by-step plan for a multi-PR refactor or migration
- Refactor summary documenting what changed and the impact
- Design decisions made before implementation began

## Files

| File | What It Covers | Status |
|------|---------------|--------|
| `2026-02-16-language-struct-refactor.md` | Summary of the Language struct refactor — what changed and impact on consumers | Executed |
| `2026-02-17-datetime-standardization-plan.md` | Step-by-step plan for standardizing all datetime types to `:utc_datetime` + `UtilsDate.utc_now()` | Executed (100%) |
| `2026-02-23-v62-uuid-column-rename-plan.md` | Plan for V62 migration: rename 35 UUID-typed FK columns from `_id` to `_uuid` suffix across 25 tables | Executed |
| `2026-09-18-failed-login-visibility.md` | Scope for recording failed sign-in attempts and surfacing them to the targeted account and the site owner | Scope only — not built |
| `2026-10-03-job-runs.md` | Universal job runs (a durable, controllable record over Oban batches), Jobs always on, storage library state and history — first customer: media storage | Phase 1 built, reviewed by Codex and fixed (plan §16–17), unreleased; phases 2–3 not started. [Review request](2026-10-03-job-runs-review-request.md) |
| `2026-10-03-job-runs-review-request.md` | Handoff to Codex for reviewing job runs phase 1: findings → code, acceptance list scored honestly, open questions | Answered (plan §16); fixes in §17 |
| `2026-10-03-bucket-page.md` | Handoff for the bucket page (a page per bucket: overview, usage, contents, health, history) after 2.49.1 / 2.50.0 made buckets in use protected and the new-bucket form pick a profile — what is done, the proposed sections and their data sources, open decisions, gotchas | Proposal — not built |
