# PR #369 — Fix login crash: update user token check constraint for UUID-only inserts

**Author:** alexdont (Sasha Don)
**Merged:** 2026-02-25
**Reviewer:** Claude Opus 4.6

## Summary

Critical bugfix. V16's check constraint required `user_id IS NOT NULL` for non-registration tokens, but the UUID cleanup removed `user_id` from the UserToken schema. V64 replaces it with a `user_uuid`-based constraint.

## Verdict: PASS

## Analysis

### Migration V64 — Correct

- Properly drops old `user_id_required_for_non_registration_tokens` constraint
- Adds new `user_uuid_required_for_non_registration_tokens` constraint
- Uses `IF EXISTS` for idempotent drop
- Has correct `down/1` migration for rollback
- `COMMENT ON TABLE` correctly marks version as '64'

### Constraint Logic — Correct

```sql
CHECK (
  CASE
    WHEN context = 'magic_link_registration' THEN true
    ELSE user_uuid IS NOT NULL
  END
)
```

This correctly allows magic_link_registration tokens without a user (registration creates the user later) while requiring all other token types to have a user_uuid.

### `postgres.ex` — Correct

- `@current_version` bumped from 63 to 64
- V63 `LATEST` tag moved to V64
- Documentation added for V64

## Notes

- This was a production-blocking bug — login was completely broken after UUID cleanup
- Good that the fix was isolated to a single migration with minimal risk
