# PR #1019 — Fix logout landing on the kit's mount, and rebuild remembered sessions on every page

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; nothing to fix

Two sign-in problems from a host. A logout under `url_prefix` probed the bare mount point, which a host's catch-all route
answers, so it landed on that host's "no such user" page. And a remembered session came back only on pages that ran the
kit's fetch plugs, so a host's public pages showed a signed-out visitor until a kit page was opened.

## Checked and sound

- **The mount point is the only thing dropped.** `bare_mount?/1` compares `path("/")` without its trailing slash to
  `prefix_base/0`, so `/phoenix_kit/en` stays a candidate, a site with the default language prefixless still falls to
  `/`, and a chain with no routable home ends on the terminal. `home_path/2` builds its own candidates and is not touched.
- **The rebuild is the existing one.** `restore_remembered_session/1` calls `ensure_user_token/1`, so `remember_me_enabled`
  is honoured on read, the cookie is dropped when the switch is off, and the account stack comes back with it.
- **It is cheap on a page with nothing to do.** No cookie is verified unless the remember-me cookie is there, and a session
  that was never fetched passes through: `conn.private[:plug_session]` is what `Plug.Session` sets when it fetches.
- **A revoked token gains nothing.** The cookie's signature is all the plug checks, so a dead token does reach the session,
  and every reader then gets no user from `get_user_by_session_token/1`. That is what the fetch plugs always did.
- **No session is renewed.** `put_token_in_session/2` adds two keys and leaves the rest alone, so the CSRF token survives
  a rebuild on a request that already passed `protect_from_forgery`.
- **Before `WebsiteAccess` is the right place.** The maintenance gate reads the session's user token, and a remembered
  administrator would otherwise be turned away from a page that rebuilds the session one plug later.

## Findings

### NITPICK — no CHANGELOG entry (left, for the release)

The PR adds none, and the entry belongs to the release commit.

## Validation

The PR's own tests ran in the full suite on the pulled tree, with no failure in this code. See the direct commits' review
for that run: `dev_docs/pull_requests/2026/2026-11-05-direct-commits/CLAUDE_REVIEW.md`.
