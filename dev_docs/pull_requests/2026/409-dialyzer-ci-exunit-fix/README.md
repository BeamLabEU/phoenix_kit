# PR #409 — Fix Dialyzer CI for ExUnit test support files

**Author:** Tymofii Shapovalov (timujinne)
**Base:** dev
**Stats:** +6 / -1 across 1 file, 1 commit

## What

Add Dialyzer ignore entries for `test/support/conn_case.ex` and `test/support/data_case.ex` to fix CI failures.

## Why

When compiled in `MIX_ENV=test` (CI environment), ExUnit expands internal macros (`__merge__/4`, `__noop__/0`, `__proxy__/2`) that Dialyzer can't resolve, producing false positive `:unknown_function` warnings. These are OTP 27.1 / ExUnit internals, not real issues.

## Key Changes

- `.dialyzer_ignore.exs`: Add file-level `:unknown_function` ignores for both test support files
