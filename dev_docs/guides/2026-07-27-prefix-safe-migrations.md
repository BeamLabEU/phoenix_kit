# Prefix-safe migrations (named-schema installs)

Moved from `AGENTS.md` 2026-07-27 — the operational rules every migration
author needs stayed there; this is the full reference.

The chain supports running into a named Postgres schema (`prefix:` opt /
`--prefix`). Two bug families broke it in 2026-07 (both fixed, PR #628);
any new `execute`-built SQL can regress them:

- **Index names stay bare on CREATE.** Postgres rejects
  `CREATE INDEX schema.name ...` — the index always lands in the
  (schema-qualified) table's schema. Qualifying the *name* is only valid
  on `DROP INDEX`.
- **Every existence check needs a schema anchor.** `information_schema.*`
  checks need `table_schema = '#{escaped_prefix}'`, `pg_indexes` needs
  `schemaname`, and `pg_constraint` `conname` checks need a table anchor.
  An unanchored check sees `public`'s objects, so a prefixed install into
  a database that also carries a public install silently skips creating
  the prefixed object.
  ⚠️ For the `pg_constraint` anchor, prefer a name-based JOIN
  (`JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n …
  WHERE t.relname = '…' AND n.nspname = $1`) over the raw
  `conrelid = '#{p}table'::regclass` idiom in IMMEDIATE checks
  (`repo().query/3`): a regclass cast RAISES when the relation doesn't
  exist yet — on a fresh chain the table's CREATE may still be queued —
  and that aborts the whole migration transaction in a way a `rescue`
  can't undo (every later statement dies with 25P02, surfacing at some
  unrelated version). V146 hit exactly this; it now JOINs by name and
  `flush()`es first. The regclass idiom is only safe after a `flush()`
  guarantees the relation exists.
- **Failures surface late.** Ecto queues `execute` calls; bad SQL queued
  by one version often blows up at a *later* version's `flush()`.

A 2026-07-12 field report from a hardened multi-schema install (schema
pre-created by a DBA, app role without CREATE on the database, PG 15+
non-writable `public`) surfaced four more families — all fixed; the
rules for new migration code:

- **Functions are created schema-qualified.** `uuid_generate_v7()` is
  created as `<prefix>.uuid_generate_v7()` and every call site
  (`DEFAULT`, backfill `UPDATE`s, `fragment/1`) qualifies it too — an
  unqualified `CREATE OR REPLACE FUNCTION` lands wherever `search_path`
  points (pollutes `public`; fails outright on PG15+). Use
  `PhoenixKit.Migrations.Postgres.Helpers.ensure_uuid_v7_function/1` +
  `uuid_v7_call/1`. The `V135` baseline is now the sole creation site
  (folding what were historically four separate re-ensure points — V40,
  V56, V61, V63 — into one call in `V135.up/1`); `Postgres.up/1` still
  re-ensures the function on every delta upgrade too (`@uuid_fn_version
  40`), as pure defense-in-depth.
- **Never bare `CREATE EXTENSION IF NOT EXISTS`** — Postgres checks the
  CREATE privilege *before* the IF-NOT-EXISTS short-circuit, so it fails
  for low-privilege roles even when the extension is installed. Use
  `Helpers.ensure_extension!/1` (checks `pg_extension` first; raises an
  operator-facing message listing citext/pgcrypto/pg_trgm when genuinely
  missing and uncreatable).
- **Same story for `CREATE SCHEMA`.** The `V135` baseline checks
  `information_schema.schemata` first and only creates when missing
  (raising a clear error if missing + `create_schema: false`) —
  folding what was historically V01's idiom. External migrators must
  have the flag threaded too: `V135` passes `create_schema: false` to
  `Oban.Migration.up/1` (folding V27's idiom) — without it Oban
  re-defaults to true for non-public prefixes and executes the failing
  statement mid-chain.
- **The prefix is validated at the `up/down` entry points**
  (`Helpers.validate_prefix!/1`, `[a-z_][a-z0-9_]*`) because it is
  interpolated into SQL mostly unquoted.
- **Tooling resolves the prefix from config.** The installer persists
  `config :phoenix_kit, prefix:` for non-public installs
  (`PhoenixKit.Install.PrefixConfig`); update/status/gen.migration
  resolve `--prefix` → config → `"public"` (`resolve_prefix/1`). And
  `Install.Common` no longer fabricates `{:current_version, 1}` from
  the mere existence of migration *files* — that once made
  `phoenix_kit.update` emit a from-scratch v01→vN migration into the
  wrong schema. Update-migration generators always emit
  `create_schema: false` (updating implies the schema exists).

`test/integration/prefix_migration_test.exs` is the oracle: it runs the
full chain into a scratch schema on the test DB (which also has a public
install, so it catches both families). It flips the sandbox to `:auto`
for the run — see its moduledoc for why neither a sandbox checkout nor a
dynamic repo instance can host the migrator. (The privilege-sensitive
paths — pre-created schema + low-privilege role — can't run under the
suite's superuser connection; re-verify those manually against the
recipe in the 2026-07-12 field report if you touch them.)

## Runtime prefix support (2026-07-12)

Every table-backed core schema `use`s `PhoenixKit.SchemaPrefix`, which
sets `@schema_prefix` from `Application.compile_env(:phoenix_kit, :prefix)`
— so on a prefixed install ALL runtime queries (delegated, direct
`repo()` calls, `update_all`/`insert_all`, Multi steps, preloads, joins)
target the named schema with no `search_path` requirement on the DB role.
Rules:

- **New table-backed schemas must add `use PhoenixKit.SchemaPrefix`**
  right after `use Ecto.Schema` — `test/phoenix_kit/schema_prefix_test.exs`
  enforces it by scanning for `schema "phoenix_kit` files. Embedded
  schemas don't need it.
- The prefix is **compile-time** config (`config.exs`, never
  `runtime.exs`); Mix recompiles the dep when it changes. It can't be
  flipped per-test — the e2e check is manual: temporarily append
  `config :phoenix_kit, prefix: "..."` to `config/test.exs`, recompile,
  run a script exercising `register_user` against a scratch schema
  (needs `PhoenixKit.Users.RateLimiter.Backend.start_link` +
  `PhoenixKit.PubSub.Manager.start_link` + `:phoenix_pubsub`/`:hammer`
  apps started), then revert + recompile.
- **Oban rides the same prefix** — the `V135` baseline creates
  `oban_jobs` inside the named schema via `Oban.Migration.up/1`
  (folding V27's original idiom), so the host's `config :app, Oban`
  must carry `prefix: "..."`. The installer writes it for new prefixed
  installs; `mix phoenix_kit.update` warns when an existing Oban config
  lacks it.
- Feature modules' own schemas (`phoenix_kit_catalogue` etc.) do NOT get
  the prefix from core — prefixed installs using feature modules need
  the same treatment there (open item, per-module).
