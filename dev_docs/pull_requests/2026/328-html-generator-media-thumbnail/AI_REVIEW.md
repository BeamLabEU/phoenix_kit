# PR #328: Extract HtmlGenerator and MediaThumbnail

**Author**: @timujinne
**Reviewer**: Claude Opus 4.6
**Status**: Merged
**Date**: 2026-02-12
**Impact**: +468 / -366 across 9 files
**Commits**: 3

## Goal

Extract HTML sitemap rendering from the monolithic `Generator` module into a dedicated `HtmlGenerator`, extract a reusable `MediaThumbnail` core component from duplicated thumbnail URL logic in 3 templates, and fix localized field validation ordering in Shop forms.

## Commits

| Hash | Description |
|------|-------------|
| `16dc0521` | Extract HTML renderer from sitemap Generator into HtmlGenerator module |
| `84131f23` | Extract MediaThumbnail component from duplicated template logic |
| `9b6220cc` | Fix localized field validation in Shop forms |

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/modules/sitemap/generator.ex` | Removed ~280 lines of HTML generation, delegates to `HtmlGenerator` |
| `lib/modules/sitemap/html_generator.ex` | **New file** — 304 lines, 3 render styles, shared `render_link/1` |
| `lib/phoenix_kit_web/components/core/media_thumbnail.ex` | **New file** — 79 lines, `<.thumbnail_url>` component + `resolve_url/2` |
| `lib/phoenix_kit_web.ex` | Added `core_components()` to `live_component` macro, added `MediaThumbnail` import |
| `lib/phoenix_kit_web/live/users/media.html.heex` | Replaced inline `cond` with `<.thumbnail_url size={:medium}>` |
| `lib/phoenix_kit_web/live/users/media_selector.html.heex` | Replaced inline `cond` with `<.thumbnail_url>` |
| `lib/phoenix_kit_web/live/components/media_selector_modal.html.heex` | Replaced inline `cond` with `<.thumbnail_url>` |
| `lib/modules/shop/web/category_form.ex` | Moved `build_localized_params` before changeset in validate handler |
| `lib/modules/shop/web/product_form.ex` | Moved `build_localized_params` + `merge_translation_params` before changeset |

## Implementation Details

### 1. Sitemap HtmlGenerator Extraction

**Before:** `generator.ex` contained ~280 lines of private HTML rendering functions (`generate_hierarchical_html/2`, `generate_grouped_html/2`, `generate_flat_html/2`, `html_head/1`, `generate_and_cache_html/3`).

**After:** New `PhoenixKit.Modules.Sitemap.HtmlGenerator` module with:
- `generate/2` public entry point accepting `(opts, entries)`
- `render_hierarchical/2`, `render_grouped/2`, `render_flat/2` private renderers
- Shared `render_link/1` replacing 3 identical inline link-building patterns
- `@valid_styles` module attribute replacing scattered string literals
- `do_generate/4` handles caching and style dispatch

**Delegation in generator.ex:**
```elixir
def generate_html(opts \\ []) do
  entries = collect_all_entries(opts)
  HtmlGenerator.generate(opts, entries)
end
```

**Bug fix:** The old `generate_and_cache_html/3` called `FileStorage.save("html_#{style}", html)`. The deprecated `FileStorage.save/2` ignores its first argument and writes to `priv/static/sitemap.xml` — meaning every HTML sitemap generation **overwrote the XML sitemap with HTML content**. The new `HtmlGenerator` correctly caches to ETS only and never writes HTML to disk.

### 2. MediaThumbnail Component

**Before:** Three templates contained identical `cond` blocks resolving thumbnail URLs:
```elixir
<% thumbnail_url = cond do
  file.file_type == "image" -> file.urls["thumbnail"] || file.urls["small"] || file.urls["original"]
  file.file_type == "video" -> file.urls["video_thumbnail"]
  true -> file.urls["thumbnail"] || file.urls["small"]
