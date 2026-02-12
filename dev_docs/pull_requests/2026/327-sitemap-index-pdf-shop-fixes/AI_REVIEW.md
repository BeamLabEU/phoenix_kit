# PR #327: Add v1.7.35 — Sitemap index, PDF, shop fixes

**Author**: @timujinne
**Reviewer**: Claude Opus 4.6
**Status**: ✅ Merged
**Date**: 2026-02-12
**Impact**: +2,693 / -1,388 across 43 files
**CI**: All 6 checks passed (format, credo strict, dialyzer, compilation warnings, tests, deps audit)

## Goal

Rewrite the Sitemap module from a single monolithic `<urlset>` to a proper `<sitemapindex>` architecture with per-module files, add PDF processing support to the Storage module, fix multiple Shop module issues (option pricing, category icons, import filtering, cart specs), and consolidate admin sidebar sessions to eliminate full-page reloads.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/modules/sitemap/generator.ex` | Near-complete rewrite: `generate_all/1`, per-module generation, auto-split at 50k URLs |
| `lib/modules/sitemap/file_storage.ex` | New per-module file operations: `save_module/2`, `load_module/1`, `delete_module/1`, `list_module_files/0` |
| `lib/modules/sitemap/cache.ex` | Widened cache keys from `atom()` to `term()`, added `put_module/2`, `get_module/1` |
| `lib/modules/sitemap/sitemap.ex` | New `flat_mode?/0`, module stats via JSON in Settings, default change for router discovery |
| `lib/modules/sitemap/scheduler_worker.ex` | New `regenerate_module_now/1`, stats persistence after generation |
| `lib/modules/sitemap/sources/source.ex` | New optional callbacks: `sitemap_filename/0`, `sub_sitemaps/1` |
| `lib/modules/sitemap/sources/entities.ex` | Implements `sub_sitemaps/1` for per-entity-type splitting |
| `lib/modules/sitemap/sources/publishing.ex` | Implements `sub_sitemaps/1` for per-blog splitting |
| `lib/modules/sitemap/sources/static.ex` | Login removed, registration made conditional |
| `lib/modules/sitemap/sources/router_discovery.ex` | Expanded exclude patterns |
| `lib/modules/sitemap/sources/shop.ex` | Category filtering by active products, language fallback |
| `lib/modules/sitemap/sources/posts.ex` | Added `sitemap_filename/0` |
| `lib/modules/sitemap/web/controller.ex` | New `module_sitemap/2`, `xsl_index_stylesheet/2`, filename validation |
| `lib/modules/sitemap/web/settings.ex` | Per-module cards, mode toggle, auth page controls |
| `lib/modules/sitemap/web/settings.html.heex` | Complete UI overhaul |
| `lib/modules/storage/services/pdf_processor.ex` | **New file** — Poppler-based PDF processing (143 lines) |
| `lib/modules/storage/services/variant_generator.ex` | PDF variant generation via first-page JPEG rendering |
| `lib/modules/storage/workers/process_file_job.ex` | PDF metadata extraction and variant pipeline |
| `lib/phoenix_kit/system/dependencies.ex` | `check_poppler/0`, `check_poppler_cached/0` |
| `lib/modules/shop/options/options.ex` | Filter options with all-zero modifiers, new `has_nonzero_modifiers?/1` |
| `lib/modules/shop/schemas/category.ex` | Fallback to legacy product `featured_image` URL |
| `lib/modules/shop/shop.ex` | Legacy image support in featured product queries |
| `lib/modules/shop/slug_resolver.ex` | New `normalize_language_public/1` |
| `lib/modules/shop/import/csv_analyzer.ex` | Config filtering at preview stage, `total_skipped` count |
| `lib/modules/shop/import/product_transformer.ex` | Race condition handling for concurrent category creation |
| `lib/modules/shop/web/catalog_product.ex` | Cart saves all specs, category icon mode support |
| `lib/modules/shop/web/catalog_category.ex` | Simplified `build_lang_url/2` |
| `lib/modules/shop/web/product_detail.ex` | Price modifier badges, admin specs display |
| `lib/modules/shop/web/product_form.ex` | Option labels from `_option_slots`, improved `humanize_key/1` |
| `lib/modules/shop/web/imports.ex` | Config selector at configure step, re-analysis on change |
| `lib/phoenix_kit_web/integration.ex` | Session consolidation, sitemap route changes |
| `lib/phoenix_kit_web/live/users/media.html.heex` | PDF badge overlay, `cond`-based thumbnail resolution |
| `lib/phoenix_kit_web/live/users/media_detail.html.heex` | Inline PDF viewer via `<iframe>`, metadata display |
| `lib/phoenix_kit_web/live/users/media_selector.html.heex` | Unified thumbnail resolution for all file types |
| `lib/phoenix_kit_web/live/components/media_selector_modal.html.heex` | Same thumbnail resolution update |
| `priv/static/assets/sitemap-cards.xsl` | **Deleted** — replaced by index-specific stylesheets |
| `priv/static/assets/sitemap-index-table.xsl` | **New file** — table layout for sitemapindex |
| `priv/static/assets/sitemap-index-minimal.xsl` | **New file** — minimal layout for sitemapindex |
| `mix.exs` | Version bump 1.7.34 → 1.7.35 |
| `CHANGELOG.md` | Comprehensive changelog entry |

## Implementation Details

### 1. Sitemap Module — Sitemapindex Architecture

**Architecture shift**: `/sitemap.xml` now returns a `<sitemapindex>` referencing per-module files at `/sitemaps/sitemap-{source}.xml`.

```
/sitemap.xml                              → <sitemapindex>
/sitemaps/sitemap-static.xml              → Static pages
/sitemaps/sitemap-publishing.xml          → Blog posts
/sitemaps/sitemap-publishing-{blog}.xml   → Per-blog (if split enabled)
/sitemaps/sitemap-shop.xml                → Shop products
/sitemaps/sitemap-entities.xml            → Entities
/sitemaps/sitemap-entities-{type}.xml     → Per-entity-type
```

**Dual-mode design** (`generator.ex:86-91`): Branches between "index mode" (per-module files, default) and "flat mode" (single urlset when Router Discovery is enabled). The `Sitemap.flat_mode?()` function delegates to `router_discovery_enabled?()`.

**Source behaviour** (`source.ex`): Two new optional callbacks:
- `sitemap_filename/0` — custom filename per source (default: `"sitemap-#{source_name()}"`)
- `sub_sitemaps/1` — return `[{group_name, entries}]` for per-group splitting

**Auto-split at 50k** (`generator.ex:40`): `@max_urls_per_file 50_000` enforces the sitemaps.org protocol limit with automatic numbered file splitting.

**Stale file cleanup** (`generator.ex:884`): `cleanup_stale_modules/1` removes orphaned files when sources get disabled.

**Route changes** (`integration.ex:5448-5460`): Sitemap routes removed from `:browser` pipeline — correct for public XML endpoints that don't need CSRF/session.

### 2. Storage Module — PDF Support

**New module**: `lib/modules/storage/services/pdf_processor.ex`

| Function | Purpose | Tool |
|----------|---------|------|
| `first_page_to_jpeg/3` | Render first PDF page to JPEG | `pdftoppm` |
| `extract_metadata/1` | Extract page count, author, title | `pdfinfo` |

**Integration pipeline**: PDF upload → metadata extraction → first-page JPEG rendering → variant generation (thumbnails) from JPEG → cleanup intermediate file.

**Dependency detection**: `check_poppler/0` and `check_poppler_cached/0` in `dependencies.ex`, following the existing ImageMagick/FFmpeg pattern with `:persistent_term` caching.

**Graceful degradation**: `extract_metadata/1` returns `{:ok, %{}}` on any failure. `first_page_to_jpeg/3` returns `{:error, :poppler_not_installed}` when tool is missing.

#### Security Analysis — External Process Invocation

**Command injection: NOT a risk.** The code uses `System.cmd/3` with list arguments (`pdf_processor.ex:50`), which calls `execvp()` directly — no shell interpreter is involved. Each argument is passed as a separate element to the OS process. Even if `pdf_path` contained shell metacharacters like `; rm -rf /` or `$(whoami)`, they would be treated as literal filename characters, never interpreted:

```elixir
# What the code does (safe — list args, no shell, uses execvp)
System.cmd("pdftoppm", ["-jpeg", "-f", "1", "-l", "1", "-r", "150", pdf_path, output_prefix])

