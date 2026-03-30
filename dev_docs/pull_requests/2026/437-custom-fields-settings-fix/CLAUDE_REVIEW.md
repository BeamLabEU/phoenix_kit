# Claude Review — PR #437

**Verdict:** Approve with follow-up improvements applied

## What's Good

1. **Dead code removal** — The `handle_event("validate", %{"_target" => ["avatar"]}, ...)` handler was unreachable because the form fires `validate_profile`, not `validate`. Moving avatar detection into the correct handler is a solid fix.

2. **Custom fields merge fix** — The old logic only preserved `avatar_file_uuid` during profile updates, silently dropping all other custom fields. The new `Map.merge(existing_custom_fields, custom_fields)` approach correctly layers form data on top of persisted data.

3. **Auto-registration with safe defaults** — `user_accessible: false` means auto-created definitions don't accidentally expose internal fields to end users.

4. **Type inference** — Pragmatic approach with sensible ordering (boolean guard before string checks, UUID before URL/email).

## Issues Found & Fixed

### Fixed: Domain logic misplaced in Auth module

`ensure_field_definitions_exist/1` and `infer_field_type/1` are custom field domain logic but lived in `Auth`. Moved both to `CustomFields` as public functions (`ensure_definitions_exist/1`, `infer_field_type/1`). Auth now delegates with a single call to `CustomFields.ensure_definitions_exist/1`.

### Fixed: Duplicate UUID regex

The UUID regex appeared inline in 3 places. Extracted to `@uuid_regex` module attribute in `CustomFields`, used by both `validate_type/2` and `infer_field_type/1`.

### Fixed: Silent failure on auto-registration

`Enum.each` discarded `add_field_definition/1` return values, silently swallowing errors (e.g., duplicate key race conditions). Now pattern-matches on the result and logs warnings via `Logger.warning/1`.

### Fixed: Duplicated merge logic in update_profile

The `update_profile` handler had inline merge logic that duplicated what `merge_custom_fields/2` does but with existing-field preservation. Extracted to `merge_custom_fields_for_save/3` — clear name, clear purpose, testable.

### Fixed: Position calculation clarity

Replaced the nested `case` + `Enum.max_by` + `|| 0` chain with a cleaner pipeline: `Enum.map` + `Enum.max/2` with default + `Kernel.+(1)`.

## Remaining Observations (not fixed)

### Low: Type inference is one-shot

`infer_field_type/1` runs on the value at the time of first save. If the first value for a key is `nil` or an empty string, it defaults to `"text"` and that type is locked forever. Acceptable given the admin-only default (admin can manually change the type).

### Low: No integer vs float distinction

`infer_field_type(value) when is_number(value)` maps both integers and floats to `"number"`. This matches HTML `<input type="number">` behavior, so it's fine.

## Testing Notes

- Verify avatar upload still works after moving the detection code
- Test saving a user with custom fields that have no definitions — should auto-create definitions
- Test that existing custom fields are preserved when editing profile (not just avatar_file_uuid)
- Test uuid field renders as readonly in user form
