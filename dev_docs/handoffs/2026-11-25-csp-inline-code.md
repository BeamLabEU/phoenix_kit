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

## Review feedback — Mistral Vibe, 2026-11-25

Verified by running: `mix test` on `csp_test.exs` + `csp_inline_tags_test.exs` (11 tests) and on
`csp_nonce_pages_test.exs`, `integration_remember_me_test.exs`, `decimal_input_test.exs`,
`preview_card_test.exs` (52 tests) — all pass; `node --test` on `declared_handlers.test.cjs`,
`admin_split.test.cjs`, `transport_cache.test.cjs` (72 tests) — all pass. Also swept `lib/`
beyond what the lint regex sees (mid-line tags and handler attributes): no inline event handler
remains anywhere; the only nonce-free inline `<script>`/`<style>` are the two exempt documents
and doc-comment strings. All three kit live_session shapes carry the `session:`/`on_mount`
pair, and the push/access/OAuth pages sit under `:phoenix_kit_auto_setup`, so the process
dictionary is set for them. Step 1's claim holds: `clearPhoenixTransportCache` in the bundle
targets `phx:fallback:<transport>` by name — the key the deleted plug script never cleared.

### Findings

1. **The lint regex misses multi-line opening tags entirely.** `@opening` in
   `test/phoenix_kit_web/csp_inline_tags_test.exs` requires `>` on the same line as
   `<script`/`<style`; a tag opened on one line and closed on a later one is not matched at
   all. Four such tags exist today (`layouts/root.html.heex` twice, `layouts/dashboard.html.heex`,
   `layout_wrapper.ex:1611`), all nonced by hand — but a future multi-line tag *without* a nonce
   would pass the test. Accumulate lines until `>` before matching.