# What WOULD be dangerous (NOT what the code does — shell-interpolated)
System.cmd("bash", ["-c", "pdftoppm -jpeg -f 1 -l 1 #{pdf_path} #{output_prefix}"])
```

This is the same pattern used throughout PhoenixKit for ImageMagick (`convert`/`identify`) and FFmpeg — it is the industry-standard approach for calling external tools from Elixir.

**Path chain is fully internal.** The user never controls the filesystem path passed to `pdftoppm`. The full chain is:

```
User uploads file
  → Storage saves to bucket (S3/local) with system-generated path
    → ProcessFileJob calls Storage.retrieve_file/1
      → File copied to temp path: /tmp/phoenix_kit_{crypto.strong_rand_bytes(8)}
        → This system-generated temp path is passed to pdftoppm
```

The user's original filename is stored in the database but never used as a filesystem path.

**Remaining hardening opportunities** (DoS protection, not injection):

1. **Add timeout** — Malicious PDFs with recursive structures or enormous page dimensions can cause `pdftoppm` to hang indefinitely. `System.cmd/3` has no built-in timeout. Recommended fix:

   ```elixir
   defp run_with_timeout(cmd, args, timeout \\ 30_000) do
     task = Task.async(fn ->
       System.cmd(cmd, args, stderr_to_stdout: true)
     end)

     case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
       {:ok, result} -> result
       nil -> {:error, :timeout}
     end
   end
   ```

2. **Add file size guard** — Skip variant generation for very large PDFs to prevent excessive memory/disk usage during rendering:

   ```elixir
   @max_pdf_size_for_processing 100 * 1024 * 1024  # 100 MB

   defp process_pdf(file) do
     if file.size && file.size > @max_pdf_size_for_processing do
       Logger.warning("Skipping PDF processing for file_id=#{file.id}, size exceeds limit")
       Storage.update_file(file, %{status: "active"})
       {:ok, []}
     else
       # ... existing processing
     end
   end
   ```

| Aspect | Status | Action |
|--------|--------|--------|
| Command injection | **Safe** — `System.cmd/3` uses `execvp`, no shell | None needed |
| Path control | **Safe** — all paths are system-generated temp paths | None needed |
| Timeout protection | **Missing** — `pdftoppm` can hang on crafted PDFs | Add `Task.yield/2` wrapper |
| File size guard | **Missing** — no limit on PDF size before processing | Add size check |
| Consistency | **Good** — same pattern as existing ImageMagick/FFmpeg | None needed |

### 3. Shop Module Fixes

**Option price display** (`options.ex`): New `has_nonzero_modifiers?/1` filters out option groups where ALL price modifiers are zero, using `Decimal.compare/2`. Prevents displaying meaningless "+$0.00" badges.

**Category icon fallback** (`category.ex`): Priority 3 fallback to legacy `featured_image` URL (plain string) when neither `image_id` nor `featured_image_id` is available.

**Import config filtering** (`csv_analyzer.ex`): Filters applied at CSV preview stage (not post-import). Shows `total_skipped` count. Race condition handling in `create_new_category/2` with unique constraint retry.

**Cart spec saving** (`catalog_product.ex`): Cart now saves ALL selected specs (not just price-affecting), so non-price options like Color are preserved.

### 4. Admin Session Consolidation

**Before**: Three separate `live_session` blocks for admin, Comments, and Sync modules → full-page reload when navigating between them.

**After**: All routes in single admin `live_session` → client-side LiveView navigation throughout.

### 5. Media UI — PDF Support

- **Thumbnail resolution**: All media templates updated from `if/else` to `cond` with three branches (image/video/other), enabling PDF thumbnail display
- **Inline PDF viewer**: `<iframe>` with fallback download link in `media_detail.html.heex`
- **PDF badge**: Red "PDF" overlay on grid thumbnails
- **Metadata display**: Page count, author, title in file details panel

## Review Assessment

### Positives

1. **Clean sitemapindex architecture** — Proper per-module file splitting follows sitemaps.org best practices. The `Source` behaviour with optional callbacks is extensible without modification. Backward compatibility preserved through `generate_xml/1` wrapper.

2. **Robust error handling** — `rescue` blocks in all external tool calls, `safe_collect/2` wraps source collection, Logger warnings for failures, graceful degradation throughout.

3. **Security-conscious implementation** — Filename validation regex (`^[a-z0-9-]+$`) prevents path traversal in sitemap controller. `System.cmd/3` uses list arguments (not shell-interpolated) for PDF processing. Sitemap routes correctly removed from browser pipeline.

4. **Good cleanup patterns** — `cleanup_stale_modules/1` removes orphaned files. Flat mode cleans up per-module files. `delete_all_modules/0` on cache invalidation.

5. **Race condition handling** — Category creation in `product_transformer.ex` catches unique constraint violations and falls back to fetching the existing record. Proper pattern for concurrent imports.

6. **Parallel multilingual collection** — `Task.async_stream` in `generator.ex:449` with `max_concurrency: System.schedulers_online() * 2` for language-specific entry collection.

7. **PDF processor design** — Clean module with proper `@field_mapping`, `Integer.parse/1` for page counts, `ErlangError` rescue for missing tools, temp file cleanup.

### Concerns

1. **Breaking default change** — `@default_router_discovery` changed from `true` to `false`. Existing installations that never explicitly set this setting will silently switch from flat mode to index mode, changing their sitemap URL structure. Should be documented in upgrade notes.

   **Risk**: Medium — affects SEO if search engines had cached the old format.

2. **Per-module regeneration is misleading** — `regenerate_module_now/1` creates an Oban job with a `source` argument, but `do_perform_regeneration/1` always calls `regenerate_sitemap/1` (full regeneration). The UI already exposes per-module regeneration buttons that may set incorrect performance expectations.

   **Impact**: Low — correctness is fine (full regen is safe), but wastes work for single-module updates.

3. **On-demand generation returns 404** — `generate_module_on_demand/2` in the controller triggers full generation but returns 404 to the client even if the requested file was successfully generated. Client must retry.

   **Suggestion**: Re-attempt to serve the file after generation succeeds.

4. **Shop source double-scan** — `active_product_category_ids/0` loads all active products into memory to build a `MapSet` of category IDs. For large shops, a targeted SQL query would be significantly more efficient:

   ```elixir
   from(p in Product, where: p.status == "active", select: p.category_id, distinct: true)
   |> repo().all() |> MapSet.new()
   ```

5. **No timeout on external PDF commands** — `pdftoppm` and `pdfinfo` called via `System.cmd/3` without timeouts. Note: the command invocation itself is secure (list args via `execvp`, no shell — see Security Analysis above), but crafted PDFs could cause `pdftoppm` to hang or consume excessive memory. Recommend wrapping in a `Task` with `Task.yield/2` timeout and adding a file size guard (see code examples in Security Analysis section).

6. **Session consolidation tradeoff** — Comments routes previously had explicit `{:phoenix_kit_ensure_module_access, "comments"}` on_mount. Now they share the general admin session's `:phoenix_kit_ensure_admin` check. Custom roles with "comments" permission but not other admin access may experience different behavior. Acceptable since they're still behind `:phoenix_kit_admin_only` pipe_through.

7. **`length(entries) > @max_urls_per_file` double traversal** — `generator.ex:212` iterates the full list to check length before chunking. For lists near 50k entries, this traverses twice. Could use `Enum.count_until/2` or proceed with chunking unconditionally.

8. **`normalize_language_public/1` naming** — Exposing a private function via a `_public` suffix wrapper is unconventional. Consider making `normalize_language/1` public directly, or renaming to a more idiomatic name.

### Minor Observations

- Thumbnail URL resolution logic is duplicated across 3 templates (`media_selector_modal`, `media_selector`, `media.html.heex`) — candidate for extraction into a component
- The `flat_mode?()` coupling to Router Discovery means the two concepts cannot evolve independently
- Module stats stored as JSON in Settings with explicit "no cache" comment suggests an underlying issue with JSON setting caching
- `safe_parse_decimal/1` in `options.ex` only handles `{decimal, ""}` exact matches — strings with trailing whitespace would bypass zero detection

### Verdict

**Approved.** The sitemapindex architecture is a significant and correct improvement that follows protocol best practices. PDF support is well-integrated with proper error handling and graceful degradation. Shop fixes address real UX issues (zero-modifier display, cart spec loss, legacy image fallback). The session consolidation eliminates annoying full-page reloads. Concerns raised are minor and don't block merge. The breaking default change (router discovery) should be noted in upgrade documentation.

## Testing

- [x] `mix format` passed
- [x] `mix credo --strict` passed (no issues)
- [x] `mix dialyzer` passed
- [x] Compilation with warnings as errors passed
- [x] Dependency audit passed
- [x] Test suite passed
- [x] Pre-commit hooks passed

## Migration Notes

**Router Discovery default change**: Sites upgrading to v1.7.35 that had not explicitly set the Router Discovery setting will switch from flat sitemap mode to sitemapindex mode. To preserve the old behavior:

```elixir
# In admin Settings UI, or programmatically:
PhoenixKit.Modules.Sitemap.update_setting("router_discovery_enabled", true)
```

**PDF processing**: Requires `poppler-utils` for thumbnail generation (optional, gracefully degrades):

```bash
# Debian/Ubuntu
apt-get install poppler-utils

# macOS
brew install poppler
```

## Related

- **Version**: 1.7.35
- **Commits**: 17 commits (including merges)
- **URL**: https://github.com/BeamLabEU/phoenix_kit/pull/327
- **New files**: `pdf_processor.ex`, `sitemap-index-table.xsl`, `sitemap-index-minimal.xsl`
- **Deleted files**: `sitemap-cards.xsl`
