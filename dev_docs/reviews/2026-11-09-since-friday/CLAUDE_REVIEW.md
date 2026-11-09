# PhoenixKit changes since Friday — Claude's check of the Codex review

Date: 2026-11-09. Checks `695c0c6f7` (Codex's fixes, see `CODEX_REVIEW.md`).

## Verification

- Ran Codex's regression tests against the code before its commit (`5a651914e`
  `lib/`): 13 of them fail there, covering all eight findings, and pass after it.
  Each finding was real and its fix is guarded.
- Read the session and authority changes: the operator of each impersonation
  is kept in the signed session (`pk_impersonators`, raw tokens, as the stack
  already holds), further impersonation from a borrowed account is judged on
  that operator only while its session is live (`root_user_from_token/1`), and
  the entry is pruned whenever an account leaves the stack (`drop_own/2`). The
  widget check now agrees with `MultiSession.impersonated?/1`, including an
  organization slot. `remove/4` reuses `update`'s guards, which already let
  `host_*` calls through.
- Users, sessions, notifications, widgets and i18n suites: 2,420 tests, 0 failures.

## Follow-ups made here

### IMPROVEMENT - MEDIUM — the refusals Codex added had no words in the rows

`remove/4` can now answer `:cannot_modify_own_roles` and `:not_permitted`, but the
Organizations row (person page, user form) and the People row (organization page)
showed "This change is not available." for both. They now reuse the People tab's
translated sentences. One visible consequence of finding 1: an Admin can no longer
remove their own company link from their page (only an Owner changes their own
link, as the link contract always said); the row now says so.

### BUG - MEDIUM — a system role saved unchanged went back to English

Finding 4 makes a role form save copy the description into `data`, as the label
already was. For a system role saved with its seed text untouched, the primary
language then holds "Administrator with elevated privileges" (and "Admin" as the
label), which `Roles.display_description/2` and `display_name/2` returned in every
language, past the translated seed text. Both now translate the seed text wherever
it is stored; a rewritten label or description shows as written. Test:
`users_admin_russian_test.exs`, failing before the change.
