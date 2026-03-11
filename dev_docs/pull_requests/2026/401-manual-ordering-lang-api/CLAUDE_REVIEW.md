# PR #401 Review — Manual Record Ordering, Language-Aware API, DataNavigator Refactor

**Author:** Max Don (`mdon`)
**Merged:** 2026-03-11
**Files changed:** 11 (795 additions, 119 deletions)

## Summary

Three cohesive changes to the entities module:
1. **Manual record ordering** — V81 migration adds `position` column, sort mode per entity, reorder/move operations.
2. **Language-aware API** — All list/get functions accept `lang:` opt for translated field resolution.
3. **DataNavigator refactor** — Defer loading to `handle_params`, use DB-level filtering instead of in-memory.

## What's Good

- **`resolve_sort_order/2` with `:sort_mode` opt** — callers that already have the entity loaded can skip the redundant DB lookup. Clean optimization.
- **DataNavigator refactor** — moving from `list_all_data() |> filter_by_entity() |> filter_by_status()` (load everything then filter in-memory) to targeted DB queries is a significant performance win.
- **Subscription model change** — subscribing to global entity/data events once in `mount` instead of per-entity in `handle_params` is simpler and eliminates stale subscriptions.
- **`move_to_position/2` with `shift_neighbors`** — correct gap-shifting implementation that re-reads position inside the transaction to avoid stale data.
- **V81 migration** — clean with `WHERE position IS NULL` guard (idempotent), proper backfill via `ROW_NUMBER()`, composite index, reversible.
- **`next_position/1` with `FOR UPDATE` lock** — prevents concurrent creates from getting the same position.

## Issues

### 1. N+1 query in `resolve_sort_order` for bulk listing (Medium)

**File:** `entity_data.ex` — `resolve_sort_order/2`

```elixir
defp entity_sort_mode_from_db(entity_uuid) do
  case Entities.get_entity(entity_uuid) do ...
```

This does a full `get_entity` + preload of `:creator` just to read `settings["sort_mode"]`. Every call to `list_by_entity/2`, `list_by_entity_and_status/3`, `search_by_title/3` without `:sort_mode` opt triggers this extra query. Consider a lightweight `Entities.get_sort_mode_by_uuid/1` which just reads the settings column, or at minimum use the existing `get_sort_mode_by_uuid/1` which already exists but also calls `get_entity`.

Not a bug since it only fires once per listing call, but the preload is wasted work.

### 2. `search_by_title/1` arity conflict risk (Low)

**File:** `entity_data.ex`

```elixir
def search_by_title(search_term) when is_binary(search_term),
  do: search_by_title(search_term, nil, [])

def search_by_title(search_term, entity_uuid, opts \\ [])
```

The `\\ []` default on the 3-arity clause means Elixir generates a `search_by_title/2` head. Combined with the explicit 1-arity head, the module now has arities 1, 2, and 3. This works but `search_by_title("Acme", [lang: "es"])` would pass the keyword list as `entity_uuid` (a string guard doesn't exist). Callers must always pass `entity_uuid` before `opts`. The `when is_binary(search_term)` guard on the 3-arity clause won't catch this — it guards `search_term`, not `entity_uuid`. Consider adding a guard: `when is_binary(search_term) and (is_binary(entity_uuid) or is_nil(entity_uuid))`.

### 3. Duplicated sort mode merge logic in `entity_form.ex` (Low)

**File:** `entity_form.ex:248-276` and `entity_form.ex:306-332`

The `save_entity` (update) and `create_entity` handlers both have identical sort_mode merge blocks:
```elixir
settings =
  case entity_params["sort_mode"] do
    mode when mode in ~w(auto manual) -> Map.put(settings, "sort_mode", mode)
    _ -> settings
  end
```

Extract to a private helper like `merge_sort_mode_param/2`.

### 4. `@type t :: %__MODULE__{}` is too loose (Nitpick)

**Files:** `entities.ex`, `entity_data.ex`

The type is defined as `%__MODULE__{}` without field types. Dialyzer won't catch misuse of specific fields. Consider defining field types or at minimum adding it as `@type t :: %__MODULE__{uuid: UUIDv7.t(), ...}` for key fields.

### 5. `build_base_path` changed from `get_entity!` to `get_entity` without updating match (Nitpick)

**File:** `data_navigator.ex`

```elixir
case Entities.get_entity(entity_uuid) do
  nil -> "/admin/entities"
  entity -> "/admin/entities/#{entity.name}/data"
end
```

This is actually the correct fix — `get_entity!` would crash on a deleted entity. Good change, just noting it's a bug fix bundled in the refactor.

### 6. `filter_by_search` still runs in-memory (Info)

**File:** `data_navigator.ex:519`

Status and entity filtering moved to DB, but search is still in-memory `Enum.filter`. For small datasets this is fine, but if entity data grows, consider using `EntityData.search_by_title/3` with the sort_mode opts.

## Migration Safety

**V81**: Safe and idempotent. Uses `add_if_not_exists`, `create_if_not_exists`, `WHERE position IS NULL` guard on backfill. Backfill assigns positions by creation date order (oldest=1) per entity. Reversible via `remove_if_exists`. The `FOR UPDATE` lock in `next_position/1` only applies within transactions, correctly noted in the comment.

## Verdict

Well-structured PR. The DataNavigator refactor is a clear performance improvement, the ordering API is thorough with proper transaction safety, and the language-aware API is backward compatible. The sort mode merge duplication (#3) is the most actionable cleanup item. No bugs found.