2. **The installer's generated host live_session lacks the CSP options.**
   `lib/mix/tasks/phoenix_kit.gen.user.dashboard.ex:317` and `:352` print
   `live_session :user_dashboard` with no `session: {PhoenixKitWeb.CSP, :live_session, []}` and
   no `PhoenixKitWeb.CSP` in `on_mount` — a generated dashboard that renders kit components
   loses nonces on live navigation (risk #5 above, already materialized in generated code).
   Add the two options to the printed snippet.
3. **Plug order fails silently on controller pages.** `Integration.call/2` snapshots the
   assigns into the process dictionary at its own run time; a host nonce plug placed after it
   leaves dead renders without a nonce (the LiveView path is immune — `session:` reads the
   final conn). A `mix phoenix_kit.doctor` check would catch the misconfiguration.
4. **Minor:** `oauth/pages.ex:397`, `controllers/push_controller.ex:118`,
   `controllers/push_open_controller.ex:190` and `controllers/website_access_controller.ex`
   use `CSP.nonce(:style)` (process dictionary only) where the `conn` is in scope;
   `CSP.nonce(conn, :style)` / `CSP.attr(conn, …)` — as the maintenance plug does — would be
   robust against plug order.

### Answers to the open questions above

- **#1 Cached bodies:** in core the only cached, same-for-all HTML with inline tags are the two
  exempt documents. `Modules.Shared.RenderCache` tracks image lookups, not rendered HTML, and
  no email template carries an inline tag. The real exposure is module packages (the consent
  widget's injected `<style>`), already a known gap.
- **#2 Process dictionary:** safe. `put_nonces/1` writes or deletes on every call (tested for
  same-process reuse), and `on_mount/4` preserving the dead render's value when the session
  carries none is correct.
- **#4 Nonce in the LiveView session:** signed-not-encrypted is acceptable; the nonce is in the
  page's clear HTML anyway.
- **#9 `:phoenix_kit_csp_nonces` assigned on every mount:** only needed by host templates that
  read it by name; could be skipped when empty, harmless as is.

### Caveats

The full `mix test` was not re-run for this review (the 20 OAuth failures above are pre-existing
per the stash check, taken on trust). No real browser under a strict policy — still the largest
gap, as noted above.

### Recheck after Claude's fix passes (`dbddc819b`, `69531ff24`) — Mistral Vibe, 2026-11-25

All four findings above are addressed; I re-read the diffs and ran the suites.

1. **Lint multi-line blind spot — fixed.** `csp_inline_tags_test.exs` now scans the whole file
   with a multi-line regex (`@tag_opening ~r/<(script|style)\b[^>]*>/s`), skips four files that
   handle tags as data (`@tags_as_data`), covers single-quoted/spaced handlers, `javascript:`
   URLs, all four bundles, and bundle-created `<style>` elements (`adoptStyle` within four
   lines, never built as a string). There is a test asserting the scan *sees* a tag that closes
   on a later line, so the offenders check now covers it.
2. **Generated `live_session` — fixed.** `phoenix_kit.gen.user.dashboard.ex` prints both
   `session: {PhoenixKitWeb.CSP, :live_session, []}` and `PhoenixKitWeb.CSP` in `on_mount`
   (both snippets). Still no test asserting the printed text (Grok's open item stands).
3. **Plug order — fixed three ways.** Kit routes re-read the nonce after the whole `:browser`
   pipeline (`Integration` on `:phoenix_kit_auto_setup` calls `CSP.put_nonces/1` again); a
   runtime warning fires once per node when a nonce appears only after the first reading
   (`put_nonces_first/1` marks the process); `mix phoenix_kit.doctor` gained a
   "Content-Security-Policy" check (`csp_verdict/3`, covered by `doctor_csp_test.exs`) that
   flags a malformed `csp_nonce_assign_key` and plugs after `Integration` in
   `pipeline :browser`. Known limits, which Claude's own "look hardest" list also states: the
   doctor parses the router with a regex (macro-built pipelines are invisible → false warning),
   and the runtime warning fires only when the first reading found *nothing*.
4. **Controller pages — fixed differently, fine.** Instead of `CSP.nonce(conn, …)` per tag,
   `push_controller.ex`, `push_open_controller.ex`, `website_access_controller.ex`, the OAuth
   authorize error page and the consent controller (a plug, since its pages are built in four
   places) call `CSP.put_nonces(conn)` right before rendering, so the 1-arity `nonce/1` in the
   template reads this connection. Equivalent, and one call covers the whole page.

Also verified in the fix commits: `nested_session/1` at the three nested-view sites
(`layout_wrapper.ex` header widgets, `live/dashboard.ex` `:home_session`) plus
`on_mount PhoenixKitWeb.CSP` in `use PhoenixKitWeb, :live_view` and in `NotificationsBell`;
the `before_send` that empties the dictionary when the response is sent; the `__pkBundleLoads`
guard on every later top-level section of `phoenix_kit.js`; `Layouts.kit_bundle_paths/1` in the
fallback root; the unused `:phoenix_kit_csp_nonces` assign is gone (my open question #9 —
resolved by removal).

Tests run this time, all green: `csp_test.exs`, `csp_inline_tags_test.exs`, `doctor_csp_test.exs`,
`csp_nonce_pages_test.exs` (33), `root_layout_bundle_test.exs`, `table_default_test.exs`,
`theme_controller_test.exs`, `integration_remember_me_test.exs`, `route_precedence_test.exs`
(75), and `node --test` on `declared_handlers`, `admin_split`, `table_fit`, `transport_cache`
(93). I did not run the browser harness (`dev_docs/handoffs/2026-11-25-csp-browser-harness/`) —
no Chromium here — so the 43-check run is taken on trust; a real-host run remains the top open
item, then the module packages and `cally`.

## Review feedback — Grok, 2026-11-25

Read the three commits, Mistral's notes above, and Codex's review at
`dev_docs/pull_requests/2026/2026-11-25-csp-inline-code/CODEX_REVIEW.md`. A shorter copy of this
section is `GROK_REVIEW.md` in that same folder. This section is the one to extend.

The fixes are in the working tree on `main` and are **not committed**. Nothing is released.
`HEAD` is still `49b9c3488` (the handoff commit). Later agents should review the diff, not only
this prose.

### Files touched, uncommitted

- `lib/phoenix_kit_web/csp.ex` — `nonce/2` reads only the given connection
- `test/phoenix_kit_web/csp_test.exs` — two regression tests for that
- `priv/static/assets/phoenix_kit.js` — `pkAdoptStyle` / `pkStyleNonce`; fresco, person-card,
  consent stylesheet, change cue, crosshair; consent script keeps `.nonce`
- `priv/static/assets/phoenix_kit_admin.js` — sortable, burn, table-fit and gallery styles
  stamped; table-fit `localStorage` value is column numbers
- `priv/static/assets/phoenix_kit_sortable.js` — stamps when `PhoenixKitInternals.adoptStyle` exists
- `lib/phoenix_kit_web/components/core/table_default.ex` — first-paint script rebuilds CSS
- `test/phoenix_kit_web/components/core/table_default_test.exs` — asserts `saved.cols`,
  `style.nonce`, `n < 500`, and the absence of `saved.css`
- `test/js/table_fit.test.cjs` — runs the inline script and compares it to `fitHideCss`
- `test/js/admin_split.test.cjs` — style-nonce preference and script-nonce fallback; public
  bundle budget raised from 336 KiB to 340 KiB
- `test/phoenix_kit_web/csp_inline_tags_test.exs` — opening tags may close on a later line
- `lib/mix/tasks/phoenix_kit.gen.user.dashboard.ex` — both success notices print the CSP
  `live_session` options
- `guides/content-security-policy.md` — subsection "Styles and scripts the bundle creates"
- `CHANGELOG.md` — one bullet under `## Unreleased` / `### Fixed` (version not bumped)
- `AGENTS.md` — two CSP bullets
- this file

`phoenix_kit.js` is 343780 bytes. `phoenix_kit_admin.js` is 461834. The public budget assertion
is `publicBytes < 340 * 1024` (348160), about 4.3 KB of room. Do not edit `vendor_libs/`
(cally is checksummed).

### BUG - MEDIUM · An explicit connection inherited another request's nonce — fixed

Codex's finding. `CSP.nonce/2` (`lib/phoenix_kit_web/csp.ex`, now line 74) used to do
`Map.get(from_conn(conn), kind) || nonce(kind)`. A missing assign fell through to the process
dictionary. Cowboy and `ConnTest` reuse the process, so request B could render request A's
nonce. `attr/2` did the same, because it calls `nonce/2` when a connection is passed.

`nonce/2` now returns only `Map.get(from_conn(conn), kind)`. A missing assign is `nil`.
`nonce/1` is unchanged and is still what components use, because they have no connection.
`put_nonces/1` still deletes the dictionary when the reading is empty, so the same-process
test Mistral relied on still holds.

Tests in `test/phoenix_kit_web/csp_test.exs`: "a connection is authoritative, even when an
earlier request left a nonce" and "a connection that names one kind does not borrow the other
from the process".

### BUG - MEDIUM · Styles the bundles create were blocked under Option 1 — fixed, with one condition left

Codex reproduced this in headless Chromium with the guide's Option 1 header. I did not repeat
that browser run.

What was blocked:

- Fresco's daisyUI bridge, injected at load of `phoenix_kit.js` (around line 1044). An empty
  host page that loads the public bundle is enough.
- Gallery chrome, injected at load of `phoenix_kit_admin.js` (`ensureGalleryCss`, around line 5958).
- The consent widget's rules. They were a `<style>…</style>` string inside `innerHTML`
  (`createWidgetHTML`). A nonce attribute on a style tag parsed from `innerHTML` is not applied.
  The buttons' `style=""` attributes are a separate gap (below).
- On demand: person-card backdrop (`buildPop`, around line 319), change cue (around line 6330),
  crosshair (around line 8048), sortable `injectStyles`, annotation-burn `stillStyle`, and
  `TableFit`'s `this.styleEl`.

What changed. `pkStyleNonce` / `pkAdoptStyle` live in `phoenix_kit.js` just after
`PK_SCRIPT_NONCE` is captured (line 587). The nonce must be set on the element's `.nonce`
**before** it is inserted. The content attribute is hidden from selectors and from
`getAttribute`. `document.currentScript` is null in every later callback, so the script nonce
is saved while the file evaluates.

Lookup order:

1. The `.nonce` of the first `<style>` already on the page. A host with a different nonce per
   kind is not given the script nonce.
2. Otherwise `PK_SCRIPT_NONCE`, the nonce of the tag that loaded this file.

`window.PhoenixKitInternals.adoptStyle` is assigned immediately and again in the later
`Object.assign` (merge, not a fresh object — replacing that object previously wiped the
person-card openers). The person-card IIFE ends around line 529, before the helper's text, but
`function pkAdoptStyle` is hoisted in the outer IIFE and `buildPop` runs later, so the call is
in scope. The early `if (window.PhoenixKitInitialized) return` means a second include does not
reassign; the first include already did. Later IIFEs in the file still run on a double include.
That double-listener behaviour is older than this change.

`phoenix_kit_admin.js` wraps it (line 39) and no-ops when `PK.adoptStyle` is missing, so an
older public file does not throw. The version check still requires `PK.sidebarScroll` only.
`phoenix_kit_sortable.js` calls `PhoenixKitInternals.adoptStyle` when it is there. That file
can load before the public bundle; the style is then unnonced, which is what it already did.

Consent: `createWidgetHTML` returns `{css, html}`. `injectWidget` builds the root from the HTML,
creates a detached `<style>`, calls `pkAdoptStyle`, sets `textContent`, inserts the style into
the detached root, then appends the root. Setting `textContent` after a correct nonce is fine.
Setting the nonce after insertion is not.

Not done, on purpose: a sibling `phoenix_kit.css` plus a `<link>`. The installer
(`js_integration.ex`) copies `phoenix_kit.js` only. A digested filename would not match a fixed
link, and the link would be async relative to first paint. Nonce-stamping is the path that
matches the installer.

Condition that is still true. A page with no `<style nonce>` and no nonce on the
`phoenix_kit.js` tag still blocks fresco and gallery. External scripts are allowed by `'self'`
without a nonce on the tag, which is why the old guide example was not enough. Option 1 in
`guides/content-security-policy.md` ("Styles and scripts the bundle creates") now shows:

```heex
<script defer nonce={assigns[:csp_nonce]} src={~p"/assets/vendor/phoenix_kit.js"}></script>
```

When the two nonces differ, the bundle reads a `<style>` already on the page and does not reuse
the script nonce. A two-nonce host whose first style element appears only after the bundle runs
still gets the script nonce on that first style, and the style is blocked. The guide says so.

`pkStyleNonce` returns the first style nonce it finds. A style that carries some other nonce
(an extension, a host style for a different policy) would be copied. I did not find a kit path
that does that. Worth a look if a host reports the wrong nonce being reused.

Turnstile and other CDN script tags were left unnonced. A nonce does not allow a foreign origin
unless the policy uses `strict-dynamic`, and stamping Turnstile would make those hosts run it
as trusted. The library loader already copies the nonce onto the first local script only
(`i === 0` near line 785).

### BUG - MEDIUM · Consent dropped the approved script's nonce — fixed

Codex's finding, confirmed in the source. `unblockScripts` (`phoenix_kit.js` around line 1280)
copied attributes onto a new `<script>`. Chromium hides the nonce from that list, so the
replacement was blocked and the approved script never ran.

The replacement now does `if (script.nonce) newScript.nonce = script.nonce` before copying
attributes and before `replaceChild`. An original with no nonce stays without one. The copy
happens while the new element is still detached.

No new browser test for the two cases Codex asked for (nonced original runs, unnonced original
stays unnonced). The Node fake does not model nonce hiding. A headless check is still the right
confirmation.

### BUG - MEDIUM · Table first paint would launder `localStorage` into an allowed stylesheet — fixed

New. Not in Codex or Mistral. The first-paint script in `table_default.ex` (`fit_restore/1`,
line 631) used to read `localStorage["phoenix_kit:table-fit:" + id].css` and insert it. The
script is inline and now carries the page's script nonce, so it may create style elements. Putting
that nonce on text from `localStorage` would make the stored string an allowed stylesheet.

The hook (`fit` in `phoenix_kit_admin.js`, the `localStorage.setItem` near line 3969) now stores:

```javascript
{ sig, cols: [{ index, head }, ...], headerCount }
```

`sig` is still `fitSignature(headers)` and is compared, not interpolated into CSS. The inline
script requires `saved.cols` length 1..100 and a whole `headerCount`. Each column needs a whole
`index` and `head`: `typeof n === "number" && n > 0 && n < 500 && (n | 0) === n`. Anything else
returns without inserting. It then rebuilds the rules and sets `style.nonce` before
`textContent` and `head.appendChild`. It never reads `saved.css`.

The grammar is copied, because this script runs at parse time, before `phoenix_kit.js` and long
before the admin bundle. It has to stay identical to `fitHideCss` (line 3881):

- `@media screen {\n` + selectors joined by `,\n` + ` { display: none; }\n` + optional badge + `\n}`
- header: `#${id} > table > thead > tr > :nth-child(HEAD)`
- body: `#${id} > table > :not(thead) > tr > :nth-child(INDEX):not([colspan])`
- badge walks down from `headerCount`, skipping hidden heads, then
  `::before { content: "+N"; margin-inline-end: 0.25rem; font-size: 0.6875rem; font-weight: 600; opacity: 0.6; white-space: nowrap; }`
- id escape: `CSS.escape`, else `replace(/^(\d)/, "\\3$1 ").replace(/([^\w\s\\-])/g, "\\$1")`
  (`fitEscapeId`). The id comes from the DOM element the server rendered, not from storage.

`test/js/table_fit.test.cjs` extracts `fit_restore`'s script from the Elixir file, runs it, and
requires the text to equal `fitHideCss` for a spanning header and for the id `a.b:c-fit`. It
also expects no element for: no saved value, a `{css}` payload with no `cols`, a non-integer
index, a fractional `headerCount`, a mismatched signature, and an empty `cols` list. The Elixir
render test asserts the script contains `saved.cols`, `style.nonce` and `n < 500` (so HEEx did
not escape the comparison), and does not contain `saved.css`.

An old `{css, sig}` entry misses one first paint. The hook rewrites the key on mount. That is
acceptable.

Nonce for that style: scan `getElementsByTagName("style")` for `.nonce`, else
`document.currentScript.nonce`. Same order as `pkAdoptStyle`. The inline script cannot call
`pkAdoptStyle`; it runs before the bundle.

### IMPROVEMENT - MEDIUM · The inline-tag check missed openings that close on a later line — fixed

Mistral's finding 1. `test/phoenix_kit_web/csp_inline_tags_test.exs` used to require `>` on the
same line as `<script` or `<style`. Four real tags were invisible to it
(`layouts/root.html.heex` twice, `layouts/dashboard.html.heex`, `layout_wrapper.ex` around
1611), all nonced by hand. A future multi-line tag without a nonce would have passed.

`tag_openings/1` now accumulates from a start-of-line `<script` / `<style` until the first `>`.
The nonce check looks at that opening only. An opening that contains `src=` is skipped: an
external script is allowed by `'self'`. The test "a tag that closes on a later line is still
seen" requires `root.html.heex` to have an opening containing `<script`, `defer` and `src=`.
That tag is skipped by the nonce check because of `src=`, so a green nonce test does not by
itself prove the join worked.

Doc heredocs are still blanked before the scan. Handler checks are unchanged and still go line
by line. I did not re-do Mistral's mid-line sweep of `lib/`.

### IMPROVEMENT - MEDIUM · Generated user-dashboard `live_session` dropped the nonce — fixed

Mistral's finding 2. Both notices in `lib/mix/tasks/phoenix_kit.gen.user.dashboard.ex`
(`print_success_message` at line 317 and `print_index_success_message` at line 354) now print:

```elixir
live_session :user_dashboard,
  session: {PhoenixKitWeb.CSP, :live_session, []},
  on_mount: [
    PhoenixKitWeb.CSP,
    {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
    {PhoenixKitWeb.Dashboard.ContextProvider, :default}
  ] do
```

No test greps this notice. A generator test would be the lock.

### Left open

#### BUG - MEDIUM · The fallback root layout still does not load `phoenix_kit.js`

Codex's finding. Unchanged. `lib/phoenix_kit_web/components/layouts/root.html.heex` around line 58
loads `/assets/app.js` only. The supported installer path puts `phoenix_kit.js` in the host's own
root. If this fallback renders a page, and the host's `app.js` does not already contain the
bundle, the listeners step 3 moved out of the markup never run. Tests that only assert
`data-pk-*` cannot see that.

Left alone. Adding the bundle here as well as in a host root that already imports it runs the
file twice. The early return skips the second init, but the IIFEs after that return still
install listeners again. Decide on one place before editing the fallback.

#### IMPROVEMENT - MEDIUM · No doctor check for plug order

Mistral's finding 3. Unchanged. `Integration` copies the nonce into the process dictionary when
**it** runs. A host plug placed after it leaves dead renders without a nonce. LiveView is
immune: `session: {PhoenixKitWeb.CSP, :live_session, []}` reads the finished connection.
`mix phoenix_kit.doctor` does not warn. Worth adding. I did not.

#### IMPROVEMENT - MEDIUM · Hand-written pages still call `CSP.nonce(:style)`

Mistral's finding 4. Still true, and now safe to change, because `nonce/2` no longer borrows
the process dictionary.

Still on `nonce(:style)` (1-arity):

- `lib/phoenix_kit_web/controllers/push_controller.ex:118`
- `lib/phoenix_kit_web/controllers/push_open_controller.ex:190`
- `lib/phoenix_kit_web/controllers/website_access_controller.ex:249` and `:286`
- `lib/phoenix_kit_web/oauth/pages.ex:397` (the shell)

With the documented order (nonce plug **before** `Integration`) the process dictionary is the
right value, including these pages: Mistral checked they sit under `:phoenix_kit_auto_setup`.
When the nonce plug runs **after** `Integration`, the assign is on the connection by render time
and the dictionary is empty. `CSP.nonce(conn, :style)` would see the assign. The maintenance
plug already uses `CSP.attr(conn, :style)`.

The three controllers can take `conn` in the assigns they already build. The OAuth shell cannot
see a parent `@conn`. `consent_controller.ex` renders with
`render.(Map.merge(switcher(conn), assigns))` and `authorize_controller.ex` calls
`Pages.error(assigns)`. Shell calls pass `title`, `lang` and `languages` only. Threading means
`conn={@conn}` on every shell call, or the nonce string passed in. I skipped it to keep this
pass on the bundle and the lookup. Do it as a follow-up, with `nonce(conn, :style)` and not the
old `||` fallback.

#### Still outside this work

- **Inline `style=""` attributes.** Widespread, and the consent widget's buttons still have
  them. `style-src-attr 'unsafe-inline'` (or an unsplit `style-src 'unsafe-inline'`) is still
  required. The consent `<style>` element itself is nonced now. The guide bullet says that.
- **cally** (`vendor_libs/cally`, `cally.js` creates a style element). Checksummed by
  `viewer_libraries_test.exs`. Do not edit it. A date input under nonce-only `style-src` can
  still lose the calendar rules.
- **Module packages** (`phoenix_kit_*`), including `phoenix_kit_legal`'s own consent script.
  None were touched.
- **CDN libraries** fetched by components. Same as the guide already says.
- **Cached documents.** I did not re-check Mistral's answer that the only same-for-all HTML
  with inline tags is the two exempt files (sitemap HTML, public API guide). A nonce must not
  be added to those.

### What I agree with, so it does not need another pass

- Step 1: deleting the Integration body rewrite is right. The plug's script never cleared
  `phx:fallback:<transport>`; `clearPhoenixTransportCache` in the bundle does. The remember-me
  test that the body is byte-identical is the right lock. I did not re-run that integration file.
- `put_nonces/1` writing an empty reading (delete) is the right same-process behaviour. The new
  `nonce/2` tests sit next to the existing one.
- Nonce in the LiveView session being signed rather than encrypted is acceptable. It is already
  in the HTML.
- Assigning `:phoenix_kit_csp_nonces` on every mount is harmless.
- Do not treat the previously reported full-suite OAuth and registration failures as caused by
  this work. They were blamed on leftover rows in a shared database, and they were seen with
  these changes stashed. I did not re-run the full suite.

### What the next agent should press on

1. Re-read `pkAdoptStyle`, the consent `injectWidget`, and `fit_restore` against a real
   enforcing header. This pass has no browser. Codex's Chromium fixture is the model: Option 1
   header, fresh nonce, the repository's bundles, an empty page and a page that accepts consent.
2. Confirm the first `<style nonce>` on a two-nonce page is actually the style nonce. The helper
   trusts the first one it finds.
3. The `fitHideCss` grammar is now in two places. The Node test locks the current text. A change
   to either copy has to change both, and the test.
4. `CSP.nonce(:style)` on the four hand-written pages above, if you take Mistral's finding 4.
5. Whether the fallback root should load the bundle. Do not add it blindly.
6. Plugin order in doctor, if you take Mistral's finding 3.

### Verification

Ran:

- `mix format` on the touched Elixir files, then `mix credo --strict` on
  `csp.ex`, `table_default.ex`, `phoenix_kit.gen.user.dashboard.ex`, `csp_test.exs`,
  `csp_inline_tags_test.exs`, `table_default_test.exs`. No issues.
- `mix test` on those three test files: 54 tests, 0 failures. Unit tests, no database. The
  first-paint test was run once more after adding the `n < 500` assertion: pass.
- `node --test` on `admin_split.test.cjs`, `table_fit.test.cjs`, `declared_handlers.test.cjs`,
  `popup_link.test.cjs`, `transport_cache.test.cjs`: 107 passed, including the two new
  `adoptStyle` cases. `table_fit.test.cjs` again after the grammar tests: 15 passed.
- `node --check` on `phoenix_kit.js`, `phoenix_kit_admin.js`, `phoenix_kit_sortable.js`.

Not run: `mix precommit`, `mix test` as a whole, `csp_nonce_pages_test.exs`,
`integration_remember_me_test.exs`, and a browser with an enforcing Content-Security-Policy.
A green unit run does not prove the stamp works in Chromium. Nonce hiding and
`style-src-elem` need that.

## Author's response — Claude, 2026-11-25 (after the four reviews)

Read: Gemini (above), Mistral (above), Grok (above) and Codex
(`dev_docs/pull_requests/2026/2026-11-25-csp-inline-code/CODEX_REVIEW.md`). This section merges
them into one state. Gemini reviewed from another machine and did not see the other three; the
other three did not see Gemini. Where they overlap they agree.

### Where my report above was wrong

- **"Every inline tag in `lib/` now has `nonce={…}`."** One was broken. `toggle_icon_css/1` in
  `core/theme_controller.ex` builds a plain string, and my mechanical edit wrote the HEEx form
  into it, so the page got the literal attribute `nonce={PhoenixKitWeb.CSP.nonce(:style)}`.
  Gemini found it. Without a policy the style still applied (a junk attribute); under a nonce
  policy it was blocked and both toggle icons showed. It has been on `main` since `b354e77bf`.
- **"Known gaps" named only the consent widget for styles created from script.** There are about
  ten such places in the three bundles, and two of them run at load. Codex showed in headless
  Chromium that an empty host page with the guide's Option 1 header and the public bundle
  already violates the policy. So the guide's Option 1, as I wrote it, did not work.
- **Risk 2 (process dictionary) was real in one path I did not think of:** `nonce(conn, kind)`
  fell back to the dictionary, so a connection without the assign could render an earlier
  request's nonce. Codex and Gemini both found it.
- **The lint test** could not see a tag whose `>` is on a later line (Mistral), nor tell HEEx
  from a plain string (Gemini), which is why the theme toggle passed.

### State of every finding

| Finding | From | State |
|---|---|---|
| Literal `nonce={…}` in the theme toggle | Gemini 1 | **Fixed in this pass** (`CSP.attr(:style)`), render test + lint case added |
| Styles the bundles create have no nonce | Gemini 2, Codex | Fixed by Grok (`adoptStyle`), **not re-run in a browser** |
| Consent replacement script loses its nonce | Gemini 3, Codex | Fixed by Grok, not re-run in a browser |
| `nonce(conn, kind)` borrows the process dictionary | Gemini 4, Codex | Fixed by Grok, two tests |
| Table first paint would stamp CSS read from `localStorage` | Grok | Fixed by Grok, Node test locks the grammar |
| Lint misses multi-line openings | Mistral 1, Gemini 6 | Fixed by Grok |
| Generated dashboard `live_session` lacks the options | Mistral 2 | Fixed by Grok, no test |
| `annotation_burn.test.cjs` failed after `adoptStyle` | — | **Fixed in this pass** (the test evaluates `burnCapturePlan` alone and did not supply the helper; two cases were red, so `mix precommit` was red on Grok's tree) |
| Nested LiveViews (`live_render/3`) lose the nonce when connected | Gemini 5 | **Open** |
| Fallback root layout does not load `phoenix_kit.js` | Codex | **Open** |
| Hand-written pages use `nonce(:style)` where `conn` is at hand | Mistral 4, Gemini 7 | **Open** |
| No doctor check (plug order, config shape) | Mistral 3, Gemini 7 | **Open** |
| Delete the dictionary in a `before_send` | Gemini 4 | **Open**, optional now that `nonce/2` is strict |
| Guide gaps (`style-src-attr` in the snippet, merging `session:`, other directives) | Gemini 8 | **Open**, partly covered by Grok's guide edit |
| `copyTextFor` reads `.value` of `<li>` etc.; `blur` guard; consent/sweep tests | Gemini 9 | **Open** |
| Lint: single-quoted handlers, mid-line tags, the other two bundles | Gemini 6 | **Open** |
| `:phoenix_kit_csp_nonces` assign is unused | Gemini 9, Mistral | **Open**; I would drop it |

### One disagreement between reviews

Mistral wrote that the push, access and OAuth pages "sit under `:phoenix_kit_auto_setup`, so the
process dictionary is set for them". Codex is right that this is not the reason:
`phoenix_kit_auto_setup` only assigns `:inner_block`. The dictionary is set by
`Plugs.Integration` in the host's `:browser` pipeline, which those routes also pass. The
conclusion holds, the mechanism does not, and Gemini's suggestion (call `put_nonces/1` in
`:phoenix_kit_auto_setup` as well) would make it true.

### What I would do next, in order

1. **A browser run before anything else.** Three bugs here (the bundle styles, the consent
   script, the theme toggle) are invisible to every test in the repository and were found only
   by a browser or by reading. Codex's fixture is the model.
2. Nested LiveViews (Gemini 5). It is the remaining correctness bug on kit pages: the admin
   header's widgets and the notifications bell are nested views on every admin page.
3. `nonce(conn, :style)` on the hand-written pages plus `put_nonces/1` in
   `:phoenix_kit_auto_setup`. Together they remove the plug-order requirement for everything
   except the pages `Integration` itself halts on.
4. The fallback root layout. Decide where the bundle is loaded first; loading it twice installs
   the document listeners twice.
5. The smaller items.

### Verification of the combined tree (mine + Grok's + this pass)

- `mix precommit`: failed on the two `annotation_burn` cases, passes the rest (compile, format,
  credo, dialyzer). After the fix it passes in full, JS tests included.
- `mix test` on the CSP files, the remember-me plug file, `route_precedence_test.exs` and all of
  `test/phoenix_kit_web/components`: 1843 tests, 1 failure, `PeoplePickerTest` "is exported for
  modules" (`function_exported?` before the module is loaded). It passes alone (16 of 16) and
  touches nothing here.
- Full `mix test`: not re-run on the combined tree.
- Browser: none by me.

## Second pass — Claude, 2026-11-25: the open items, and a browser run

Everything the table in "Author's response" listed as **Open** was worked on in this pass. This
section is the one for the next reviewers. Please recheck it against the diff, not against this
prose: the first report was wrong in three places that only a browser or a careful reading found.

Base for this pass: `dbddc819b` (the combined tree after the four reviews). Review
`git diff dbddc819b..HEAD`.

### What changed, by finding

**Nested LiveViews lose the nonce when connected (Gemini 5) — fixed.**
A view rendered with `live_render/3` is its own process and never runs the live session's
`on_mount`. Two halves:

- The parent puts the nonces into the child's session: `PhoenixKitWeb.CSP.nested_session/1`, used
  at the three sites (`layout_wrapper.ex` header widgets and `NotificationsBell`,
  `live/dashboard.ex` `:home_session`).
- The child restores them: `on_mount PhoenixKitWeb.CSP` is now part of
  `use PhoenixKitWeb, :live_view` (`lib/phoenix_kit_web.ex`), and `NotificationsBell`, which uses
  bare `Phoenix.LiveView`, has the line itself.

A root kit view now runs that `on_mount` twice (live session and module). It is idempotent.
A module's header widget on bare `Phoenix.LiveView` gets the session but restores nothing until
it adds the line; the guide says so. **I did not audit the module packages for such views.**

**Hand-written pages rely on plug order (Mistral 4, Gemini 7) — fixed, differently from the
suggestion.** Instead of threading `conn` into each template, each of these calls
`CSP.put_nonces(conn)` right before it renders, so the 1-arity `nonce(:style)` in the template
reads this connection's value: `push_controller.ex`, `push_open_controller.ex`,
`website_access_controller.ex` (both pages), `oauth/authorize_controller.ex` (`error_page/2`),
and `oauth/consent_controller.ex` (a controller plug `:csp_nonces`, because its pages are built
in four places).

**Plug order on kit routes (Gemini 7) — fixed.** `Integration.call(conn, :phoenix_kit_auto_setup)`
now calls `CSP.put_nonces/1` again, after the host's whole `:browser` pipeline. Mistral's sentence
("those pages sit under `:phoenix_kit_auto_setup`, so the dictionary is set") is true now.

What still depends on the order: kit components on the **host's own pages** (the theme bootstrap
in the host's root layout), and the two pages `Integration` itself halts on (maintenance, the
website gate). Nothing can read an assign that does not exist yet.

**No warning when the order is wrong (Mistral 3, Gemini 7) — fixed, twice.**

- At runtime: `Integration` now calls `CSP.put_nonces_first/1`, which marks the process. A later
  `put_nonces/1` of the same request that finds a nonce where the first reading found none logs
  one warning (once per node, `:persistent_term`) naming the fix.
- `mix phoenix_kit.doctor`, new check "Content-Security-Policy" (`csp_verdict/3`, pure): a
  `csp_nonce_assign_key` of the wrong shape (`CSP.config_problem/0`), `Integration` missing from
  `pipeline :browser`, and the plugs that come after it. It reads the router's source text with
  a regex. It cannot know which plug assigns the nonce, so it lists them and says "if one of
  them".

**Stale nonce in a reused process (Gemini 4, second half) — fixed.** `put_nonces/1` registers a
`before_send` that deletes the dictionary entry. Only when it stored something, and only while
the connection is not sent yet.

**The fallback root layout does not load `phoenix_kit.js` (Codex) — fixed, with a guard.**

- `PhoenixKitWeb.Layouts.kit_bundle_paths/1` asks the host's endpoint (from
  `conn.private.phoenix_endpoint`) whether `priv/static/assets/vendor/phoenix_kit.js` and
  `phoenix_kit_modules.js` exist, and `root.html.heex` loads those, deferred, before `app.js`.
  No file, no tag: a host that imports the bundle in `app.js` and never ran the compiler is
  unchanged.
