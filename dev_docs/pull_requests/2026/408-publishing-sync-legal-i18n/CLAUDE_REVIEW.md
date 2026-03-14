# PR #408 Review: Fix Publishing group sync, add Legal i18n

**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/408
**Author**: timujinne
**Date**: 2026-03-14
**Reviewer**: Claude

## Summary

Two changes bundled:
1. **Publishing group sync**: Groups defined in Settings JSON are now synced to the DB table (both eagerly on `add_group` and lazily on `create_post`), fixing `:group_not_found` errors.
2. **Legal multilanguage**: Legal page generation now supports language selection — language-aware template lookup (`{name}.{lang}.eex` fallback), language selector in UI, per-language status badges.

## Verdict: Approve with suggestions

The core logic is sound. The group sync fix addresses a real data consistency issue, and the multilanguage approach is well-designed with proper fallback chains. A few items worth improving.

---

## Issues Found

### 1. Bare `rescue _` in Settings LiveView (Medium)

**File**: `lib/modules/legal/web/settings.ex:286-296`

```elixir
defp publishing_module_languages do
  Publishing.enabled_language_codes()
rescue
  _ -> ["en"]
end

defp default_language do
  Publishing.get_primary_language()
rescue
  _ -> "en"
end
```

**Problem**: Bare `rescue _` swallows all exceptions silently — including genuine bugs (e.g., `ArgumentError`, `FunctionClauseError`). If these functions break in a future refactor, the error will be invisible.

**Suggestion**: At minimum, log the error:

```elixir
defp publishing_module_languages do
  Publishing.enabled_language_codes()
rescue
  e ->
    Logger.warning("Failed to get enabled languages: #{inspect(e)}")
    ["en"]
end
```

Or better: check if Publishing module is enabled before calling, avoiding the need for rescue entirely.

### 2. Duplicated `upsert_group` payload construction (Low)

**File**: `lib/modules/publishing/publishing.ex:637-647` and `lib/modules/publishing/publishing.ex:1916-1926`

The same map structure for `DBStorage.upsert_group/1` is built in two places — once in `add_group` (eager sync) and once in `sync_group_to_db` (lazy sync). If the schema changes, both must be updated.

**Suggestion**: Extract a private `build_group_attrs/1` helper:

```elixir
defp build_group_attrs(group) do
  %{
    name: group["name"],
    slug: group["slug"],
    mode: group["mode"],
    data: %{
      "type" => group["type"],
      "item_singular" => group["item_singular"],
      "item_plural" => group["item_plural"]
    }
  }
end
```

### 3. Silent fallback in `update_existing_legal_post` (Low)

**File**: `lib/modules/legal/legal.ex:965-990`

When `read_post` or `add_language_to_post` fails, the code silently falls back to `existing_post`:

```elixir
case publishing_module().read_post(...) do
  {:ok, p} -> p
  _ -> existing_post    # <-- silent failure
end
```

This means if the language-specific read fails (e.g., DB error), the primary language post gets overwritten with the wrong language's content. A `Logger.warning` on the fallback branch would help debug production issues.

### 4. Hardcoded "en" as default in `render/3` (Low)

**File**: `lib/modules/legal/services/template_generator.ex:59`

```elixir
def render(template_name, context, language \\ "en")
```

The caller (`legal.ex:878`) already resolves the primary language properly, so this default is only hit if someone calls `render/2` directly. It's fine as-is, but inconsistent with the pattern in `generate_page/2` which uses `get_primary_language()`. Not a bug since all current call sites pass the language explicitly.

### 5. Language selector sends value but "Generate All" also sends it (Nit)

**File**: `lib/modules/legal/web/settings.html.heex:331-340`

The language is stored in assigns via `select_generation_language` event AND passed as `phx-value-language` on the buttons. The event handler reads from params first, falling back to assigns. This works correctly but the dual mechanism is slightly redundant — the `phx-value-language` on buttons could be removed since the assign is always up-to-date. Not a bug, just unnecessary.

---

## What's Done Well

- **Defensive comment on `add_language_to_post`** (lines 953-957): Documenting the UUID-as-slug bug and why the check for existing languages is needed prevents future developers from "simplifying" the code and reintroducing the bug.
- **Lazy sync pattern**: The `sync_group_to_db` fallback in `create_post_in_db` handles existing installations gracefully without requiring a migration.
- **Template fallback chain**: `{name}.{lang}.eex` → `{name}.eex` is the right approach, and checking parent app before PhoenixKit templates preserves customizability.
- **`ensure_legal_blog` added to `generate_page`**: Previously missing, this prevents the first page generation from failing if the legal group didn't exist yet.

## Publishing `read_back_post` Bug

The PR documents a known bug where `read_back_post` tries to look up a UUID as a slug when `db_post=nil`, causing `{:error, :not_found}`. The workaround (using `case` instead of `=`) is correct but this root cause should be tracked for a proper fix in Publishing — it will bite other callers of `add_language_to_post` too.

**Recommendation**: Create a follow-up issue to fix `read_back_post` to handle UUID identifiers correctly regardless of `db_post` value.
