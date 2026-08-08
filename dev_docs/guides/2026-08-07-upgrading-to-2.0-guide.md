# Upgrading to PhoenixKit 2.0 — the squashed migration chain

2.0 consolidates the versioned migration chain. `V01`..`V134` no longer exist as
individual modules; `V135` is a generated **baseline** that produces their
cumulative schema in one step, and `V136`..`V164` remain as ordinary deltas.
Nothing about your data changes because of the consolidation itself — but this
release also carries a **repair** for a long-standing defect, and that part does
change behavior. Read the whole page before upgrading a production database.

## In one paragraph

If your database is already at `V135` or above, the baseline never runs: the
version comment gates it exactly as it gates any other version, so upgrading is
an ordinary delta run. If your database is **below** `V135`, 2.0 refuses to
migrate it and tells you so — you must first upgrade on the last `1.7.x`
release (the **bridge**, `{:phoenix_kit, "~> 1.7.235"}`), which still carries
the full chain, and only then move the pin to `~> 2.0`. Separately, this
release repairs schema damage that a migration-ordering defect left on
essentially every install created by
`mix phoenix_kit.install`. The fix is `V164` — an ordinary delta in the chain,
not a separate command — so it runs automatically the moment your update
reaches it (step 3 below); it adds constraints, and on a large database that
costs locks and a validation scan, so plan your maintenance window around
step 3, not step 4. `V163`, immediately before it in the same chain, is a
separate repair (upstream's, not this one's) that promotes some tables'
`uuid` columns to primary keys — `V164` depends on it having run, because a
foreign key cannot reference a column with no primary key. Both apply in the
same `mix phoenix_kit.update` run; you do not invoke them separately.

## Step by step

1. **Land on the bridge first.** Pin `{:phoenix_kit, "~> 1.7.235"}` — the last
   `1.7.x` release, and the one this guide calls the bridge — run
   `mix phoenix_kit.update`, and confirm the version comment reaches `V135` or
   higher before you touch the `~> 2.0` pin:

   ```sql
   SELECT obj_description('public.phoenix_kit'::regclass, 'pg_class');
   ```

   Use your schema name instead of `public` for a prefixed install.

2. **Confirm it on EVERY environment, not just one.** Development, staging and
   production each have their own database. A dependency bump travels with your
   code; the migration does not. Bumping the pin while production is still below
   the floor turns the deploy's migrate step into a `BelowFloorError` — loud and
   safe, but a failed deploy.

3. **Move the pin** to `{:phoenix_kit, "~> 2.0"}` and run
   `mix phoenix_kit.update` as usual. **This is where the defect below actually
   gets repaired** — `V164` runs as an ordinary delta in this same chain run
   and adds the missing constraints. On a large database that costs locks and
   a validation scan (see "What V164 repairs" below); this is the step to run
   in a maintenance window, not step 4.

