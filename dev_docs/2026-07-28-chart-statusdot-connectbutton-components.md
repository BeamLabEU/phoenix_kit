# New core components: Chart, StatusDot, ConnectAccountButton (+ stat_card value_color)

**Origin:** extracted from NordSwitch (nordswitch.eu), whose hand-rolled versions
run in production-dev today and will be swapped for these on release.
**Status:** implemented, reviewed, tested. This doc is the after-action record —
the original handoff asked for testing, review and polish, and this is what that
pass found and changed.

## What shipped

### `PhoenixKitWeb.Components.Core.Chart`

Server-rendered SVG, zero JS, theme-aware via `currentColor`:

- `line_chart/1` — line/area over `{x, y}` points; `step` for interval data
  (right-open steps), optional `marker_x` "now" line, auto or explicit domains,
  `:empty` slot.
- `sparkline/1` — polyline over a list of numbers.
- `bar_chart/1` — vertical bars from a **zero baseline**, native `<title>`
  tooltips, optional per-datum `class`, aligned labels.

Core (and the dashboards module) had no chart primitives at all; every consumer
either hand-rolled SVG or pulled a JS library. These are LiveView-native:
assigns change → SVG re-renders.

### `PhoenixKitWeb.Components.Core.StatusDot`

`status_dot/1` — semantic coloured dot + optional label + optional `pulse`.
Boolean `up={bool}` convenience or explicit `variant`. Fills the gap between
nothing and the domain-specific badges in `Badge`.

### `PhoenixKitWeb.Components.Core.ConnectAccountButton`

`connect_account_button/1` — OAuth-popup account linking (distinct from
`OAuthProvider`, which is app sign-in). Driven by the generic `PopupLink` hook.

### `stat_card` extension

Optional `value_color` for values whose colour carries information (a price
coloured by cheapness). Backward compatible; default nil.

## What the review pass changed

The components were handed over deliberately untested. Testing plus **four**
external review rounds (grok / kimi / codex / zai / vibe / agy) found these.

Rounds 2, 3 and 4 each found defects **in the previous round's fixes** — worth
recording, because it is the reason the sweeps kept going. A fix aimed at a
narrow symptom repeatedly re-created the same class of bug on a path it did not
touch: flooring a bar's height without moving its `y` pushed it out of the
viewBox exactly as the zero-height bar had been invisible; widening a
zero-length path so a lone point would paint made it paint a full-width line
for out-of-domain data and threw away the second value of any same-x pair; and
a magnitude-relative y padding that rescued huge *flat* series swamped the
signal in huge *near-flat* ones.

The round-4 resolution was to stop patching symptoms and fix the cause: a
collapsed domain now scales to the **centre** (the same treatment a flat y
series already got), and a path that genuinely paints nothing renders a **dot**
at the point's true position rather than a fabricated line across a range
nobody measured.

**Crashes and silent failures**

- `bar_chart` scaled from `max(value)`, so a **negative value produced a negative
  rect height** — SVG discards those, so the bar silently vanished rather than
  rendering below a baseline. An all-negative series divided by the `1.0e-9`
  floor and threw the geometry to astronomical numbers. Bars are measured from a
  zero baseline now.
- A **single data point** produced a bare `M x,y` path, which is valid and paints
  nothing. It holds its value across the range instead — the same reading `step`
  mode already gave it. Same fix for a single sparkline value.
- **Reversed domains** (`x_domain={{10, 0}}`) drove the span negative; the
  `1.0e-9` floor then produced coordinates around `1.0e12` and the chart vanished
  off-canvas. Both axes normalise.
- **One bad point took the page down.** `nil`, a string, or a `Decimal` raised an
  uncaught `ArithmeticError` mid-render — and `Decimal` is what Ecto hands you
  for money, in a kit with a billing module. Points are normalised: tuples or
  `%{x:, y:}` maps, Decimals converted, non-numeric dropped, `:empty` when
  nothing usable survives.

**Security / correctness**

- `connect_account_button` used an **inline `onclick`** — CSP-hostile in a kit
  that removed inline handlers everywhere else — whose `return false` cancelled
  navigation *unconditionally*, including when the popup was blocked. That is
  precisely when the documented "falls back to normal navigation" was supposed to
  save it; the button simply did nothing. It is a hook now that preventDefaults
  only after `window.open` returns a live window, and leaves modifier-clicks
  alone.
- Every unconfigured button shared **one DOM id** (`window_name` defaulted to a
  constant), which is invalid HTML and breaks `phx-hook`. The default derives
  from `href` now.
