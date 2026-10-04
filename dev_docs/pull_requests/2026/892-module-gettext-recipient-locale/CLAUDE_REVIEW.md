# PR #892: Fix module email text ignoring the recipient's language

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `4a9108a0a` (merge `02e70b8c0`)
**Date**: 2026-10-03

## Goal

`RecipientLocale.in_locale/2` installed the recipient's locale for `PhoenixKitWeb.Gettext`
only. A feature module's own backend (`PhoenixKitBilling.Gettext`) has no locale of its own
on the process and falls back to the process-global Gettext locale, which on a worker or in
an admin's LiveView is the *sender's*. A module's default email text therefore came out in
the sender's language.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit/utils/recipient_locale.ex` | `in_locale/2` also runs `fun` under `Gettext.with_locale/2` with the **base** language (`es` for `es-ES`); `base_locale/1` |
| `test/support/module_gettext.ex` + fixtures | a stand-in for a module's backend with base-code catalogues (`en`, `es`, `pt`) |
| `test/phoenix_kit/utils/recipient_locale_test.exs`, `email/content_test.exs` | module backend reads the recipient's language; both locales restored on return, raise, throw and exit; a backend with its own locale keeps it |

## Verification

- Read the diff against `PhoenixKitWeb.Users.Auth.put_gettext_locale/2`, which the moduledoc
  now says it mirrors: the web path sets the backend's locale to `gettext_locale/1` and the
  global one to the same value, honouring `host_live_view_locale: :leave` for host
  LiveViews. This function sets the global to the **base** language instead, which is right
  for module catalogues (named `es`, `et`, `ru`; Gettext matches exactly) and is *scoped*:
  `Gettext.with_locale/2` restores it, so the `:leave` setting (about not clobbering a host
  LiveView's ambient locale) is not violated.
- Audited the callers of `in_locale/2` (`Email.Catalog`, `Email.Content`,
  `Notifications.Render`, `DigestWorker`, `UserNotifier`): all render for a recipient on a
  worker or on behalf of another user — the case the change is for. `nil` still leaves the
  ambient locale alone.
- `mix test` on the merged tree: the PR's tests, the email and notification suites, and the
  moduledoc doctests pass; the full suite passes (see the release commit).

## Findings

No bugs. The limitations are stated in the function's doc and accepted:

- **NITPICK** — a module that ships only a dialect catalogue (`pt_BR`, no `pt`) is read in
  `pt` and so misses; the module's backend is not known here. Documented. A module with both
  works.
- **NITPICK (adjacent, not part of this PR)** — `Integrations.Probe.run/2` copies only
  `PhoenixKitWeb.Gettext`'s locale into its spawned check process. A check that renders text
  from a module backend would read the global locale of a fresh process. No such check exists
  today; left alone.

## Verdict

Approve as merged. Correct, minimal, scoped, and the tests cover the failure modes (raise,
throw, exit, pre-set backend locale, dialect).