4. **Optional completeness check.** `V163` and `V164` apply together in step 3
   inside one `mix phoenix_kit.update` run, so an ordinary upgrade does not stop
   partway between them — you will not observe an install permanently stuck at
   comment `163` from following this guide. (A comment reading `163` mid-deploy
   just means step 3 is still running: `V163` — upstream's own catalog-driven
   `uuid`-column repair, unrelated in mechanism to the fix this guide is about —
   has applied and `V164` has not reached its version-comment stamp yet. Continue
   or re-run `mix phoenix_kit.update`; there is nothing else to do for that case.)
   This step is for anyone who wants independent confirmation the repair took,
   or who suspects step 3 stopped for an unrelated reason (see "A failed step 3
   is safe to re-run" below): check with the count query further down — a
   healthy install answers ~86, and 19 means the defect is still there.
   `mix phoenix_kit.repair` compares your whole schema against the full manifest
   and creates anything missing additively, using the same `NOT VALID` +
   `VALIDATE` sequence `V164` itself uses, so everything this page says about
   locks and maintenance windows applies to it too. It is not required if step 3
   already completed — this is a completeness check, not a second application of
   the fix:

   ```bash
   mix phoenix_kit.repair --dry-run      # reports only, changes nothing
   mix phoenix_kit.repair                # applies additive fixes
   ```

   `--dry-run` is opt-in: the bare command **writes**.

   Two things to know before running the write form. Like every other
   `phoenix_kit.*` task it boots your application (`mix app.start`), so run it
   from an environment that does not also start your web server — with
   `PHX_SERVER` set, the endpoint tries to bind a port already in use. And a
   write run re-runs **Oban's own migrator** for the PhoenixKit prefix, the
   same `Oban.Migration.up(prefix: …, create_schema: false)` call the baseline
   makes; `--dry-run` skips it, because previewing another library's migrator
   is not something this tool can do safely.

## What V164 repairs, and why it exists

The fix ships as `V164` (`lib/phoenix_kit/migrations/postgres/v164.ex`) — an
ordinary delta, applied automatically wherever `mix phoenix_kit.update` reaches
it (step 3 above). It is not `mix phoenix_kit.repair`, and it is not a
separate step you have to remember to run.

`V56` and `V57` built the UUID foreign-key layer, and their existence checks
queried the database immediately while the DDL they depended on was still
queued. Any chain run that crossed those two versions inside one migrator
invocation — which is every install created by the installer, since it emits a
single unpinned wrapper for the whole chain — therefore silently skipped work:

- **~46 `*_uuid` columns** were left nullable instead of `NOT NULL`.
- **~67 of the 70 declared foreign keys** were never created at all.
- `phoenix_kit_comments.fk_comments_user_uuid` was missing, so `V72` added it
  later with a guessed `ON DELETE CASCADE`.

Incrementally-upgraded installs that crossed `V56`/`V57` in separate narrow
wrappers are unaffected. To see where you stand:

```sql
-- expect ~86 on a healthy install (measured against a fresh V135..V164 build):
-- 70 are the UUID FK layer this repair targets, the rest are unrelated
-- fk_-prefixed constraints already present elsewhere in the schema. A much
-- lower number means the defect hit you.
SELECT count(*) FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public' AND c.contype = 'f' AND c.conname LIKE 'fk\_%';
```

Consequences you must plan for:

- **Comment deletion semantics change.** The comments foreign key is corrected
  from `ON DELETE CASCADE` to `ON DELETE SET NULL`, matching what `V56`/`V57`
  always declared and the convention of every sibling table (a like or a
  dislike is meaningless without its user and still cascades; a comment's
  content outlives its author and is blanked instead). If your application
  relied on deleting a user to delete their comments, that no longer happens —
  the rows survive with `user_uuid = NULL`. The comments module already types
  the field as nullable, so nothing raises.
- **Constraint creation costs locks — including the `NOT VALID` step itself.**
  `ALTER TABLE ... ADD CONSTRAINT ... NOT VALID` is not metadata-only: it takes
  `ShareRowExclusiveLock` on **both** the child table and the table it
  references, for as long as the `ADD` runs. That mode conflicts with the
  `RowExclusiveLock` every ordinary `INSERT`/`UPDATE`/`DELETE` takes, so every
  write to either table blocks while the lock is held — and if the lock
  acquisition itself queues behind a long-running transaction, every reader
  and writer that arrives after it queues too. Over 60 of the 70 declared
  foreign keys reference `phoenix_kit_users`, so a single run takes this lock
  on the users table roughly 60 times. Nothing in the chain sets a
  `lock_timeout`, so set one yourself for the session running the migration —
  `SET lock_timeout = '3s'` — so a stuck acquisition aborts loudly instead of
  freezing the users table for the rest of the run; if it aborts this way,
  just re-run `mix phoenix_kit.update` (see "A failed step 3 is safe to
  re-run" below). Only the *validation* that follows each `ADD` is the
  non-blocking part: it takes `SHARE UPDATE EXCLUSIVE`, which does not block
  reads or writes but does scan the table, and across dozens of tables on a
  large database that scan is not instant either. Run the whole step in a
  maintenance window, and never through PgBouncer in transaction-pooling mode
  (use a direct connection).
- **Only the foreign-key half tolerates concurrent traffic.** Those constraints
  degrade to `NOT VALID` instead of failing. The `NOT NULL` half does not: it
  reads the column's `NULL` count and then issues `SET NOT NULL`, and a row
  inserted with a `NULL` between the two makes that statement fail and the
  migration stop. Statements auto-commit individually (the wrapper disables the
  DDL transaction), so a stopped run leaves the work up to that point applied
  and is safe to re-run — but this is the concrete reason to run step 3 with the
  application not serving writes rather than alongside live traffic.
- **A failed step 3 is safe to re-run.** The generated update wrapper sets
  `@disable_ddl_transaction true`, so a mid-`V164` failure does not roll back:
  every constraint and column change issued before the failure is already
  committed, but no `schema_migrations` row was inserted for `164` and the
  version comment still reads `163`. Just run `mix phoenix_kit.update` again —
  `V164` checks for each constraint and each `NOT NULL` before acting, so it
  picks up where it left off instead of redoing or duplicating work. This
  isn't a guarantee against every failure: if the cause is persistent (a
  permissions problem, for example), the re-run fails the same way and that
  needs fixing first.
- **Nothing is forced onto live data.** `NOT NULL` is applied only where the
  column currently has zero `NULL` rows; otherwise the repair warns with the
  table, column and row count and leaves the column alone. Validation failures
  leave the constraint `NOT VALID` (new writes are still checked) and report the
  orphan count. The repair never deletes, never rewrites, and never backfills a
  live column.
- **Predict this before the window, not after.** Some constraints staying
  `NOT VALID` is the normal case, not an edge case — measured against a real
  pre-production database, 3 of the 70 constraints failed validation:
  `phoenix_kit_users_tokens.user_uuid` (498 rows, 23 orphans),
  `phoenix_kit_user_role_assignments.user_uuid` (92 rows, 33 orphans), and
  `phoenix_kit_files.user_uuid` (126 rows, 1 orphan). You can find these ahead
  of time with an orphan count per `(child.column -> parent.column)` pair, for
  example the first of the three above:

  ```sql
  SELECT count(*) FROM phoenix_kit_users_tokens t
  LEFT JOIN phoenix_kit_users u ON u.uuid = t.user_uuid
  WHERE t.user_uuid IS NOT NULL AND u.uuid IS NULL;
  ```

  Swap in the child table, FK column and referenced column for any other pair
  — the full list V164 validates is in
  `lib/phoenix_kit/migrations/uuid_fk_columns.ex`. Run this for every pair
  before your maintenance window so a nonzero count is an expected, planned
  outcome rather than a surprise in the migration log; the query below tells
  you afterward which of your predictions actually came true.
- **An FK you already have under a different name is adopted, not duplicated.**
  `V164` matches on shape — column, referenced table, referenced column — not on
  constraint name, so an equivalent foreign key you or Ecto created as
  `<table>_<column>_fkey` is recognised and left alone. If its `ON DELETE`
  action differs from the one this chain declares, that is reported and still
  left alone: adding a second constraint would not change the behaviour anyway
  (PostgreSQL fires every matching action and the strictest one wins), and
  dropping the one your application already relies on is not a decision a
  migration should make for you. Reconcile it by hand if the declared action is
  the one you want.
- ⚠️ **A degraded outcome still exits successfully.** If a constraint could not
  be validated, could not be created, or a column had `NULL` rows, `V164` warns,
  moves on, and the chain still stamps `164` — the deploy goes green with
  follow-up work outstanding. The run ends with a single
  `PhoenixKit V164 SUMMARY:` line naming
  every constraint left `NOT VALID`; **check step 3's output for it.** Each
  named constraint enforces new writes but not the rows already there, and
  re-running the migration will not retry them — clean up the reported rows and
  `ALTER TABLE … VALIDATE CONSTRAINT …` by hand. To find them later:

  ```sql
  SELECT conrelid::regclass AS table, conname
  FROM pg_constraint
  WHERE contype = 'f' AND NOT convalidated
    AND connamespace = 'public'::regnamespace;
  ```

## Named-schema (prefixed) installs

Two migrations name objects by embedding the schema prefix into the object name,
and the longest such name is 42 characters. With PostgreSQL's 63-byte identifier
limit that leaves **20 characters** for the prefix. A longer prefix is silently
truncated by PostgreSQL, after which the expected and actual index names differ
forever and the repair reports objects that are really there. 2.0 rejects a
prefix longer than 20 bytes at the entry points rather than letting you discover
this later.

## Rolling back

- `mix ecto.rollback` on a wrapper that targets a version **below** the floor
  clamps to the floor and says so; the version comment stays at the floor. Below
  the floor there is nothing to roll back to in this release — that is what the
  bridge is for.
- A full teardown (`PhoenixKit.Migrations.down(version: 0)`) still removes
  everything, baseline included. Shared extensions (`citext`, `pgcrypto`,
  `pg_trgm`) are deliberately left in place.
- The repair itself is not undone by a rollback: it restamps the version comment
  and leaves the constraints it created. Removing them is a manual decision.

## Known cosmetic divergence

A database built by the old chain in one shot retains `phoenix_kit_users.preferred_locale`
and its index — `V28` added the column and `V30`'s removal check ran before the
addition was flushed, so single-run installs kept it. The baseline does not
create it, and the repair treats it as optional in either direction. It is
unused by application code; leaving it is harmless.

## If something looks wrong

`mix phoenix_kit.doctor` reports version state, pool and PgBouncer topology, and
runs the repair's verify pass read-only. `mix phoenix_kit.repair --dry-run --json`
gives the machine-readable finding list. A finding tagged as a rendering-only
difference on an unverified PostgreSQL major is informational: two majors can
render the same expression differently, which is not drift.
