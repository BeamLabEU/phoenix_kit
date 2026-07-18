# PR #642: Media popup viewer: in-place details, live refresh, collapsible sidebar, folder-view scroll

**Author**: @alexdont
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed — no bugs found; one design note recorded (not fixed,
not blocking)
**Date**: 2026-07-16

## Goal

Five commits, bundled into one PR:

1. Admin `MediaBrowser` clicks now always open the in-place modal viewer
   (previously `admin={true}` navigated straight to `/admin/media/:uuid`);
   the viewer sidebar gains an "Open details page" link instead.
2. Live refresh: `ProcessFileJob` and `AnnotationThumbnailJob` broadcast
   completion over PubSub; open `MediaBrowser`/`MediaCanvasViewer` instances
   swap in the fresh row without a manual reload.
3. Collapsible info sidebar in the popup viewer, persisted per-user.
4. Folder view scrolls as one region (breadcrumbs + hero header + toolbar +
   grid together) instead of the grid having its own nested scrollport.
5. `MarkdownEditor`'s navigation guard flips to opt-in (the old default was
   silently inert — see below).

## Verified correct (no action needed)

### Live-refresh plumbing (PubSub → lifecycle hook → `send_update` fan-out)

Traced the full path: `Storage.broadcast_file_processed/1` and
`broadcast_file_thumbnail_updated/1` publish on `"phoenix_kit:media:files"`
→ `MediaBrowser.attach_file_event_forwarding/1` (invoked once, from
`setup_uploads/1`, only when `connected?`) subscribes and attaches a
`:handle_info` hook that `{:halt}`s on the two message shapes and
`{:cont}`s everything else → `forward_to_browsers/2` fans out via
`send_update` to every id in `socket.assigns[:media_browser_ids]` → each
`MediaBrowser.update/2` clause reloads just that file
(`Storage.get_file/1` + `enrich_files/1`) and patches `:uploaded_files`
(and `:viewer_file` only for the `file_processed` variant, per opts).

This gets several subtle things right that are easy to get wrong:

- **Hook composability.** `attach_hook(:phoenix_kit_mb_file_events,
  :handle_info, ...)` and the separate `url_sync` hooks
  (`:phoenix_kit_mb_url_sync_info`) use distinct names and both fall
  through via `{:cont, socket}` for non-matching messages — confirmed no
  collision with the `Embed` macro's injected
  `handle_info({MediaBrowser, _, _}, socket)` / `{:leaf_changed, _}`
  clauses, or with a host's own `handle_info`.
- **No duplicate subscribe/attach.** `attach_file_event_forwarding/1` only
  runs from inside `setup_uploads/1`'s "not yet set up" branch, and a
  fresh WS-connect `mount/3` gets a brand-new socket/process — so the
  attach-hook-raises-on-duplicate-name failure mode the code comments flag
  can't actually trigger under the documented HTTP→WS lifecycle.
- **Correct LC-remount signal.** The canvas viewer's id
  (`"media-canvas-viewer-#{uuid}-#{w}x#{h}-#{map_size(urls)}"}`) changes
  when `file_processed` swaps in real dimensions/variants, forcing a clean
  remount (fixing the 1000×1000 placeholder) — but `thumbnail_updated`
  passes `viewer: false`, which short-circuits `viewing?` to `false`
  before the swap, so a rebaked annotation thumbnail refreshes the grid
  row only and never touches (remounts) an open annotator session. This
  is exactly the ordering the module doc claims and the new
  `"thumbnail live refresh"` test asserts both halves of it (grid swaps,
  viewer LC id stays put).
- **`enrich_files/1` is self-contained** (own DB queries for
  `FileInstance`s + folder breadcrumb, keyed only by the passed file/
  folder uuids) — safe to call for a single reloaded file with no hidden
  dependency on the original list-rendering assigns.

### Admin click behavior change

