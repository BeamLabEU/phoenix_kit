# Audits & Reports

Point-in-time analysis documents. Each captures a snapshot of the codebase at a specific date — what was found, what was inconsistent, what needed fixing. These are **historical records**, not living documents. They don't get updated as the codebase evolves.

## When to Add a File Here

- Audit of a specific pattern across the codebase (e.g. "how many places use X wrong")
- Analysis report produced before or during a refactor
- Performance or compilation investigation
- PR quality assessment

## Files

| File | What It Covers |
|------|---------------|
| `2026-02-14_pr_review_analysis.md` | Assessment of PR quality and project direction at a point in time |
| `2026-02-14_slow_compilation_analysis.md` | Compilation performance analysis with identified bottlenecks |
| `2026-02-14-uuid-naming-convention-report.md` | Audit of UUID field naming inconsistencies across schemas |
| `2026-02-15-datetime-inconsistency-report.md` | Full audit of datetime type mismatches (`NaiveDateTime` vs `DateTime`) that caused a production bug |
| `2026-02-16-struct-vs-map-audit.md` | Audit of 27 plain maps acting as de-facto structs, categorized into 3 tiers for conversion |
| `2026-02-23-css-overrides-analysis.md` | Analysis of CSS customization needs vs what Tailwind/daisyUI handles automatically |
| `2026-02-23-uuid_migration_audit.md` | Database schema audit of UUID migration completeness |
| `2026-02-23-uuid_migration_audit_corrected.md` | Root cause analysis of V40 buffering bug and corrected migration status |
