# PhoenixKit 2.54.0 — complete release review

**Reviewer:** Codex (OpenAI)  
**Date:** 2026-10-05  
**Baseline:** `v2.53.0` (`93f753973`)  
**Prepared release:** `eddf7214d`, version 2.54.0

## Scope

Reviewed the complete 37-file release diff: PR #903's installer/config editing, PR #905's table fitting, log-out exemption, mail logging, Settings layout, disabled-module redirects and provider icons, the three-worker cron backfill, version/CHANGELOG and Gettext changes. This is a release review, not solely a review of PR #905.

## Findings fixed

### BUG - MEDIUM — Cron presence checks can leave real jobs unscheduled

An aliased DigestWorker makes the updater attempt a duplicate cadence, causing the whole digest backfill to be refused. Module references in another job's arguments, and longer module names beginning with a worker's name, can suppress a real worker entry. Both are fixed by reading actual worker positions and digest arguments from parsed entries. Details and reproductions: [installer review](../903-oban-cron-insertion/GPT_REVIEW.md).

### BUG - MEDIUM — Failure logging bypasses recipient masking

The delivery log masks `email.to`, then prints the adapter error unchanged. Brevo/SMTP responses can echo complete addresses, including in nested maps/lists or Erlang charlists. Inspection can truncate a long address before its `@`, defeating any scrub performed afterwards.

Error terms are now scrubbed before bounded inspection, preserving the error status and diagnostic text. Tests exercise the real Brevo adapter with a nested response containing a long recipient and a second address, a charlist error and invalid UTF-8 bytes. The original adapter result is returned unchanged. Success logs now name the configured adapter rather than merely `PhoenixKit.Mailer`.

### BUG - MEDIUM — Dropping the last table column also hides the dropped-column indicator

`fitHideCss` put `+N` on `:last-child::before`. A final header with a priority is itself a valid eviction candidate, so a simple Name/Email/Status table loses both final columns and its indicator. The current Integrations table's permanent Actions column concealed this reusable-component bug.

The indicator now targets the last surviving header by its header position, preserving the separate header/body positions after a spanning header. Added JS regressions. Chromium confirms the narrow table fits and shows `+2`, resizing restores columns, print shows all columns and destruction removes the stylesheet.

### NITPICK — The anonymous log-out exemption's documentation denies its session changes

The ordinary controller path clears anonymous session data and persisted account cookies. Corrected the moduledoc and explained the implication for hosts using `SameSite=None`; authentication-bearing requests retain their CSRF checks.

## Other release checks

- Version 2.54.0 is an appropriate minor bump for the new table-fitting API. No migration changes are included; the cron upgrade's first activity prune is documented.
- Settings changes preserve field names, descriptions and form behavior. Provider icons preserve their labels and fixed tile sizing. Disabled-module redirects use route helpers and the existing allowlisted tab parameter.
- Both localized and ordinary log-out routes run the exemption before the host CSRF pipeline; the session/account stack and raw remember-me-cookie checks prevent exempting authenticated requests.
- The CHANGELOG now includes the review fixes. Gettext extraction/merge reports zero new, removed or fuzzy messages; no additional catalogue diff was produced.

## Remaining limitations

The pre-paint restore is an inline script, so restrictive script CSP may block it; the hook still measures on mount. Hosts forbidding dynamically inserted styles also need a CSP-compatible integration before using fitting. Full subjects are intentionally logged and can contain personal information; the address scrub is not a general-purpose secret scrubber for arbitrary adapter messages. Computed config and nested environment overrides retain the updater's conservative/manual handling.

## Validation

- Original targeted baseline: 367 tests, zero failures, with PostgreSQL available.
- Wider installer/Mix/UI/mail validation: 787 tests and 8 doctests, zero failures.
- Final mail and cron regression rerun: 37 tests, zero failures.
- Worker/digest backfills against 25 real workspace host configurations: parseable and idempotent; no host files written.
- `mix precommit`: passed, including warnings-as-errors compilation, test compilation, formatting, strict Credo, Dialyzer and all 266 JS tests.
- Table-fit JS tests: 12 passed. Chromium: fitting/indicator, resize, print and stylesheet cleanup passed.
- Full PostgreSQL-backed suite: 87 doctests and 8,552 tests, zero failures; six skipped and one excluded because the DB role lacks CREATEROLE.
- `mix prerelease`: exit 0; production compilation, quality checks, dependency audits, docs and Hex package build pass. Release check: 7/7 passed, zero warnings or failures; the generated tarball was cleaned up.

No publishing or release tagging is part of this review.
