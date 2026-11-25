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

## Recheck at `69531ff24`

I would close the four findings above for the documented host setup. I found two follow-ups in the verification tooling.

- **The browser harness exits successfully when a behavioral check fails.** `rec` accumulates failures, and the final block prints their count. Only an exception sets a failing exit status. The decimal-field check also prints whether the host's inline handler ran while its predicate checks only the clear and restore values. Set the exit code when `failed.length > 0`, and include `host === undefined` in that predicate. This run did produce zero failures and showed the handler blocked in all three modes. See [browser checks](../../../handoffs/2026-11-25-csp-browser-harness/run.cjs).
- **The doctor's CSP check reports an internal exception for a boolean setting.** With `csp_nonce_assign_key: false`, `config_problem/0` returns `nil` because booleans are atoms. The expression `key && host_router_source()` then passes `false` as the router source, for which `csp_verdict/3` has no clause. I confirmed the `FunctionClauseError`. The doctor catches it and marks that check failed. Recommend rejecting boolean assign names with an actionable config warning and covering the path from the setting to the verdict. See [doctor](../../../../lib/mix/tasks/phoenix_kit.doctor.ex#L2620).

### Independent verification

- The focused Elixir suite passed 151 tests with PostgreSQL, and the four focused JavaScript suites passed 93 tests. The committed Chromium harness reported 43 checks and zero failures. Two of its 43 entries only log documented limitations.
- In a separate Chromium fixture I enabled the core consent widget and clicked its Accept All button. Its stylesheet, the Fresco stylesheet and the gallery stylesheet all applied. The consented script carrying the original nonce executed. An otherwise equivalent unnonced control stayed blocked and accounted for the sole CSP violation.
- I served the real kit router, Integration plug and fallback root in a temporary Phoenix endpoint with the PostgreSQL test repo and vendored assets. Chromium connected to the sign-in LiveView, then followed its magic-link navigation in the same document. The public bundle loaded once, ahead of the module bundle and app.js. Every style element on the destination retained the document nonce and had a stylesheet. Chromium reported zero CSP violations. The fixture used a minimal module bundle and logged that anonymous session tracking was unavailable.
- The explicit-connection lookup now reads only from that connection. The focused tests cover the stale-value and split-nonce cases. On a bare host page with split nonces, the bundle still needs an existing nonced style element, as the guide documents.

This recheck covers the core auth and consent paths above. The full suite, authenticated admin navigation, and external module packages were outside this run.
