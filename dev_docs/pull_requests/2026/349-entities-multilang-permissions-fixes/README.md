# PR #349 — Fix Entities Multilang and Permissions Review Issues

**Author:** Max Don (@mdon)
**Merged:** 2026-02-18
**Base:** dev
**Commits:** 3
**Files changed:** 16 (+699 / -337)

## Summary

Combined fix PR addressing three areas:

1. **Entities multilang title unification** — Moves title translations from `metadata["translations"]` into the JSONB `data` column as `_title` key, unifying title storage with other field translations using the same override-only pattern.

2. **Rekey logic fix** — `rekey_primary/2` now recomputes all secondary language overrides against the new promoted primary, instead of leaving old secondary overrides untouched (which was incorrect since overrides are relative to the primary).

3. **Permissions review follow-ups** — Fixes 7 issues from PR #341 review: error atoms instead of hardcoded strings, system role self-edit logic, sorted custom keys, catch-all Scope fallbacks, UUID in admin auto-grant, CSS columns layout.

## Key Changes

### Entities Multilang
- `_title` stored in `data[lang]["_title"]` alongside custom fields (override-only for secondaries)
- `title` DB column remains denormalized copy for queries/sorting
- `seed_title_in_data/2` provides lazy backwards-compat migration on mount
- Old `metadata["translations"]` location used as transitional fallback in reads
- Slug generation button disabled on secondary language tabs
- 9 validation error messages wrapped in gettext

### Permissions
- `can_edit_role_permissions?/2` returns error atoms (`:not_authenticated`, `:owner_immutable`, `:self_role`, `:admin_owner_only`) — translated at LiveView call sites
- System role users can now edit roles they also hold (Admin+Editor can edit Editor)
- `custom_keys/0` sorted explicitly
- Catch-all fallback clauses on Scope functions prevent FunctionClauseError
- `auto_grant_to_admin_roles` uses UUID instead of integer ID

### Documentation
- 88+ namespace fixes: `PhoenixKit.Entities` -> `PhoenixKit.Modules.Entities` across DEEP_DIVE.md, OVERVIEW.md, README.md
- Field type count corrected (11 -> 12, file is now registered)
- `utc_datetime_usec` -> `utc_datetime` in docs

## Related PRs
- Follow-up to: [#341 — Custom permissions and edit protection](/dev_docs/pull_requests/2026/341-custom-permissions-edit-protection)
- Builds on: [#347 — DateTime standardization](/dev_docs/pull_requests/2026/347-datetime-standardization)
