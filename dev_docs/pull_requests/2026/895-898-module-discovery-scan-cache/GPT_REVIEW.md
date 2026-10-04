# PRs #895 and #898 — GPT release recheck

Reviewed the published 2.52.0 tag (`72c9b8127`) against 2.51.0, including the post-merge attribute restoration.

No additional defect found. The restored `@hash_memo_key` and `@settled_after_seconds` make the memo usable; the cold-scan lock is restricted to the local node. Runtime consumers use the persistent scan cache, boot/rescan refresh it, and registration/unregistration invalidate it. Compiler consumers keep reading disk. The fingerprint covers code-path directories, app files, dependent beams and configured modules; recent timestamps prevent memoization. Files replaced with identical size and preserved timestamps remain the documented limitation.

The release's tests measure actual beam reads, include a non-vacuous fixture dependency, and exercise both the router recompile hook and LiveView mounts/toggles. See the [complete release recheck](../../../reviews/2026-10-04-2.52.0-release/GPT_REVIEW.md) for validation and package provenance.