end %>
```

**After:** New `PhoenixKitWeb.Components.Core.MediaThumbnail` with:
- `<.thumbnail_url>` component using slot-based API with `:let`
- `resolve_url/2` public function with pattern-matched clauses for video/image/other
- Two size variants: `:small` (selectors, default) and `:medium` (gallery/preview)

**Usage:**
```heex
<.thumbnail_url :let={url} file={file} size={:medium}>
  <%= if url do %>
    <img src={url} alt={file.filename} />
  <% else %>
    <.icon name="hero-document" class="w-12 h-12" />
  <% end %>
</.thumbnail_url>
```

**Import change:** `core_components()` added to `live_component` macro in `phoenix_kit_web.ex`, since `MediaSelectorModal` is a LiveComponent that needs the new component.

### 3. Shop Form Localized Validation Fix

**Before (category_form.ex):**
```elixir
def handle_event("validate", %{"category" => category_params}, socket) do
  changeset = Shop.change_category(category_params) |> Map.put(:action, :validate)  # 1. changeset first
  category_translations = merge_translation_params(...)                                # 2. translations after
```

**After:**
```elixir
def handle_event("validate", %{"category" => category_params}, socket) do
  category_translations = merge_translation_params(...)                                # 1. translations first
  category_params = build_localized_params(..., category_translations, ...)            # 2. merge into params
  changeset = Shop.change_category(category_params) |> Map.put(:action, :validate)    # 3. changeset with complete data
