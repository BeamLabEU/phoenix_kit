# PR #900: Shorten the email-confirmation waiting screen

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `ccb10a0f7` (merge `560eee043`)
**Date**: 2026-10-03 (merged 2026-10-04)

## Goal

The parked "Confirm your email to continue" page carried a long paragraph and a second
hint line. It now shows one line with the address and, only when a live confirm token exists,
the sent time.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit_web/users/confirmation_instructions.html.heex` | One `We sent a confirmation link to %{email}.` line; the "Sent … ago" line renders only with `@confirmation_sent_at`; the "No confirmation email on record — use Resend below." branch is gone |
| `priv/gettext/**/default.po`, `default.pot` | New msgid in 9 catalogs, two msgids removed, line references renumbered |
| `test/integration/phoenix_kit_web/users/auth_flows_test.exs` | Two cases: the short copy, and the sent-time element appearing only after a token exists |

## Verification

- All eight translated catalogs carry `We sent a confirmation link to %{email}.` with `%{email}`
  intact, no fuzzy flag, and neither removed msgid left behind (`rg` over `priv/gettext` and
  `lib`/`test`: the only remaining mention of the old strings is the test's `refute`). The
  template's msgids match the `.pot` (`Sent` :21, `We sent…` :16, `Confirm your email…` :10).
- Translations read correctly and keep each locale's existing address form (de *Sie*, es *tú*,
  fr *nous avons envoyé*, it, pl, ru, et first-person plural).
- `en` has empty `msgstr` throughout, as for every other `en` entry.

## Findings

- **IMPROVEMENT - MEDIUM** — `confirmation_instructions.html.heex:16-19`: the line now says
  *"We sent a confirmation link to …"* even when `@confirmation_sent_at` is `nil`, i.e. when no
  live confirm token exists (never sent, all expired, or mail failed). The docstring of
  `Auth.get_last_confirmation_sent_at/1` (`auth.ex:1518-1524`) states this exact page's
  "we sent a link" claim needs that evidence, and the removed branch ("No confirmation email on
  record — use Resend below.") was the honest fallback. After the PR a user whose email never
  went out sees a confident claim, no timestamp, and no pointer to Resend. The first new test
  (`auth_flows_test.exs`, "waiting screen is short") enshrines it: `register_user/0` sends
  nothing there, yet it asserts the "We sent" copy. Fix: render the "We sent" line only when
  `@confirmation_sent_at`, otherwise a short line such as the old "No confirmation email on
  record — use Resend below." (restore the msgid and its eight translations), and adjust the test
  to cover both branches.
- **NITPICK** — `et/default.po`: the *msgstr* of the unchanged msgid "Confirm your email to
  continue" was shortened to *"Kinnitage oma e-post"* (dropping "jätkamiseks"), in `et` only; the
  other seven locales still say "…to continue". Not wrong, but an unrelated, unannounced copy
  change that makes the locales drift. Also `et` is now *Kinnitage* (formal) above *Saatsime…*
  neutral lines — pre-existing mix of addressing, not introduced here.
- **NITPICK** — the class expression `(@confirmation_sent_at && "mb-1") || "mb-6"` is nil-punning;
  `if(@confirmation_sent_at, do: "mb-1", else: "mb-6")` states the intent.

## Verdict

The catalogs and template are consistent and the page is shorter, but dropping the no-record
fallback re-introduces the unsupported "we sent" claim the sent-at lookup was added to prevent.
Fix the MEDIUM (a small template + test change) before the next release.

## Resolution (2.52.0)

- **IMPROVEMENT - MEDIUM** — fixed: the page says "We sent a confirmation link to …" only when
  `@confirmation_sent_at` is set; otherwise the "No confirmation email on record — use Resend below." line is back
  (msgid and its translations restored from history in all eight locales; `gettext.extract --merge` round trip, 0 fuzzy).
  The test now covers both branches and asserts the "We sent" claim only after a real delivery.
- NITPICKs (`et` wording of an unchanged msgid, `||` class expression) — the class expression went away with the
  rewrite; the `et` string is left to a native speaker.
