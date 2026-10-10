# PR #923 — Opt-in permanent default-locale redirect with a bounded cache

**Author:** timujinne · **Merged:** 2026-10-10 (71590040c) · **Reviewer:** Claude · **Released in:** 2.60.3

## Summary

With `default_language_no_prefix` on, `/<default>/...` redirects to the prefixless URL. That redirect has been a 302
since #861's era (`Phoenix.Controller.redirect/2` sends `conn.status || 302`). The PR adds an opt-in
`config :phoenix_kit, :default_locale_redirect, status: 301, max_age: 86_400` for hosts that want search engines to see
a permanent redirect. `maybe_permanent_redirect/1` sets the status (301/308 or the atoms) and
`cache-control: private, max-age=<max_age>` for GET and HEAD only. Other methods, an unset/`false` option and a
misconfigured option keep the 302; a misconfiguration is logged once per node via `:persistent_term`.

Verdict: correct and well bounded. No bugs found.

## Checked

- **POST bodies:** non-GET/HEAD never leave the 302 path, so the "a 301 would discard a POST body" incident stays closed.
- **Cache risk:** which language is the default is a runtime setting, so an uncapped 301 could pin a browser to a stale
  shape. `private` + a finite `max-age` bounds it, and `private` keeps the session-cookie-carrying response out of shared
  caches. Plug only adds its own default `cache-control` when none is set, so the header survives.
- **`Phoenix.Controller.redirect/2`** honours a pre-set `conn.status` (verified by the tests asserting 301/308).
- **Option shapes:** `%{}`, `301`, `true`, `[]`, an unknown atom and 307 all fall to the 302 with one warning;
  `Keyword.keyword?/1` guards the `Keyword.get`.
- **Tests:** `auth_locale_test.exs` is `async: false`, so the `Application` env and `:persistent_term` flag mutations
  cannot leak; each `put_redirect_config/1` restores both. 45 tests, 0 failures.
- **Only caller:** `redirect_default_locale_to_clean_url/2` is the single default-locale canonicalising redirect, so
  nothing else needs the option.

## Findings

- **NITPICK — an invalid `max_age` falls back to one day silently.** `max_age: "1h"`, `-1` or `3600.0` get 86400 with no
  log, while a bad `status` warns. It is documented ("one day when missing or invalid") and the fallback is the safe
  direction (a bounded cache), so left as is rather than widening the warn-once path.
- **NITPICK — the misconfiguration warning only fires on the first matching request,** not at boot, and
  `mix phoenix_kit.doctor` does not check the option. Cheap to add later if hosts trip over it; not worth a release.

## Gate fix shipped alongside (not from this PR)

`mix precommit` failed on main before this release: dialyzer reported `pattern_match … Pattern: false, Type: true` at
`lib/modules/storage/services/hdr.ex:1`. Cause: `mp_images/2` (commit 003ea3c11, HDR gain-map detection) guarded
`is_integer(ifd)` / `is_integer(count)` on `int/4`, which always returns an integer. Replaced the `with` by an `if` on
the IFD bound (credo rejected the reduced `with`); HDR and locale tests pass (57, 0 failures).
