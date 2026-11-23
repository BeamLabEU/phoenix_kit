# PR #1055 — Add comments and show_path options to MediaBrowser; own_files_only now covers annotations

**Author:** timujinne · **State:** merged 2026-11-23 (`2192e2840`) · **Reviewed:** 2026-11-23

Reviewed before the merge, from the PR diff. The PR's three new Elixir test files (28 tests,
the integration file `media_canvas_viewer_own_files_test.exs` included, which the author had
not run) and `etcher_tooltip_actions.test.cjs` were run at the PR head against a scratch
database: all pass. #1057 is stacked on this PR. Fixes made on main after the merge are at the end.

**Verdict:** merged. Fix 1 is done on main. Findings 2 and 3 are a CHANGELOG line (at release) and a doc line, still open.

## Checked, fine

- **Reply with comments off.** `comments={false}` refuses `annotation_reply` in a server clause,
  not just by hiding the button.
- **Comments mark.** Every reload path goes through `load_annotations/3`. The `comments_off`
  mark is in `@load_injected_meta_keys`, so it is never stored.
- **Unrendered components.** The composer and `CommentsComponent` are not rendered with comments
  off, so their events cannot be reached.
- **`file_writable?/2`.** It is only reordered and checks the same things.
- **Path column.** The colspan math is right: 8 columns, or 7 without Path.
- **Gettext.** No new strings.

## Findings

1. **IMPROVEMENT - MEDIUM — the thread's inline title editor is offered where its save is now
   always refused.** `build_comment_decorations/1` (`media_canvas_viewer.ex`, used by the
   comments sidebar) gives every decoration `on_save: :annotation_title_updated`.
   `apply_annotation_title_update/3` now requires `can_annotate` and a writable file. So these
   viewers get an editor that saves nothing and says nothing:
   - readonly hosts and pickers
   - managed files
   - `own_files_only` on someone else's file

   Before this PR, readonly and picker viewers could rename a shape from the thread. Fix: pass
   `can_annotate` in and use `on_save: if(can_annotate, do: :annotation_title_updated)`.
   `phoenix_kit_comments` treats `nil` as read-only. Add a render test.
2. **IMPROVEMENT - MEDIUM — a user-visible change on core's own pages.** `Live.Users.Libraries`
   (contributor role) and `Live.Users.Media` (`viewer_uuid`) pass `own_files_only`, so library
   contributors and restricted Media viewers can no longer draw on, re-title or Reply to other
   uploaders' files. A file with a nil uploader becomes read-only for them. This matches
   `LibraryMember`'s contributor rule, so it is right, but it needs a CHANGELOG line at release.
3. **IMPROVEMENT - MEDIUM — "covers the drawings" does not reach the burn endpoint.**
   `AnnotationBurnController.allowed?/3` checks the uploader or `Libraries.can?(:edit)` and
   knows nothing about the embedding's `own_files_only`. Core's contributor case is safe,
   because `can?` refuses there. A host that embeds `own_files_only` for someone who does hold
   `:edit` still accepts a forged burn POST. Say so in the `own_files_only` doc, or record it
   as a follow-up.
4. **NITPICK** — under `own_files_only` on someone else's file, Reply on a shape is refused
   (it creates the master comment), but the sidebar thread still takes comments. This is
   documented, but the line is arbitrary: gate both, or state that comments are not file writes.
5. **NITPICK** — no test renders `MediaBrowser` itself. Dropping the `comments` forwarding
   (`browser.html.heex`) or the `show_path` forwarding to the list view would pass every test.
6. **NITPICK** — `annotation_writable` is computed once (`assign_new`). A role change while the
   viewer is open leaves the tools stale until it is reopened. The handlers re-check on every
   event, so this affects the display only.

## Fixed on main after the merge (2026-11-23)

- **Finding 1.** The second argument of `build_comment_decorations/2` says whether a label
  is editable (default `true`, so `/1` callers keep working). The viewer's template passes
  `@can_annotate`, so a read-only viewer gets `on_save: nil`, which `phoenix_kit_comments`
  treats as read-only. A unit test covers both cases in `media_canvas_viewer_test.exs`.
- **A clash with #1056.** `media_browser_show_path_test.exs` built `ListView` assigns without
  the `mark` assign #1056 added, so all four of its tests raised `KeyError` once both PRs
  were on main. `mark: nil` added.
- The read-only-without-a-user rule from the #1057 review also landed in
  `MediaCanvasViewer.assign_can_annotate/3`. See
  `dev_docs/pull_requests/2026/1057-media-viewer-embed-options/CLAUDE_REVIEW.md`.

## Fixed on main in the follow-up pass

- **Finding 3.** The `:own_files_only` docs (MediaBrowser and MediaViewer) now say the option
  does not reach `AnnotationBurnController`, which checks the uploader or `Libraries.can?(:edit)`
  only — a host embedding `own_files_only` for someone who does hold `:edit` still accepts a
  forged burn POST.
