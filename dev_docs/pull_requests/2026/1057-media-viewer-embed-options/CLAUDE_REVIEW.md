# PR #1057 — Add embedding options to the MediaViewer lightbox

**Author:** timujinne · **State:** merged 2026-11-23 (`f1f412d01`, after #1055) · **Reviewed:** 2026-11-23

Reviewed before the merge, at the PR head (`061b4f2b9`). One finding was a bug already on
main before the PR. Fixes made on main are at the end.

**Verdict:** merged. Finding 1 is fixed on main, both halves. Findings 2–7 are still open.

## Checked, fine

- `annotate_only`, `comments`, `authors` and the title-edit gate are enforced on the server as
  well as in the markup. Every `etcher:patch-shape` push goes through `patch_shape/3` →
  `wire_metadata/2`.
- `files` membership is checked, and trashed or system-managed files are skipped
  (`servable?/1`). Private-library files keep the time-window token (`private: private?`),
  with integration tests.
- The catch-all `handle_event` stops crashes on forged events.
- No new JS hooks, so `ADMIN_HOOKS` and `admin_split.test.cjs` are unaffected. No new msgids.

## Findings

1. **BUG - HIGH (on main before this PR) — the lightbox let anyone draw.** The `MediaViewer`
   moduledoc says `current_user` is "nil-tolerant (lightbox falls back to view-only)". It did
   not:
   - `MediaGallery` opens `MediaViewer` even when `readonly`.
   - `MediaViewer` passed no `can_annotate`.
   - `MediaCanvasViewer.assign_can_annotate/3` then gave a file of a site library
     `can_annotate: true`, because only user libraries and managed libraries are checked.

   So an anonymous visitor of a readonly gallery's lightbox got the drawing toolbar, and
   `etcher:annotations-changed` created and deleted shapes on Media-library files with
   `creator_uuid` nil. Deleting a shape cascades its discussion away.
   - **Anonymous half: fixed on main**, below.
   - **Signed-in half: fixed on main after the merge.** A *signed-in* visitor of a readonly
     gallery could still draw, because the gallery said nothing. `media_gallery.html.heex` now
     passes `can_annotate={not @readonly}` to the `MediaViewer` attribute this PR added.
2. **IMPROVEMENT - MEDIUM (on main, undercuts the new `authors` promise) — dragging a marker
   with a discussion overwrites its byline.** `curate_row/2` merges the first reply's author
   into `metadata["comment_author"]`. `persistable_attrs/2` keeps that key, because
   `@load_injected_meta_keys` deliberately leaves it out. A drag then stores the first
   commenter's name in place of the person who drew the marker. The new authors test covers
   only a marker with no discussion. Fix: inject the preview author under its own key, add that
   key to `@load_injected_meta_keys`, and update Etcher's header to match.
3. **IMPROVEMENT - MEDIUM — more database reads on every parent render.** `update/2` now runs
   `assign_neighbours/1` as well as `curate_file/2`, so each parent render adds two or more
   `get_file` walks. That contradicts the comment saying this is "worked out when the file
   changes". Recompute only when `current_uuid` or `files` changed, or fix the comment.
4. **NITPICK** — `write_scope` has no effect in the lightbox: there is no `details_path`,
   `edit_target` or `persist_rotation` for it to gate. The "Embedding for an outside person"
   recipe presents it as a restriction.
5. **NITPICK** — the `:comments` doc should carry the same offline-protection caveat as
   `:authors`. Shapes go out without `comment_count`, so `offline_protect="comment_count"`
   protects nothing.
6. **NITPICK** — `refresh_file_comments/1` checks `comments` but not `authors`. With
   `authors={false}` it sends `send_update` to a `CommentsComponent` that is not rendered.
7. **NITPICK** — `MediaGallery`'s behaviour changes (an out-of-selection `preview_image` and a
   trashed file now show "File not found"). That wants a CHANGELOG line at release.

## Fixed on main (2026-11-23)

### Anonymous visitors (before the merge)

`MediaCanvasViewer.assign_can_annotate/3` now also requires a `current_user`: nobody signed in
changes a drawing, whatever the host passed. The `etcher:annotations-changed` boundary reads
that assign, and `annotation_reply` already required a user. Board mode follows the same rule:
no host renders a board without a user, and a nil user wrote creator-less rows there too. The
`:can_annotate` and `:current_user` docs say so. `media_canvas_viewer_board_test.exs` now
renders its "default host" case with a signed-in user and gains a test that a nil user gets
locked shapes and no tools.

### After the merge

- **The gallery.** `media_gallery.html.heex` passes `can_annotate={not @readonly}`.
  `media_gallery_test.exs` finds the lightbox component in the rendered tree and asserts
  `false` for a readonly gallery and `true` otherwise.
- **Tests broken from the start.**
  - `test/integration/.../media_canvas_viewer_authors_test.exs` returned `file:` from its
    `setup`, a field ExUnit reserves, so all three of its tests raised before running. It now
    returns `stored_file:`, and they pass. The PR body said it had not been run.
  - `media_canvas_viewer_embed_options_test.exs`'s `updated/2` helper now passes a signed-in
    user by default, because nobody signed in never draws. One assertion pins the nil case.
