# AGENTS.md

**PhoenixKit** — foundation for building Elixir/Phoenix apps (SaaS, ERP, marketplaces, AI apps, community platforms). Library-first architecture with Phoenix/PostgreSQL: auth + Magic Links, role-based access (Owner/Admin/User), admin dashboard, daisyUI 5 themes, versioned migrations, layout integration with parent apps.

**Topic guides** — read when working in that area: [core UI components](dev_docs/guides/2026-09-11-core-components.md) · [external module packages](dev_docs/guides/2026-09-11-external-module-development.md) · [login & registration](dev_docs/guides/2026-07-28-login-and-registration.md) · [activity feed](dev_docs/guides/2026-09-11-activity-feed.md) · [notifications](dev_docs/guides/2026-07-27-notifications.md) · [integrations](dev_docs/guides/2026-07-27-integrations-system.md) · [prefix-safe migrations](dev_docs/guides/2026-07-27-prefix-safe-migrations.md) · [admin path & label](dev_docs/guides/2026-09-11-admin-path-and-label.md) · [active role](dev_docs/guides/2026-09-13-active-role.md) · [machine API](dev_docs/guides/2026-10-11-machine-api.md)

## Workflow

0. **First clone only:** `git config core.hooksPath .githooks` — enables the tracked pre-commit hook (a clone must not run code on checkout, so git won't do this for you). `mix phoenix_kit.doctor` reports it under "Git Hooks".
1. Make changes
2. `mix precommit` — compile (warnings as errors) + `deps.unlock --check-unused` + `test.compile` (compiles every `test/**/*_test.exs` in a `MIX_ENV=test` subprocess without `test_helper.exs` — no DB, zero tests run; catches a test file that does not compile, e.g. a duplicate `describe`) + `quality.ci` (format-check, credo --strict, dialyzer) + JS tests. **Does NOT run `mix test`** — see "CI/CD" below.
3. Fix problems
4. `git diff` / `git status` → commit

## Development Commands

- `mix setup` — full setup; `mix deps.get` — deps only; `mix ecto` — list ecto commands
- `mix format`, `mix credo --strict`, `mix dialyzer`, `mix quality`, `mix quality.ci`

### Tests

Two levels: **unit** (`test/phoenix_kit/`, `test/modules/` — no DB) and **integration** (`test/integration/`, `test/modules/*/integration/` — real PostgreSQL via Ecto sandbox).

```bash
mix test.setup    # create DB + run migrations (first time)
mix test          # run all (migrations auto via test_helper)
mix test.reset    # drop + recreate
```

Test DB `phoenix_kit_test` uses embedded `PhoenixKit.Test.Repo` (`test/support/test_repo.ex`). Schema comes from the versioned migration chain — `test_helper.exs` runs `PhoenixKit.Migration.ensure_current/2` on every boot. **Do not** swap in `Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)` — it goes silently stale (see `ensure_current/2` moduledoc).

**Without PostgreSQL:** integration tests are auto-excluded; unit tests still run (banner printed, exit 0).

**`PhoenixKit.TestSupport.PostgresPreflight`** is the shared DB connection check every package's `test_helper.exs` runs before starting its repo. It ships in `lib/` so sibling packages can reach it through Hex — never call it from application code. Why it exists + the load-bearing implementation details: `dev_docs/guides/2026-09-11-postgres-preflight.md`.

DB tests: `use PhoenixKit.DataCase, async: true` — auto-tags `:integration`.

### Local cross-repo development

Core has no `phoenix_kit` dep of its own — the flow matters from the **consumer** side. Every feature module wraps its `phoenix_kit*` deps in a `pk_dep/3` helper, so a module's suite can run against **uncommitted local core** without publishing. From inside the module's directory:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Var name = dep app upper-cased + `_PATH`; unset = published Hex pin (`mix hex.publish` / CI unaffected). `phoenix_kit_parent` does the same permanently — use it to exercise the whole tree against local core. Details: workspace `AGENTS.md` → "Testing a module against local deps".

### Code Search

- `rg` — text/regex/strings/comments
- `ast-grep` — structural patterns; **prefer over text grep for code searches**: `ast-grep --lang elixir --pattern 'def $FUNC($$$ARGS) do $$$BODY end' lib/`

## Pull Requests

- **Branch:** PRs against **`main`** (`gh pr create --base main --head <fork-owner>:<branch>`). There is no `dev` branch; do not target one.
- **CI/CD:** `.github/workflows/ci.yml` is **manual-only** (`workflow_dispatch`) — nothing runs on push or PR. When dispatched: `postgres:16` + `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix deps.unlock --check-unused`, `mix test.setup` + `mix test`.
- ⚠️ **Nothing runs the Elixir suite automatically — not CI, not `precommit`.** For anything touching the schema, run `mix test` yourself: with no DB reachable, `test_helper.exs` excludes every `:integration` test but still **exits 0** — a green summary proves nothing about a migration.
- Point the suite at an existing DB (avoids needing `CREATEDB`; bound concurrency on shared servers):
  ```bash
  PGHOST=… PGUSER=… PGPASSWORD=… PGDATABASE=my_scratch_db PGPOOL=20 mix test --max-cases 8
  ```
- ⚠️ **Database-less runs set `config :phoenix_kit, :update_mode, true`** (`test_helper.exs`): every `PhoenixKit.Settings` read short-circuits to `nil`, so **every settings-dependent unit assertion runs against "nothing is configured"**. A test that needs a *value* must prime the cache itself (start `PhoenixKit.Cache.Registry` + `{PhoenixKit.Cache, name: :settings}`, then `PhoenixKit.Cache.put/3` — consulted before the short-circuit). Worked example: `test/phoenix_kit/utils/safe_destination_settings_test.exs`.
- **Commit messages:** start with `Add`, `Update`, `Fix`, `Remove`, `Merge`.
- **Versioning:** bump `mix.exs` `@version` + `CHANGELOG.md`; run `mix compile`, `mix test`, `mix format`, `mix credo --strict` before committing. Latest migration version:
  ```bash
  ls lib/phoenix_kit/migrations/postgres/v*.ex | sed 's/.*\/v\([0-9]*\)\.ex/\1/' | sort -rn | head -1
  ```
- **CHANGELOG entries:** write against the bumped `@version` heading; match existing style (Added / Changed / Fixed / i18n, bullets from PR scopes + post-merge review fixes).
- **CHANGELOG archive:** `CHANGELOG.md` holds the **current quarter only** (it ships in the Hex package and hexdocs). On the first release of a new quarter, move the previous quarter's entries verbatim into `dev_docs/changelogs/YYYY-QN.md` (heading `# PhoenixKit changelog — YYYY QN`) and add its link to the footer of `CHANGELOG.md`. 2025 is one file, `dev_docs/changelogs/2025.md`.
- **PR reviews:** `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md` (`CLAUDE_REVIEW.md` for Claude). Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.
- **Publish:** `mix prerelease` first — it is the gate, running `deps.get --check-locked`, `deps.unlock --check-unused`, a prod `compile --warnings-as-errors`, `quality.ci`, `deps.audit`, `hex.audit`, `docs`, `hex.build`, `phoenix_kit.release_check` and `package.clean`. Then `mix hex.publish`.
- **Package tarballs:** `hex.build`/`hex.publish` drop `phoenix_kit-<version>.tar` in the project root and never clean up — left alone they pile up one-per-release (199 MB by Sep 2026). `prerelease` now ends with `package.clean`; after a bare `mix hex.publish`, or if a gate step failed before the cleanup ran, sweep them with `mix package.clean`. They are gitignored, never commit one.

## Database

- Schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- New migrations use `uuid_generate_v7()` (NOT `gen_random_uuid()`)
- Oban-style versioned migrations in `lib/phoenix_kit/migrations/postgres/`
- ⚠️ **A module's table is never touched by a core migration.** Core's chain still creates 141 tables that belong to 25 modules (a leftover from when they lived in core); `PhoenixKit.Migrations.ModuleOwnedTables` says whose each table is. No version after V223 may create, change or drop one: put the change in the owning module's own chain. A new core table goes into `ModuleOwnedTables`' core list. `test/phoenix_kit/migrations/module_owned_tables_test.exs` enforces both. The move of these tables into their modules: `dev_docs/plans/2026-10-25-module-table-ownership.md`.
- Every edit to `v*.ex`, including comments, changes the manifest's `chain_hash`. For schema-neutral edits, run `mix run dev_docs/squash/restamp_chain_hash.exs --restamp` after `mix format`, then run the release-check tests. For schema changes and manifest verification, follow the [manifest regeneration policy](dev_docs/squash/README.md#manifest--reference-policy-regenerate-never-hand-merge).

### Prefix-safe migrations (named-schema installs)

The chain supports running into a named Postgres schema (`prefix:` opt / `--prefix`). Full reference + incident history: `dev_docs/guides/2026-07-27-prefix-safe-migrations.md`. Prefix is validated at the entry points (`Helpers.validate_prefix!/1`); tooling resolves `--prefix` → `config :phoenix_kit, prefix:` → `"public"`. Hard rules for new `execute`-built SQL:

- **Index names stay bare on CREATE** — qualify only on `DROP INDEX`.
- **Every existence check needs a schema anchor** — `table_schema` on `information_schema.*`, `schemaname` on `pg_indexes`, name-based `pg_class` + `pg_namespace` JOIN for `pg_constraint` (never `'p.table'::regclass` in an IMMEDIATE check — it raises when the relation doesn't exist yet and aborts the whole transaction).
- **Schema-qualify functions** via `PhoenixKit.Migrations.Postgres.Helpers.ensure_uuid_v7_function/1` + `uuid_v7_call/1`; **never bare `CREATE EXTENSION`** (use `Helpers.ensure_extension!/1`) **or bare `CREATE SCHEMA`** (check `information_schema.schemata` first; thread `create_schema: false` to external migrators like Oban).
- **New table-backed schemas must `use PhoenixKit.SchemaPrefix`** right after `use Ecto.Schema` — enforced by `test/phoenix_kit/schema_prefix_test.exs`. Prefix is compile-time config (`config.exs`, never `runtime.exs`). **Oban rides the same prefix** — the host's `config :app, Oban` must carry `prefix: "..."`.
- ⚠️ **Oban's schema follows the Oban library, not this chain.** V135 calls `Oban.Migration.up/1` once; a host that later moves to a newer Oban (the `~> 2.20` pin allows it) keeps the old schema — under Oban 2.24 (schema v14) every unique insert, cron's included, fails. `mix phoenix_kit.update` steps it up through a generated `phoenix_kit_update_oban_vNN_to_vMM` host migration (`PhoenixKit.ObanSchema`); doctor/status report it, boot logs it. Never fold a newer Oban version into a core `V*` migration.
- Oracle: `test/integration/prefix_migration_test.exs` runs the full chain into a scratch schema (bad SQL queued by one version often blows up at a later version's `flush()`).

## Admin UI Components

Building admin forms, lists, or media pickers? Read `dev_docs/guides/2026-09-11-core-components.md` first — canonical form primitives (`Core.{Input, Select, Textarea, Checkbox}`), the list-UI toolkit (sortable, bulk-select, reorder modal, pagination), multilang form components, LayoutWrapper, MediaBrowser, dashboard. Two rules that bite mid-task:

- ⚠️ **Multilang wrapper scope:** `<.multilang_fields_wrapper>` wraps translatable fields **only** — its id includes `@current_lang`, so a language switch re-mounts everything inside; non-translatable fields (pricing, status, actions) render outside it or lose state on every switch.
- ⚠️ **Every `<form phx-change=…>` needs a unique `id`** — without it LiveView form recovery is silently disabled and host test suites warn `missing_form_id`. LiveComponent → derive from `@id`; inside a comprehension → include the row uuid. Full audit: `dev_docs/investigations/2026-07-27-missing-form-id-audit.md`.

## Storage & Image Editing

Files, variants, buckets and serving: `lib/modules/storage/README.md` (→ "Versions and caching", "Editing images"). Landmines:

- ⚠️ **System-managed files are never served or listed** — tile chunks and an edited image's hidden unedited original (`ImageEditing.backup/1`) are `system_managed` children. `FileController`, `FileServer` and `Storage.get_public_url*` refuse them; a new serving path must too. The unedited original is reachable only through `GET /api/files/:uuid/unedited`. Its objects sit at private `unedited_*` keys, copied off the served keys by the first edit (a public bucket hands served keys out as plain URLs), so never point a backup row back at a served key.
- ⚠️ **Delete stored objects only through `Storage.delete_stored_objects/2`** (or `delete_file_completely/2`, which ends in it, or `delete_unreferenced_keys/1`, the second phase of a deletion made in a transaction of the caller's). Keys are shared (cross-user copies, an edited file and its backup) and content-addressed (written again by later jobs); it re-checks the references under the directory lock. A bare `Manager.delete_file/1` on a key can delete another file's bytes.
- ⚠️ **Something derived from a file's bytes is recorded only while those bytes are still its original** — read them with `Storage.retrieve_original/1` and check `Storage.original_key?/2` in the transaction that records the result (variants, dimensions). An image edit can swap the original at any moment.
- ⚠️ **Every file, folder and folder link has a `library_uuid`** (V202, `Storage.Libraries`). A writer that names none lands in Media through the column default, which is why existing module code keeps working. Keep libraries apart: a folder's subfolders, home files and links are all its own library's; the core functions refuse a cross-library move/attach/link with `{:error, :other_library}`, so go through them rather than writing `folder_uuid` or inserting a `FolderLink` by hand. Objects are not shared across libraries either, with one explicit exception: `Storage.link_copy/3` (and `relink_file/3` for an existing record) — called by name, donor by file, the caller checks the user may read the donor, and only the original and generator-made sizes (`spec_hash`) are shared, never burned or annotated thumbnails. A root-level listing for one library passes `library_uuid:`.
- ⚠️ **A file in a user library, or in a hidden system library (`Libraries.hidden?/1`), is private** (V203): its URL needs a time-window token. Mint it with `Storage.authorized_url(scope, file, variant)` (checks access first) or `URLSigner.signed_url(uuid, variant, private: true)`; the other URL helpers mint the permanent token, which the file route refuses for it. A new serving path must refuse the permanent token too, and never redirect a private file to a public object URL.
- ⚠️ **A managed hidden library (`Libraries.managed?/1`, `create_system_library(…, hidden: true, media_listing: …, managed: true)`) is changed by no user, an Owner included.** A new function that trashes, deletes, moves, renames, links, annotates, burns on, edits the image of or rewrites the details of a file or folder must start with `Libraries.check_managed(target, opts)` and take the owner module's `managed: :owner` option (see `lib/modules/storage/README.md`, "Shown in Media and read-only"); `update_file/2`, `update_file_instance/2` and the stored-file processing stay open. The check goes before any owner, `system: true` or `can?/3` branch.
- ⚠️ **A cloud bucket's keys live in an `object_storage` Integrations connection** (`integration_uuid`); the bucket form has no key fields. A bucket carrying its own `access_key_id`/`secret_access_key` is legacy and must keep working — `S3.resolve_credentials/1` reads both, and `Storage.BucketCredentials.move_to_integration/2` moves one on purpose (never automatically, never clearing a key it cannot read back). The bucket keeps its own `region`/`endpoint` (not secrets; `public_url` runs per file, so no settings lookup behind it). **Every endpoint goes through `Storage.Endpoint`** (`parse/1` is the one reading, `check/3` the guard: `:system` refuses metadata/link-local/reserved, `:personal` also loopback/private and plain http) — never re-parse one by hand, and a connection validator needs the owner (`Integrations.validate_credentials/3` `owner:`), or a user connection is checked like an admin's. A personal SMTP connection's host goes through `Mailer.SmtpEndpointPolicy` (opt-in `config :phoenix_kit, :personal_smtp_policy, :restricted`; addresses judged by `Utils.PublicAddress.public?/1`, so `:blocked_ip_ranges` applies), at Test Connection and before every send.
- ⚠️ **A user's own bucket (V206) has `owner_uuid` and stays out of everything the site enumerates.** `Storage.list_buckets/0`, `list_enabled_buckets/0` and `Profiles.list_profiles/0` return the site's rows only — keep it that way, and never build a bucket list for placement, probing, health or deletion from anything else. A user's bucket is reached through file location rows (`Manager.read_order/4` resolves located buckets by uuid) and the library's own profile (`Storage.owned_buckets_for_dir/1`); a miss never probes one. `owner_uuid` has **no FK** on purpose (SET NULL would turn it into a site bucket) and is **never cast from params** (`Bucket.owned_changeset/4` only). A library's storage choice is final (`Profiles.set_library_profile/2` refuses it; `assign_user_profile/2` is the creation path). Backup mode needs one original per site bucket plus the backup, because placement fills primaries before backups.
- ⚠️ **Media shows each viewer only what is theirs** (`dev_docs/plans/2026-09-30-media-by-viewer.md`). A holder of `media` *without* `media.view_all` is a restricted viewer of a site library: `Live.Users.Media` passes `viewer_uuid` to `MediaBrowser`, which adds `:viewer_uuid` to every `Storage` read (`lib_opts/1`) and refuses, in its first `handle_event` clause, any event naming another's file, an invisible folder, or changing a folder the viewer did not create. **A new listing or a new event in the browser must carry the option / be covered by that guard**, and a new way to open a file by uuid (a URL param, an API) must check `Storage.viewer_can_see_file?/2` and the library. The storage admin screens are `media.manage`, not `media`; `media.view_all`/`media.manage` are sub-permissions of a core section (`Permissions` `@core_sub_permissions`) backfilled once to existing `media` holders. The media pickers are deliberately unfiltered (editors authoring content).
- **Build file URLs with `version:`** when the instance is at hand (`URLSigner.signed_url(uuid, variant, version: instance)`); only a versioned URL is cached for good.

## Login & Registration

Full reference: `dev_docs/guides/2026-07-28-login-and-registration.md`. All settings live on `/admin/settings/users`. Landmines:

- ⚠️ **`Routes.local_path?/1` is the only redirect guard** — rejects `//`, `/\`, and **ASCII control characters** (browsers strip tab/CR/LF, so `"/\t/evil.com"` lands as `//evil.com`; LiveView's `validate_local_url!` does not block these). Every LiveView `redirect(to: ...)` of user-influenced input MUST go through it.
- **Post-auth destination:** one resolver, `Routes.post_auth_path/1`. Precedence: explicit `return_to` > `after_registration_path` > `after_login_path` > `/admin`. Tail is `/admin`, not `"/"` — `"/"` belongs to the host and may 404.
- **Carrying `return_to`:** `Routes.return_to_query/1` threads it across login/register/magic-link/QR/OAuth links and the magic-link email URL. A new sign-in entry point must thread it too.
- ⚠️ **Hiding the registration `<select>` is not the control** — `registration_changeset/3` casts `account_type` from the payload, so every public form pipes its params through `Auth.enforce_registration_account_type/2`. **Never hardcode `%{"remember_me" => "true"}`** — flows with no UI to tick use `Auth.remember_me_params/0`.
- ⚠️ **Public auth endpoints rate-limit BEFORE the lookup** — limiting inside the send throttles only addresses that resolve to a user, turning the deliberately generic copy into an account-existence oracle. Rate limiting keys on `PhoenixKit.Utils.IpAddress.extract_from_conn/1` (a public `remote_ip` as-is; behind a loopback/private peer — or, when `:trusted_proxies` is set, only a peer inside it — the LAST `x-forwarded-for` entry, then `x-real-ip` — never the first XFF entry, which the client writes); the test adapter reports one peer for every conn, so give each login-heavy test its own peer (`with_peer/2` in `auth_flows_test.exs`).
- **Email confirmation:** `require_email_confirmation` (default true) gates *enforcement* only; emails always send. Honored at eleven sites (the `ensure_*` on_mount hooks, the `require_authenticated_*` plugs, and the role/permission plugs via the shared private `confirmation_gate/2`) — add it to any new gate.
- ⚠️ **Soft-failure paths need `rescue` AND `catch :exit`** — an unreachable DB raises on an unowned checkout but *exits* on a dead pool. Bites on a settings cache miss; presents as suite flakiness. Never evict a real settings key in a test; read a unique probe key instead.
- **The admin header's breadcrumb is built from four assigns and nothing else** — `page_section` (+ `_path`), `page_crumbs`, `page_title`, and the optional `page_subtitle` (shown only with the `show_page_descriptions` setting on). A page title never carries its own trail ("CRM — Contacts"): the section is the module, the crumbs are every level between, the title is the page. The rules and the per-page-type shapes are in `dev_docs/guides/2026-09-25-admin-header-trail.md`.
- ⚠️ **Flash belongs inside the LiveView tree** (LayoutWrapper / dashboard / host layout). `root.html.heex` deliberately has none — a copy there double-rendered every message with duplicate ids.
- ⚠️ A `disabled` `<.checkbox>` still submits its **un-disabled** hidden `value="false"` fallback, silently rewriting the setting on save. Don't use `disabled` to mean "inactive right now" in a settings form.

## Permissions

`PhoenixKit.Users.Permissions` — allowlist model (row present = granted, absent = denied); Owner always has full access, enforced in code. The moduledoc is the source of truth; highlights:

- **Module keys** gate admin sections/feature modules; custom keys via `register_custom_key/2`. The two integration keys are independent flat keys: `integrations_system` is auto-granted to Admin, `integrations` is opt-in (never auto-granted).
- **`api` key** — gates Settings -> API (keys, service users, the API switches and limits). A core section key and **opt-in for Admin** (`opt_in_admin_keys/0`): neither the boot sweep nor the tab registry grants it, so an upgrade does not let every Admin mint bearer keys. The Owner has it by construction. Guide: `dev_docs/guides/2026-10-11-machine-api.md`.
- **`"*"` superadmin key** (`Permissions.superadmin_key/0`) — a blanket Owner-equivalent grant honored by `Scope.superadmin?/1` / `has_module_access?/2` / `accessible_modules/1`. In `all_module_keys/0` but NOT `enabled_module_keys/0` (never a *required* key); cannot be registered as a custom key.
- **Admin-area gate**: `Scope.can_access_admin_area?/1` — true for Owner, Admin, OR any single permission holder (`admin?/1` is a deprecated alias). `Scope.holds_all_enabled_permissions?/1` is the "can do everything, like Owner" check.
- **Sub-permissions** — dotted keys under a base (`"calendar.view_others"`), declared in `permission_metadata/0`'s `sub_permissions`, checked by the module via `Scope.can?/2`. A sub implies its base (granting a sub auto-grants the base; revoking the base cascades). Grant/revoke run under a per-`{role, base-key}` advisory lock.
- **Edit protection**: `can_edit_role_permissions?/2` — users cannot edit their own role; only Owner can edit Admin.
- ⚠️ **Who may hand out a role is decided in `Roles`, never only in the page**: `Roles.can_manage_role?/2` — an Owner always; anyone else only a role that is neither Owner nor Admin and whose every key they hold (a `"*"` role needs `"*"`). `sync_user_roles/3`, `assign_role/4`, `remove_role/3` and `delete_role/2` apply it for `actor:` (omitted = system, unchecked); a non-Owner never changes their own roles (`:cannot_modify_own_roles`), and refused changes come back in `:refused`. A new role-changing path passes `actor:` (`promote_to_admin/3`, `demote_to_user/2` and `safely_remove_role/3` take it too). ⚠️ An authorization or backfill decision reads permissions through `Permissions.fetch_permissions_for_role/1` / `fetch_permissions_matrix/0` / `fetch_roles_with_permission/1` and fails closed on `{:error, _}` — the `get_*` readers answer `[]` on a database error, which passes every subset check. The role modals render unmanageable roles locked and carry a held locked role as a hidden input, or the omission reads as a removal.
- **`settings.security`** (core sub-permission of `settings`, backfilled once to existing `settings` holders) gates Settings → Authorization and Settings → Website access (static map, tab, `Live.Settings.SecurityGate` on mount and every event) and the registration / new-user-default keys of Settings → Users. ⚠️ Those keys are enforced in `Settings.update_settings/2` with `scope:` (`Settings.security_setting_key?/1`: every `oauth_*`, `website_access_*`, `maintenance_*` key plus registration / login-method keys), because every settings form posts them as hidden fields — a settings page that saves through `update_settings` passes `scope:`. `update_settings/2` writes only `Settings.form_setting_keys/0` (public keys + OAuth secrets): a new form-owned key goes into `@public_setting_keys`, and internal flags (`*_backfilled`) are never writable from a form. The website-gate password is never rendered or held in assigns.
- **New-user default role** is never Owner or Admin (changeset, option list, and the runtime fallback `Roles.default_role_for_new_users/0`), and a changed value must pass `can_manage_role?/2` for the person saving. `list_all_settings/0` reports an unusable stored value as the role actually used, so the forms show and save that.
- **Ending someone's sessions** takes the status-change rank rule (`Sessions.can_revoke_sessions_of?/2` → `Auth.can_manage_user_status?/2`; own sessions always): pass `actor:` to `Sessions.revoke_session/2` / `revoke_user_sessions/2`.
- **Active role** (`PhoenixKit.Users.ActiveRole`, opt-in `role_switcher_enabled`): a user with 2+ switchable roles acts as one **per session**, and `Scope.for_user/1` narrows `cached_roles`/`cached_permissions` to it. Default = first held role in role order (`/admin/users/roles`). Guide: `dev_docs/guides/2026-09-13-active-role.md`.
  - ⚠️ **The active role lives on the session token** (`phoenix_kit_users_tokens.active_role_uuid`) and reaches `for_user/1` only through `%User{active_role_uuid: _}`, a virtual field that only the token loader fills. The refresh reloads through `phoenix_kit_session_token`, never by uuid — a by-uuid reload or a session/assign copy silently changes the role.
  - Access decisions read the scope; rules protecting against a user's REAL roles read `Scope.held_roles/1`. `Roles.*`/`User.get_roles` DB reads ignore the active role. Removing a role signs out the sessions acting as it (`Sessions.revoke_user_sessions_in_role/2`).
  - ⚠️ **Internal `custom_fields` keys: `Auth.merge_user_custom_fields/3`, never a whole-map replace from a struct held in assigns** — a stale replace restores every other key's old value. The other way round, `custom_fields` passed to `Auth.update_user_profile/2` / `User.profile_changeset/3` is the account holder's input: only defined, user-accessible fields are kept (`CustomFields.cast_user_input/2`), so system code never writes its keys through it.

## Languages

Core and always on — **not** a feature module (no Modules card, not in `ModuleRegistry`; `languages` is a core permission key). The switch is the first card of Settings → Languages: `Languages.enabled?/0`. Reference: `lib/modules/languages/README.md`. Landmines:

- ⚠️ **A menu or switcher reads `Languages.get_enabled_languages/0`, never `get_display_languages/0`** — the latter returns hardcoded defaults while the switch is off (languages with no route behind them).
- ⚠️ **The page must stay reachable while the switch is off** (it holds the switch). That is why the key is core: `Auth` refuses a page whose key is `feature_enabled?` false.
- ⚠️ **Switch off = single-language: no URL carries a locale segment**, for any locale (`Routes.path/2` emits none; the locale plug 302s `/<code>/…` to the clean path on kit routes). The site's language is `Languages.primary_language_code/0` — never `get_default_language/0` (nil while off) with a hardcoded `"en"` fallback. Host-owned `/:locale` scopes are the host's to handle: `guides/locale-routing.md`.

## Integrations System

Centralized OAuth / API key / bot token / credential management. Full reference: `dev_docs/guides/2026-07-27-integrations-system.md`; design: `dev_docs/plans/integrations-system.md`.

- **Storage:** `phoenix_kit_settings` JSONB, keys `integration:{provider}:{name}`. Consumers reference connections by storage-row **uuid** — all public API except `add_connection/3` and the read shims is uuid-strict.
- ⚠️ **Owner scopes:** every context call takes an `:owner` opt, **default `:system`** — pass `owner: {:user, uuid}` explicitly on the personal path or a forgotten owner silently births a SYSTEM row. Never encrypt `owner_uuid`.

## Activity Feed & Notifications

Track business-level actions via `PhoenixKit.Activity.log/1` (`action: "resource.verb"`; `target_uuid` = who was affected, drives notifications). Full references: `dev_docs/guides/2026-09-11-activity-feed.md` and `dev_docs/guides/2026-07-27-notifications.md`. Admin UI: `/admin/activity`.

- ⚠️ Notifications fan out via `Notifications.maybe_create_from_activity/1` when `target_uuid != actor_uuid` — **never insert `phoenix_kit_notifications` rows directly**. Kill switch: `notifications_enabled`.
- ⚠️ `DigestWorker` runs ONLY from cron, so `mix phoenix_kit.update` must **backfill those entries into existing hosts** (`ObanConfig.ensure_digest_cron_entries/2`) — a digest cadence suppresses the per-event inbox row, so a missing entry drops the notification entirely.
- **External modules** — call `PhoenixKit.Activity.log/3` (module key, action, options; never raises, so no guard or rescue) and read the actor with `PhoenixKitWeb.Actor`, never from assigns by hand. ⚠️ Both are absent from core ≤ 2.37.5. A module declares its core floor as a compound requirement in `mix.exs` (`">= 2.38.0 and < 3.0.0"`) and calls them directly when that floor is 2.38.0 or later; a module on a lower floor feature-detects (`function_exported?(PhoenixKit.Activity, :log, 3)` after `Code.ensure_loaded?/1`; same for `PhoenixKitWeb.Actor`) and keeps the old path as the fallback.
- **Cleanup:** `activity_retention_days` / `notifications_retention_days` (default 90); daily PruneWorkers via Oban.

## Machine API

Keys, tools and the REST endpoints modules plug into. Full reference: `dev_docs/guides/2026-10-11-machine-api.md`. Core code: `lib/phoenix_kit/api/`; admin page: `PhoenixKitWeb.Live.Settings.Api` (`/admin/settings/api`, permission `api`); the how-to-connect page for admins is `PhoenixKitWeb.Live.Settings.ApiGuide` (`/admin/settings/api/guide`, same permission, read-only).

- **Off by default, fails closed.** `api_admin_enabled` / `api_public_enabled` (read through `PhoenixKit.API.Config`); an off side answers 404 after one cached settings read.
- **A module's API can be switched off** on Settings -> API (setting `api_disabled_modules`, newline-separated module keys, default empty = all on): `PhoenixKit.API.Registry` withholds the module's tools like `api_disabled_tools` ones, and core's `system.*` tools are never affected. Every request path goes through the registry, so a new transport must not read `ModuleRegistry.all_api_tools/1` on its own.
- ⚠️ **A live session writes only after the person confirms, and only where an admin let it** (`Executor.execute_as/5` with `allow: :all`, `api_session_write_modules`, the "Agent may act" box): every write of a `:user` actor is held in a confirmation row bound to the user and runs through `Executor.redeem_as/6`, which repeats the whole request path. Do not add a path that runs a session's write on the first call, and do not let a key read that list.
- **Modules declare tools** with the optional `api_tools/0` callback (`PhoenixKit.API.Tool`); each admin tool has exactly one `scope` and one role `permission`. Module cron jobs use `oban_crons/0`. A host application declares its own tools the same way, in a module of its own (guide: "Tools of the host application").
- ⚠️ **Effective rights = key scopes ∩ the owner's permissions right now** (`Scope.for_user(user, narrow: false)` + `Scope.can?/2`). Owner rights are **never cached**; only the key row is (`Keys.Cache`, 60 s, invalidated on revoke and rotate). Do not add a cache in front of the permission check.
- ⚠️ **A token exists once**: `Keys.create_key/3` and `Keys.rotate/3` return it, only a SHA-256 of the secret is stored. The Settings page keeps it in the `:new_token` socket assign alone. Never put a token in a flash, a URL, a `phx-value-*`, a form field or a log line (LiveView logs event params at debug). The tests capture the debug log and assert it.
- ⚠️ **Service users (`users.api_only`) get no web session.** Every web authentication door refuses them, and so does the session lookup. A new login path (SSO, impersonation, an API that mints a session) must refuse `api_only` users too, with a test.
- **Settings -> API checks on the server** what the form offers: owner, scopes and roles are re-checked in the event handler and again in `Keys` / `ServiceUsers`, and the person's own rights are re-read from the database on every event that changes something (`with_access/2` -> `fresh_scope/1`; the scope captured at mount can be stale). Add a forged-input test (`render_submit(view, "event", params_the_form_never_offers)`) and a lost-`api`-mid-session test for every new event. ⚠️ `Keys.revoke/2`, unlike `Keys.rotate/3` and `Keys.update_scopes/3`, takes a bare actor uuid and checks nothing: the CALLER must authorize with `Keys.can_manage?/2` (the page does, by finding the key through `Keys.list_keys/1`).
- **The log never carries a request-derived value** (`PhoenixKit.API.LogSafe`): a failed handler or host hook logs the exception module, and the message only for `ArithmeticError` and `FunctionClauseError` (fixed text). The stdlib raises `ArgumentError`, `RuntimeError` and `UndefinedFunctionError` with the failing input, so their messages stay out. Test with a request-derived sentinel, not a constant. A process a handler spawns logs its own crashes outside this rule, so never put request data in the messages of such a process. Atoms are logged as "an atom" (one can be made from input) except `nil`, booleans, `:ok` and `:error`.
- **Credentials in URLs are refused** (`400 token_in_url`) before authentication. Keep `api_key` and `token` in `:phoenix, :filter_parameters` (`PhoenixKit.boot/1` does).
- **Install/update:** `mix phoenix_kit.update` adds `PhoenixKit.API.BodyGuard` to the host endpoint (2 MB body limit, JSON errors as problem+json). Add new install steps to **both** `phoenix_kit.install` and `phoenix_kit.update`.
- **Transports:** REST, `POST /mcp/admin` and `POST /mcp/public` (`PhoenixKit.API.MCP`) and `GET .../openapi.json` (`PhoenixKit.API.OpenAPI`) all reuse `Auth` and `Executor`. A transport never sends from inside the executor: `Executor.execute/4` and `Executor.visible/2` return data, `call/4` and `list/2` send it. Schemas shown to clients come from `Executor.input_schema/1` and `OutputShape.for_tool/1`. MCP and OpenAPI log through `LogSafe` too.
- ⚠️ **Public discovery** (`PhoenixKit.API.PublicDiscovery`: the guide `GET /mcp`, `/.well-known/api-catalog`, the `Link` headers, the API section of `/llms.txt`) is built from `Registry.visible_tools(:public, :all)` on every request, behind ONE predicate (`check/1`: public switch, website gate, at least one public tool). A new page or header of this kind asks it and answers the API's own 404 when it is false. **A document served without a key never names the admin API** (admin path, tool, scope, permission, `Bearer`, "approval"): `PhoenixKitWeb.APIDiscoveryTest` builds its banned list from the admin registry and scans every public body and header, the REST list and the public OpenAPI included, so a new public document goes into that scan. `OutputShape.for_tool/1` therefore gives a public write tool a preview shape with no approval in it.
- ⚠️ **A discovery document never trusts the `Host` header**: `PublicDiscovery.origin/1` takes the request host only when it is well-formed and in `MCP.Origin.known_hosts/1` (the canonical host plus the hosts the `:api_request_context` hook returns), else `MCP.Origin.canonical_origin/0`; the scheme and port are always the canonical origin's, never the request's (a TLS-terminating proxy cannot turn `https` into `http`); never `Routes.base_url/0` (uncached database read). `/llms.txt` and `/.well-known/*` URLs are origin-root strings; the API and the guide go through `Routes.path/1`.
- ⚠️ **`lib/phoenix_kit/api/` names no module** (no shop, no cart): the API is split by audience (`/api/admin/v1`, `/api/public/v1`), a public tool names its anonymous caller's token with `Tool.client_token`, and a module adds error codes with `api_problems/0`. Every deprecated name lives in `PhoenixKit.API.Legacy`, deleted in 3.0.0; `PhoenixKit.API.ModuleNeutralTest` fails on any other line that spells one.
- **Tool authors:** module tests call `PhoenixKit.API.ToolLint.check_tools/1`. A tool prices its own calls with `Tool.cost` (an integer, or `{Module, :function}` over the raw input); `Executor.cost/2` is the only place that reads it.
- **Tests:** `async: false`, `PhoenixKit.API.KeyTestSupport` for fake tool modules, users and keys, one `X-Forwarded-For` address per request. `test/integration/api/public_api_end_to_end_test.exs` is the end-to-end reference.
- **Strings:** the page's gettext entries are added by hand to `default.pot` and the nine `.po` files; `PhoenixKitWeb.Live.Settings.ApiTranslationsTest`, `PhoenixKitWeb.Live.Settings.ApiFlowTranslationsTest`, `PhoenixKitWeb.Live.Settings.ApiGuideTranslationsTest` and `PhoenixKit.API.PublicDiscoveryTranslationsTest` (the public guide) fail when one is missing.
- ⚠️ **The admin guide is generated and holds no key:** its tools come from `Registry.visible_tools(:admin, :all)`, its error table from `Problem.statuses/0` and `Shape.advice/1`, so a new tool or error code needs no edit there. Snippets carry the placeholder `<your key>` (VS Code: an `inputs` prompt); never read a real token into it. The Claude Code line puts `--header` after the URL (the option is variadic). A new admin MCP/REST field that clients must know goes into `Shape.instructions(:admin)` too.
- ⚠️ **A handler called with `ctx.dry_run? == true` writes nothing** and answers `{:preview, preview, fingerprint}`; the executor also calls it that way to build previews and to re-check values at confirmation and approval time. A write in a dry run is a real write. Every write tool needs the tests listed in the guide (dry run writes nothing, fingerprint, stale after a change): a key marked "Needs approval" sends every write through them, dangerous or not.
- ⚠️ **Confirmation and idempotency state lives in the database** (`phoenix_kit_api_confirmations`, `phoenix_kit_api_idempotency`) and every transition is one atomic statement (`UPDATE ... WHERE status = ... `, `INSERT ... ON CONFLICT DO NOTHING`). Do not replace one of them with read-then-write.
- ⚠️ **An answer with a credential is never stored for replay** (`Idempotency.credential_bearing?/1`): name secret fields `*_token` (core's rule is `Auth.credential_name?/1`) or list them in the tool's `credentials`; a write tool whose answer always carries one declares `replay: false` (`PhoenixKit.API.Tool`), or it keeps advertising an `idempotency_key` it cannot honour. Feature-detect `replay:` on a core that may be older: `Code.ensure_loaded?(PhoenixKit.API.ControlFields) and function_exported?(PhoenixKit.API.ControlFields, :replay_tool?, 1)`.
- **The log of the flow follows `LogSafe`:** no confirmation code, idempotency key, tool input or approval preview in a log line.
- **Approvals** run through `PhoenixKit.API.Approvals` only; the approvals page (`PhoenixKitWeb.Live.Approvals`, `/admin/approvals`, a menu entry for `api` holders, shown only while `Approvals.in_use?/0`, whose badge is counted per viewer by `AdminTabs.with_scope_badges/2`; the preview is read by `PhoenixKit.API.Approvals.View`) re-reads the person's rights with `PhoenixKit.API.Access.fresh_scope/1` on every event, as Settings -> API does. A new admin page for the API uses `Access`, not a private copy.
- **New cron workers** go into three places of `lib/phoenix_kit/install/oban_config.ex` (the generated crontab, the manual instructions, `@worker_cron_entries`) and into `config/config.exs`; `oban_cron_backfill_sync_test.exs` fails when they disagree.

## External Module Packages

Writing a standalone `phoenix_kit_*` module (discovery, Tailwind/JS asset pipelines, route modules, publishing routing): read `dev_docs/guides/2026-09-11-external-module-development.md`. Landmines:

- ⚠️ Standalone module packages **must** include `:phoenix_kit` in `extra_applications` — without it `PhoenixKit.ModuleDiscovery` won't find the module and its routes 404.
- ⚠️ **Never register a JS hook from an inline `<script>` in a template** — morphdom does not execute inserted script tags, so an inline hook works on a hard load and silently vanishes on `live_redirect`. Ship hooks via `js_sources/0` instead.

## Public and admin JavaScript

Public pages load `phoenix_kit.js` only; the code of the admin and user-dashboard hooks is in `phoenix_kit_admin.js`, fetched on the first mount of any of them. Guide: `guides/public-and-admin-javascript.md`; design: `dev_docs/plans/2026-10-27-public-admin-js-split.md`. Landmines:

- ⚠️ **A hook goes in `phoenix_kit.js` only if a page outside the admin area and the user dashboard can render it** (a generic form/UI primitive, or something every page needs). Anything else is registered as `window.PhoenixKitAdminHooks.Name` in `phoenix_kit_admin.js` **and** its name added to `ADMIN_HOOKS` in `phoenix_kit.js` — a host spreads `window.PhoenixKitHooks` into `LiveSocket` once, so a hook with no stub there is "unknown" to every host. Three places have to agree — the `ADMIN_HOOKS` array, the keys the admin file defines, and the lists in `test/js/admin_split.test.cjs` — and that test fails when they do not.
- ⚠️ **Never add to `window.PhoenixKitHooks` after the public bundle has run** — the host's copy is already made. Stubs, not late registration.
- Code both files need stays in `phoenix_kit.js` and reaches the admin file through `window.PhoenixKitInternals` (private). The admin file is a plain script and cannot see the public file's closure; a TypeScript `checkJs` pass over each file lists every identifier it uses and does not define (it reports only `define` and `Chart` on the current files).
- A callback that reaches a stubbed hook before the bundle arrives (`updated`, `beforeUpdate`, `disconnected`, `reconnected`) is dropped, and a `push_event` sent in that window is not replayed. A hook that must see the first event belongs in the public file. A listener the admin file installs on `document` outside any hook (the media browser's box select and Shift-click range) starts when the bundle runs, not at page load.
- Chart.js is a vendored library (`vendor_libs/chartjs/`, `ViewerLibraries`), not part of any bundle; `window.PhoenixKitLibraries.chartjs()` is the way to get it. A new core-committed library: replace nothing by hand — the file is the exact upstream one, its checksum enforced by `viewer_libraries_test.exs`.
- Where the vendored files are served from is resolved in the browser in this order: `window.PHOENIX_KIT_LIB_BASE` (the host's word, or `config :phoenix_kit, library_base_url:` — read at compile time, not from `runtime.exs`), next to the tag that loads `phoenix_kit.js` (CDN and path-prefix hosts), then the compiler's default `/assets/vendor/lib/` (`PHOENIX_KIT_LIB_BASE_DEFAULT`). Never derive it from the facts file's address: a host may move, defer or re-minify that file. Production output is minified with the host's esbuild (`ViewerLibraries.maybe_minify/2`); a file written by the compiler must survive being minified again.
- Tests that need the shipped files as a browser runs them use `test/js/support/pk_env.cjs` (one fake page, scripts recorded, `load/1` per file).

## Host hooks and small shared APIs

Pointers; each module's `@doc` is the reference.

- **`PhoenixKit.Cache.remember(cache, key, fun, until: …)`** — get-or-compute with a wall-clock expiry (`{:end_of_day, "Europe/Tallinn"}`); errors are returned, never stored; no single-flight lock, so `fun` must be side-effect free.
- **`PhoenixKitWeb.Plugs.ProbeBlock`** — plug it in the host endpoint before `Plug.Static` to answer scanner probes (`/.env`, `wp-login.php`, `*.php`) with a bare 404; `/.well-known/` always passes; `extra:` / `except:` adjust it.
- **Sitemap** — `config :phoenix_kit, sitemap: [extra_sources: [...]]` adds sources without restating the defaults (`sources:` replaces them). A route with `metadata: %{sitemap: false}` stays out of the sitemap — both router discovery and a static entry resolving to it. `mix phoenix_kit.doctor` warns when robots.txt (a static file or a routed one) has no `Sitemap:` line.
- **Host LiveViews and locale** — `config :phoenix_kit, host_live_view_locale: :leave` stops the kit's on_mount from calling `Gettext.put_locale/1` for a host LiveView (the kit's own views still get it). `host_anonymous_scope: {Mod, :fun, args}` gives the layout the host's scope struct when nobody is signed in — display only, never an access decision.
- **Default-locale redirect** — with `default_language_no_prefix` on, `/<default>/...` redirects to the prefixless URL with a 302; `config :phoenix_kit, :default_locale_redirect, status: 301, max_age: 86_400` makes it permanent for GET/HEAD with `cache-control: private, max-age=…` (see `PhoenixKitWeb.Users.Auth.validate_and_set_locale/2`).
- **Hidden profile sections** — `ProfileSettingsTabs.set_section_hidden(section, hidden?, actor_uuid: …, source: …)` hides a user-settings section site-wide (Settings → Users); pass the actor so the change is attributed like any settings save.
- ⚠️ **A user-supplied URL is fetched only through `Storage.store_from_url/2` / `Storage.RemoteFetch`** (public addresses only, bytes sniffed for the type) — and **`URLSigner.verify_url/2` means "signed by this app", not "this viewer may see it"**. Both: `lib/modules/storage/README.md`.

## URL Prefix and Navigation

**NEVER hardcode PhoenixKit paths.** Use prefix helpers:

| Scenario | Use |
|---|---|
| Template links | `<.pk_link navigate="/path">` or `patch` |
| LV navigate/patch | `Routes.path("/path")` |
| Controller redirect | `Routes.path("/path")` |
| Email URLs | `Routes.url("/path")` |

```elixir
alias PhoenixKit.Utils.Routes
push_navigate(socket, to: Routes.path("/admin"))
url = Routes.url("/users/confirm/#{token}")
```

```heex
<.pk_link navigate="/admin">Admin</.pk_link>
<.pk_link_button navigate="/admin/users" variant="primary">Manage Users</.pk_link_button>
```

#### The language lives in the URL — never in the session

Every localized page is served at a URL that carries its language
(`/et/products`; the default language may be prefixless). The navigation hook
sets Gettext from the URL on every navigation, and the language switcher
rewrites the locale segment. **Session-locale routing is unsupported by
design** — don't add a session fallback, a "session locale mode", or a switcher
option that can emit the same URL for every language. A saved preference may
only pick where a bare landing request redirects. Rationale and a migration
recipe: `guides/locale-routing.md`; the switcher's moduledoc states the same
contract, and in dev it warns when a non-default language renders at a
locale-less URL.

#### The admin segment is renameable — keep writing `/admin`

`config :phoenix_kit, admin_path: "/backoffice"` (compile-time, `config.exs` only) moves the whole admin area; `admin_panel_label` (ten translated presets, or a plain string as untranslated escape hatch) renames the *wording*. **`/admin` stays the canonical name in code** — never write the configured value anywhere:

- emit (canonical → real): `Routes.apply_admin_segment/1`; read (real → canonical): `Routes.canonical_admin_path/1`
- **`Routes.admin_area_path?/1` is the supported way to ask "does this REAL URL land in the admin area?"** — use it instead of `String.contains?(path, "/admin/")`, which gets `/administrators`, a host page at `/shop/admin`, and every renamed host wrong.
- Anything comparing an incoming request path to a path written in code must canonicalise first, or it silently matches nothing (dead tab highlighting).
- Tests that flip `admin_path` must do so in the **sync** phase (`async: false`) — it is cached in `:persistent_term` and a flip in a file body leaks into other files' router compilation.

Full details (inverse-function table, label presets, preset-addition procedure): `dev_docs/guides/2026-09-11-admin-path-and-label.md`.

## Parent Project

### Install Commands

- `mix phoenix_kit.install` — install (use `--help`)
- `mix phoenix_kit.update` — update
- `mix phoenix_kit.status` — installation status
- `mix phoenix_kit.gen.migration` — custom migration

Features: versioned migrations, table prefix, idempotent ops, PostgreSQL validation, mailer templates.

## daisyUI version (host-owned; advisory warnings only)

The daisyUI plugin lives in the **host** app (`assets/vendor/daisyui.js` + `daisyui-theme.js`). Core only declares a designed-for minimum (`PhoenixKit.Install.DaisyUI.minimum_version/0`, currently 5.6.0) and warns below it from `phoenix_kit.install` / `phoenix_kit.update` / `phoenix_kit.doctor` — advisory, never touching host files. **Do NOT re-add `scrollbar-gutter` overrides** in layouts, PkDialog, or modules (every local compensation was deliberately deleted; daisyUI ≥ 5.1 handles the gutter). The rule is about the **root/page** gutter and modal scroll-lock compensation. An **inner** `overflow-auto` region that owns its own scrollbar and changes height on navigation may reserve its gutter with `[scrollbar-gutter:stable]`: `.drawer-side` in `layout_wrapper.ex`, the FolderExplorer tree and the MediaBrowser content column. Leave those in place. Rationale for not vendoring daisyUI in core: `dev_docs/investigations/2026-07-12-daisyui-version-management-investigation.md`.

## TODOs

Workspace-tracked items not ready for inline `# TODO` in `lib/` live in `dev_docs/todos.md` (component test-coverage gaps, signed file-URL hardening).
