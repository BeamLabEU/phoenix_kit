# Release 2.57.0 review

Reviewer: Codex. Date: 2026-10-08.

Reviewed `v2.56.1..v2.57.0`, including the release fixes in
`750e1fcc7b59e3df4c8632916124e7392be10813`. The annotated `v2.57.0` tag
resolves to that commit, which was also the clean checkout's HEAD at review start.
No migration changed (V211).

## Result

**Two BUG - HIGH findings and six BUG - MEDIUM findings remain.** No critical
issue found. The statement that the remaining upload inbox issues cannot lose
data is too strong: a metadata-write failure deletes the upload, and a second
browser can discard bytes still queued in the first. Retrying into a different
library also changes the file's privacy policy.

This is a review of the published release. Application code, versions and tags
were left unchanged. The changes recommended below need a follow-up patch.

## Findings

### 1. BUG - HIGH — Retry can turn a private upload into a site-library file

Locations: [inbox_problems/1 and retry_upload_problems/2](../../../../lib/phoenix_kit_web/components/media_browser.ex#L450),
[retry_entry/1](../../../../lib/phoenix_kit_web/components/media_browser.ex#L530),
[store_upload/8](../../../../lib/phoenix_kit_web/components/media_browser.ex#L5094),
[UploadInbox.put/3](../../../../lib/modules/storage/upload_inbox.ex#L65).

The sidecar stores client metadata but no destination library or folder.
Every writable MediaBrowser lists the user's whole inbox. Retry queues the bytes
in the browser receiving the click, and `store_upload/8` takes its library from
that browser's current `lib_opts/1`.

Reproduced through real uploads and PostgreSQL: create a private user library,
open it at `/admin/media/my/<slug>`, disable bucket writes, and upload a file.
Re-enable writes, open `/admin/media`, and click the failed file's Retry. The file
lands in Media (`00000000-0000-7000-8000-000000000001`), and the inbox is empty.
It loses user-library privacy, including the requirement for a time-window URL.
The same flow can place bytes intended for one shared library in a different
shared library, or in the currently open folder.

Claude recorded the missing destination, but its privacy consequence warrants
HIGH severity. User scoping prevents another user's inbox being listed; it does
not preserve the destination or access policy of this user's upload.

**Recommended change:** persist the accepted destination library and folder,
retry against it after checking current access, and scope the panel to its
intended destination. Make moving a failed upload to a different destination an
explicit action. Browser Resume needs the same destination contract.

### 2. BUG - HIGH — A sidecar-write error deletes both server copies

Locations: [UploadInbox.put/3](../../../../lib/modules/storage/upload_inbox.ex#L75),
[move/2](../../../../lib/modules/storage/upload_inbox.ex#L256),
[into_inbox/3 and the receipt acknowledgement](../../../../lib/phoenix_kit_web/components/media_browser.ex#L1617).

`put/3` moves the source bytes before writing their sidecar. On a sidecar write
or rename error, its `else` removes the destination. The source has already been
removed by either branch of `move/2`. `into_inbox/3` then returns the original
source path as its fallback, although that path no longer exists, and
`parent_progress/3` still acknowledges receipt. This also tells IndexedDB to
forget the browser copy. Disk-full conditions can therefore permanently lose a
received upload instead of preserving it for Retry.

Fault injection used the release module's code with only the module name and
UUID generation replaced, allowing a directory to occupy the sidecar's `.tmp`
path. The actual move/write/error cleanup ran and returned:

```elixir
%{result: {:error, :eisdir}, source_exists: false, inbox_bytes_exist: false}
```

The cleanup is identical for `:enospc` and other metadata-write errors.

**Recommended change:** commit metadata and bytes without deleting the source
before success, or restore/return the surviving byte path on failure. Only send
the browser a receipt acknowledgement after a real recoverable copy exists.

### 3. BUG - MEDIUM — A quick refresh misses recovery records and never scans again

Locations: [UploadResume.mounted](../../../../priv/static/assets/phoenix_kit.js#L7647),
[_reportLeftovers](../../../../priv/static/assets/phoenix_kit.js#L7746),
[UploadInbox.read_item/3](../../../../lib/modules/storage/upload_inbox.ex#L166),
[component inbox initialization](../../../../lib/phoenix_kit_web/components/media_browser.ex#L1308).

The browser scans once, 1.5 seconds after mount, but ignores other page loads'
records until their heartbeat is more than 15 seconds old. A normal quick
refresh occurs well within that window. Its first scan sees no leftovers;
there is no later scan, and the heartbeat only touches this hook's own live
records. A reconnect scans only its own tab id, so it does not recover the
previous page load's records either.

An executable probe of the released hook with controlled time and stashed rows
reported zero records at the first scan and still zero after 35 seconds, with
no pending scan. The bytes remain in IndexedDB, but this page offers no Resume.
Another sufficiently delayed reload can find them.

Server recovery has the same timing gap: a new browser hides fresh `received`
items for 120 seconds. After the original LiveView's queue has disappeared,
waiting on the new idle page does not reload its cached `upload_inbox_problems`.
That list is refreshed at initialization or a processed batch, not on a timer.

**Recommended change:** rescan records after the relevant stale deadline, or
use an owner/lease mechanism that detects the dead uploader and then refreshes
the panel. Preserve cross-tab protection while doing so.

### 4. BUG - MEDIUM — Library patches keep the previous library's browser-stash scope

Locations: [UploadResume.mounted and _stash](../../../../priv/static/assets/phoenix_kit.js#L7654),
[stable MediaBrowser component](../../../../lib/phoenix_kit_web/live/users/media.html.heex#L16),
[library switcher links](../../../../lib/phoenix_kit_web/live/users/media.ex#L206).

`_scope` is captured from `window.location.pathname` only at mount. Switching
libraries patches the same LiveView and MediaBrowser; the hook's id remains
stable and it has no `updated()` handler. Files picked after the switch are
stored under the page's original library path. After refresh at the new path,
those records cannot be found there. Reopening the original path can instead
offer files picked for the other library. Query-string folder navigation is
also absent from the scope from the outset.

The released-hook probe changed the path from `/admin/media/my/private` to
`/admin/media`; `_scope` remained `/admin/media/my/private\u0000user-a`.

**Recommended change:** give each upload an explicit destination identifier
from the server. Keep acknowledgements tied to the scope captured for that
upload, and update the destination used for new picks on patches. Merely
reassigning `_scope` would make acknowledgements for older in-flight uploads
address the wrong record.

### 5. BUG - MEDIUM — Off-type inbox refusals are invisible until another inbox reload

Location: [off_type_upload? branch](../../../../lib/phoenix_kit_web/components/media_browser.ex#L651).

The release correctly retains an inbox item's bytes on an off-type refusal,
but the `{user_uuid, id}` branch only calls `UploadInbox.fail/3` and returns the
unchanged socket. It does not refresh `upload_inbox_problems`, add a session row,
or schedule a batch commit. A fresh off-type upload therefore disappears from
processing without a visible explanation. Retry into an incompatible browser
first removes the problem row, then takes this branch, so the row disappears
again even though the retry failed.

A direct call through the component's real drain returned one failed disk item,
zero visible problems, and no scheduled batch. A regression assertion that the
component has one visible problem fails.

**Recommended change:** refresh the inbox assign when marking an off-type item
failed, or return a failed result through the common batch settlement path.

### 6. BUG - MEDIUM — The converter can create a preview after timeout cleanup

Locations: [FocalPoint.run_detection/1](../../../../lib/modules/storage/focal_point.ex#L274),
[ImageProcessor.preview_jpeg/3](../../../../lib/modules/storage/services/image_processor.ex#L295).

The caller-owned `after` fixes cleanup of a preview that exists when the task
is killed. It does not stop the external converter. On this Linux runtime,
killing the task awaiting `System.cmd/3` does not guarantee that the command
process is killed before it writes its output. A slow decoder can create the
preview after `File.rm/1` has already run.

Reproduced through the unchanged `FocalPoint.detect/1` using a real BMP that
libvips cannot decode and a stand-in `convert` executable that waits 12 seconds
before writing the requested JPEG path. Detection returned `:error` at about
10 seconds with no preview; 2.5 seconds later a new `phoenix_kit_focal_*.jpg`
existed. The probe removed that file afterwards. This contradicts the release
note that timeout no longer leaves a preview behind.

**Recommended change:** own and terminate/reap the external conversion process
before cleanup, with a timeout that covers it, or arrange cleanup when that
process actually exits. Add a delayed-output timeout regression.

### 7. BUG - MEDIUM — Age-based interruption allows Discard to delete a live queued upload

Locations: [age classification](../../../../lib/modules/storage/upload_inbox.ex#L180),
[discard_upload_problems/2](../../../../lib/phoenix_kit_web/components/media_browser.ex#L540).

A file still queued behind slow stores becomes `interrupted` after 120 seconds,
because no active ownership is recorded and the initial drain does not touch it.
A second browser then offers Retry and Discard with copy claiming that the page
was closed or refreshed. Discard deletes the bytes directly, without checking
whether the first browser still owns or is processing them.

The component regression probe aged a received item to 121 seconds, queued it
in one MediaBrowser without draining it, initialized a second MediaBrowser,
and called its Discard handler. The first queue still had one entry; its byte path was gone.
The next store will fail with `:file_missing`. The same missing ownership check
also permits stale failed-item panels to discard an item another tab has just
started retrying.

This extends Claude's age-only finding: the consequence includes data loss,
not only an inaccurate status or a failed redundant Retry.

**Recommended change:** claim items atomically for processing, track a lease
or active owner, and reject Retry/Discard from stale panels while claimed.
A single timestamp touch cannot protect a store that itself takes over 120 seconds.

### 8. BUG - MEDIUM — Later browser copies cannot be recovered after a LiveView exit

Locations: [upload fanout](../../../../lib/phoenix_kit_web/components/media_browser.ex#L1675),
[settle_upload/4](../../../../lib/phoenix_kit_web/components/media_browser.ex#L5021),
[UploadInbox.locate/1](../../../../lib/modules/storage/upload_inbox.ex#L89).

Confirmed Claude's open item by tracing the complete path: later recipients
get `<inbox-path>-<component-id>` copies. Their basename fails `locate/1`'s UUID
check, so a storage failure becomes a socket-only `path` problem. A refresh
loses that reference, and `UploadInbox.list/1` cannot rediscover the bytes because
there is no sidecar. The bytes may remain on disk, but the user cannot recover
or discard them through the inbox. Successful processing by the first browser
can remove the only sidecar, leaving later recipients entirely unrepresented.
A readonly first recipient can instead leave a misleading interrupted original.

**Recommended change:** route an upload to its originating browser/destination,
or create a real inbox item per intended recipient before acknowledging receipt.
Sweep untracked copies created by the old path. This was already recorded in
Claude's review; the release's refresh-recovery guarantee still does not cover it.

## Other open items

- **IMPROVEMENT - MEDIUM — Bound inbox retention.** There is no per-user or
  node byte/item limit, and the seven-day sweep only runs when that user lists
  their inbox. Users who never return leave retained failures indefinitely;
  sidecar-less copies are never swept. Add admission limits and a periodic sweep.
  This also makes finding 2's disk-full trigger more likely.
- **IMPROVEMENT - MEDIUM — Make the persistence boundary explicit.** The default
  is node-local temporary storage. A configurable persistent path exists, but
  refresh recovery across nodes or ephemeral restarts needs deployment support.
  Inbox directories also use the host umask rather than explicitly requesting
  private permissions.
- HEIC format-list probing still does not exercise an actual HEVC decode, and
  the probe's `magick` fallback differs from the pipeline's `convert` command.
  The AVIF format fallback and settings-page existence query remain as Claude
  recorded. No additional high-severity issue found in those paths.

## Validation and scope limits

- Existing targeted Elixir suites: **151 tests, 0 failures**, in two runs
  (37 upload/email/library tests, plus 114 HEIC/settings/media/component tests).
  PostgreSQL was reachable; integration tests ran. The only excluded category
  was `:requires_createrole` because the test role lacks CREATEROLE.
- `mix precommit` **passed**, including compile, test-file compilation, format,
  Credo, Dialyzer with the existing ignore list, and all **314 JavaScript tests**.
- Targeted existing JavaScript suites: **65 tests, 0 failures** (upload resume,
  neighbour warming, hires loading, instant viewer, breadcrumb switcher).
- Three temporary regression assertions **fail against the released code**:
  private Retry destination, visible off-type failure, and age-based live-byte
  deletion. These are expected failures reproducing findings 1, 5 and 7, not
  failures in the existing suite.
- Executable temporary probes confirmed the quick-refresh and stale-path stash
  behavior, destructive metadata-error cleanup, and delayed preview output.
  JavaScript probes executed the released hook with controlled clock/storage;
  they were not full browser/IndexedDB end-to-end tests. The metadata-error probe
  used the deterministic UUID injection described above.
- Email section links still use the shared redirect guard and permission-filtered
  sections. The same-slug library switch fix is consistent with `Libraries.url_id/2`.
  Existing tests for both passed. Private neighbour URL handling, escaped neighbour
  metadata, viewer direction and fetch restrictions showed no further serious issue.
- The full 8,810-test suite and prerelease publishing gate reported in the release
  handoff were not rerun. No application code was changed during this review.
