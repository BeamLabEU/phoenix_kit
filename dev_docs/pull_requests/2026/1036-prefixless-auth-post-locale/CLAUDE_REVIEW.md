# PR #1036 — Fix the prefixless auth POSTs answering in the gettext default, not the primary language

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no changes

Merged into `main` as 66e169b0f.

`generate_basic_scope/1` (`POST /users/log-in`, log-out, session/account switching, the magic-link / QR / passkey /
registration-link completions, OAuth, context switching) had no locale step. Its flash messages and redirects followed
the host's gettext default instead of the site's primary language. The scope now adds
`:phoenix_kit_locale_validation`, as the `/:locale/` scopes and the prefixless pages already do.

Checked:
- **No redirect on these routes.** `process_locale/1` redirects only when the path carries a `locale`/`language` param.
  None of the basic-scope routes binds either one (their params are `:token`, `:provider`, `:uuid`, `:ref`, `:key`,
  `:id`, `:user_uuid`). So every request takes `assign_default_locale/1`: Gettext is set and nothing is redirected.
  A login POST cannot be turned into a GET, and an OAuth callback keeps its query.
- **Pipeline order.** The locale plug runs after `:browser`, so it overrides a locale the host set in `:browser`. The
  CHANGELOG states this, and it matches the prefixless pages.
- **Explicit locale in controllers.** A controller that sets the locale itself still wins, since plugs run first.
- **`/api/consent-config`.** It now answers in the primary language rather than the gettext default. Neither is the
  requesting page's language, so this does not get worse. The sub-bullet records it.

## Findings

None.

## Validation

`test/integration/i18n` (including the new `prefixless_auth_post_locale_test.exs`) and `test/integration/users` on a
fresh scratch DB: green.