```

Same reordering applied in `product_form.ex`. This ensures changeset validation runs against complete, localized params rather than raw form data missing translation values.

## Review Assessment

### Positives

1. **Real bug fix** — The `FileStorage.save/2` issue was silently corrupting the XML sitemap with HTML content. Clean removal of the broken call.

2. **Good DRY extraction** — `MediaThumbnail` eliminates genuine triplication. The slot-based `:let` API gives templates full control over rendering while centralizing URL resolution.

3. **Clean module boundary** — `HtmlGenerator` is self-contained with proper `@moduledoc`, `@doc`, `@spec` annotations. The `render_link/1` shared helper reduces the 3 duplicated link patterns to one.

4. **Correct validation fix** — The shop form reordering is the right approach; localized params must be built before the changeset can validate them.

5. **LiveComponent import gap fixed** — Adding `core_components()` to the `live_component` macro is a structural improvement that benefits any LiveComponent needing core components, not just this PR.

### Concerns

1. **Performance regression: entries collected on cache hit.** The new `generate_html/1` always calls `collect_all_entries(opts)` before delegating to `HtmlGenerator.generate/2`. If the cache has a hit, those entries are discarded. The old code checked cache first, then collected entries only on miss.

   **Impact:** Every HTML sitemap request runs all source DB queries regardless of cache state.

   **Suggested fix:**
   ```elixir
   def generate_html(opts \\ []) do
     style = Keyword.get(opts, :style, "hierarchical")
     cache_enabled = Keyword.get(opts, :cache, true)

     if cache_enabled do
       case Cache.get(:"html_#{style}") do
         {:ok, cached} ->
           Logger.debug("Sitemap: Using cached HTML sitemap (#{style})")
           {:ok, cached}

         :error ->
           entries = collect_all_entries(opts)
           HtmlGenerator.generate(opts, entries)
       end
     else
       entries = collect_all_entries(opts)
       HtmlGenerator.generate(opts, entries)
     end
   end
   ```

2. **Validation runs after entry collection.** Related to #1: `base_url` and `style` validation now happens inside `HtmlGenerator.generate/2`, after entries are collected. The old code validated before doing any work. On the error path (missing `base_url`, invalid style), DB queries run for nothing.

3. **`base_url` validation semantics changed.** Old: `!Keyword.get(opts, :base_url)` — catches `nil`, `false`, missing key. New: `!Keyword.has_key?(opts, :base_url)` — only catches missing key. Passing `base_url: nil` explicitly now bypasses validation. Low risk (callers are internal) but a subtle behavior change.

4. **`:medium` fallback chain for non-image/video files.** The catch-all `resolve_url(%{urls: urls}, :medium)` checks `urls["thumbnail"] || urls["small"] || urls["medium"]` — preferring smaller variants over medium. This preserves old behavior but seems counterintuitive for the `:medium` size variant.

### Minor Observations

- `resolve_url/2` is public (`def`) with `@spec` and `@doc`, but only used internally via the `<.thumbnail_url>` component. Reasonable API design for future programmatic use, though currently unused externally.
- Icon size in fallback UI differs between templates (`w-12 h-12` vs `w-16 h-16`) — component doesn't abstract this, each template still handles its own fallback rendering. A future iteration could add a `fallback_icon_class` attr.
- `do_generate/4` uses a default argument (`cache_opts \\ []`) on a private function — works fine but the two call sites (one with arity 3, one with arity 4) can be slightly confusing to read.

## Follow-up from PR #327 Review

PR #327's AI review identified 8 concerns and 4 minor observations. This PR addresses 2 of them:

### Addressed by #328

| #327 Item | How #328 Fixed It |
|-----------|-------------------|
| Minor observation: thumbnail URL duplication across 3 templates | New `MediaThumbnail` component eliminates all 3 duplicated `cond` blocks |
| Concern #5 (partial): `FileStorage.save/2` bug | HTML no longer written to disk; ETS-only caching prevents XML sitemap corruption |

### Still Open from #327

| # | Issue | Priority |
|---|-------|----------|
| 1 | **Breaking router_discovery default** — Sites upgrading silently switch sitemap URL structure | Medium |
| 2 | **Per-module regeneration runs full regen** — `regenerate_module_now/1` always calls full `regenerate_sitemap/1` | Low |
| 3 | **On-demand generation returns 404** — Controller should re-serve after successful generation | Low |
| 4 | **Shop source double-scan** — Loads all products into memory for `MapSet` instead of targeted SQL query | Medium |
| 5 | **No timeout on PDF commands** — `pdftoppm`/`pdfinfo` can hang on crafted PDFs; add `Task.yield/2` wrapper | Medium |
| 6 | **Session consolidation tradeoff** — Comments permission behavior change for custom roles | Low |
| 7 | **`length(entries) > @max_urls_per_file` double traversal** — Could use `Enum.count_until/2` | Low |
| 8 | **`normalize_language_public/1` naming** — Unconventional `_public` suffix | Low |
| — | **`safe_parse_decimal/1` trailing whitespace** — Strings with spaces bypass zero detection | Low |
| — | **`flat_mode?()` coupling** — Tied to Router Discovery, cannot evolve independently | Low |

### New Issue Introduced by #328

| Issue | Priority |
|-------|----------|
| **`collect_all_entries` runs on every HTML sitemap request**, including cache hits — performance regression vs. #327 code | Medium |

## Verdict

**Approved with notes.** The extraction refactors are clean and well-motivated. The `FileStorage.save` bug fix is the most valuable change — it resolved silent XML sitemap corruption. The `MediaThumbnail` component is a textbook DRY improvement with a good API. The shop form validation fix is correct.

The `collect_all_entries` performance regression (concern #1) should be addressed in a follow-up — it's straightforward to fix by moving the cache check back into `generate_html/1` before entry collection.

## Testing

- [x] `mix compile --warnings-as-errors`
- [x] `mix credo --strict` — 0 issues
- [x] `mix dialyzer` passes
- [x] All 3 HTML sitemap styles verified via MCP eval
- [x] HTML/XML sitemap rendering verified manually
- [x] Media thumbnails in selector and gallery verified

## Related

- **Follows**: PR #327 (v1.7.35 sitemap index, PDF, shop fixes)
- **New files**: `html_generator.ex`, `media_thumbnail.ex`
- **URL**: https://github.com/BeamLabEU/phoenix_kit/pull/328
