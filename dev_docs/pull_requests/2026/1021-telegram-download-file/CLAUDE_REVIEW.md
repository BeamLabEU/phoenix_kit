# PR #1021 — Add Telegram.download_file/3: a size-capped download of a file sent to the bot

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one bug and one nitpick fixed

Adds `Telegram.download_file/3`: `getFile`, then the file itself, with a size cap and a total deadline, so a
module can fetch a voice message or document without holding the bot token. `request/4` stops logging
`inspect(reason)`.

## Findings

### BUG - MEDIUM — `:deadline_ms` did not bound a server that went silent (fixed)

The doc calls `:deadline_ms` "the limit on the whole file download" and `:timeout` the answer when it passes.
The check lives in the `into:` collector, and a collector runs only when a chunk arrives. `receive_timeout`
was a fixed 60 s, so a server that stopped sending never reached the check:

- `deadline_ms: 5_000` against a silent server waited 60 s, twelve times the limit asked for.
- The answer was `:unreachable`, not the documented `:timeout`, so a caller could not tell a stalled download
  from a dead network.

The PR's deadline test covers the trickling server only, where each chunk does arrive. `Req.Test` cannot stall,
so the real shape was checked with a scratch script on a raw `:gen_tcp` socket: silence after the headers and
silence after the first chunk both end in `{:error, %Req.TransportError{reason: :timeout}}` at the
`receive_timeout` given.

Fixed: `receive_timeout` is now `min(@download_timeout, deadline_ms)`, a transport `:timeout` answers
`{:error, :timeout}`, and the doc says so. A connect timeout takes the same path.

Two limits stay on record:

- It is still not a hard cap. Bytes arriving until just before the deadline, then silence, can run one more
  `receive_timeout` past it. A hard cap needs a second process to kill the request, which this does not earn.
- The new test pins the mapping (it fails with the clause removed). The `min/2` cannot be seen through
  `Req.Test`, and `@api_base` is fixed, so no test can point a real socket at it. The scratch script is the only
  evidence for that half.

### NITPICK — the moduledoc's scope line left the download out (fixed)

"Scope is deliberately narrow" listed sending and `getUpdates`. It now names `download_file/3`.

### NITPICK — a bad `:deadline_ms` is ignored while a bad `:max_bytes` is refused (not fixed)

`positive_or/2` turns `deadline_ms: 0` or `"5000"` into the default, where `:max_bytes` answers
`:invalid_max_bytes`. The size cap guards memory, so refusing is right there. A wrong deadline falls back to a
safe value. Not worth a new error reason.

## Checked and sound

- **`failure_reason/1` has no catch-all, on purpose.** The previous `inspect(reason)` took anything, and this
  repo has had a redaction crash on a failed send, so this was read closely. Every `{:error, _}` of `Req.get/2`
  and `Req.post/2` is an exception: `Req.Finch.normalize_error/1` passes exceptions through and the adapter has
  no other error shape. A catch-all would be unreachable.
- **No decompression past the cap.** `Req.Steps.compressed/1` only applies when `into` is nil, so no
  `accept-encoding` is sent, and `decompress_body` skips a streamed body.
- **The collector sees `{:data, _}` only.** Req's Finch adapter handles status, headers and trailers itself.
- **The Req floor holds.** Core requires `~> 0.5`, and `get_private`, `put_private` and `into:` are all older.
- **`file_path/1`** allows no `?`, `#`, `%` or `..`, so Telegram's answer cannot reshape the URL.
- **The `@spec`'s `:not_configured | :deleted`** matches `Integrations.get_credentials/2`.
- **No `inspect` of a request error is left** in `telegram.ex`.

No module calls this yet, so the wider `:timeout` meaning breaks nobody.
