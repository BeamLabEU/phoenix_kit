# Running PhoenixKit under a strict Content-Security-Policy: report for review

Date: 2026-11-25. Branch: `main`. Author: Claude (with the maintainer).

This report describes three commits and asks for a review of them. It says what was changed, why,
what was verified, and where the work is most likely to be wrong.

| Commit | Step | Size | State |
|---|---|---|---|
| `48912e11e` | 1. The integration plug no longer writes a script into host pages | 3 files, +32 −87 | pushed |
| `b354e77bf` | 2. Nonce support for the kit's inline `<script>` and `<style>` | 27 files, +544 −34 | pushed |
| `55039edd7` | 3. No inline event handlers in core's markup | 24 files, +662 −283 | local, not pushed |

Nothing is released to Hex. All three sit under `## Unreleased` in `CHANGELOG.md`.

## Why

A fresh host project installed PhoenixKit with a policy of `script-src 'self'`. An agent reviewing
that project reported that PhoenixKit's inline scripts were blocked in the browser and that the
host's own test for its policy failed. It gave the host three options: allow `'unsafe-inline'`,
loosen the policy only for PhoenixKit's routes, or wait for nonce support in PhoenixKit.

We checked the report against core and it was right on the facts:

- `PhoenixKitWeb.Plugs.Integration` put an inline `<script>` after `<head>` on **every** HTML
  response of the host's `:browser` pipeline, the host's own pages included. So the second option
  (loosen only the kit's routes) could not work.
- Nothing in `lib/` read a CSP nonce.
- Core's layouts and components rendered inline `<script>` and `<style>` tags in about 25 places.

Two things in the report were incomplete:

- It said the scripts change per request. They do not; they vary by site settings, theme and
  language. Hashes are still impractical, so the conclusion held.
- It did not mention inline event handlers (`onclick="…"`). A nonce cannot be put on an attribute,
  so nonce support alone would not have made a strict policy possible.

The goal of the three steps: a host can keep a strict `script-src` on its own pages today, and on
the kit's pages by handing the kit its nonce.

## Step 1: the plug leaves the response body alone (`48912e11e`)

**Before.** `Integration.call/2` registered a `before_send` callback that rewrote the body of every
HTML response to insert a script. The script cleared Phoenix's cached LongPoll fallback from
browser storage.

**After.** The callback, the script and the body rewriting are deleted. The plug now only restores
the remember-me session and runs the website-access gate.

**Why nothing is lost.** `priv/static/assets/phoenix_kit.js` already has the same clearing
(`clearPhoenixTransportCache`), and the installer puts that file in the host's root layout before
`app.js`. The bundle's copy is also the correct one: the plug's filter skipped every key starting
with `phx:`, and the key Phoenix actually writes is `phx:fallback:<transport>`. The plug's script
never cleared the flag it existed for. `test/js/transport_cache.test.cjs` already pins the
bundle's behaviour.

**Test.** `test/integration/phoenix_kit_web/plugs/integration_remember_me_test.exs` gained a case:
an HTML body sent through the plug comes out byte-identical.

**Left alone on purpose.** `PhoenixKitGlobals` still carries a third, stale copy of the clearing
line inside its inline script. That script has to stay inline for `window.PHOENIX_KIT_PREFIX`, so
the line was not touched. It is harmless and redundant.

## Step 2: nonces on inline `<script>` and `<style>` (`b354e77bf`)

### What a host does

```elixir
config :phoenix_kit, csp_nonce_assign_key: :csp_nonce
# or %{script: :script_nonce, style: :style_nonce}
```

The host's own plug generates the nonce, puts it in the policy header and in `conn.assigns`, and
runs **before** `PhoenixKitWeb.Plugs.Integration`. The option name and shape follow
`Phoenix.LiveDashboard`'s `csp_nonce_assign_key`. With the setting absent nothing is read and no
attribute is rendered.

### How the nonce reaches a tag

New module: `lib/phoenix_kit_web/csp.ex` (`PhoenixKitWeb.CSP`).

A function component cannot see the `conn`, and threading an assign through every component and
every host call site was not realistic. So the nonces of the current page are kept in the
**process dictionary**, the way Gettext keeps the locale.

1. `Integration.call/2` now starts with `CSP.put_nonces(conn)`. The request process also renders
   the dead render of a LiveView, so components rendered there find the nonce.
2. The three kit `live_session`s in `lib/phoenix_kit_web/integration.ex` gained
   `session: {PhoenixKitWeb.CSP, :live_session, []}` and `PhoenixKitWeb.CSP` as their first
   `on_mount`. The nonce travels in the LiveView session and is restored in the socket process.
   This matters for `<style>`: a style element that a later patch inserts is checked against the
   policy of the document, whose nonce does not change during live navigation.
3. A page written as a string with the `conn` at hand uses `CSP.attr(conn, kind)`.

Every inline tag in `lib/` now has `nonce={PhoenixKitWeb.CSP.nonce(:script | :style)}`. A few
`<script src=…>` tags in the kit's root layout got it too; that is harmless and is what a
`'strict-dynamic'` policy needs.

### Deliberate exemptions

The HTML sitemap (`lib/modules/sitemap/html_generator.ex`) and the public API guide
(`lib/phoenix_kit/api/public_discovery/guide_html.ex`) carry no nonce. Both are cached or served
identically to everyone, and a per-request nonce must never be written into a cached body. Their
inline style is a constant.

### Tests

- `test/phoenix_kit_web/csp_test.exs`: the config shapes, escaping, the session round trip into
  another process, and that a second request in the same process does not inherit the first one's
  nonce.
- `test/integration/phoenix_kit_web/csp_nonce_pages_test.exs`: the sign-in page through the real
  router. Every inline tag has the nonce on the first render and on the connected render, and
  there is no `nonce=` at all without the setting.
- `test/phoenix_kit_web/csp_inline_tags_test.exs`: fails on an inline `<script>` or `<style>` in
  `lib/` without the nonce call.
- `test/phoenix_kit_web/route_precedence_test.exs`: its expected `on_mount` list gained
  `{PhoenixKitWeb.CSP, :default}`.

## Step 3: no inline event handlers (`55039edd7`)

About 45 handler attributes in 14 files, plus eight `onclick` attributes in the HTML the
cookie-consent widget builds inside `phoenix_kit.js`.

**After.** The markup names what it wants with a data attribute. One block of document-level
listeners in `phoenix_kit.js` ("DECLARATIVE HANDLERS", right after the password-toggle block) does
the work.

| Was | Now | Where |
|---|---|---|
| `onclick="document.activeElement.blur()"` | `data-pk-blur` | users list, activity filters, media browser header (15 places) |
| `onclick="navigator.clipboard.writeText(…)"` | `data-pk-copy="text"` / `data-pk-copy-from="id"` | OAuth callback URL (two places), integrations JSON |
| `onerror="…"` on `<img>` | `data-pk-img-error="hide \| remove \| placeholder"` | avatars, media grid |
| `onsubmit="return false"` | `data-pk-no-submit` | `date_nav` picker form |
| `onkeydown` swallowing Enter | `data-pk-no-enter` | GIF search in the annotation composer |
| `onfocus` / `onblur` / `onkeydown` | `data-pk-zero-clear` | `<.decimal_input>` |
| `oninput="…"` (20 lines, twice) | `data-pk-language-filter` | language switcher |
| `onclick` / `onscroll` | `data-pc-step`, `data-pc-jump`, existing `data-pc-track` | `<.preview_card>` |
| `onclick="window.PhoenixKitConsent.x()"` | `data-pk-consent="x"` (allow-listed) | consent widget |

**Design choices.**

- **In the public bundle, not the admin one.** These components render on any page.
- **Delegated listeners, not hooks.** Controller-rendered pages and dead views render the same
  markup, and a hook needs a LiveView.
- **Capture phase** for events that do not bubble (`error`, `focus`, `blur`, `scroll`, `submit`)
  and for `keydown`.

**`<.decimal_input>` is the one with a behaviour change.** It used to concatenate its own handler
and the host's into one attribute (`ours;host`). Now the kit's part is a capture-phase listener on
the document, and a handler the host passes is rendered exactly as the host wrote it. The order
(kit first, host second) is kept because capture on the document runs before the target's own
handler. The zero logic was ported line for line; its "browser-like run" tests moved from
`decimal_input_test.exs` (where node evaluated the attribute strings) to
`test/js/declared_handlers.test.cjs` (where node calls the exported functions) with the same case
tables.

**Other test changes.** `preview_card_test.exs` asserts the data attributes instead of the JS
text. The admin-layout snapshot fixture was regenerated; the only markup change in it is the
avatar's `onerror` becoming `data-pk-img-error="hide"`. The lint test gained two cases: no handler
attribute in `lib/`, none in the two bundles. The public bundle grew by about 9.4 KB, so its size
budget in `test/js/admin_split.test.cjs` went from 328 to 336 KiB, with a note in the style of the
earlier increases.

## Documentation added

- `guides/content-security-policy.md` (host-facing, linked from `guides/README.md`, in the hexdocs
  extras).
- A "Content-Security-Policy" section in `AGENTS.md` with the three rules for future work.
- `CHANGELOG.md` entries under Added, Changed and Fixed.

## What was verified, and what was not

- `mix precommit` passes on the final tree (compile with warnings as errors, format, credo
  strict, dialyzer, JS tests).
- Full `mix test` against the real database: 17 055 tests, 20 failures. All 20 are in
  `PhoenixKit.API.OAuth.ClientsResolveTest` (9), `PhoenixKitWeb.OAuth.RegisterTest` (6),
  `PhoenixKit.Integration.Users.RegistrationTest` (2), `ClientsTest`, `CimdFlowTest` and
  `ApprovalFlowTest` (1 each). The same files fail the same way with our changes stashed; the
  errors read so far show rows left behind in the shared test database (seven preregistered
  OAuth clients where a test expects one). We did not clean the database or prove this for each
  of the 20.
- **Not verified: a real browser under a strict policy.** Every claim about what the browser
  accepts rests on reading the CSP rules, not on a run. This is the largest gap.
- **Not verified: the host project that raised the issue** has not been rebuilt against this tree.

## Where to look hardest

These are the points we are least sure of, in rough order of risk.

1. **A cached page body with a nonce in it.** We exempted the two cached documents we found. We
   did not audit every place where core or a module stores rendered HTML (publishing page cache,
   email previews, anything that calls a kit component outside a request). A nonce stored in a
   cache is useless at best and, if a cache is shared between visitors, lets one visitor's nonce
   appear on another's page. Please search for other caches of rendered kit markup.
2. **The process dictionary.** `put_nonces/1` overwrites or deletes on every call because a
   connection process serves several requests. `on_mount/4` only writes when the session carries
   nonces, so a host live session without the session option keeps what the plug stored for the
   dead render. Is there a path where a page renders in a process that still holds an older
   page's nonce: a request that never passes `Integration`, a task spawned during a render?
3. **Plug order.** The kit reads the assign when `Integration` runs. A host whose nonce plug
   comes later gets no nonce on controller pages, silently. The kit's live sessions do not depend
   on the order (the session function reads the final `conn`). Should the doctor task warn?
4. **The nonce in the LiveView session.** It is signed, not encrypted, and sits in the page's
   `data-phx-session`. The nonce is on the same page in clear text anyway, so we judged this
   acceptable. Please confirm.
5. **Host live sessions.** A host's own `live_session` that renders `LayoutWrapper` or other kit
   components needs the two options from the guide, or tags added by live navigation carry no
   nonce. Nothing detects their absence.
6. **Listener semantics versus the inline handlers.**
   - `focus` and `blur` are caught in the capture phase on `document`. LiveView's `phx-focus` and
     `phx-blur` use `focusin` / `focusout`, which fire after; the component's moduledoc promises
     that order.
   - A broken image that fails before the bundle runs fires no second `error` event. A sweep on
     `DOMContentLoaded` covers images already complete with zero width. A LiveView patch can
     still undo the `display: none`, as it could before.
   - `data-pk-copy` swallows a clipboard rejection silently and does nothing when
     `navigator.clipboard` is missing (an insecure context). The old inline code threw in the
     console instead. No user feedback either way, as before.
   - `data-pk-blur` uses `closest`, so it fires for a click anywhere inside the marked element,
     as the bubbling `onclick` did.
7. **Stale `phoenix_kit.js` on a host.** Markup without inline handlers plus an old bundle means
   dead copy buttons, dropdowns that stay open and no zero-clearing until the file is refreshed.
   The `:phoenix_kit_js_sources` compiler refreshes it on `mix compile`; a host that vendored the
   file by hand does not get that. The changelog says so. Is that enough, or does it need a
   version check in the bundle?
8. **The lint test is line-based.** It sees a tag only when it opens a line, and a handler only
   as `on…=` followed by a quote or brace. A tag or handler assembled from string pieces in
   Elixir would pass it. `@doc` heredocs are blanked so examples do not count.
9. **`on_mount` now assigns `:phoenix_kit_csp_nonces` on every kit LiveView socket**, an empty
   map when the feature is off. It is one more assign on every mount. Is it wanted at all?

## Known gaps, not attempted

- **Inline `style="…"` attributes.** Core uses them widely. A strict host still needs
  `style-src-attr 'unsafe-inline'`.
- **The cookie-consent widget** injects a `<style>` element from script and uses many style
  attributes. Its buttons were converted; its styles were not.
- **Module packages** (`phoenix_kit_*`). None was touched. `phoenix_kit_legal` ships its own
  `phoenix_kit_consent.js`, which may still build markup with `onclick`.
- **No doctor check** for the nonce setting, plug order or a stale bundle.

## How to check it yourself

```bash
git diff ce9ac30ed..55039edd7 --stat
mix precommit
mix test test/phoenix_kit_web/csp_test.exs \
         test/phoenix_kit_web/csp_inline_tags_test.exs \
         test/integration/phoenix_kit_web/csp_nonce_pages_test.exs \
         test/integration/phoenix_kit_web/plugs/integration_remember_me_test.exs \
         test/phoenix_kit_web/components/core/decimal_input_test.exs \
         test/phoenix_kit_web/components/core/preview_card_test.exs
node --test test/js/declared_handlers.test.cjs test/js/admin_split.test.cjs
```

The most useful single check would be a host app with the policy from the guide's Option 1,
opened in a browser with the console visible: the sign-in page, the admin dashboard, the users
list (filters and avatars), Settings → Authorization (the copy button), a form with
`<.decimal_input>`, and a live navigation between two admin pages.

Reviews go in `dev_docs/pull_requests/2026/` under each agent's own file name, as usual; there is
no PR number for this work, so name the folder after this report.

---

## Review findings (Gemini, 2026-11-25)

Reviewed commits `48912e11e`, `b354e77bf`, and `55039edd7` (`ce9ac30ed..55039edd7`) plus full-repo
scans of `lib/`, `priv/static/assets/`, `guides/`, and `test/`. No prior agent reviews existed yet
on `main` (`dev_docs/pull_requests/2026/` has no folder for this change yet).

Overall direction is sound: Step 1 cleanly removes response-body rewriting, Step 2's process
dictionary + LiveView session design fits Phoenix/LiveView well, and Step 3's delegated
`data-pk-*` listeners in `phoenix_kit.js` are clean (and also fix a latent JS string-escaping bug
in the old `onclick="navigator.clipboard.writeText('#{@url}')"` copy buttons). However, there is
one **critical rendering bug** already live in `b354e77bf`, a **high-impact gap in runtime
`<style>` creation** that breaks Option 1 in the browser, and several medium bugs and improvements.

### Bugs

#### 1. `BUG - CRITICAL`: `ThemeController.toggle_icon_css/1` renders literal `<style nonce={PhoenixKitWeb.CSP.nonce(:style)}>`
- **Where:** `lib/phoenix_kit_web/components/core/theme_controller.ex:135-146`
- **Problem:** `toggle_icon_css/1` builds a plain Elixir string heredoc (`"""`, not `~H"""`) and
  hands it to `Phoenix.HTML.raw/1` at line 110. Writing `<style nonce={PhoenixKitWeb.CSP.nonce(:style)}>`
  inside a plain string does **not** interpolate the expression — every page rendering
  `<.theme_controller>` in toggle mode (any light/dark pair) now outputs the literal invalid HTML
  `<style nonce={PhoenixKitWeb.CSP.nonce(:style)}>`, **even when CSP is off**. Under a strict
  `style-src 'self' 'nonce-…'` policy the browser blocks the `<style>` and both sun and moon icons
  appear at once.
- **Why tests missed it:** `test/phoenix_kit_web/csp_inline_tags_test.exs:24` only checks
  `line =~ "CSP.nonce("` without distinguishing HEEx from plain Elixir strings, and
  `theme_controller_test.exs` only asserts on the CSS rules inside the tag.
- **Fix:** Use `<style#{PhoenixKitWeb.CSP.attr(:style)}>` (like `auth_page_wrapper.ex:164`), or
  move `<style :if={...} nonce={PhoenixKitWeb.CSP.nonce(:style)}>` directly into
  `theme_toggle_pair/1`'s `~H` template. Add a test asserting the rendered `<style>` tag has the
  resolved nonce (and never literal `PhoenixKitWeb.CSP`).

#### 2. `BUG - HIGH`: 10 runtime `document.createElement("style")` sites (plus cookie consent) lack a nonce and break under Option 1 (`style-src 'self' 'nonce-…'`)
- **Where:**
  - `lib/phoenix_kit_web/components/core/table_default.ex:642` (`fit_restore` inline `<script>` has
    a script nonce, yet appends an un-nonced `<style data-pk-table-fit>`)
  - `priv/static/assets/phoenix_kit_admin.js:3901` (`TableFit` hook — breaks responsive table column
    hiding on admin tables)
  - `priv/static/assets/phoenix_kit_admin.js:84` (`SortableGrid` drag/wiggle/selection/flash CSS)
  - `priv/static/assets/phoenix_kit_admin.js:2433` (`AnnotationBurn` `.pk-burn-still` style —
    without it, transitions are not suspended before cloning the SVG, so hover/selection outlines
    can burn into the saved image)
  - `priv/static/assets/phoenix_kit_admin.js:5943` (`ViewerGallery` `#pk-gallery-css`)
  - `priv/static/assets/phoenix_kit.js:319` (Person card `<dialog>` `.pk-person-pop::backdrop`)
  - `priv/static/assets/phoenix_kit.js:1022` (`injectFrescoDaisyUIStyles` theme token bridge)
  - `priv/static/assets/phoenix_kit.js:6289` (`LiveChange` cue animation + `[data-change-marker]`
    visibility — without it, change markers stay hidden)
  - `priv/static/assets/phoenix_kit.js:8004` (`PkChartCrosshair` suppressing overlapping native SVG
    tooltips)
  - `priv/static/assets/phoenix_kit_sortable.js:43` (legacy standalone sortable hook)
  - `priv/static/assets/phoenix_kit.js:1336` + `:1517` (Cookie consent widget injects `<style>` via
    `innerHTML` — already noted in Known gaps)
  - *(Vendor note)* `priv/static/assets/vendor_libs/cally/cally.js:624` also creates a `<style>` in
    Shadow DOM.
- **Problem:** The report listed only cookie consent under "Known gaps", but all 10 sites above are
  blocked by the exact `style-src 'self' 'nonce-…'` header recommended in `guides/content-security-policy.md`
  Option 1.
- **Fix:** Add a `pkStyleNonce()` helper in `phoenix_kit.js` (and expose it on
  `PhoenixKitInternals` for `phoenix_kit_admin.js`) that reads the `.nonce` IDL property from a
  server-rendered `<style>` element:
  ```js
  function pkStyleNonce() {
    var el = document.querySelector("style[data-pk-mobile-inputs], style[data-phoenix-kit-themes], style[nonce]");
    return (el && el.nonce) || "";
  }
  ```
  Per the HTML spec, browsers clear the `nonce` content attribute to `""` on parse while preserving
  the real value on `el.nonce` (so `style[nonce]` still matches, CSS `[nonce^="…"]` exfiltration
  stays impossible, and split `%{script: …, style: …}` configs are respected — never fall back to
  `PK_SCRIPT_NONCE`). Set `if (n) style.nonce = n;` before `appendChild(style)` at every site,
  do the same in `table_default.ex:642`, and convert the consent widget's `<style>` from `innerHTML`
  to `createElement("style")`.

#### 3. `BUG - MEDIUM`: `unblockScripts` in `phoenix_kit.js` strips CSP nonces from consent-gated scripts
- **Where:** `priv/static/assets/phoenix_kit.js:1258-1271`
- **Problem:** When consent is granted, `unblockScripts(category)` clones blocked `<script>` tags
  by looping `Array.from(script.attributes)` and calling `newScript.setAttribute(attr.name, attr.value)`.
  Because browsers empty the `nonce` content attribute after parsing while keeping the real value on
  the `script.nonce` IDL property, this copies `nonce=""` and drops the nonce. Under a nonce-based
  `script-src`, unblocked inline (or `'strict-dynamic'`) scripts fail to run.
- **Fix:** Skip `attr.name === "nonce"` in the `setAttribute` loop and copy
  `if (script.nonce) newScript.nonce = script.nonce;`.

#### 4. `BUG - MEDIUM`: `CSP.nonce(conn, kind)` leaks stale process-dictionary nonces when `conn` has none
- **Where:** `lib/phoenix_kit_web/csp.ex:69-71`
- **Problem:**
  ```elixir
  def nonce(%Plug.Conn{} = conn, kind) when kind in [:script, :style] do
    Map.get(from_conn(conn), kind) || nonce(kind)
  end
  ```
  When a caller explicitly passes `conn`, `from_conn(conn)` is the authoritative source for that
  request. Falling back to `nonce(kind)` (process dictionary) means a request on a reused HTTP
  connection process that did not pass through `Integration` — or a host configuring only
  `%{script: :script_nonce}` — can inherit a stale nonce from an earlier request.
- **Fix:** Return `Map.get(from_conn(conn), kind)` directly. And in `CSP.put_nonces/1`, register a
  `Plug.Conn.register_before_send/2` callback that calls `Process.delete(@pdict_key)` once the
  response is ready to send, so a reused connection process never carries a nonce into a subsequent
  request on a non-`Integration` pipeline.

#### 5. `BUG - MEDIUM`: Child / sticky LiveViews mounted via `live_render/3` lose CSP nonces on connected mount
- **Where:**
  - `lib/phoenix_kit_web/live/dashboard.html.heex:27` (`@home_view` with `session: @home_session`)
  - `lib/phoenix_kit_web/components/layout_wrapper.ex:1276` (`widget.live_view` header widgets)
  - `lib/phoenix_kit_web/components/layout_wrapper.ex:1283` (`NotificationsBell`)
- **Problem:** Child/sticky LiveViews run in separate processes and skip the parent `live_session`'s
  `on_mount` hooks. If `@home_view` (e.g. a dashboard module or host home view) or a header widget
  renders any kit component with `<style>` or `<script>` (`<.table_default>`, `<.theme_controller>`,
  `<.media_browser>`), its connected render has no nonce in its process dictionary.
- **Fix:** Add a helper (e.g. `CSP.session_from_current/0` or `CSP.merge_session/1`) and merge it
  into `@home_session`, `widget.session`, and `NotificationsBell`'s session, and restore nonces via
  `on_mount PhoenixKitWeb.CSP` (or in child mount).

### Improvements

#### 6. `IMPROVEMENT - HIGH`: Harden `test/phoenix_kit_web/csp_inline_tags_test.exs` and add component render tests
- **Blind spots in the current lint test:**
  1. Did not distinguish HEEx (`~H` / `.heex`) from plain Elixir strings, letting Bug #1 pass.
     Reject `nonce={...}` inside non-HEEx strings (plain strings must use `#{...CSP.attr(...)}`).
  2. `@opening ~r/^\s*"?<(script|style)\b([^>]*)>/` only matches single-line tags starting a line —
     it misses multi-line `<script\n  ...>` / `<style\n  ...>` tags and mid-line tags like
     `<div><style>...</style></div>` or `~s(<style>...)`. Scan the full stripped source with
     multiline/dotall regexes.
  3. `@handler ~r/\son[a-z]+=["{]/` misses single-quoted handlers (`onclick='...'`) and whitespace
     around `=` (`onclick = "..."`), and does not check `javascript:` URIs.
  4. Bundle check skips `priv/static/assets/phoenix_kit_sortable.js` and `phoenix_kit_upload_manager.js`,
     and does not check for un-nonced `document.createElement("style")` or `'<style>'` in JS.
  5. `csp_nonce_pages_test.exs` only exercises `/users/log-in`. Add unit render assertions under a
     configured nonce for `ThemeController` (toggle mode), `AuthPageWrapper` (with custom bg),
     `TableDefault` (`fit: true`), `LayoutWrapper`, `MaintenanceMode`, `WebsiteAccessController`,
     `PushController`, `PushOpenController`, and `OAuth.Pages`.

#### 7. `IMPROVEMENT - HIGH`: Eliminate plug-order fragility on kit routes + validate config in `doctor`
- Calling `CSP.put_nonces(conn)` at the start of `:phoenix_kit_auto_setup`
  (`lib/phoenix_kit_web/integration.ex:198`) in addition to `Plugs.Integration` means any host CSP
  plug placed anywhere in `:browser` (even *after* `Plugs.Integration`) works for all kit LiveViews
  and kit controllers; only early halts inside `Integration` (`WebsiteAccess`/`MaintenanceMode`)
  would still need the host's CSP plug ahead of `Integration`.
- Pass `conn` and use `CSP.nonce(conn, :style)` in `PushController`, `PushOpenController`,
  `WebsiteAccessController`, and `OAuth.Pages` (instead of relying on the 0-arity process-dictionary
  call when `conn` is already right there).
- Validate `:csp_nonce_assign_key` (currently invalid values like `"csp_nonce"` or
  `%{scripts: :a}` silently return `[]` in `csp.ex:144-151`) — warn in `mix phoenix_kit.doctor`
  (and check plug ordering in the router when the option is set).

#### 8. `IMPROVEMENT - MEDIUM`: Fix gaps in `guides/content-security-policy.md` and `OAuth.Responses`
- **Option 1 snippet (`guides/content-security-policy.md:34`):** Add `style-src-attr 'unsafe-inline'`
  directly into the copy-paste example (with a short comment) so hosts copying Option 1 don't break
  inline `style="..."` attributes immediately.
- **External `<script src=…>` tags & `'strict-dynamic'`:** `phoenix_kit.js:576` captures
  `PK_SCRIPT_NONCE = document.currentScript.nonce` to propagate nonces when lazy-loading
  `phoenix_kit_admin.js` and vendored viewer libraries, and `'strict-dynamic'` requires a nonce on
  every parser-inserted `<script src=…>`. Document adding `nonce={@csp_nonce}` to the host's
  `root.html.heex` tags (`phoenix_kit.js`, `phoenix_kit_modules.js`, `app.js`).
- **Merging `live_session` `session:`:** Phoenix only accepts one `session:` option per
  `live_session`. Show the 3-line merge pattern (`Map.merge(my_session(conn), PhoenixKitWeb.CSP.live_session(conn))`)
  for hosts that already have a `session:` callback.
- **Other directives hosts hit in practice:** Mention Cloudflare Turnstile
  (`script-src` + `frame-src https://challenges.cloudflare.com`), media viewer/upload previews
  (`blob:` / `data:` in `img-src`/`media-src` and S3 origins if direct URLs are used), LiveView
  WebSocket (`connect-src 'self'`), and OAuth consent redirects (`form-action`, cross-referencing
  `PhoenixKitWeb.OAuth.Responses`). Also update the now-stale note in
  `lib/phoenix_kit_web/oauth/responses.ex:16-18` which still says strict `style-src` cuts the
  consent page's `<style>`.

#### 9. `IMPROVEMENT - MEDIUM` / `NITPICK`: Small edge cases in `priv/static/assets/phoenix_kit.js` (Step 3)
- **`copyTextFor` (`phoenix_kit.js:191`):** `source.value !== undefined && source.value !== null`
  is true for `<pre>` today (falls through to `textContent`), but elements like `<li>`, `<button>`,
  `<option>`, `<meter>`, `<progress>`, and `<data>` have a `.value` property (e.g. `li.value === 0`).
  Check `source.tagName === "INPUT" || source.tagName === "TEXTAREA" || source.tagName === "SELECT"`
  before reading `.value`.
- **`data-pk-blur` (`phoenix_kit.js:300`):** Guard `typeof document.activeElement.blur === "function"`
  before calling `.blur()`.
- **`sweepBrokenImages` (`phoenix_kit.js:307-311`):** Note that a valid SVG image without intrinsic
  `width`/`height` attributes can report `naturalWidth === 0` in some browsers; if SVG avatars are
  ever rendered with `data-pk-img-error`, this sweep could falsely hide/remove them.
- **Test gap in `test/js/declared_handlers.test.cjs`:** Add unit tests for `data-pk-consent`
  (confirming allow-listed actions dispatch and unknown actions like `__proto__` / `constructor` /
  arbitrary methods are ignored) and for `sweepBrokenImages`.

### Direct answers to "Where to look hardest" (items 1–9)

1. **Other cached HTML bodies:** Audited all `Cache.put`, `safe_to_string`, `to_iodata`, and
   `Phoenix.HTML.raw` calls in `lib/`. Only `HtmlGenerator` (HTML sitemap) and `GuideHTML` (public
   API guide) are cached/shared in core; email previews render inside `<iframe sandbox="" srcdoc>`
   with no nonces. External module packages with page caches (e.g. publishing) should be warned
   never to render nonced kit components into shared caches.
2. **Process dictionary:** Two real issues found — `CSP.nonce(conn, kind)` falls back to stale
   pdict state (Bug #4; also clean up via `register_before_send`), and child `live_render/3` views
   lose nonces across processes (Bug #5).
3. **Plug order:** Mitigate structurally via `:phoenix_kit_auto_setup` + passing `conn` in
   standalone controllers + a `doctor` warning (Improvement #7).
4. **Nonce in `data-phx-session`:** Confirmed acceptable. The nonce is already present in clear text
   on the same page and response header, and Phoenix signs `data-phx-session` so it cannot be
   tampered with.
5. **Host live sessions:** Confirmed silent omission risk; guide needs the `session:` merge example
   (Improvement #8), and `doctor` could flag host `live_session`s when `:csp_nonce_assign_key` is
   set.
6. **Listener semantics:** Capture-phase `focus`/`blur`/`keydown` order vs host inline handlers and
   LiveView `focusin`/`focusout` holds up; minor edge cases noted in Improvement #9.
7. **Stale `phoenix_kit.js`:** `mix phoenix_kit.doctor` already checks vendored `phoenix_kit.js`
   presence/compiler wiring (`lib/mix/tasks/phoenix_kit.doctor.ex:2351`), and `phoenix_kit_admin.js`
   already enforces version parity at runtime. No extra runtime banner needed, just keep the
   changelog note prominent (and optionally check bundle version/hash in `doctor`).
8. **Lint test:** Too brittle as written and already let Bug #1 through (Improvement #6).
9. **`:phoenix_kit_csp_nonces` socket assign:** Currently unused across `lib/` and undocumented in
   `guides/content-security-policy.md`. Either drop it (keeping `PhoenixKitWeb.CSP.nonce/1` as the
   single API, like Gettext) or only assign it when non-empty and document it in the guide.

