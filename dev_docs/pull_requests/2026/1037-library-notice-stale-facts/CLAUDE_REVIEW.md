# PR #1037 — Tell a page that ran an outdated copy of the install facts apart from missing facts

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; two gaps fixed in a follow-up commit

Merged into `main` as 804164949.

When `window.PHOENIX_KIT_LIBS` lacks a library key, the loader still reports `reason: "facts"` at once. Then, when the
page has an undigested `phoenix_kit_modules.js` tag, it fetches that file once with `cache: "reload"`. If the server's
copy names the key, the failure becomes `reason: "stale"`, and the notice, console and `data-stale` copy all say
"reload the page".

Checked:
- **Why the stale copy happens, and whether a reload helps.** Phoenix's `static_path/2` adds `?vsn=d` to undigested
  assets, and Plug.Static answers those with `public, max-age=31536000, immutable`. So a browser keeps an old facts
  file for a year, and a normal reload does not revalidate it. A `cache: "reload"` fetch of the same URL (same cache
  key, query included) writes the fresh response into the HTTP cache. That is why the PR's "a plain reload works"
  claim holds.
- **Repeat reporting.** The admin stubs ask again every few seconds. `pkFactsFail` returns early on `stale`, and for a
  `facts` record it calls `pkLibFail` with the same url and reason, which `pkLibFail` already ignores. So there is no
  repeated console line or event, as the tests say.
- **The notice.** `_render` rebuilds the whole list on every event, so the `facts` → `stale` switch replaces the row
  instead of adding one. The stale record's url is the facts file's, so dismissing the `facts` row does not hide the
  `stale` one. That is correct: it is new advice.
- **The CSP listener.** It matches failures by url. A `stale` record exists only after the fetch of that url succeeded,
  so no violation can be about it. A blocked fetch leaves the record `facts`.
- **gettext.** The msgid is in `default.pot` and all ten `.po` files. Nine are translated and `en` is empty as usual;
  none is fuzzy. The moved line references match `library_load_notice.ex` (68, 72, 86).
- **Size.** The public file is 296 531 bytes after the follow-up, under the new 292 KiB (299 008 B) budget.

## Findings

### IMPROVEMENT - MEDIUM — a cached facts file from before `PHOENIX_KIT_LIBS` still got the "recompile" advice

`pkFactsFail` fetched only when `window.PHOENIX_KIT_LIBS` was set: a page whose facts script never ran has no copy to
call outdated. But `PHOENIX_KIT_LIBS` was added on 2026-10-08 (998286b50). The facts file has existed since 2026-08-03
(64d1dcdce), when it set only `PHOENIX_KIT_PREFIX` and `PHOENIX_KIT_CONSENT_AVAILABLE`. A host upgrading across that
change, with the old file held for a year by the immutable `?vsn=d` header, ran a copy with no `PHOENIX_KIT_LIBS` at
all. That is the PR's own scenario in its most likely form, and it kept the misleading "recompile / run
phoenix_kit.update" text.

**Fixed:** "the page ran some copy of the facts" now also counts
`typeof window.PHOENIX_KIT_CONSENT_AVAILABLE === "boolean"`, which only the facts file writes, in every version.
`PHOENIX_KIT_PREFIX` is not used: the `phoenix_kit_globals` layout component writes it too, so it would make a blocked
facts script look outdated. Tests cover both: a pre-LIBS copy becomes `stale`, and a prefix alone causes no fetch.

### IMPROVEMENT - MEDIUM — the server's copy was read only in its unminified shape

The PR read the fetched file with `/^window\.PHOENIX_KIT_LIBS\s*=\s*(\{.*\});?\s*$/m` + `JSON.parse`, which assumes
one assignment per line with quoted keys. Some hosts run the facts file through their own esbuild. The doctor's
`admin_file_in_facts/1` already reads that shape loosely, and `test/fixtures/phoenix_kit_modules.esbuild.min.js` is
such a file: one line, `window.PHOENIX_KIT_PREFIX=…,…,window.PHOENIX_KIT_LIBS={admin:{file:"…",cdn:null},…}`. On those
hosts the regex never matched, so a stale page stayed `facts` with the wrong advice.

**Fixed:** `pkFreshFacts` now keeps the response text, and `pkFactsName(text, key)` reads it the doctor's way. It finds
the object after `PHOENIX_KIT_LIBS` by counting braces, then tests for `key: { … file: "…" }` with optional quotes. The
existing "stays `facts`" cases (no facts line, `{not json}`, a copy without the key) still pass. A new test reads the
real minified fixture: `admin` and `fresco` become `stale`, and an unknown key stays `facts`.

### NITPICK — limits the PR states, left as they are

The two console lines on a stale page (`facts`, then `stale`), the unretried fetch, and the CORS / `connect-src` limit
for a cross-origin facts file are described in the PR. They are reasonable trade-offs.

## Validation

- `node --test test/js/*.test.cjs`: 892 tests, 0 failures. The two new loader tests fail against the PR's
  `phoenix_kit.js`.
- `mix precommit`: exit 0 (compile, credo --strict, dialyzer, test.compile, JS tests).
