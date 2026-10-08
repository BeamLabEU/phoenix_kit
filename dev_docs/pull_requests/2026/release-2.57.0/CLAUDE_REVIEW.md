# Release 2.57.0 review (v2.56.1..HEAD)

Reviewer: Claude. Scope: 21 commits since `v2.56.1` — the upload-problems panel (`d838479c5`), HEIC
support (`f3620d0a4`), the email section `:link` (PR #912 + follow-ups), the "Loading full quality…" pill,
the viewer's gentler neighbour warming (PR #913 + `e690ca711`), the library switcher in the Media and
Libraries headers (`a5135977a`, `59419a2ec`), plus plans/handoffs (docs only). No migration (still V211).

Method: three independent read-only reviews (uploads / HEIC + email link / viewer JS + switchers), each
finding re-checked against the code before acting. Targeted suites, the JS suite and the gate were run
after the fixes (see the CHANGELOG for the result of the gate).

## Fixed in this release

- **BUG - MEDIUM — email section link used a private, weaker redirect guard** (`email_sending.ex`
  `link_target/2`): `"/\t/evil.example"` passed. Now `Routes.local_path?/1`; test fixture added.
- **BUG - MEDIUM — preview temp file leaked on a detection timeout** (`focal_point.ex`): the JPEG preview
  was created and removed inside the task `Task.shutdown(:brutal_kill)` kills, so a slow HEIC left
  `phoenix_kit_focal_*.jpg` behind. The path is made and removed by the caller now.
- **BUG - MEDIUM — a sidecar could be deleted while being rewritten** (`upload_inbox.ex`): `write_meta`
  truncated then wrote; a concurrent `list/1` read a partial file, took it for broken and removed it,
  orphaning the kept bytes. Written to `.tmp` and renamed now.
- **BUG - MEDIUM — Retry in a browser that takes another file type destroyed the kept bytes**
  (`media_browser.ex` off-type branch). A kept inbox item is now marked failed with the reason and stays
  (Retry elsewhere, or Discard); only a non-inbox temp file is dropped.
- **BUG - MEDIUM — `/admin/libraries` ignored a switch to your own library whose slug equals a shared
  library's slug** (`libraries.ex` same-library clause compared the bare slug). Compared through
  `Libraries.url_id/2` now.
- **BUG - MEDIUM — the browser-side upload stash was not tied to a user**: after sign-out/sign-in on a
  shared machine, Resume offered (and uploaded) the previous user's files. The stash scope now includes the
  user uuid (`data-user` on the hook element).
- **BUG - LOW — a malformed `upload_resume_available` / `retry_upload` / `discard_upload` payload crashed
  the sender's own component** (`to_string/1` of a map, missing `"key"`). Guarded; catch-all clauses added.
- **IMPROVEMENT — HEIC extension match was case-sensitive** (`IMG_1.HEIC` is stored as `"HEIC"`): lowered.
- **IMPROVEMENT — chevron clicks did not set the warm direction** (only ArrowLeft/Right did), so stepping
  back with the on-screen arrow warmed the wrong side's large variant. A capture click listener sets it.
- **NITPICK — InstantViewer `destroyed()` did not clear `_pillTimer`.**

## Known, left as is (on record)

- **Upload inbox is not scoped by library/folder/file type** (`inbox_problems/1`): a failed upload from
  library A is listed — and retried into — whichever browser the user has open. The data-loss half is fixed
  (above); recording the destination in the sidecar and filtering the panel is a design change.
- **Second and later browsers on a page get a `<path>-<id>` copy** that has no sidecar, so a store failure
  keeps it only as an in-memory problem; if the LiveView exits the bytes sit in the inbox directory until
  the OS cleans the temp dir. A readonly first browser leaves the original inbox item in place (it later
  reads as "interrupted" although stored). Needs a per-recipient inbox item and an orphan sweep.
- **"Interrupted" after 120 s by age alone**: a long queue of large files can read as interrupted while
  still draining; Retry then hits `:file_missing`. Needs a touch on drain start or an in-flight set.
- **Inbox has no quota, no 0700 mode, and sweeps only when its owner lists**; node-local temp storage (a
  multi-node/ephemeral deploy loses "survives a refresh" silently). Worth a moduledoc line and a periodic
  sweep.
- **`heic_files_exist?/0` runs on every Settings mount** with no index on `mime_type`/`ext`: a scan of
  `phoenix_kit_files` (twice, static + connected render). Admin-only page; cache or defer if it shows up.
- **`avif` is in `@unwritable_formats`**: a format-less rendition of an AVIF original is now a JPEG even
  where ImageMagick can write AVIF. Intentional-looking and safe (spec hashes unchanged); revisit if hosts
  want AVIF renditions.
- **The HEIC probe checks the format list, not that an HEVC decoder is present** (libheif without
  libde265 lists HEIC but fails to decode), and falls back to `magick` while the pipeline runs `convert`.
- **`updated()` re-warms and re-announces `pk:viewer-neighbours` on every patch of the modal** (sidebar
  toggles, comments), restarting the settle timer; `warmUrl` dedupes fetches but not the event.
- Smaller: `media.ex` keeps `page_title` "Media" while the header shows the library name; `Libraries.browse`
  lists libraries twice on a fresh visit; orphaned comment above `neighbor_original_url`; the hires pill's
  `role="status"` toggled with `aria-hidden` is an unreliable live region; no test for the 3 s `_picked`
  expiry or fast stepping.

## Verified clean

Path traversal / cross-user access in `UploadInbox` (uuid-only names at every join); the `own_files_only`
and viewer guards cover the new retry/discard events; switcher authorization (every row is a server-built
`patch`, `handle_params` is the gate; private libraries are not exposed); private-library neighbour URLs
in `data-neighbors` carry time-window tokens (no permanent token minted); `data-neighbors` JSON is
HEEx-escaped; `navigator.connection` / `fetchPriority` feature detection; listener and timer cleanup
across `live_redirect`; command-injection surface of `preview_jpeg/3` (argv list, pinned coder, limits);
spec-hash stability for non-HEIC renditions (no mass regeneration); no `phx-change` form without an id
was added.

## Follow-up after the Codex review (2.57.1)

Codex's review of the published 2.57.0 (`CODEX_REVIEW.md`) was right on every point I re-checked, and it
corrects a claim of mine: "none of these loses data" was too strong. Each finding was reproduced or traced
in the code before being fixed:

| # | Finding | Resolution in 2.57.1 |
|---|---|---|
| 1 HIGH | Retry stores a private-library upload in Media | The sidecar records the destination (`library_uuid`, `folder_uuid`) when the first browser claims the item; a panel lists only its own library's items; a retry stores at the recorded folder. Regression test through the real page (private library → Media does not list it → Retry lands in the library). |
| 2 HIGH | A sidecar-write error deletes both copies | `put/4` puts the bytes back where they came from before forgetting its copy; receipt is only acknowledged with a surviving path. (No injection point for a sidecar-only failure, so it is covered by reading + the unwritable-inbox test.) |
| 3 MEDIUM | Quick refresh never finds the stash; panel never re-reads | The hook schedules a second look for when a fresh record of another page load would be stale. Server side, a claimed item whose owner process is gone reads as interrupted at once, and a browser polls (10 s) while an upload is in somebody's hands. JS tests run the real hook with a fake store and clock. |
| 4 MEDIUM | Library patches keep the old stash scope | The scope (path + `folder` + user) is read at each pick; each key remembers the scope it was picked under, so acknowledgements address the right record. |
| 5 MEDIUM | Off-type refusal of a kept item is invisible | The inbox assign is refreshed when the item is marked failed. (No component-level test: `only_file_type` cannot be set through the Media page.) |
| 6 MEDIUM | The converter writes the preview after cleanup | The caller still removes the preview, and on a timeout a delayed second removal runs after ImageMagick's own 60 s time limit. The converter is still not killed; reaping the OS process is left open. |
| 7 MEDIUM | Discard deletes a live queued upload | Items are claimed by their LiveView's pid; `claim/4` and `discard/2` run under a lock and refuse an item another live process holds; an owner alive keeps an item live whatever its age. |
| 8 MEDIUM | Later browsers' copies are unrecoverable | Each recipient's copy is a real inbox item (`put(..., copy: true)`), a readonly or orphaned recipient deletes its own item, and unclaimed sidecar-less bytes are swept after a week. |
| – | Retention | Directories `0700`; every inbox is swept at most hourly on arrival. Documented node-local persistence. **No per-user quota yet.** |

Still open: a per-user quota, killing the HEIC converter process on timeout, a shared-lock for
claim across nodes beyond `:global.trans`, an explicit "move to another library" action for a kept upload,
and HEIC probe fidelity (HEVC decode, `magick` vs `convert`).