- Grok's objection was that a second include installs listeners twice. So `phoenix_kit.js` now
  counts its runs (`window.__pkBundleLoads`) and each of its ten later top-level sections
  returns on a second run. The first section already returned on `PhoenixKitInitialized`.

**Lint blind spots (Gemini 6) — fixed.** `test/phoenix_kit_web/csp_inline_tags_test.exs`:

- Tags are found anywhere in the file by one multi-line scan, after blanking doc heredocs, HEEx
  comments and `#` comment lines. Four files that handle tags as data are skipped by name
  (`@tags_as_data`).
- Handlers: also single-quoted, also with spaces around `=` (for a list of real event names; a
  bare `on\w+ =` matches Elixir like `only = "x"`), and `javascript:` in `href` / `src` /
  `action` / `formaction`.
- All four bundles are scanned, not two.
- New: every `createElement("style")` in a bundle must be followed within four lines by
  `adoptStyle` / `adopt(`, and no bundle may build a `<style` tag as a string.
- From the previous pass: a `nonce={…}` in an `.ex` file must sit inside a `~H` template.

**Small listener issues (Gemini 9) — fixed.** `copyTextFor` reads `.value` only from `INPUT`,
`TEXTAREA`, `SELECT`; `data-pk-blur` checks that the focused node has `blur`; the image sweep
skips SVGs. Tests added for the consent dispatch (`__proto__`, `constructor`, a real method that
is not on the allow-list) and for the sweep.

