# Request for Etcher: let the host supply SortableJS, or turn off the CDN load

Draft of an issue for https://github.com/alexdont/etcher, written 2026-10-07. It is the upstream
prerequisite named in `2026-10-07-self-hosted-viewer-libraries.md` ("Closing the second review",
item 1). Not yet sent.

---

**Title:** Let the host supply SortableJS (or turn off the CDN load) so Etcher makes no third-party request

## Context

Etcher 0.19.0's Customise dialog loads SortableJS itself from jsDelivr: `SORTABLE_CDN`
(`priv/static/etcher.js`, line 1949) and `_withSortable` (lines 5216–5232). These locations were
verified against the [published Hex 0.19.0 package](https://repo.hex.pm/tarballs/etcher-0.19.0.tar);
its bundle matches PhoenixKit’s installed copy byte-for-byte. If
`window.Sortable` is already present it uses that. Otherwise it injects a `<script>` for the CDN URL,
and if that fails it sets `this._sortableFailed` and falls back to native drag-and-drop. That fallback
is a good design, and it is what we would like to build on.

The problem is hosts that cannot or will not allow that request:

- **Strict CSP.** The page uses `script-src 'self'`, so the load is blocked.
- **Offline or private installs.** There is no route to a third-party CDN.
- **No third-party requests.** The host wants zero, for privacy or compliance.

PhoenixKit (which loads Etcher) is moving to serve its viewer libraries, including SortableJS, from
the host's own origin. Etcher’s Sortable loader is the remaining hardcoded third-party library
load identified in the four installed viewer/editor bundles (see audit scope below). Preloading
`window.Sortable` avoids it when the preload succeeds, but does not suppress the CDN request when
the local file fails. Preserving native reordering in that failure case currently requires touching
private implementation details, which we would rather not depend on.

## Proposal

Add two settings on the existing `window.Etcher` extension surface, read at the time
`_withSortable` runs:

```js
window.Etcher = window.Etcher || {}; // also safe before etcher.js loads
window.Etcher.sortableUrl = "/assets/vendor/lib/sortable-1.15.0-ab12cd.js"; // optional
window.Etcher.loadSortableFromCdn = false;                                  // default: true
```

Behaviour of `_withSortable`:

1. If `window.Sortable` exists, use it (unchanged).
2. Otherwise, if `window.Etcher.sortableUrl` is a non-empty string after trimming, load that URL
   instead of the CDN one. If it fails, use native drag-and-drop and call back with `null`.
   **Do not try the CDN after a custom URL fails**, even when `loadSortableFromCdn` is true.
3. Otherwise, if `window.Etcher.loadSortableFromCdn === false`, **make no request**, go straight to
   the existing native drag-and-drop path (the `_sortableFailed` behaviour), and call back with
   `null`.
4. Otherwise, load `SORTABLE_CDN` as today.

Defaults keep the current behaviour, so existing hosts see no change. `undefined`, `null`, an
empty/whitespace-only URL, or a non-string URL means “no custom URL”; the CDN switch then decides
whether a request is allowed. The flag disables the **built-in CDN choice**, not a host-supplied URL
(which may itself be cross-origin). A host wanting no network load at all leaves the URL unset and
sets the flag to false.

Read settings before the first load attempt, preserving values supplied before Etcher loads. Hosts
set them before mounting layers/opening Customise; changing them does not cancel an in-flight load.
Keep the existing precedence where a subsequently supplied `window.Sortable` wins even after an
instance previously failed. For this small change, failure may remain terminal for that instance;
changing a URL need not reset it automatically.

On success, validate that the global provides the constructor API Etcher uses (`new Sortable(...)`)
before invoking the enhanced path. A script that loads but exports no usable Sortable global takes
the native path. Settle all queued callbacks on success or failure and avoid mounting a Sortable
instance into a dialog/layer destroyed while loading. Sharing loads between layers is a useful
follow-up, but is not a prerequisite for this API.

## Why this shape

- It matches the conventions already in the file (`window.Etcher.colorSwatches`, `tooltipSlots`,
  `defaultColor`).
- Both settings are optional, so nothing changes for anyone who ignores them.
- It reuses the existing no-Sortable path, so annotations and the Customise dialog keep working.
  Only list reordering uses native drag-and-drop instead.

## Tests / acceptance

- With `loadSortableFromCdn = false` and no `window.Sortable`, opening Customise creates no
  `<script>` and makes no network request, and reordering still works natively.
- With `sortableUrl` set, only that URL is requested, for either value of the CDN flag.
- A custom URL returning 404, blocked by CSP, or loading without a usable global calls back with
  `null`, keeps annotations/native reordering usable, and never requests the CDN. Check attempted
  script URLs with CDN access otherwise allowed, so CSP cannot conceal an unwanted attempt.
- Empty/whitespace/non-string custom URLs follow the flag, without requesting the current page.
- Settings supplied before bundle evaluation survive; settings supplied after evaluation but before
  the first Customise open are honoured.
- Queued callbacks settle once on failure; repeated opens do not remain stuck waiting, and supplying
  a valid global after failure still enables enhanced reordering.
- Closing/destroying the dialog or layer during loading does not initialise detached UI.
- With `window.Sortable` present, nothing is requested, as today.
- Default settings still request `SORTABLE_CDN`.

## What PhoenixKit will do with it

Set `sortableUrl` from its install facts (a same-origin file), and set `loadSortableFromCdn = false`
in its local-only mode. Because the custom URL is authoritative, this upstream setting does not
implement local-then-CDN fallback. If a host explicitly opts into that sequence, PhoenixKit’s shared
loader owns it and supplies the resulting global; Etcher’s built-in CDN path stays disabled.

The PhoenixKit plan proposes a temporary, test-guarded private-field workaround until this API
ships; that workaround has not been implemented as part of this request. The upstream API removes
that dependency and lets an optional Sortable failure preserve annotations and native reordering.

## Audit scope and API review

A static search of PhoenixKit’s installed Fresco, Tessera, Etcher and Leaf bundles covered script
insertion, dynamic imports, workers, fetch/XHR and asset URL assignments. It found Etcher’s Sortable
script injection, but no additional runtime library loader in those four files. This is a scoped
static review, not proof that the full application makes no external request.

There **are** runtime content loads: Fresco loads supplied image URLs; Tessera fetches its supplied
DZI manifest and tiles; Etcher loads supplied image/preview URLs; Leaf renders inserted images.
Their origins depend on host/user content. SVG namespace strings and URL-input placeholders are
not network loads. The self-hosting promise concerns library code and its dependencies, not every
content URL. Full integration acceptance still needs browser coverage of the exercised features.

The flat settings fit the existing `window.Etcher.colorSwatches`/`defaultColor` convention, so a new
options object is unnecessary for these two controls. The maintainer can choose a nested shape if
preferred; the precedence and no-fallback-on-custom-failure contract above are the important parts.
This request does not require changes to Fresco, Tessera or Leaf to serve their current JS locally.

## Related, optional (can be separate issues)

- **Waiting for Fresco.** Tessera and Etcher log an error and return if `window.Fresco` is not ready
  when they mount, so they depend on load order. Queuing until `window.Fresco` (or `Fresco.onReady`)
  exists would remove that race, but would require bounded waiting and cancellation on destruction.
  `Fresco.onReady` handles viewer-instance readiness once the Fresco global exists; it does not load
  the Fresco script. PhoenixKit will chain the mounts itself either way, so this is not a prerequisite.
- **Exposing a version.** A `window.Etcher.version` (and the same for Fresco and Tessera) would let a
  host confirm the loaded file matches the Elixir package it expects.
