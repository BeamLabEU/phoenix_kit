# UUID Parameter Rename & Integer Rejection — Agent Instructions

**Date:** 2026-02-16
**Context:** PR #340 completed the Pattern 2 schema migration. The migration guide (`dev_docs/uuid_migration_instructions_v3.md` V3.3) now mandates UUID-first parameter naming and hard errors on integer inputs. This document tells you what code to change.

## The Rule

1. **Public API functions** use `_uuid` parameter names (e.g., `post_uuid`, `user_uuid`)
2. **Integer arguments** to public functions raise `ArgumentError` — this catches stale callers
3. **Private helpers** that resolve between types keep their specific names (`resolve_user_uuid(user_id)` takes integer, `resolve_user_id(user_uuid)` takes UUID)
4. **Oban workers** are the ONE exception — they may accept both types in private helpers because old jobs in the queue can't be changed

## Pattern to Follow

The Posts module (`lib/modules/posts/posts.ex`) was partially migrated but still uses `_id` parameter names. Here's what the final pattern should look like, using Comments module as reference (`lib/modules/comments/comments.ex`):

### Before (WRONG — current state in Posts)

```elixir
def like_post(post_id, user_id) when is_binary(user_id) do
  if UUIDUtils.valid?(user_id) do
    do_like_post(post_id, user_id, resolve_user_id(user_id))
  else
    case Integer.parse(user_id) do
      {int_id, ""} -> like_post(post_id, int_id)
      _ -> {:error, :invalid_user_id}
    end
  end
end

def like_post(post_id, user_id) when is_integer(user_id) do
  do_like_post(post_id, resolve_user_uuid(user_id), user_id)
end
```

### After (CORRECT — target state)

```elixir
def like_post(post_uuid, user_uuid) when is_binary(user_uuid) do
  if UUIDUtils.valid?(user_uuid) do
    do_like_post(post_uuid, user_uuid, resolve_user_id(user_uuid))
  else
    {:error, :invalid_user_uuid}
  end
end

def like_post(_post_uuid, user_uuid) when is_integer(user_uuid) do
  raise ArgumentError,
    "like_post/2 expects a UUID string for user_uuid, got integer: #{user_uuid}. " <>
    "Use user.uuid instead of user.id"
end
```

### Key changes:
- Parameter names: `post_id` → `post_uuid`, `user_id` → `user_uuid`
- Remove `Integer.parse` fallback in binary clause — UUID strings only
- Integer clause raises `ArgumentError` instead of resolving
- Error tuple uses `:invalid_user_uuid` not `:invalid_user_id`
- Private `do_*` helpers keep their current parameter names (they receive resolved values)

## Modules to Update

### 1. Posts Module — `lib/modules/posts/posts.ex`

**Functions to rename parameters + add integer rejection:**

