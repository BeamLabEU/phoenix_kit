# PR #354 - Add Publishing DB Storage, Public Post Rendering, and i18n Support

**Author:** Max Don (mdon) + Claude Opus 4.6 co-author
**Branch:** dev (merged 2026-02-21)
**Size:** +23,444 / -5,331 (massive PR)

## What

Adds database-backed storage for the Publishing module alongside the existing filesystem storage, wires up public post rendering in DB mode, and adds i18n/gettext support for public-facing pages.

## Key Changes

1. **DB Storage Layer** - New V59 migration (4 tables: groups, posts, versions, contents), Ecto schemas with UUIDv7, DBStorage context, DualWrite sync layer, DBImporter for filesystem-to-DB migration
2. **Public Post Rendering** - DB mode for slug resolution + post fetching in controllers, new PostShow LiveView for post detail pages
3. **i18n Support** - Gettext wrappers for listing page (Read More, dates, month names), locale set from URL language
4. **Pages Module Move** - Moved from `lib/phoenix_kit_web/live/modules/pages/` to `lib/modules/pages/` (self-contained module pattern)
5. **Editor Enhancements** - Version management refactored, DB-aware persistence, settings UI for storage mode
6. **Workers** - MigrateToDatabaseWorker, ValidateMigrationWorker for filesystem-to-DB migration
7. **Tests** - Mapper, Metadata, PublishingAPI, PubSub tests added

## Why

Publishing module was filesystem-only, which doesn't scale for multi-server deployments and makes querying/filtering posts difficult. DB storage enables proper indexing, transactions, and multi-instance support. The dual-write approach allows gradual migration without data loss.

## How

- Oban-style V59 migration creates 4 normalized tables with UUIDv7 PKs and proper FK cascades
- `DBStorage` module provides Ecto-based CRUD, `DualWrite` syncs filesystem ops to DB
- `DBImporter` bulk-imports existing filesystem posts with progress tracking via PubSub
- Public controllers check `Publishing.db_storage?()` to route reads to DB or filesystem
- Pages module restructured to follow the `lib/modules/` convention established by other modules
