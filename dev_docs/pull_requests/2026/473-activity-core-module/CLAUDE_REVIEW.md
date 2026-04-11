# PR #473 Review — Activity core module for admin dashboard

**Reviewer:** Claude
**Date:** 2026-04-03
**Verdict:** Approve with suggestions

---

## Summary

Adds a cross-cutting Activity module (`PhoenixKit.Activity`) that logs business-level actions across the platform. Includes a V90 migration for the `phoenix_kit_activities` table, an Oban-based pruning worker, a complete admin UI (index with filters + detail page), and activity logging wired into all user lifecycle events (registration, email confirmation, password changes, profile updates, role changes, status changes, avatar changes, notes, deletion). Also fixes a bug where the media upload modal was nested inside the profile form causing a crash.

**Stats:** +1729 / -61 across 20 files, 15 commits.

---

## What Works Well

1. **Clean API design.** `Activity.log/1` is a simple map-in, tuple-out function with a rescue wrapper so activity logging never crashes the caller. The `log_user_change/4` helper that auto-extracts from/to diffs from Ecto changesets is a nice abstraction that prevents repetitive metadata assembly.

2. **Batch resolution pattern.** `resolve_resource_users/1` batch-queries user emails by `resource_uuid` instead of storing stale emails in metadata. This means the activity feed always shows the user's current email, and avoids N+1 queries.

3. **Real-time updates via PubSub.** The index LiveView subscribes to the activity topic and auto-refreshes when new entries arrive. Clean integration with the existing `PubSub.Manager`.

4. **Comprehensive logging coverage.** Every user lifecycle event is covered: registration (self + admin), email confirmation (email link, magic link, OAuth, manual admin toggle), password changes (user + admin paths), profile updates (with field diffs), avatar changes (with from/to UUIDs), role changes (with added/removed summary), status changes, notes (create/delete), and user deletion.

5. **Mode semantics are correct.** User-initiated actions (form submissions, button clicks) are `manual`; system-triggered actions (email confirmation via token, OAuth auto-confirm, password reset via token) are `auto`. This distinction was explicitly fixed during the PR lifecycle.

6. **Media modal bug fix.** Moving `UserMediaSelectorModal` outside the `simple_form` in `user_settings.ex` is a legitimate fix — the upload input was triggering `validate_profile` on the parent form which didn't have uploads registered.

7. **`build_audit_context` fix in UserForm.** Capturing IP and user_agent during mount (via assigns) rather than calling `get_connect_info` after mount is correct — `connect_info` is only available during the mount phase.

8. **Good documentation.** The AGENTS.md addition is thorough: API examples, naming conventions, complete action table, external module integration pattern, and retention config.

---

## Issues

### Bug: Pagination drops `module` and `mode` filters

**File:** `lib/phoenix_kit_web/live/activity/index.html.heex:265-269`

The pagination links only include `page`, `action`, and `resource_type` in `URI.encode_query/1`. The `module` and `mode` filters are not preserved, so clicking page 2 while filtering by module will reset those filters.

```heex
# Current — missing module and mode
URI.encode_query(%{
  "page" => page,
  "action" => @filter_action || "",
  "resource_type" => @filter_resource_type || ""
})

# Should be
URI.encode_query(
  Enum.reject([
    {"page", page},
    {"module", @filter_module},
    {"mode", @filter_mode},
    {"action", @filter_action},
    {"resource_type", @filter_resource_type}
  ], fn {_k, v} -> is_nil(v) or v == "" end)
)
```

### Nit: Missing `actor_uuid` in `delete_admin_note`

**File:** `lib/phoenix_kit/users/auth.ex:2192-2209`

The `delete_admin_note/1` function only receives the note struct and has no access to the current admin user. The activity log entry is missing `actor_uuid`, so the "who deleted this note" information is lost. The function signature would need to accept the current user to fix this.

### Nit: `resource_uuid` uses `Ecto.UUID` while other UUIDs use `UUIDv7`

**File:** `lib/phoenix_kit/activity/entry.ex:40`

`resource_uuid` is typed as `Ecto.UUID` while `actor_uuid` and `target_uuid` are `UUIDv7` (via `belongs_to`). This is intentional — resource UUIDs can reference any entity (posts, comments, etc.) that may not be in the users table — but it means you can't add a `belongs_to` association for resource lookups. Worth documenting the rationale.

### Nit: Duplicated `action_badge_color/1`

**Files:** `lib/phoenix_kit_web/live/activity/index.ex:144-161` and `lib/phoenix_kit_web/live/activity/show.ex:68-85`

The `action_badge_color/1` function is copy-pasted between both LiveViews. Additionally, `mode_badge_color/1` exists only in `show.ex` while `index.html.heex` uses inline `case` logic for the same purpose. Could be extracted to a shared helper.

### Nit: No FK constraints in migration

**File:** `lib/phoenix_kit/migrations/postgres/v90.ex`

The migration defines `actor_uuid` and `target_uuid` columns as plain `:uuid` without `references(:phoenix_kit_users)`. The schema has `foreign_key_constraint` validations, but these only work at the Ecto level. Without DB-level FKs, orphaned activity entries can reference deleted users. This may be intentional (activities should survive user deletion for audit purposes), but if so, the `belongs_to` associations in the schema will raise on preload for deleted users — the `resolve_resource_users` rescue clause handles this gracefully, but `get_entry!/1` with preload will return `nil` associations silently.

### Nit: Changeset construction in `update_user_profile` (UserForm)

**File:** `lib/phoenix_kit_web/users/user_form.ex:704-720`

The admin profile update path manually reconstructs a changeset from old/new user data to pass to `log_user_change/4`:

```elixir
changeset = Ecto.Changeset.change(user, %{
  email: updated_user.email,
  username: updated_user.username,
  ...
})
```

This only tracks 5 hardcoded fields. If new profile fields are added later, they won't appear in activity diffs unless this list is updated. The self-service path in `auth.ex` doesn't have this problem because it uses the actual `profile_changeset`.

---

## Verdict

**Approve with suggestions.** The Activity module is well-designed with a clean API, comprehensive coverage, and good UI. The pagination filter bug should be fixed before or shortly after merge. The other items are minor and can be addressed in follow-up work.

### Priority fixes
1. **Pagination filter loss** — functional bug, filters reset on page navigation
2. **Missing actor_uuid in note deletion** — audit gap

### Low-priority improvements
3. Extract shared badge color helpers
4. Make admin profile changeset field list dynamic
5. Document the intentional lack of FK constraints
