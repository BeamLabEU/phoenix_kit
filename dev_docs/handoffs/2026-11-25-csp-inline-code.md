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
