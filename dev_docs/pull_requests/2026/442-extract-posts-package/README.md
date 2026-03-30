# PR #442 — Extract Posts module to separate phoenix_kit_posts package

**Author:** Alex (alexdont)
**Base:** dev
**Date:** 2026-03-21
**Impact:** -8,043 lines / +64 lines (net: -7,979)

## Summary

Removes the built-in Posts module (~8,000 lines) from PhoenixKit and registers it as an external package (`{:phoenix_kit_posts, "~> 0.1"}`). Follows the same extraction pattern established by PR #439 (Sync extraction).

## What was removed

- **32 source files** in `lib/modules/posts/` — all Posts context, schemas, LiveViews, workers, handlers
- **Post schemas**: Post, PostLike, PostDislike, PostGroup, PostGroupAssignment, PostTag, PostTagAssignment, PostMedia, PostMention, PostComment, CommentLike, CommentDislike, PostView
- **LiveView routes** (8 endpoints) — admin posts list, edit, details, groups, group edit, settings
- **Auth permission mappings** — 6 LiveView-to-permission entries
- **ScheduledPostHandler** and **PublishScheduledPostsJob** worker
- **Posts web SPEC.md** design document

## What was kept

- **Migration files** — historical records for version upgrades
- **`posts` permission key** — seeded by existing migrations, reused by external package
- **Sitemap Posts source** (`sitemap/sources/posts.ex`) — stays with Sitemap module, updated to use optional `PhoenixKitPosts` dispatch

## Key changes

| File | Change |
|------|--------|
| `module_registry.ex` | Removed `Posts` from `internal_modules/0`, added `PhoenixKitPosts` to `known_external_packages/0` |
| `comments.ex` | `default_resource_handlers/0` conditionally includes `PhoenixKitPosts` via `Code.ensure_loaded?/1` |
| `process_scheduled_jobs_worker.ex` | Extracted `catchup_scheduled_posts/0` helper; guarded with `Code.ensure_loaded?(PhoenixKitPosts)` |
| `sitemap/sources/posts.ex` | Replaced `Posts.list_public_posts` with optional `PhoenixKitPosts` dispatch via `Module.concat/1` |
| `sitemap/web/settings.ex` | Posts enabled check uses `PhoenixKitPosts` instead of `PhoenixKit.Modules.Posts` |
| `integration.ex` | Removed 8 hardcoded posts admin routes (10 lines) |
| `auth.ex` | Removed 6 LiveView permission mappings |
| `.dialyzer_ignore.exs` | Added `:unknown_function` ignores for optional module calls |
| `config.exs` | Comment handler reference updated to `PhoenixKitPosts` |
| Tests | Removed Posts from module list assertion, removed posts-specific test |

## Optional module dispatch pattern

The PR went through 4 commits to find the right pattern for calling an optional external module:

1. Direct `PhoenixKitPosts.function()` — compile warnings
2. `apply(PhoenixKitPosts, :function, [args])` — Credo warnings
3. `Module.concat([PhoenixKitPosts]).function()` — no warnings from compiler or Credo

All calls guarded by `Code.ensure_loaded?(PhoenixKitPosts)` at runtime.

## Related PRs

- Previous extraction: [#439](/dev_docs/pull_requests/2026/439-extract-sync-package) — Sync module extraction (established the pattern)
