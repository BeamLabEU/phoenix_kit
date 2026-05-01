# PR #499: Updated the media browser component

**Author**: @alexdont
**Reviewer**: Claude Opus 4.7 (1M)
**Status**: ✅ Merged (2026-04-20)
**Commit**: `2d8a85ef` (merge), PR head `e4fe81c7`
**Branch**: `dev` → `main`

## Goal

Follow-up on PR #497 that lands several independent improvements to `MediaBrowser`:

1. One-line `use PhoenixKitWeb.Components.MediaBrowser.Embed` macro so parent LiveViews no longer have to hand-wire `allow_upload`, the `"validate"` stub, and the `handle_info` delegator.
2. Site-icon (favicon) + default tab title settings, and move project logo from the Authorization settings page to the main Settings page.
3. UX polish: unified card wrapping sidebar+content, toggleable search bar, picker vs admin click behaviour via `admin={true|false}`, selection-menu with bulk Download + Delete, drag-drop upload at any folder level.
4. Fixes: stale `data-media-view` CSS, scope-root query now shows only direct children, missing `recursive_ctes(true)` on scoped trash, scope-root new-folder form alignment.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_web/components/media_browser.ex` | `setup_uploads/1`, `parent_progress/3`, `handle_parent_info/2`, `pending_upload` branch in `update/2`, `admin` attr gating `click_file`, `download_selected` event, `show_search` toggle, scope_folder_name wiring |
| `lib/phoenix_kit_web/components/media_browser/embed.ex` | **New.** Embed macro: `on_mount` for `setup_uploads`, `@before_compile` injects fallback `"validate"` event + MediaBrowser `handle_info` delegator |
| `lib/phoenix_kit_web/components/media_browser.html.heex` | Card wrapper around sidebar+content; all `@uploads` → `@parent_uploads`; toggleable search; `…` selection dropdown with Download+Delete; scope_folder_name used in sidebar Root label + header; file-type badge-based list view |
| `lib/modules/storage/storage.ex` | Scope-root file query returns only direct children instead of full subtree; search path extracted to `scope_subtree_query/1`; `recursive_ctes(true)` added to trash subtree query (was missing) |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | Reads `default_tab_title` + `site_icon_file_uuid` settings, renders dynamic `<.live_title default=...>` and `<link rel="icon">` |
| `lib/phoenix_kit_web/live/settings.ex` / `.html.heex` | Project Logo, Site Icon (with tab-preview mockup), Default Tab Title form fields; `open_media_selector`, `clear_image`, `media_selected` handlers |
| `lib/phoenix_kit_web/live/settings/authorization.html.heex` | Removed the Logo Image field (moved to main settings) |
| `lib/phoenix_kit_web/live/users/media.ex` / `.html.heex` | Migrated to `use MediaBrowser.Embed`, passes `admin={true}` + `parent_uploads={@uploads}` |
| `priv/static/assets/phoenix_kit.js` | `MediaDragDrop`: `pushEventTo(this.el, …)` instead of `pushEvent`, new `download_files` handler; `FolderDropUpload`: ignore internal drags by checking `dataTransfer.types.includes("Files")` |
| `AGENTS.md` | New "MediaBrowser Component" section documenting embed + admin attr |

## Implementation Details

### Upload-channel routing across parent and LiveComponent

This is the core architectural trick. LiveView's upload channel sends progress/validate events to the socket that called `allow_upload/3` — which must be the parent LiveView, not the LiveComponent. The PR threads the flow as:

1. `Embed.on_mount/4` calls `MediaBrowser.setup_uploads/1` on the **parent** socket. The progress callback is `&__MODULE__.parent_progress/3` — also runs on the parent.
2. On `update/2` first-render, the component emits `send(self(), {__MODULE__, :register_component, id})`. Since LiveComponents run in the parent LV process, `self()` is the parent — the message is received by `handle_parent_info/2` which accumulates component ids into `socket.assigns[:media_browser_ids]`.
3. When an upload finishes on the parent, `parent_progress/3` copies the temp file to `System.tmp_dir!()` and sends `{__MODULE__, :process_pending_upload, path, entry}` to itself. `handle_parent_info/2` fans it out via `send_update(MODULE, id: id, pending_upload: {path, entry})` to each registered component.
4. `update/2`'s `Map.has_key?(assigns, :pending_upload)` branch runs `process_pending_upload` in the component's state, using its own `current_folder_uuid` and `scope_folder_id`.

Clean separation; handles multiple MediaBrowsers embedded on the same page. The `@before_compile`-injected fallbacks let user-defined `handle_info`/`handle_event` clauses still win for other patterns.

### Scope root: direct children only

`build_scope_file_query/4` used to return the full subtree when `folder_uuid` was nil. The PR narrows that to direct children so moving a file into a subfolder visually removes it from the scope-root view. Full-subtree walk is preserved via `scope_subtree_query/1` but only when a search term is present. Consistent with what users expect from a folder UI.

### Site icon + title

`layout_wrapper.ex` pulls `default_tab_title` and `site_icon_file_uuid` from the cached settings store on every render. The favicon URL is `URLSigner.signed_url(uuid, "thumbnail")`, so it's a signed pre-signed S3 URL with a TTL — this means **every page load re-renders the `<link rel=icon>` with a different signed URL** (no cache key stability). Modern browsers typically don't re-fetch favicons unless they change, but the behaviour is worth noting. See "Observations" below.

## Observations

### ~~BUG - MEDIUM — Multi-browser page upload crashes on second component~~ (fixed)

When two `MediaBrowser`s are mounted on the same page (e.g., a picker modal + the admin page), `handle_parent_info({_, :process_pending_upload, path, entry}, socket)` dispatched `send_update(..., pending_upload: ...)` to every registered component id. Each component's `update/2` ran `process_pending_upload` → `process_single_upload` → `File.rm(path)`. After the first component processed the upload, the temp file was deleted; the second then hit:

```elixir
{:ok, stat} = Elixir.File.stat(path)  # MatchError: {:error, :enoent}
```

**Fix applied** (`media_browser.ex:handle_parent_info/2`, `:process_pending_upload` clause): the first registered component receives the original temp path; every other component gets a per-id copy (`"#{path}-#{id}"`). Each component now owns and deletes its own temp file. The hash-based dedup in `store_file_in_buckets` still collapses to a single persisted record, and each component independently calls `reload_current_page/1` so they all see the new file.

### BUG - LOW — Favicon URL rotates every render

Because `signed_url/2` produces a short-lived signed URL and the `<link rel="icon">` is rendered on every page render, the `href` changes on every navigation. Browsers usually de-dup by the resolved resource but there's no guarantee — worst case, the favicon re-fetches on each full page load. Two reasonable fixes: cache the signed URL in ETS keyed by uuid+variant with a shorter TTL than the sig, or use a public/unsigned variant for icons.

### IMPROVEMENT - MEDIUM — Scope-bypass comment in `maybe_set_folder/2`

```elixir
# Bypass scope check on initial placement: new uploads start at root
# (folder_uuid: nil) which fails the scope gate. The target folder is
# already constrained by current_folder_uuid || scope above, so this is safe.
if folder_uuid, do: Storage.move_file_to_folder(file.uuid, folder_uuid, nil)
```

The comment is correct for the intended flow (`folder_uuid = current_folder_uuid || scope` at line 1628), but passing `nil` for the scope param of `move_file_to_folder/3` is load-bearing security behaviour hidden behind a comment. If the callsite changes (e.g., someone refactors `folder_uuid` derivation), the bypass silently becomes "ignore scope entirely." Safer: compute the bypassed value explicitly at the call site (e.g., `scope_for_initial_placement(socket)`) so the function name documents the intent, or add a defensive assertion that the derived folder is within scope before dropping the scope argument.

### IMPROVEMENT - LOW — N file uploads → N full page reloads

Each `pending_upload` branch calls `reload_current_page()` + `put_flash`. A user dropping 10 files triggers 10 serial reloads and 10 overlapping flash messages. Worth debouncing: batch pending uploads per render cycle, or only reload on the last entry of a drop group (entries are available via `@parent_uploads.media_files.entries`).

### IMPROVEMENT - LOW — `Embed` macro always calls `allow_upload(:media_files, …)`

Any LiveView that `use`s the Embed pays the upload setup cost and reserves the `:media_files` upload name, regardless of whether the browser is actually rendered on that page. For a single-use library this is fine, but if a host app wants its own `:media_files` upload elsewhere, it will conflict. A `use PhoenixKitWeb.Components.MediaBrowser.Embed, upload: :pk_media` option (or nested socket assigns) would future-proof this.

### ~~BUG - HIGH — Embed macro's `handle_info` misses the 4-tuple from `parent_progress/3`~~ (fixed)

The macro (`embed.ex:66-72`) injects:

```elixir
def handle_info({PhoenixKitWeb.Components.MediaBrowser, _, _} = msg, socket) do
  PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