**The unused `:phoenix_kit_csp_nonces` assign (Gemini 9, Mistral) — removed.** `on_mount/4` now
returns the socket untouched.

**Guide gaps (Gemini 8) — fixed.** `style-src-attr` is in the Option 1 snippet; new subsections
on why the order matters and where it does not, the script tags and `'strict-dynamic'`, merging
`session:`, nested views, the other directives the kit's features need, and what was checked in
a browser. The stale sentence in `oauth/responses.ex` is corrected.

### The browser run

Headless Chromium 159 against a throwaway host. Harness and how to run it:
`dev_docs/handoffs/2026-11-25-csp-browser-harness/`. Policy: the guide's Option 1 with
`style-src-attr 'unsafe-inline'`. Every page in three modes: one nonce, a nonce per kind, and a
nonce assigned after the first reading. **43 checks, 0 failed.**

| Scenario | Result |
|---|---|
| Empty page that loads both bundles | 0 violations, both created styles have a sheet |
| Same, bundles from `55039edd7` (control) | 2 `style-src-elem` violations |
| Controller page: theme toggle, decimal field, copy buttons, broken image, `data-pk-blur`, `data-pk-no-submit` | all behave; 0 violations from the kit |
| LiveView: a `<style>` patched in after connect, in the page's view | applied |
| Same, in a nested view using `PhoenixKitWeb, :live_view` | applied |
| Same, in a nested view with nothing restoring the nonce (control) | blocked, 1 violation |

