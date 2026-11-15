# PR #1033 — Invite-only: admit accounts an admin creates, translate the code messages

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no changes

Merged into `main` as ddf351c60.

This PR makes three changes:
1. `Auth.admin_create_user/2` marks the new account admitted (`Referrals.mark_satisfied(user, "admin_created")`), so an
   admin-added person is not parked on `/users/referral`. A failed mark is logged and the call still answers
   `{:ok, user}`, because the account exists.
2. `OAuth.handle_oauth_callback/2` redeems `?referral_code=` only for an account the callback has just created
   (`status == :created`), and charges that check to the per-IP `check_referral_validation_rate_limit/1`. Over the
   limit, the account is created and left parked.
3. The three rejection strings of `Referrals.validate_for_signup/2` go through gettext, read per call so the caller's
   locale applies. "Referral code is required" is new in `default.pot` and the nine locales (`en` is the source, so its
   msgstr is empty).

Checked and fine:
- **Status atoms.** `find_or_create_user/3` answers only `:created` and `:found` (`oauth.ex:96`, `:139`), so the
  `:created` clause and the catch-all cover every case.
- **Return shape.** `record_signup_use/2` answers `:ok` on every path, so it satisfies the `:ok <-` step of the `with`.
  A rejected or raced code never rolls back the sign-in.
- **Nil IP.** `check_referral_validation_rate_limit/1` allows a nil IP, the same as the signup forms.
- **Other ways to create a user.** `rg register_user lib` finds only the public form, magic-link registration and the
  OAuth path. Those must not be auto-admitted, and they aren't.
- **Return value.** `merge_user_custom_fields/3` returns the row from `update_all … select`, without preloads.
  `UserForm.create_user/2` uses only `uuid`/`email`, and `host_convert_to_managed/3` accepts `{:ok, %User{}}`.
- **String matches.** No code matches the English text of a rejection message (`rg` over `lib/`; only the tests do).

## Findings

### NITPICK — The admission mark broadcasts `user_updated` inside a host's transaction (not changed)

`host_convert_to_managed/3` documents `fn -> Auth.admin_create_user(attrs, created_by) end` as its `first_manager`,
called inside its transaction. `mark_satisfied/2` → `merge_user_custom_fields/3` broadcasts `user_updated` before that
transaction commits. `do_register_user/2` already broadcasts `user_created` there too, and the moduledoc already warns
that events go out before the host's commit. So this adds a second pre-commit event of the same kind, not a new class
of problem. Left as is.

## Validation

`oauth_referral_code_test.exs`, `referral_access_gate_test.exs`, `referrals_validation_test.exs`, then
`test/integration/users` + `test/phoenix_kit/users` on a fresh scratch DB: green.
