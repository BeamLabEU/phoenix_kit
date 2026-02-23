# PR #354 Follow-Up Items

**Created:** 2026-02-22
**Status:** Critical issues FIXED, remaining items are high/medium priority

## Fixed (2026-02-22)

### 1. Pages SimpleRenderer Reference - FALSE POSITIVE
`PhoenixKit.Modules.Pages.SimpleRenderer` exists and is correctly aliased. No fix needed.

### 2. Pages Component Coupling - FIXED
Moved all 8 content components (Image, Video, EntityForm, Page, Hero, Headline,
Subheadline, CTA) from `lib/modules/publishing/components/` to
`lib/modules/shared/components/` with `PhoenixKit.Modules.Shared.Components.*` namespace.
Publishing components kept as thin delegates for backward compatibility.
Updated all references in Pages.Renderer, Pages.PageBuilder.Renderer,
Publishing.Renderer, Publishing.PageBuilder.Renderer, and guides/integration.md.

### 3. PublishingContent Test - FIXED
Test asserted `title` is required but schema defaults it to `""` via `default_if_nil`.
Updated test to match implementation.

### 4. UtilsDate Violations - FIXED
Replaced bare `DateTime.utc_now()` with `UtilsDate.utc_now()` in all file-write contexts:
- `lib/modules/pages/metadata.ex:135` - default_metadata()
- `lib/modules/pages/storage.ex` - 6 locations: create_post, create_post_slug_mode,
  create_blank_version, create_version_from_source, create_new_version,
  do_migrate_post_to_versioned
- `lib/modules/publishing/metadata.ex:135` - default_metadata() (same issue)
Added `alias PhoenixKit.Utils.Date, as: UtilsDate` to all three files.

## Remaining Items

## Transaction Safety Fixes

### 1. Publish Version Transaction
```
File: lib/modules/publishing/publishing.ex:1441-1471
Issue: Multi-record update without transaction
Action: Wrap in Ecto.Multi or Repo.transaction
```

### 2. TOCTOU Upsert Race
```
Files: db_storage.ex:62-69, db_storage.ex:471-479, db_importer.ex:252-271
Issue: Check-then-act without atomicity
Action: Use Repo.insert with on_conflict option
```

### 3. DualWrite Content Sync
```
File: lib/modules/publishing/dual_write.ex:99-154
Issue: Post + version + content created without transaction
Action: Wrap in Repo.transaction
```

### 4. Status Propagation Race
```
File: lib/modules/publishing/publishing.ex:1301-1337
Issue: Non-transactional status update across multiple content records
Action: Wrap propagation in transaction
```

## Auth & Security

### 5. PostShow Auth Scope
```
File: lib/modules/publishing/web/post_show.ex
Issue: No authorization scope validation
Action: Add scope check in mount/handle_params
```

## Tech Debt

### 6. ListingCache Duplication (~1,465 lines)
```
Files: publishing/listing_cache.ex, pages/listing_cache.ex
Action: Extract ListingCacheBase, parameterize by config
```

### 7. N+1 Queries
```
File: lib/modules/publishing/db_storage.ex:524-544
Action: Preload versions and contents in initial query
```

### 8. Pages PubSub
```
Action: Create Pages.PubSub for feature parity with Publishing
```
