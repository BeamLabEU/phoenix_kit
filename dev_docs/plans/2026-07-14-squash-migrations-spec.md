# Migration-chain consolidation (squash) + verify-and-repair — SPECIFICATION

Status: **REVIEWED DRAFT r2** (spec only; implementation not started).
Written 2026-07-14 at v1.7.193/V148; revised 2026-07-16 at v1.7.196/V150; counters refreshed
2026-08-07 at **v1.7.233/V164** (chain V01..V164 — 162 upstream + our V164 repair; 28,000 lines across 163 files — V148→V164 in three weeks of spec/tooling work, live confirmation of §3.1's cadence point; V152-V160 delta
classified in the inventory appendix);
**r2 = post-review revision** incorporating a 7-reviewer round:
4 internal adversarial agents (claims / design / completeness / ops) + GLM-5.2, Kimi K2.7,
Mistral Medium. Verdicts: claims-verifier APPROVE (all mechanical claims confirmed against HEAD;
line refs re-anchored below), all others NEEDS-WORK → their ~50 findings are folded in here.
Branch: `squash-migrations` (merged with feature/core-owned-redirect-destinations = upstream 1.7.233 + redirect work, 2026-08-07).
Supersedes: `2026-06-15-squash-migrations-plan.md` (June plan; stale).
Companion: `2026-07-14-squash-inventory.md` (per-version classification of all 150 migrations, since
extended by its own addenda through `V164`).

