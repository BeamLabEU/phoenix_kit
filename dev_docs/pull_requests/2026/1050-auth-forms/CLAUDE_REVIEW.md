# PR #1050 — Fix form errors on untouched fields; rework the sign-in, sign-up and confirmation pages

**Author:** mdon · **Merged:** 2026-11-20 (`c208337e8`) · **Reviewed on main:** `a5111808e`

Read the merged diff without the `.po` churn: `Core.Input.field_errors/1` /
`field_untouched?/2` and every primitive that now uses them (Checkbox, Select, Textarea,
DateInput, DecimalInput, MultilangForm, the two storage forms, UserSettings custom fields), the
login, registration and magic-link registration LiveViews and templates, `AuthMethods`,
`OAuthButtons`, `AuthPageWrapper`, `ScopeNotifier.broadcast_account_changed/1` and the
`set_input` / Turnstile JS. Also read the post-merge fixes: Codex's restored confirmation
submit and configured-provider lookup, and the release recheck's `6fc0bb7b6`.

**Verdict:** no open bug. Codex and the release recheck already fixed the real ones: link
previews could confirm an account, and buttons showed for providers with no credentials.
Two improvements are recorded below and were not applied.

## Checked, fine

- **Untouched-field rule.** `field_untouched?/2` is used by every form primitive. No component
  under `components/` still maps `field.errors` itself. A submit sends no `_unused_` markers,
  and LiveView treats every input as used once the form has been submitted, so a failed save
  always shows its errors. Nested `inputs_for` forms have their own `params`, and LiveView puts
  the marker inside the nested map, so the rule works there too.
- **Registration and magic-link registration.** `_unused_*` keys pass `form_params/3` only
  while the visitor types. `save_params/2` drops them, so a forged marker cannot hide the
  errors of a failed save. Nothing casts them.
- **`login_handoff`.** It is a `Phoenix.Token` over `{action, email}` with a 60 s lifetime,
  minted only after the LiveView creates the account. It skips only the second Turnstile
  challenge for that email. The password check and the login rate limit still run.
- **`broadcast_account_changed/1`.** It rides the existing `{:phoenix_kit_scope_roles_updated, _}`
  message on the user's own topic. It cannot fail (`rescue` + `catch :exit`).
- **Return-to threading.** Magic link, QR, register and the provider links all carry
  `return_to` through `Routes.return_to_query/1` or `oauth_return_query/1`.

## Findings

- **IMPROVEMENT - MEDIUM — the "Add account" dialog reads OAuth credentials uncached on every
  admin navigation.** `AccountMenu.add_account_modal/1` calls
  `OAuthAvailability.configured_providers/0` in its body (since `6fc0bb7b6`). That function
  uses `Settings.has_oauth_credentials_direct?/1`: one database query per enabled provider.
  `admin_nav` and `user_dashboard_nav` pass `current_path`, so the call runs on the dead
  render, again on the connected mount, and on every patch or navigation. It only costs
  anything while OAuth and a provider switch are on: up to three queries per page view. The
  login and registration pages make the same call in `mount/3`, so a public, unauthenticated
  page costs two of these rounds per hit. **Not fixed:** the direct read is deliberate
  (`aadceb0f2`, "prevents race conditions when credentials are updated through admin UI"), and
  the release recheck relies on it to treat an undecryptable secret as missing. The fix worth
  doing later is a cached `configured_providers/0` for *display*, invalidated with the
  credential settings, with the OAuth callback keeping the direct read.
- **IMPROVEMENT - MEDIUM — the provider list is fixed in code.** `configured_providers/0`,
  `provider_icon/1` and `provider_name/1` know exactly `:google`, `:github` and `:facebook`.
  That predates this PR, and the three stay in step (a fourth atom cannot come out of
  `configured_providers/0`, so no `FunctionClauseError`). But it is the kind of choice the
  "Design for every installation" rule says should come from a registry: a new provider means
  editing four places. Left for the next change that adds a provider.
- **NITPICK — `login_handoff` can be replayed within its 60 s window** for more password
  sign-ins as the same email. The visitor already knows the password (they just set it), so
  nothing extra is exposed. Left as is.
