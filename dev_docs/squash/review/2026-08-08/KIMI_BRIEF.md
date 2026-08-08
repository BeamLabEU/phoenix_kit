# Adversarial review brief — PhoenixKit migration squash, final round (2026-08-08)

You are the last reviewer before this branch becomes a pull request against
`BeamLabEU/phoenix_kit`. Two earlier reviewers (GLM-5.2 and an Opus agent with
live database access) already went through it; their findings are fixed. What I
need from you is the thing reviewers usually miss: **inputs and states nobody
modelled.** Do not re-derive the design — attack it.

Read `dev_docs/squash/review/2026-08-08/repair_and_registry.diff` (the shipping
code under review) and any file in the repo you need for context. Key files:
`lib/phoenix_kit/migrations/postgres/v164.ex` (the repair migration),
`lib/phoenix_kit/migrations/uuid_fk_columns.ex` (its data), and
`lib/phoenix_kit/migrations/postgres.ex` (the chain registry).

## What this branch does

It replaces migrations `V01`..`V134` with one generated **baseline** `V135` that
reproduces their cumulative schema, keeps `V136`..`V164` as ordinary deltas, and
refuses to migrate a database below `V135` (you must first upgrade on the last
`1.7.x` release, the "bridge"). The version a database is at is a PostgreSQL
COMMENT on `{prefix}.phoenix_kit`.

`V164` repairs a historical defect. `V56`/`V57` built the UUID foreign-key layer
and guarded their own work with `repo().query` existence checks that ran while
the DDL they depended on was still QUEUED in Ecto's migration runner (`execute/1`
only queues; nothing had flushed). Every guard failed closed, so on any install
created by `mix phoenix_kit.install` — one wrapper spanning the whole chain —
~46 `*_uuid` columns stayed nullable and ~67 of 70 declared foreign keys were
never created. `V164` re-imposes the NOT NULLs where no NULL rows exist, creates
the missing FKs `NOT VALID` then `VALIDATE`s them, corrects one FK from
`ON DELETE CASCADE` to `SET NULL`, and normalizes two indexes whose shape
diverged between `public` and named-schema installs because two old migrations
issued an unqualified `DROP INDEX`.

## Specific things to try to break

1. **`V164` against states nobody modelled.** It runs on other people's
   production databases. What input makes it corrupt data, abort a deploy
   mid-way, or silently do the wrong thing? Consider: a table that exists with
   the right name but a different owner or column type; an FK whose referenced
   column has no unique index; a partial or `DEFERRABLE` constraint already
   present under the expected name; a column that is `GENERATED`; a table
   inherited or partitioned; identifiers at PostgreSQL's 63-byte limit; a schema
   named with characters that survive its `escaped_prefix` handling. The SQL is
   built by string interpolation — go after that specifically.
2. **The idempotence claim.** `V164` must be a no-op on a second run and must be
   safe to re-run after failing halfway (statements auto-commit individually —
   the generated wrapper sets `@disable_ddl_transaction true`). Find a
   half-applied state from which re-running does the wrong thing.
3. **The version-comment contract.** The comment is the only record of where a
   database is. What sequence of runs, rollbacks, or a comment edited by hand
   leaves the schema and the comment disagreeing in a way the chain will then act
   on wrongly? Note `down/1` on `V164` restamps to `163` and undoes nothing.
4. **Data assumptions in `uuid_fk_columns.ex`.** 70 FK tuples and 47 NOT NULL
   pairs, hand-maintained. Is any tuple wrong — a column that is legitimately
   nullable, an `ON DELETE` that contradicts how the application uses the table,
   a referenced table that no longer exists? Two exclusions are declared
   (`@relaxed_after_v57`); is the list complete?
5. **Anything a Russian- or non-ASCII-data install would hit** that an
   English-only test suite would never produce.

## Ground rules

- Read-only. Do not edit files, do not run migrations, do not touch any database.
- Be concrete: name the file and line, the exact input or state, and the
  observable wrong outcome. A finding I cannot reproduce from your description
  is worth little.
- If you think a specific claim above is false, say so plainly and say why.
- Skip praise and skip summarising the design back to me. Findings only, ordered
  by how much damage they do, with a severity tag (`CRITICAL` / `HIGH` /
  `MEDIUM` / `LOW`) and an explicit final verdict: is this safe to publish?
