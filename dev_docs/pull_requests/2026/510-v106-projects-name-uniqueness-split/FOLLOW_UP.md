# PR #510 Follow-Up — V106 projects name uniqueness split

PR #510 split V101's single global unique index on
`phoenix_kit_projects (lower(name))` into two partial unique indexes
(one per `is_template` value), unblocking
`Projects.create_project_from_template/2` for the common path where a
real project should reuse the source template's name.

The Claude review (`CLAUDE_REVIEW.md`) flagged one HIGH bug, one
MEDIUM improvement, and three NITPICKs. One was already fixed before
this sweep started; the rest are addressed below.

## Fixed (pre-existing)

- ~~**BUG-HIGH — `up/1` and `down/1` write wrong version values to
  `COMMENT ON TABLE phoenix_kit`**~~ — closed by Pincer in
  `86f8ac0d` ("Fix V106 version-comment off-by-one", 2026-04-29,
  same day as the review). V106's `up/1` was writing `'105'` instead
  of `'106'`, and `down/1` was writing `'104'` instead of `'105'`.
  The framework reads this comment as the source of truth for the
  current schema version (`postgres.ex:843-880`), so on the
  incremental V105 → V106 upgrade path the comment never advanced
  past `'105'` — V106.up would replay on every deploy, and the
  admin dashboard / `mix phoenix_kit.status` would report a stale
  version. Fresh installs masked the bug because
  `handle_version_recording/4` stamps the final version on
  multi-step runs and overrode V106's bad write. V106 was still on
  `dev` (not yet on Hex) when this was caught, so the amend was
  safe. See the fix commit's body for the full failure-mode
  walk-through.

## Fixed (Batch 1 — 2026-05-01)

### IMPROVEMENT-MEDIUM — `down/1` cross-mode duplicate pre-check

