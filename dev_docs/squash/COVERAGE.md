# What is verified, per version range

The squashed chain ships **30 files**: `V135` — a generated baseline that
reproduces the cumulative schema of `V01`..`V134` in one step — plus **29
ordinary deltas**, `V136`..`V164`. This page answers one question: for each part
of that chain, which scenario proves it, and what is deliberately left unproven.

Run everything with `verify.exs` (see README for invocation). Every claim below
was observed, not reasoned about; the SKIPs are named with their reason.

## The two properties that matter

**Equivalence.** A fresh install of `V135 + V136..V164` must produce exactly what
the pre-squash chain `V01..V164` produced. That is `s1` (schema) and `s2` (seed
data), compared against tool-written references built on the pre-squash
("bridge") checkout. `s1_self`/`s2_self` are the oracles for the comparison
itself: two independent installs of the *same* chain must compare equal, so a
normalizer bug cannot hide a real diff.

**Composition.** The chain must reach the same state regardless of *how* it is
applied — all at once, or a version at a time, or resuming from an existing
install. This is the property the historical `V56`/`V57` defect violated: those
versions checked the database with `repo().query` while the DDL they depended on
was still queued, so they behaved differently when several versions ran inside
one migrator invocation than when each ran in its own. `s3` and `s22` cover this.

## Coverage by range

| Range | What covers it |
|---|---|
| `V01`..`V134` (folded into the baseline) | `s1` + `s2` — the whole point of the references: they were produced by running the real, unfolded chain. `s6` tears the baseline back down to 0 and re-creates it identically. `s11` installs it into a named schema alongside a `public` install with no cross-leak. `s15` pins the version-comment stamp. |
| `V136`..`V164` (live deltas) | `s1`/`s2` run the full chain, so every delta executes. `s3` upgrades from the floor and from floor+3 — deltas only — and lands byte-identical to a single-run install. `s22` applies **each delta in its own migrator invocation** and requires the result to equal the one-shot run, which is the per-version statement `s1`/`s3` do not make on their own. |
| `V164` (the repair delta) | `s21` — damages a healthy install the way the flush defect did (drops every declared FK, drops every `NOT NULL`, flips the comments FK back to `CASCADE`), runs the chain, and asserts full restoration; then re-runs it and requires a byte-identical no-op; then, on a separate schema, leaves an orphan row in place and requires the constraint to be added `NOT VALID` with the row untouched. |
| Below the floor | `s4` — `up`, `down` **and** `ensure_current/2` on a persistent below-floor install must each raise the specific `BelowFloorError` with its bridge message; `ensure_current` additionally carries the `mix test.reset` hint. `s13` covers `--adopt`. |
| Consumer wrappers | `s5` — replays the host application's real 54-file wrapper set (1 installer + 48 pinned wrappers + 5 interleaved consumer migrations), including the rollback round-trip and the named breakage class an unguarded consumer rename produces. |
| The repair engine | `s7` tamper matrix, `s8` idempotence, `s9` report-only divergence, `s10` data preservation, `s12` pooled-connection detection, `s17` revision scoping, `s19` data-dependent create failure, `s20` comment ahead of `@current_version`. |
| Both installation paths | `--mode b` (named scratch schemas) is the default and covers everything. `--mode a` re-runs `s1`/`s2` against `public`, the path almost every consumer actually uses. See below. |

## Mode A, and what `DROP SCHEMA public CASCADE` is

Mode A installs into `public` instead of a named scratch schema. Because two
installs cannot coexist in one `public`, the comparison is sequential: install,
dump, **reset**, install, dump, compare. The reset is

```sql
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
```

which deletes every object in that one schema — **not the database**. Two
consequences worth knowing before running it:

- `CASCADE` also drops the shared extensions (`citext`, `pgcrypto`, `pg_trgm`),
  which live in `public`. The chain reinstalls them via
  `Helpers.ensure_extension!/1`, but anything in *another* schema whose columns
  depend on them goes too — including `s4`'s persistent below-floor handoff
  schema. Reseed it afterwards from the bridge checkout
  (`--mode b --scenario s4_seed`), or `s4` degrades to
  `SKIP:handoff-schema-absent`.
- It is double-gated: `PK_SQUASH_ALLOW_RESET` must equal `PGDATABASE`, so the
  command cannot fire against a database you did not name explicitly.

Mode A needs its own references, because a `public` reference and a
named-schema reference legitimately differ on shared-object paths (e.g.
`public.gen_random_bytes` inside `uuid_generate_v7`'s body). Keep them apart with
`PK_SQUASH_REF_DIR` — this repo keeps the mode-B set in `reference/` and the
mode-A set in `reference_mode_a/` — and build each on the bridge checkout in the
same mode you will compare in. The harness refuses a cross-mode comparison
instead of reporting a bogus diff.

## Deliberately not proven

- **A second PostgreSQL major.** `s9`'s cross-major cell needs an operator-run
  container with a different major. Until then a finding that rests only on
  expression *rendering* is reported as informational rather than drift — the
  differ marks those reasons explicitly.
- **`s16`** (Oban delegated, never manifested) — the assertion body is still
  pending; it reports `SKIP:pending-p2-body` rather than passing vacuously.
- **`s18`** (a migration starting mid-repair) — needs two processes interleaved
  by hand; it reports `SKIP:needs-manual-trigger`. Note the advisory lock only
  prevents the opposite order (a chain run cannot *start* during a repair); this
  direction is detected by the version-comment re-read, not prevented. Spec §6.1.
- **`s4_seed`** cannot run on this checkout at all: seeding a below-floor install
  requires the pre-squash chain, so it reports
  `SKIP:needs-pre-squash-checkout` here and is run on the bridge worktree.
- **Index `NULLS NOT DISTINCT`** has no structured field in the manifest. No
  version in the chain declares it, and until one does it is covered only by the
  index definition text; see `Repair.Differ`'s moduledoc.