end
```

That pattern matches **3-element** tuples only. But `parent_progress/3` (`media_browser.ex:320`) sends:

```elixir
send(self(), {__MODULE__, :process_pending_upload, persistent_path, entry})
```

— a **4-element** tuple. The Embed's clause will not match, so Phoenix logs `UnhandledInfo` and the upload never reaches `handle_parent_info/2` → `send_update(pending_upload: ...)` → the component. Drag-drop uploads on `/admin/media` (the one caller that uses the macro) effectively rely on this path.

The `:register_component` message is a 3-tuple and goes through fine, which is probably why superficial testing (click "Add Media" dialog) worked — the registration + send_update + legacy `handle_progress/3` flow still exists via `@parent_uploads.media_files` entries. But drag-drop via `FolderDropUpload` hook — the feature this PR specifically enables "at any folder level" — is silently broken because it depends on the 4-tuple path.

**Fix applied:** the message was reshaped to a 3-tuple `{__MODULE__, :process_pending_upload, {persistent_path, entry}}` in `parent_progress/3`, and the matching `handle_parent_info/2` clause was updated to destructure the wrapped payload. Now the Embed macro's single `{Mod, _, _}` clause catches every variant.

Still worth adding: an integration test that drag-drops a file onto a MediaBrowser embedded via the Embed macro and asserts the file lands in storage.

### NITPICK — `default_tab` + `site_icon_uuid` fetched on every render

`layout_wrapper.ex`:

```elixir
<% default_tab = PhoenixKit.Settings.get_setting_cached("default_tab_title", "") %>
<% site_icon_uuid = PhoenixKit.Settings.get_setting_cached("site_icon_file_uuid", "") %>
```

`get_setting_cached` is cheap (ETS) but doing it inline in a layout template means you pay it per render. Pulling these into an `assign` in the `on_mount` hook that already populates layout data would be cleaner and makes the settings swap-able in tests.

## Post-Merge Follow-Up

Fixes applied in a follow-up commit on `dev`:

- **HIGH**: Reshape `parent_progress/3` message to 3-tuple `{Mod, :process_pending_upload, {path, entry}}` and update `handle_parent_info/2` to destructure the payload, so the Embed macro's single `{Mod, _, _}` catch-all clause matches both `:register_component` and `:process_pending_upload`.
- **MEDIUM**: In `handle_parent_info({_, :process_pending_upload, _}, …)`, copy the temp file per additional registered component (`"#{path}-#{id}"`) so each component deletes its own file and the crash on the shared path is eliminated.

`mix compile --warnings-as-errors`, `mix format`, and `mix credo --strict` pass.

### Still outstanding / worth follow-up

- [ ] Integration test: drag-drop upload via the Embed macro on a LiveView that does not set `admin={true}`
- [ ] Integration test: two `MediaBrowser`s on the same page both see a drag-drop upload
- [ ] Favicon re-fetch behavior under real browser (`BUG - LOW` above)
- [ ] Unit test for `build_scope_file_query/4` when `search` is blank vs non-blank at scope root

## Related

- Previous: [#497 Media browser improvements](../497-media-browser-improvements/)
- Previous: [#495 Media browser component](../495-media-browser-component/)
