# The upload manager

`PhoenixKitWeb.Components.Core.UploadManager` — a queue, a speed readout and
per-file controls for any Phoenix LiveView upload. Used by the media browser and
both media pickers; usable anywhere else, and portable (see the end).

## For an AI agent: how to add this to a page

Read this section and the module doc of `PhoenixKitWeb.Components.Core.UploadManager`;
nothing else is needed. In a PhoenixKit app there is nothing to install: the
component is imported by `use PhoenixKitWeb, :live_view` / `:live_component`,
the script is part of `phoenix_kit.js`, and the route for chunks is mounted.

1. **Mount** (the one call; `accept` and `max_file_size` are yours to decide,
   LiveView's default size limit is 8 MB, which is almost never what you want):

   ```elixir
   alias PhoenixKitWeb.Components.Core.UploadManager
   alias PhoenixKitWeb.ResumableUpload

   socket
   |> UploadManager.allow_upload(:photos,
     accept: ~w(.jpg .png),
     max_entries: PhoenixKit.Modules.Storage.max_upload_files(),
     max_file_size: PhoenixKit.Modules.Storage.max_upload_size_mb() * 1_000_000,
     progress: &handle_progress/3
   )
   ```

2. **Store** in the progress callback. `consume/3` is `consume_uploaded_entry/3`
   that also deletes the assembled file once your function returns `{:ok, _}`:

   ```elixir
   def handle_progress(:photos, entry, socket) do
     if entry.done? do
       ResumableUpload.consume(socket, entry, fn %{path: path} ->
         {:ok, MyApp.store!(path, entry.client_name)}
       end)
     end

     {:noreply, socket}
   end
   ```

3. **Render**:

   ```heex
   <.upload_manager id="photos" upload={@uploads.photos}
     max_concurrent={PhoenixKit.Modules.Storage.max_concurrent_uploads()} />
   ```

   A page that already has its own `<.live_file_input>`: add `dropzone={false}`.
   In a LiveComponent, add `cancel_event="cancel_upload" cancel_target={@myself}`
   and answer that event with `cancel_upload/3`.

4. **Optional**: `notify_event="batch_done"` (an event to your LiveView when a
   batch ends), `position={:bottom_left}`, `layout={:inline}`,
   `remember_scope={user_uuid}`. See "Telling the page" below.

Mistakes to avoid: calling `consume_uploaded_entry/3` directly on a resumable
upload (the assembled file is then never deleted; use `ResumableUpload.consume/3`),
leaving out `max_file_size`, giving two uploads on one page the same component
`id`, and rendering the component inside something with `phx-update="ignore"`.

Check it: `node --test test/js/upload_manager_*.test.cjs` (the script),
`mix test test/phoenix_kit_web/components/core/upload_manager_test.exs` and
`test/phoenix_kit_web/uploads` (the component, the plug). Real examples to
copy: `media_selector.ex` (a LiveView) and `media_selector_modal.ex` (a
LiveComponent). In a browser, a pick must show the panel; if files upload with
no panel, the hook is not registered.

## Quick start (in any other Phoenix 1.8 / LiveView 1.x project)

Tested by wiring it into a fresh `mix phx.new` app from this section alone.

Requirements: Tailwind, daisyUI 5 (the panel uses `btn`, `badge`, `progress`,
`card`) and the Heroicons Tailwind plugin (`hero-*` classes). Phoenix 1.8's
generators include all three.

1. Copy `lib/phoenix_kit_web/components/core/upload_manager.ex` to
   `lib/my_app_web/components/upload_manager.ex` and rename the module to
   `MyAppWeb.UploadManager`. Two lines need changing:
   * `use Gettext, backend: PhoenixKitWeb.Gettext` becomes
     `use Gettext, backend: MyAppWeb.Gettext` (the generated backend works
     unchanged; the labels are plain English msgids, so untranslated they show
     as written).
   * `import PhoenixKitWeb.Components.Core.Icon` becomes
     `import MyAppWeb.CoreComponents, only: [icon: 1]` (the stock `icon/1`;
     `only:` avoids a clash with the import already in `html_helpers`).
   The `PhoenixKitWeb...` names left in the moduledoc are only text.
   Keep the file under `lib/my_app_web/` so Phoenix 1.8's
   `@source "../../lib/my_app_web"` in `app.css` makes Tailwind scan it.
2. In `html_helpers` of `my_app_web.ex`, right after the `CoreComponents`
   import, add `import MyAppWeb.UploadManager, only: [upload_manager: 1]`.
3. Copy `priv/static/assets/phoenix_kit_upload_manager.js` to `assets/js/`.
   In `assets/js/app.js`, above `new LiveSocket(...)`, add
   `import "./phoenix_kit_upload_manager.js"`, and pass
   `hooks: {...colocatedHooks, ...window.PhoenixKitHooks}`. The script creates
   `window.PhoenixKitHooks` and sets `UploadManager` on it.
4. A complete minimal LiveView:

   ```elixir
   defmodule MyAppWeb.UploadLive do
     use MyAppWeb, :live_view

     def mount(_params, _session, socket) do
       {:ok,
        socket
        |> allow_upload(:photos,
          accept: :any,
          max_entries: 50,
          auto_upload: true,
          progress: &handle_progress/3
        )
        |> MyAppWeb.UploadManager.attach()}
     end

     def handle_progress(:photos, entry, socket) do
       if entry.done? do
         consume_uploaded_entry(socket, entry, fn %{path: path} ->
           dest = Path.join(System.tmp_dir!(), entry.client_name)
           File.cp!(path, dest)
           {:ok, dest}
         end)
       end

       {:noreply, socket}
     end

     def render(assigns) do
       ~H"""
       <Layouts.app flash={@flash}>
         <.upload_manager id="photo-uploads" upload={@uploads.photos} max_concurrent={5} />
       </Layouts.app>
       """
     end
   end
   ```

   Add `live "/upload", UploadLive` to the router.

Check it works: on first render you will see `phx-hook="UploadManager"`,
`#photo-uploads-wrap` and `#photo-uploads-entries`; the panel stays hidden and
the `data-pk-upload-entry` rows appear only after files are picked. In a
browser, pick several files: a panel shows speed and a row per file. If files
upload with no panel, the hook is not registered (look for `UploadManager` in
`liveSocket.hooks`).

## Why it exists

LiveView's browser uploader starts every picked file at once, each on a channel
of its own. A hundred files is a hundred simultaneous transfers: slower for all
of them, heavy on the server, and nothing to pause, reorder or skip. The
manager sits in front of the upload's file input, holds the files in the
browser and hands them to LiveView a few at a time.

## What it does

* **Auto concurrency.** One file goes first, alone, as a speed probe. The queue
  then adds a transfer at a time while the total speed keeps rising by at least
  15%, and backs off when an extra transfer stops paying for itself. It never
  exceeds `max_concurrent`, and looks again every 20 s once settled.
* **A panel** (floating in the corner of the screen, or inline) with the number
  in flight, the live total speed, the time left, how many are done, and every
  file with its state. What needs attention or is moving is listed first.
* **Per-file controls:** pause / resume, skip / add back, upload this next,
  cancel, retry. Pause all, cancel all, retry failed, clear finished.
* **Self-healing.** A file that has not started within 6 s, or has shown no
  progress for 20 s, is cancelled and sent again once, then reported as failed.

**The panel.** Floating, it sits in the bottom-right corner (`position={:bottom_left}`
for the other) and spans the bottom of a phone. A new batch opens it; while
files are sending it has no close button (Cancel all asks first); a batch that
ends cleanly shrinks to a one-line "✓ 12 uploaded" with a dismiss button, and
one that ends with a failure stays open with Retry failed. Only the summary
line is announced to screen readers, not the changing speed.

**Pausing a file that is already sending stops it and sends it again from the
start when resumed.** LiveView's upload channel cannot resume. A file still
waiting is simply held.

## Using it

```elixir
# mount
socket
|> allow_upload(:photos, accept: :any, max_entries: 100, auto_upload: true,
     progress: &handle_progress/3)
|> PhoenixKitWeb.Components.Core.UploadManager.attach()
```

```heex
<.upload_manager id="photo-uploads" upload={@uploads.photos} max_concurrent={5} />
```

Consume finished entries in the `progress:` callback as usual — the manager
counts an entry as done when it is consumed (or `done?` while still listed).
`attach/1` answers the panel's cancel button for every upload on the page, so
the LiveView needs no event of its own. Attributes are documented in the module.

`import PhoenixKitWeb.Components.Core.UploadManager, only: [upload_manager: 1]`
is part of `use PhoenixKitWeb, :live_view` / `:live_component` already.

### Beside an input the page already has

`dropzone={false}`, and `scope="parent"` (the default then) so the manager
listens on the element the component is placed in: it takes whatever reaches
that upload's input, whether picked, dropped by another hook, or fed back by the
resume hook. The media browser does exactly this.

### Inside a LiveComponent

Uploads on a component's own socket: pass `cancel_event="cancel_upload"` and
`cancel_target={@myself}`; the event receives `%{"ref" => ref, "name" => name}`
and calls `cancel_upload/3`. (Uploads on the parent LiveView need only
`attach/1` there.)

## Resumable uploads (optional)

LiveView's own uploader sends a file in one go and cannot resume it. With
`PhoenixKitWeb.ResumableUpload` the file travels in chunks the server keeps
(`resumable_upload.ex`, one file: a Plug, the store, and the `external:`
function). The manager then:

* **pauses a file where it is** and resumes from there (the chunk on its way
  is dropped and sent again; at most one chunk, 2 MiB by default, is repeated);
* **retries a dropped connection** by itself (1 s, 2 s, 4 s ... 30 s, six
  tries; offline waits for the browser to come back) and says "Reconnecting";
* **carries on after a reload**: the same file picked again, by the same
  person, is the same upload, and the server says how much it already has.
  In the media browser the files the page stashed before it went away are
  offered again with Resume, so even the re-pick is one click (up to the
  stash's size limit);
* **checks every chunk** (SHA-256 when the browser has Web Crypto), writes it
  only at the exact end of the file (a repeated or late chunk gets `409` and
  the right offset), and never writes past the declared size.

`UploadManager.allow_upload/3` turns it on by default (`resumable: false` opts
out); the component notices by itself. Finished entries are consumed with
`ResumableUpload.consume/3`, as in the agent section above.

`consume/3` is `consume_uploaded_entry/3` that also deletes the assembled file
when the callback returns `{:ok, _}`; the meta's `path` is that file, so a
callback written for LiveView's own uploader needs no change. PhoenixKit mounts
the plug itself (`/api/resumable-uploads`) and the media browser, the selector
page and the picker use it unless an admin turns off *Resumable uploads* in
Settings -> Media.

Anywhere else:

1. Copy `lib/phoenix_kit_web/uploads/resumable_upload.ex` (needs only `plug`,
   `phoenix` and `jason`; rename the module; `external/1` takes `base:` and
   `owner:` so no PhoenixKit call is left in use).
2. Mount it: `forward "/uploads", MyAppWeb.ResumableUpload` in the router, and
   pass `base: "/uploads"` to `external/1`. The endpoint's `Plug.Parsers` must
   let `application/octet-stream` through (`pass: ["*/*"]`, the generated
   default). The signed token uses the endpoint's `secret_key_base`.
3. `owner:` is `fn socket -> some_id end`; no owner, no upload. The default
   reads PhoenixKit's signed-in user.

Limits to know:

* Partial files live in `config :phoenix_kit, :resumable_upload_dir` (default
  `System.tmp_dir!/phoenix_kit_resumable`) and are swept after a day without a
  chunk. Point it at a disk with room for the largest batch.
* Chunks go to one server: behind a load balancer without sticky routing,
  chunks of a file must reach the same node (the partial file is local).
* Browsers only reopen files the page stashed or the user picks again; none can
  read a path by itself.
* Cancelling a file in the manager deletes its partial file; closing the tab or
  a failure does not (that is the point). One exception: after a reconnect the
  manager no longer knows the old transfer's job, so cancelling a requeued file
  leaves its old partial to the daily sweep.

## Telling the page

Two ways to hear what the manager does, neither needs the page to read its
internals:

* **DOM events**, fired on the panel and bubbling, with details in
  `event.detail`: `pk-upload:file-done` and `pk-upload:file-failed`
  (`{name, size, key, error}`), and `pk-upload:batch-complete` when the last
  thing in flight ends (`{done, failed, cancelled, skipped, total, bytes}`).
* **An event to the LiveView**: `notify_event="batch_done"` pushes
  `batch-complete`'s detail as string keys to `handle_event("batch_done", params, socket)`;
  `notify_target={@myself}` sends it to a component instead.

A retry that fails again is announced again; a file is never announced twice
for the same outcome.

## Unfinished uploads

When a page is reloaded, closed or loses the network while files are waiting or
sending, the manager remembers (in this browser's `localStorage`: names and
sizes, no bytes, for a day, per page, upload and `remember_scope`) which files
did not make it. On the next visit the panel opens as "Unfinished uploads":
*Didn't finish: a.mp4, b.mov. Choose the files again to continue.* with a
*Choose files* button. Picking a file again (the same name, size and date)
takes it off the list, and with resumable uploads it carries on from where the
server has it. The X forgets the list. `remember={false}` turns it off; the
media browser does, because it has its own panel for this.

## How the script and the markup talk

The component renders one `<span data-pk-upload-entry>` per LiveView upload
entry (`data-ref`, `data-key`, `data-size`, `data-progress`, `data-done`,
`data-error`). The script reads those and nothing else: it matches its queued
files to entries by the file's key (`name|size|lastModified`, the one the server
computes), and cancels by pushing one event. The panel's DOM is
`phx-update="ignore"`, built from a `<template>` the component renders, so every
class is in HEEx where the host's Tailwind scans it, and every string is
translated on the server and handed over in `data-labels`.

## LiveView behaviour worth knowing

Found while building it, handled in the script:

* **Overlapping preflights lose entries.** Two files handed to the input in
  quick succession can leave an entry registered on the server that the browser
  never sends. The manager hands over one batch at a time and waits for it to
  start moving.
* **A consumed or cancelled entry can come back.** The browser's form-change
  message listing the file is built before the server's reply that dropped it,
  and the server adds any entry it is told of and does not know. The re-added
  entry sits at 0% for good and holds a `max_entries` slot. The manager cancels
  entries belonging to files it has finished or stopped, a few times.
* **`cancel_upload/3` can crash the LiveView.** It raises when the entry is
  already gone and *exits* when the entry's channel has just ended. `attach/1`
  rescues both.
* **A file handed over while the socket is down is dropped silently.** LiveView's
  input handler returns early when the view is not connected, so no entry ever
  appears. The manager feeds nothing while disconnected, gives no verdict for
  time spent offline, and on reconnect sends again what never showed up.
* **A File LiveView has handled cannot be fed again.** It carries LiveView's
  stamp and is ignored. Every re-send (a retry, a stall, a reconnect) hands over
  a fresh `File` over the same bytes.
* **The upload's ref changes after a rejoin.** The new LiveView process
  registers the upload again, so the input's `data-phx-upload-ref` and the
  panel's `data-upload-ref` (updated even though the panel is `phx-update="ignore"`)
  differ from what they were at mount. The script reads the ref when it needs it.
* **A rejoin drops every entry.** The new process has none of the old one's
  entries, so a row that vanishes is not proof the host consumed it. While the
  socket is down the script reaches no "done" verdict, and on reconnect it stops
  the old transfers and sends the unfinished files again as fresh `File`s; a
  resumable one carries on from the offset the server kept (same name, size and
  date, same upload id).
  If the host consumed an entry just before the drop, the file can be stored
  twice: the manager prefers a duplicate to a loss.

## Taking it to another project

Two files (three with resumable uploads, see above), nothing else: `upload_manager.ex` (needs `Phoenix.Component`, a
gettext backend and an `icon/1` component) and
`priv/static/assets/phoenix_kit_upload_manager.js`, which registers the hook
`UploadManager` in `window.PhoenixKitHooks`. Import the script in `app.js` and
spread `window.PhoenixKitHooks` into the `LiveSocket` hooks. PhoenixKit's own
bundle (`phoenix_kit.js`) carries a verbatim copy of the script, kept in step by
`test/js/upload_manager_bundle.test.cjs`.

## Tests

`test/js/upload_manager_queue.test.cjs` (the queue policy, run against a
simulated connection), `test/js/upload_manager_bundle.test.cjs`,
`test/phoenix_kit_web/components/core/upload_manager_test.exs` and the media
browser / selector integration tests.
