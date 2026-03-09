# PR #397 — Publishing module: editor UX, AI translation, and collaborative editing fixes

**Author:** Max Don
**Base:** dev
**Commits:** 8
**Files changed:** 21 (+1229, -1046)

## What

1. **Clean up publishing module:** Fix UUID routing bugs (slug vs UUID mix-ups in `create_version`, PubSub broadcasts, translation status), remove dead code (filesystem path references, backward-compat fallbacks in workers, unused function parameters), standardize identifier naming from `post_path`/`post_slug` to `post_identifier`.

2. **Optimize DB queries:** Replace N+1 `list_times_on_date` queries with pre-computed `date_counts` map. Add `ListingCache` for dashboard group insights. Replace per-translation status UPDATEs with single bulk UPDATE. Use incremental post replacement in `change_status`/`toggle_status` instead of full reload.

3. **Rework editor layout:** Two-column design with content-first (title + markdown editor on left, metadata sidebar on right). Mobile stacks content on top.

4. **Rework AI translation:** Replace hardcoded translation prompt with AI prompt system integration. Convert slidedown UI to modal dialog. Add prompt and endpoint selectors. Add "Generate Default Prompt" button. Show AI Translate button on version switcher row. Translation progress persists across page refreshes via Oban job query on mount.

5. **Replace primary language banner:** Swap full-width informational banner for a compact tooltip on the "Primary:" label in the language switcher.

6. **Add skeleton loading UI:** Instant visual feedback (skeleton placeholders) when switching between languages in the editor.

7. **Fix collaborative editing:** Spectator initial sync now works (was dead code path), lock promotion properly updates the JS editor state, lock expiration timer starts even on failed DB reads.

8. **Fix admin sidebar highlighting** for publishing group pages.

## Why

- The publishing module accumulated bugs from the filesystem-to-UUID migration — slug and UUID identifiers were mixed up in several code paths, causing silent failures in version creation, PubSub broadcasts, and translation status updates.
- Listing and index views had N+1 query patterns and redundant DB calls that degraded with many posts.
- The editor layout prioritized metadata over content, making the writing experience feel cluttered.
- AI translation used a hardcoded prompt with no user customization, and progress was lost on page refresh.
- Collaborative editing had dead code in spectator sync and bugs in lock promotion that prevented the JS editor from receiving content updates.

## How

### Commit 1: UUID routing cleanup
- Fix `create_new_version` passing slug instead of UUID to `create_version_in_db`
- Fix PubSub handlers to match by slug OR UUID
- Standardize `post_path`/`post_slug` to `post_identifier` across PubSub module
- Remove dead code: `resolve_db_post`, filesystem path references, worker backward-compat fallbacks

### Commit 2: DB query optimization
- `ListingCache` for dashboard group insights
- Pre-computed `date_counts` map replaces per-post `list_times_on_date`
- Bulk UPDATE for translation statuses
- Incremental post replacement instead of full list reload

### Commit 3: Sidebar highlighting fix
- Correct active state detection for publishing group pages in admin nav

### Commit 4: Two-column editor layout
- Content (title + editor) on left, metadata sidebar on right
- Responsive: stacks vertically on mobile

### Commit 5: AI translation rework
- AI prompt system integration with prompt selector
- Modal UI replacing slidedown
- Translation progress recovery via `Oban.Job` query on mount

### Commit 6: Primary language tooltip
- Replace banner with tooltip on "Primary:" label

### Commit 7: Skeleton loading
- Skeleton placeholders during language switch

### Commit 8: Collaborative editing fixes
- Wire up spectator initial sync (was dead code)
- Lock promotion pushes content to JS editor
- Lock expiration timer starts even on failed DB reads
