# Upgrading to PhoenixKit 3.0

**New installs need nothing from this guide.** `mix igniter.install phoenix_kit` gives you core's tables, and every
module you install creates its own.

3.0 is a major release because of two removals. Read both before you upgrade a production database.

1. **Core no longer creates the tables of the optional modules.** Until 2.65 core's migration chain created 140 tables
   that belong to 25 modules (ai, billing, catalogue, emails, ...). From 3.0 each module's own migration chain creates
   its tables, and `mix phoenix_kit.update` runs the installed modules' chains after core's, in dependency order (staff
   before projects, billing before ecommerce). Existing tables are left exactly as they are.
2. **Email templates no longer come from the database.** A message is built from your override files
   (`priv/phoenix_kit_templates/...`, see [Email templates](email-templates.md)) or the shipped default. The
   `phoenix_kit_email_templates` table is no longer read, and the admin pages that edited it are gone.

The machine API also lost its deprecated shop names (see "Removed" below).

## Coming from 1.7.x

There is one route, three pins, run in this order on **every** database (development, test, staging, production):

| database at | pin | run until `mix phoenix_kit.status` reports |
|---|---|---|
| below V135 (any 1.7.x before 1.7.236) | `{:phoenix_kit, "== 1.7.236"}` | V135 or higher |
| V135 to V224 (1.7.236, any 2.x) | `{:phoenix_kit, "== 2.65.0"}` | V225 |
| V225 | the 3.x release you want | the current version |

