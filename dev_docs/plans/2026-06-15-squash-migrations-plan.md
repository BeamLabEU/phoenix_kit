# Squash migrations — IMPLEMENTATION PLAN (2026-06-15)

Branch `squash-migrations`. Strategy ratified by operator (acting as **upstream BeamLabEU maintainer** — this is an
official upstream change, so fork/upstream merge-conflict risk is moot). Companion: `2026-06-15-squash-migrations-research.md`.

## Decisions

- **Approach:** delete-squash. Collapse `V01..V{floor}` into ONE baseline module `V{floor}`; raise `@initial_version`
  to `floor`; keep `V{floor+1}..V135` as individual delta files; delete `V01..V{floor-1}`.
- **Floor = 110** (conservative). Binding internal minimum is `external-prod-A = v121`; DEV/decor/MebelKit(=Andi) = v135.
  110 leaves 11 versions of margin below the binding min and keeps V111–V135 (25 deltas). Files: **135 → 26**.
  Parameterized — trivially re-targetable if the operator prefers a higher floor (e.g. 121).
- **Version = 2.0.0.** Removing the ability to upgrade directly from `< floor` changes the upgrade contract → semver MAJOR;
  also signals the intentional consolidation. (1.8.0 rejected: the dropped-upgrade-path is breaking.)
- **Upgrade contract (documented, Oban-style):** consumers must be on a PhoenixKit version whose schema is `>= floor`
  before upgrading to 2.0.0. A guard in `up/3` raises a clear error if `0 < migrated_version < @initial_version`
  (instead of a cryptic `UndefinedFunctionError` on a deleted module).
- **Forward re-squash convention:** documented procedure (+ helper script) to re-snapshot periodically so files don't
  re-accumulate: pick new floor ≤ min-deployed, regenerate baseline, delete intervening deltas, bump `@initial_version`,
  major-bump. See `dev_docs/` MIGRATIONS / re-squash section (to be written).

## Baseline construction (snapshot-from-dump — reliable, regenerable)

1. Run the OLD chain `V01..110` into throwaway schema `sq_snap_110`; the cumulative schema IS the baseline source.
2. `pg_dump --schema-only --no-owner --no-privileges -n sq_snap_110 --exclude-table='*.schema_migrations'`.
3. Transform → `lib/phoenix_kit/migrations/postgres/v110.ex`:
   - prepend `public` objects NOT captured by the `-n` dump: `CREATE EXTENSION IF NOT EXISTS citext|pgcrypto|pg_trgm`
     and `CREATE OR REPLACE FUNCTION uuid_generate_v7()` (copied verbatim from V40);
   - schema-qualifier `sq_snap_110.` → runtime `prefix` (placeholder-substituted at run time);
   - add idempotency guards where practical (CREATE … IF NOT EXISTS);
   - end `up/1` with `COMMENT ON TABLE #{p}phoenix_kit IS '110'`;
   - `down/1` tears the squashed objects down (to version 0) and is comment-correct.
4. Baseline writes its OWN version comment (PhoenixKit only auto-stamps multi-step `up`; a single-step `up(version: 110)`
   must self-stamp — see research §1).

## Files to change

- CREATE `lib/phoenix_kit/migrations/postgres/v110.ex` (baseline; replaces existing v110 content).
- DELETE `lib/phoenix_kit/migrations/postgres/v01.ex` … `v109.ex`.
- MODIFY `lib/phoenix_kit/migrations/postgres.ex`: `@initial_version 110`; keep `@current_version 135`; move/adjust the
  moduledoc version log; add the below-floor guard; drop the now-dead `version_checks` V83 heal entry (V83 deleted).
- `mix.exs`: `@version "2.0.0"`. `CHANGELOG.md`: 2.0.0 entry (consolidation + upgrade requirement).
- `lib/mix/tasks/phoenix_kit.gen.migration.ex`: verify next-version logic still correct with raised floor.
- Tests: `release_check` self-validates `@current_version == max(v*.ex on disk)` = 135 (v135 kept) ✓; per-version tests
  (v106/107 are **below floor 110** → those migration files are deleted, but the *tests* assert schema state which the
  baseline still produces — confirm they pass; if they reference deleted modules, adapt). v112/113/114/125 unaffected.