Confirmed no other code path depended on `admin={true}` navigating
directly: `rg` for `admin={true}` under `lib/` turns up only the one call
site (`live/users/media.html.heex`), and the pre-existing test suite had
no assertion pinning the old push-navigate behavior (the new `"admin
click_file"` describe block is additive, not a replacement). The single
remaining `click_file` handler correctly branches only on `select_mode`
now; both grid and list-view rows funnel through it.

### Sidebar-toggle button positioning

The new collapse/expand button (`top-3`, `right-14`/`right-3` depending on
state) sits inside the viewer-column's own `relative` wrapper, not the
outer modal's positioning context — so on large screens, "not collapsed"
(`right-3`) lands at the *seam* with the sidebar, not on top of the
modal's separate close button (which is positioned against a different
ancestor). Confirmed by reading the surrounding structure, not just the
diff hunk — no overlap.

### Scroll-region consolidation

The former nested-scroll setup (outer flex column + an independently
`overflow-auto` grid wrapper) is now a single `overflow-auto` container
holding breadcrumbs/hero/toolbar/grid, with the sticky list-view `<thead>`
directly inside it (no intervening `overflow` ancestor) — matches the
comment's claim and is the more correct way to get `position: sticky` to
pin against the actual scrollport.

### `MarkdownEditor` navigation-guard flip

Confirmed the stated prior bug: `data-protect-navigation={@protect_navigation}`
rendered a boolean directly, and the JS hook's `dataset.protectNavigation
=== "true"` check (`priv/static/assets/phoenix_kit.js:1437`) never matched
against Phoenix's rendering of a bare `true`/`false` in a HEEx attribute —
so the guard was inert regardless of the old default. The fix
(`to_string/1` + default `false`) makes the shipped behavior intentional:
hosts that already pass `protect_navigation={true}` now get a *real*
(previously absent) guard — a behavior change, but a bugfix one, and `rg`
found no other in-repo callers of `MarkdownEditor` to audit.

### Rotation-persistence status pill + sidebar-collapse persistence

Both use the established "fresh read + merge, not the parent-passed
struct" pattern already used for the Etcher palette
(`load_user_colors`/`load_user_line_params`), so a concurrent
`custom_fields` write elsewhere isn't clobbered. The `rotation_status_token`
guard on the auto-hide timer correctly keeps the pill up for the full
window after the *last* save in a rapid-rotate burst rather than hiding
after the first timer fires.

### Test coverage

Four new `describe` blocks cover: admin click → popup (not navigation),
rotation persistence + reseed on reopen, sidebar collapse + persistence
across reopen, and both live-refresh broadcasts (thumbnail-only vs.
full-processing, including the "viewer LC id must NOT change" negative
assertion for the thumbnail case). Good-faith read of `Storage.get_file/1`,
`enrich_files/1`, `Auth.get_user_field/2`, `Auth.update_user_custom_fields/2`
confirmed all referenced functions pre-exist; nothing invented.

## Design note (not a bug, not fixed)

**`"phoenix_kit:media:files"` is a single unscoped PubSub topic** — every
connected `MediaBrowser`/embedded picker on the whole install receives
every `file_processed`/`thumbnail_updated` broadcast for every file
anyone uploads anywhere, not just files relevant to that browser's scope.
This is safe (each recipient only acts if the uuid is already in its own
`uploaded_files`/`viewer_file`, so there's no cross-tenant data
disclosure — just a wasted message), but it's a different scoping
posture than e.g. the Notifications system's per-user topic
(`phoenix_kit:notifications:<uuid>`). Fine at current scale for an
admin-facing media library; worth scoping (e.g. by bucket or folder
subtree) if upload volume or connected-session count grows enough for the
fan-out to matter. Not fixing — no reported problem, and scoping now
would be speculative.

## Gate

`mix precommit` — format, compile (warnings-as-errors), `credo --strict`
(8815 mods/funs, 0 issues), `dialyzer` (passed) — all clean on the
merged tree.