- The moduledoc's security rationale was **wrong**: it claimed the local-path
  check kept `window.opener` from third parties. The popup navigates on to the
  provider and the opener reference survives, so the provider's origin can reach
  `opener.location` — reverse tabnabbing. The doc now names the real mitigation
  (COOP + `postMessage`). The local-path check is kept, for what it does do.
- `stat_card`'s `value_color` interpolated into `style=`; a `;` could append a
  second declaration. Stripped, and the attribute is spread conditionally
  (HEEx renders `style={nil}` as an empty `style=""`).

**Accessibility**

- Charts carried `role="img"` with **no accessible name**. Optional `aria_label`
  renders as `<title>` + `aria-label`; unlabelled charts are marked decorative.
- `status_dot` conveyed state through **colour alone** — silent to a screen
  reader, indistinguishable to red/green colour-blind users. Unlabelled dots
  carry a visually-hidden state name kept in step with the colour. `pulse`
  respects `prefers-reduced-motion`.

**API, changed while it was still free (nothing consumes these yet)**

- `area_chart` → **`line_chart`** (`area_chart area={false}` *was* a line chart).
- a11y attr `label` → **`aria_label`**, so it stops colliding with bar data's own
  `label:` key.
- Hook `ConnectAccountPopup` → **`PopupLink`**; nothing about it is
  OAuth-specific, and hook names freeze once hosts copy the bundle.
- `:rest` global on all three charts and on `status_dot`.
- Bars: `<title>` tooltips, zero baseline, per-datum `class`, rendered `id`,
  labels sized to their own slot (`justify-between` drifted the first and last
  labels to the container edges while bars sit at slot centres).
- Gridlines got the `vector-effect` the line already had.
- Bar tooltip values are formatted for display, so a computed `0.1 + 0.2` reads
  as `0.3` rather than `0.30000000000000004`.

## Tests

- `test/phoenix_kit_web/components/core/{chart,status_dot,connect_account_button,stat_card}_test.exs`
- `test/js/popup_link.test.cjs` — the hook's pure decision logic (which clicks to
  intercept, where to place the popup, same-origin). Run via `mix test.js`, wired
  into `mix precommit`; skips itself when node isn't installed.

Verified live in `phoenix_kit_parent` at `/core-components-showcase` (local
only): positive bars end exactly at the baseline, negatives hang below it, and
heights stay proportional.

## Known limits, deliberately not addressed

- **Numeric domains only.** Callers map time → number. A datetime-axis helper, if
  ever wanted, should be a separate wrapper rather than a widening of this API.
- **Single series.** Overlay two absolutely-positioned charts sharing a viewBox;
  `currentColor` makes per-series theming trivial (`text-primary` /
  `text-secondary`).
- **`preserveAspectRatio="none"`** protects strokes via `vector-effect`, but dash
  patterns and the bars' `rx` corners still distort under heavy stretch.
- **No axis tick labels.** The highest-value future addition; gridline positions
  are already computed. Render them as HTML beside the SVG, not `<text>` inside
  it, which the stretch model would distort.
- **Large N:** pre-aggregate above roughly 1–2k points rather than expecting
  decimation.

## Follow-ups

- `status_dot`'s state vocabulary (`online` / `offline` / `ok` / …) is gettext'd
  but has no catalogue entries yet — it renders English until a translation pass
  runs `mix gettext.extract --merge`. Left out of this change deliberately:
  extraction rewrites all nine catalogues (~18k lines) and would bury the
  component diff.
- `connect_account_button`'s derived DOM id is lossy — `/foo/bar` and `/foo-bar`
  slug to the same id, so two such buttons on one page would collide again.
  Pass an explicit `id` in that case.

- `phoenix_kit_dashboards` widgets are the natural second consumer and would
  validate the API quickly.
- `phoenix_kit_publishing` hand-rolls a status dot
  (`version_switcher.ex`, `status_dot_classes/3`) — the exact duplication
  `StatusDot` exists to remove.
- NordSwitch adopts these on release.
- Unrelated but noticed: core ships the full **Chart.js UMD library** (it was
  inlined in `priv/static/assets/phoenix_kit.js`; since the public/admin split it
  is the vendored `vendor_libs/chartjs/` file, loaded on demand by the email
  dashboard and by `window.PhoenixKitLibraries.chartjs()`), which sets
  `window.Chart`. Worth a deliberate decision about whether the kit wants two
  charting stories now that zero-JS primitives exist.
