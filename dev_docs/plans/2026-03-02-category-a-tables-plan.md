# Plan: Category A Tables — Rename `id` → `uuid` and verify integrity

> **Status**: DONE — Verified on production
> **Date**: 2026-03-02
> **Implemented**: v1.7.54 (V72), released 2026-03-03
> **Verified on**: dev-nalazurke-fr after V72 migration on 2026-03-03

## What are Category A tables?

30 tables where the PK column `id` is already UUID type (no separate `uuid` column).
Ecto schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}` to map `:uuid` field → DB column `id`.

## What needs to happen

1. **Migration: Rename `id` → `uuid`** on 30 tables — metadata-only, instant
2. **Migration: Add 4 missing FK constraints** on `_uuid` columns
3. **Code: Remove `source: :id`** from 29 Ecto schemas (not 30 — see notes below)

PK auto-updates on rename. 29 existing FK constraints pointing to these tables auto-update too.

---

## Per-table checklist

| # | Table | FKs In | Missing FKs | Status |
|---|-------|--------|-------------|--------|
| 1 | `phoenix_kit_buckets` | 1 | — | ✅ |
| 2 | `phoenix_kit_comment_dislikes` | 0 | — | ✅ |
| 3 | `phoenix_kit_comment_likes` | 0 | — | ✅ |
| 4 | `phoenix_kit_comments` | 3 | `user_uuid` → `users.uuid` | ✅ |
| 5 | `phoenix_kit_comments_dislikes` | 0 | `user_uuid` → `users.uuid` | ✅ |
| 6 | `phoenix_kit_comments_likes` | 0 | `user_uuid` → `users.uuid` | ✅ |
| 7 | `phoenix_kit_file_instances` | 1 | — | ✅ |
| 8 | `phoenix_kit_file_locations` | 0 | — | ✅ |
| 9 | `phoenix_kit_files` | 6 | — | ✅ |
| 10 | `phoenix_kit_post_comments` | 3 | — | ✅ |
| 11 | `phoenix_kit_post_dislikes` | 0 | — | ✅ |
| 12 | `phoenix_kit_post_groups` | 1 | — | ✅ |
| 13 | `phoenix_kit_post_likes` | 0 | — | ✅ |
| 14 | `phoenix_kit_post_media` | 0 | — | ✅ |
| 15 | `phoenix_kit_post_mentions` | 0 | — | ✅ |
| 16 | `phoenix_kit_post_tags` | 1 | — | ✅ |
| 17 | `phoenix_kit_post_views` | 0 | — | ✅ |
| 18 | `phoenix_kit_posts` | 8 | — | ✅ |
| 19 | `phoenix_kit_scheduled_jobs` | 0 | `created_by_uuid` → `users.uuid` | ✅ |
| 20 | `phoenix_kit_storage_dimensions` | 0 | — | ✅ |
| 21 | `phoenix_kit_ticket_attachments` | 0 | — | ✅ |
| 22 | `phoenix_kit_ticket_comments` | 2 | — | ✅ |
| 23 | `phoenix_kit_ticket_status_history` | 0 | — | ✅ |
| 24 | `phoenix_kit_tickets` | 3 | — | ✅ |
| 25 | `phoenix_kit_user_blocks` | 0 | — | ✅ |
| 26 | `phoenix_kit_user_blocks_history` | 0 | — | ✅ |
| 27 | `phoenix_kit_user_connections` | 0 | — | ✅ |
| 28 | `phoenix_kit_user_connections_history` | 0 | — | ✅ |
| 29 | `phoenix_kit_user_follows` | 0 | — | ✅ |
| 30 | `phoenix_kit_user_follows_history` | 0 | — | ✅ |

**Skipped FK**: `comments.resource_uuid` and `scheduled_jobs.resource_uuid` are polymorphic — intentionally no FK constraint.

**Non-phoenix_kit tables**: `service_images.media_uuid` and `services.featured_media_uuid` reference `phoenix_kit_files.id` — will auto-update on rename.

---

## Schema files (remove `source: :id`)

| File | Module |
|------|--------|
| `lib/modules/storage/schemas/bucket.ex` | Storage |
| `lib/modules/storage/schemas/dimension.ex` | Storage |
| `lib/modules/storage/schemas/file.ex` | Storage |
| `lib/modules/storage/schemas/file_instance.ex` | Storage |
| `lib/modules/storage/schemas/file_location.ex` | Storage |
| `lib/modules/posts/schemas/post.ex` | Posts |
| `lib/modules/posts/schemas/post_comment.ex` | Posts |
| `lib/modules/posts/schemas/post_dislike.ex` | Posts |
| `lib/modules/posts/schemas/post_group.ex` | Posts |
| `lib/modules/posts/schemas/post_like.ex` | Posts |
| `lib/modules/posts/schemas/post_media.ex` | Posts |
| `lib/modules/posts/schemas/post_mention.ex` | Posts |
| `lib/modules/posts/schemas/post_tag.ex` | Posts |
| `lib/modules/posts/schemas/post_view.ex` | Posts |
| `lib/modules/posts/schemas/comment_like.ex` | Posts |
| `lib/modules/posts/schemas/comment_dislike.ex` | Posts |
| `lib/modules/comments/schemas/comment.ex` | Comments |
| `lib/modules/comments/schemas/comment_like.ex` | Comments |
| `lib/modules/comments/schemas/comment_dislike.ex` | Comments |
| `lib/modules/tickets/ticket.ex` | Tickets |
| `lib/modules/tickets/ticket_comment.ex` | Tickets |
| `lib/modules/tickets/ticket_attachment.ex` | Tickets |
| `lib/modules/tickets/ticket_status_history.ex` | Tickets |
| `lib/modules/connections/block.ex` | Connections |
| `lib/modules/connections/block_history.ex` | Connections |
| `lib/modules/connections/connection.ex` | Connections |
| `lib/modules/connections/connection_history.ex` | Connections |
| `lib/modules/connections/follow.ex` | Connections |
| `lib/modules/connections/follow_history.ex` | Connections |
**Notes:**
- `webhook_event.ex` is Category B (BIGINT PK, not UUID) — excluded from this plan
- `scheduled_jobs` schema already has `@primary_key {:uuid, UUIDv7, autogenerate: true}` (no `source: :id`) — only needs DB column rename
- Total schema changes: 29 (not 30)

---

## Post-release verification results (2026-03-03)

- **Query 1** (no UUID `id` columns): 0 rows — all 30 tables renamed
- **Query 2** (FK constraints missing): 0 rows — all 4 constraints created
- **Migration version**: 72

```sql
-- 1. No Category A tables should have 'id' column anymore
SELECT table_name FROM information_schema.columns
WHERE table_name LIKE 'phoenix_kit_%' AND column_name = 'id'
AND data_type = 'uuid';
-- Expected: 0 rows

