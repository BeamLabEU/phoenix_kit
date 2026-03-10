# Claude Review — PR #398

**Verdict: Approve with minor suggestions**

Clean, focused PR with two independent features. Both are well-implemented with appropriate patterns.

## Issues

### 1. `post_count` increment may drift from reality (posts.ex:1413)

```elixir
repo().update_all(inc: [post_count: inserted_count])
```

The `post_count` is incremented by `inserted_count` from `insert_all`, which correctly accounts for `on_conflict: :nothing` skipping duplicates. However, if `post_count` was already out of sync (e.g., from a previous bug or manual DB edit), this compounds the drift. Consider a periodic reconciliation or using a subquery count instead:

```elixir
# Alternative: set exact count
from(g in PostGroup, where: g.uuid == ^group_uuid,
  update: [set: [post_count: subquery(
    from(a in PostGroupAssignment, where: a.group_uuid == ^group_uuid, select: count())
  )]])
```

This is low priority — the current approach is correct for normal operation.

### 2. Flash message not wrapped in `gettext()` (web/posts.ex:278-279)

```elixir
|> put_flash(:info, "Added #{count} post(s) to group")
|> put_flash(:error, "Failed to add posts to group")
```

Both messages should use `gettext` for i18n consistency. The interpolation can use `ngettext` for proper pluralization:

```elixir
|> put_flash(:info, ngettext("Added 1 post to group", "Added %{count} posts to group", count))
```

### 3. Groups loaded on every `handle_params` call (web/posts.ex:86)

```elixir
|> load_groups()
```

`load_groups/1` is called in `handle_params`, which fires on every URL change (filtering, pagination, sorting). Groups rarely change — consider loading once in `mount` (connected clause) instead, or adding a simple cache.

### 4. Missing `prefix` option in queries (posts.ex)

Both `add_posts_to_group/3` and `list_groups/1` use `repo().insert_all`, `repo().update_all`, and `repo().all` without passing `prefix:` option. If PhoenixKit uses schema prefixes for multi-tenancy, these queries will hit the wrong schema. Check if other Posts context functions pass a prefix.

## Positive

1. **`on_conflict: :nothing`** — Correct use for idempotent bulk insert. No duplicates, no crashes.
2. **Transaction wrapping** — The insert + count update are properly wrapped in `repo().transaction`.
3. **Custom fields fallback** — Clean use of `Phoenix.Naming.humanize/1` and reuse of existing `format_custom_field_value/3`. No new helpers needed.
4. **Dynamic group filter** — Replaces a TODO comment with working code. The `@groups` assign serves double duty for both the filter dropdown and the bulk action dropdown.

## Summary

Both features are straightforward and well-implemented. The main items are i18n wrapping for flash messages and potentially moving `load_groups` to mount only. Ready to merge.
