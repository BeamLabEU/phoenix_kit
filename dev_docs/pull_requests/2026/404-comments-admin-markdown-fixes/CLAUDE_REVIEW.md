# PR #404 Review — Updated comments admin, fixed markdown editor

**Reviewer:** Claude
**Date:** 2026-03-12
**Status:** MERGED
**Author:** @alexdont

## Summary

Six commits covering: dimension form bug fix, markdown editor navigation fix, comments metadata JSONB field (V82 migration), test comments seed script, reply indicators in admin comments, and CommentsComponent crash fix.

## Changes Reviewed

### 1. Dimension form inputs clearing each other (`dimension_form.ex`, `dimension_form.html.heex`)

**Good:** Derives `dimension_type` from `live_action` in mount instead of leaving it nil. Removes duplicate `phx-change="validate"` on checkbox that was sending partial form data.

**No issues found.** Clean, minimal fix.

### 2. MarkdownEditor toolbar fix (`listing.html.heex`)

**Good:** Changes `navigate` to `href` so the page does a full reload, ensuring inline scripts execute.

**Minor concern:** Using `href` instead of `navigate` loses SPA-style navigation (full page reload). This is a pragmatic fix but the root cause is that JS hooks aren't re-initialized on LiveView navigation. Consider adding a `phx-hook` to the markdown editor component long-term so it works with LiveView navigation.

### 3. Comments metadata JSONB field (`comment.ex`, `v82.ex`, `postgres.ex`)

**Good:** Idempotent migration with `add_if_not_exists`, proper table existence check, schema + type + changeset all updated consistently. Default `%{}` is sensible.

**Issue — No validation on metadata size:**
The `metadata` field is cast but not validated. A malicious or buggy client could store arbitrarily large JSON. Consider adding a `validate_change/3` that checks byte size, e.g.:
```elixir
|> validate_change(:metadata, fn :metadata, value ->
  if byte_size(Jason.encode!(value)) > 10_000, do: [metadata: "too large"], else: []
end)
```
**Severity:** Low — depends on whether comments are user-facing or admin-only.

### 4. Reply indicators in admin comments (`index.html.heex`, `comments.ex`)

**Good:** Adds `:parent` preload and shows reply context with truncated parent content. Clean UI with icon and subtle styling.

**No issues found.**

### 5. CommentsComponent crash fix (`details.html.heex`)

**Good:** Fixes `resource_id` → `resource_uuid` to match expected assign name. Straightforward bug fix.

**No issues found.**

### 6. Test comments seed script (`test_comments.exs`)

**Good:** Useful for visual verification. Creates a realistic hierarchy (top-level, replies, nested).

**Minor:** This is a dev-only seed script, fine as-is. Consider adding a note that it requires at least one user and one post to exist.

## Migration Notes

- V82 added, `@current_version` bumped to 82 in `postgres.ex`
- V81 documentation was also added to `postgres.ex` (entity_data position column) — appears to have been a missing doc entry, not a new migration in this PR
- Migration is idempotent and follows established patterns

## Verdict

**Approve.** Six focused, well-scoped fixes. The metadata size validation is worth considering but not blocking. The `href` workaround for markdown editor is pragmatic — a proper hook-based solution can be a follow-up.

## Follow-up Suggestions

1. **Metadata validation** — Add byte-size validation on `metadata` field if comments are user-facing
2. **MarkdownEditor hooks** — Long-term: make the editor work with LiveView navigation via `phx-hook` instead of falling back to full page reload
