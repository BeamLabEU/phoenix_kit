# Claude Review — PR #442: Extract Posts Module

**Verdict:** Approve — clean extraction following established pattern

## Extraction Completeness

| Integration Point | Status | Notes |
|------------------|--------|-------|
| Source files (32 files, ~8K lines) | Removed | Entire `lib/modules/posts/` deleted |
| Route definitions (8 admin routes) | Removed | 10 lines from `integration.ex` |
| Auth permission mappings (6 entries) | Removed | LiveView-to-permission map in `auth.ex` |
| Comment handler default | Updated | Conditional `PhoenixKitPosts` in `comments.ex` |
| Scheduled jobs worker | Updated | Catch-up logic guarded by `Code.ensure_loaded?` |
| Sitemap posts source | Updated | Optional dispatch via `Module.concat/1` |
| Sitemap settings | Updated | Posts enabled check uses `PhoenixKitPosts` |
| Config | Updated | `comment_resource_handlers` points to `PhoenixKitPosts` |
| Dialyzer | Updated | `:unknown_function` ignores added |
| Module registry | Updated | Moved from internal to external packages |
| Tests | Updated | Module count and posts-specific assertions removed |

## What's Good

1. **Follows the Sync extraction pattern exactly.** Same approach as PR #439 — removed from `internal_modules/0`, added to `known_external_packages/0`, beam scanning auto-discovers when installed.

2. **Optional dispatch is well-guarded.** Every call to `PhoenixKitPosts` is wrapped in `Code.ensure_loaded?/1` checks. Core PhoenixKit compiles and runs cleanly without the package.

3. **Comments module gracefully degrades.** `default_resource_handlers/0` builds the handler map conditionally — when Posts isn't installed, the `"post"` handler simply isn't registered.

4. **Scheduled jobs worker refactored cleanly.** Extracting `catchup_scheduled_posts/0` and `catchup_scheduled_broadcasts/0` into separate functions improved readability while adding the optional guard.

## Observations

### Sitemap files updated but Sitemap is also pending extraction

The `sitemap/sources/posts.ex` and `sitemap/web/settings.ex` files were updated to reference `PhoenixKitPosts`. Since the Sitemap module will also be extracted from core, these changes will leave with it. The changes are correct and harmless — they ensure the Sitemap module works properly with the external Posts package both now and after its own extraction.

### Module.concat discovery path

It took 4 commits to land on `Module.concat([PhoenixKitPosts])` as the dispatch pattern. This avoids both compile-time warnings (direct module reference) and Credo warnings (`apply/3`). Worth noting as the established pattern for future module extractions.

### Config still references PhoenixKitPosts

`config/config.exs` has `"post" => PhoenixKitPosts` in `comment_resource_handlers`. This is PhoenixKit's own dev config so it's fine, but parent apps without `phoenix_kit_posts` installed will get a warning if they copy this config. The runtime guard in `comments.ex` handles this gracefully regardless.

## Testing Notes

- CI passes: all 6 checks green (formatting, credo, dialyzer, compilation, audit, tests)
- Core compiles with zero warnings about missing Posts modules
- Admin Modules page should show "Not Installed" card for Posts when `phoenix_kit_posts` dep is absent
