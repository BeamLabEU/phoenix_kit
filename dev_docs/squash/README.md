# Migration squash — maintainer verification tooling

MAINTAINER-ONLY tooling for the PhoenixKit migration-chain consolidation
(squash) and the verify-and-repair capability.

- Specification: `dev_docs/plans/2026-07-14-squash-migrations-spec.md`
  (REVIEWED DRAFT r2 — sections referenced below as §N).
- Per-version inventory (seeds / backfills / drops / hazards):
  `dev_docs/plans/2026-07-14-squash-inventory.md`.
- All files here are excluded from the hex package (`mix.exs` `files:`
  whitelist is `~w(lib priv mix.exs README.md LICENSE CHANGELOG.md)`).

## Layout

| Path | What it is |
|---|---|
| `repo_helper.ex` | `PhoenixKit.Squash.RepoHelper` — env-wired Ecto repo bring-up (direct connection, sandbox escape) |
| `dump_helper.ex` | `PhoenixKit.Squash.DumpHelper` — pg_dump + deterministic normalization (S1 oracle), seed-data dumping + uuid/timestamp normalization (S2 oracle), whitelist compare, `diff -u`. NB the S1 schema dump deliberately INCLUDES `oban_*` tables (the manifest excludes them, spec §6.1): S1 therefore also pins Oban-package consistency — an Oban version bump between the bridge reference build and the squash checkout will surface as an S1 diff (re-pin, don't chase phantom drift) |
| `migration_runner.ex` | `PhoenixKit.Squash.MigrationRunner` — version-bounded `PhoenixKit.Migrations.up/down` runs via ephemeral `Ecto.Migrator` wrappers (prefix-threaded bookkeeping), stepwise per-version execution, below-floor assertion with a specific error matcher |
| `verify.exs` | Scenario harness for the §8.2 matrix (S1-S13, S15-S22) — see the scenario table below |
| `generate_baseline.exs` | ExpectedSchema manifest generator (stepwise chain + per-version catalog diffs); its authoritative env/flag contract lives in its own header |
| `reference/` | Tool-written S1/S2 reference dumps for cross-checkout comparison (regenerate, never hand-edit; keep out of hex — dev_docs already is) |
| `reference_mode_a/` | The same, built in `--mode a` against `public` (kept apart: a public reference and a named-schema reference legitimately differ on shared-object paths) |
| `COVERAGE.md` | What is verified per version range, and what is not |
| `restamp_chain_hash.exs` | Recomputes `ExpectedSchema.chain_hash/0` over the shipped `v*.ex` set after promotion; writing requires `--restamp` |
| `out/` | Retained dumps/diffs from `--verbose` runs and failures; disposable, do not commit |

## Floor parameterization — nothing is hardcoded

The floor (`V{floor}` baseline version) and current chain head are **never**
hardcoded in any script (the June 2026 draft hardcoded 110/135; that class of
staleness is retired):

- current: `PhoenixKit.Migrations.Postgres.current_version/0` (compiled code).
- floor: `PhoenixKit.Migrations.Postgres.initial_version/0` — post-squash the
  registry's `@initial_version` IS the floor. On pre-squash checkouts
  (`@initial_version == 1`) the tooling accepts the `PK_SQUASH_FLOOR` env
  override (`MigrationRunner.floor/0`); on squashed checkouts the override
  must be unset (a contradiction raises).

The floor VALUE is a P0 operator input (§4, D1/D2: fresh readings from the
complete supported-install set; candidate 121 is unconfirmed). Read the
compiled values at any time:

```bash
MIX_ENV=test mix run --no-start -e \
  'IO.puts("initial=#{PhoenixKit.Migrations.Postgres.initial_version()} current=#{PhoenixKit.Migrations.Postgres.current_version()}")'
```

## Offline smoke gate (`--check`)

Every runnable `.exs` here supports `--check`: it compiles all its modules,
runs the helpers' DB-free self-checks, validates configuration parsing,
prints a one-line OK and exits 0 — **without any DB access**. Run it after
every edit; a script that cannot pass its own `--check` must not ship:

```bash
MIX_ENV=test mix run --no-start dev_docs/squash/verify.exs --check
MIX_ENV=test mix run --no-start dev_docs/squash/generate_baseline.exs --check
```

`verify.exs --check` additionally lists every scenario with its current
runnability (`RUNNABLE` / `SKIP:<reason-slug>`), computed from the compiled
code state — scenarios light up automatically as the P2/P3 artifacts land.

## Database environment

**Reality (probed 2026-07-14, §8.1 / audit):** the only reachable server is
PostgreSQL 17.4 at **172.18.0.13:5432** (direct), role
`tim_dev_manager_andi_user` with **no CREATEDB** — the harness cannot create
databases and no scratch DB exists yet. Client tooling is ready
(psql/pg_dump 17.10). Nothing DB-backed runs until the operator provides one
of (ranked, §8.1):

- **(a) CREATEDB** on 172.18.0.13 — best; unlocks everything including
  `mix test.setup` and true clean-DB Mode A per scenario.
- **(b) Pre-created owned DBs** — `pk_squash_a`, `pk_squash_b`,
  `phoenix_kit_test` (minimum viable: just `phoenix_kit_test`). Ownership
  gives schema create/drop and trusted-extension install (PG13+: citext,
  pgcrypto, pg_trgm are *trusted* — a DB owner can `CREATE EXTENSION` them
  without superuser). Reset recipe between Mode A runs (the harness issues
  exactly this, behind the `PK_SQUASH_ALLOW_RESET` gate):

  ```sql
  DROP SCHEMA public CASCADE;
  CREATE SCHEMA public;
  ```

  (On PG15+ `public` is owned by `pg_database_owner` = the DB owner, so this
  works without superuser. The CASCADE also drops extensions installed in
  `public` — the chain reinstalls them via `Helpers.ensure_extension!/1`.)
- **(c) Operator-side disposable PG container** — required anyway for two
  matrix cells: the hardened low-privilege recipe and a **second PG major**
  (§6.2 deparse/structural-comparison risk).

**Connection rules:**

- Always the **direct** endpoint `172.18.0.13:5432`. **NEVER PgBouncer**
  (`pgbouncer:6432`): transaction pooling breaks pg_dump session state and
  this project's PgBouncer silently drops transactional DDL. The only
  PgBouncer contact the spec allows is S12's *dry-run detection* cell.
- `~/.pgpass`-style credentials live in
  `/www/phoenix_kit/.git/squash_verify.pgpass` (host field points at
  172.18.0.13) — usable for manual `psql`/`pg_dump` probes. **Postgrex never
  reads `.pgpass`**: the scripts require `PGPASSWORD` exported explicitly
  and fail eagerly with a clear message when it is missing.

## Environment-variable contract

| Variable | Used by | Required | Meaning |
|---|---|---|---|
| `PGHOST` | all `[DB]` paths | for DB runs | Direct Postgres host (e.g. `172.18.0.13`) |
| `PGPORT` | all `[DB]` paths | no (5432) | Direct port — never 6432/PgBouncer |
| `PGUSER` | all `[DB]` paths | for DB runs | Role owning the scratch DB |
| `PGPASSWORD` | all `[DB]` paths | for DB runs | Postgrex does not read `.pgpass`; export explicitly |
| `PGDATABASE` | all `[DB]` paths | for DB runs | The scratch database (never a live one) |
| `PGSSL` | repo_helper | no | `"true"` enables SSL |
| `PK_SQUASH_FLOOR` | migration_runner (`floor/0`), verify.exs, generate_baseline.exs | pre-squash only | Floor override while `@initial_version == 1`; must be unset on squashed checkouts |
| `PK_SQUASH_SCHEMA` | verify.exs | no (`pk_squash_test`) | Base name for scratch schemas (Mode B and named cells) |
| `PK_SQUASH_ALLOW_RESET` | verify.exs (Mode A) | Mode A only | Must equal `PGDATABASE`; authorizes the `DROP SCHEMA public CASCADE` reset recipe |
| `PK_SQUASH_WHITELIST` | verify.exs | no | Override of the committed `:legacy_optional` list (comma-separated; empty string = fully strict) |
| `PK_SQUASH_REF_DIR` | verify.exs | no (`dev_docs/squash/reference`) | Where S1/S2 reference dumps live |
| `PK_SQUASH_OUT_DIR` | verify.exs | no (`dev_docs/squash/out`) | Where dumps/diffs are retained |

`generate_baseline.exs` consumes the `PG*` set and `PK_SQUASH_FLOOR`; its
script header documents any additional flags authoritatively.

## Two modes (both implemented; the June draft's Mode A was broken)

### Mode B — throwaway named schemas (default, `--mode b`)

All installs run into named scratch schemas (`{PK_SQUASH_SCHEMA}_*`) inside
`PGDATABASE`; `public` is never touched, so this is safe against any scratch
DB (including a shared one) — but still never point it at a live database:
`schema_migrations` bookkeeping is prefix-threaded into the scratch schemas,
yet the objects under test are real DDL.

```bash
PGHOST=172.18.0.13 PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=pk_squash_a \
PK_SQUASH_FLOOR=121 \
MIX_ENV=test mix run dev_docs/squash/verify.exs --mode b --scenario s1_self,s2_self
```

### Mode A — sequential clean-DB (`--mode a`)

Installs run into `public` of a **dedicated, disposable** scratch DB.
Side-by-side comparisons are sequential: install → dump → reset → install →
dump → compare (the normalizer makes the schema name irrelevant). Reset is
the §8.1(b) recipe above — destructive, therefore double-gated:

```bash
PGHOST=172.18.0.13 PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=pk_squash_a \
PK_SQUASH_ALLOW_RESET=pk_squash_a \
MIX_ENV=test mix run dev_docs/squash/verify.exs --mode a --scenario s11_pre
```

Mode A is required for the strongest S11 cell (public-vs-named cross-leak).
The S4 handoff scenarios refuse Mode A (`SKIP:needs-mode-b`): the persistent
below-floor schema cannot survive `DROP SCHEMA public CASCADE`, which also
drops extension-dependent objects in other schemas.

## Running scenarios

```bash
MIX_ENV=test mix run dev_docs/squash/verify.exs [--mode a|b] [--scenario ids] [--verbose]
```

- Each scenario prints one machine-readable line:
  `RESULT <id> PASS|FAIL|ERROR|SKIP:<reason-slug>`.
- Exit codes: `0` = no failures (SKIPs allowed), `1` = FAIL/ERROR present,
  `2` = usage/configuration error.
- Scratch schemas are registered before creation and dropped in `after`
  blocks — **exceptions cannot leak them**. `--verbose` retains schemas and
  all dumps under `PK_SQUASH_OUT_DIR`; comparison failures retain their
  dumps + diff regardless.
- Sub-checks within a scenario are labelled (`[s11_pre_parity]`, …) in the
  output and in retained file names.

### Cross-checkout workflows (S1/S2/S4)

The full S1/S2/S4 scenarios compare the NEW (squashed) code against OLD
(bridge) chain output, which requires two checkouts and a persistent
artifact between them:

1. **On the bridge (pre-squash) checkout**: `--scenario s1_self,s2_self`
   proves the normalizer/seed oracles (two independent fresh installs must
   compare equal) **and writes the reference dumps** to `reference/`
   (`s1_old_chain.sql`, `s2_old_chain_seeds.txt`, each with a
   `-- pk-squash-ref` header recording schema + chain version).
   `--scenario s4_seed` (Mode B, `PK_SQUASH_FLOOR` set) builds the
   persistent below-floor handoff schema `{base}_below_floor` at `floor-1`.
2. **On the squash checkout**: `--scenario s1,s2` compares a fresh
   new-chain install against the references (skipping with a clear reason if
   the reference is stale — chain version mismatch — or was built in the
   other mode); `--scenario s4` asserts the specific `BelowFloorError`
   (struct fields + bridge message, `up` AND `down`) against the handoff
   schema. Any-raise-passes is deliberately impossible: the matcher pins the
   error struct.

Same-mode rule: build references and run their comparisons in the SAME mode
(named-schema refs in `--mode b`, public refs in `--mode a`). Cross-kind
comparison false-diffs on shared-object references (e.g.
`public.gen_random_bytes` inside `uuid_generate_v7`'s body); the harness
detects the mismatch and skips instead of reporting a bogus diff.

## Scenario table (§8.2 → harness ids → status)

**Which range each scenario actually proves — and what is deliberately left
unproven — is `COVERAGE.md`.** Read that first if the question is "is the chain
verified to V164?"; this table is the per-scenario index.

Status as of the full `--mode b` run on 2026-08-08: **21 PASS, 0 FAIL**, three
SKIPs, each named below. The phase labels in the Status column
(**now+DB** = needs only an operator scratch DB; **P2** = repair engine /
manifest; **P3** = squashed registry / baseline / `BelowFloorError`) record which
deliverable a scenario waited on — all of them have since landed, so the labels
are history, not a to-do list. The only scenarios that do not run are the three
SKIPs: `s4_seed` (needs the pre-squash checkout by construction), `s16`
(assertion body pending) and `s18` (manual two-process trigger).

The matrix was re-run after the renumber to `V164` (`6adf55b6`) and the merge of
upstream's own `V163` (`10b36a7d`): 20 PASS, `s1`/`s2` skipped on a stale
reference (the rebuilt references had been written into the bridge checkout's own
`reference/` and needed promoting into this repo — done), and `s22` ERRORed on
`FATAL: remaining connection slots are reserved for roles with the SUPERUSER
attribute` — this shared server sits at 390-398 of 400 connections, so a long run
can lose its slots mid-flight. Neither is a code result; both are re-run
separately.

**The manifest did NOT need regenerating for upstream's `V163`, and regenerating
it here would be a mistake** — see "Manifest + reference policy" below: on this
branch the generator would replay the squashed chain and produce a
self-referential baseline. `V163` adds no manifest object; it converges databases
onto shapes the manifest already declares (`phoenix_kit_email_events.uuid` is
already `uuid`/`not_null` with the `uuid_generate_v7` default there, and its
`_pkey` is already required). What proves manifest-vs-chain agreement is
behavioural and it ran post-merge: `s3`, `s7` and `s8` — the last of which
requires a freshly installed chain to yield an EMPTY repair plan — all pass.

| Spec | Harness id(s) | Oracle (short) | Status |
|---|---|---|---|
| S1 | `s1_self` / `s1` | normalized `pg_dump --schema-only` diff empty (self-oracle strict; full run modulo committed whitelist, any unlisted diff fails) | `s1_self`: now+DB; `s1`: P3 + reference |
| S2 | `s2_self` / `s2` | normalized seed-row dumps identical (uuid/timestamp remapped); email-template absence warned per release-mode tolerance | `s2_self`: now+DB; `s2`: P3 + reference |
| S3 | `s3` | upgrade from `floor` and `floor+k`: deltas only, comment = current, dump + seed parity vs single-run install | P3 |
| S4 | `s4_seed` / `s4` | specific `BelowFloorError` (struct fields + bridge message) from `up` AND `down` | `s4_seed`: now+DB on bridge checkout (+`PK_SQUASH_FLOOR`); `s4`: P3 |
| S5 | `s5` | consumer wrapper replay (i-iv incl. interleaved failure mode + rollback round-trip) | P3 (fixtures; stub) |
| S6 | `s6` | full down to 0 (range + direct baseline down), shared extensions survive, identical re-create | P3 |
| S7 | `s7` | tamper matrix: repair restores each dropped class, extras untouched | P2 (stub) |
| S8 | `s8_pre` / `s8` | double `up()` no-op today; repair idempotence (empty plan ×2, byte-identical dumps) | `s8_pre`: now+DB; `s8`: P2 (stub) |
| S9 | `s9` | divergence report-only, exit 2, no deparse false-positives (same + second PG major) | P2 (stub; second major needs operator container) |
| S10 | `s10` | seeded + user rows + tuned settings survive repair | P2 (stub) |
| S11 | `s11_pre` / `s11` | coexisting-install parity + no-leak snapshots (Mode A adds public-vs-named) | `s11_pre`: now+DB; `s11`: P3 (repair cell with P2) |
| S12 | `s12` | pooled detection, `--unsafe-pooled` degraded mode | P2 (stub; §10 Q6 endpoint) |
| S13 | `s13` | `--adopt` stamp/report/data-invariant gates | P2 (stub) |
| S14 | — | compile/format/credo; extended release_check (min/contiguity/loadable-range/manifest-hash) + the same hash as a plain unit test | not a verify.exs scenario — `mix precommit` today; extensions land in P2/P3 |
| S15 | `s15` | single-step fresh stamps `'{floor}'`; multi-step stamps `'{current}'` | P3 |
| S16 | `s16` | Oban delegated, never manifested; no oban entries in Report | P2 (stub) |
| S17 | `s17` | since/revision scoping (comment-era shape clean, pending reported) | P2 (stub) |
| S18 | `s18` | concurrent migration mid-repair → distinct abort | P2 (stub) |
| S19 | `s19` | `:create_failed` + diagnostics on V137-class data-dependent drift | P2 (stub) |
| S20 | `s20` | comment > `@current_version`: repair hard-errors, doctor warns | P2 (stub) |
| S21 | `s21` | `V164` repair: a flush-defect-damaged install is fully restored (every declared FK validated, every non-exempt `NOT NULL` re-imposed, comments FK back to `SET NULL`), a second pass is a byte-identical no-op, and an orphan-blocked FK is left `NOT VALID` with the row untouched | P3 |
| S22 | `s22` | per-version composition: each delta `V136`..`V164` applied in its OWN migrator invocation yields schema + seeds byte-identical to one single invocation (the `V56`/`V57` defect class) | P3 |

Manual, operator-side (not in the harness): the 2026-07-12 hardened-install
recipe (pre-created schema, no-CREATE role, PG15+ non-writable public)
against baseline + repair.

## Safety rules

1. **NEVER point any of this at a live database.** Scratch DBs / schemas
   only. The live endpoint carries real installs; the only permitted live
   contact is read-only catalog probing, and S12's dry-run cell.
2. **NEVER drop shared objects.** Extensions (citext, pgcrypto, pg_trgm) and
   anything in `public` outside the harness's own Mode A scratch DB may be
   used by other applications in the cluster. `verify.exs` refuses
   `DROP SCHEMA` on `public` outside the gated Mode A reset path, and S6
   asserts that a full `down()` leaves extensions installed.
3. **Mode B never installs into `public`** — shared-DB safety depends on it.
4. **The prefix is always threaded** into `Ecto.Migrator` so
   `schema_migrations` bookkeeping lands in the scratch schema, never in a
   shared `public` (the June draft polluted live `public.schema_migrations`).
5. **Neither script writes to `lib/` under normal use.**
   `generate_baseline.exs` emits its manifest/baseline artifacts under
   `--output-dir` (default `dev_docs/squash/output/`) for hand review — its
   own header is explicit: "nothing is written into lib/ (that is P2/P3)".
   `verify.exs` never writes to `lib/` either. Promoting a reviewed artifact
   into `lib/` is a distinct, manual, P2/P3-only step that neither tool
   takes on its own. Caveat: `--output-dir` is an unvalidated CLI string —
   an operator who explicitly points it at `lib/phoenix_kit/migrations/...`
   defeats this guarantee themselves; that is a deliberate P2/P3 promotion
   action, not sanctioned default behavior.
6. Any SQL added to this tooling follows the prefix-safe rules from
   AGENTS.md: bare index names on CREATE, schema-anchored catalog checks, no
   regclass casts in immediate checks, extensions/schemas only through
   `PhoenixKit.Migrations.Postgres.Helpers`.

## Manifest + reference policy (regenerate, never hand-merge)

- The `ExpectedSchema` manifest is **tool-generated with a deterministic
  emit order and a `chain_hash`**. It is NEVER hand-merged: after any rebase
  that touches `v*.ex`, and after every **renumber event** (eight so far;
  latest V163→V164 2026-08-07, when this delta moved off the `V163` slot upstream's
  own UUID primary-key-integrity migration claimed the next day — see
  `dev_docs/plans/2026-07-14-squash-inventory.md`'s "Post-V161 additions"), regenerate
  it with `generate_baseline.exs` (§8.3 runbook). A migration PR may land with a stale
  manifest; the `chain_hash` assertion in `release_check` **and** its plain-unit-test
  twin are the release-time gate — regeneration must happen before publish. **Known
  stale as of 2026-08-08**: the merge that brought upstream's real `V163` in
  (`10b36a7d`) did not regenerate the manifest, so `expected_schema.ex` currently has
  no knowledge of `V163`'s objects at all (confirmed: `git show 10b36a7d --stat --
  lib/phoenix_kit/migrations/expected_schema.ex` is empty) — regeneration is
  outstanding before the next full verify run can be trusted.
- ⚠️ **Regenerate from a PRE-SQUASH checkout, never from the squashed
  branch.** The generator builds the baseline by replaying the chain it finds.
  On the squashed branch that chain already *starts* with the baseline, so the
  run is self-referential: it can only reproduce what the current baseline
  produces, and it loses everything the baseline knows that a replay of
  `V135..HEAD` cannot show — the pre-floor bimodal drift the manifest depends
  on, and objects created below the floor and dropped above it (`floor_carryover`).
  Observed 2026-08-07: a regeneration run on the squashed branch emitted a
  baseline that no longer seeded `phoenix_kit_role_permissions`, which failed
  s2/s5/s8/s10 (25 seed rows appearing only under repair). The committed
  baseline's own header comment records which kind of run produced it — read it
  before overwriting the file.
- ⚠️ **`chain_hash` is restamped after promotion, not by the generator.** The
  generator cannot know the post-promotion `v*.ex` set — its own emitted
  baseline joins that set only once you copy it into `lib/`, and any later edit
  to a delta moves the hash again. Run
  `mix run dev_docs/squash/restamp_chain_hash.exs --restamp` last, after `mix format`
  (`--check` reports staleness without writing). Skipping it leaves
  `release_check` reporting a stale manifest even though the manifest content
  is correct.
- The S1/S2 reference dumps in `reference/` follow the same policy:
  tool-written by `s1_self`/`s2_self` on the bridge checkout, header-stamped
  with the chain version, regenerated whenever the chain head moves, never
  edited by hand. The harness refuses stale references (`SKIP:reference-stale`)
  instead of comparing against them.
- Version-comment lore for anyone debugging scratch installs: after a
  renumber event the DB's version comment can LIE about the content it
  describes (observed live 2026-07: a comment claiming N while holding the
  renumbered N+1 content). Trust marker probes (catalog checks for
  version-specific objects) over the raw comment when they disagree — this
  is also why §6.4's `--heal-comment` is probe-driven.
