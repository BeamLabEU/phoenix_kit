# Claude review — PR #910 (2026-10-07)

**Verdict:** sound; no bugs found. One nitpick and two notes recorded; nothing changed in `lib/`.

Scope: behind a proxy that writes the port (Caddy's `{remote}`), `X-Forwarded-For` carries
`203.0.113.7:28858` / `[2001:db8::7]:28858`, which `IpAddress` could not parse, so every visitor read as the
proxy. The PR strips the port, reports an IPv4-mapped `::ffff:a.b.c.d` as `a.b.c.d`, and moves a session stored
with the proxy's loopback/private address to the visitor's once, instead of reading it as "changed IP" forever.

## Traced, no finding

- **Port stripping is anchored on both shapes.** Probed through `client_address/1` with `203.0.113.7:28858`,
  `[2001:db8::7]:28858`, `[::ffff:1.2.3.4]:80`, bare `::ffff:1.2.3.4`, bare `2001:db8::1:443` (left alone, an
  address), `1.2.3.4:` (not an address, falls back to the peer), an out-of-range port, a trailing space, a
  zone id, and a two-entry header whose last entry carries a port. All came back as documented.
- **The trusted header is unchanged.** Still only read when the peer is loopback/private, still the LAST
  `x-forwarded-for` entry, so a visitor-supplied first entry cannot be chosen.
- **Every address reader goes through the new path.** `rg` over `lib/` finds no other `x-forwarded-for` /
  `x-real-ip` / `remote_ip` reader outside `IpAddress`; `extract_ip_address/1`, `client_address/1`,
  `client_address_from_socket/1` and `parse/1` all end in `format_client/1`.
- **The rebind race is handled.** The `UPDATE` is conditional on the stored value, so of two concurrent
  requests one moves it; the loser re-reads the winner's address (or the stored one for a row signed out
  meanwhile) and is checked against that. `local_address?(nil)` is false, so a session with no stored
  address is never rebound.
- **Rebind runs only when fingerprinting is on**, which is the only time the stored address is compared.
- The PR's own tests (36 across the four files) pass.

## NOTE — the rebind is a deliberate loosening of strict mode

The moduledoc and CHANGELOG say so plainly: a user agent is easy to copy, so a stolen token with the
browser's user agent, sent through the proxy, moves once. What bounds it is that it moves only from a
private/loopback stored address to a public one, once. No change asked for.

## NOTE — upgrade effects are documented, not code

`WebsiteAccess.AllowedAddresses` compares exactly, so an allowed address written as the proxy's
(`172.18.0.8`) or as `::ffff:a.b.c.d` stops matching. Both are in the CHANGELOG "Upgrading" section with
the action needed.

## NITPICK — `verify_session_fingerprint` computes the address and user-agent hash twice per request

`proxy_rebind_address/3` and `verify_fingerprint/4` each call `get_ip_address/1` and `hash_user_agent/1`.
Both are a header read and a SHA-256; negligible, not worth threading the values through.
