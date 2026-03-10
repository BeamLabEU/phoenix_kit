# PR #398 — Fix custom fields display and add bulk "Add to Group" action

**Author:** Sasha Don
**Base:** dev
**Commits:** 2
**Files changed:** 4 (+135, -1)

## What

1. **Fix Custom Fields card hidden when no field definitions are registered:** Show the `custom_fields` JSONB data in admin user details even when no custom field definitions are registered, using humanized keys as labels.

2. **Add bulk "Add to Group" action on posts index:** Add `add_posts_to_group/3` for bulk insert with `on_conflict: :nothing`, `list_groups/1` for admin dropdown, bulk action button with group dropdown, and dynamic group filter options replacing the static TODO comment.

## Why

1. Custom fields data was stored in the database but invisible in the admin UI when no field definitions were configured — making it impossible to see user metadata.

2. Managing post-group assignments one at a time was tedious. Bulk assignment and dynamic group filtering streamline the workflow.

## How

### Commit 1: Custom fields fallback
- Added `else` branch in `user_details.html.heex` to render custom fields from raw JSONB when field definitions aren't registered
- Uses `Phoenix.Naming.humanize/1` for key labels and existing `format_custom_field_value/3` for values

### Commit 2: Bulk add to group
- `Posts.add_posts_to_group/3`: transactional bulk insert with `on_conflict: :nothing`, increments group `post_count` by actual inserted count
- `Posts.list_groups/1`: simple query ordered by name
- `Posts` LiveView: `load_groups/1` on mount, `bulk_add_to_group` event handler
- Template: dropdown button in bulk action bar, dynamic group filter options
