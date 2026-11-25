# PhoenixKit CSP review

The full write-up for later agents is the section "Review feedback — Grok, 2026-11-25" in
`dev_docs/handoffs/2026-11-25-csp-inline-code.md`. This file is the short copy. Extend the handoff.

Reviewed commits `48912e11e`, `b354e77bf` and `55039edd7` (report `49b9c3488`), plus Mistral's notes in the handoff and `CODEX_REVIEW.md`. The fixes below are in the working tree and are not committed. Nothing here is released.

## Fixed

### BUG - MEDIUM · An explicit connection inherited another request's nonce

`CSP.nonce/2` used to fall back to the process dictionary when the given connection had no assign for that kind. A controller process serves many requests, so request B could render request A's nonce. `attr/2` did the same.

`nonce/2` now reads only that connection. A missing assign is no nonce. Components that have no connection still use `nonce/1`. Two tests cover a bare connection after a stored nonce, and a connection that names only the script nonce.

See [connection lookup](../../../../lib/phoenix_kit_web/csp.ex#L73).

### BUG - MEDIUM · Styles the bundles create were blocked under the guide's example policy

Fresco injects a stylesheet as soon as `phoenix_kit.js` loads. The admin bundle does the same for gallery chrome. Consent built its rules as a `<style>` string inside `innerHTML`, which never receives a nonce. The change cue, the crosshair, person-card backdrop, sortable, image-burn and table-fit styles were created the same way.

`pkAdoptStyle` stamps the element before it is inserted. It prefers the `.nonce` of a `<style>` already on the page, so a host with a different nonce per kind is not given the script nonce. When the page has no style nonce, it uses the nonce of the `<script>` that loaded the bundle, captured while that file evaluates (`document.currentScript` is null in every later callback). The consent widget's rules are a real `<style>` element now, inserted the same way. `phoenix_kit_admin.js` calls the helper when the public file provides it, and does not throw when an older public file does not. `phoenix_kit_sortable.js` does the same.

A page that has neither a nonced `<style>` nor a nonce on the `phoenix_kit.js` tag still blocks those rules. The guide's Option 1 example now shows the nonce on that tag. A sibling `phoenix_kit.css` was not added: the installer copies `phoenix_kit.js` only, and a digested filename would not match a fixed `<link>`.

See [adoptStyle](../../../../priv/static/assets/phoenix_kit.js#L580) and [the guide](../../../../guides/content-security-policy.md#styles-and-scripts-the-bundle-creates).

### BUG - MEDIUM · Consent dropped the original script's nonce

Chromium hides a nonce from the attribute list, so the replacement script lost it and a strict `script-src` refused the script the visitor had just approved. The replacement now copies `script.nonce` before it is inserted. An original that had none stays without one.

See [consent script replacement](../../../../priv/static/assets/phoenix_kit.js#L1280).

### BUG - MEDIUM · The table's first paint would have laundered `localStorage` into an allowed stylesheet

Once the inline restore script carries the page's nonce, inserting `localStorage["phoenix_kit:table-fit:" + id].css` would make whatever is in that key an allowed stylesheet. The hook now stores `{sig, cols, headerCount}` — column numbers, not CSS. The inline script rebuilds the rules from positive integers only (the same grammar as `fitHideCss`) and sets `.nonce` before `appendChild`. A stored `css` string is ignored. An old `{css: ...}` entry misses one paint; the hook rewrites the key on mount.

The Node test runs that script, extracted from `table_default.ex`, and requires its text to equal `fitHideCss` for a spanning header and an id that needs escaping. It also refuses a non-integer, a bad signature, an empty column list, and a payload that is only a stylesheet string.

See [fit_restore](../../../../lib/phoenix_kit_web/components/core/table_default.ex#L631) and [fitHideCss](../../../../priv/static/assets/phoenix_kit_admin.js#L3881).

### IMPROVEMENT - MEDIUM · The inline-tag check missed an opening that closed on a later line

Mistral's finding. The check now joins lines until the first `>` and judges that opening. A tag with `src=` is skipped (an external script is allowed by `'self'`). `root.html.heex` has a multi-line `<script defer … src=` and the test requires that opening to be seen, so a join that never reaches `src=` fails.

See [csp_inline_tags_test.exs](../../../../test/phoenix_kit_web/csp_inline_tags_test.exs#L15).

### IMPROVEMENT - MEDIUM · The generated user-dashboard `live_session` dropped the nonce

Mistral's finding. Both notices printed by `mix phoenix_kit.gen.user.dashboard` now include `session: {PhoenixKitWeb.CSP, :live_session, []}` and `on_mount: [PhoenixKitWeb.CSP, …]`. No test greps that notice text.

See [phoenix_kit.gen.user.dashboard.ex](../../../../lib/mix/tasks/phoenix_kit.gen.user.dashboard.ex#L317).

## Left open

### BUG - MEDIUM · The fallback root layout still does not load `phoenix_kit.js`

Codex's finding, unchanged. `root.html.heex` loads `/assets/app.js` only. A host the installer set up loads the bundle from its own root, which is the supported path. A page that actually renders this fallback, and whose `app.js` does not already include the bundle, loses the listeners step 3 moved out of the markup. Rendering tests that only see `data-pk-*` cannot tell. Left as it is: adding a second copy of the bundle next to a host that already imports it would run the file twice.

See [default root](../../../../lib/phoenix_kit_web/components/layouts/root.html.heex#L58).

### IMPROVEMENT - MEDIUM · No doctor check for plug order

Mistral's finding, unchanged. `Integration` snapshots the nonce when it runs. A host plug placed after it leaves the process dictionary empty. LiveView is immune, because `live_session` reads the finished connection. A doctor warning would catch the misconfiguration. Not added in this pass.

### IMPROVEMENT - MEDIUM · Hand-written pages still call `CSP.nonce(:style)`

The push install page, the push-open page, the website-access pages and the OAuth shell still read the process dictionary. With the documented plug order that is the right value. It is the wrong value when the host's nonce plug runs after `Integration`: the assign is on the connection by the time the template renders, and `nonce/2` would see it. The OAuth shell does not receive the connection (each page passes `title`, `lang` and `languages`), so threading it means an assign on every shell call. Not done here. The maintenance page already uses `CSP.attr(conn, :style)`.

### Still outside this work

- **Inline `style=""` attributes**, including the consent widget's buttons. `style-src-attr 'unsafe-inline'` is still required. The consent `<style>` element itself is nonced.
- **cally** (`vendor_libs/cally`) injects a style element. The file is checksummed. A date input under a nonce-only `style-src` can still lose the calendar's rules.
- **Module packages**, CDN libraries, and Turnstile. A nonce on the Turnstile tag would not allow `challenges.cloudflare.com` unless the host uses `strict-dynamic`, and stamping it would surprise a host that does.
- **A public page with no style nonce and no nonce on the `phoenix_kit.js` tag.** Fresco and gallery stay blocked there. That is the case Codex reproduced. The stamp fixes it once the tag carries the shared nonce, which the guide now shows. This pass did not repeat the headless Chromium run.

## Verification

- `mix test` on `csp_test.exs`, `csp_inline_tags_test.exs` and `table_default_test.exs`: 54 tests, then the first-paint assertion again, 0 failures. These are unit tests.
- `node --test` on `admin_split.test.cjs`, `table_fit.test.cjs`, `declared_handlers.test.cjs`, `popup_link.test.cjs` and `transport_cache.test.cjs`: 107 passed, including the two `adoptStyle` cases. `table_fit.test.cjs` again after the grammar tests: 15 passed.
- `mix credo --strict` on the six touched Elixir files: no issues. `mix format` on those files.
- `node --check` on `phoenix_kit.js`, `phoenix_kit_admin.js` and `phoenix_kit_sortable.js` passed earlier in the pass. The public file is 343780 bytes. The size budget in `admin_split.test.cjs` is `340 * 1024` (348160), about 4.3 KB of room.
- Not run: `mix precommit`, the full `mix test`, the integration nonce-page tests, and a browser with an enforcing policy. The earlier full-suite OAuth and registration failures were left alone; they were reported against a shared database before these edits.