`down/1` documents the rollback as lossy when a template and a real
project share a name post-V106 (legal under the partial-index split,
illegal under V101's global index). Previously the migration just
let PostgreSQL discover the duplicates during `CREATE UNIQUE INDEX`
and surfaced a generic `duplicate key value violates unique
constraint` error — by which point the partial indexes had already
been dropped, leaving the table with NO name uniqueness at all
until the rollback could be either completed or reversed.

`down/1` now runs a pre-check SELECT BEFORE dropping the partial
indexes:

```elixir
case repo().query!(
       "SELECT lower(name) FROM #{p}phoenix_kit_projects " <>
         "GROUP BY lower(name) HAVING count(*) > 1 LIMIT 1",
       [],
       log: false
     ) do
  %{rows: []} -> :ok
  %{rows: [[duplicate_name]]} ->
    raise "Cannot roll back V106: name #{inspect(duplicate_name)} ..."
end
```

`LIMIT 1` because surfacing one offender at a time matches how
operators resolve duplicates (delete or rename one, re-run the
rollback, repeat). The error message names the duplicate so the
operator has something to grep for. The moduledoc on `down/1` was
updated to call out the pre-check ordering explicitly.

### NITPICK — moduledoc clarity on the changeset half

The original moduledoc carried the sentence "The Ecto changeset's
`unique_constraint(:name, name: :phoenix_kit_projects_name_index, ...)`
reference is updated in the same release of `phoenix_kit_projects`."
Reading that without the surrounding context could lead a future
maintainer to grep `lib/` for the constraint reference and conclude
something was missing — the matching changeset edit lives in the
**downstream `phoenix_kit_projects` package**, not in this repo.

Replaced the one-sentence note with a dedicated `##
Schema-side change only — changeset half lives downstream`
subsection that:

- Calls out explicitly that the `Project` schema has no
  representation in this repo (`rg phoenix_kit_projects_name_template_index
  lib/` returns only V106 itself).
- Documents the downstream changeset's `is_template`-driven
  constraint-name selection.
- Spells out the consequence of forgetting to ship the changeset
  half: V106's split would be invisible to end users — they'd still
  see the legacy single constraint name in error tuples instead of
  the partial-specific names.

### Tests added (`test/phoenix_kit/migrations/v106_test.exs`)

12 new tests — none required to invoke `V106.up/down` (they need an
`Ecto.Migrator` runner, see V107Test for the same constraint).
Pinned via raw-SQL state assertions and behaviour replication, the
same pattern V107Test uses.

`describe "schema state (verified at boot)"` — 6 tests:

- partial unique index for templates exists
- partial unique index for real projects exists
- V101's global unique index has been replaced (does NOT exist) —
  catches a regression that re-introduces the global index
- templates and real projects can share a name (the V106 goal —
  pinned by attempting both inserts and asserting both succeed)
- two templates with the same name are still rejected
- two real projects with the same name are still rejected
- name uniqueness is case-insensitive within each mode (since both
  partial indexes are on `lower(name)`)

`describe "down/1 — cross-mode duplicate pre-check"` — 5 tests:

- no duplicates → query returns empty rows
- single template + single project sharing a name → duplicate
  detected (the exact scenario the pre-check exists for)
- case-only difference still counts as a duplicate (case-insensitive
  comparison)
- only one duplicate is returned even when multiple exist (LIMIT 1
  semantics — surfaces at most one at a time)
- single row at any name → no duplicate (sanity)

The tests use raw `INSERT INTO phoenix_kit_projects` statements via
`Repo.query!` rather than a schema's changeset path because the
`Project` schema lives in the downstream `phoenix_kit_projects`
package — same isolation pattern as V107Test (which uses raw
inserts for the same reason).

## Skipped (with rationale)

### NITPICK — Hoist `prefix_str/1` to `Postgres.Helpers`

The reviewer observed that V106's local `defp prefix_str/1` is
duplicated across 30+ migrations (V77 onwards), with the modern
2-clause shape (`"public" -> "public."` / fallback) and a legacy
3-clause variant in V77/V79/V80 that handles `nil`. The hoist would
delete ~60 lines of duplication.

Skipped per the reviewer's own framing — "that's a chore PR, not
part of V106":

- **Scope mismatch.** PR #510 is a one-file migration adding two
  indexes. Folding a 30-file workspace-wide refactor into its
  follow-up would bury the V106-specific signal in mechanical
  edits.
- **Future migrations would re-introduce the duplicate** unless
  the convention shift is documented (AGENTS.md addition) AND
  enforced (ast-grep precommit guard, or update to
  `mix phoenix_kit.gen.migration`'s template). Both belong in the
  hoist PR, not here.
- **Migration-immutability norm.** The community convention is
  "don't touch shipped migrations." For PhoenixKit's Oban-style
  versioned migration pattern (Elixir modules, not timestamped
  files) the rule is softer — Oban itself has refactored migration
  helpers across releases — but the principle still argues for
  doing it as one focused PR with a clear rationale, not as a
  side-effect of a per-migration follow-up.

Surfacing as a candidate for a separate "migration helpers
refactor" PR if Max wants to do it. Low value-per-effort today
(the helper is 3 lines per migration), but the cost grows linearly
with every new migration — V200 with this still duplicated would
be ~200 LOC of dead helper across the source tree.

### NITPICK — Add integration test for incremental V105 → V106 upgrade path

The reviewer suggested an integration test that exercises the
incremental V105 → V106 path and asserts `migrated_version/1 == 106`
afterwards — the test that would have caught the version-comment
off-by-one before it shipped to `dev`.

Skipped because the actual bug is already fixed (preceding section)
and the proposed test is preventive coverage for OFF-BY-ONE BUGS IN
OTHER MIGRATIONS, not V106-specific. That's broad migration-
framework testing infrastructure shaped — closer to a feature
addition than a quality fix per the workspace's `feedback_quality_sweep_scope.md`
rule ("refactor existing paths; don't add missing features even if
PR reviews flagged them").

Surfacing as a candidate for a follow-up the next time a
similar off-by-one would have benefited from it. The right shape is
probably a generic helper in `test/integration/migrations_test.exs`
that takes a target version and asserts the comment matches after
the runner finishes — applicable to every migration, not just V106.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit/migrations/postgres/v106.ex` | `down/1` gains a pre-check SELECT that raises an actionable message naming a duplicate name BEFORE dropping the partial indexes; moduledoc rewritten to a dedicated subsection on the schema-side-only nature + the downstream changeset half |
| `test/phoenix_kit/migrations/v106_test.exs` | new file — 12 tests covering schema state (6) + the down pre-check behaviour (5) plus one sanity test |

## Verification

- `mix compile --warnings-as-errors` — clean
- `mix test test/phoenix_kit/migrations/` — 18 tests, 0 failures
  (12 new + 6 pre-existing V107)
- `mix test` — 1040 tests + 11 doctests; 1 intermittent failure in
  `test/integration/media_browser_scope_test.exs` (pre-existing
  flake — converged 1/0/0 across 3 stability runs, name varies
  between `scope_invalid detection` and `scoped_fallback?
  detection`; not introduced by this work)
- `mix format` — clean

## Open

None.
