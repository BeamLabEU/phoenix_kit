# PR #437 — Fix user settings saving and custom field definitions

**Author:** Alex (alexdont)
**Base:** dev
**Date:** 2026-03-20

## Summary

Fixes two related issues in the user settings system:

1. **User settings form was not saving correctly** — avatar upload detection was in a dead `validate` handler that never fired (the form uses `validate_profile`), and `update_profile` was only preserving `avatar_file_uuid` instead of merging all existing custom fields.

2. **Custom field definitions were not auto-created** — when `update_user_custom_fields/2` saved keys without corresponding field definitions, those fields were invisible in admin and user settings UIs. Now definitions are auto-registered with type inference.

3. **Added `uuid` type** to the custom fields system — validation, UI rendering (readonly monospace input), and type inference for UUID-shaped strings.

## Changes

| File | What changed |
|------|-------------|
| `user_settings.ex` | Moved avatar upload detection into `validate_profile`; removed dead `validate` handler; changed `update_profile` to merge form custom_fields on top of all existing fields |
| `auth.ex` | Added `ensure_field_definitions_exist/1` called before saving custom fields; added `infer_field_type/1` for boolean/number/uuid/url/email/text inference |
| `custom_fields.ex` | Added `"uuid"` to `@supported_types`; added `validate_type` clause for uuid format |
| `users.html.heex` | Added `uuid` to field type dropdown in admin |
| `user_form.html.heex` | Added readonly monospace input rendering for uuid fields |

## Key Design Decisions

- **Auto-registration defaults to admin-only** (`user_accessible: false`) — safe default, admin can enable user visibility later
- **Type inference is best-effort** — inspects the first value seen; once the definition exists, the type is locked
- **UUID field renders readonly** — UUIDs are system-assigned identifiers, not user-editable
