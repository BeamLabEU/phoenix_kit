# PR #423 — Add Database-Backed Integration Test Infrastructure

## What

Adds a self-contained integration test suite (274 tests) that runs against a real PostgreSQL database, with no parent app required. Also fixes two production bugs in the publishing module's `db_storage.ex` discovered during test development.

## Why

PhoenixKit previously relied on smoke tests (module loading) for its own test suite and delegated integration testing to parent apps. This meant bugs in core contexts (users, publishing) could only surface downstream. A library-level integration suite catches regressions earlier and provides confidence when refactoring.

## How

### Test Infrastructure

- **Embedded repo** (`PhoenixKit.Test.Repo`) — standalone Ecto repo configured in `config/test.exs` pointing at `phoenix_kit_test` database, using Ecto sandbox for test isolation.
- **Migration wrapper** — single migration file in `test/support/postgres/migrations/` that calls `PhoenixKit.Migrations.up()`, reusing the production migration chain.
- **Graceful degradation** — `test_helper.exs` checks for database existence via `psql -lqt` before attempting connection. When DB is unavailable, integration tests (tagged `:integration` via `DataCase`) are auto-excluded and unit tests still pass.
- **Mix aliases** — `mix test.setup` (create + migrate) and `mix test.reset` (drop + recreate) for database lifecycle.

### Test Coverage

| Area | Tests | Modules Exercised |
|------|-------|-------------------|
| User registration | 30 | `Auth.register_user`, `Roles`, guest users |
| Authentication | 25 | `Auth.get_user_by_email_and_password`, session tokens, fingerprinting |
| Email confirmation | 12 | Confirmation tokens, `confirm_user` |
| Email change | 20 | `apply_user_email`, `update_user_email` |
| Passwords | 20 | Update, admin reset, reset-via-token |
| Profiles | 28 | `update_user_profile`, custom fields, status, Owner protection |
| Roles | 31 | Role CRUD, custom roles, assign/remove, promote/demote |
| Permissions | 46 | Grant/revoke/copy/set, Scope integration, permission matrix |
| DB smoke | 2 | Repo connection, table existence |
| Publishing groups | ~45 | Group CRUD, trash/restore, force-delete cascade |
| Publishing posts | ~50 | Create (timestamp/slug modes), read with params |
| Publishing versions | ~40 | Clone, publish, archive, delete constraints |
| Publishing translations | ~35 | Add/delete languages, translation status propagation |

### Bug Fixes

1. **`next_version_number/1`** — `SELECT max(version_number) ... FOR UPDATE` is invalid PostgreSQL (aggregates can't combine with row-level locks). Fixed by selecting all version numbers with `FOR UPDATE`, then computing max in Elixir.

2. **`copy_contents_to_version/2`** — `DateTime.utc_now()` returns microsecond precision, but `insert_all` into `:utc_datetime` columns (second precision) rejects the mismatch. Fixed with `DateTime.truncate(:second)`.

### Other Changes

- CI now runs `mix test.setup` before `mix test` (with PostgreSQL service already present)
- Fixed `preferred_env` → `preferred_envs` typo in `mix.exs` `cli/0`
- Removed 7 dead `should_regenerate_cache?` tests
- Fixed ETS table-exists crash in `rate_limiter_test.exs`
- Added documentation for `trash_post` bypass pattern and translation naming conventions in publishing README
