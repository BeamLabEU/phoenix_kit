# PR #1023 — Let <.audio_recorder> start from a page's button and fill a page's upload

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; two bugs, one improvement and two nitpicks fixed

Adds `start_button={false}` with `AudioRecorder.start/2`, so a page's own control starts the recorder, and
`upload={@uploads.name}`, so a finished clip joins a page's own upload instead of being sent as a message.

## Findings

### BUG - MEDIUM — the moduledoc told a page to accept `.ogg`, which crashes it at mount (fixed)

The new "Into an upload of your own" section said the upload must accept "`audio/*` (or `.webm`, `.ogg`,
`.mp4`)". `.ogg` has no MIME type on this stack, so `allow_upload/3` raises:

    allow_upload(socket, :x, accept: ~w(.ogg))
    ** (ArgumentError) invalid accept filter provided to allow_upload.
       Expected a file extension with a known MIME type.

Run against the real function: `.webm`, `.mp4`, `.wav` and `audio/*` pass and `.ogg` raises. `accepted/1` in the
same file carries a comment saying exactly this. A module author following the doc crashes the page, and leaving
`.ogg` out to avoid that refuses every Firefox clip, since Firefox records Ogg.

Fixed in the doc: `audio/*` for `:native`, with the reason, and `audio/*` or `.wav` for `:wav_16k`.

### BUG - MEDIUM — a clip ready while the connection was down vanished with no message (fixed)

The recorder's own path survives a dropped connection. `pushEventTo` without a callback returns
`Promise.allSettled`, so `await this.push("recorder_clip")` does not throw, the clip stays in `preparing`, and
`reconnected()` reports `:failed`.

`handOver/1` went to idle straight after `uploadTo`, and that is where the clip dies. `uploadTo` fires the input's
`phx-change`, `pushWithReply` answers `no connection` while disconnected, and the rejoin renders a new input with
a new ref. By the time the view is back, the state is `idle`, so `reconnected()` has nothing to report. The person
pressed Send, saw the recorder go quiet, and has no file, no error and no way to get the recording back.

Fixed: with the socket down, `handOver/1` stays in `preparing` under the watchdog, so the clip ends as a clip of
the recorder's own does, with `:failed` at the reconnect, or after 120 s if no reconnect comes. Two tests cover
this, and both fail with the fix removed.

The clip is still lost, but the person now knows to record again. Holding the `File` and handing it over from
`reconnected()` would keep it, and is worth doing if voice notes on poor connections turn out to matter.
`liveSocket.isConnected()` reads the socket, not the view, so the short gap between the socket returning and the
view rejoining is not caught.

Read from LiveView's source and tested in the Node harness, not run in a real browser.

### IMPROVEMENT - MEDIUM — without a start button, keyboard focus fell to the top of the page (fixed)

`backToIdle/0` exists to put the focus back on the start button once Send is hidden ("leaves a keyboard user at
the top of the page"). With `start_button={false}` there is no such button, so the PR guarded the call and the
focus was simply lost, after every clip, in the mode this PR adds.

Fixed: `onStart` remembers `document.activeElement`, and `backToIdle/0` focuses that when the recorder has no
button of its own. The existing rule stands, so a clip that ends by itself does not pull focus from elsewhere.
Two tests cover both sides, and the first fails with the fix removed. A control that is gone by then (a closed
menu) ignores `.focus()`, so that case stays as it was. Checked in the Node harness only, not in a real browser.

### NITPICK — the test host compiled with two warnings (fixed)

`handle_event/3` sat between the two `handle_info/2` clauses of `AudioRecorderHostLive`, without `@impl`. `mix
precommit` compiles `test/support` without warnings-as-errors, so nothing failed.

### NITPICK — `start_button` is read once, and the doc did not say so (fixed)

The button sits inside `phx-update="ignore"`, so changing the attribute later does nothing. It joins the "read
once" sentence with `format`, `max_seconds` and `label`.

## Left as they are

- **`busy` makes the page's button do nothing, silently.** The page set `busy`, so it can disable its own button.
- **The `.dialyzer_ignore.exs` entry covers the whole file**, where a regex on the `start` spec would cover one
  contract. It matches `admin_dock.ex` next to it, and the file has one such spec.

## Checked and sound

- **A second press is safe.** `start()` already refuses while starting, while not idle and while busy, so the
  page's button, which stays clickable during a recording, cannot start a second one.
- **`data-upload-ref` is the input's id.** `live_file_input/1` renders `id={@upload.ref}` and
  `name={@upload.name}`, and `dispatchUploads` filters on that name. `input.form` also covers an input placed
  outside its form with `form=`.
- **The recorder follows a rebuilt upload.** LiveView merges `data-` attributes into a `phx-update="ignore"`
  element, and the hook reads them when the clip is ready, not at mount.
- **`hidden` survives a re-render.** The ignored element keeps it, so a progress update of the page's upload
  cannot hide a recording.
- **Every `part("start")`** is guarded (`updated`, `show`, `backToIdle`), and `destroyed` removes the start
  listener before its `ready` check.
- **Nothing reads `@upload_name` or `@uploads` in upload mode.** Both sit behind `if @upload` or `:if`, and
  `cancel_entries/1` has the clause for it. A test asserts a recorder error leaves the page's files alone.
- **`start/2` does not leak.** `phoenix_kit_web.ex` imports `only: [audio_recorder: 1]`.
- **Default mode is unchanged**, and no code renders the component except through `audio_recorder/1`, so the new
  assigns are always present.
