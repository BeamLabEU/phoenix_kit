# PR #990 — Keep the admin JavaScript off public pages

**Author:** timujinne · **Reviewer:** Claude · **Status:** open draft · **Reviewed at:** `648ce18d4`
**Verdict:** the split is sound; fix the three bugs below before merging. Review only: this is an unmerged
draft on a contributor's branch, so nothing here has been applied.

Splits `phoenix_kit.js` into a public half with a stub per admin hook, and `phoenix_kit_admin.js`, loaded by the
first stub to mount. Chart.js becomes its own vendored library, and production output is minified.

## How this was checked

- **Run in real Chromium** against LiveView 1.2.13, using the PR's shipped files and a hand-built facts file: the
  three bugs and the `PHOENIX_KIT_LIB_BASE` finding.
- **Read, not run:** the other findings, except where one says otherwise.
- The reviewer re-read the code of every finding. The browser runs were done by a review agent and were not
  repeated.
- `node --test test/js/*.test.cjs` at the PR head: 787 of 787. `mix test` and dialyzer were not run.
- The moved hook bodies, the `UploadManager` stand-in internals and the early-press replay were not reviewed in
  depth. The PR's tests cover them and pass.

## Merging with main

One conflict, in `priv/static/assets/phoenix_kit.js`, checked against `bbee119bd`. It is not #1023: all of
#1023's changes, and the recorder fixes from its review, merge cleanly. `a879f43dd` (the password eye button) put
`hideRevealedPasswords` directly above `PkHashHighlight`, which this PR moves out.

Keep the password block in `phoenix_kit.js`, because login and registration need it, and drop `PkHashHighlight`.
Taking the PR's side drops the password block. With that resolution the JS suite passed 799 of 799 and the file
stayed under its 272 KiB budget (measured before `bbee119bd`).

## Findings

### BUG - MEDIUM — a stub's `mounted` is always asynchronous, so a `push_event` in the element's first diff is lost

`phoenix_kit.js:4675`. `loadAdminBundle().then(...)` defers the real `mounted` to a microtask even when the bundle
is already loaded. LiveView mounts hooks and dispatches events in one synchronous stack, so `handleEvent` is not
registered yet when the event fires.

`module.ex:407` and the PR body confine the loss to the window before the bundle arrives, and the early start is
said to narrow that to a session's first admin page. In fact the window opens on every mount, for the whole
session.

Run with the bundle loaded and idle, one diff adding two hooks plus a `push_event`: the plain hook received it,
the stubbed hook mounted and did not. Nothing in core or the emails module depends on this today, so it is a
broken contract rather than a live failure, but `scope: :admin` is a new public promise to modules.

Fix: when `window.PhoenixKitAdminLoaded` is set, install the real hook and call `mounted` synchronously.

### BUG - MEDIUM — one failed bundle request leaves every admin hook on that page dead

`phoenix_kit.js:4556`, `:4675-4706`. `mounted` fires once per element and a stub has no `reconnected`, so stubs
that shared the failed request, or mounted during the 4 s pause, never try again. The early start makes this more
likely: its failure opens the pause just before the socket joins, and the first real mounts are refused without a
request.

The comment gives "would stay dead until reloaded" as the reason for having no attempt cap, but on the page that
failed, that is still what happens. The guide's "heals on the next admin page" is accurate, and needs a live
navigation.

Run with the first request answering 503, then a socket disconnect and reconnect and a 5.5 s wait: the server saw
exactly one request and the hook never mounted. One 503 during a deploy on `/admin/media` leaves uploads, drag and
drop and the viewer dead until the person navigates away. `admin_split.test.cjs:430` advances the clock past the
pause before mounting, so it misses this ordering.

Fix: a refused or failed stub retries on a timer after the pause.

### BUG - MEDIUM — with both vendored tags deferred, the early start can kill every admin hook

`phoenix_kit.js:4726-4734`, against the claims at `:145` and `guides/public-and-admin-javascript.md:55`. A deferred
script runs at `readyState === "interactive"`, so the `setTimeout(0)` branch is taken, and it can fire before a
slower deferred `phoenix_kit_modules.js` has arrived. The load fails on the missing facts, `adminRetryAt` is set,
and the stubs mounting next are refused with no request.

Run with `defer` on both tags and the facts file 800 ms slower: `PHOENIX_KIT_LIBS` did arrive, no admin request was
ever made, and the console told the person to run `mix phoenix_kit.update`, which is the wrong advice. The docs
call deferring safe. No host in the workspace defers `phoenix_kit.js`, so this waits for the first that does.

