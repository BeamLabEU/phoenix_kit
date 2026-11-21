# Review of PR #1052 — Notification wording

Reviewed the merged change at `94bb45d40`, including the fixes in the original review. The following findings concern the worker, settings and delivery paths on main.

### BUG - HIGH · A historical backfill granted a new permission

On installations still due for the security-settings backfill, a custom role holding `settings` would also receive the newly registered `settings.messages`. That permission lets its holder change outgoing notification wording. The backfill now grants only its historical permission, `settings.security`. A database test covers the custom-role upgrade. Sites that already ran the affected backfill should review existing `settings.messages` grants. The grant rows do not distinguish a deliberate grant from one made by the backfill.

### BUG - HIGH · Production delivery lost the recipient's wording locale

The workers passed a base language, or no language for a reader using the site default. Regional wording could be skipped, and site-default edits could disappear altogether. Workers now resolve the full content locale and use it for rendering and delivery while keeping the existing channel locale field compatible. The instant worker also checks record visibility before preparing a quote. Tests run actual delivery jobs with site-default and regional wording and check the digest envelope.

### BUG - MEDIUM · Edited copy could lose delivery links or render empty

An operator could remove the record or notification-preferences link by simplifying the email body. Telegram could also drop the preferences link when using custom wording or truncating a long reason. Both renderers preserve the relevant links. Email falls back to the underlying subject or body when the selected wording expands to an empty string. Regression tests inspect HTML, plain text and Telegram output.

### BUG - MEDIUM · A stale form could clear a newer edit

Submitting an empty final field triggered a reset using the version in the LiveView socket. The reset now checks the version submitted with that form, just like a save. A LiveView test submits a stale clear and verifies the newer copy survives.

### BUG - MEDIUM · A cache notification could precede the database commit

The message writer announced a settings change inside the transaction holding the advisory lock. A subscriber could refill its cache from the previously committed row. Saves now write the setting and its history together under the lock, then announce the change after the transaction succeeds. Resets follow the same ordering. The wording resolver also reads its fallback candidates in a batch.

### BUG - MEDIUM · The editor preview could disagree with delivery

The preview treated untouched email defaults as operator edits, masking host templates. It also used a separate Telegram renderer. Preview now layers edits over inherited wording and uses each delivery renderer. A LiveView regression test supplies a host template and checks that the preview displays it.

## Verification

The focused run passed 412 tests and four doctests. The full suite against a fresh PostgreSQL database reported 16,245 tests and 99 doctests with zero failures, 34 skipped and one excluded. `mix precommit` passed, including Credo, Dialyzer and 938 JavaScript tests.
