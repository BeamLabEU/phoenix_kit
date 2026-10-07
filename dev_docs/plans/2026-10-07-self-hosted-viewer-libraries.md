# Plan: serve the viewer libraries from the host's own origin, and say so when they fail to load

Status: **proposal, for review. No code written.** Author: Claude (with Dmitri), 2026-10-07.

## The problem

`priv/static/assets/phoenix_kit.js` lazy-loads seven libraries from `cdn.jsdelivr.net` at runtime:

| Library | How it is loaded | Where it comes from today |
|---|---|---|
| Fresco (viewer) | `<script>` injected, pinned `gh/alexdont/fresco@v0.13.1` | Hex dep of core |
| Tessera (progressive rungs, deep zoom) | same, `@v0.3.8` | Hex dep of core |
| Etcher (annotations) | same, `@v0.19.0` | Hex dep of core |
| Leaf (editor) | same, `@v0.8.0` | Hex dep of core |
| SortableJS 1.15.0 | `<script>` injected, `npm/sortablejs` | npm only |
| Panzoom 4.6.0 | `<script>` injected, `npm/@panzoom/panzoom` | npm only |
| wavesurfer.js 7 | dynamic `import()` of the ESM build | npm only |

**Audit gap found in review (verified):** the table lists only what `phoenix_kit.js` loads. The
dependency bundles load things too: Etcher's own `SORTABLE_CDN` (`deps/etcher/priv/static/etcher.js`)
pulls SortableJS from jsDelivr the first time its Customise dialog opens. Etcher uses `window.Sortable`
when it is already present, and falls back to native drag-and-drop when it cannot load it. Any "no
third-party request" claim has to cover the whole graph, not just the seven rows above.

Consequences seen in the field (a host with a strict Content-Security-Policy, Fotki, 2026-10-07):

1. **A host whose CSP is `script-src 'self'` silently loses the photo viewer's zoom, its
   sharper-version swap, annotations, the editor, sortable lists, panzoom and the waveform.**
   The only symptom was a `console.error`, so the viewer looked "half working" and a
   whole investigation was spent finding it.
2. Every viewer open makes third-party requests (privacy, offline and air-gapped installs, CDN
   outages, corporate proxies).
3. The CDN tag has to be kept in lock-step with the Hex version by hand. It has drifted twice
   (leaf, etcher), and `test/phoenix_kit_web/vendored_cdn_pins_test.exs` exists only to catch that.

PhoenixKit cannot and should not change a host's CSP. It *can* stop needing a third-party origin,
and it can make the failure visible. This plan does both, in that order of urgency.

## What already exists that this builds on

- `Mix.Tasks.Compile.PhoenixKitJsSources` already copies `phoenix_kit.js` and the module bundle into
  every host's `priv/static/assets/vendor/` on **every** `mix compile`, diffing first so unchanged
  files are untouched. It already writes a small "install facts" preamble
  (`window.PHOENIX_KIT_PREFIX`, `PHOENIX_KIT_CONSENT_AVAILABLE`) into a file that is already
  `<script>`-tagged. A new fact needs no layout edit and no `phoenix_kit.update` backfill.
- Fresco, Tessera, Etcher and Leaf are Hex deps of core with their JS in `priv/static`, resolvable
  with `:code.priv_dir/1` (the same call the compiler uses for module bundles). The lock names the
  exact version.
- The loaders already honour a **pre-import** (`window.{Fresco,Tessera,Etcher}Hooks` present means
  "skip the CDN"). That behaviour stays and still wins.
