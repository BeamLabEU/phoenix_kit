# Claude Review — PR #1041

**PR:** Add client metadata documents, dynamic client registration and a client policy for the
OAuth server (timujinne)
**Reviewer:** Claude Opus 5.5, with an independent reviewer per layer of the stack
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep; fixes are on `main`)

The OAuth stack #1039–#1043 was reviewed one layer at a time, each against the current `main`
(so a problem a later layer already fixed is noted, not reopened). V233 and V234 are unreleased,
so the schema changes below amend V234 rather than adding V235. The manifest was regenerated and
the chain hash restamped.

## Verdict

No critical or high bug. The SSRF guard holds:
- https on port 443 only;
- every resolved address must be public, and the connection goes to the checked address (no
  DNS rebinding);
- no redirects;
- size and time limits, HTTP/1 only, and a JSON content type required.

The `RemoteFetch` changes are off by default for existing callers. The client policy compares
whole hosts, and fails closed when the settings cannot be read. Deleting a client cannot race a
consent. `oauth_test_seams` is compile-time and set only in this repo's test config.

## Findings

### BUG - MEDIUM — anyone could grow the client table without limit and push real clients off the list (fixed, 601e0f724)
Each new document URL that served a valid document became a stored row, before any sign-in. The
only cap was 20 a minute per network, and rows lived at least a day. A flood also hid real
clients from the admin list, which is newest-first and capped at 200. There is now an
install-wide ceiling, `api_oauth_cimd_clients_ceiling` (default 1000), on metadata-document
clients without a grant inserted in the last 24 h. It is checked before a new URL is fetched. The
admin list shows pre-registered clients and clients in use first.

### NITPICK — a client id URL with path `/` was accepted against the moduledoc (fixed, 4ce0e36fc)
### NITPICK — the register controller's moduledoc said "counted before anything is read" (fixed, 4ce0e36fc)

## Open
- **Download slots.** The four download slots (each up to 8 s; DNS has no timeout of its own)
  can be kept busy by a couple of networks. While they are, a client whose cached document has
  expired gets 503. Two fixes are possible: a per-network cap on fetches in flight, or serving a
  recently stale row on `:busy`. Both change behaviour that deserves its own PR.
- **The client ceiling is counted without a lock.** Concurrent fetches can pass it by at most
  `api_oauth_cimd_concurrency`. This is documented.
