## PR #510 — V106 migration: split phoenix_kit_projects name uniqueness for templates vs projects

**Author:** Max Don (@mdon)
**Reviewer:** Claude
**Date:** 2026-04-29
**Verdict:** ⚠️ APPROVE WITH FOLLOW-UP — already merged. The schema goal is correct and well-motivated, but the version-tracking metadata in `up/1` and `down/1` is off by one. Needs a V107 fix-up (or an amend if 1.7.99 hasn't shipped yet) before the next release goes out.

---

## Summary

Replaces V101's single global unique index on `phoenix_kit_projects (lower(name))` with two partial unique indexes — one for templates, one for real projects — so a template `"Onboarding"` and a real project `"Onboarding"` can coexist. This unblocks `Projects.create_project_from_template/2`, which currently collides whenever a real project should reuse the source template's name (the common path).

V106 was chosen over V105 because PR #507 (`feat/v104-crm-tables`) already claimed V105.

## Files Changed (2)

| File | Change |
|------|--------|
| `lib/phoenix_kit/migrations/postgres.ex` | +1 / −1 — `@current_version 105 → 106` |
| `lib/phoenix_kit/migrations/postgres/v106.ex` | +84 — new migration |

## Schema delta

```sql
-- BEFORE (V101)
CREATE UNIQUE INDEX phoenix_kit_projects_name_index
  ON phoenix_kit_projects (lower(name));

-- AFTER (V106)
CREATE UNIQUE INDEX phoenix_kit_projects_name_template_index
  ON phoenix_kit_projects (lower(name)) WHERE is_template = true;

CREATE UNIQUE INDEX phoenix_kit_projects_name_project_index
  ON phoenix_kit_projects (lower(name)) WHERE is_template = false;
```

## Green flags

- **Right tool for the job.** Two partial unique indexes are exactly the PostgreSQL-native way to model "uniqueness within a discriminated subset." Cleaner than adding `is_template` to the unique key (which would let a template and a project named the same thing trip a single composite index but defeats name reuse across the whole template→project flow).
- **Idempotent and reversible.** `CREATE UNIQUE INDEX IF NOT EXISTS` / `DROP INDEX IF EXISTS` on both sides; `down/1` recreates V101's exact original index name (`phoenix_kit_projects_name_index`) so a roll-back lands on the V101 baseline.
- **Lossy-rollback warning is documented.** The `@doc` on `down/1` calls out that recreating the global unique index will fail if a template and a real project share a name post-V106. That's the right note to leave for whoever runs the rollback.
- **Why-V106 reasoning is in the PR body.** The collision with PR #507's V105 claim is captured for archaeologists.
- **Schema-side change only — no data migration.** The two partial indexes split the existing rows into two disjoint sets (`WHERE is_template = true/false`); each subset is already unique under V101's stricter constraint, so no data needs touching.

## Findings

### BUG — HIGH — `COMMENT ON TABLE` version values are off by one

File: `lib/phoenix_kit/migrations/postgres/v106.ex:60` and `:81`

```elixir
def up(opts) do
  ...
  execute("COMMENT ON TABLE #{p}phoenix_kit IS '105'")   # ← should be '106'
end

def down(opts) do
  ...
  execute("COMMENT ON TABLE #{p}phoenix_kit IS '104'")   # ← should be '105'
end
```

**Why this matters.** PhoenixKit's migration framework uses the `phoenix_kit` table comment as the **source of truth** for the current schema version. `Postgres.migrated_version/1` reads it via `pg_catalog.obj_description`, and `Postgres.up/1` then computes `(initial + 1)..opts.version` to decide which steps to apply (`postgres.ex:803-814`, `:843-880`).

The **established convention** across V100–V105 is:

| Migration | `up` writes | `down` writes |
|---|---|---|
| V101 | `'101'` | `'100'` |
| V102 | `'102'` | `'101'` |
| V103 | `'103'` | `'102'` |
| V104 | `'104'` | `'103'` |
| V105 | `'105'` | `'104'` |
| **V106** | **`'105'`** ❌ | **`'104'`** ❌ |

V106 uses V105's values verbatim — looks like a copy-paste from `v105.ex:66,82` that wasn't updated.

**Failure mode for incremental upgrades (V105 → V106), the common production path:**

1. Operator deploys a release containing V106. `migrated_version/1` reads `'105'`. `up` runs `change(106..106, :up, opts)` → V106.up executes, finishes by writing `'105'`. **Comment never advances.**
2. Next deploy: `migrated_version/1` again reads `'105'`. Framework again runs V106.up. The DDL is idempotent (`DROP INDEX IF EXISTS`, `CREATE INDEX IF NOT EXISTS`) so nothing breaks, but **every deploy replays V106.up forever**.
3. When V107 ships, `@current_version = 107` but the comment still says `'105'`. The framework runs V106.up + V107.up on every deploy until V107 itself updates the comment past 105 — and even then the DB never settles on a coherent record of what's been applied.

**Why fresh installs mask the bug.** On a 0 → 106 multi-step run, `handle_version_recording/4` (`postgres.ex:1100-1113`) calls `record_version(opts, Enum.max(range))` after the per-step `up/1` calls finish — that final write stamps `'106'` and overrides V106.up's bad `'105'` write. So fresh installs end up correct. Only **incremental** V105 → V106 upgrades leave the comment stuck at `'105'`. (Same reasoning for `down`: multi-step rollbacks happen to be saved by the next migration's `down`, but a single-step V106 → V105 rollback leaves the comment at `'104'`, skipping V105.)

