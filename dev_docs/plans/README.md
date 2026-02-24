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
