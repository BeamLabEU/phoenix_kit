# TODOs

Workspace-tracked items not ready for inline `# TODO` in `lib/`.

## Component test coverage for `phoenix_kit_web/components/core/`

Partial coverage exists in `test/phoenix_kit_web/components/core/`. Remaining gaps:

- `<.draggable_list>` — three branches need rendered-HTML asserts: (a) `:draggable=false` → no SortableJS hook, no `cursor-grab`; (b) `draggable, sortable_handle=nil` → hook + full-item `cursor-grab`; (c) `draggable, sortable_handle=".pk-drag-handle"` → hook + `data-sortable-handle` set, **no** `cursor-grab` on the item wrapper (caller's responsibility).
- `<.table_default>` card-view branch — pin `phx-hook="SortableGrid"`, `data-sortable-*`, `data-id`, `class="sortable-item"`, drag-handle footer.
- `<.input>`, `<.select>`, `<.textarea>` — inline error rendering, daisyUI variant classes, FormField vs raw `name=`/`value=` dispatch.
- `<.flash>` if complexity has grown.

## Signed file-URL hardening (`modules/storage`)

In `lib/modules/storage/services/url_signer.ex` (the upload and `/info`
authorization gaps were closed in `lib/phoenix_kit_web/controllers/{upload,file}_controller.ex`):

- **Token is 16-bit** — first 4 hex chars of an MD5, ~65k space, brute-forceable. Widen it (consider HMAC over MD5).
- **Tokens never expire**, yet the 401 says *"Invalid or expired token."* Add real expiry or fix the message.
- **Fails open on a nil `secret_key_base`** — the token degrades to a predictable no-secret hash. Fail closed.

Low urgency (current use is public post images), but don't rely on the "capability URL" framing for sensitive files.

## Image probes outside the job's limits (`modules/storage`)

`ProcessFileJob.warm_probes/2` (`lib/modules/storage/workers/process_file_job.ex`)
starts four `Task.start` processes per file, unlinked and unsupervised. From the
2026-11-15 pre-release review, not fixed:

- They outlive the job: when the job returns early (first probe fails, cancelled,
  timed out) the temp file and the `ProbeCache` table are removed while up to four
  ImageMagick decodes still run.
- They are outside the `file_processing` queue's concurrency: a burst of uploads
  runs four extra full decodes per file.
- A process waiting on a `:running` key whose claimer was killed polls for the
  30 s `@wait_ms` before redoing the work.

Wanted: tasks owned by the job (`Task.Supervisor.async_stream_nolink` or
`Task.async` awaited before the temp file goes), or no warm-up at all if the
measured gain is small.
