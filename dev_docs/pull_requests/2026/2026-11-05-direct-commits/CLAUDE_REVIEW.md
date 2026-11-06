# Direct commits of 2026-11-03 to 2026-11-05 (on main, no PR)

**Author:** Dmitri Don · **Reviewer:** Claude · **Verdict:** nine bugs fixed, three of them high (two in storage, one in the
recorder), and one improvement; nothing left open

Everything since 3.3.0 that no review doc covered: the storage commits, the first-manager picker and the audio recorder.
Reviewed elsewhere and not repeated here: `4f6d2258d` (#1005), `82b9b5c4a` (#1006), `1e16cc213` (#1007 to #1012), `89d1b488d`
(#1013 to #1016), `d842dc478` (#1017, #1018). `febdf7f9e`, `20ebbc35d` and `ade4d4a21` change `mix.lock` only. The Leaf pin
`~> 0.10.0` admits 0.10.1, and `phoenix_kit.js` takes nothing from Leaf that moved.

Every bug below was reproduced with a failing test before it was fixed, except where it says otherwise. Two independent
reads did part of this: one over quotas and originals-only backups, one over the recorder, whose author also wrote this
review. Each of their findings was checked against the code before it went in here.

## `a4c3918ad` — storage quotas

### BUG - HIGH — "backed up here" escaped the quota (fixed)

`charged/1` and `charged_owner/1` left out any library whose profile has an `owner_uuid`, on the reasoning that such a library
is on the owner's own storage. A V206 profile in `:backup` mode has one too, and it keeps every file on the site's buckets,
with a copy on the owner's. So with own buckets enabled, one choice on the library form gave an account unlimited site
storage: usage read 0 and `check_upload/2` never asked. The test missed it because `own_storage!/2` built a profile with no
buckets at all.

A library is now left out only when its profile's `primary` is a bucket with an owner, the same line
`Profiles.user_storage_for/1` draws between `:only` and `:backup`.

### BUG - MEDIUM — a refusal was reported as missing buckets (fixed)

`:quota_exceeded` appeared nowhere outside `Quotas`, so the panel said "The server could not save it." and the flash said
"Upload failed: No storage buckets configured. Please configure at least one storage bucket", sending the person to
settings that were fine. Both now say there is no storage left for this library, and the flash counts those files apart,
as it does a file that is in another library. Three strings, translated in every catalogue.

### BUG - MEDIUM — a slip in the limit field lifted the limit (fixed)

`Integer.parse/1` reads `"1e3"` as `{1, "e3"}`, and anything but a clean positive number saved `"0"`, which means no limit,
with a success flash. A number field lets `1e3` through. Blank and `0` still mean no limit; any other value that is no
whole number now keeps the limit there is, as the neighbouring fields do.

### NITPICK — "save as a copy" rendered again on a refusal (fixed, no test)

`finish_copy/2` passed `{:error, :quota_exceeded}` to Oban, which rendered the image again up to three times with the same
result. It cancels now. No test: a real render needs `magick`, which this machine lacks. The person is still not told,
which is true of every failure on that path.

### IMPROVEMENT - MEDIUM — usage sums rows, not objects (left, by decision)

`usage/1` adds up `File.size` per row, so the same bytes uploaded by two people into one library count twice, and the
second upload can be refused. The other way round, the sizes of an edited image's hidden original are not counted. Both are
small next to the total, and neither loses anything. Counting distinct `FileInstance.file_name` would fix both, at the cost
of a heavier query on the upload path. The maintainer chose rows, and the moduledoc, which promised each object once, now
says what it does.

### NITPICK — a host hook that raises takes the upload down (left)

A raise in `:storage_quota` fails the upload, loudly. That is the right side to fail on for a limit, so it stays.

### Checked and sound

Every upload path goes through `store_file_in_buckets/7` (browser, resumable, URL fetch, save as copy), and derived objects
are never refused. `link_copy/3`, which only modules call, is counted but not refused. The key is not in
`form_setting_keys/0`. Trash, restore and contributor charging do what
the moduledoc says. Two uploads at once can overshoot, as it also says.

## `90c5ad23c` — a backup bucket of originals only

### BUG - HIGH — an edited image's real original was deleted from the backup (fixed)

`object/2` read every system file as `:derived`, which is right for a tile and wrong for the hidden unedited original of an
edited image. That file is system-managed too, and nothing can make it again. So the next reconcile left the bucket out of
`keep`, and `unlink/2` deleted the object: the backup then held only the edited render, and the true original was on the
primary alone. It was not the last copy, but it is what this option exists to protect. Both `object/2` now treat the
`original` of `ImageEditing.backup?/1` as an original. A test with a tile pins the other side.

### BUG - MEDIUM — a leftover `derived` stopped library creation (fixed)

The moduledoc says a `derived` left from before 2.53 reads as `all`. `site_row/1` copied it into a new row, where
`validate_inclusion/3` refuses it, so with such a row on the Default profile every "backed up here" library rolled back.
`put_bucket/4` still refuses `derived` from a caller; only the snapshot maps it.

### NITPICK — burned thumbnails leave such a backup (left)

A burned thumbnail has no `spec_hash` and was drawn in the browser, so it can only be approximated again, and it counts as
derived. A design call: it is a thumbnail, and the original stays.

### Checked and sound

`verified_placement?/5` still stops the last copy going, and an S3 error makes `holds?/2` false rather than true. The capped
count cannot loop. Changing the option bumps the revision and queues the reconciler.

## `dbb4f2766`, `c9118b465` — the reconciler's lease (V228)

### NITPICK — a dead holder's lease can skip a file, in one rare case (left)

The first version of this review called this an open improvement, and had the recovery wrong. It said the boot trigger starts
a new pass 30 s after a restart, which then meets the dead holder's lease. It does not. The interrupted run stays claimed while
its Oban job reads `executing` (`SweepWorker` leaves that to Lifeline), the boot trigger only records a restart on it
(`existing/3` in `Engine`), and Lifeline rescues the job after `rescue_after`, 60 minutes by default. The five-minute lease ran
out long before, so the pass carries on and copies the file. A storage move cut by a restart therefore looks stalled for up
to an hour, then finishes by itself. Nothing here changed that.

What is left is a batch killed by its 30-minute `timeout/1` and retried inside the five minutes: that file is `:skipped` and
waits for the next run. Read from the code; no restart was staged.

### NITPICK — the lease's soft failures handled a raise but not an exit (fixed)

`renew/3` and `release/2` rescued, and a dead pool exits (`AGENTS.md`: soft-failure paths need both). In `release/2` that exit
ran in the `after` of `hold/5`, so it replaced the work's own result; in `renew/3` it ended renewal for good. A test covers
the release; the renewal is the same clause, with no test.

### NITPICK — a killed renewer left a `:DOWN` in the holder's mailbox (fixed, no test)

`stop_renewer/1` could leave one behind in the process that asked, which for a repair is a LiveView. It flushes it now.

### Checked and sound

The claim is one conditional `UPDATE`. Release and renewal match the token, so a lease that ran out and was taken stays
the new holder's. Re-entry is per process, and nothing calls it inside a transaction. V228 is additive and catalog-only,
with its columns in the manifest, and `update_all` leaves `updated_at` alone. The clock is the app's, and a skew past the
200 s a renewed lease keeps in hand would be needed to matter.

## `cbef7e9a3`, `2adb71b10`, `9dc16ae27` — S3 multipart, B2, Hetzner

### NITPICK — a failed disk write left the partial file behind (fixed, no test)

`:ok = IO.binwrite/2` raised on a full disk, past the `File.rm/1` that the comment above it promises. It is an `{:error, _}`
now, which takes the path that removes the file. Disk full cannot be staged here in a way that tells the two apart.

### NITPICK — docs still named what the code stopped using (fixed)

The moduledoc and the README named `ExAws.S3.upload/4` and `ExAws.S3.download_file`, and the README a session advisory lock.

### IMPROVEMENT - MEDIUM — the key store failed on B2 (fixed)

`KeyStore.S3` names Backblaze B2 in its moduledoc, and its `request/2` still called `ExAws.request/2`, the call `2adb71b10` moved
everything else off. On a B2 region that raised, which `request/2` rescued into `{:ex_aws_raised, _}`, so the off-host copy of
the encryption secret was never written. It goes through `S3Request.request/2` now.

That alone would have been wrong: this store's settings come from the host and may leave the host or the region to
`config :ex_aws`, and `S3Request.config/1` read neither, so it would have signed with its neutral region. It now reads both as
ExAws does. `key_store_s3_test.exs` runs the store through real HTTP against a stub, in a B2-shaped region, with the settings
in each place, and checks the region each request is signed for. Not run against real B2.

### NITPICK — a download reads its ranges one at a time (left)

For every provider, not just B2, and slower for a large video than ExAws's eight at a time. It is correct, and memory stays
at one range.

### Checked and sound

Parts are `{number, etag}` as `complete_multipart_upload` wants, sorted, and `get_headers_list` gives plain strings. A
file an exact multiple of 5 MiB gets no empty last part, and an empty object downloads as an empty file. A failed part
aborts. `S3Request.config/1` restores the real region for signing, and every call of the storage provider and the connection
check goes through it. `hetzner` is in every provider list, no database constraint names providers, and it is addressed
virtual-host style as Tigris is. The CHANGELOG says this ran against real B2 and Hetzner buckets, which this review did not
repeat.

## `f9063a8e3` — the first-manager picker and person search

Sound. The pattern escapes `%`, `_` and `\`, `concat_ws` ignores a missing name, and an empty query is the first page on
purpose. The chosen person goes through `create` and its checks again, so the picker is a convenience and no way round them.

### NITPICK — a pick from results a later search replaced does nothing (left)

`picker_pick` looks the person up in the last results, so a press landing just as newer ones arrive picks nobody, silently.

## `a673a5882` — `<.audio_recorder>`

### BUG - HIGH — two recorders sending at once crashed the page (fixed)

Every recorder used the upload name `:audio`. A LiveView holds a name for as long as an entry uses it, and
`ensure_unique_upload_name!/2` raises when another component starts an upload under it. So pressing Send on one recorder
while the other was still uploading killed the page's process, and the clips and the page's state with it. WoodMatrix has
two recorders on one page, and the moduledoc and CHANGELOG said that was fine. Each recorder now has an upload name of its
own, built from its id.

Nothing caught this because nothing tested it. The test named "two recorders on a page" mounted two separate LiveViews, and
the browser run's uploads finish on loopback before the next one starts. Run again under LiveView's latency simulator, the
old code crashes in real Chromium and the fixed code does not.

### BUG - MEDIUM — a recording that ended by itself used a stale `sending` (fixed)

`start/0` never set `sending`, and `MediaRecorder` stops by itself when its tracks end: a microphone unplugged, a permission
withdrawn. On a first clip, or after a Cancel, the recording was thrown away with no word. After a Send, a partial clip
went out. It now always sends what was caught. Confirmed in Chromium, old code and new.

### BUG - MEDIUM — a slow upload was reported failed, then delivered (fixed)

The hook gave up 120 s after the upload began, whatever the size, and nothing cancelled the entry. Below about 384 kbit/s a
180 s clip showed "could not be sent", then reached the page anyway, and a retry made a duplicate. The server now reports
each step (`audio_recorder_progress`), so the timer measures silence, not length, and any failure the hook reports cancels
what is running.

### BUG - MEDIUM — `finish/0` went on after the clip was over (fixed)

A reconnect during the WAV conversion told the person the clip failed, and `finish/0` then uploaded it anyway, armed a timer
nothing cleared, and 120 s later reported a false failure over whatever came next. It now stops after each `await` when the
clip is no longer preparing, and a settled event always clears the timer.

### NITPICK — a failed write ran the spinner out (fixed)

An entry the server could not write stays unfinished, and `handle_progress/3` dropped that callback. It now ends the clip
as `:failed`.

### NITPICK — smaller points (fixed)

`Sending…` is a status region now. The moduledoc says `format`, `max_seconds` and `label` are read once, and that a
`:native` clip's opening bytes name its container and prove nothing about what is inside. A comment claimed `phx-target`
routes the hook's events: that is only `render_hook/3`, a browser finds the component from the DOM.

### Tests that proved less than their name (fixed)

The "two recorders" test above. "Has no samples" failed at `"WAVE"` and never reached `size > 0`. "By default ... portal"
passed `portal: true` itself. No JS test called `destroyed/0`, so "the microphone is released" had none behind it.

## Validation

`mix precommit` passes (credo, dialyzer, 685 JS tests). `mix test` on a fresh database: 14,261 tests, 7 failures, all of them
`magick`, which this machine lacks. The same run before these fixes gave 14,250 tests and 8 failures, the eighth a sandbox
race whose file passes alone. An alias reorder in `quotas.ex` came after that run, and the suites it touches ran again. So did
the S3 and key store suites after the key store fix, which came later still.

The browser run is 26 scenarios in real Chromium with a fake microphone: 26 of 26 on the fixed code. On the old code the
two tightened scenarios and the console check fail. Not tested: Safari, Firefox, a real microphone. Telegram, S3 and the
image renders needing `magick` are stubbed or skipped here.
