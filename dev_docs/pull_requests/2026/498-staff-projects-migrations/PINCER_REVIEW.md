# Pincer Review — PR #498

**PR:** Add V100 staff tables and V101 projects tables migrations
**Author:** Max Don (+ Claude Opus 4.7)
**Reviewer:** Pincer 🦀
**Date:** 2026-04-19

## Summary

Two migration versions added to `phoenix_kit` core:

- **V100** — Four staff tables: departments, teams, people (1:1 with users), team memberships. Cascading deletes model the org hierarchy.
- **V101** — Five project tables: task library, task dependencies, projects, assignments (task instances in a project), project-level dependencies. Polymorphic assignee pattern with `CHECK` constraint.

Bumps `@current_version` from 99 → 101. Updates moduledoc changelog.

## What Works Well

- **UUIDv7 PKs** throughout — consistent with the project standard
- **Cascading delete chain** is well-designed: dept → team → memberships, user → person → memberships
- **Polymorphic assignee** with `CHECK (num_nonnulls(...) <= 1)` — elegant enforcement at the DB level
- **Index coverage** is thorough — all FKs indexed, status columns indexed, partial indexes on nullable assignee columns
- **`prefix_str` handling** consistent with existing migrations
- **Rollback ordering** correct — dependent tables dropped first
- **`IF NOT EXISTS`** on all `CREATE TABLE` and `CREATE INDEX` — safe for re-runs
- **Moduledoc** clearly documents both versions with proper changelog entries

## Issues Found

### Non-blocking

1. **No self-reference guard on `phoenix_kit_project_dependencies`** — An assignment could reference itself as a dependency (`assignment_uuid = depends_on_uuid`). This should be enforced at the application level (or via a `CHECK` exclusion), but it's not a migration blocker since the existing pattern in this codebase is application-level validation.

2. **No `updated_at` trigger** — `updated_at` columns exist but are only set to `DEFAULT NOW()` with no trigger to auto-update on row modification. This is consistent with the existing migration pattern (app-layer handles it), so not an issue — just noting for awareness.

3. **`estimated_duration_unit` default is `'hours'`** — Reasonable default, but no `CHECK` constraint to validate allowed values (hours, days, weeks, etc.). Minor — can be validated in the Ecto schema.

4. **V100 `phoenix_kit_staff_people` has many nullable columns** — job_title, employment_type, dates, phones, bio, skills, notes, DOB, personal_email, emergency contacts. This is fine for a staff profile table, but worth noting that PII fields (DOB, personal email, emergency contacts) may warrant encryption-at-rest considerations at the application layer.

## Verdict

**✅ Clean, well-structured migrations. No blockers.** 

The PR follows established patterns, has solid FK/index coverage, and the polymorphic assignee pattern with DB-level CHECK constraints is a nice touch. Minor notes above are all application-level concerns, not migration issues.