-- 2. All 29 incoming FK constraints now reference 'uuid' not 'id'
SELECT tc.table_name, kcu.column_name, ccu.table_name AS ref_table, ccu.column_name AS ref_col
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name
JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY' AND ccu.column_name = 'id'
AND ccu.table_name LIKE 'phoenix_kit_%';
-- Expected: only Category B tables still reference 'id'

-- 3. All 4 missing FK constraints now exist
SELECT 'comments.user_uuid' AS missing WHERE NOT EXISTS (
  SELECT 1 FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu USING (constraint_name)
  WHERE tc.constraint_type = 'FOREIGN KEY' AND kcu.table_name = 'phoenix_kit_comments' AND kcu.column_name = 'user_uuid'
) UNION ALL
SELECT 'comments_dislikes.user_uuid' WHERE NOT EXISTS (
  SELECT 1 FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu USING (constraint_name)
  WHERE tc.constraint_type = 'FOREIGN KEY' AND kcu.table_name = 'phoenix_kit_comments_dislikes' AND kcu.column_name = 'user_uuid'
) UNION ALL
SELECT 'comments_likes.user_uuid' WHERE NOT EXISTS (
  SELECT 1 FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu USING (constraint_name)
  WHERE tc.constraint_type = 'FOREIGN KEY' AND kcu.table_name = 'phoenix_kit_comments_likes' AND kcu.column_name = 'user_uuid'
) UNION ALL
SELECT 'scheduled_jobs.created_by_uuid' WHERE NOT EXISTS (
  SELECT 1 FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu USING (constraint_name)
  WHERE tc.constraint_type = 'FOREIGN KEY' AND kcu.table_name = 'phoenix_kit_scheduled_jobs' AND kcu.column_name = 'created_by_uuid'
);
-- Expected: 0 rows
```
