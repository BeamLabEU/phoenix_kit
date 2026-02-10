# PR #316: Add markdown rendering and bucket access types

**Author**: @timujinne
**Reviewer**: @claude
**Status**: Merged
**Commit**: `31036862` (merge)
**Date**: 2026-02-04

## Goal

Add markdown rendering capability for product descriptions in the Shop module, implement smart file serving based on bucket access types, and add pagination to public shop catalog pages.

## What Was Changed

### Summary

| Area | Changes |
|------|---------|
| Markdown Component | New component with XSS sanitization |
| Storage Module | V50 migration + smart file serving |
| Shop Module | Pagination for catalog pages |
| Bug Fixes | consent.js path, Add to Cart crash |
| Cleanup | Removed 5 completed plan files |

### Files Modified (22 files)

| File | Additions | Deletions | Description |
|------|-----------|-----------|-------------|
| `lib/phoenix_kit_web/components/core/markdown.ex` | 94 | 0 | New markdown rendering component |
| `lib/phoenix_kit/migrations/postgres/v50.ex` | 40 | 0 | Add access_type to buckets |
| `lib/phoenix_kit/migrations/postgres.ex` | 9 | 2 | Register V50 migration |
| `lib/phoenix_kit_web/controllers/file_controller.ex` | 80 | 39 | Smart file serving logic |
| `lib/modules/storage/services/manager.ex` | 84 | 0 | Add `get_file_access/1` |
| `lib/modules/storage/schemas/bucket.ex` | 11 | 0 | Add access_type field |
| `lib/modules/storage/web/bucket_form.html.heex` | 29 | 0 | UI for access_type |
| `lib/modules/shop/web/shop_catalog.ex` | 127 | 2 | Pagination support |
| `lib/modules/shop/web/catalog_category.ex` | 137 | 1 | Pagination for category pages |
| `lib/modules/shop/web/catalog_product.ex` | 7 | 8 | Markdown rendering |
| `lib/modules/shop/web/product_detail.ex` | 6 | 1 | Markdown rendering |
| `lib/modules/shop/shop.ex` | 3 | 1 | Support for pagination |
| `lib/phoenix_kit_web.ex` | 1 | 0 | Import markdown component |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | 1 | 1 | Fix consent.js path |
| `.gitignore` | 1 | 0 | Add plans/ directory |
| `CHANGELOG.md` | 48 | 0 | Document changes |
| `mix.exs` | 3 | 2 | Version updates |

### Deleted Files (5 plan files, -2038 lines)

- `plans/shop-localized-fields.md` (764 lines)
- `plans/shop-translations.md` (471 lines)
- `plans/shop-translations-comparison.md` (246 lines)
- `plans/variant-image-binding.md` (191 lines)
- `plans/variant-image-mapping.md` (366 lines)

## Implementation Details

### 1. Markdown Component

New component at `lib/phoenix_kit_web/components/core/markdown.ex`:

```elixir
# Usage
<.markdown content={@description} />           # Full rendering with sanitization
<.markdown content={@description} compact />   # Compact mode for previews
<.markdown content={@description} sanitize={false} />  # Trusted content
```

**Features:**
- GFM (GitHub Flavored Markdown) via Earmark
- Smart typography (smartypants)
- Code block syntax highlighting classes
- XSS sanitization using `HtmlSanitizer` (enabled by default)
- Graceful error handling with HTML-escaped fallback

### 2. Bucket Access Types (V50 Migration)

Adds `access_type` VARCHAR column to `phoenix_kit_buckets`:

| Access Type | Behavior |
|-------------|----------|
| `public` (default) | Redirect to CDN URL |
| `private` | Proxy through server |
| `signed` | Presigned URLs (future) |

### 3. Smart File Serving

New `get_file_access/1` function in Storage Manager:

```elixir
# Returns one of:
{:local, path}      # Local file - serve directly
{:redirect, url}    # Public bucket - redirect to CDN
{:proxy, file_name} # Private bucket - proxy through server
```

**FileController changes:**
- Local files: `send_file/3` directly (no temp file copying)
- Public cloud: `redirect(conn, external: url)`
- Private cloud: Download to temp, serve, cleanup
- Retry logic (5 attempts) for bucket cache race conditions

### 4. Shop Catalog Pagination

**URL-based pagination** for SEO:
- `?page=N` parameter support
- Cumulative loading (page N shows products 1..N)
- `handle_params/3` for browser navigation
- "Show More" button with `push_patch`

```elixir
# mount/3 and handle_params/3 support
per_page = 24
{products, total} = Shop.list_products_with_count(
  status: "active",
  page: 1,
  per_page: page * per_page,
  exclude_hidden_categories: true
)
```

## Bug Fixes

### Add to Cart Crash
- Fixed option validation using `get_selectable_specs_for_product`
- Handle 3-tuple error returns to prevent `CaseClauseError`
- Removed debug logging from `select_spec` handler

### consent.js Path
- Fixed URL path in layout wrapper

## Code Quality Assessment

### Strengths

1. **Clean architecture**: Bucket access logic well-separated with clear return types
2. **Security**: Markdown component sanitizes by default, opt-out for trusted content
3. **Error handling**: Retry logic for race conditions, graceful markdown fallback
4. **SEO-friendly**: URL-based pagination supports direct linking and crawling

### Minor Observations

1. `proxy_remote_file/4` deletes temp file after `serve_file` - works because response already sent, but could use `register_before_send` for clarity
2. Retry logging at `:debug` level - consider `:info` for production visibility

## Testing

- [x] Pre-commit checks passed (`mix format`, `mix credo --strict`)
- [x] Compilation successful
- [x] Markdown rendering works in product descriptions
- [x] Bucket access types function correctly (public/private)
- [x] Pagination works with URL parameters

## Commits (11)

1. `3701bf05` - Remove completed and duplicate shop plan files
2. `6ba63575` - Add plans/ to .gitignore
3. `44870b59` - Merge remote-tracking branch 'upstream/dev'
4. `a5dfece7` - Merge remote-tracking branch 'upstream/dev'
5. `a24b79d7` - Fix Add to Cart crash caused by discovered option validation
6. `d1ea13df` - Add bucket access_type for smart file serving (V50)
7. `a35315e5` - Add pagination to public shop catalog pages
8. `0faf6018` - Merge remote-tracking branch 'upstream/dev'
9. `066e658f` - Merge remote-tracking branch 'upstream/dev'
10. `0d0756a8` - Merge remote-tracking branch 'upstream/dev'
11. `818c4e54` - Add markdown rendering for product descriptions

## Related

- Storage Module: `lib/modules/storage/`
- Shop Module: `lib/modules/shop/`
- Markdown Component: `lib/phoenix_kit_web/components/core/markdown.ex`
- V50 Migration: `lib/phoenix_kit/migrations/postgres/v50.ex`
