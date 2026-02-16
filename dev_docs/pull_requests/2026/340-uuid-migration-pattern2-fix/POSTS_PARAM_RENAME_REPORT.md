# Posts Module — `_id` → `_uuid` Parameter Rename Report

**PR:** #340 (continuation — Bug 3 follow-up)
**Date:** 2026-02-16
**Agent:** Claude Opus 4.6

This report documents the parameter rename and integer rejection work done on the Posts module as a follow-up to Bug 3 in the PR #340 review. The previous commit (`b6541813`) made Posts functions *accept* UUIDs; this work *renames* the parameters and *rejects* integers per UUID migration guide V3.3.

---

## Scope

- **5 files modified**
- **28 public functions** updated in `posts.ex`
- **8 call sites** updated across 4 web files
- **1 private helper** removed (`resolve_user_uuid/1`)

---

## Changes to `lib/modules/posts/posts.ex`

### Group A+B: 12 Functions Restructured

These had dual `is_integer`/`is_binary` guard clauses with `Integer.parse` fallback. Now: binary clause first with UUID validation, integer clause raises `ArgumentError`.

| Function | Old Params | New Params |
|----------|-----------|------------|
| `create_post/2` | `user_id` | `user_uuid` |
| `list_user_posts/2` | `user_id` | `user_uuid` |
| `create_group/2` | `user_id` | `user_uuid` |
| `list_user_groups/2` | `user_id` | `user_uuid` |
| `like_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `unlike_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `post_liked_by?/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `dislike_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `undislike_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `post_disliked_by?/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `add_mention_to_post/3` | `post_id, user_id` | `post_uuid, user_uuid` |
| `remove_mention_from_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |

**Pattern applied:**

```elixir
# Binary clause first — UUID only, no Integer.parse fallback
def like_post(post_uuid, user_uuid) when is_binary(user_uuid) do
  if UUIDUtils.valid?(user_uuid) do
    do_like_post(post_uuid, user_uuid, resolve_user_id(user_uuid))
  else
    {:error, :invalid_user_uuid}
  end
end

# Integer clause — raise to catch stale callers
def like_post(_post_uuid, user_uuid) when is_integer(user_uuid) do
  raise ArgumentError,
    "like_post/2 expects a UUID string for user_uuid, got integer: #{user_uuid}. " <>
      "Use user.uuid instead of user.id"
end
```

### Group C: 16 Functions Renamed (simple param renames)

| Function | Renamed Params |
|----------|---------------|
| `list_post_likes/2` | `post_id` → `post_uuid` |
| `list_post_dislikes/2` | `post_id` → `post_uuid` |
| `list_post_mentions/2` | `post_id` → `post_uuid` |
| `attach_media/3` | `post_id, file_id` → `post_uuid, file_uuid` |
| `detach_media/2` | `post_id, file_id` → `post_uuid, file_uuid` |
| `detach_media_by_id/1` | `media_id` → `media_uuid` |
| `list_post_media/2` | `post_id` → `post_uuid` |
| `reorder_media/2` | `post_id, file_id_positions` → `post_uuid, file_uuid_positions` |
| `set_featured_image/2` | `post_id, file_id` → `post_uuid, file_uuid` |
| `get_featured_image/1` | `post_id` → `post_uuid` |
| `remove_featured_image/1` | `post_id` → `post_uuid` |
| `add_post_to_group/3` | `post_id, group_id` → `post_uuid, group_uuid` |
| `remove_post_from_group/2` | `post_id, group_id` → `post_uuid, group_uuid` |
| `list_posts_by_group/2` | `group_id` → `group_uuid` |
| `remove_tag_from_post/2` | `post_id, tag_id` → `post_uuid, tag_uuid` |
| `reorder_groups/2` | `user_id, group_id_positions` → `user_uuid, group_uuid_positions` |

### Other posts.ex Changes

- **`@moduledoc` examples** — Updated to use UUID strings instead of integers
- **Error atoms** — `:invalid_user_id` → `:invalid_user_uuid` (6 occurrences)
- **Removed `resolve_user_uuid/1`** — Now unused since all integer-accepting clauses were removed
- **`reorder_groups` query** — `g.user_id == ^user_id` → `g.user_uuid == ^user_uuid` (previously tracked as deprecated integer column concern, now fixed)

---

## Changes to Web Layer

All `current_user.id` → `current_user.uuid` where passed to Posts API functions:

| File | Lines | Functions Called |
|------|-------|----------------|
| `web/details.ex` | 54, 84, 95 | `post_liked_by?`, `unlike_post`, `like_post` |
| `web/edit.ex` | 363, 462 | `create_post`, `list_user_groups` |
| `web/group_edit.ex` | 133 | `create_group` |
| `web/groups.ex` | 128, 140 | opts `user_id:` value, `list_user_groups` |

---

## What Was NOT Changed (by design)

- **Private helpers** (`do_like_post`, `do_unlike_post`, etc.) — already receive resolved values
- **`resolve_user_id/1`** — still needed by binary clauses for dual-write (UUID → integer FK)
- **`maybe_filter_by_user/2`** — private helper, `Integer.parse` still works (UUID falls through correctly)
- **Schema field names** — `user_id:`, `post_id:` in changeset attrs are DB column names
- **`get_post!/1`, `get_group/1`** etc. — generic ID resolvers, param name `id` is fine
- **Internal `current_user.id`** in web layer — ownership checks and stub maps compare against DB integer columns

---

## Verification Results

| Check | Result |
|-------|--------|
| `mix compile --warnings-as-errors` | Clean |
| `mix format` | Clean |
| `mix credo --strict` | No issues |
| `mix test` | 156 tests, 0 failures |
| No `:invalid_user_id` atoms remaining | Confirmed |
| No `Integer.parse` in public functions | Confirmed |
| No `current_user.id` in Posts API calls | Confirmed |
| `resolve_user_uuid/1` fully removed | Confirmed |

---

## Review Checklist for Other Agents

1. Verify all 12 Group A+B functions have binary-first clause, `ArgumentError` for integers, no `Integer.parse`
2. Verify all 16 Group C functions have consistent `_uuid` param names in head, @doc, and body
3. Verify web callers pass `current_user.uuid` to every Posts API call
4. Verify `reorder_groups` query uses `g.user_uuid == ^user_uuid`
5. Verify `resolve_user_uuid/1` is fully removed
6. Check for any missed callers outside `lib/modules/posts/` that might still pass integers
7. Verify `@doc` examples use UUID strings, not integer literals

---

## Updates to Previous Review Concerns

From the original CLAUDE_REVIEW.md:

| Item | Previous Status | New Status |
|------|----------------|------------|
| Bug 3: Posts like/dislike/mention reject UUIDs | Fixed (`b6541813`) | Now fully renamed + integer rejection added |
| Concern: `posts.ex` `list_user_groups` uses `g.user_id` | Tracked | **Fixed** — `reorder_groups` now uses `g.user_uuid` |
| Concern: `posts.ex` `reorder_groups` uses `g.user_id` | Tracked | **Fixed** — query updated to `g.user_uuid == ^user_uuid` |
| Concern: `posts.ex` `maybe_filter_by_user` uses `p.user_id` | Tracked | Unchanged (private helper, works correctly with UUID input) |
