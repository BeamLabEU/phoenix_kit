# PhoenixKit CSP review

Reviewed commits `48912e11e`, `b354e77bf` and `55039edd7` against `ce9ac30ed`, including Mistral's feedback in the handoff. Removing the Integration plug's response rewrite is worth shipping independently. I would qualify the guide's compatibility claim until the following issues are addressed.

## BUG - MEDIUM · The public bundle violates the example policy on an otherwise empty host page

Fresco's theme setup appends an inline stylesheet as soon as the public bundle loads. The admin bundle does the same for gallery styles. In headless Chromium with the exact Option 1 header, both produced a `style-src-elem` violation and both style elements had a null `.sheet`. The public violation requires neither a kit layout nor the consent widget. Allowing style attributes as suggested in the guide leaves this failure intact. Other style elements are created on demand, including the admin table's column-fitting rules.

Move constant rules into a same-origin stylesheet. For rules that depend on live state, give the kit-owned style element the document's **style** nonce before populating it. The guide supports distinct script and style nonces. Cover a plain host page that loads the public bundle as well as an admin page. See [public bundle](../../../../priv/static/assets/phoenix_kit.js#L1022) and [admin bundle](../../../../priv/static/assets/phoenix_kit_admin.js#L5943).

## BUG - MEDIUM · Consent drops the original script's nonce

A host can provide a nonce-authorized inline script with a consent category. On acceptance, the widget creates a replacement script and copies the original's content attributes. Chromium hides the nonce value from that attribute list. In the browser check, accepting analytics produced a `script-src-elem` violation and the approved script never ran.

Preserve the original element's `script.nonce` property on its replacement before inserting it. Leave an originally unnonced script unnonced. A two-case browser test can verify both outcomes. See [consent script replacement](../../../../priv/static/assets/phoenix_kit.js#L1259).

## BUG - MEDIUM · The fallback root layout does not load the new listeners

A sign-in request through the real test router returned one external script, `/assets/app.js`. The kit's default root has no public bundle tag. A host using the supported installer arrangement loads the bundle through separate tags in its own root layout. If the kit fallback root renders a page instead, and app.js relies on those tags, controls converted in step 3 lose their handlers even with CSP disabled. A host importing the bundle into app.js already supplies it.

Load the public bundle through the supported asset path in the fallback root and check a converted control under that layout. Rendering tests that only assert the control's data attribute cannot tell whether the listener loaded. See [default root](../../../../lib/phoenix_kit_web/components/layouts/root.html.heex#L58) and [layout selection](../../../../lib/phoenix_kit/layout_config.ex#L83).

## BUG - MEDIUM · An explicit connection can inherit another request's nonce

The existing same-process test clears the dictionary by calling `put_nonces/1` for request B. A different path is explicitly supported by `nonce(conn, kind)` for a controller or plug running **before** that call. If request A left a nonce and B's connection has none for this kind, the fallback returns A's. This also affects `attr(conn, kind)`. A correct header for B rejects the stale value.

Make an explicit connection authoritative, including a missing assign. Keep process lookup for component calls that have no connection. Add a regression with A stored and B passed directly, including B configured with only one nonce kind. Mistral's proposed controller change should use the corrected lookup. Also, the router's `phoenix_kit_auto_setup` only assigns `:inner_block`. It does not initialize CSP. See [connection lookup](../../../../lib/phoenix_kit_web/csp.ex#L73) and [auto-setup plug](../../../../lib/phoenix_kit_web/integration.ex#L2452).

## Verification

The six focused Elixir files in the handoff passed with PostgreSQL (63 tests). The declared-handler, admin-split and transport-cache JavaScript suites passed (72 tests). A separate test-router request inspected the scripts actually emitted on sign-in. An isolated HTTP fixture served the repository's public and admin bundles to headless Chromium with an enforcing header and a fresh nonce. It confirmed the two rejected stylesheets, the consent-script failure and successful delegated zero clearing. Browser coverage was limited to that fixture. The full suite and end-to-end host LiveView navigation were outside this run.