Fix: skip the early start while `window.PHOENIX_KIT_LIBS` is missing, and open no pause on a missing-facts failure.

### IMPROVEMENT - MEDIUM — an upgrade can lose all admin JS with no build-time signal

`integration.ex:1507-1510`, `phoenix_kit.doctor.ex:2408`. `warn_missing_js_compiler/2` stays quiet unless a module
declares `js_sources/0`, but the admin bundle now needs the facts file for core alone. A host with no compiler and
no modules tag upgrades, compiles cleanly and loses all 40 admin hooks, where on main only the viewer libraries
failed. One host in the workspace is wired this way. The signal is a console error at runtime. The doctor also
passes a host with the compiler but no facts tag, since it only inspects the disk.

### IMPROVEMENT - MEDIUM — "nothing in the host's code changes" is not true for one host

`guides/public-and-admin-javascript.md:15`. One host spreads `window.PhoenixKitHooks.TableCardView` and adds its own
`updated()` calling `this.applyMode`. Before the bundle arrives the stub has no `applyMode`, so a patch to that
element throws. After it arrives, `Object.keys(real).forEach(...)` silently replaces the host's `updated`. The guide
documents the replacement but not the `TypeError`.

### IMPROVEMENT - MEDIUM — `js_minifier` naming a host module never works on a clean build

`viewer_libraries.ex:261`, documented at the guide's line 75. The install puts `:phoenix_kit_js_sources` first in
`:compilers`, so a host's own module is not compiled yet in a fresh release build. `apply/3` raises, the `rescue`
makes it `{:error, _}`, and the readable files ship, with a note saying "Install esbuild", which is not the problem.
`minify/1` with an uncompiled module was run; the compiler order was read. Say the module must come from a
dependency, and word the note per cause.

### IMPROVEMENT - MEDIUM — the sidebar scroll restore no longer runs before paint on a full load

`phoenix_kit_admin.js:2004`, `:2077-2086`. `early()` used to run at `DOMContentLoaded`. It now runs when the bundle
arrives, and that request starts at `DOMContentLoaded` at the earliest, so a scrolled sidebar is likely to paint at
the top and jump. The comment at `:2004` is no longer true. Live redirects are unaffected. The paint was not
measured. A few lines of restore in the public file would do it.

### IMPROVEMENT - MEDIUM — `window.PHOENIX_KIT_LIB_BASE` can be clobbered from the DOM (already on main)

`phoenix_kit.js:159` here, `:152` on main. `String(window.PHOENIX_KIT_LIB_BASE)` accepts a named element, and the
variable is unset on a default host. Run: `<a id="PHOENIX_KIT_LIB_BASE" href="…/evil/">` in the body made the page
fetch and execute `/evil/admin-….js`.

Reach is narrow. Core's `HtmlSanitizer` strips `id`, so it needs a host rendering less-sanitized HTML, and a strict
CSP blocks it. This is not a regression, but the PR rewrites this function and makes it load more code, so it is
the moment for the one-line fix: `typeof window.PHOENIX_KIT_LIB_BASE === "string"`.

### NITPICK — stale comments and a silent class-based hook

- `avatar_crop.ex:94`, `markdown_editor.ex:85` and `layout_wrapper.ex:1339` still place moved code in
  `phoenix_kit.js`.
- A class-based module hook behind a stub does nothing, with no message. It is documented as unsupported, but one
  `console.error` would help.

## Not confirmed

- In production both files are minified again on every `mix compile`, with no caching. Cost only, from reading.
- A default Phoenix Dockerfile may run `mix compile` before esbuild is installed, shipping readable files despite
  the size table. The guide does say to run `mix assets.setup` first. Not tested.

## Checked and sound

- **The hook lists agree:** 35 public and 40 admin as claimed, and every literal `phx-hook` in `lib/` resolves in
  one of the two files. A free-variable scan of the public file finds nothing undefined.
- **No admin hook in the auth or maintenance templates searched.** Sibling uses looked at are admin or dashboard.
- **The stub lifecycle:** the real hook lands on LiveView's own instance, a stub destroyed while loading never
  mounts, and overlapping mounts share one request.
- **Base URL order and digested names** are correct, and better than main for a host that bundles the file.
- **Minified output runs:** real esbuild output of both files resolves all 40 hooks, and sizes match the table to
  within tens of bytes (esbuild 0.28).
- **Chart.js** matches jsDelivr's 4.5.1 byte for byte.
- **An older core** accepts the extra `js_sources/0` keys, so `scope: :admin` degrades to a public bundle as claimed.
