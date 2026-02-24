# UUID Migration Audit Report

**Date:** 2026-02-23
**Scope:** All `phoenix_kit_*` tables

The goal of the migration is:
- Every table that had an integer `id` should now have **both** the old `id` (integer, legacy) **and** a new `uuid` (uuidv7) column.
- All relationship/foreign key columns should use the `_uuid` suffix (e.g. `user_uuid`, `comment_uuid`) instead of `_id`.

---

## Issue 1: Tables missing their own `uuid` column

These tables still have `id` as `bigint`/`integer` but no `uuid` column has been added yet.

| Table | `id` type |
|-------|-----------|
| `phoenix_kit_admin_notes` | bigint |
| `phoenix_kit_ai_accounts` | bigint |
| `phoenix_kit_sync_transfers` | bigint |

**Fix:** Add a `uuid` column (uuidv7) to each of these tables.

---

## Issue 2: Relationship columns already UUID type but still named `_id`

These columns have the correct UUID type but the wrong naming convention — they should end in `_uuid`, not `_id`.

| Table | Current column | Rename to |
|-------|---------------|-----------|
| `phoenix_kit_comment_dislikes` | `comment_id` (uuid) | `comment_uuid` |
| `phoenix_kit_comment_likes` | `comment_id` (uuid) | `comment_uuid` |
| `phoenix_kit_comments` | `parent_id` (uuid) | `parent_uuid` |
| `phoenix_kit_comments` | `resource_id` (uuid) | `resource_uuid` |
| `phoenix_kit_comments_dislikes` | `comment_id` (uuid) | `comment_uuid` |
| `phoenix_kit_comments_likes` | `comment_id` (uuid) | `comment_uuid` |
| `phoenix_kit_file_instances` | `file_id` (uuid) | `file_uuid` |
| `phoenix_kit_file_locations` | `bucket_id` (uuid) | `bucket_uuid` |
| `phoenix_kit_file_locations` | `file_instance_id` (uuid) | `file_instance_uuid` |
| `phoenix_kit_post_comments` | `parent_id` (uuid) | `parent_uuid` |
| `phoenix_kit_post_comments` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_post_dislikes` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_post_group_assignments` | `group_id` (uuid) | `group_uuid` |
| `phoenix_kit_post_group_assignments` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_post_groups` | `cover_image_id` (uuid) | `cover_image_uuid` |
| `phoenix_kit_post_likes` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_post_media` | `file_id` (uuid) | `file_uuid` |
| `phoenix_kit_post_media` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_post_mentions` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_post_tag_assignments` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_post_tag_assignments` | `tag_id` (uuid) | `tag_uuid` |
| `phoenix_kit_post_views` | `post_id` (uuid) | `post_uuid` |
| `phoenix_kit_scheduled_jobs` | `resource_id` (uuid) | `resource_uuid` |
| `phoenix_kit_ticket_attachments` | `comment_id` (uuid) | `comment_uuid` |
| `phoenix_kit_ticket_attachments` | `file_id` (uuid) | `file_uuid` |
| `phoenix_kit_ticket_attachments` | `ticket_id` (uuid) | `ticket_uuid` |
| `phoenix_kit_ticket_comments` | `parent_id` (uuid) | `parent_uuid` |
| `phoenix_kit_ticket_comments` | `ticket_id` (uuid) | `ticket_uuid` |
| `phoenix_kit_ticket_status_history` | `ticket_id` (uuid) | `ticket_uuid` |

**Fix:** Rename each column via migration (`ALTER TABLE ... RENAME COLUMN`).

---

## Issue 3: Integer relationship column missing its `_uuid` companion

This column is an integer foreign key but no `_uuid` counterpart has been added yet.

| Table | Column | Missing |
|-------|--------|---------|
| `phoenix_kit_scheduled_jobs` | `created_by_id` (bigint) | `created_by_uuid` |

**Fix:** Add `created_by_uuid` (uuid) column to `phoenix_kit_scheduled_jobs`.

---

## In Progress: Both `_id` (integer) and `_uuid` present — old column pending cleanup

These tables are mid-migration: the new `_uuid` column exists alongside the old integer `_id` column. The uuid population and cutover still needs to happen before the old columns can be dropped.

| Table | Old integer columns | New uuid columns |
|-------|--------------------|--------------------|
| `phoenix_kit_admin_notes` | `author_id`, `user_id` | `author_uuid`, `user_uuid` |
| `phoenix_kit_comment_dislikes` | `user_id` | `user_uuid` |
| `phoenix_kit_comment_likes` | `user_id` | `user_uuid` |
| `phoenix_kit_comments` | `user_id` | `user_uuid` |
| `phoenix_kit_comments_dislikes` | `user_id` | `user_uuid` |
| `phoenix_kit_comments_likes` | `user_id` | `user_uuid` |
| `phoenix_kit_files` | `user_id` | `user_uuid` |
| `phoenix_kit_post_comments` | `user_id` | `user_uuid` |
| `phoenix_kit_post_dislikes` | `user_id` | `user_uuid` |
| `phoenix_kit_post_groups` | `user_id` | `user_uuid` |
| `phoenix_kit_post_likes` | `user_id` | `user_uuid` |
| `phoenix_kit_post_mentions` | `user_id` | `user_uuid` |
| `phoenix_kit_post_views` | `user_id` | `user_uuid` |
| `phoenix_kit_posts` | `user_id` | `user_uuid` |
| `phoenix_kit_scheduled_jobs` | `created_by_id` | *(missing — see Issue 3)* |
| `phoenix_kit_sync_transfers` | `connection_id`, `approved_by`, `denied_by`, `initiated_by` | `connection_uuid`, `approved_by_uuid`, `denied_by_uuid`, `initiated_by_uuid` |
| `phoenix_kit_ticket_comments` | `user_id` | `user_uuid` |
| `phoenix_kit_ticket_status_history` | `changed_by_id` | `changed_by_uuid` |
| `phoenix_kit_tickets` | `user_id`, `assigned_to_id` | `user_uuid`, `assigned_to_uuid` |
| `phoenix_kit_user_blocks` | `blocker_id`, `blocked_id` | `blocker_uuid`, `blocked_uuid` |
| `phoenix_kit_user_blocks_history` | `blocker_id`, `blocked_id` | `blocker_uuid`, `blocked_uuid` |
| `phoenix_kit_user_connections` | `requester_id`, `recipient_id` | `requester_uuid`, `recipient_uuid` |
| `phoenix_kit_user_connections_history` | `actor_id`, `user_a_id`, `user_b_id` | `actor_uuid`, `user_a_uuid`, `user_b_uuid` |
| `phoenix_kit_user_follows` | `follower_id`, `followed_id` | `follower_uuid`, `followed_uuid` |
| `phoenix_kit_user_follows_history` | `follower_id`, `followed_id` | `follower_uuid`, `followed_uuid` |

**Fix:** Once uuid values are populated and application code is cutover, drop the old integer columns.

---

## Tables fully migrated (no issues)

These tables have no legacy integer id/relationship columns remaining:

- `phoenix_kit_buckets`
- `phoenix_kit_file_instances` *(pending rename in Issue 2)*
- `phoenix_kit_file_locations` *(pending rename in Issue 2)*
- `phoenix_kit_post_tags`
- `phoenix_kit_post_tag_assignments` *(pending rename in Issue 2)*
- `phoenix_kit_storage_dimensions`
- `phoenix_kit_ticket_attachments` *(pending rename in Issue 2)*
