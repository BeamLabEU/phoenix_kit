# PR #1006 — Resumable uploads and an upload manager for the media module

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve with fixes; one bug fixed, two open
improvements

The upload manager (`Core.UploadManager` + `phoenix_kit_upload_manager.js`), resumable chunked uploads
(`PhoenixKitWeb.ResumableUpload`, mounted at `/api/resumable-uploads`), the media settings for files
per upload, concurrency, resumable on/off and the two retention periods, and `ProcessFileJob` marking a
file `failed` on its last attempt.

## Checked and sound

- **The plug's authorization.** The token binds `id`, `size` and `owner` and must match the path
  segment (`%{id: ^id}`), so `part_path/1` only ever sees a hex id taken from a signed token: no
  traversal. Forged and expired tokens are refused (tested).
- **The `path` callbacks read is the server's.** For an external upload `consume_uploaded_entry/3`
  hands over `conf.entry_refs_to_metas`, the meta `external/1` returned, never anything from the client.
- **Writes.** A chunk is appended only at the current end, never past the declared size, under a lock,
  with at most 16 MiB read per request and an optional SHA-256.
- **Routing.** `BodyGuard` guards only the machine-API prefixes, so 2 MiB chunks are not refused. The
  forward has no pipeline, which is right for a header token (no session, no CSRF). The
  `Plug.Parsers` `pass: ["*/*"]` requirement and the single-node limit are in the guide.
- **Every `MediaSelectorModal` call site passes `phoenix_kit_current_user`.** `external/1` needs it
  (no owner, no upload), and the moduledoc already calls it required.
- **`ProcessFileJob`** marks `failed` only on the last attempt, only from `processing`, and re-raises.
- **Settings** are read through the sanitizing getters, and a retention of 0 reads as the default.

## Findings

### BUG - MEDIUM — a resumable entry was consumed without checking that its bytes had arrived (fixed)

For an `external:` upload, LiveView takes `entry.done?` from the browser. Nothing on the server compared
the assembled file with the declared size before the callback ran. That had two consequences:

1. **The same file in flight twice crashed the page.** The upload id is the hash of owner, name, size
   and modified time, so two entries of one file share one `.part`. The queue's `observe/2` explicitly
   handles "two files with the same name, size and date". Both reach 100%. The first consume stores the
   file and `release/1` deletes the part. The second callback then finds no file: `File.cp!` in
   `MediaBrowser.parent_progress/3` raises and takes down the host LiveView, with every other upload in
   flight. The selector page and modal raise the same way in `FileHash.sha256!/1`.
2. **A client that reports done early gets a truncated file stored** as if it were whole.

`ResumableUpload.consume/3` now runs the callback only when the part file's size equals
`entry.client_size` (the size the token was signed for). Otherwise it drops the entry, keeps the
partial file (picking the file again carries on from it) and answers `{:error, :incomplete_upload}`.
Every core caller already treats a non-success value as a failure: `parent_progress/3` checks
`== :done`, and the selectors match `file_uuid when is_binary`. LiveView's own uploads are unaffected.

Tests:

- `resumable_upload_test.exs`, "consume/3": complete, partial and missing. The partial and missing
  tests fail on the old code.
- `media_resumable_upload_test.exs`: an entry reported done on `/admin/media` with its file partial or
  missing stores nothing and leaves the page alive.

### IMPROVEMENT - HIGH — `mix precommit` was red on `main` (fixed)

`credo --strict` failed on 25 unaliased nested-module calls in `settings_tabs_test.exs` (this PR) and
two in `user_libraries_ui_test.exs` (from a4c3918ad, the storage-quotas commit). With the gate red,
dialyzer and the JS tests never ran. Aliases added; credo now reports no issues.

### IMPROVEMENT - MEDIUM — six strings never reached the catalogs (fixed)

"Unfinished uploads", "Choose files", "Didn't finish: %{names}. Choose the files again to continue.",
"%{names} and %{count} more", "Resumable uploads" and its setting description were in no `.pot` or
`.po` file, so `mix gettext.extract --check-up-to-date` failed. "%{mb}MB per file" was left over after
the template moved to the longer string.

I did the full extract and merge round trip. Two entries came back as fuzzy carryovers, each serving
another msgid's text ("Choose files" served German "Bild auswählen", "Unfinished uploads" served
"Unfertig"). I translated all six strings by hand in de, es, et, fr, it, pl, ru and uk, and cleared
the fuzzy flags in `en`. The result is 0 untranslated and 0 fuzzy, and a second round trip changes
nothing.

### IMPROVEMENT - MEDIUM — same name, size and date means the same upload (open)

Two files with different contents but identical name, size and modified time interleave into one
part through the 409 offset handshake, and the stored result is a mix of both. A realistic case: two
`index.html` files of equal size from an unzipped archive (zip keeps modified times). Genuine twins
are now safe, but only one is stored and the second answers `:incomplete_upload`. The root fix keys
the upload by something per file:

- `client_relative_path` when the input sends one (LiveView 1.2 carries it; core's folder drop does
  not send it), or
- a hash of the first chunk sent with the opening `GET`.

Left to the author, because it changes the resume key.

### IMPROVEMENT - MEDIUM — partial files have no per-owner bound (open)

Each token lets its owner leave up to `client_size` bytes on disk for a day. A signed-in user with
upload rights can keep registering new file names (`max_entries` bounds concurrency, not the total)
and never send `DELETE`. At the defaults (100 files × 500 MB per selection) that fills
`System.tmp_dir!` quickly. LiveView's own uploader deletes its temp file when the channel ends. A cap
on the bytes held per owner would bound it, for example with the owner hash as a filename prefix and
a sum checked in `external/1`. Not changed: it needs a decision on the limit and on what the user is
told when they hit it.

### NITPICK — the chunk lock was cluster-wide (fixed)

`:global.trans/2` locks on every connected node by default. The part file is local to one node, so in
a cluster each chunk paid a round trip to every node and could stall on an unreachable one. It now
passes `[node()]`.

### NITPICK — a last attempt that times out or is orphaned stays "processing" (not changed)

On `timeout/1` (5 min) Oban kills the job process, and Lifeline discards orphaned jobs. Neither runs
the new `rescue`, so those files still sit in `processing`. A `[:oban, :job, :exception]` telemetry
handler, or the reconciler, would cover them. Not worth the machinery for this PR.

### NITPICK — the preflight meta sent to the browser carries the server path (not changed)

`external/1`'s meta goes to the client in the preflight reply, and it includes `path`, the absolute
location of the part file, which reveals `:resumable_upload_dir`. The browser does not use it, and
`consume/3` could derive it from `meta.id`. Not changed: the guide promises `meta.path` to callbacks
written for LiveView's uploader, and a host calling `consume_uploaded_entry/3` directly would lose it.

### NITPICK — `MediaBrowser.handle_progress/3` cannot match what consume returns (pre-existing, not changed)

`consume_uploaded_entry/3` returns the unwrapped value, so its `{:ok, %{file_uuid: _}}` and
`{:postpone, _}` clauses (and `upload_flash/1`'s counting) never match. No core code wires it:
`setup_uploads/1` uses `parent_progress/3`. It predates this PR; delete or fix it separately.

## Gate

`mix precommit` green after the fixes above. The unit tests for `ResumableUpload` and `UploadManager`
pass (55). The test database was in crash recovery for the whole session, so the new
`media_resumable_upload_test.exs` cases (and the rest of the integration suite) compile but have not
been run against PostgreSQL. Run `mix test test/integration/phoenix_kit_web/live/users/media_resumable_upload_test.exs`
before the release.