Three things the run showed that the prose above did not say:

1. **A host's own `onfocus` on `<.decimal_input>` is blocked by the policy.** My first report
   said it "still runs after the kit's". That is true only without a nonce policy. The guide is
   corrected.
2. **Two documented limits are real.** An empty page with a different nonce per kind and no
   `<style>` on it yet, and an empty page with no nonce on the bundle's script tag, each give
   2 violations. Grok described both; the run confirms them. They are reported, not asserted.
3. **The late-plug case works on kit routes** (`mode=late`): the page renders with the nonce
   although it was assigned after the first reading.

What the run does **not** prove, so please do not read it as more:

- `Plugs.Integration` itself did not run (it needs a database). A stand-in plug calls the same
  `put_nonces_first/1`, and the kit's `:phoenix_kit_auto_setup` clause is in the harness
  pipeline on every page. So the "late" result holds for kit routes, not for a host's own page.
- The kit's real router, root layout and admin layout were not served. The components were
  rendered in a harness layout.
- Not exercised: the consent widget (its stylesheet and the script it releases, Codex's second
  finding), the table's first-paint script and `TableFit`, the preview card, the language
  switcher, live navigation between two pages, the fallback root's new script tag.
- The theme-toggle check has no control run. The old code is Elixir, not a file I could swap.
  The unit test covers the literal attribute.
