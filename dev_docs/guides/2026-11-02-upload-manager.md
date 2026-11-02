# The upload manager

`PhoenixKitWeb.Components.Core.UploadManager` — a queue, a speed readout and
per-file controls for any Phoenix LiveView upload. Used by the media browser and
both media pickers; usable anywhere else, and portable (see the end).

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

## Taking it to another project

Two files, nothing else: `upload_manager.ex` (needs `Phoenix.Component`, a
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
