# PR #410 Review: Added login page customisability

**PR**: https://github.com/BeamLabEU/phoenix_kit/pull/410
**Author**: alexdont
**Date**: 2026-03-14
**Reviewer**: Claude

## Summary

Moves auth branding (logo, background image, background color) and authentication method settings (magic links, OAuth) from the General Settings page to a dedicated Authorization Settings sub-page. Introduces an `AuthPageWrapper` component that resolves file UUIDs to signed URLs at render time. Adds responsive mobile background image support. Also refactors comments table markup.

## Verdict: Approve with required fixes

Good feature split — auth branding deserves its own page. The `AuthPageWrapper` component is clean. However, there's a CSS injection vulnerability and a fragile hidden-fields architecture that should be addressed.

---

## Issues Found

### 1. CSS injection via `auth_background_color` (High)

**File**: `lib/phoenix_kit_web/components/auth_page_wrapper.ex:71-89`

```elixir
defp bg_style_tag(assigns) do
  desktop = bg_css(assigns.auth_bg_image, assigns.auth_bg_color)
  mobile = if assigns.auth_bg_image_mobile != "" do
    "@media (max-width: 768px) { .auth-bg { background-image: url('#{assigns.auth_bg_image_mobile}'); } }"
  else
    ""
  end
  "<style>.auth-bg { #{desktop} background-size: cover; background-position: center; } #{mobile}</style>"
end

defp bg_css("", color), do: "background: #{color};"
```

The `auth_bg_color` value is admin-controlled text injected directly into a `<style>` tag via `raw/1`. An admin (or anyone who gains admin access) can set the color to:

```
red; } </style><script>alert('xss')</script><style> .x {
```

This closes the style tag and injects arbitrary HTML/JS. Same applies to the `url('...')` values if URLs were user-provided (they're signed URLs here so lower risk).

**Fix**: Sanitize the color value — strip `<`, `>`, `{`, `}`, `;` beyond the value itself, or better yet validate it's a valid CSS color/gradient:

```elixir
defp sanitize_css_value(value) do
  # Strip characters that could break out of CSS context
  String.replace(value, ~r/[<>"']/, "")
end
```

Or use a Content Security Policy + a `style` attribute on the div instead of injecting a `<style>` tag.

### 2. Hidden fields architecture is fragile (Medium)

**File**: `lib/phoenix_kit_web/live/settings/authorization.html.heex:30-83`

The authorization page includes 12+ hidden fields to pass through settings from other pages (project_title, site_url, week_start_day, time_zone, date_format, time_format, allow_registration, etc.) because `Settings.update_settings/1` validates ALL settings via a single `SettingsForm` changeset.

**Problem**: If any new required field is added to `SettingsForm.changeset/2` (e.g., a new general setting), the authorization page will fail validation because it won't include the new hidden field. This coupling is invisible and will cause hard-to-debug failures.

**Suggestion**: Refactor `Settings.update_settings/1` to accept partial updates — only validate fields that are present in the params. Or create a dedicated `update_auth_settings/1` function that only validates auth-related fields. This is the right long-term fix since more sub-pages will likely be added.

### 3. `String.to_existing_atom` on user input can crash LiveView (Medium)

**File**: `lib/phoenix_kit_web/live/settings/authorization.ex:110`

```elixir
def handle_event("open_media_selector", %{"target" => target}, socket) do
  {:noreply,
   socket
   |> assign(:show_media_selector, true)
   |> assign(:media_selection_target, String.to_existing_atom(target))}
end
```

If `target` is anything other than `"logo"`, `"background"`, or `"background_mobile"`, this raises `ArgumentError` and crashes the LiveView process. Same issue on line 90 with `String.to_existing_atom(provider)`.

**Fix**: Use a map lookup or explicit pattern matching:

```elixir
@valid_media_targets %{"logo" => :logo, "background" => :background, "background_mobile" => :background_mobile}

def handle_event("open_media_selector", %{"target" => target}, socket) do
  case Map.fetch(@valid_media_targets, target) do
    {:ok, target_atom} ->
      {:noreply,
       socket
       |> assign(:show_media_selector, true)
       |> assign(:media_selection_target, target_atom)}
    :error ->
      {:noreply, socket}
  end
end
```

### 4. `clear_branding_image` has no catch-all (Low)

**File**: `lib/phoenix_kit_web/live/settings/authorization.ex:113-123`

```elixir
def handle_event("clear_branding_image", %{"target" => target}, socket) do
  key =
    case target do
      "logo" -> "auth_logo_file_uuid"
      "background" -> "auth_background_image_file_uuid"
      "background_mobile" -> "auth_background_image_mobile_file_uuid"
    end
  ...
```

No catch-all clause — unknown target raises `CaseClauseError` and crashes LiveView.

### 5. `signed_preview_url` should be private (Nit)

**File**: `lib/phoenix_kit_web/live/settings/authorization.ex:167`

```elixir
def signed_preview_url(file_uuid, variant) do
```

This is only used within the template. Should be `defp`.

---

## What's Done Well

- **`AuthPageWrapper` as a shared component** — All 9 auth pages now use a consistent wrapper with centralized branding logic. Good DRY refactoring.
- **`assign_new` for settings resolution** — Avoids re-resolving UUIDs to URLs on every render.
- **Media selector integration** — Replacing raw URL inputs with file picker from media library is a much better UX.
- **Responsive background** — Desktop/mobile image split with CSS media query is the right approach.
- **Optional settings list** — Branding UUIDs correctly added to `@optional_settings` so empty defaults are allowed.

## Architecture Note

The comments table refactoring (index.html.heex) in this PR is unrelated to auth page customization. Ideally these would be separate commits/PRs to keep changes focused and reviewable.