**Downstream visibility:**
- `PhoenixKitWeb.Live.Dashboard` (`dashboard.ex:40`) shows the wrong version to admins ("DB at 105" while the package is at 106).
- `mix phoenix_kit.status` reports the same stale version.
- `lib/phoenix_kit/install/migration_strategy.ex:100,184` makes upgrade decisions on this number.

**Fix.** One-character changes:

```elixir
def up(opts) do
  ...
  execute("COMMENT ON TABLE #{p}phoenix_kit IS '106'")
end

def down(opts) do
  ...
  execute("COMMENT ON TABLE #{p}phoenix_kit IS '105'")
end
```

**Roll-out options:**
- **If 1.7.99 has not yet been published to Hex** that contains V106: amend V106 in place (the schema half is already correct; this just corrects the metadata write). Anyone who applied V106 from `dev` can self-heal by running `COMMENT ON TABLE phoenix_kit IS '106'` once.
- **If V106 has already shipped to Hex consumers**: open a small follow-up V107 whose only job is to (a) `COMMENT ON TABLE phoenix_kit IS '107'` and, if you want belt-and-suspenders, run an `UPDATE`-style heal that promotes any `'105'` it finds to `'106'` before stamping `'107'`. Treat this as the same shape as the "V83 prefix-bug heal" already in `postgres.ex:986-1017`.

### IMPROVEMENT — MEDIUM — `down/1` could pre-check for cross-mode duplicates

`down/1` documents that the rollback is lossy if a template and a real project share a name post-V106. Currently it lets PostgreSQL discover that during `CREATE UNIQUE INDEX` and surface the generic `duplicate key value violates unique constraint` error. A two-line pre-check turns that into an actionable message at the start of the down migration:

```elixir
case repo().query!(
       "SELECT lower(name) FROM #{p}phoenix_kit_projects " <>
       "GROUP BY lower(name) HAVING count(*) > 1 LIMIT 1") do
  %{rows: []} -> :ok
  %{rows: [[name]]} ->
    raise "Cannot roll back V106: duplicate project/template name #{inspect(name)}. " <>
          "Resolve duplicates before rolling back."
end
```

Optional — the moduledoc already warns about it. But operators reading the eventual error message will appreciate it. Not blocking.

### NITPICK — `prefix_str/1` helper duplicates a pattern that's slightly different from V102–V105

V102–V105 each define their own local `prefix_str/1`-style helper with subtly different shapes (some return `"public."`, some return `"public"`). V106's version matches the V103/V104/V105 shape (returns `"public."`), which is right for the call sites. Long-term, hoisting one canonical helper into `Postgres` (or `Postgres.Helpers`) would let migrations stop re-defining it — but that's a chore PR, not part of V106.

### NITPICK — Doc comment on `up/1` says "Schema-side change only"

The moduledoc carries a sentence: "The Ecto changeset's `unique_constraint(:name, name: :phoenix_kit_projects_name_index, ...)` reference is updated in the same release of `phoenix_kit_projects` to point at whichever partial index applies (the `is_template` value at validate time selects the correct constraint name)."

The corresponding changeset update is in a downstream package (no `phoenix_kit_projects` schema lives in this repo — `rg` confirms only the migrations reference the table). Worth being explicit in the moduledoc that the changeset half lives outside this repo, so a future reader doesn't grep `lib/` for the `unique_constraint` call and conclude something is missing. One-line tweak.

### NITPICK — Test plan in PR body has the up/down item unchecked

The PR description's test plan still has `[ ] Migration up/down both succeed on a fresh DB` unchecked. Given the version-comment bug, this is actually the right state — but the bug also means that on a fresh DB the `up` half will **appear** to succeed (final-version stamp is fixed by `handle_version_recording/4`) while masking the underlying defect. A targeted test that exercises the **incremental** V105 → V106 path and checks `migrated_version/1` afterwards would have caught this. Worth adding when the V107 heal lands.

## Suggested follow-ups

1. **Open V107 (or amend V106 if pre-Hex)** that corrects the comment values. If V106 has shipped, V107 should also heal any DBs stuck at `'105'`. Mirror the V83 prefix-heal pattern in `postgres.ex:986-1017`.
2. **Add an integration test** in `test/integration/migrations/` that runs a fresh install through V105 then a single-step jump to V106 and asserts `migrated_version_runtime/1 == 106`. Cheap insurance against the same off-by-one in future migrations.
3. **Land the matching `phoenix_kit_projects` changeset change** in the downstream package the PR body refers to — `unique_constraint(:name, name: :phoenix_kit_projects_name_template_index)` vs `:phoenix_kit_projects_name_project_index` chosen by `is_template`. Without it, conflict errors hit the generic FK error path instead of producing a clean `name has already been taken` form error. (This is called out in the PR body but worth restating; without it the V106 split is invisible to end users.)

## Files in this review folder

- `CLAUDE_REVIEW.md` — this document.
