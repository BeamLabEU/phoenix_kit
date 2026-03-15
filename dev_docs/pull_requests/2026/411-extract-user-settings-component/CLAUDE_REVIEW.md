# PR #411 Review: Extract UserSettings into reusable LiveComponent

**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/411
**Author**: alexdont
**Date**: 2026-03-14
**Reviewer**: Claude

## Summary

Extracts all user settings logic (profile, email, password, OAuth, avatar upload) from `PhoenixKitWeb.Live.Dashboard.Settings` into a standalone `PhoenixKitWeb.Live.Components.UserSettings` LiveComponent. The parent LiveView becomes a thin wrapper that delegates to the component. Parent apps can now embed user settings anywhere with a single `live_component` call.

## Verdict: Approve with minor suggestions

Clean extraction. The component API is well-designed with sensible defaults and good configurability. No functional issues found.

---

## Issues Found

### 1. Verbose debug logging left in production code (Low)

**File**: `lib/phoenix_kit_web/live/components/user_settings.ex:52-57, 430-435, 593-597`

Multiple `Logger.info` calls for avatar upload flow that look like development debugging:

```elixir
Logger.info("check_avatar_uploads_complete: entries=#{length(entries)}, done?=...")
Logger.info("Still uploading avatar, checking again...")
Logger.info("avatar validate event: entries=#{length(entries)}")
Logger.info("Uploaded avatars: #{inspect(uploaded_avatars)}")
Logger.info("Avatar file UUIDs: #{inspect(avatar_file_uuids)}")
Logger.info("First avatar file UUID: #{inspect(avatar_file_uuid)}")
```

These are noisy at `info` level. Either downgrade to `debug` or remove entirely — the meaningful events (file stored, UUID saved, errors) are already logged separately.

### 2. Redundant nil check (Nit)

**File**: `lib/phoenix_kit_web/live/components/user_settings.ex:600`

```elixir
if avatar_file_uuid && avatar_file_uuid != nil do
```

`avatar_file_uuid && avatar_file_uuid != nil` is redundant — the `&&` already handles `nil`. Just `if avatar_file_uuid do` suffices.

### 3. `email_success_message` / `email_error_message` won't propagate on re-render (Low)

**File**: `lib/phoenix_kit_web/live/components/user_settings.ex:90-91`

```elixir
|> assign_new(:email_success_message, fn -> assigns[:email_success_message] end)
|> assign_new(:email_error_message, fn -> assigns[:email_error_message] end)
```

`assign_new` only sets the value if the key doesn't already exist. After the first `update/2` call, these assigns will exist (as `nil`), so subsequent updates from the parent (e.g., after email confirmation token handling in `mount/3`) won't propagate. The parent sets `email_success_message` and then `push_navigate`s, which triggers a fresh mount — so this works in the current flow. But if the parent ever sends these assigns without a navigation, they'll be silently ignored.

**Suggestion**: Use a conditional assign pattern:

```elixir
|> then(fn socket ->
  if Map.has_key?(assigns, :email_success_message),
    do: assign(socket, :email_success_message, assigns.email_success_message),
    else: assign_new(socket, :email_success_message, fn -> nil end)
end)
```

### 4. Facebook missing from `get_available_oauth_providers` (Nit)

**File**: `lib/phoenix_kit_web/live/components/user_settings.ex:524`

```elixir
all_providers = ["google", "apple", "github"]
```

Facebook is missing from the available providers list even though the OAuth settings page (PR #410) supports it. If Facebook OAuth is enabled, users won't see the connect button.

---

## What's Done Well

- **Clean component API** — `user`, `sections`, `email_confirm_url_fn`, `return_to` with sensible defaults. Documentation is thorough.
- **Parent notification pattern** — `{:phoenix_kit_user_updated, updated_user}` is the right way for LiveComponents to communicate state changes upward.
- **`maybe_allow_upload`** — Correctly guards against re-registering the upload on subsequent `update/2` calls.
- **Thin parent LiveView** — The dashboard settings page is now just 72 lines, focused on routing/mounting concerns.
- **`@default_sections`** — Allows parent apps to cherry-pick which settings sections to show.