At each pin: `mix deps.get`, then `mix phoenix_kit.update`, then commit what it wrote. An older release's
`mix phoenix_kit.status` compares the database only with its own chain, so on 1.7.x "Next: Ready" means "current for
1.7.x", not for 3.x. The breaking changes of 2.0 are in
[Upgrading to 2.0](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/guides/2026-08-07-upgrading-to-2.0-guide.md);
the settings and functions renamed on the way are in [Renamed and removed since 1.7](#renamed-and-removed-since-17).

## Before you run the update

- **Stop the application first, or work on a separate checkout.** The update compiles and boots the app. Recompiling a
  `_build/prod` that a running, supervised server loads from can restart it on half-upgraded code against the old
  database, and it keeps serving without complaint. Upgrade a copy, deploy the result.
- **Preview it,** where the release has the flag (`mix phoenix_kit.update --help` lists it):
  `mix phoenix_kit.update --dry-run` shows the diff of every project file it would edit, lists the steps it would run,
  and writes nothing.
- **Only the database, without booting the app:** `mix phoenix_kit.update --migrate-only` starts the repo alone and runs
  PhoenixKit's step-up, Oban's schema step-up and the installed modules' migrations (writing their files). Use it when
  starting the app is unwelcome on that machine (bots, pollers, a Telegram `getUpdates` loop competing with production),
  then run the full update where the app may start, for the configuration and asset steps.
- A database below the release's floor is refused. Releases up to 3.9.0 refused only after editing `config/config.exs`
  and writing module migration files; if such a run left files behind, delete them before you run it again, or the next
  run writes a second set. Later releases refuse before writing anything.

### Generated step migrations belong to the pin that wrote them

`mix phoenix_kit.update` writes `..._phoenix_kit_update_vNN_to_vMM.exs`. Files written by this release call
`PhoenixKit.Migrations.up_to!(MM, prefix: ...)`; earlier releases wrote `PhoenixKit.Migrations.up(version: MM)` (those
files are left as they are). Either works only with a release whose chain has version MM and accepts a database at NN:

- **Already there:** on a database at MM or later (another environment's later step file already ran, or the whole
  chain built a fresh database) `up_to!/2` does nothing.
- **Forward:** after you move the pin on, a database still at NN raises `BelowFloorError` on that file, naming the
  bridge release to install first; the migration never reports success. Apply each step file on every environment while
  it is still on the pin that wrote it.
- **Backward:** an older pin does not have the versions the file names. Its migration raises `TargetAheadError`
  ("this release's chain ends at V…") instead of failing half-way; move the file out of `priv/repo/migrations` while
  that pin is in use.

So for a staged rollout, walk each environment through the pins of the table above one at a time; do not commit the
step files of a later pin before every environment has passed the earlier one. Rebuilding an empty database from old
step files is covered in [Fresh databases and old host migrations](#fresh-databases-and-old-host-migrations).

## Edits the updater makes to your project

Besides migrations, `mix phoenix_kit.update` keeps a few optional pieces of your project in step with the kit. Each has
a stable ID, and the update records in **`.phoenix_kit.exs`** (project root — commit it) which ones it applied and which
you declined:

| ID | the edit |
|---|---|
| `module_js_seed` | the module-hooks `<script>` tag in the root layout, and the seeded `phoenix_kit_modules.js` |
| `oban_queues`, `oban_queues:<queue>` | the Oban queues core and your *installed* packages declare (never removed, limits never changed) |
| `daisyui_themes` | `themes: false` → `themes: all` on the daisyUI plugin in `app.css` |
| `css_sources_import` | `@import "./_phoenix_kit_sources.css";` in `app.css` |
| `theme_bootstrap` | the theme bootstrap in your root layout (opt-in only, see below) |

- **Removed one on purpose?** It stays removed. An edit recorded as applied that is gone on a later run is treated as
  declined, not re-added, and the run lists it with `mix phoenix_kit.update --repair-patch ID` to bring it back.
- **Decline one up front:** `mix phoenix_kit.update --skip-patch ID` (repeatable), or an inline marker in the file it
  edits: `# phoenix_kit:skip oban_queues:posts` in `config.exs`, `/* phoenix_kit:skip daisyui_themes */` in `app.css`,
  `<%!-- phoenix_kit:skip module_js_seed --%>` in the root layout.
- **No `.phoenix_kit.exs` yet:** the first run behaves exactly as before and then records what is present.
- Required configuration (Ueberauth, Hammer, the Oban block and its supervisor child, the compilers, the boot hook) and
  the security-relevant endpoint guard (`body_guard`) cannot be declined.

## Order of operations

1. **Get to 2.65.0 first.** 3.0 upgrades an existing database only from **V225**, the last 2.x version.
   `mix phoenix_kit.update` refuses every lower database with a notice that names 2.65.0;
   `PhoenixKit.Migrations.up/1` (what a migration file runs) raises `BelowFloorError`, also naming 2.65.0, for a
   database below V135 or one that has any of the module tables (every database built by a 2.x release does).
   2.65.0 sends a database below V135 to `1.7.236` first (see
   [Upgrading to 2.0](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/guides/2026-08-07-upgrading-to-2.0-guide.md)).

   ```elixir
   {:phoenix_kit, "== 2.65.0"}   # the bridge
   ```

   ```bash
   mix deps.get
   mix phoenix_kit.update   # repeat until it reports V225; run the generated migration(s)
   ```

   For a prefixed install, pass the same `--prefix` you installed with, and check each prefix.

2. **Export email templates you edited in the admin UI** (skip if you never changed one):

   ```bash
   mix phoenix_kit_emails.templates.export
   ```

   This writes your active templates as files under your app. Do it **before** you move to 3.0: the 3.0 emails module has
   no way to read the table through the application, and an edit that lives only in the table stops being sent.
   Commit the files. The table itself is not touched or dropped.

   **Without the emails module** (a core-only host) the export task is not there. Core 3.0 sends the shipped default
   copy, or your override files ([Email templates](email-templates.md)). To keep a template that was edited through an
   earlier release's editor, list the candidates (a seeded row that nobody edited has `is_system = true` and no
   `updated_by_user_uuid`):

   ```sql
   SELECT name, status, is_system, version, updated_by_user_uuid, updated_at
   FROM phoenix_kit_email_templates
   WHERE NOT is_system OR updated_by_user_uuid IS NOT NULL OR updated_at > inserted_at;
   ```

   and copy each one's `subject` and `text_body` / `html_body` (stored per language) into
   `priv/phoenix_kit_templates/<email>/` files (`subject.txt`, `text.txt`, `html.html`; `subject.de.txt` for one
   language). Compare with the default first: a row can differ only in whitespace.

3. **Move everything together.** Core 3.0 and every installed module must be on a release that accepts core 3.x (their
   core requirement reads `>= <floor> and < 4.0.0`). Update all `phoenix_kit*` dependencies in one commit; a module
   still on an older release keeps resolving core 2.x and `mix deps.get` will say so. `phoenix_kit_emails` needs core
   3.0 or later.

   ```bash
   mix deps.update phoenix_kit phoenix_kit_ai phoenix_kit_billing ...   # every phoenix_kit* you use
   mix phoenix_kit.update   # apply core updates, then each installed module's chain
   ```

   The module chains adopt the tables that already exist and add what is missing, so on an upgraded database they change
   nothing that holds data.

4. Run `mix phoenix_kit.doctor`. It checks core's tables; a module's tables are checked from its own manifest when the
   module is installed.

## Removed in 3.0

- **Machine API:** the deprecated paths `/api/shop/v1` and `/mcp/shop` (use `/api/public/v1` and `/mcp/public`), the old
  settings keys `api_public_cart_rate_per_min`, `api_public_cart_rows_per_ip_hour` and
  `api_public_cart_rows_global_hour` (the rows stay in `phoenix_kit_settings`; the first save of Settings -> API writes the
  new `api_public_token_rate_per_min`, `api_public_new_rows_per_ip_hour` and `api_public_new_rows_global_hour`), a public
  tool that names its caller token `cart_token` must now declare `client_token:`, the four shop error codes now come only
  from the module that declares them (`api_problems/0`), and `PhoenixKit.API.RateLimit.check_cart_rows/1` is
  `check_new_rows/1`.
- **Email provider callbacks** `get_active_template_by_name/1`, `render_template/2,3`, `track_usage/1` and
  `get_source_module/1`, and `PhoenixKit.Mailer.track_usage_after_delivery/2`. A custom provider drops them.

## Renamed and removed since 1.7

The migrations rename these rows for you. Code of yours that reads one by its old name
(`PhoenixKit.Settings.get_setting/2`, a raw query) silently gets `nil`, so search your app for every old name.

**Settings keys** (`phoenix_kit_settings.key`):

| old key | new key | migration |
|---|---|---|
| `db_sync_enabled` | `sync_enabled` | V44 (1.7.x) |
| `db_sync_incoming_mode` | `sync_incoming_mode` | V44 (1.7.x) |
| `db_sync_incoming_password` | `sync_incoming_password` | V44 (1.7.x) |
| `storage_default_bucket_id` | `storage_default_bucket_uuid` | V76 (1.7.x) |
| `publishing_translation_endpoint_id` | `publishing_translation_endpoint_uuid` | V76 (1.7.x) |
| `tickets_enabled` | `customer_support_enabled` | V77, then V109 (1.7.x) |
| `tickets_per_page` | `customer_support_per_page` | V77, then V109 |
| `tickets_comments_enabled` | `customer_support_comments_enabled` | V77, then V109 |
| `tickets_internal_notes_enabled` | `customer_support_internal_notes_enabled` | V77, then V109 |
| `tickets_attachments_enabled` | `customer_support_attachments_enabled` | V77, then V109 |
| `tickets_allow_reopen` | `customer_support_allow_reopen` | V77, then V109 |
| `auto_granted_perm:tickets` | `auto_granted_perm:customer_support` | V77, then V109 |
| `seo_module_enabled` | `crawlers_module_enabled` | V172 (2.x) |
| `seo_no_index` | `crawlers_no_index` | V172 (2.x) |

V77 renamed the `tickets_*` keys to `customer_service_*` and V109 renamed those to `customer_support_*`; a host that
read the in-between names needs the same change. The role permission `module_key` moved the same way
(`tickets` → `customer_service` → `customer_support`, and `seo` → `crawlers`, where V172 keeps the old `seo` rows).
V114 replaced the `integration:<provider>:<name>` keys of integration rows with the row's uuid; read connections
through `PhoenixKit.Integrations`, never by key.

**Removed, with no replacement key:** `shop_currency` (V184) and `billing_default_currency` (V189). Neither was read;
the default currency is the `is_default` row of `phoenix_kit_currencies` (`PhoenixKitBilling.get_default_currency/0`).

**Functions:** `PhoenixKit.Users.Auth.Scope.user_id/1` is `user_uuid/1` (since 1.7.63). It shows up only as a compile
warning, and an app compiled with warnings allowed gets `nil` in its place: build once with
`mix compile --warnings-as-errors` after the upgrade. The test LiveViews older installers generated
(`...PhoenixKitLive.Test*AuthLive`) call it too; `mix phoenix_kit.doctor` flags them, delete them.

## Fresh databases and old host migrations

This matters only if your host upgraded from 2.x **and** you rebuild its database from the migration files: a test
database (`mix test` runs `ecto.migrate` with the standard `test` alias), CI, a new developer machine, a new
environment. The problem does not touch a running database; the fix does run once on it, see below.

First find out whether you are affected. On a throwaway database (for example the test one:
`MIX_ENV=test mix do ecto.drop, ecto.create, ecto.migrate`), run the migrations, then `mix phoenix_kit.status`. If the
migrations fail, or any installed module is reported as not installed or behind, read on. If they go through and every
module is up to date, stop here.

**Symptom.** `mix ecto.migrate` on an empty database stops part-way through the old history with one of:

- `PhoenixKit database is at version 65, below this release's floor (V225)` (`BelowFloorError`, the version differs by
  file), raised by a `..._phoenix_kit_update_vNN_to_vMM.exs`;
- `relation "phoenix_kit_..." does not exist`, raised by a module's generated `..._update_vXX_to_vYY.exs`, or by a
  migration you wrote that alters a module's table.

**Cause.** Two separate things; either one is enough to fail.

- A step file that sets the version stamp itself. A plain `PhoenixKit.Migrations.up(version: 69)` on a database that is
  already at V225 does nothing, but a file that also runs `COMMENT ON TABLE phoenix_kit IS '65'` (the generator does not
  write one; hosts have it in files they edited by hand or took from an older generator) pulls the stamp from V225 down
  to V65 (a stamp below V135 is refused), and the next file's `up(version: 69)` finds a database below the floor and
  raises. Find such files with `grep -l "COMMENT ON TABLE" priv/repo/migrations/*.exs`; delete one that is a step file
  (step 2 below), and for a file you wrote by hand remove the `COMMENT` line.
- Core no longer creates the module tables. A module's `..._update_vXX_to_vYY.exs` runs that module's chain only up to
  the old target version, and a step in it can need a table that is only created further on, by a later step of that
  chain or by another module's chain (which is why the new files below are generated in dependency order); your own
  migrations that alter a module's table run before that module's chain has created it.

On a database that already ran these files none of this happens: every one of those versions is recorded in
`schema_migrations`.

**Fix.** Replace the generated files by a fresh set:

1. Keep the migration that installed PhoenixKit (it calls `PhoenixKit.Migrations.up(...)`; usually the oldest,
   `..._add_phoenix_kit_tables.exs`, or `..._create_phoenix_kit_tables.exs` if yours has that name), the Oban schema
   steps (`..._phoenix_kit_update_oban_vNN_to_vMM.exs`: they step Oban's own tables and replay fine), and every
   migration you wrote by hand.
2. Delete the generated ones: `..._phoenix_kit_update_vNN_to_vMM.exs` (and any `..._phoenix_kit_force_update_...`)
   for core and `..._<module>_update_vXX_to_vYY.exs` for each module.
3. Guard each hand-written migration that touches a module's table. It now runs before that module's chain has created
   the table, so test for the table first, in a `DO $$ BEGIN IF to_regclass('public.phoenix_kit_orders') IS NOT NULL
   THEN ... END IF; END $$` block (your own prefix instead of `public` if you use one), or use `ALTER TABLE IF EXISTS`,
   and make `down` tolerate a missing table as well. A guarded migration does nothing on an empty database. If it adds
   something the module's own chain does not create, rename it after step 4 (the generated files get timestamps newer
   than every migration that exists then) so that it sorts after them, make it idempotent (`ADD COLUMN IF NOT EXISTS`,
   `CREATE INDEX IF NOT EXISTS`; the new name is a new version, so it runs once more on running databases), and repeat
   step 5.
4. On an empty database run `mix ecto.create && mix ecto.migrate`, then `mix phoenix_kit.update` (in CI or any
   non-interactive shell add `--yes`; without it the task stops with an error, and if it had already written the module
   files a plain `mix ecto.migrate` finishes the job). It writes one `..._update_v00_to_vNN.exs` per installed module, in dependency
   order (billing before ecommerce, staff before projects), and runs them. Commit them with the rest.
5. Check it: drop and recreate the scratch database, then run `mix ecto.migrate` once more. It must now go through from
   nothing, with no extra command.

**What the new files do to your existing databases.** Their versions are not in `schema_migrations`, so the next
`mix ecto.migrate` on a running database runs them once. They are idempotent: they adopt the tables that exist and add
what is missing, and on an upgraded database they change nothing that holds data. A module's chain may drop and add a
CHECK constraint again with the same condition (seen for two CHECK constraints of one module on a copy of an upgraded
database); that takes an exclusive lock on its table while every row is validated. Rehearse on a restored copy, and run
it in a quiet hour if a table is large. If you prefer that a running database does not run the files at all, confirm
with `mix phoenix_kit.status` that every module reports up to date, then insert the new file versions into
`schema_migrations` yourself. Do not roll these files back on a database that holds data: their `down` goes back to
version 0 of the module's chain.

A database built from a structure dump (`mix ecto.dump` once, which needs `pg_dump`, then `mix ecto.load` in a `test`
alias that no longer runs `ecto.migrate`) avoids all of this for tests, at the price of `mix test` no longer proving
that the migrations build a database.

## If something goes wrong

- *`BelowFloorError` naming 2.65.0* - the database is below V225. Do step 1. If it appears while `mix ecto.migrate`
  rebuilds an *empty* database from your old migration files, see "Fresh databases and old host migrations" instead.
- *A module's table is missing after the upgrade* - run `mix phoenix_kit.update` again with the module installed; its
  chain creates what is missing. Nothing in core 3.0 drops a table.
- *`mix deps.get` cannot resolve* - a module is still on a release that pins core `~> 2.x`; update it to the 3.x-ready release.
