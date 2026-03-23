# PR #436 Review: Updated the users_settings live_component

**Author:** Alex (alexdont)
**Status:** Merged → `dev` on 2026-03-20
**Files changed:** 2 (+338 / -497, net -159 lines)

---

## Summary

Two unrelated changes bundled together:

1. **UserSettings UI redesign** (`user_settings.ex`) — Consolidated the multi-card layout (Profile, Email, Password, OAuth) into a single card. Email/Password forms are now hidden behind toggle buttons. Profile section redesigned with a larger avatar and responsive mobile layout. Custom fields bug fix for form param nesting.

2. **Dialyzer suppression** (`connections_live.ex`) — Added `@dialyzer {:nowarn_function, ...}` directives to suppress false-positive MapSet opaqueness warnings on recursive functions.

---

## What's Good

- **Net reduction of ~160 lines** while keeping all functionality — the single-card layout is cleaner
- **Toggle pattern for Email/Password** — good UX, reduces visual clutter for settings users rarely change
- **Custom fields bug fix** — correctly reads from `profile_form[user][custom_fields]` instead of `params["custom_fields"]`, fixing a real data path mismatch
- **Responsive layout** — proper `lg:` breakpoint handling for mobile
- **Dialyzer directives** are appropriate — these are known false positives with MapSet opaque type in recursive calls

---

## Issues Found & Fixed

All issues below were identified in review and fixed in a follow-up commit.

### High Priority (Fixed)

1. **Removed features restored:**
   - **Timezone selector** — the entire timezone section (timezone select, mismatch warning, browser detection) was missing. Restored.
   - **Apple provider icon** — the `"apple"` case was removed from the OAuth provider icon match. Restored with `hero-device-phone-mobile`.
   - **OAuth-only password warning** — the alert telling OAuth-only users to set a backup password was removed. Restored.
   - **Provider email display** — connected providers were no longer showing the provider email. Restored `provider_email || current_email`.

2. **Custom fields `select` used index-based values** — The new select stored the *index* of the selected option instead of the actual value, breaking existing saved data. Fixed by switching back to `<.select>` component with proper `{label, value}` tuples.

3. **Custom field types reduced** — Only `select` and fallback `text` were handled. Restored all types: `textarea`, `number`, `email`, `url`, `date`, and `select` with their proper input components.

### Medium Priority (Fixed)

4. **Duplicated custom_fields extraction logic** — Extracted `extract_custom_fields/1` and `merge_custom_fields/3` private helpers to DRY the repeated `get_in(params, ["profile_form", "user", "custom_fields"])` pattern.

5. **Hidden form ID collision risk** — Restored unique `id` attributes on hidden email input (`#{@id}-hidden-user-email`), email password field (`#{@id}-current-password-for-email`), and password current-password field (`#{@id}-current-password-for-password`).

6. **`shadow-xl` → `shadow-sm`** — Reverted to match the rest of the app's card styling.

### Low Priority (Fixed)

7. **Divider placement** — Removed the misplaced divider from inside the username field container. Custom fields now have a proper "Additional Information" divider heading, only shown when custom fields exist.

8. **`required` attribute restored** — All custom field inputs now pass `required={field["required"]}`.

### Additional Fixes

9. **Profile/avatar success and error messages** — Were missing from the template. Restored `@profile_success_message`, `@last_uploaded_avatar_uuid` success alert, and `@avatar_error_message`.

10. **Disconnect confirmation dialog** — Restored the descriptive original message instead of the terse "Disconnect this account?".

---

## Verdict

The UI consolidation is a nice simplification, and the custom fields param path fix is a genuine bug fix. The issues above (removed features, data compatibility break, reduced field types) have all been fixed in the follow-up commit.