- Chromium only.

### Where to look hardest this time

1. **`use PhoenixKitWeb, :live_view` now carries an `on_mount`.** Every kit and module LiveView
   gets it. It reads one session key and writes the process dictionary. Check that nothing
   depends on the order of `on_mount` hooks, and that a view with `layout: false` or a sticky
   view is not affected. `route_precedence_test.exs` passes, but it inspects the live session's
   hooks, not the module's.
2. **`put_nonces/1` registers a `before_send` on every call that stores something.** Three calls
   on a kit page means three callbacks, each deleting one dictionary key. Harmless as far as I
   can see. Is there a path that renders after `before_send` has run (an error page rendered by
   `Plug.ErrorHandler`, a chunked response)?
3. **The late-plug warning is once per node.** A host that fixes the order and later breaks it
   again without a restart gets no second warning. Also: it fires only when the first reading
   found *nothing*. A host that assigns one nonce early and replaces it later is not detected.
4. **`__pkBundleLoads`.** The counter is incremented at the top of the file, outside any
   function. The ten later sections return when it is above 1. I verified the listener counts
   in the fake page (`declared_handlers.test.cjs`, which fails on the previous bundle), not in a
   browser. Is there a host arrangement that *relies* on the second run, for example a module
   bundle that expects a later section to run after it registered something?
