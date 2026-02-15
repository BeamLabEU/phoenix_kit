# PR #329: Add resource context resolution to Comments admin UI

**Author**: @alexdont
**Reviewer**: Claude Opus 4.6
**Status**: Merged
**Date**: 2026-02-12
**Impact**: +86 / -1 across 5 files
**Commits**: 1

## Goal

Show linked resource titles (e.g., post name) next to the `resource_type` badge in the comments moderation table. Admins can click through to the source resource. Unresolvable resources display a "(deleted)" fallback.

Introduces a callback pattern where resource handler modules implement `resolve_comment_resources/1` to batch-resolve titles and admin paths. The Posts module is registered as the first handler.

## Commit

| Hash | Description |
|------|-------------|
| `4c59b1dc` | Add resource context resolution to Comments admin UI |

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `config/config.exs` | Added `comment_resource_handlers` map with `"post" => PhoenixKit.Modules.Posts` |
| `lib/modules/comments/comments.ex` | New `resolve_resource_context/1` + `resolve_for_type/2` (~43 lines) |
| `lib/modules/comments/web/index.ex` | New `resource_context` assign, `resource_info/2` helper, resolution call in `load_comments/1` |
| `lib/modules/comments/web/index.html.heex` | Resource title link + "(deleted)" fallback in table row |
| `lib/modules/posts/posts.ex` | New `resolve_comment_resources/1` — batch query for post titles |

## Implementation Details

### Architecture: Callback-based Resource Resolution

The Comments module uses polymorphic associations (`resource_type` + `resource_id`). Previously, the admin moderation table only showed a `resource_type` badge with no link to the actual resource. This PR adds a handler-dispatch pattern:

1. **Config registry** — `comment_resource_handlers` maps resource type strings to handler modules:
   ```elixir
   config :phoenix_kit,
     comment_resource_handlers: %{
       "post" => PhoenixKit.Modules.Posts
     }
   ```

2. **Batch resolution** — `Comments.resolve_resource_context/1` groups comments by `resource_type`, deduplicates IDs, and dispatches to the appropriate handler:
   ```elixir
   comments
   |> Enum.group_by(& &1.resource_type, & &1.resource_id)
   |> Enum.reduce(%{}, fn {resource_type, ids}, acc ->
     resolved = resolve_for_type(resource_type, Enum.uniq(ids))
     # merge into {resource_type, resource_id} => %{title, path} map
   end)
   ```

3. **Handler contract** — Modules implement `resolve_comment_resources/1`:
   ```elixir
   # In Posts module
   def resolve_comment_resources(resource_ids) when is_list(resource_ids) do
     from(p in Post, where: p.id in ^resource_ids, select: {p.id, p.title})
     |> repo().all()
     |> Map.new(fn {id, title} -> {id, %{title: title, path: "/admin/posts/#{id}"}} end)
   end
   ```

4. **UI rendering** — Pattern-matched in template via `case resource_info(@resource_context, comment)`. Resolved resources get a clickable link (truncated to 50 chars); unresolved show "(deleted)" with the raw ID in a tooltip.

### Defensive Design

- `Code.ensure_loaded?/1` + `function_exported?/3` guard before calling handler
- `rescue` in both `resolve_for_type/2` and `resolve_comment_resources/1` — double-wrapped error handling
- Missing handler for a resource type returns `%{}` (shows "(deleted)" in UI)
- Missing module or missing callback returns `%{}` silently

## Review Assessment

### Positives

1. **Clean batch pattern** — Groups by resource type and deduplicates IDs before querying. A page of 20 comments about 5 different posts produces one `WHERE id IN (...)` query, not 20 individual lookups.

2. **Extensible design** — Adding support for a new resource type (e.g., shop products) only requires adding to the config map and implementing `resolve_comment_resources/1` on the target module. No changes to Comments code.

3. **Good fallback UX** — "(deleted)" with the raw ID in a tooltip lets admins investigate orphaned comments. The link uses `Routes.path/1` for correct prefix handling.

4. **Defensive handler dispatch** — `Code.ensure_loaded?` + `function_exported?` is the correct pattern for optional callbacks on runtime-configured modules.

### Concerns

1. **N+1 on resource types, not comments, but still sequential.** `resolve_resource_context/1` calls `resolve_for_type/2` inside `Enum.reduce/3`, making one DB query per distinct resource type sequentially. With comments spanning many resource types (posts, shop products, entities, etc.), this becomes serial queries. Could use `Task.async_stream/3` for parallel resolution.

   **Impact:** Low today (only Posts handler exists), but scales linearly with resource types.

