# PR #407 Review: Module Access Guards and Legal Module Fixes

## Overview
PR #407 introduces module access guards, fixes Legal module integration issues with DB-backed Publishing, and includes various improvements across the codebase.

## Key Changes

### 1. Module Access Guards
**Files Modified**: 
- `lib/modules/ai/web/endpoints.ex`
- `lib/modules/entities/web/entities.ex`
- `lib/modules/entities/web/entities_settings.ex`
- `lib/modules/publishing/web/index.ex`
- `lib/modules/publishing/web/settings.ex`
- `lib/modules/sitemap/web/settings.ex`

**Changes**:
- Added `enabled?()` checks in `mount/3` functions
- Disabled modules now block LiveView mounting
- Action buttons hidden for disabled modules
- Removed duplicate enable/disable toggles from 7 module settings pages

**Pattern Applied**:
```elixir
if Module.enabled?() do
  # Normal initialization
  {:ok, socket}
else
  {:ok, socket}
end
```

### 2. Legal Module Fixes
**Files Modified**:
- `lib/modules/legal/legal.ex`
- `lib/modules/legal/web/settings.ex`

**Changes**:
- Fixed DB-backed Publishing integration:
  - Changed `post.path` → `post.uuid`
  - Changed `updated_at` → `published_at`
- Added error logging instead of silent rescue:
  ```elixir
  rescue
    e ->
      Logger.error("Legal.list_generated_pages failed: #{inspect(e)}")
      []
  ```

### 3. Sitemap Improvements
**Files Modified**:
- `lib/modules/sitemap/sources/router_discovery.ex`

**Changes**:
- Added module route prefix filtering
- Disabled module routes excluded from sitemap
- New `@module_route_prefixes` mapping:
  ```elixir
  @module_route_prefixes %{
    "/shop" => {PhoenixKit.Modules.Shop, :enabled?},
    "/newsletters" => {PhoenixKit.Modules.Newsletters, :enabled?},
    "/publishing" => {PhoenixKit.Modules.Publishing, :enabled?},
    "/connections" => {PhoenixKit.Modules.Connections, :enabled?}
  }
  ```

### 4. Other Fixes

**DB.Listener** (`lib/modules/db/listener.ex`):
- Added `{:eventually, _ref}` case for auto_reconnect

**Flash Component** (`lib/phoenix_kit_web/components/core/flash.ex`):
- Error flashes now auto-dismiss after 8 seconds

**Publishing.DBStorage** (`lib/modules/publishing/db_storage.ex`):
- Simplified primary_language lookup

## Files Changed Summary
- 28 files changed
- 427 insertions(+)
- 671 deletions(-)

## Quality Assessment
- Changes are focused and well-documented in CHANGELOG
- Module access guard pattern consistently applied
- Error handling improved (Legal module logging)
- Code cleanup (removed duplicate toggles)
- No breaking changes to public APIs

## Recommendations
✅ **Approve** - Changes are well-structured, address specific issues, and maintain backward compatibility.

## Testing Notes
- Module access guards should be tested with both enabled and disabled states
- Legal module integration with DB-backed Publishing needs verification
- Sitemap route filtering should be validated with disabled modules