| Function | Current params | Target params |
|----------|---------------|---------------|
| `like_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `unlike_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `dislike_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `undislike_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `post_liked_by?/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `post_disliked_by?/2` | `post_id, user_id` | `post_uuid, user_uuid` |
| `add_mention_to_post/3` | `post_id, user_id, mention_type` | `post_uuid, user_uuid, mention_type` |
| `remove_mention_from_post/2` | `post_id, user_id` | `post_uuid, user_uuid` |

**Also check these functions** that may still use `_id` params (read the file to verify):
- `create_post/2`
- `update_post/2`
- `delete_post/1`
- `get_post/1`, `get_post!/1`
- `list_posts/1`
- `list_user_groups/2`
- `reorder_groups/2`
- `schedule_post/3`
- `list_post_likes/1`, `list_post_dislikes/1`
- `list_post_mentions/1`
- All other public functions

### 2. Comments Module — `lib/modules/comments/comments.ex`

Already migrated to UUID-first logic but still uses `_id` parameter names. Same rename needed:

| Function | Current params | Target params |
|----------|---------------|---------------|
| `like_comment/2` | `comment_id, user_id` | `comment_uuid, user_uuid` |
| `unlike_comment/2` | `comment_id, user_id` | `comment_uuid, user_uuid` |
| `dislike_comment/2` | `comment_id, user_id` | `comment_uuid, user_uuid` |
| `undislike_comment/2` | `comment_id, user_id` | `comment_uuid, user_uuid` |
| `comment_liked_by?/2` | `comment_id, user_id` | `comment_uuid, user_uuid` |
| `comment_disliked_by?/2` | `comment_id, user_id` | `comment_uuid, user_uuid` |
| `create_comment/1` | check params | rename if using `_id` for UUIDs |
| `update_comment/2` | check params | rename if using `_id` for UUIDs |
| `delete_comment/1` | check params | rename if using `_id` for UUIDs |
| `get_comment/1` | check params | rename if using `_id` for UUIDs |

### 3. Connections Module — `lib/modules/connections/connections.ex`

Check all public functions. Key ones:
- `send_connection_request/2`
- `accept_connection/1`, `reject_connection/1`
- `follow_user/2`, `unfollow_user/2`
- `block_user/2`, `unblock_user/2`
- `get_connection_status/2`
- All list/query functions

### 4. Tickets Module — `lib/modules/tickets/tickets.ex`

Check all public functions:
- `create_ticket/2`
- `update_ticket/2`
- `get_ticket/1`, `get_ticket!/1`
- `assign_ticket/2`
- `add_comment/2`
- `list_tickets/1`
- All other public functions

### 5. Storage Module — `lib/modules/storage/storage.ex`

Check all public functions:
- `get_file/1`, `get_bucket/1`
- `create_file/1`, `delete_file/1`
- All other public functions

### 6. Other Modules to Check

These modules may also have `_id` params for UUID values:
- `lib/modules/billing/billing.ex`
- `lib/modules/shop/shop.ex`
- `lib/modules/referrals/referrals.ex`
- `lib/modules/emails/templates.ex`
- `lib/modules/ai/ai.ex`
- `lib/modules/entities/entities.ex`
- `lib/modules/sync/connections.ex`
- `lib/modules/sync/transfers.ex`
- `lib/modules/legal/schemas/consent_log.ex`

### 7. Web Layer — Callers

After renaming parameters, check that callers pass the right values. Search for:
- `current_user.id` being passed where `current_user.uuid` is needed
- Any `phx-value-id` that should be `phx-value-uuid`
- Handler patterns `%{"id" => id}` that should be `%{"uuid" => uuid}`

Key web files:
- `lib/modules/posts/web/*.ex` and `*.html.heex`
- `lib/modules/tickets/web/*.ex` and `*.html.heex`
- `lib/modules/comments/web/*.ex` and `*.html.heex`
- `lib/phoenix_kit_web/live/modules/connections/*.ex` and `*.html.heex`
- `lib/modules/storage/web/*.ex` and `*.html.heex`

## What NOT to Change

- **Private helpers** like `resolve_user_uuid(user_id)` and `resolve_user_id(user_uuid)` — these are correctly named because the param type matches
- **Schema fields** — `field :user_id, :integer` stays as-is (it's the DB column name)
- **Changeset keys** — `%{user_id: ..., user_uuid: ...}` stays (these are DB column names for dual-write)
- **Oban worker** integer fallbacks — old jobs in queue need them
- **`PhoenixKit.UUID.get/2`** — this universal helper intentionally handles all types

## Verification

After all changes:

```bash
mix compile --warnings-as-errors
mix format
mix credo --strict
mix test
```

Also run these searches to find remaining issues:

```bash
# Find public functions with _id params that should be _uuid
# (exclude resolve_*, defp, schema fields, changeset keys)
ast-grep --lang elixir --pattern 'def $FUNC($$$, user_id) when $$$' lib/modules/

# Find callers passing .id where .uuid is needed
ast-grep --lang elixir --pattern 'current_user.id' lib/modules/ lib/phoenix_kit_web/

# Find phx-value-id in templates (should mostly be phx-value-uuid)
grep -r 'phx-value-id' lib/ --include='*.heex'
```

## Commit Convention

Split into logical commits per module:
1. "Rename posts module parameters from _id to _uuid and reject integer inputs"
2. "Rename comments module parameters from _id to _uuid and reject integer inputs"
3. etc.

Do NOT mention Claude or AI in commit messages. Start with action verbs (Add, Update, Fix, Remove, Rename).
