# Review brief — squash-migrations, round of 2026-08-07

You are reviewing **uncommitted changes on top of commit `79e60cf0`** on branch
`squash-migrations` of PhoenixKit (Elixir/Phoenix library, PostgreSQL-only
Oban-style versioned migration chain). Read these two frozen snapshots — the
working tree may move under you while you review:

- `dev_docs/squash/review/2026-08-07/lib_changes.diff` — shipping code
- `dev_docs/squash/review/2026-08-07/tooling_and_docs.diff` — verification
  harness, generator, docs

You may also read any file in the repo for context.

## What this branch does, in one paragraph

It consolidates ~163 accumulated migration versions into a generated
**baseline** at floor `V135` (`lib/phoenix_kit/migrations/postgres/v135.ex`,
~11k lines, 1199 statements) plus the surviving deltas `V136..V163`. A database
at or above the floor skips the baseline via the version comment on
`{prefix}.phoenix_kit`; a database below the floor is refused with
`BelowFloorError` and must first upgrade on the last `1.7.x` release (the
bridge). Separately the branch fixes a real historical defect: `V56`/`V57`
issued existence checks with `repo().query` while the DDL they depended on was
still queued in Ecto's migration runner, so on every install created by
`mix phoenix_kit.install` (one unpinned wrapper spanning the whole chain) ~46
`*_uuid` columns stayed nullable and ~67 of 70 declared foreign keys were never
created. `V163` repairs that.

## What changed in THIS round (what to focus on)

1. **`Postgres.up/1` and `.down/1` now take an advisory lock**
   (`acquire_chain_lock!/0`) on the same key `Repair.Environment` uses, closing
   a spec-vs-code divergence two earlier reviewers flagged (spec §6.1 promised
   mutual exclusion; only repair actually locked). It is a
   `pg_advisory_xact_lock`, deliberately NOT the session-level lock repair
   uses — reasoning is in the comment. **Question for you: is that reasoning
   correct, and is there a self-deadlock or lock-starvation path I missed?**
   Note repair only calls read-only `Postgres` functions, so repair→migrator
   nesting on a different pooled connection should not arise; verify that
   claim.
2. **`V163` extended from the NOT NULL half to the full FK repair** (see
   `lib/phoenix_kit/migrations/postgres/v163.ex`): every constraint in
   `UUIDFKColumns.fk_constraints/0` created `NOT VALID` then `VALIDATE`d, with
   a PL/pgSQL exception handler so a validation failure leaves the constraint
   `NOT VALID` and warns with an orphan count instead of aborting. Two columns
   are exempt from NOT NULL (`@relaxed_after_v57`) because their FK is
   `ON DELETE SET NULL` — re-imposing NOT NULL there would contradict the FK.
   **Review the SQL, the flush placement, and prefix-safety** (rules in
   `CLAUDE.md` → "Prefix-safe migrations"; never `::regclass` in an immediate
   check, schema-anchored existence checks, bare index names on CREATE).
3. **`chain_hash` restamping** (`dev_docs/squash/restamp_chain_hash.exs`). The
   manifest's staleness detector hashes the shipped `v*.ex` set. The generator
   cannot compute it, because the baseline must be generated from a
   *pre-squash* checkout and only joins the shipped set at promotion time. This
   round I mistakenly regenerated the manifest *from the squashed branch* — a
   self-referential run that silently dropped 25 `phoenix_kit_role_permissions`
   seed rows from the baseline and failed four scenarios. Reverted; the trap is
   now documented in `dev_docs/squash/README.md`. **Is the restamp step
   trustworthy, or does it paper over a real generator bug?**
4. **`ensure_current/2` below-floor coverage** added as a third entry point in
   scenario S4, proving `Ecto.Migrator` carries `BelowFloorError` out of its
   spawned Task un-wrapped so the `context: :ensure_current` re-tag (and its
   `mix test.reset` hint) actually happens.
5. Documentation-only: an index-`NULLS NOT DISTINCT` limitation note in the
   differ, and two operator caveats in the 2.0 upgrade guide (the task boots
   the host app; a write-mode repair re-runs Oban's own migrator).

## Verification evidence already collected (do not re-run; challenge it)

- Full suite: **1918 tests, 38 doctests, 0 failures** against `phoenix_kit_test`.
- Verification matrix `dev_docs/squash/verify.exs --mode b`: **17 scenarios
  PASS, 0 FAIL**, 3 documented SKIP (`s4_seed` needs a pre-squash checkout,
  `s16` pending body, `s18` manual trigger). S1 proves
  `baseline+deltas ≡ pre-squash chain` modulo a two-object whitelist; S2 proves
  seed data byte-identical.
- `mix phoenix_kit.release_check`: `chain_hash matches 29 on-disk migration
  file(s)` PASS. The three failing checks there are release-time gates (dirty
  tree, branch, tag) and expected pre-merge.
- The live consumer app (`/www/app`, path dep on this branch) compiles, boots
  and serves HTTP 200 with these changes.
- `V163`'s NOT NULL half was applied to a real pre-production database: 45
  columns set NOT NULL, zero skips, comments FK flipped to `SET NULL`, both
  exclusions held, 66 comments intact. **The FK half has no automated coverage
  yet** — a scenario is being written; assume it unproven.

## What I want from you

A severity-tagged review (`BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT`,
`NITPICK`) with a verdict. Prioritise: correctness of the advisory lock;
correctness and safety of `V163` on a large live database (locking, validation
cost, orphan handling, idempotence, partial-failure recovery); anything in the
squash design that could make a *consumer's* upgrade fail in a way the guide
does not warn about. Be concrete — cite file and line, and say what input or
state produces the failure. If you believe a claim above is wrong, say so
plainly; I would rather hear it now than after publish.