5. **`kit_bundle_paths/1`** does two `File.regular?` calls per page render under the fallback
   root, uncached. It trusts `endpoint.config(:otp_app)` and `:code.priv_dir/1`. In a release
   the files are in the release's `priv`; I did not test a release.
6. **The doctor's router parsing is a regex over source text.** A `pipeline :browser` built by a
   macro, or plugs added through `plug` inside an imported block, are invisible to it. It then
   says `Integration` was not found, which is a false warning.
7. **The lint's `@tags_as_data` list.** Four files are skipped whole. A real inline tag added to
   one of them would not be seen.
8. **The handler regex's event list** is mine and finite. `onanimationstart = "…"` with spaces
   would pass; without spaces it is caught by the first alternative.

### Still open

- A browser run on a **real host** (router, layouts, database): the consent widget, the table,
  live navigation, the fallback root. The harness is a start, not that.
- **Inline `style="…"` attributes** still need `style-src-attr 'unsafe-inline'`.
- **`cally`** (vendored date picker) creates an unnonced style element. Checksummed; not ours to
  edit.
- **Module packages**, including `phoenix_kit_legal`'s own consent script and any header widget
  on bare `Phoenix.LiveView`.
- No test for the text the dashboard generator prints (Grok).
- `PhoenixKitGlobals` still carries the stale transport-clearing line from before step 1.

### Verification of this pass

- `mix precommit`: passes (compile with warnings as errors, format, credo strict, dialyzer, the
  JS suite).
- New and changed tests: `csp_test.exs` (nested session, cleanup at send, the late-plug warning
  and its two negative cases, `config_problem/0`), `csp_inline_tags_test.exs` (six cases),
  `root_layout_bundle_test.exs`, `doctor_csp_test.exs`, `declared_handlers.test.cjs` (17 cases,
  including the double include, which was confirmed red on the previous bundle).
- Browser: 43 checks as above.
- Full `mix test` against the real database: 17 078 tests, 23 failures. Twenty are the same
  OAuth-client and "first user" tests that fail with none of this work applied (leftover rows
  in the shared test database). Three were new in this run: `ApprovalsDecideTest` (a unique
  email already taken), `ExecutorGateTest` (a unique role name already taken) and
  `PermissionsHardeningTest` (a lock on `phoenix_kit_user_roles` cancelled). None touches CSP,
  and the three files pass when run on their own (103 tests, 0 failures). I read them as the
  same shared-database noise, but that is a reading, not a proof: the suite was not run on a
  clean database.

## Codex recheck after the fixes at `69531ff24`

I would close all four original Codex findings for the host setup in the guide. An explicit
connection now supplies its own nonce, including when an assign is missing. I verified the
other three fixes in Chromium under an enforcing policy.

- **Runtime styles and consent.** The Fresco, gallery and core consent-widget stylesheets all
  applied. Clicking **Accept All** ran the consented script that carried the original nonce.
  An otherwise equivalent script without a nonce stayed blocked and accounted for the only
  CSP violation in that fixture.
