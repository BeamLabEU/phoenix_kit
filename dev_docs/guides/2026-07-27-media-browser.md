# MediaBrowser Component

Moved from `AGENTS.md` 2026-07-27 — the embed quick-start stayed there;
this is the full reference.

Embeddable media UI: folder tree, grid/list, upload, search, selection, drag-drop, trash. `lib/phoenix_kit_web/components/media_browser.ex` (+ `.html.heex`). Used by `/admin/media` and any LV needing media picking.

**One-line embed** — the macro injects upload setup, the `"validate"` upload-channel stub, and the `handle_info` delegator:

```elixir
defmodule MyAppWeb.MediaPage do
  use MyAppWeb, :live_view
  use PhoenixKitWeb.Components.MediaBrowser.Embed
  def mount(_params, _session, socket), do: {:ok, socket}
end
```

```heex
<.live_component module={PhoenixKitWeb.Components.MediaBrowser}
  id="media-browser" parent_uploads={@uploads} />
```

`parent_uploads={@uploads}` is required (LiveView `allow_upload` constraint).

**Click behavior** (in order):
1. `select_mode` on → toggle file in/out of selection (toolbar Select button enters this mode).
2. Otherwise → in-place modal (image/video/PDF/icon + metadata + Download). With `admin={true}` its sidebar also links to the file's storage page (`/admin/media/:uuid/storage`). Closes via X/Esc/backdrop. Prev/Next chevrons + ←/→ keys step through current page's `uploaded_files`. If `PhoenixKitComments` is installed AND admin-enabled, a comment thread for `resource_type="file"` renders under metadata, keyed by `file_uuid`.

**Other attrs:**
- `scope_folder_id` — constrain to a virtual root (trash/tree/uploads/move all honor it)
- `on_navigate={:navigate}` — controlled mode; component emits `{MediaBrowser, id, {:navigate, params}}` so parent can `push_patch`. Parent feeds URL params back via `send_update(..., nav_params: ...)`. Reference: `lib/phoenix_kit_web/live/users/media.ex`.
- `initial_params` — apply URL params on first render (avoid root-view flash)

**URL sync (shareable folder deep links)** — added 1.7.126. Don't hand-write the controlled-mode round-trip; opt in via the Embed macro and it's automatic — folder/search/page/view land in the URL as `?folder=<uuid>&q=&page=&view=`, so a reload or a shared link reopens that folder. Folder tracked by uuid (rename-stable; unknown/out-of-scope → root). The `push_patch` only appends the query to the **current** path, so every existing segment (locale, parent resource ids, sub-tab — e.g. `/en/admin/orders/:id/edit/files`) is preserved.

```elixir
use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: true
# non-default component id / multiple browsers:
use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "my-browser"]
```
```heex
<.live_component module={PhoenixKitWeb.Components.MediaBrowser}
  id="my-browser" on_navigate={:navigate} initial_params={@initial_params}
  parent_uploads={@uploads} />
```

Implemented with LiveView lifecycle hooks (`attach_hook(:handle_params)` + `attach_hook(:handle_info)` in `on_mount`), **not** injected clauses — so it composes with a host LiveView that already defines its own `handle_params`/`handle_info` (e.g. a resource-edit page that loads its record in `handle_params`). No clash, nothing to reconcile. Public helpers `MediaBrowser.Embed.parse_nav_params/1` + `build_nav_query/1` for hosts that want a custom round-trip. `/admin/media` (`Live.Users.Media`) is the reference call site. Single-browser-per-page assumed (query keys aren't namespaced per component).

**Selection actions:** `…` dropdown in header → Download (staggered `<a download>` clicks via `MediaDragDrop` hook in `priv/static/assets/phoenix_kit.js`) + Delete (move to trash, or permanently if trash view active).

**Manual wiring** (if not using Embed) — Embed's `@before_compile` injection ensures user-defined clauses match first:

```elixir
def mount(_p, _s, socket), do: {:ok, PhoenixKitWeb.Components.MediaBrowser.setup_uploads(socket)}
def handle_event("validate", _p, socket), do: {:noreply, socket}
def handle_info({PhoenixKitWeb.Components.MediaBrowser, _, _} = msg, socket),
  do: PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
```

**Files:** `media_browser.ex`/`.html.heex`/`embed.ex`, backing context `lib/modules/storage/storage.ex`, JS hooks `priv/static/assets/phoenix_kit.js`.
