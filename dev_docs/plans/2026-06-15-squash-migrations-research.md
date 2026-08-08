# Squash migrations — RESEARCH report (2026-06-15)

Branch: `squash-migrations`. Source task: `SQUASH_MIGRATIONS_TASK.md`.
Method: 6 parallel read-only researchers (Workflow `wf_c83f4b83-177`) + direct probes.

## 1. Version-tracking mechanism (the safety foundation)

- `migrated_version` is stored as a **PostgreSQL table COMMENT on `{prefix}.phoenix_kit`** (Oban-style),
  read via `pg_catalog.obj_description(...)`, written via `COMMENT ON TABLE {prefix}.phoenix_kit IS 'N'`.
  The `phoenix_kit` table's rows are unused; only the comment matters.
  — `lib/phoenix_kit/migrations/postgres.ex:1221-1252` (read), `:1518-1521` (write).
- `up/3`: fresh DB (`migrated_version == 0`) runs `@initial_version..@current_version` (1..135);
  existing DB runs `(migrated+1)..target`; `migrated >= target` → no-op. — `postgres.ex:1174-1188`.
- Dispatch is **purely dynamic**: `Module.concat([__MODULE__, "V#{pad2(idx)}"]) |> apply(dir, [opts])`.
  No case/cond map. **A missing module in the live range → `UndefinedFunctionError`.** — `postgres.ex:1459-1462`.
- Quirk: PhoenixKit's `handle_version_recording` only auto-stamps the comment for **multi-step** `:up`
  (`total_steps > 1`); single-step migrations must stamp their own. (Oban always stamps.) — `postgres.ex:1473-1487`.
  V80 is a known module that omits its own stamp — relies on the multi-step fallback.

**Safe-squash recipe (mechanically sound):** create one baseline module named exactly `V{floor}` whose
`up/1` reproduces the cumulative idempotent schema of V1..floor and stamps its own comment `'floor'`;
bump `@initial_version` to `floor`; keep `V(floor+1)..V135` as individual files; baseline `down/1` tears
down to 0. Existing installs (`migrated >= floor`) skip the baseline; fresh installs run baseline + delta.

## 2. Oban reference

Oban 2.23.0 ships **no** baseline consolidation (V01–V14 all applied individually). Same dispatch/comment
pattern as PhoenixKit. So there is **no upstream precedent** for this kind of squash; we'd be inventing it.

## 3. Deployed versions (the floor)

- Local **Andi** (`/www/app`, prefix `public`): live DB comment = **`135`** (fully current). No table prefix set.
- docker1 (operator-provided): **external-dev-A** and **external-dev-B** at **v135** (2026-06-15).
- **external-prod-A**: lags; **version not yet confirmed** — task requires asking the docker1 operator
  before fixing the floor. **The floor MUST be ≤ the minimum actually-deployed prod version.**

## 4. Fork divergence (the decisive risk)

- Fork `v01..v134` are **byte-identical to upstream/main**; only `v135` is fork-exclusive. Merge-base is
  yesterday (`41057ae2`, 2026-06-14) — the fork tracks upstream tightly.
- Upstream adds **~15-18 new vN files/month** AND **patches existing old files continuously**
  (100 modify-commits to v01–v99, last 2026-04; 32 to v100+ in May–June). Fork merges upstream every ~2-5 days.
- A **delete-based squash** (remove v01..floor) → **guaranteed delete/modify merge conflict** on the next
  upstream patch to any squashed file — expected within **1-4 weeks** — and breaks clean upstream merges
  thereafter. Prior precedent: fork already renumbered `v114→v115` "to make room for upstream v114".

## 5. Squash surface (what code changes)

- CREATE `lib/phoenix_kit/migrations/postgres/v{floor}.ex` (baseline).
- MODIFY `postgres.ex`: `@current_version` (only hardcoded max), the `⚡ LATEST` moduledoc marker (`:532`),
  and `@initial_version` (`:1163`) if raising the floor.
- DELETE `v01.ex .. v{floor-1}.ex` **only if** `@initial_version` is raised (else dispatch crashes).
- `mix phoenix_kit.release_check` asserts `@current_version == max(v*.ex on disk)` — self-validates.
- Tests are **version-agnostic** (`ensure_current/2`); the 6 `vNNN_test.exs` pin schema state and need no edits.
- `@version`/CHANGELOG are normally maintainer-owned (PR #527) — the task explicitly overrides for this work.

## 6. Verification feasibility

- **No Postgres on localhost**; `pg_dump`/`psql` installed. Docker-network PG `172.18.0.6:5432` **is reachable**
  from this host; `pgbouncer:6432` too. Andi DB user lacks `CREATEDB` (can't `mix ecto.create`).
- Viable verify paths: (a) CREATEDB/superuser creds on the docker PG → isolated throwaway DBs;
  (b) prefix-aware migrations into throwaway **schemas** (`squash_verify_old` / `squash_verify_new`) in the
  dev DB, `pg_dump --schema-only -n …`, normalize + diff; (c) a dedicated scratch Postgres.
- **No real/prod DB writes.** Verification is the entire safety guarantee — a squash that can't be
  schema-diffed should not merge.

## Open decisions (need operator input)

1. **Strategy** given fork divergence (delete-squash vs snapshot-keep-files vs upstream-PR vs pause).
2. **Squash floor** — requires `external-prod-A` migrated_version (only relevant if delete-squash).
3. **Verification environment** — which of (a)/(b)/(c) above.
4. **Version bump** — 1.8.0 vs 2.0.0 (delete-squash is arguably breaking → 2.0.0).