- Docs: upgrade requirement + re-squash convention.

## Prefix-safety bug fix (SEPARATE workstream — commit before the squash)

**Bug:** several migrations emit `CREATE [UNIQUE] INDEX #{name}` / `ADD CONSTRAINT #{name}` where `#{name}` is
*schema-qualified* (e.g. via the `prefix_index_name/2` helper returning `"#{prefix}.#{name}"`). Index/constraint/trigger
names are scoped to their table and **must not** be schema-qualified — `CREATE INDEX schema.idx ON ...` is a syntax error
(42601). It only works for real installs because the default `public` prefix makes the qualifier empty (`postgres.ex:1368`,
`if escaped_prefix != "public"`). So **non-`public` prefix installs are broken** (fail ~V62). Confirmed live: a non-public
run dies at `CREATE INDEX IF NOT EXISTS sq_ref_135.phoenix_kit_users_tokens_user_uuid_idx`.

**Fix (real upstream bug):** at every CREATE/ADD site, use a **bare** object name and keep only the **table** qualified;
DROP sites keep the qualified name (valid). `public` output stays byte-identical (qualifier already empty there); non-public
now produces valid SQL. Scope: **all** current `v01..v135` (complete standalone fix; squash later deletes v01..v109 but the
fix stands alone and is independently backportable). Add a regression test asserting prefixed DDL uses bare object names.
Filed as its own commit ahead of the squash commits.

**Bonus:** with prefixes fully safe, the chain runs into a throwaway *schema* without `public`-corruption risk — enabling
verification even if no clean DB is granted (only a benign identical `CREATE OR REPLACE FUNCTION public.uuid_generate_v7`).

## Verification (adversarial)

The chosen "throwaway schema in dev DB" env is INFEASIBLE as-is: (a) the prefix bug breaks non-public runs, and (b) the dev
DB's `public` already holds the real `phoenix_kit*` tables, so unqualified-DDL + `search_path` would mutate live tables.

**Primary (pending operator):** a clean throwaway DATABASE (CREATEDB grant or a scratch DB) — run each scenario with the
normal `public` prefix in an isolated DB whose `public` is empty, `pg_dump --schema-only -n public` (exclude
`schema_migrations`), normalize, diff. Cleanest, zero risk, exact unmodified chain.
**Fallback (no grant, after the prefix fix lands):** throwaway SCHEMAS in the dev DB via the now-safe prefix mechanism
(explicit qualification → no `public` corruption), `pg_dump -n <schema>`, `DROP SCHEMA … CASCADE`.

Mechanism proven either way: Ecto migrator via a custom version-runner; host `pg_dump` over direct PG 172.18.0.6:5432
(creds in `.git/squash_verify.pgpass`); cleanup drops only throwaway objects; never drop `public` functions/extensions.

1. **Fresh-install equivalence:** NEW chain (baseline + V111..135) vs OLD chain (V01..135) → normalized schema dumps
   must be **byte-identical** (empty diff). This is the core guarantee.
2. **Existing-install upgrade:** schema migrated OLD to 110/121, then NEW code `up()` runs only V{n+1}..135 (baseline
   skipped), ends at 135 == reference; no data loss.
3. **Below-floor guard:** install at `< floor` + NEW code → clear raised error (not silent corruption / not cryptic crash).
4. **Down + idempotency + re-run** sanity.
5. `mix compile --warnings-as-errors`, migration tests, `mix format`, `mix credo --strict`.

## Gate

Show operator the plan + full diff + verification results (empty schema diff) **before any merge/push**. Work stays on
`squash-migrations`. Restore stashed `auth.ex` WIP on `main` afterward (`git stash pop`).
