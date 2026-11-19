# Claude Review — PR #1040

**PR:** Add the authorization code flow for pre-registered OAuth clients (timujinne)
**Reviewer:** Claude Opus 5.5, with an independent reviewer per layer of the stack
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep; fixes are on `main`)

The OAuth stack #1039–#1043 was reviewed one layer at a time, each against the current `main`
(so a problem a later layer already fixed is noted, not reopened). V233 and V234 are unreleased,
so the schema changes below amend V234 rather than adding V235. The manifest was regenerated and
the chain hash restamped.

## Verdict

No critical, high or medium bug. Checked and sound:
- **Authorize:** the client and `redirect_uri` are checked first; the redirect is an exact
  match, with the port ignored only for the `127.0.0.1` / `[::1]` literals; PKCE is S256
  only; `resource` and `state` are checked.
- **No open redirect:** an error is redirected only for a pre-registered client, after its URI
  was confirmed.
- **Consent:** the id is 256 bits, stored only as an HMAC bound to an HttpOnly cookie, and used
  once by one atomic UPDATE. The page is CSRF-protected and refuses impersonated sessions,
  service users and managed organizations.
- **Token endpoint:** a code is single-use with a 60 s life, and PKCE is checked in constant
  time. Refresh rotation is serialized under the grant lock.
- **Discovery:** the metadata comes from the canonical origin, never the Host header.
- **Pages:** HEEx-escaped and frame-proof.
- **Language:** the per-request language choice is justified. `/oauth` is a reserved,
  locale-less segment, and a chosen language travels in `?lang=`, never in the session.

## Findings

### IMPROVEMENT - MEDIUM — a few networks could hold every waiting request (fixed, b1308b2c4)
Anonymous `GET /oauth/authorize` stores a request for 600 s, under a single install-wide ceiling
of 1000. With 30 requests a minute per network, four networks could keep the table full and every
real sign-in got the busy page. Requests now keep `network_hash` (a SHA-256 of
`IpAddress.network/1`, never the address; V234), and `Requests.create/2` also refuses a network
that holds `api_oauth_requests_per_network` live requests (default 20). It is counted under the
same advisory lock as the ceiling.

### IMPROVEMENT - MEDIUM — `/oauth/token` and `/oauth/revoke` answers were unreadable from a browser (fixed, 7815831a1)
They now send `access-control-allow-origin: *`, like the metadata documents. No cookie or other
ambient credential is involved.

### NITPICK — the request-log filter missed chardata messages (fixed, 4ce0e36fc)

## Not changed
- Two processes of one client refreshing with the same token at once can end the connection: one
  of them takes the retry path, and the other's later refresh reads as reuse. This is the
  documented trade-off for theft detection. A client must keep only the newest answer.
