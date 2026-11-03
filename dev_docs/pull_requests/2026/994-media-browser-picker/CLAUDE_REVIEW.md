# PR #994 — Add a picker mode to the media browser

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve with fixes

Codex's fix (`confirm_pick/1` through `pickable_uuids/2`) is in place; Mistral reported nothing.

## Checked and sound

- **Gate order.** Every picker event (`click_file`, `pick_quick_confirm`, `pick_confirm`/`pick_cancel`)
  passes the library-access, viewer, own-files and `foreign_reference?` gates first.
- **One pick check.** `pickable_uuids/2` loads in bulk and applies library + viewer, system-managed,
  trashed, `only_file_type` and scope (homed or linked). The initial `selected`, `picker_reset`, clicks,
  the upload's auto-pick and Confirm all use it, so the host gets only uuids the viewer could see.
- **Refusals ahead of the handlers:** `@folder_action_events`, `@picker_off_events`,
  `@picker_file_write_events`, a permanent delete in the trash view.
- **Upload routing and DOM ids.** Picker uploads go to pickers, others to the other browsers; a picker next
  to a plain browser gets its own ids (`dom_id/2`); every `phx-change` form has an id. A refused pick logs
  that it was refused, never the client's value. No inline script; strings in the pot and all nine `.po`.

## Findings

### BUG - MEDIUM — a picker's upload acknowledgement never reached its own hook (fixed)
`parent_progress/3` and `handle_parent_info(:cancel_rejected_uploads)` run on the **host's** socket, where
`resume_target/1` finds no `:picker` assign, so the `phoenix_kit:upload-received` ack went out unnamed —
and a picker's `UploadResume` hook accepts only events naming it (`_mine`). Every file uploaded into a
picker stayed in IndexedDB (up to 250 MB each, 7 days), and a reconnect listed it under "Upload problems"
as cut short, offering a Retry that sent the bytes again.
**Fix:** `ack_received/3` takes the upload name; a `:media_picker_files` upload is acknowledged to every
picker the host registered (`media_picker_ids`, each hook forgets only keys it holds), anything else
unnamed as before; the cancel path groups its entries by `upload_config`.
Test: `media_browser_picker_test.exs` "the picker's UploadResume hook is told the bytes arrived".

### IMPROVEMENT - MEDIUM — the orphan view and "Delete all orphaned" ignored a scope (fixed)
Pre-existing (5d169b140), inherited by the picker. Both handlers read no `scope_folder_id`, only the header
hides them, and `toggle_orphan_filter` is rendered nowhere — so a forged event in a browser scoped to,
say, an order folder listed every orphan of the library, and `delete_all_orphaned` queued them all for the
trash. **Fix:** a scoped browser refuses `delete_all_orphaned`, and `toggle_orphan_filter` unless it turns
an open orphan view off; `delete_all_orphaned` joins `@picker_file_write_events`.
Test: `test/phoenix_kit_web/components/media_browser_scoped_orphans_test.exs` (DB-free).

### IMPROVEMENT - MEDIUM (plausible) — two pickers on one page share `:media_picker_files` (not changed)
Routing sends a picker upload to every registered picker, and each renders
`<.live_file_input upload={@parent_uploads[:media_picker_files]}>` (same `ref` id). With two pickers
mounted at once (two slots, or the hidden kept-mounted pattern the moduledoc suggests) the ids collide
and an upload lands in, and is auto-picked by, both. Not fixed: it needs a per-picker upload name (an
attribute threaded through `setup_uploads/1`) and a two-picker test host. Until then the moduledoc should
say "one picker per page".

### NITPICK — stale or uncapped pick state (not changed)
`confirm_pick/1` does not re-apply `max_select`/`pick_mode` if the host changes them on a mounted picker
without `picker_reset`; `remove_files_from_lists/2` sets `:picked` directly, so `pick_limit_hit` stays on
after a broadcast frees a slot; switching library keeps the old library's picks (Confirm then drops them
silently, through `pickable_uuids/2`). None returns a file the viewer could not see.
