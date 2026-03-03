# PR #385 — Remove JsIntegration, DBImporter, and migration workers; refine publishing/sync modules

- **Author**: Max Don (@mdon)
- **Merged**: 2026-03-03
- **Merged by**: Dmitri Don (@ddon)
- **Base**: `dev`
- **Lines**: +218 / -2,099 (net -1,881)

## Summary

Large cleanup PR that removes three legacy modules and their associated UI/test/PubSub infrastructure, while also refining the sync module to use UUIDs consistently and relocating the post title field in the editor layout.

## What changed

### Removed modules (dead code elimination)

1. **`PhoenixKit.Install.JsIntegration`** (266 lines) — Automatic JS integration for install/update tasks. Removed from both `phoenix_kit.install` and `phoenix_kit.update` pipelines.

2. **`PhoenixKit.Modules.Publishing.DBImporter`** (433 lines) — Synchronous filesystem-to-database importer. All UI buttons ("Import to DB", "Migrate to Database", "Migrate All to Database") removed from index, listing, and settings pages.

3. **`PhoenixKit.Modules.Publishing.Workers.MigrateToDatabaseWorker`** (418 lines) — Async Oban worker for FS→DB migration. Removed along with its PubSub broadcast handlers.

4. **`PhoenixKit.Modules.Publishing.Workers.ValidateMigrationWorker`** (181 lines) — Oban worker that validated FS vs DB consistency post-migration.

### Publishing PubSub cleanup

Removed 6 broadcast functions from `Publishing.PubSub`:
- `broadcast_db_import_started/2`
- `broadcast_db_import_completed/3`
- `broadcast_db_migration_started/1`
- `broadcast_db_migration_group_progress/3`
- `broadcast_db_migration_completed/1`
- All corresponding `handle_info` clauses in Index, Listing, and Settings LiveViews.

### Publishing UI changes

- **Index page**: Removed conditional "Migrate All to Database" button, always shows "Create Group" instead. Empty state simplified (no FS group count messaging).
- **Listing page**: Removed `fs_post_count` assign, "Import to DB" button, and FS-aware empty state. Removed `refresh_groups/1` and `db_import_in_progress` assign.
- **Settings page**: Removed per-group "Migrate" buttons, `fs_group_count` assign, and "Migrate to Database Storage" alert banner.
- **Editor**: Title field moved from the left sidebar metadata column into the right content column, above the markdown editor. Styled larger (`text-2xl font-semibold`). Save button no longer conditionally disabled based on `has_pending_changes` / `is_new_post` / `is_new_translation` — simplified to just `readonly? || is_autosaving`. Removed the `handle_event("save", ...)` clause for `has_pending_changes == false`.
- **Post show**: Layout wrapper changed from `PhoenixKitWeb.Layouts.dashboard` to `PhoenixKitWeb.Components.LayoutWrapper.app_layout`.
- **Listing cache**: Added `enrich_with_db_uuids/2` to batch-fetch DB UUIDs for FS posts, enabling UUID-based links in admin listing even in filesystem mode. `serialize_post` and `normalize_post` now include `uuid` field.

### Sync module refinements (id → uuid)

- **`connection_notifier.ex`**: `remote_connection_id` → `remote_connection_uuid` throughout (type, struct fields, response parsing, metadata storage). Backwards-compatible: parses `connection_uuid || connection_id` from remote response.
- **`transfers.ex`**: Removed `|| opts[:connection_id]` fallback in `list_transfers/1`, `count_transfers/1`, `table_stats/1`.
- **`api_controller.ex`**: Response key `connection_id` → `connection_uuid`.
- **`receiver.ex`**: `get_record_id/1` now prefers `uuid` key, falls back to `id`.
- **`import_worker.ex`**: `extract_record_pk/1` now prefers `uuid`, log message says "uuid:" instead of "id:".
- **Sync README**: Updated code examples to use `_uuid` suffixed parameters.

### Update task

- Added `alias PhoenixKit.Migrations.Postgres, as: MigrationsPostgres` to satisfy Credo nested module alias rule.
- Removed `update_js_integration/0` private function and its call from the update pipeline.
- Removed `JsIntegration` from alias list.

### Tests

- Removed `DBImporter` module existence test from `publishing_api_test.exs`.
- Removed `MigrateToDatabaseWorker` module existence test.
- Removed all 5 DB import PubSub broadcast function tests from `pubsub_test.exs`.

## Why

The FS→DB migration path (DBImporter, MigrateToDatabaseWorker, ValidateMigrationWorker) was a transitional feature for existing installs upgrading to database-backed publishing. That migration path is no longer needed — new installs start with DB storage directly, and existing installs have already migrated. Similarly, JsIntegration handled automatic `app.js` patching that is no longer required.

The sync module was still referencing integer `id` fields in several places despite the project-wide move to UUID primary keys.