- The waveform hook already degrades gracefully ("Library unavailable (offline / CSP): reveal the
  native controls"). The other loaders only `console.error`.

## Goals and non-goals

Goals:
- A host with the default install works under `script-src 'self'` with no CSP edit.
- No third-party request for any PhoenixKit library in the default path.
- When a library still cannot load (CSP, 404, offline), an administrator is told, in the page, what
  failed and what to do. End users are not alarmed.
- The version pin has one source of truth (the lockfile / manifest), not a hand-edited string.

Non-goals: changing how any library behaves; bundling the libraries into `phoenix_kit.js` (it is
~650 KB already and they are rarely all needed, so lazy loading stays); a CSP helper or a CSP check
on the server (the host owns that policy).

## Part A: the visible-failure notice (ship first, independent of Part B)

This is small, useful on its own, and still needed after Part B because a 404, a missing
`:phoenix_kit_js_sources` compiler or a stale host build can all still stop a library loading.

### Detection (client, in `phoenix_kit.js`)

- One shared helper, `loadLibrary(name, url, opts)`, replaces the five hand-copied
  `script.onload` / `onerror` blocks (and gives wavesurfer's `import()` the same bookkeeping).
  It records failures in `window.__pkLibFailures[name] = { url, reason }`.
- `reason` is classified, not guessed: a document-level `securitypolicyviolation` listener
  (capture phase, installed once) matches the event's `blockedURI` to a library URL and records
  `"csp"` with the `effectiveDirective`; a plain `script.onerror` without a matching violation is
  `"load"` (a script error does not expose the HTTP status, so 404, network and offline are
  indistinguishable); a dynamic `import()` rejection is `"load"` too, but may be a parse error. See
  "Revised decisions" for the correlation rules.
- Retry is narrow: a failed classic script is removed and may be retried a bounded number of times.
  A failed `import()` of the same URL is **not** assumed to re-run a module whose evaluation failed,
  so for wavesurfer the error is terminal for the document and the notice recommends a reload once the
  cause is repaired.
- The `console.error` stays, but now names the likely cause and the fix.
- Dispatches `window` event `pk:library-failed` `{ name, url, reason, directive }`.

### Display (server-rendered shell, client-filled)

- JS strings in core are translated through server-rendered text, so the notice is a hidden
  `<div id="pk-library-notice" hidden phx-update="ignore" role="alert">` rendered by
  `LayoutWrapper` (admin layout) **only for an Owner, an Admin or a superadmin of the active scope**
  (not `can_access_admin_area?/1`, which is also true for any single-permission holder), with all its
  gettext
  copy in `data-*` attributes (title, the CSP text, the load text, the fix, a dismiss label).
- A hook `LibraryLoadNotice` reads `window.__pkLibFailures` on mount, listens for
  `pk:library-failed`, and fills and un-hides it. The message lists the failed libraries and says one
  of two things:
  - **CSP:** names the attempted URL, the blocked origin and the `effectiveDirective` (for example
    `script-src-elem`; never a blanket "edit `script-src`"). For a local asset the advice is to check
    the host's asset-serving configuration against its intended policy; "update and rebuild" is
    reserved for the case where the attempted URL is a CDN one.
  - **Load:** the library "could not be loaded or run" (with its URL), cause unknown. Check the
    network and that the build vendors the PhoenixKit JavaScript (`:phoenix_kit_js_sources` in
    `compilers`, or run `mix phoenix_kit.update`).
  - The copy states its uncertainty; it does not assert CSP or a 404 without evidence.
- Dismissal is remembered per browser session (`sessionStorage`, wrapped in try/catch like the rest
  of core's client storage; the notice works without it).
- End users get nothing: the viewer degrades as it does today. Hosts that use the dashboard layout
  rather than `LayoutWrapper` get the same element from the dashboard shell (to confirm).

### `mix phoenix_kit.doctor`

Add a "Viewer libraries" check: `:phoenix_kit_js_sources` present in `compilers`, and (after Part B)
every expected vendored file present and matching the lock. This catches the missing-compiler case
before a browser does.

## Part B: serve the libraries from the host's own origin

### Vendoring

- The compiler gains a second pass that copies each library into
  `priv/static/assets/vendor/lib/<name>-<version>.js` (diff-first, like the existing files):
  - Fresco, Tessera, Etcher, Leaf: from `:code.priv_dir(app)` plus a known relative path, with
    `<version>` from the *consumer's* `Application.spec(app, :vsn)` plus a short content hash
    (see the facts below). Version and hash in the name make each file cacheable for good and remove the
    hand-edited pin.
  - SortableJS, Panzoom, wavesurfer (npm-only): committed under core's own
    `priv/static/assets/vendor_libs/` with their licences (MIT, MIT, BSD-3) and a short
    `README` naming the exact upstream version and how it was fetched. The compiler copies them the
    same way. A small manifest (`name`, `version`, `path`, checksum) is the single list the compiler and
    tests read. **SortableJS is part of B1**, not B2: Etcher's Customise dialog needs it (see "Etcher's
    own SortableJS request" below), so "the four Hex-dep libraries" are not self-hosted without it.
    B2 is Panzoom and wavesurfer.
- The compiler writes the result into the install facts, using the **consumer's** loaded version and
  a content hash in the name (a path dependency can change bytes without changing its version):
  `window.PHOENIX_KIT_LIBS = { fresco: { file: "fresco-0.13.1-3f9a1c.js", cdn: null }, ... }`.
  `cdn` is `null` unless the host has opted in to a CDN fallback
  (`config :phoenix_kit, library_cdn_fallback: true`); when it has, the compiler writes a URL it builds
  from that app's loaded version and the known upstream path. **There is no CDN URL, tag or version
  hardcoded in `phoenix_kit.js` any more.**
- `mix phoenix_kit.update` and `phoenix_kit.install` call the same vendoring function for the library
  files and the facts, not only for `phoenix_kit.js` (today they copy just that one file, and the facts
  file is written only by the compiler). A host without the compiler therefore gets bundle, libraries
  and facts from a single step.

### Etcher's own SortableJS request

Etcher's Customise dialog calls `_withSortable`, which uses `window.Sortable` if present and otherwise
injects its own jsDelivr script, marking `this._sortableFailed` on that hook instance if the load fails
(then it falls back to native drag-and-drop). We must neither leave that request to the CDN nor let a
failed *local* load trigger it. Without rewriting upstream bundle strings:

- Core's `EtcherLayer` wrapper loads the local Sortable through the shared `loadLibrary`, in parallel
  with Etcher itself, and waits for both before calling Etcher's `mounted`.
- If Sortable loaded, `window.Sortable` exists and Etcher uses it. If it failed, the wrapper sets
  `self._sortableFailed = true` on the hook instance before `mounted`, so Etcher takes its native
  drag-and-drop path and **makes no CDN request**. (A host that opted in to the CDN fallback does not
  get the flag.)
- That flag is an Etcher internal. A test greps the installed `deps/etcher` bundle for
  `_sortableFailed` / `_withSortable` and fails loudly if upstream renames them. The durable fix is an
  upstream Etcher option (a local URL, or "never load from a CDN") for the Etcher maintainer; this is
  the bridge until then.

### Loading

- The bundle captures its own script URL **at evaluation time** (`document.currentScript.src`, which
  is unavailable later and for module scripts) and derives the library base from it, so `static_url`,
  an asset host or a path prefix work without configuration: `base = dirname(that URL) + "/lib/"`.
  There is no broad `src*="phoenix_kit"` selector (it can match `phoenix_kit_modules.js`). A host that
  bundles core's source into its own `app.js` (where `currentScript` names the wrong file) sets
  `window.PHOENIX_KIT_LIB_BASE` explicitly. Library file names come from the facts, looked up at
  **request time**, because the facts load after the core file.
- `loadLibrary` tries the vendored URL first. Order of preference, unchanged at the top:
  1. pre-imported global (`window.FrescoHooks` etc.), as today;
  2. vendored same-origin file named by `PHOENIX_KIT_LIBS`;
  3. **Nothing else, by default.** There is no built-in CDN path and no version guessing. With the
     facts present the library is local-only; if the facts name a `cdn` URL (the host opted in, URL
     built from its own loaded version) it is tried once after a failed local load. With the facts
     absent, the bundle does not invent a URL: it reports the failure and Part A's notice tells the
     host to recompile or run `mix phoenix_kit.update`. See "How a host gets the bundle and the
     facts" below.
- Wavesurfer: `import(url)` against the vendored ESM file (same-origin, so it satisfies `'self'`).

### Tests

- `vendored_cdn_pins_test.exs` is reshaped, not deleted: with no tag in the bundle, it now asserts
  that `phoenix_kit.js` contains **no** hardcoded `cdn.jsdelivr.net/gh/` pin, and that the compiler's
  output (file names and, when opted in, `cdn` URLs) names each Hex-dep library at the version the
  *consumer's* project loaded. The drift class it guards cannot occur.
- Compiler test (temp host dir): files are created at the versioned, content-hashed names, an unchanged
  compile does not touch them, a missing source is a loud compile error (like today's core file), and
  the facts preamble lists them. The same function run from `phoenix_kit.update` produces identical
  output.
- Etcher bridge: with the local Sortable failing, Etcher makes no request to any CDN and the Customise
  list still reorders by native drag-and-drop; with it loaded, Etcher uses the local copy.
- Node tests for `loadLibrary`: vendored URL used first, a CDN URL only when the facts name one (the
  host opted in); with the facts absent, no request and a recorded failure, CSP classification from a synthetic `securitypolicyviolation`, pre-import
  still wins, failures recorded once per library, the expected global validated after `onload`.
- ExUnit: the shared notice component renders for an Owner, an Admin and a superadmin of the active
  scope, and not for an anonymous user, an ordinary user, or a restricted single-permission holder
  (for example a media viewer). Both `LayoutWrapper` and the dashboard shell are covered.

## Phases

1. **Part A**: shared `loadLibrary` (in-flight promises, global validation); Fresco-before-layers
   ordering fix; CSP-aware failure notice for Owner/Admin/superadmin; doctor check.
2. **Part B1** (a partial rollout until acceptance below): vendor the four Hex-dep libraries **and
   SortableJS**, consumer-version and content-hashed names, facts in the compiler *and* in `update` /
   `install`; the Etcher bridge; local-only by default; no hardcoded CDN tag left in the bundle.
3. **Part B2**: Panzoom and wavesurfer, exact versions, provenance, notices.
4. **Acceptance for "no third-party request by default"**: the production-style build
   (`compile` → assets → `phx.digest`) and the enforced-CSP browser test over the whole graph. Only
   then is the claim made.

## How a host gets the bundle and the facts

The bundle (`phoenix_kit.js`) and the facts (`phoenix_kit_modules.js`, with `PHOENIX_KIT_LIBS`) must
arrive together, because the new bundle has nothing to fall back to. Today they do not always:
`install` and `update` copy only the bundle, and only the compiler writes the facts. The plan closes
that gap at the source instead of papering over it in the bundle:

- **Normal hosts** (`:phoenix_kit_js_sources` in `compilers`): the next `mix compile` after upgrading
  vendors bundle, libraries and facts together. A dependency upgrade always compiles, so there is no
  window in which a new bundle runs against old facts.
- **Hosts without the compiler** (they get a compile-time warning today): `mix phoenix_kit.update`
  now vendors bundle, libraries and facts itself, through the shared function.
- **Hosts that bundle core's source into their own `app.js`**: they set `window.PHOENIX_KIT_LIB_BASE`
  and `window.PHOENIX_KIT_LIBS` explicitly (documented), because neither the script URL nor the facts
  file is where the bundle expects.
- **Anything else** (facts absent): no guess is made. The failure is recorded and the admin notice says
  what to run. A wrong-version guess would be worse than a clear message, since a version-mismatched
  library renders normally and quietly stops honouring the server's API.

Fotki can then drop `https://cdn.jsdelivr.net` from its `script-src` (keeping `blob:` for images,
which Etcher needs), and its Tailwind `@source` line is unrelated to this.

## Bundle size: `phoenix_kit.js` should stay roughly neutral

`phoenix_kit.js` is already ~669 KB. The libraries themselves never go into it (they stay separate
lazy files, vendored next to it). What Part A and B *do* put in it is small and mostly **replaces**
code that is already there:

- The classic-script loader blocks (fresco, tessera, etcher, leaf, panzoom: about 800 bytes each,
  roughly 4 KB; plus SortableJS's, which sits inside its hook) are near-identical code. One shared `loadLibrary` replaces all of them.
- Added: the failure bookkeeping and the `securitypolicyviolation` classifier (~1 KB) and the
  `LibraryLoadNotice` hook (~1.5 KB). Net change is expected to be about zero to +1.5 KB (under
  0.3%).

Rule for the PR: report `wc -c priv/static/assets/phoenix_kit.js` (core's file, 668,901 bytes at the
time of writing; `priv/static/assets/vendor/phoenix_kit.js` is the generated host copy) before and
after, uncompressed and gzipped, and aim for roughly neutral. This is a target, not a hard cap:
see "Revised decisions" for why a hard cap is the wrong tool.

## Costs and risks

- **Disk in every host:** about 2.3 MB of vendored JS (Etcher 1.17 MB, Leaf 0.67 MB, Fresco 0.14 MB,
  Tessera 24 KB, plus the three npm files) even if a host never opens the annotation tools. They are
  fetched lazily, so no page pays for them. `mix phx.digest` gzips them.
- **Package size:** the npm trio adds a small amount to core's Hex package; licences must ship with
  them.
- **Version bumps of the npm trio** (SortableJS, Panzoom, wavesurfer) become a deliberate core change (update the file, the manifest and
  a test), instead of a one-line CDN edit. That is the point, but it is more ceremony.
- **Static path assumptions:** the base URL is derived from where `phoenix_kit.js` loaded, so it
  follows the host's own static setup. A host that serves `priv/static/assets/vendor` selectively
  (not as a directory) would miss `lib/`. The doctor check proves only that the files exist on disk;
  whether Plug.Static, a proxy or an asset host actually serves them is proved by the deployed-browser
  smoke test, not by doctor.
- **The notice is only as good as the classification.** Browsers differ slightly in
  `securitypolicyviolation` details; the fallback is the generic "could not be loaded" text, which is
  still better than silence.
- **A CDN choice that was deliberate.** The original authors may have wanted the CDN for bundle size
  or update speed. This plan keeps the lazy loading and the size profile, and keeps a CDN only as an
  explicit host opt-in.

## Alternatives considered

- **Document the CSP requirement only.** Cheapest, and worth doing regardless, but leaves every
  strict-CSP host broken until someone reads the docs, and keeps third-party requests.
- **A `ContentSecurityPolicy` helper listing the origins PhoenixKit needs.** Keeps the host in control
  and is easy, but it institutionalises the third-party dependency instead of removing it. Reasonable
  as a stop-gap for the fallback case; not the main fix.
- **Bundle everything into `phoenix_kit.js`.** Fixes CSP but makes every page download ~3 MB.
- **A host-side pre-import in each app's `app.js`** (already supported). Good for one host, but it
  covers only Fresco, Tessera and Etcher and has to be repeated everywhere.
- **Server-side CSP detection** (e.g. in doctor by fetching the host's own page). Fragile; the
  browser is the only place that knows what was blocked.

## Open questions for reviewers

All answered by the two reviews; kept for the record, **resolved**.

1. CDN fallback after Part B? **Resolved:** local-only by default; explicit host opt-in, with URLs the
   compiler builds from the consumer's loaded version; no built-in pin.
2. Audience for the notice? **Resolved:** the active scope's Owner, Admin or superadmin.
3. Server-side record of a failure? **Resolved:** no, not in v1.
4. npm trio ownership and wavesurfer plugins? **Resolved:** normal core dependency maintenance; exact
   versions, checksums and notices in one manifest; plugins vendored with their transitive assets when
   introduced.
5. `vendor/lib/` location? **Resolved:** default stays; `window.PHOENIX_KIT_LIB_BASE` overrides it.
6. Dashboard layout? **Resolved:** it has its own shell; one shared notice component serves both.
7. Fresco load-order guarantee? **Resolved:** it did not exist (verified); Part A chains Tessera and
   Etcher through Fresco's successful load.

## Codex review — 2026-10-07

**Verdict:** the direction is sound: keep lazy loading, serve the installed dependencies' own
bytes, and make failures visible. Part A can ship independently. Resolve the following issues
before treating Part B as implementation-ready. These comments supplement the proposal above;
where they disagree, the choice still needs to be made explicitly.

### Required corrections

1. **The seven core loaders are not the whole dependency graph.** The installed
   `deps/etcher/priv/static/etcher.js` has its own `SORTABLE_CDN` pointing at jsDelivr. Copying that
   file unchanged does not meet the no-third-party-request goal. Audit the shipped dependency
   bundles for runtime scripts, imports, workers and associated assets. Prefer an upstream Etcher
   loader API that accepts a local URL/shared loader and preserves standalone use. Preloading the
   local Sortable global before the relevant Etcher feature is another option after verifying its
   guard, but costs an extra download. Do not silently rewrite upstream bundle strings. This needs
   to be included in B1/B2 acceptance, not deferred until after claiming full self-hosting.

2. **Make CDN fallback opt-in, or narrow the privacy promise.** Automatically falling back on a
   local outage makes exactly the external request an offline/private host wants to avoid. My
   preference is local-only once the manifest is present, with explicit host opt-in for CDN fallback.
   A temporary legacy path when facts are absent can preserve older integrations, but document that
   those integrations still use the CDN. Generate any retained Hex-library fallback URLs from the
   host's resolved application version and known upstream path; a core hardcoded tag is not enough.
   `mix.exs` permits older Leaf/Fresco minors than this repository's lock resolves, so tests passing
   against core's lock do not establish that a consumer's fallback matches its installed Elixir API.

3. **A script error does not expose HTTP status.** The proposed test “fallback only on 404” cannot
   be implemented from `script.onerror`. Keep the result generic (`load`, possibly `timeout`),
   unless there is independent evidence; avoid adding a second fetch solely to diagnose status.
   An ESM rejection can also mean a parse/evaluation error, so it must not always be described as a
   network failure. After classic-script `onload`, validate the expected global/hook before marking
   success: a 200 response alone does not establish a usable library.
   See [HTMLScriptElement](https://developer.mozilla.org/en-US/docs/Web/API/HTMLScriptElement).

4. **CSP attribution is best-effort and asynchronous.** Cross-origin blocked URLs may be reduced
   to their origin; exact matching against the CDN file URL misses that case. Track pending attempts,
   normalise URLs, correlate full URLs or origins conservatively, and allow a later violation event
   to refine a generic failure. Do not attribute every same-origin policy event to every library.
   Ignore report-only violations for failure classification (`disposition`), and retain
   `effectiveDirective` so `script-src-elem` is represented accurately. The fallback text should
   admit uncertainty rather than assert CSP or 404 without evidence. See the
   [CSP reporting specification](https://www.w3.org/TR/CSP3/#strip-url-for-use-in-reports).

5. **Capture an asset base during script execution, with an explicit override for bundled hosts.**
   `document.currentScript` is unavailable in later hook callbacks and for module scripts. Even at
   evaluation time it can identify `app.js` if a host bundles the core source into that file, which
   gives the wrong neighbouring directory. Capture the standalone script URL immediately; support
   an explicit library base URL for bundled/custom integrations. Prefer the generated facts script's
   known location when appropriate, rather than a broad `src*="phoenix_kit"` selector that can pick
   `phoenix_kit_modules.js`. The facts currently live in the modules file, loaded **after** the core
   file; look up library filenames at request time, not at core evaluation time. See
   [currentScript](https://developer.mozilla.org/en-US/docs/Web/API/Document/currentScript).

6. **Self-hosted and same-origin are different guarantees.** An asset host can be operated by the
   application owner yet have a different origin, and therefore does not satisfy `'self'` on the
   page's origin. A cross-origin wavesurfer ESM file additionally needs working CORS and JavaScript
   MIME handling. Define the default as same-origin static serving, with explicit asset-host support
   under that host's CSP/CORS policy. A doctor filesystem check cannot prove that Plug.Static, a
   reverse proxy or an asset host actually serves the files; amend the claim that it “covers” selective
   static serving. Verify that with a deployed-browser smoke test.

7. **Enforce Fresco ordering; it is not guaranteed today.** Tessera's installed bundle checks
   `window.Fresco.onReady` in `mounted` and returns if unavailable. Independent async script loads
   can race regardless of parent/child DOM order. Chain Tessera's mount through Fresco's successful
   load, and verify Etcher's equivalent contract. Fresco's readiness API can then handle viewer
   instance readiness. Check required globals even when a layer was pre-imported. Also guard every
   wrapper against mounting after its LiveView hook has been destroyed during loading.

8. **The proposed audience is broader than “administrator”.**
   `Scope.can_access_admin_area?/1` includes any permission holder, including a restricted media
   viewer. For deployment diagnostics, prefer active-scope Owner/Admin role checks plus the explicit
   superadmin grant, rather than the admin-area gate. `Scope.superadmin?/1` alone tests the blanket
   permission and does not include Owner automatically. Keep the diagnostic shell inside the LiveView
   tree and use one shared component for LayoutWrapper and the separate dashboard layout, which
   exists and renders its own flash group. Include nested/host layout cases to avoid duplicate ids.

### Implementation refinements and acceptance checks

- Use one in-flight promise per library, shared by simultaneous mounts. Settle and clear waiting
  callbacks on error, avoid permanent stuck “loading” flags, and define a bounded retry policy.
  Report final failure once after any permitted fallback is exhausted; clear an old failure if a
  retry succeeds. A failed local attempt followed by successful fallback should not leave a broken
  library alert. Preserve wavesurfer's native controls fallback.
- Scope session dismissal to the failed library/version set, so dismissing Fresco does not hide a
  later Leaf failure. Remove window listeners in `destroyed`; render library names/URLs with
  `textContent`, and test notice behaviour after LiveView navigation. Explain that a completely
  missing core bundle cannot report its own absence; the doctor remains useful for that case.
- Use the **consumer's loaded application version**, not core's checked-in lock, for Hex assets.
  Add a content hash to versioned filenames if promising immutable caching: path dependencies can
  change bytes without changing `Application.spec(app, :vsn)`. Pin wavesurfer to an exact npm release
  rather than the current floating `@7`, record checksums/provenance and preserve all upstream
  notices. Check whether the selected ESM build has relative imports before copying just one file.
- Exercise a production-style `mix compile` → assets build → `mix phx.digest` flow. Runtime filename
  strings are not automatically rewritten into digest URLs; ensure the original named assets survive
  deployment, or generate a mapping to the actual deployed names. Retain old assets for rolling
  deployments/open tabs; avoid eager deletion during compile. Document cache headers separately
  from versioned naming.
- Add browser coverage under actual enforced CSP: zero third-party library requests, Etcher's
  Sortable-dependent UI, delayed Fresco versus fast Tessera, simultaneous mounts, navigation away
  during loading, absent expected globals, report-only policy, and successful recovery. Node mocks
  and layout rendering tests remain useful but cannot prove browser CSP or deployed static serving.
- Correct the bundle-size command: core's file is `priv/static/assets/phoenix_kit.js` (currently
  **668,901 bytes**), not `priv/static/assets/vendor/phoenix_kit.js`, which is a generated host path.
  There are **six** classic-script loaders including SortableJS, plus wavesurfer's import. Measure
  actual uncompressed and compressed change; prefer a small understandable helper over an arbitrary
  2 KB limit that forces another failure-prone lazy request merely to show the failure notice.

### Suggested answers to the open questions

1. Local-only by default with an explicit compatibility opt-in for CDN fallback.
2. Owner/Admin/superadmin deployment audience, respecting the current active scope.
3. No Activity entry or beacon in the first version: browser asset failures are operational
   diagnostics, and a new reporting endpoint adds authentication, deduplication and abuse concerns.
4. Vendor future plugins and their transitive assets when introduced; assign npm bumps to normal
   core dependency maintenance and record exact versions in the same manifest.
5. Keep the proposed directory default; expose a URL override for custom serving/bundling before
   introducing configurable filesystem layouts.
6. Yes: the dashboard has its own shell. Share the notice component and document host-layout use.
7. Preserve the libraries' readiness contracts and explicitly fix the current Fresco/Tessera race.

**Suggested phase adjustment:** keep A independent; make B1/B2 an explicitly partial rollout until
Etcher's nested loader and all npm assets are covered. Declare the no-third-party default achieved
only after a production-style browser test verifies the full graph. No application code was changed
as part of this review.

## Revised decisions after the Codex review (author, 2026-10-07)

Every claim in the review that I could check against the code was right; the points marked
"verified" below were confirmed in `deps/` and `lib/`. Where this section differs from the body
above, **this section wins** (the body's factual errors were also corrected in place).

### Accepted as written

- **Required 1, the nested Etcher loader (verified).** The no-third-party goal is not met by copying
  `etcher.js` unchanged. Decision: core's Etcher wrapper makes `window.Sortable` available from the
  local vendored copy before Etcher's Customise dialog can ask for it (Etcher already prefers
  `window.Sortable`), at a one-off ~40 KB lazy fetch. An upstream Etcher option to take a local URL
  is the cleaner long-term fix and stays on the list for its maintainer; we do not rewrite strings
  inside upstream bundles. **B1/B2 acceptance includes the whole graph:** an audit of every shipped
  dependency bundle (scripts, `import()`, workers, assets) and a browser test with zero third-party
  requests. Until that passes, B1/B2 are announced as a partial rollout.
- **Required 2, fallback policy.** Local-only by default once the manifest is present; CDN fallback
  only on an explicit host opt-in. With the facts absent there is **no** fallback and no old pin (see
  "Closing the second review"). Any retained fallback URL is generated from
  the **consumer's** loaded application version and the known upstream path, never from core's
  hardcoded tag: `mix.exs` allows older minors than core's lock (Leaf `~> 0.4.1 ... ~> 0.8.0`,
  Fresco `~> 0.10 ... ~> 0.13`), so a tag matching core's lock can mismatch a consumer's Elixir half.
  This answers open question 1.
- **Required 3, status and success.** `script.onerror` carries no HTTP status; results are `load` or
  `timeout`, with no extra diagnostic fetch. After classic-script `onload` the expected global/hook is
  validated before marking success. An ESM rejection is described as "could not load or run", not as
  a network failure.
- **Required 4, CSP correlation (best effort).** Track pending attempts; normalise and compare full
  URLs, falling back to origin comparison; ignore `disposition: "report"`; keep
  `effectiveDirective` (`script-src-elem`); let a later violation refine an earlier generic failure;
  never attribute an unrelated same-origin event to a library. The fallback text states uncertainty.
- **Required 5, asset base.** Capture the standalone script URL at core evaluation time (not in later
  callbacks); support an explicit `window.PHOENIX_KIT_LIB_BASE` (and a matching config) for hosts that
  bundle the core source into their own `app.js`, where `currentScript` would name the wrong file;
  do not use a broad `src*="phoenix_kit"` selector (it can match `phoenix_kit_modules.js`). The facts
  live in `phoenix_kit_modules.js`, which loads after the core file, so filenames are looked up at
  **request time**, never at core evaluation.
- **Required 6, same-origin versus self-hosted.** The default guarantee is same-origin static
  serving. An asset host is supported, under that host's own CSP/CORS and JavaScript MIME handling
  (relevant to the cross-origin wavesurfer ESM). The doctor check is reworded: it proves the files
  exist on disk, not that Plug.Static, a proxy or an asset host serves them. A deployed-browser smoke
  test is what proves serving.
- **Required 7, the Fresco race (verified).** Core's `TesseraLayer` wrapper loads Tessera
  independently of Fresco, and Tessera's `mounted` logs an error and returns when
  `window.Fresco.onReady` is missing (Etcher has the same dependency). Decision: chain Tessera's and
  Etcher's mounts through Fresco's successful load; check the required globals even when a layer was
  pre-imported; guard each wrapper against mounting after its hook was destroyed during loading. This
  is a real bug fix in its own right, independent of CSP, and can ship in Part A.
- **Required 8, audience (verified).** `can_access_admin_area?/1` is true for any holder of a single
  permission, a restricted media viewer included. The notice is for the active scope's Owner, Admin
  or superadmin (`Scope.superadmin?/1` does not imply Owner, so both are checked). One shared
  component is used by `LayoutWrapper` and the dashboard shell, kept inside the LiveView tree, with
  nested and host layouts checked for duplicate ids. Answers open questions 2 and 6.

### Implementation refinements adopted

- One in-flight promise per library, shared by simultaneous mounts; waiting callbacks are settled and
  cleared on error; no permanent "loading" flag; a bounded retry; one final failure report after any
  permitted fallback; a stale failure is cleared when a retry succeeds; wavesurfer keeps its native
  controls fallback.
- Dismissal is per failed library and version set; listeners removed in `destroyed`; library names and
  URLs rendered with `textContent`; tested across LiveView navigation. A completely missing core
  bundle cannot report its own absence, so the doctor check stays.
- Hex assets use the consumer's loaded version, with a **content hash in the filename** (a path
  dependency can change bytes without changing `Application.spec(app, :vsn)`; Fotki is exactly that
  case). wavesurfer is pinned to an exact npm release (not the floating `@7`), with checksums,
  provenance and upstream notices recorded; the selected ESM build is checked for relative imports
  before copying a single file.
- Production-style flow tested: `mix compile` → assets build → `mix phx.digest`. Runtime filename
  strings are not rewritten by the digest, so the original named files must survive deployment (or a
  mapping to deployed names is generated); old assets are kept for rolling deploys and open tabs, and
  the compiler never deletes eagerly. Cache headers are documented separately from versioned names.
- Browser coverage under an **enforced** CSP: zero third-party library requests, Etcher's
  Sortable-dependent UI, delayed Fresco with a fast Tessera, simultaneous mounts, navigation away
  during loading, absent expected globals, a report-only policy, and recovery. Node mocks and layout
  tests stay but cannot prove CSP or deployed serving.

### Where I differ, or add a note

- **No hard 2 KB cap on `phoenix_kit.js`.** Codex is right that an arbitrary limit could push the
  notice into another failure-prone lazy request just to report a failure. I keep the intent
  (Dmitri: the file is already oversized): the shared loader replaces about 4 KB of duplicated
  loader code, the net change is reported uncompressed and gzipped, and the target is roughly
  neutral, with a small understandable helper preferred over micro-golf.
- **Fresco ordering ships in Part A**, not B: it is a bug today whatever happens to CSP.
- **Open question 3** (server-side record of a failed library): agreed, none in v1. Browser asset
  failures are operational diagnostics, and a reporting endpoint brings authentication, de-duplication
  and abuse concerns that this change should not take on.
- **Open question 5**: keep `vendor/lib/` as the default and add the URL override above before
  considering configurable filesystem layouts.

### Adjusted phases

Superseded: see **Phases** in the body (updated after the second review).

## Codex second review — 2026-10-07

**Verdict:** the revised decisions resolve most of the first review and give a sensible implementation
approach. Three remaining decisions need to be explicit; the first affects the privacy guarantee.

1. **Etcher must stay local-only when the local Sortable preload fails, too.** Verified against
   `deps/etcher/priv/static/etcher.js`, `_withSortable`: when `window.Sortable` is absent it creates
   a CDN script, unless its instance has already marked Sortable as failed. Therefore preloading
   Sortable solves the successful path, but a local 404/offline failure followed by opening Customise
   still triggers a third-party request if Etcher is mounted normally. Specify the failure behaviour:
   either require an upstream loader option that disables external fallback and uses native drag
   handling, or conservatively prevent Etcher from mounting when its local Sortable prerequisite
   fails and show the diagnostic. The upstream option is preferable because annotations should not
   become unavailable just because an optional reorder enhancement failed. Avoid depending on
   Etcher's private `_sortableFailed` field as a public integration API. Acceptance must include a
   **missing/broken local Sortable file with third-party access otherwise allowed**, and assert that
   no external request is attempted. Enforced CSP alone can conceal an attempted external load;
   check attempted URLs as well as successful network requests.

2. **Move Sortable vendoring into B1 if B1 supplies it locally to Etcher.** The adjusted phases
   currently put local Sortable delivery in B1 but commit all three npm libraries in B2. Make B1
   include Sortable's exact-version asset, manifest entry and notices; B2 then adds Panzoom and
   wavesurfer. Alternatively put the Etcher/local-Sortable integration wholly in B2 and describe
   the remaining external path in B1. Either ordering works; the current dependency is circular.

3. **Define where version-correct URLs come from when install facts are absent.** The revised
   rule says every retained fallback URL uses the consumer's loaded application version, but the
   proposed place to emit that version is precisely the compiler-generated facts. A manually copied
   core bundle without those facts cannot discover an Elixir application version in the browser.
   Choose and document a concrete compatibility contract: require separately supplied version/URL
   metadata, disable fallback when the version is unknown, or explicitly retain the old core pins
   as a limited legacy exception with possible API mismatch. For manifest-present hosts that opt in
   to fallback, emit version-derived fallback URLs with the facts. Do not claim the same guarantee
   for both cases unless both have a source of consumer-version information.

### Small clarifications before implementation

- Consolidate the normative text once these choices are settled. The revised section wins, but the
  body still says version-only filenames are immutable, derives the base from a broad script selector,
  says doctor covers selective HTTP serving, uses an admin-area scope in the ExUnit test, and leaves
  the old automatic-fallback phases in place. Replace those passages and mark answered open questions
  as resolved so implementers do not have to reconcile three versions of the specification.
- Make CSP notice copy depend on the attempted URL. For a current local asset, “update so it is
  served from this site” is inaccurate; name the blocked origin/effective directive and recommend
  checking the host's asset-serving configuration and intended CSP. Reserve the update/rebuild
  guidance for legacy CDN delivery. Do not universally recommend editing `script-src` when an
  explicit `script-src-elem` was the enforcing directive.
- Define retry narrowly. Removing a failed script and retrying is workable for classic scripts;
  do not assume repeated `import()` of the same URL reruns a module that failed evaluation. The first
  version can keep that error terminal for the document and recommend a reload after repair.
- Preserving assets during compile is useful, but a clean release image still drops previous files.
  Document that rolling-deploy/open-tab retention also needs deployment/static-host retention; the
  compiler alone cannot guarantee it.

No application code changed in this second review. With the three decisions above settled, the plan
is ready to implement; the remaining items are specification cleanup and acceptance details.

## Closing the second review (author, 2026-10-07)

Codex's three remaining decisions, settled; the body above was edited to match, so there is one
specification, not three.

1. **Etcher stays local-only when local Sortable fails.** The durable answer is an **upstream Etcher
   option** that disables its external SortableJS load and uses native drag-and-drop (annotations must
   not become unavailable because an optional reorder enhancement failed); this is a prerequisite for
   declaring B1 accepted, and goes to Etcher's maintainer. Until it ships, the bridge in "Etcher's own
   SortableJS request" (setting the instance's `_sortableFailed` before `mounted`) is a **temporary,
   test-guarded workaround**, not an integration API: a test fails loudly if the installed Etcher no
   longer has that field, and Etcher's `~> 0.19.0` range is what bounds it. Not mounting Etcher when
   Sortable fails is rejected. Acceptance adds the case Codex names: a **missing or broken local
   Sortable file with third-party access otherwise allowed**, asserting that **no external URL is even
   attempted**, checked from the attempted-request log and not only from successful requests, since an
   enforced CSP alone can hide an attempt.
2. **Sortable moves into B1** (exact-version asset, manifest entry, notices); B2 is Panzoom and
   wavesurfer. The circular dependency is gone.
3. **Where version-correct URLs come from without facts: nowhere, by design.** Of Codex's options, the
   chosen one is *disable the fallback when the version is unknown*. A browser cannot learn an Elixir
   application's version, so the guarantee is not claimed for that case. For manifest-present hosts
   that opt in, the compiler emits version-derived `cdn` URLs with the facts. The old core pins are
   **not** retained as a legacy exception (their API-mismatch risk is the reason for this plan). To make
   the no-facts case rare, `install` and `update` now vendor bundle, libraries and facts together, so
   the bundle and the facts arrive in one step (see "How a host gets the bundle and the facts").

Clarifications applied in the body: content-hashed names (not version-only); the base captured at
evaluation time with an explicit override and no broad selector; doctor proves files on disk, not
serving; the ExUnit audience test uses Owner/Admin/superadmin and a restricted-holder negative;
notice copy depends on the attempted URL and the effective directive; retry is narrow and an ESM
failure is terminal for the document; the old automatic-fallback phases are replaced; answered open
questions are marked resolved. **Retention across deploys:** keeping previous assets for rolling
deployments and open tabs needs deployment or static-host retention as well; a clean release image
drops older files, and the compiler alone cannot guarantee it. This is documented, not promised.
