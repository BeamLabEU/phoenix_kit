# PR #471 Review — Fix orphan files query: publishing_versions instead of posts.data

**Reviewer:** Claude
**Author:** @timujinne
**Date:** 2026-04-01
**Verdict:** Approve

## Summary

One-commit, 2-line fix for a 500 error on `/admin/media`. Migration v88 moved the `data` column from `phoenix_kit_publishing_posts` to `phoenix_kit_publishing_versions` and renamed `featured_image` to `featured_image_uuid`, but the orphan files query in `storage.ex` wasn't updated to match.

## Changes

### `lib/modules/storage/storage.ex`

| Before | After |
|--------|-------|
| `phoenix_kit_publishing_posts` | `phoenix_kit_publishing_versions` |
| `pp.data->>'featured_image'` | `pv.data->>'featured_image_uuid'` |

The query is part of `orphan_file_conditions/0`, which builds NOT EXISTS subqueries to determine which uploaded files are not referenced by any table.

## Verification

- The table `phoenix_kit_publishing_versions` and column `data->>'featured_image_uuid'` are consistent with migration v88 and with the adjacent `phoenix_kit_publishing_contents` query on line 743, which uses the same `featured_image_uuid` key.
- The alias changed from `pp` to `pv` to match the new table name — cosmetic but correct.

## Assessment

Straightforward regression fix. No issues found. Clean PR.
