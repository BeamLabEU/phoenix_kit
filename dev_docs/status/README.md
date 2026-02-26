# Status Tracking

Progress snapshots for long-running migration efforts. These documents track the state of work across many files or modules at a specific point in time — what's done, what's pending, what's blocked. They're **not updated in place**; a new file is created when a significant milestone is reached.

## When to Add a File Here

- Migration progress matrix (module-by-module, file-by-file)
- Summary of a multi-PR effort at a checkpoint
- "Where we are" document before handing off work to another session

## Files

| File | What It Covers |
|------|---------------|
| `2026-02-05-uuid-module-status.md` | Per-module UUID migration status matrix — which modules had been converted to UUIDv7 at this date |
| `2026-02-14-legacy_id_analysis.md` | Analysis of remaining legacy integer `id` field usage across the codebase, with resolution status |
| `2026-02-14-uuid_migration_summary.md` | Summary of critical issues found during the UUIDv7 migration at this checkpoint |