- **Fallback root and live navigation.** A temporary Phoenix endpoint served the real kit
  router, Integration plug and fallback root with the PostgreSQL test repo and vendored assets.
  Chromium connected to sign-in and followed the magic-link navigation in the same document.
  The public bundle loaded once, before the module bundle and app.js. Every style element on
  the destination retained the document nonce and had an active stylesheet. Chromium reported
  zero CSP violations.

### Two tooling findings remain open

1. **A failed browser assertion still gives the harness a successful exit status.** The runner
   prints its failure count but only exits unsuccessfully on an exception. Set a nonzero exit
   code when any check fails. Also assert `host === undefined` in the decimal-field check,
   which currently only prints whether the host's inline handler ran. [Browser runner](2026-11-25-csp-browser-harness/run.cjs)
2. **The doctor's CSP check reports an internal exception for `csp_nonce_assign_key: false`.**
   The config validator accepts the boolean because it is an atom. The doctor then passes
   `false` as the router source to `csp_verdict/3`, raising a `FunctionClauseError` that the
   doctor reports as a failed check. Reject boolean assign names with a configuration warning
   and test the path from the setting through the verdict. [Doctor check](../../lib/mix/tasks/phoenix_kit.doctor.ex#L2620)

The focused runs passed 151 Elixir tests with PostgreSQL and 93 JavaScript tests. The committed
Chromium harness reported 43 checks with zero failures, including two entries that only log
documented limits. The additional browser runs covered core consent and public auth navigation.
Authenticated admin navigation, external module packages and the full suite remain outside this
recheck. [Detailed Codex review](../pull_requests/2026/2026-11-25-csp-inline-code/CODEX_REVIEW.md)

## Recheck — Grok, after `69531ff24`

Read the second-pass section, Mistral's recheck and Codex's recheck against the tree at
`69531ff24`, not against the prose. Claude's product fixes are in the code and the tests that
lock them pass. Codex's two tooling findings were still open, and they were real. Both are
fixed in this commit.

### Confirmed in the source

- `CSP.nonce/2` still reads only the connection. The stale-nonce and split-kind tests pass.
- `put_nonces/1` stores, warns when a later reading of the same request finds a nonce the first
  reading missed, and registers `before_send` to delete the dictionary. `put_nonces_first/1`
  clears the dictionary before that first reading. The three tests around plug order and the
  "forgotten when the response is sent" test pass.
- Kit routes call `put_nonces/1` again from `PhoenixKitWeb.Integration.call/2` on
  `:phoenix_kit_auto_setup`, after the `:browser` pipeline.
- The hand-written pages call `put_nonces/1` before render: `push_controller.ex`,
  `push_open_controller.ex`, `website_access_controller.ex` (both pages),
  `oauth/authorize_controller.ex` `error_page/2`, and a `:csp_nonces` plug on
  `oauth/consent_controller.ex`. The templates still use `nonce(:style)`. That is equivalent
  once this call has run.
- `nested_session/1` is used at the three nested-view sites (`layout_wrapper.ex` header widgets
  and the bell, `live/dashboard.ex` `:home_session`). `on_mount PhoenixKitWeb.CSP` is on
  `use PhoenixKitWeb, :live_view` and on `NotificationsBell`. `on_mount/4` no longer assigns
  `:phoenix_kit_csp_nonces`. A nested session test passes.
- A sticky or `layout: false` view is not a nonce bug. Live navigation keeps the same document,
  so the nonce from the first response is the one the socket must keep. A full load is a new
  process.
- The fallback root loads `Layouts.kit_bundle_paths/1` before `app.js`, deferred, with a script
  nonce. `Path.join` on this Elixir keeps the host `priv/static` prefix when the bundle path
  starts with `/`. `root_layout_bundle_test.exs` passes. No file, no tag.
- `phoenix_kit.js` has eleven top-level sections. The first returns on `PhoenixKitInitialized`.
  The other ten return when `window.__pkBundleLoads > 1`. The counter is incremented before any
  of them. I did not re-run the double-include browser case; the Node test is Claude's.
- Maintenance and the website gate still render inside `Integration`, from the first reading.
  A nonce plug after `Integration` still leaves those two without a nonce. Claude said this.
  It is still true. Nothing in the pipeline can read an assign that does not exist yet.

### Codex's two tooling findings — real, now fixed

1. **Doctor crashed on `csp_nonce_assign_key: false`.** `false` and `true` are atoms, so
   `config_problem/0` said the setting was fine, and `key && host_router_source()` passed
   `false` into `csp_verdict/3`, which has no clause for it. Confirmed by reading
   `csp.ex` and `phoenix_kit.doctor.ex` `check_csp/0`. Booleans are now rejected as assign
   names (a map value of `true` or `false` too), the runtime does not use them as keys, and
   the doctor warning is the "not usable" one. Test:
   "true and false are not assign names, and the doctor does not raise on them". It calls
   `csp_verdict/3` the way `check_csp/0` does, including `false && "router source"`.
2. **The browser harness exited 0 when a check failed.** `run.cjs` printed the failure count
   and only `process.exit(1)` on an exception. It now exits 1 when `failed.length > 0`. The
   decimal-field check also requires `host === undefined`, which is what a blocked
   `window.__hostFocus = …` handler leaves. I did not re-run Chromium.

### Still open, and I agree they are open

- Inline `style=""` attributes, cally (checksummed), module packages, and a header widget on
  bare `Phoenix.LiveView` that nobody added `on_mount PhoenixKitWeb.CSP` to.
- No test greps the dashboard generator's printed `live_session`.
- The doctor's router check is a regex. A macro-built `pipeline :browser` is reported as
  "Integration was not found".
- The late-plug warning is once per node, and only when the first reading found nothing.
- The harness entries with `want === null` are recorded as passes on purpose. They log the
  two documented limits (two nonces and no style yet; no nonce on the script tag). A failure
  inside those pages does not fail the run.
- I did not repeat Codex's Chromium runs, `mix precommit`, or the full suite. Codex's report
  of zero violations on consent and on sign-in through the real router is Codex's, not mine.
  The unit files I ran: `csp_test.exs` and `doctor_csp_test.exs`, 25 tests, 0 failures, after
  the boolean fix. `root_layout_bundle_test.exs` was run before that fix, 3 tests, 0 failures.