2. **Admin path hardcoded as string in Posts handler.** The path `"/admin/posts/#{id}"` bypasses the `Routes.path/1` helper. While `Routes.path/1` is correctly applied in the template (`navigate={Routes.path(path)}`), the handler returns a prefix-relative path that *assumes* it will be wrapped. This contract is implicit — if anyone uses `path` directly without `Routes.path/1`, the prefix will be missing.

   **Suggestion:** Either document this contract explicitly (handler returns prefix-relative paths) or have the handler return full prefixed paths via `Routes.path("/admin/posts/#{id}")`.

3. **`rescue` in `resolve_for_type/2` catches too broadly.** The rescue wraps the entire function including `Application.get_env`, `Map.get`, `Code.ensure_loaded?`, and the handler call. A crash in any of these returns `%{}` with just a warning log. Consider narrowing the rescue to only the `mod.resolve_comment_resources(resource_ids)` call, since the other operations shouldn't raise.

4. **No behaviour definition.** The callback contract is implicit — handlers must implement `resolve_comment_resources/1` returning `%{id => %{title: String.t(), path: String.t()}}`. There's no `@behaviour` or `@callback` definition. A behaviour would:
   - Give compile-time warnings for missing implementations
   - Document the expected return type via `@callback` specs
   - Make the contract discoverable

   **Suggestion:**
   ```elixir
   # In comments module or a separate behaviour file
   @callback resolve_comment_resources([term()]) :: %{
     optional(term()) => %{title: String.t(), path: String.t()}
   }
   ```

5. **`config.exs` change is dev-only.** The `"post" => PhoenixKit.Modules.Posts` handler is added to PhoenixKit's own `config/config.exs`, which only applies when PhoenixKit runs standalone. Parent applications that use PhoenixKit as a dependency need to add this config themselves. This should be documented, or the Posts handler should be registered as a default (perhaps in `PhoenixKit.Config`).

6. **Title truncation in template vs. tooltip.** `String.slice(title, 0..49)` truncates to 50 characters for display, with the full title in `title={title}` tooltip. This is fine, but note that `String.slice/2` with `0..49` returns 50 characters — consider if very long titles with special characters could cause layout issues in the `max-w-[200px]` container.

### Minor Observations

- The `resource_info/2` helper in `index.ex` is a simple `Map.get` wrapper — could be inlined, but readability is arguably better with the named function.
- The "(deleted)" fallback assumes unresolvable = deleted, but it could also mean the handler module isn't configured for that resource type. The fallback text could be more neutral (e.g., "unavailable") though "(deleted)" is likely correct for the vast majority of cases.
- The `to_string(comment.resource_id)` in the tooltip works for both UUID and integer IDs — good defensive choice.
- Double `rescue` (in `resolve_for_type/2` and in `resolve_comment_resources/1` in Posts) — the outer one makes the inner one redundant for crash protection, though the inner one in Posts prevents a single bad post from failing the entire batch.

## Verdict

**Approved.** This is a clean, well-scoped feature addition. The batch resolution pattern is correct, the handler dispatch is properly defensive, and the UI provides good admin UX with clickable links and fallbacks. The main follow-up items are: defining a `@behaviour` for the callback contract, documenting the config requirement for parent apps, and considering `Routes.path/1` usage inside handlers rather than in the template.

## Testing

- [x] `mix compile --warnings-as-errors` (from PR description context)
- [x] `mix credo --strict`
- [x] `mix dialyzer`
- [x] Manual verification of resource links in admin UI
- [x] Deleted resource fallback verified

## Follow-up Recommendations

| Priority | Item |
|----------|------|
| Medium | Define `@callback resolve_comment_resources/1` behaviour for compile-time safety |
| Medium | Document `comment_resource_handlers` config for parent applications |
| Low | Add handlers for other comment-supporting resources (shop products, entities) |
| Low | Consider parallel resolution via `Task.async_stream` when handler count grows |
| Low | Narrow `rescue` scope in `resolve_for_type/2` to just the handler call |

## Related

- **Builds on**: Comments module (polymorphic `resource_type` + `resource_id` architecture)
- **URL**: https://github.com/BeamLabEU/phoenix_kit/pull/329