**Counters re-checked 2026-08-08** (after `10b36a7d`, the merge of upstream's own `V163` — "UUID
primary-key integrity", PR #688 — landed the day after this file's 2026-08-07 refresh; see the
inventory's "Post-V161 additions" for the version-by-version detail). The "162 upstream + our V164
repair; 163 files" accounting on the line above was correct on 2026-08-07 — at that point this
branch's own repair delta had just moved to `V164` (leaving the `V163` slot deliberately open) and
upstream's real `V163` had not yet been merged in. It is one version behind reality now: the
pre-squash chain this line describes would be 164 files (`V01`..`V162`, upstream's real `V163`,
and this branch's `V164`), not 163. It is **not** what `lib/phoenix_kit/migrations/postgres/`
actually ships, which is unaffected either way — the squash already ran (floor 135, §4), so the
shipped chain is 30 files (`V135` baseline + `V136`..`V164`, 29 deltas), a number this line was
never describing. Left as originally written above rather than edited in place, since the
surrounding prose ties it to specific reviewer-round claims verified against that exact HEAD;
corrected here instead so a reader checking "does the file count match reality" is not misled.

All `postgres.ex` line refs are re-anchored to v1.7.196 HEAD (verified by grep; 1.7.197-198
added only the V149-V151 moduledoc entries above the code section — same-shift caveat applies):
`@initial_version`/`@current_version` :1311-1312, `@uuid_fn_version` :1319, `up/1` :1328-1343,
`down/1` :1346-1370, `migrated_version/1` :1373-1410 (legacy no-comment→1 at :1400), heal
:1530-1568, `version_checks/0` :1572-1586, dispatch :1627-1629, `handle_version_recording/4`
:1641-1655 (multi-step-only stamp :1646-1648), `record_version/2` :1686-1689.

---

## 0. Goal and non-goals

**Goal.** Collapse versioned migrations `V01..V{floor}` into ONE baseline module `V{floor}`,
keeping `V{floor+1}..V{current}` as individual deltas, reproducing the resulting schema
**byte-for-byte modulo an explicit, enumerated divergence whitelist** (§5.1 `:legacy_optional`;
the old chain itself produces bimodal end-states — see §3.7), without breaking any existing
install, including consumer apps' accumulated wrapper migrations. Additionally ship an
idempotent, additive-only **verify-and-repair** capability safe against live production DBs:
verifies every expected object, creates only what is missing, reports (never fixes) anything
divergent.

**Non-goals.** No schema changes; no data conversions beyond what the chain already does; no
change to the version-tracking mechanism (COMMENT on `{prefix}.phoenix_kit`); no per-module
migration chains (modules have none — all module DDL lives in the core chain, §3.3); no
automatic destructive repair, ever; repair is NOT a migration bridge (§6.4).

---

## 1. Ratified decisions (summary)

| # | Decision | Choice |
|---|---|---|
| D1 | Floor rule | `floor = min(confirmed migrated_version across the COMPLETE surveyed set of supported installs)`; parameterized in tooling; fixed only at execution time from FRESH readings (DBs can regress via backup restores). Margin below the confirmed min is false safety — survey completeness is the binding input |
| D2 | Floor candidate today | **160** — the committed-set minimum (operator confirmed 2026-08-04 that the local host app is the ONLY install under the seamless-upgrade commitment; its live DB reads V160). All design text stays `{floor}`-parameterized; external/public Hex consumers ride the permanent bridge (D9) at any floor |
| D3 | Skip semantics | Unchanged Oban-style comment-gated skip |
| D4 | Below-floor contract (existing installs) | `0 < migrated < floor` → hard `BelowFloorError` (bridge message; test-DB variant says `mix test.reset`) in `up/1`, `down/1`, and generator tooling |
| D5 | Single source of truth | One tool-generated **ExpectedSchema manifest** spanning `V01..@current_version` (objects tagged `since:`, shape-`revisions:`, `presence:`, plus data-invariant assertions); baseline `V{floor}.up` applies its `since ≤ floor` slice; verify/repair consume the same manifest |
| D6 | Repair placement | `PhoenixKit.Migrations.Repair` (runtime, immediate queries, raw comment read) + `mix phoenix_kit.repair`; never re-executes delta modules; Oban is delegated, never manifested |
| D7 | Backfills | Zero historical backfills in the baseline; repair backfills only columns it itself just added, from declared defaults |
| D8 | Version | **2.0.0**; every future floor raise is likewise a MAJOR bump with its own bridge (§7.3) |
| D9 | Rollout | Two-stage delivery: pre-squash PR (repair engine + generator + tooling fixes, zero `v*.ex` contention), then ONE atomic squash PR with a same-day regenerate-rebase-merge protocol; last 1.7.x = frozen bridge (permanently available on Hex; ~90 days = security-backport window only) |
| D10 | Baseline construction | Generated from a real migrated scratch DB by **incremental per-version catalog introspection** (→ `since`/revision tags), emitted deterministically in `Helpers.*` idioms, hand-reviewed, verified by normalized dump + seed-row diffs; repeatable tool |
| D11 | Re-squash cadence | Institutionalized (delta > ~100 versions or annually); each re-squash = major bump + its own bridge; manifest regeneration is per-migration-release regardless |
| D12 | Verification env | Operator-provided scratch DB (§8.1); nothing destructive near the live DB; at least one matrix cell on a second PG major |
| D13 | Fresh-DB clamp | `initial == 0` with `opts.version < floor` → clamp: run the baseline, don't raise. Contract: covers PK **wrapper** migrations only; consumer-authored migrations depending on below-floor intermediate shapes are a documented breakage class (§5.3) |

---

## 2. Background: machinery facts (verified at HEAD v1.7.196)

- Version state = table COMMENT on `{prefix}.phoenix_kit`, read via `obj_description`
  (`postgres.ex:1373-1410`); *table exists but no comment → legacy-mapped to version 1*
  (`:1400`); table absent → 0. Written by `record_version/2` (`:1686-1689`) and by every version
  module self-stamping (150/150 currently self-stamp; the multi-step auto-stamp `:1646-1648`
  fires only when `total_steps > 1` — single-step runs rely entirely on self-stamps, which the
  D13 clamp path depends on).
- `up/1` (`:1328-1343`): fresh → `change(@initial_version..target)`; behind → deltas with a
  `uuid_generate_v7` re-ensure when starting ≥ V40 (`:1337`); at/ahead → silent no-op
  (`:1340-1341`).
- Dispatch is dynamic (`:1627-1629`); a missing module in the live range raises
  `UndefinedFunctionError`. NOTHING checks range completeness today (release_check asserts only
  the max — §5.3). Direct calls to `PhoenixKit.Migrations.Postgres.VNN` bypass `up/1` guards
  entirely; they are not a supported API and get no clamp (documented, not defended).
- `down/1` (`:1346-1370`) rolls `current..(target+1)`; the target itself is not down-migrated.
- `@initial_version 1` / `@current_version 150` (`:1311-1312`); `@uuid_fn_version 40` (`:1319`);
  heal registry `version_checks/0` holds exactly `{83, …}` (`:1572-1586`).
- `ensure_current/2` (`migration.ex:308-324`) re-enters `up/1` on every test boot
  (`test/test_helper.exs:49`, `prefix_migration_test.exs:66-67,191`).
- Consumer surface: installer emits an **unpinned** `add_phoenix_kit_tables.exs`;
  `phoenix_kit.update` emits pinned wrappers with `@disable_ddl_transaction true`, from-version
  from the live DB comment (`update.ex:415-540`); `gen.migration` derives from-version from
  FILENAMES and scans for `create_phoenix_kit_tables` while the installer writes
  `add_phoenix_kit_tables` (`gen.migration.ex:83`) — pre-existing bug.
- 2026-07 prefix-safety overhaul (PR #628/#631) is load-bearing: `Helpers.validate_prefix!/1`,
  privilege-aware `ensure_extension!`, schema-qualified `ensure_uuid_v7_function` +
  `uuid_v7_call/1`, bare index names on CREATE, schema-anchored checks, name-based
  `pg_constraint` JOINs — never regclass casts in immediate checks (V146 trap: 25P02 poisons the
  whole migration transaction).
- In-repo repair prior art: `UUIDRepair` (runtime additive repairer + dry-run),
  `heal_version_comment/2` (artifact-probe → stamp, raise-only), `mix phoenix_kit.doctor`
  (report-only, PgBouncer heuristic `doctor.ex:155-174`), V141 normalize-on-every-up, `Helpers`'
  dual migration/runtime variants.

## 3. Key research facts that shaped the design

1. **Churn kills frozen baselines**: ~30% of legacy files modified in the last month; ~16 new
   versions/month; **six** renumber events (latest V151→V152, 2026-07-15). Baseline must be
   tool-regenerable.
2. **The chain is not uniformly idempotent**: early files (V10) crash on re-run; V20's bucket
   seed has no conflict guard; V35 seeds via upsert. Repair needs the manifest, not chain re-runs.
3. **Feature modules have no own chains** — all module DDL (catalogue/locations/warehouse/crm/
   staff/…, incl. V149) lives in core versions; the baseline covers module tables too.
4. **One local consumer** (`/www/app`, Andi, verified at '147', no drift; 41 wrapper files —
   §5.3's regression surface, including real consumer-authored migrations that ALTER phoenix_kit
   tables, e.g. `20260402133000_phoenix_kit_catalogue_v013_base_price.exs`). docker1 numbers are
   operator-confirmed only and stale.
5. **No ecosystem precedent** (upstream: zero squash intent; Oban never squashed at ~2
   versions/year vs our ~16/month). Django (bridge-in-time, elidable data ops) and Rails
   squasher (baseline from real DB state) supply the transferable rules.
6. **Verification env is read-only today**: direct PG 17.4 at 172.18.0.13:5432 OK (pgpass host
   field stale), psql/pg_dump 17.10, NO createdb, PgBouncer must never carry DDL.
7. **The old chain's end-state is bimodal** (single-run installs vs incrementally-upgraded
   installs differ), because immediate-query guards see pre-flush state on single runs: fresh
   single-run chains RETAIN `users.preferred_locale` + index (V30's immediate guard misses V28's
   queued add — `v30.ex:91-105`) and BOTH V13+V22 duplicate partial unique indexes; upgraded
   installs don't. Verified live: bimodality is real in the fleet (Andi's initial install was a
   single multi-step run). Consequence: "byte-for-byte" needs the §5.1 `presence:` model and the
   S1 whitelist.

---

## 4. Floor decision

**Rule (D1):** floor = min(confirmed `migrated_version`) across the **complete** list of installs
the maintainer commits to seamless upgrades for. No margin below the confirmed min (a margin
protects nothing an unsurveyed install wouldn't also break; the guard + permanent bridge protect
stragglers at ANY floor). Confirmation must be a **fresh reading at implementation time** —
`migrated_version` can regress via backup restores.

**Data (2026-07-16 — CONFIRM BEFORE IMPLEMENTATION):**

| install | version | as of | status |
|---|---|---|---|
| Andi/MebelKit (local host app) | 160 | 2026-08-04 | verified live (obj_description) |

Operator confirmed (2026-08-04): this one-row table IS the complete seamless-upgrade set — the
external DEV/prod installs listed in the June task file are no longer in scope and their names
were removed from these documents. Everything else (unknown public Hex consumers included) is
bridge-path by design: the guard raises with the stopover message at ANY floor, and the bridge
release stays on Hex permanently (§7.2).

**Floor candidates** (repo at V164, 28,000 lines / 163 files; per-floor deleted-line figures
unchanged since 1.7.193 — v01..v147 never touched, verified by git diff):

| floor | legacy files removed (v01..v{floor-1} deleted + v{floor} replaced by baseline) | lines removed | delta files remaining |
|---|---|---|---|
| 110 | 109 + 1 | 19,725 | 53 |
| **121** | 120 + 1 | 21,537 | 42 |
| **135** | 134 + 1 | 23,231 | 28 |
| 147 | 146 + 1 | 25,155 | 16 |
| **163** | 162 + 1 | 27,950 | 0 |

---

## 5. Design

### 5.1 ExpectedSchema manifest + thin baseline `V{floor}`

```elixir
defmodule PhoenixKit.Migrations.ExpectedSchema do
  @moduledoc false  # tool-generated; documented in Repair's docs; huge module must not hit hexdocs
  # Regenerated by the generator (§8.3) whenever a migration is added. Deterministic emit order
  # (since, class, id) so diffs are append-mostly; NEVER hand-merged — regenerate after rebase.
  # Object.t :: %{
  #   id: String.t(), class: :extension | :function | :sequence | :table | :column | :index
  #        | :constraint | :seed | :comment,          # NO :oban class — Oban is delegated (§6.1)
  #   since: pos_integer(),                           # version that INTRODUCED the object
  #   revisions: [{as_of_version :: pos_integer(), shape :: map()}],  # ordered; multi-step
  #        # objects (e.g. role_permissions.module_key VARCHAR(50)@53 → VARCHAR(120)@142) carry
  #        # one revision per alteration; single-shape entries are FORBIDDEN for any object the
  #        # generator's per-version diff pass saw altered
  #   presence: :required | :legacy_optional,         # :legacy_optional = known bimodal drift
  #        # (§3.7: preferred_locale + index, V13-vs-V22 duplicate index): verify reports
  #        # info-level either way; repair NEVER creates them
  #   check: {:catalog, spec} | sql,                  # parameterized, schema-anchored, non-raising
  #   create: sql | {:helper, mfa},                   # additive-only
  #   backfill: nil | :default | {:manual, sql_text},
  #   owner: atom()}                                  # best-effort table-family tag (:catalogue,
  #        # :warehouse, :crm, ... :core fallthrough) for future per-module extraction slices —
  #        # informational only, never load-bearing for verify/repair correctness
  # plus: data_invariants :: [%{since: v, assert: sql, desc: ...}] — generator-emitted assertions
  #   for upgrade-only transforms (minimum set: post-V114 no composite "integration:*" settings
  #   keys; V137 email_events/aws_message_id uniqueness; V109/V77 renamed keys absent). Used by
  #   verify (report-only) and as the --adopt gate (§6.4 R4).
  def objects(prefix) :: [Object.t()]
  def data_invariants() :: [...]
  def chain_hash() :: String.t()   # hash over v*.ex set at generation time (staleness detector)
end

defmodule PhoenixKit.Migrations.Postgres.V{floor} do
  use Ecto.Migration
  def up(opts)    # applies the since <= {floor} slice via queued execute/flush, class-ordered:
                  # extensions < functions < SEQUENCES < tables < columns < indexes < constraints
                  # < seeds < comment (sequences before tables: V140 nextval() column DEFAULTs);
                  # ALWAYS self-stamps '{floor}' regardless of range membership (single-step runs
                  # get no auto-stamp; multi-step range-end stamp then overwrites — correct, S15)
  def down(opts)  # teardown of the baseline slice to version 0 (reverse order) +
                  # Oban.Migration.down; never drops shared extensions / public functions
end
```

Baseline content requirements (details per inventory; all floors below assume ≥ 121):

- Owns V01's semantics: schema pre-check + `CREATE SCHEMA` only when missing and
  `create_schema: true`, else operator-facing raise.
- Extensions via `Helpers.ensure_extension!/1` (citext, pgcrypto, pg_trgm), immediate, before
  queued DDL. Functions via `Helpers.ensure_uuid_v7_function/1` + `extract_primary_slug()`
  (`v52.ex:41`); all call sites via `Helpers.uuid_v7_call/1`. `@uuid_fn_version 40` + the `up/1`
  re-ensure stay.
- **At-floor shapes, not final-state.** Every object present at V{floor} is emitted in the shape
  it had AT the floor — its newest revision with `as_of_version <= floor` — including an object a
  still-surviving delta ABOVE the floor later alters or drops. This is the opposite rule from the
  manifest (§5.1 above, final-state only): a delta module is written against the shape the chain
  would actually have produced by that point, so if the baseline silently omitted an object because
  it's absent from the fully-migrated FINAL schema, the first still-live delta touching it has
  nothing to act on and the chain breaks. Confirmed live: `V152.up/1`'s bare `ALTER COLUMN
  list_uuid DROP NOT NULL` against a floor-135 baseline that never created the column, because
  V156 — above the floor — drops it later and a final-state-only baseline excludes it on that
  basis alone, with no floor-awareness. Concretely: an object belongs in the baseline when
  `since <= floor` AND (`dropped_at` unset OR `dropped_at > floor`); objects dropped AT OR BELOW
  the floor are correctly absent from both the baseline and the manifest (the ordinary case).
  Bare index names; per-column `ADD COLUMN IF NOT EXISTS` coverage for repair-mode column healing;
  constraints via name-based catalog guards; NO regclass in immediate checks.
- **Oban**: `Oban.Migration.up(prefix:, create_schema: false)` exactly as V27; Oban objects are
  **delegated, never manifested** — verify/repair resolve Oban state via `Oban.Migration`'s own
  version/diagnostics, not shape comparison (host Oban versions legitimately differ; a manifested
  snapshot would flag every host as drifted).
- **Seeds (final state)**: roles (SupportAgent as `DO NOTHING`, not the historical upsert),
  settings with final keys/values/module tags (V03 seeds carry `module='system'`; V35 `tickets_*`
  keys materialize as `customer_support_*` at any candidate floor — V77→V109 double rename; no
  `ai_text_processing_slots`), currencies, payment options, storage dimensions, admin role
  permissions (after roles, conditional on Admin; the V53 'tickets' permission key materializes
  as 'customer_support'), publishing/legal/… settings. **V20 bucket seed gets a
  `WHERE NOT EXISTS` guard** (no unique constraint to hang `ON CONFLICT` on). **System email
  templates**: manifest `:seed` entries with `create: {:helper, {mod, fun, args}}` wrapping the
  existing seeder in the same apply/rescue best-effort semantics (their only current call sites,
  `v15.ex:130-151`/`v31.ex:523-525`, die with the deleted files — without this, 2.0 fresh
  installs ship an empty templates table and S2 as first drafted would not notice).
- No historical backfills (D7).

### 5.2 Registry changes (`postgres.ex`)

- `@initial_version {floor}`; `@current_version` unchanged.
- **`up/1`** (new cond order):
  1. `initial > 0 and initial < @initial_version` → raise `PhoenixKit.Migrations.BelowFloorError`
     (struct fields: db_version, floor, bridge_version, message; message names the bridge; the
     `ensure_current/2` path decorates it with the test-DB hint "if this is a test/CI database,
     run `mix test.reset`" — GLM M6: a consumer's persistent CI DB is the common below-floor case
     and "install the bridge" is the wrong advice there).
  2. `initial == 0` → clamp (D13): `change(@initial_version..max(opts.version,
     @initial_version), :up, opts)`. Covers pinned below-floor wrappers AND pathological
     `version: 0`/negative pins. Consumer-facing doc: `up(version: 27)` on a fresh DB now lands
     at `{floor}`, not 27 — by design.
  3. `initial < opts.version` → deltas as today (uuid re-ensure retained).
  4. else `:ok`. (A comment ahead of `@current_version` is a silent no-op here — repair/doctor
     own that detection, §6.4 R6.)
- **`down/1`**: `0 < current < @initial_version` → `BelowFloorError` (note: a below-floor install
  cannot uninstall via 2.0.0 — bridge first; documented). Targets: `target == 0` → full teardown,
  implemented as `change(current..(floor+1)//-1, :down)` **plus a direct `V{floor}.down(opts)`
  call outside the range machinery** — the range MUST NOT cross the floor boundary or it
  dispatches deleted modules (GLM M3). `0 < target < @initial_version` → clamp target to
  `@initial_version` with a logged warning.
  **Clamped-down invariant (stated, tested):** a clamped down is a *recorded no-op* — Ecto marks
  the consumer wrapper rolled back while the PK comment stays at `{floor}`; the disagreement is
  intentional; below-floor rollback of PK state is unsupported (only `version: 0` teardown
  changes pre-floor state). Consumer downs interleaved below floor run against the floor shape —
  must be shape-guarded (same breakage class as §5.3). verify/doctor flag "comment at floor but
  consumer wrapper history rolled back" as a warning.
- Moduledoc collapse; stale V27-era examples fixed; `version_checks/0` `{83,…}` dropped (heal
  mechanism stays); `UUIDRepair` + its update-task caller retired.
- Terminology: "below-floor" (hyphenated) everywhere, matching `BelowFloorError`.

### 5.3 Consumer-app compatibility — scope and limits of the guarantee

**Guaranteed (no consumer changes):** replay of PK **wrapper** migrations — unpinned installer
first (jumps to current; clamp never fires) or pinned below-floor chains (clamp → baseline →
no-ops → deltas). Traced and test-pinned (S5 i/ii).

**NOT guaranteed (documented breakage class):** consumer-AUTHORED migrations interleaved between
wrappers that depend on below-floor intermediate shapes — any object in the inventory's
Drops/renames list (43 versions: V74 bigint-id drops, V47/V80 string→JSONB, V84 `mailing_*`→
`newsletters_*`, V89 `price`→`base_price`, …). Real instance in the flagship consumer:
`…_phoenix_kit_catalogue_v013_base_price.exs` (survives only via its hand-added IF EXISTS
guard); `…_add_prefix_to_phoenix_kit_cat_catalogues.exs` shows the unguarded pattern. Pre-squash
these replayed against the exact intermediate shape; post-squash they replay against `{floor}`
shape. Remedy (upgrade guide, named breakage class): shape-guard such migrations (IF EXISTS /
column checks) or collapse history — **`mix phoenix_kit.consolidate_wrappers` is promoted from
nice-to-have to a shipped 2.0.0 deliverable** (collapses accumulated wrappers into one; makes
the class moot for repos that adopt it). S5 gains variant (iii) pinning the documented failure
mode and (iv) a rollback→migrate round-trip (§8.2).

**Tooling:**
- `mix phoenix_kit.update`: unaffected mechanically (from-version = live comment); add
  generation-time below-floor refusal with the bridge message; upgrade guide: confirm comment ≥
  floor on EVERY environment's DB (dev/staging/prod) before bumping the pin — a dep bump bundled
  with an unapplied wrapper otherwise fails at deploy-time migrate (risk row §9).
- `mix phoenix_kit.gen.migration`: fix the `create_`/`add_` filename-scan bug; emitted `down`
  pins clamp-safe versions.
- `mix phoenix_kit.release_check`: add `min(vNN on disk) == @initial_version`, contiguity of
  `{floor}..{current}`, loadable-module range assertion, manifest `chain_hash` freshness. PLUS a
  DB-free unit test in the plain `mix test` suite asserting the same hash (release_check runs
  only via the `prerelease` alias and CI is manual-only — the habitual gate must catch staleness
  too).

**Test surface (per-floor disposition; task file requires it):** at floor 121 delete
`v106/v107/v112/v113/v114_test.exs` (reference deleted modules → S14 compile gate), floor 135
additionally `v125_test.exs`; `v145_test.exs` survives all candidates. Load-bearing schema-state
assertions from deleted tests (e.g. V112's dropped-index and NULL-vs-0 pins) migrate into
manifest `expected` revisions exercised by S8/S9. New unit tests: below-floor guard messages,
clamp arithmetic, range-completeness.

### 5.4 Deliberately NOT carried into 2.0.0

Historical backfills below floor (bridge carries them); `UUIDRepair` + caller;
`PhoenixKit.Migrations.UUIDFKColumns` (callers v56/v57/v70 are all below any candidate floor —
orphaned dead code otherwise); the `{83,…}` heal entry; stale `describe_version_changes`
hardcodes + `migration.ex` moduledoc `version: 2` examples; phantom `Migrations.SQLite`/`MyXQL`
references (`migration.ex:326-333`). **Docs cleanup includes AGENTS.md/CLAUDE.md**: its
prefix-safe-migrations section pins semantics to V01/V27/V40/V51 files that the squash deletes —
rewrite those references to the baseline module + Helpers.

---

## 6. Verify-and-repair

### 6.1 Architecture: one manifest, three consumers, no delta re-execution

```
lib/phoenix_kit/migrations/expected_schema.ex     # generated manifest (§5.1)
lib/phoenix_kit/migrations/postgres/v{floor}.ex   # thin baseline (slice since <= floor)
lib/phoenix_kit/migrations/repair.ex              # runtime executor: verify/repair
lib/mix/tasks/phoenix_kit.repair.ex               # UX
```

```
mix phoenix_kit.repair [--dry-run] [--prefix P] [--json] [--adopt] [--unsafe-pooled]
                       [--heal-comment]
# exit codes: 0 clean / 1 repairs applied-or-pending / 2 report-only divergences present
```

**Comment reading:** repair reads the **raw** `obj_description` (NULL vs numeric) and NEVER
routes through `migrated_version/1`'s legacy no-comment→1 mapping (`postgres.ex:1400`) — that
mapping would swallow the half-installed/adopted case into the below-floor error (§6.4 R3/R4
dichotomy). Migration entry points keep the legacy mapping; repair does not.

**Scope rule:** repair applies manifest objects with `since <= comment` only, each at the newest
**revision** with `as_of_version <= comment` (never a future shape — the later delta performs the
alteration exactly as the chain would). Objects with `since > comment` are *pending migrations* —
reported, never pre-applied (deltas may carry data migrations that must run through the chain).
Delta modules are never re-executed (V137 dedup-DELETE / V144 conditional-DROP class is
chain-legal but repair-illegal). Verify compares each object against the same revision choice —
so a healthy DB at comment 135 with `module_key VARCHAR(50)` (final shape arrives at V142) is
clean, not falsely divergent.

**Concurrency (one direction enforced, the other detected):** repair takes a session-level
advisory lock, pinned to one connection via `repo.checkout/1`. `Postgres.up/down` take the SAME
key, as a transaction-scoped `pg_try_advisory_xact_lock` in a bounded wait loop. That makes one
direction real on every path: **a chain run cannot start while a repair holds the lock** — it
waits, announces the wait, and fails with an actionable message rather than hanging if the lock
is never released. The reverse is NOT prevented: the wrappers `mix phoenix_kit.update` and
`phoenix_kit.gen.migration` generate set `@disable_ddl_transaction true`, and `Ecto.Migrator`
runs such a migration outside a transaction (and in a `Task` with its own pooled connection), so
the migration side's lock is released after its own statement and a repair starting mid-run is
not blocked. A session-level lock cannot fix this: without an enclosing transaction each
`repo()` query may check out a different connection, so lock and unlock would land on different
backends. Closing that direction needs a different mechanism (e.g. repair holding a conflicting
lock on `schema_migrations`, as Ecto's own `:table_lock` strategy does) — out of scope here.
Until then the reverse race is caught, not prevented, by the comment re-read below. Repair
re-reads the comment immediately after acquiring the lock and again before the final verify —
if it moved, abort with a distinct "concurrent migration detected" status (S18). The create path
tolerates `duplicate_object`/`duplicate_column` as `:already_present` (races resolve additively).
Any `create` failure (e.g. unique index over data whose dedup-delta never ran — Kimi's V137
scenario) is caught per-statement and reported as `:create_failed` with a diagnostic query, never
a crash, never an implicit retry (S19).

Execution: validate prefix → resolve repo (pooled probe §6.3) → advisory lock → read raw comment
→ branch per §6.4 → apply/verify slice class-ordered (extensions < functions < sequences <
tables < columns < indexes < constraints < seeds; comment handled ONLY per §6.4, not as a generic
sliced object) → `Oban.Migration.up(prefix:, create_schema: false)` → re-read comment → final
verify (objects + data invariants, report-only) → comment policy → `Report`.

### 6.2 Additive-only safety rules (engine-enforced)

Never: DROP anything, ALTER TYPE, SET/DROP NOT NULL on pre-existing columns, UPDATE/DELETE user
data, rename, touch objects outside `phoenix_kit*`/`oban_*` in the target schema. Generator
restricts `create` to `CREATE…`/`ALTER … ADD …`/`INSERT … ON CONFLICT DO NOTHING` (or
`WHERE NOT EXISTS`)/`COMMENT`. Repair-mode backfill: only the declared default of a column repair
itself just added. Seeds: strict `DO NOTHING` (never clobber operator-tuned values).

**Divergence detection is structural, not deparse-text** (PG majors render `pg_get_indexdef`/
`pg_get_constraintdef` differently — cast decoration, ANY(ARRAY[…]), NULLS NOT DISTINCT):
columns via `information_schema`/`pg_attribute` attributes (type, typmod, nullability, default
normalized through the TARGET server's `pg_get_expr`); constraints via
contype/conkey/confkey/confdeltype + predicate re-normalized on the target; indexes via
indkey/opclass/predicate likewise; raw-text equality only where no structural decomposition
exists. Preflight asserts `server_version` within a declared supported range (§6.3).
Severity mapping (explicit, load-bearing for R4): `:missing`+creatable → repaired/would_repair;
wrong type/length/default, unexpected NOT NULL, divergent index/constraint definition,
`:create_failed`, failed data invariant → **error-severity, report-only**; `:legacy_optional`
presence either way, unknown extra `phoenix_kit_*` objects, pending versions → info.

### 6.3 Environment rules

Immediate `repo.query!/3` per statement, autocommit, no queued `execute`, no regclass casts.
PgBouncer: detect pooled connections (doctor heuristic + `pg_backend_pid()` sampling), warn,
require `--unsafe-pooled` (skips FK `VALIDATE` + advisory locking). Direct connection
recommended/documented (Andi runtime rides `pgbouncer:6432`; repair targets 172.18.0.13:5432).
No `CREATE INDEX CONCURRENTLY` in v1. FKs added `NOT VALID` + `VALIDATE` (validation failure →
leave NOT VALID, report orphan diagnostic).

### 6.4 Version-comment policy (raw comment; R# referenced from code)

1. **Never lower the comment.**
2. Numeric comment in `[floor..current]`: heal drift within the claimed version (revision-scoped
   slice); comment untouched; pending deltas reported. **Stale-LOW comment** (schema demonstrably
   ahead of comment — marker probes for versions above it succeed; the V80 class and the 2026-06
   renumber incident): repair does NOT auto-raise; it reports prominently with the evidence and
   offers `--heal-comment` (generalized `heal_version_comment`: stamp the highest version whose
   marker probes all pass). Warning attached: running `mix phoenix_kit.update` from a stale-low
   comment re-runs deltas whose data ops are not all no-ops (V137 dedup, V141 normalize).
3. Numeric `0 < comment < floor`: hard `BelowFloorError`, bridge message. Repair is a
   completeness tool, not a migration bridge — non-additive intermediates (V58 timestamptz, V74
   PK promotion, V114 key rewrite) cannot be bridged additively.
4. Comment **NULL** (or meta table absent) while `phoenix_kit*` tables exist — the
   half-installed / adopted / PgBouncer-ate-the-comment class: refuse by default, name `--adopt`
   in the message (NOT the bridge — the bridge's 1.7.x `up(from=1)` would replay non-idempotent
   early files into a built schema). `--adopt` applies the **`since <= floor` slice only**, then
   stamps `'{floor}'` **iff** the verify pass shows zero `:missing` AND zero error-severity
   divergences AND all floor-level data invariants pass; then directs to `mix phoenix_kit.update`
   for deltas (whose guarded data ops re-establish delta-era invariants through the real chain).
   Any failure → no stamp, report, message "this DB has pre-transform data or divergent objects;
   --adopt is not a migration bridge".
5. Lying-HIGH within `[floor..current]`: healed naturally by R2 (missing objects ≤ comment get
   created); newest-version marker cross-check flags "comment ahead of schema" as a warning.
6. **Comment > `@current_version`**: hard error ("DB claims version N but this code supports
   ≤ {current}; upgrade phoenix_kit first") — both in repair AND as a doctor/verify warning;
   `up/1` silently no-ops in this state, so repair/doctor are the only detection surface.

---

## 7. Versioning, rollout, upstream

### 7.1 Version: 2.0.0

Breaking upgrade contract → MAJOR. Hex-resolver mechanics: loose `~> 1.7` pins never auto-resolve
to 2.0.0 — stragglers stay safe; NB the property protects **direct** pins only (a
transitive-only consumer gets pulled once modules widen; the guard is the loud backstop).

### 7.2 Sequencing (two-stage, no hold-window)

1. **Pre-squash PR** (lands first, zero `v*.ex` contention, works at `@initial_version 1`):
   repair engine + ExpectedSchema generator + manifest + gen.migration/release_check fixes +
   consolidate_wrappers. Independently valuable (repair works against the FULL chain).
2. **Atomic squash PR**: baseline `V{floor}` + deletions + `@initial_version` bump + guards/clamp
   + test-surface disposition + docs. Merge protocol agreed with the maintainer: regenerate
   manifest at merge-day HEAD, rebase, merge same day (hours, not a multi-day hold — at ~1.4
   releases/day a hold-window ask is unrealistic and, since the baseline consumes no new version
   number, unnecessary).
3. Bridge = last 1.7.x tag; **permanently available on Hex** (packages are immutable) — the
   stopover path never expires; the ~90-day window bounds security backports only. Documented
   path: pin bridge → update → confirm ≥ floor on EVERY environment → move to `~> 2.0`.
4. CHANGELOG/@version: maintainer-sanctioned for this task.

**Status, checked 2026-08-08 against `git log upstream/main..HEAD` and the working tree.** The
content of both stages has been built — item 1's repair engine/generator/manifest/gen.migration
fixes landed first (commit `0e4d8e0d`), item 2's baseline + deletions + registry guards landed
after (commit `af86e3af`) — but the *delivery* mechanism this section specifies (two independently
mergeable PRs, the first with "zero `v*.ex` contention") has not happened: both stages are commits
on this one branch, `squash-migrations`, and nothing from it has merged to `upstream/main` yet. The
PR this branch is about to open (`dev_docs/pull_requests/2026/squash-migrations-PR.md`) is
therefore a single PR carrying both stages, not the first of two — whether the maintainer wants it
split before review is now their call, not a decision this branch made for them; flagged as an open
item in the PR description. Item 3's bridge is no longer abstract: `mix.exs` on this branch reads
`@version "1.7.235"`, and that is the concrete tag the upgrade guide
(`dev_docs/guides/2026-08-07-upgrading-to-2.0-guide.md`) names as the bridge — but it is still the
in-progress version on an unmerged, unreleased branch, not a cut, tagged Hex release; "permanently
available on Hex" is a property it will have once published, not yet. Item 4 (CHANGELOG entry, the
`@version` bump itself to `2.0.0`) has not been touched, per this task's own instruction that both
files are maintainer-owned — confirmed by `git diff --stat` showing neither file changed on this
branch.

### 7.3 Re-squash institutionalized

Policy: re-squash when delta > ~100 versions or annually. **Every floor raise is a MAJOR bump
with its own bridge release** (the 7.1 auto-pull argument applies identically to every raise;
"2.x minors for floor raises" is withdrawn as self-contradictory). Manifest regeneration happens
per migration-adding release regardless; re-squash then reduces to re-slice + delete + bridge.
Re-squash correctness itself is an UNTESTED invariant of this spec (deferred; first re-squash
must re-run the full matrix).

### 7.4 Module-ecosystem pin coordination (new; blocking for adoption)

Every published `phoenix_kit_*` module pins core with a three-segment `~> 1.7.x` requirement
(verified in /www: manufacturing/warehouse `~> 1.7.190`, locations/catalogue/ecommerce
`~> 1.7.189`, projects `~> 1.7.130`, document_creator `~> 1.7.118`; survey the rest — billing,
comments, entities, staff, crm, ai, publishing, sync, …). Consequence: `{:phoenix_kit, "~> 2.0"}`
+ any module = hard resolver conflict; hex-based consumers are blocked from 2.0.0 until ALL
module packages ship widened pins (`"~> 1.7.196 or ~> 2.0"`). Verified: no module calls migration
internals → widening is a **patch release per module** (~14 coordinated releases), sequenced
BEFORE/with the 2.0.0 publish (P5). Risk row §9; consumers advised to keep a direct core pin
(transitive auto-pull).

**Re-verified 2026-08-08** against every `phoenix_kit_*` checkout under `/www` that has its own
`mix.exs` (excluding `/www/phoenix_kit_{ciuser,flushfix,i18n,imp,integration,qfix,sec,smtp,
userfix}`, which `git worktree list` confirms are worktrees of core itself, `app: :phoenix_kit`,
not separate consumer packages). The individual pins named above have all moved forward with the
modules' own releases and are stale as *numbers*, but the **conclusion is unchanged and still
blocking**: every checked-out module still pins a bare `~> 1.7.x` with nothing that would resolve
against `2.0`, e.g. `catalogue`/`locations` `~> 1.7.189`, `entities`/`warehouse` `~> 1.7.214`,
`emails` `~> 1.7.217`, `document_creator` `~> 1.7.189`, `ecommerce`/`manufacturing`/`projects`
`~> 1.7.231`. `crm` uses a two-clause requirement, `"~> 1.7 and >= 1.7.219"`, which is a different
*style* but the same outcome — it still excludes `2.0.0`. None of the ~14 coordinated
patch-releases this section calls for have shipped; this remains fully open, and this survey (like
the spec's original one) cannot see the module packages that are not checked out locally
(billing, staff, ai, publishing, sync, dashboards, comments) — the "~14" figure itself is carried
forward from the original spec, not re-derived here.

---

## 8. Verification plan

### 8.1 Environment — operator request (ranked)

(a) **CREATEDB** on 172.18.0.13 (best; unlocks everything incl. `mix test.setup`);
(b) three pre-created owned DBs `pk_squash_a`/`pk_squash_b`/`phoenix_kit_test` (reset via
`DROP SCHEMA public CASCADE`; trusted extensions come with DB ownership on PG13+);
(c) operator-side disposable PG container — required anyway for TWO cells: the hardened
low-privilege recipe AND a **second PG major** (§6.2 deparse/structural risk).
Minimum viable: (b) with just `phoenix_kit_test`.
S12's pooled-endpoint cell: `--dry-run` detection-path only against the pooled live endpoint
(zero writes), or operator adds one scratch DB to the pgbouncer config for the full degraded-mode
test (§10 Q6).

### 8.2 Scenario matrix

| # | Scenario | Oracle |
|---|---|---|
| S1 | Fresh-install equivalence: NEW vs OLD chain (bridge tag), clean DBs | normalized `pg_dump --schema-only` diff empty **modulo the committed `:legacy_optional` whitelist; any UNLISTED diff fails**; normalization rules written down (dollar-quote-aware splitting, stable ordering, no index-shift diffing) |
| S2 | Seed-data equivalence: dump seeded tables incl. **email templates** (tolerance: rows match when the seeder ran; absence allowed only in release-mode) | diff empty; note: repair-mode seed semantics intentionally differ from historical upserts (V35/V45 `DO UPDATE` → `DO NOTHING`) |
| S3 | Existing-install upgrade from exactly `floor` and `floor+k` | deltas only; comment = current; row-count+checksum probes unchanged |
| S4 | Below-floor guard: `up`/`down`/update-generation at `floor-1` | **specific `BelowFloorError`** (struct+message asserted; ensure_current variant carries the test-reset hint) |
| S5 | Consumer wrapper replay: (i) Andi's real 41-file set; (ii) synthetic pinned chain `[27,50,120,current]`; (iii) **interleaved consumer migration touching a below-floor-shaped object** → documented, actionable failure; (iv) rollback→migrate round-trip incl. one interleaved consumer down → final state ≡ fresh setup; repair afterwards creates NO spurious columns; doctor flags the desync | as stated |
| S6 | Baseline down to 0 (range + direct `V{floor}.down` split) + re-up; Oban teardown via `Oban.Migration.down`; shared extensions/functions survive | clean teardown, identical re-create |
| S7 | Repair tamper matrix: drop each object class one at a time → repair | restored; dump diff empty; EXTRA objects untouched |
| S8 | Repair idempotence: healthy DB, twice | empty plan ×2; byte-identical dumps |
| S9 | Divergence reporting: wrong type / extra NOT NULL / same-named-different index (on the SAME and on a SECOND PG major) | `:report_only`, schema untouched, exit 2, no deparse false-positives |
| S10 | Data preservation: seeded + user rows + operator-tuned settings survive repair | checksums unchanged |
| S11 | Prefixed install: S1+S7 into named schema alongside public install; `prefix_migration_test.exs` passes unchanged | no cross-schema leaks |
| S12 | Pooled-connection: dry-run detection against pooled endpoint; degraded mode if Q6 env granted | warns; requires `--unsafe-pooled`; VALIDATE skipped |
| S13 | `--adopt`: (a) comment stripped from healthy floor-state DB → converges, stamps `'{floor}'`, subsequent update runs deltas; (b) half-installed → no stamp, report; (c) object-clean but **data-invariant-failing** (composite integration keys present) → no stamp | stamp value asserted; invariants gate |
| S14 | DB-free gates: compile/format/credo; release_check extended (min/contiguity/loadable-range/manifest-hash); the same hash as a plain unit test; baseline-slice static checks | all green |
| S15 | Stamp semantics: single-step `up(version: floor)` fresh → `'{floor}'`; multi-step fresh → `'{current}'` | exact comments |
| S16 | Oban: baseline delegation output == host `Oban.Migration` for the pinned harness version; repair/verify SKIP oban objects (delegated) | no oban entries in Report |
| S17 | Repair since/revision scoping: missing `since<=comment` object healed at the comment-era revision; `since>comment` reported pending; healthy old-shape multi-revision object (module_key@50 at comment 135) verifies CLEAN; after heal, `phoenix_kit.update` converges the shape | as stated |
| S18 | Concurrency: chain `up()` advances the comment mid-repair | repair aborts with "concurrent migration detected"; re-run converges |
| S19 | Data-dependent non-additive drift: missing V137-class unique index + duplicate rows present | `:create_failed` with orphan/dup diagnostic; no crash, no invalid index |
| S20 | Comment > `@current_version` | repair hard-errors; doctor warns; `up()` no-op documented |

Manual (operator-side): the 2026-07-12 hardened-install recipe (pre-created schema, no-CREATE
role, PG15+ non-writable public) against baseline + repair.

### 8.3 Tooling (rewrite of `dev_docs/squash/`)

- `generate_baseline.exs` → **manifest generator**: scratch DB → chain **version-by-version in
  separate migrator runs** (per-version catalog diffs → `since` + `revisions`; separate runs also
  reproduce the *upgraded* end-state, making the §3.7 bimodality enumerable: a fresh single-run
  dump vs the incremental dump yields the `:legacy_optional` whitelist mechanically) → emit
  ExpectedSchema (deterministic order; `chain_hash`) + data invariants → hand review. Old draft
  is unusable (does not compile; broken dollar-quote splitter; preamble regresses the 2026-07
  fixes). The generator refuses to emit `:required` entries for objects the inventory marks
  excluded.
- `migration_runner.ex` → keep pattern; fix the CRITICAL missing-`:prefix` bug (pollutes live
  `public.schema_migrations`); derive floor/current from `Postgres.initial_version/0` /
  `current_version/0`.
- `dump_helper.ex` → dollar-quote-aware splitting, word-boundary schema substitution,
  `diff -u` via System.cmd, **seed-table data dumping + uuid/timestamp normalization (S2)**.
- `verify.exs` → implement S1–S13, S15–S20; Mode A fix; cleanup on exceptions; below-floor
  assertions match the specific error struct (an any-raise-passes check is how a missing guard
  slips through).
- `README.md` → rewrite: floor-parameterized, no-CREATEDB reality, 172.18.0.13, option-(b) reset
  recipe. Reference dump snapshot lives under `dev_docs/squash/` (hex whitelist excludes it).
- pgpass host field `172.18.0.6` → `172.18.0.13`.
- Merge policy: the manifest is never hand-merged; after any rebase touching `v*.ex`, regenerate.
  The hash assertion is a release-time gate — a migration PR may land with a stale manifest as
  long as regeneration happens before publish; renumber events ⇒ regenerate (runbook).

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| an unlisted install turns out to sit below the floor | committed set is operator-confirmed (one install); guard + permanent bridge make any straggler loud and recoverable, never silent |
| Baseline diverges from real chain output | generated from migrated DB; S1/S2 oracles; regenerable |
| Fresh-vs-upgraded bimodal end-states | `presence: :legacy_optional` + S1 whitelist; repair never creates them |
| IF-NOT-EXISTS name-match blindness | structural verify layer; report-only (S9) |
| PG-major deparse differences → false divergences | structural comparison + target-server pg_get_expr + version preflight + second-major matrix cell |
| Manifest staleness (migration added, not regenerated) | chain_hash in release_check AND plain unit test; runbook; §10 Q5 upstream commitment |
| Manifest merge conflicts between parallel PRs | deterministic emit order; never-hand-merge policy; release-time gate |
| Comment lies (high, low, > current) | §6.4 R2/R5/R6 + marker probes + `--heal-comment` |
| PgBouncer drops DDL / pooled repair | autocommit statements; pooled detection + `--unsafe-pooled`; comment-strip case lands in R4 --adopt |
| Stale consumer wrappers / interleaved consumer migrations | clamp + qualified guarantee + consolidate_wrappers + S5(i-iv); down-desync invariant + doctor warning |
| Repair races a live migration | shared advisory lock blocks a migration STARTING during a repair; the reverse is detected by the comment re-read + S18, not prevented (§6.1) |
| Repair create fails on data-dependent drift | per-statement `:create_failed` + diagnostics (S19) |
| Oban version skew | delegated-not-manifested; S16 |
| Module pins block 2.0 adoption / auto-pull transitive consumers | §7.4 coordinated pin-widening before publish; direct-pin advice |
| Dep bump bundled with unapplied wrapper fails at deploy-time migrate | upgrade guide: confirm ≥ floor on every env; BelowFloorError message echoes it |
| ensure_current on persistent CI DBs | test-reset hint in the error (S4) |
| hexdocs bloat from generated module | `@moduledoc false`; snapshot under dev_docs |
| Re-squash correctness untested | acknowledged; first re-squash re-runs full matrix; each raise = major + bridge |
| Manifest executor is novel machinery | de-scoping lever: imperative baseline + verify-probes-only (drops auto-repair to report-only); contracts survive |

## 10. Open questions for the operator (block implementation, not review)

1. ~~Install survey~~ RESOLVED 2026-08-04: committed set = the local host app only (live at
   V160); floor decision reduced to picking the number (operator question below).
2. **Scratch-DB option** (§8.1 a/b/c; recommend (a), or (b)×3). Plus (c) for the second-PG-major
   and hardened-install cells.
3. Confirm 2.0.0 + bridge policy (permanent bridge, ~90-day security window) + "every floor raise
   = major + own bridge" (§7.3).
4. Repair v1 scope: FK VALIDATE default-on? `--adopt` in v1? `--heal-comment` in v1?
5. **Upstream maintainer commitment**: adopt the regenerate-manifest-per-migration-release
   workflow (needs a scratch DB in their release env) + the same-day squash-PR merge protocol +
   ~14 module pin-widening releases (§7.4).
6. Add one scratch DB behind pgbouncer for S12's degraded-mode cell (optional; else S12 =
   dry-run-only detection).

## 11. Implementation phases (after spec sign-off — NOT this task)

1. **P0**: floor confirmation (fresh, complete); scratch DB(s); pgpass fix.
2. **P1**: tooling (§8.3): generator + runner + dump + verify; prove S1/S2 self-oracles on the
   OLD chain (incl. bimodality enumeration → whitelist).
3. **P2 (pre-squash PR)**: ExpectedSchema + repair engine + mix task + gen.migration/
   release_check/unit-hash fixes + consolidate_wrappers; S7-S20 subset that runs pre-squash.
4. **P3 (squash PR)**: baseline V{floor} from the manifest slice; deletions; guards/clamp;
   test-surface disposition (§5.3); moduledoc/docs incl. AGENTS.md.
5. **P4**: full S1–S20 matrix + manual hardened-install recipe; fix; re-run to green.
6. **P5**: module pin-widening wave (§7.4); CHANGELOG/version; atomic squash PR merge protocol;
   bridge tag; upgrade guide + re-squash/regeneration runbook.

Estimated diff: −{19,725…23,231} migration lines; +thin baseline + ExpectedSchema (~2-4k) +
repair engine (~1-1.5k) + tooling/tests. Net repo shrink ≈ 15-20k lines.
