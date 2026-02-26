# PR #371 — Fix 3 billing bugs from PR #370 review + delete button for Media Detail

**Author:** timujinne (Tymofii Shapovalov)
**Merged:** 2026-02-26
**Reviewer:** Claude Opus 4.6

## Summary

Follow-up bugfix PR addressing issues found in PR #370 review:
- Fix dead code: remove `subscription_type_id: type.id` from `create_subscription/2`
- Fix key mismatch: accept `:subscription_type_uuid` in `create_subscription/2`
- Fix stale field read: `change_subscription_type/3` reads `subscription_type_uuid` instead of nil `subscription_type_id`
- Remove accidentally committed `.beam` files, add `*.beam` to `.gitignore`
- Add Delete File button with confirmation modal to Media Detail page
- Add missing `phoenix_kit_posts` metadata orphan check to `storage.ex`
- Add `String.trim()` to AWS credential values across SQS/email modules

## Verdict: NEEDS FIXES

## Critical Issues

### 1. `String.trim(nil)` crash when AWS credentials not configured

**Files:**
- `lib/modules/emails/sqs_polling_job.ex:327-329`
- `lib/modules/emails/sqs_worker.ex:652-654`
- `lib/phoenix_kit/aws/infrastructure_setup.ex:444-446`

**Severity:** HIGH — runtime crash

The PR added `String.trim()` calls around AWS config values, but the guard check doesn't prevent nil from entering:

```elixir
if config.aws_access_key_id != "" and config.aws_secret_access_key != "" and
     config.aws_region != "" do
  [
    access_key_id: String.trim(config.aws_access_key_id),     # nil != "" is true!
    secret_access_key: String.trim(config.aws_secret_access_key),
    region: String.trim(config.aws_region)
  ]
```

After the Config.AWS change in this same PR (returning `nil` instead of `""` when unconfigured), `get_aws_access_key/0` can return `nil`. Since `nil != ""` evaluates to `true` in Elixir, the guard passes and `String.trim(nil)` crashes with `FunctionClauseError`.

**Fix:** Change guards to check for both nil and empty string:
```elixir
if is_binary(config.aws_access_key_id) and config.aws_access_key_id != "" and
   is_binary(config.aws_secret_access_key) and config.aws_secret_access_key != "" and
   is_binary(config.aws_region) and config.aws_region != "" do
```

Or use `to_string/1` before trimming: `String.trim(to_string(config.aws_access_key_id))`

**Note:** `infrastructure_setup.ex` is safe — it validates credentials are non-nil before building the config map (line 119-121). But SQS workers are vulnerable.

### 2. Orphan detection still references non-existent `phoenix_kit_shop_variants` table

**Inherited from PR #370** — not fixed in this PR. The `phoenix_kit_posts` metadata check was added, but the variants table issue remains.

## What's Correct

- Billing fixes are clean and correct:
  - Removed dead `subscription_type_id: type.id` line
  - `create_subscription/2` now accepts `:subscription_type_uuid` as preferred key with proper fallback chain
  - `change_subscription_type/3` reads `subscription_type_uuid` correctly
- `.beam` files removed and `.gitignore` updated
- Media Detail delete button implementation is good:
  - Proper confirmation modal with warning text
  - Calls `Storage.delete_file_completely/1`
  - Flash messages on success/error
  - Redirect to media list on success
- `phoenix_kit_posts` metadata orphan check is correct

## Remaining Issues from PR #370 (Still Open)

| # | Issue | Severity | Status |
|---|-------|----------|--------|
| 1 | `phoenix_kit_shop_variants` in orphan query | CRITICAL | NOT FIXED |
| 2 | Default preload `:plan` -> `:subscription_type` | HIGH | NOT FIXED |
| 3 | Empty legacy files | LOW | NOT FIXED |

## New Issues from This PR

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 1 | `String.trim(nil)` crash in SQS workers | HIGH | Fix nil guard in `build_aws_config` |
