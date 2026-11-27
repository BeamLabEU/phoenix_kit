# Review of PR #1067

Reviewed head `334da2f77` against `c364c5f4e`, covering avatar resolution and cropping, the mention list, stacked picker cards, recorded clip types, and the opt-in account menu theme controls.

## BUG - HIGH — Mention results disclosed an email-derived identifier

Gravatar URLs contain a deterministic hash of the user's address. The mention search checked the viewer's permission before returning or searching the email but returned that hash to all viewers. Rendered mention chips and unscoped comment thumbnails had the same new fallback.

The compact avatar resolver now requires a viewer scope with the existing `users` permission before selecting Gravatar. Search results and rendered mentions pass the viewer through. Unscoped callers still get uploaded and OAuth pictures, then initials or the caller's empty thumbnail. Regression coverage includes a user manager, a restricted viewer, and an absent scope.

## BUG - MEDIUM — System theme reverted for upgraded browsers

The bootstrap promotes an old preference from `phoenix_kit_theme` to `phx:theme`. Selecting System cleared only the newer key, so syncing a newly mounted menu or reloading the page restored the previous choice.

Selecting System now clears both keys. A JavaScript regression test runs the rendered bootstrap and controller with a legacy dark preference, selects System, then checks the choice after a menu sync and a fresh page load.

## Verification

`mix precommit` passed, including strict Credo, Dialyzer and 1,008 JavaScript tests. The 97 focused Elixir tests passed against PostgreSQL, including mention permissions, account menu integration, CSP and the admin layout snapshot. The full Elixir suite was outside this validation run.
