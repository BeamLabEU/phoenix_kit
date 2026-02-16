# PR #340 Deep Dive Review — UUID Migration & Pattern 2 Fix

**PR:** [#340](https://github.com/BeamLabEU/phoenix_kit/pull/340) — "Fixed issue with uuid and updated id to uuid for clarity"
**Merged:** 2026-02-16 into `dev`
**Scope:** 1,404 additions / 1,066 deletions across 93 files, 11 commits
**Reviewer:** Claude Opus 4.6

---

## What This PR Does

This PR is a large-scale UUID migration across 5 modules (Connections, Comments, Referrals, Posts, Tickets, Storage) and completes the "Pattern 2" schema normalization. The work falls into three categories:

1. **`belongs_to :user, type: :integer` → UUID-based associations** — Migrated ~20 schemas from integer-based user FKs to `belongs_to :user, foreign_key: :user_uuid, references: :uuid, type: UUIDv7`
2. **Pattern 2 PK normalization** — Changed 29 schemas from `@primary_key {:id, UUIDv7, ...}` to `{:uuid, UUIDv7, autogenerate: true, source: :id}` so code uses `.uuid` consistently
3. **Context & web layer updates** — Updated `.id` → `.uuid` across context modules, LiveViews, and templates

---

## Verdict: Well-Executed — All Bugs Found and Fixed

The schema-level work is **excellent** — all 29 PK migrations, 56 `belongs_to` declarations, 10 `has_many` FK fixes, and 2 composite-PK fixes are correct. The `@foreign_key_type :id` → `UUIDv7` bug fix in history schemas is an important catch.

The audit found 3 bugs and 9 deprecated-column concerns. **All 3 bugs have been fixed** in follow-up commits.

| Severity | Count | Summary | Status |
|----------|-------|---------|--------|
| **BUG (runtime)** | 2 | Stale `.id` on Pattern 2 structs → nil at runtime | **FIXED** `5163b56f` |
| **BUG (incomplete migration)** | 12 | Posts like/dislike/mention functions reject UUID strings | **FIXED** `b6541813` |
| **Concern (deprecated columns)** | 9 | Queries using deprecated integer columns (work now, break at Phase 4) | Tracked |
| **Advisory** | 4 | Documentation/consistency nits | Open |

---

## BUG 1 (HIGH): `request.id` in Connections Template — FIXED

**File:** `lib/phoenix_kit_web/live/modules/connections/user_connections.html.heex:240,247`
**Fixed in:** commit `5163b56f`

```heex
phx-value-id={request.id}   <%!-- BUG: Connection is Pattern 2, .id is nil --%>
```

**Impact:** Accept/Reject connection buttons pass `nil` to the event handler. `Connections.accept_connection(nil)` and `reject_connection(nil)` return `{:error, :not_found}`. Users cannot accept or reject connection requests.

**Fix applied:** Changed `request.id` → `request.uuid` on both lines.

---

## BUG 2 (MEDIUM): `file.id` in Shop Image Downloader — FIXED

**File:** `lib/modules/shop/services/image_downloader.ex:137-138`
**Fixed in:** commit `5163b56f`

```elixir
Logger.info("[ImageDownloader] Successfully stored file with ID: #{file.id}")
{:ok, file.id}
```

**Impact:** `Storage.File` is Pattern 2. `file.id` returns `nil`. The caller receives `{:ok, nil}` instead of `{:ok, <uuid>}`. Product image imports will silently fail to link the file to the product.

**Fix applied:** Changed `file.id` → `file.uuid` on both lines.

---

## BUG 3 (MEDIUM): Posts Module Not Migrated to Accept UUIDs — FIXED

**File:** `lib/modules/posts/posts.ex` — 12 function clauses
**Fixed in:** commit `b6541813`

The Posts module's like/dislike/mention operations used an integer-only approach. Unlike the Comments module (which was properly migrated), these functions rejected UUID strings.

**What was fixed:**

| Function | Change |
|----------|--------|
| `like_post/2` | Extracted `do_like_post/3`, UUID path resolves `user_id` for dual-write |
| `unlike_post/2` | Extracted `do_unlike_post/2`, lookups switched to `user_uuid` column |
| `dislike_post/2` | Extracted `do_dislike_post/3`, UUID path resolves `user_id` for dual-write |
| `undislike_post/2` | Extracted `do_undislike_post/2`, lookups switched to `user_uuid` column |
| `post_liked_by?/2` | Integer clause resolves to UUID, query uses `user_uuid` column |
| `post_disliked_by?/2` | Integer clause resolves to UUID, query uses `user_uuid` column |
| `add_mention_to_post/3` | UUID path resolves `user_id` for dual-write |
| `remove_mention_from_post/2` | Split into integer/binary clauses, extracted `do_remove_mention/2`, lookups use `user_uuid` |

**Additional changes:**
- Added `alias PhoenixKit.Utils.UUID, as: UUIDUtils` (matches 14 other modules)
- Added `resolve_user_id/1` helper (UUID → integer, for dual-write)
- Simplified `resolve_user_uuid/1` to use `Auth.User` alias instead of full module path

---

## Concerns: Deprecated Integer Column Usage

These queries use the deprecated integer `user_id`/`assigned_to_id` columns. They work during the dual-write period but will break when integer columns are dropped:

| Module | File:Line | Query |
|--------|-----------|-------|
| Posts | `posts.ex:1382` | `list_user_groups/2` — `g.user_id == ^user_id` |
| Posts | `posts.ex:1447` | `reorder_groups/2` — `g.user_id == ^user_id` |
| Posts | `posts.ex:1750` | `maybe_filter_by_user/2` — `p.user_id` for integers |
| Tickets | `tickets.ex:1019` | `maybe_filter_by_user/2` — `t.user_id` for integers |
| Tickets | `tickets.ex:1035` | `maybe_filter_by_assigned_to/2` — `t.assigned_to_id` for integers |
| Tickets | `tickets.ex:1006` | `count_unassigned_tickets/0` — `is_nil(t.assigned_to_id)` |
| Tickets | `list.ex:316,319` | `matches_assigned?/2` — `ticket.assigned_to_id` |

Not blocking since Phase 4 is future work, but these should be tracked.

---

## What Was Done Well

### Schema Layer (Excellent)
- All 29 Pattern 2 PKs correctly use `{:uuid, UUIDv7, autogenerate: true, source: :id}`
- All 56 `belongs_to` associations audited — every one has correct `references: :uuid` and `type: UUIDv7`
- 10 `has_many` associations correctly received explicit `foreign_key:` to prevent Ecto inferring `xxx_uuid_id`
- 2 composite-PK schemas (`post_group_assignment`, `post_tag_assignment`) correctly received `references: :uuid`
- `@foreign_key_type :id` → `UUIDv7` bug fix in 3 history schemas prevents incorrect type defaults

### Context Layer (Good, one module incomplete)
- **Connections**: Exemplary — all queries use UUID columns, comprehensive dual-write, proper resolve helpers
- **Comments**: Properly migrated — handles both UUID and integer inputs, queries UUID columns
- **Referrals**: Proper dual-write for both code and user FKs
- **Storage**: Clean dual-write, consistent `.uuid` usage
- **Tickets**: Good dual-write, proper resolve helpers
- **Posts**: Creates were correct; like/dislike/mention operations now also handle UUIDs (Bug 3 fix)

### Dialyzer Cleanup
- Removed dead-code clauses in resolve helpers where Dialyzer proved patterns could never match
- Replaced `MapSet` with plain map in category cycle detection to avoid opaque-type tracking issues

---

## Advisory Items (Low Priority)

1. **`@foreign_key_type` inconsistency** — 15 of 29 Pattern 2 schemas don't declare `@foreign_key_type UUIDv7` (the other 14 do). Not a bug since all `belongs_to` have explicit `type:`, but inconsistent. Consider adding it everywhere.

2. **`@moduledoc` examples outdated** — Connection/Block/Follow schemas still show `id: "018e3c4a-..."` in struct examples (should be `uuid:`).

3. **`scheduled_jobs.ex` docstring** — iex examples use `post.id` (should be `post.uuid`).

4. **`uuid_module_status.md` outdated** — Still lists Pattern 2 schemas as `@primary_key {:id, UUIDv7, ...}`. Should reflect the new `{:uuid, UUIDv7, source: :id}`.

---

## Follow-Up Commits

| Commit | Description |
|--------|-------------|
| `5163b56f` | Fix stale `.id` access on Pattern 2 structs in connections template and image downloader (Bugs 1 & 2) |
| `b6541813` | Migrate posts like/dislike/mention functions to accept UUID user identifiers (Bug 3) |

## Remaining Action Items

### Short-term
- [ ] Update `uuid_module_status.md` to reflect Pattern 2 completion

### Advisory (low priority)
- [ ] Add `@foreign_key_type UUIDv7` to 15 Pattern 2 schemas missing it (consistency only)
- [ ] Update `@moduledoc` struct examples in connection/block/follow schemas (`id:` → `uuid:`)
- [ ] Update `scheduled_jobs.ex` docstring examples (`post.id` → `post.uuid`)

### Phase 4 preparation
- [ ] Track deprecated integer column queries (9 instances listed above)
- [ ] When dropping integer columns, update Posts `list_user_groups`, `reorder_groups`, `maybe_filter_by_user`; Tickets `maybe_filter_by_user`, `maybe_filter_by_assigned_to`, `count_unassigned_tickets`, `matches_assigned?`
