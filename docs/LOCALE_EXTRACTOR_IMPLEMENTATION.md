# LocaleExtractor Implementation

## Problem Summary

Two related routing issues in PhoenixKit:

1. **Admin routes getting locale prefixes**: Publishing module's `Routes.path("/admin/...", locale: @current_locale)` adds locale to admin URLs when the current locale differs from the default (e.g., `en-US` vs `en`). This causes navigation to cross live_session boundaries, breaking layouts.

2. **Blog catch-all routes capturing everything**: The pattern `/:language/:blog` matches any URL with a 2-letter language prefix, causing routes like `/es/shop`, `/fr/billing` to be routed to the Publishing controller instead of their intended modules.

## Solution: LocaleExtractor Plug

Extract and strip locale from URL path **before** route matching. This allows all routes to work with or without locale prefix, eliminating the need for duplicate route definitions.

### Key Design Decisions

1. **Plug Placement**: Must run in the Endpoint, before the Router, since pipeline plugs run AFTER route matching.

2. **Prefix Handling**: Only extract locale from paths within the PhoenixKit URL prefix scope.

3. **Admin Routes**: Never add locale prefix to admin paths in URL generation.

4. **Blog Routes**: Controller validates blog exists, returns 404 for unknown slugs.

---

## Architecture

### Request Flow (Before)

```
Request: /phoenix_kit/es/shop
    ↓
Router tries to match routes
    ↓
No match for /es/shop in Shop routes (no :locale version)
    ↓
Falls through to blog catch-all /:language/:blog
    ↓
Publishing controller receives request (WRONG!)
```

### Request Flow (After)

```
Request: /phoenix_kit/es/shop
    ↓
Endpoint runs LocaleExtractor plug
    ↓
Detects "es" is valid locale, strips from path
conn.path_info: ["phoenix_kit", "shop"]
conn.assigns[:current_locale_base] = "es"
    ↓
Router matches /phoenix_kit/shop → Shop module (CORRECT!)
```

---

## Implementation

### Phase 1: Create LocaleExtractor Plug

**File: `lib/phoenix_kit_web/plugs/locale_extractor.ex`**

```elixir
defmodule PhoenixKitWeb.Plugs.LocaleExtractor do
  @moduledoc """
  Extracts locale from URL path and normalizes the request path.

  Transforms: /prefix/es/shop → /prefix/shop (with locale in assigns)

  This allows ALL routes to work with or without locale prefix,
  eliminating the need for duplicate route definitions.

  ## Configuration

  The plug respects the configured PhoenixKit URL prefix and only
  processes paths within that scope.

  ## Usage

  Add to your Endpoint, before the Router:

      plug PhoenixKitWeb.Plugs.LocaleExtractor
      plug MyAppWeb.Router
  """

  import Plug.Conn

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper

  # Path segments that should never be treated as locale codes
  @reserved_segments ~w(admin api webhooks assets static files images fonts js css favicon)

  def init(opts), do: opts

  def call(conn, _opts) do
    # Only process if Languages module is enabled
    if languages_enabled?() do
      process_locale_extraction(conn)
    else
      assign_default_locale(conn)
    end
  end

  defp process_locale_extraction(conn) do
    url_prefix = get_url_prefix()
    prefix_segments = path_to_segments(url_prefix)

    case extract_locale_after_prefix(conn.path_info, prefix_segments) do
      {:ok, locale_base, new_path_info} ->
        conn
        |> assign(:current_locale_base, locale_base)
        |> assign(:current_locale, resolve_full_dialect(locale_base))
        |> assign(:locale_from_url, true)
        |> rewrite_path_info(new_path_info)

      :no_locale ->
        assign_default_locale(conn)

      :not_phoenix_kit_path ->
        # Not a PhoenixKit path, don't touch it
        conn
    end
  end

  # Extract locale from path after the PhoenixKit prefix
  defp extract_locale_after_prefix(path_info, prefix_segments) do
    case strip_prefix(path_info, prefix_segments) do
      {:ok, [potential_locale | rest]} ->
        if valid_extractable_locale?(potential_locale) do
          base = DialectMapper.extract_base(potential_locale)
          new_path = prefix_segments ++ rest
          {:ok, base, new_path}
        else
          :no_locale
        end

      {:ok, []} ->
        # Just the prefix, no locale
        :no_locale

      :no_match ->
        :not_phoenix_kit_path
    end
  end

  # Strip the PhoenixKit prefix from path_info
  defp strip_prefix(path_info, []) do
    # No prefix (prefix is "/")
    {:ok, path_info}
  end

  defp strip_prefix(path_info, prefix_segments) do
    if List.starts_with?(path_info, prefix_segments) do
      {:ok, Enum.drop(path_info, length(prefix_segments))}
    else
      :no_match
    end
  end

  defp valid_extractable_locale?(segment) do
    cond do
      # Reserved segments are never locales
      segment in @reserved_segments ->
        false

      # Check if it's a valid enabled locale
      valid_enabled_locale?(segment) ->
        true

      true ->
        false
    end
  end

  defp valid_enabled_locale?(segment) do
    enabled_codes = get_enabled_language_codes()
    base_codes = Enum.map(enabled_codes, &DialectMapper.extract_base/1)

    segment in enabled_codes or segment in base_codes
  end

  defp resolve_full_dialect(base_code) do
    get_enabled_language_codes()
    |> Enum.find(fn code -> DialectMapper.extract_base(code) == base_code end)
    || base_code
  end

  defp assign_default_locale(conn) do
    default = get_default_language()
    base = DialectMapper.extract_base(default)

    conn
    |> assign(:current_locale_base, base)
    |> assign(:current_locale, default)
    |> assign(:locale_from_url, false)
  end

  defp rewrite_path_info(conn, new_path_info) do
    %{conn | path_info: new_path_info}
  end

  # Helper functions with fallbacks for when modules aren't loaded

  defp languages_enabled? do
    Code.ensure_loaded?(Languages) and Languages.enabled?()
  rescue
    _ -> false
  end

  defp get_enabled_language_codes do
    if Code.ensure_loaded?(Languages) do
      Languages.get_enabled_language_codes()
    else
      ["en"]
    end
  rescue
    _ -> ["en"]
  end

  defp get_default_language do
    if Code.ensure_loaded?(Languages) do
      case Languages.get_enabled_language_codes() do
        [first | _] -> first
        _ -> "en"
      end
    else
      "en"
    end
  rescue
    _ -> "en"
  end

  defp get_url_prefix do
    Config.get_url_prefix()
  rescue
    _ -> "/phoenix_kit"
  end

  defp path_to_segments("/"), do: []
  defp path_to_segments("/" <> path), do: String.split(path, "/", trim: true)
  defp path_to_segments(path), do: String.split(path, "/", trim: true)
end
```

### Phase 2: Integration Instructions

Users need to add the plug to their Endpoint. Document in README:

```elixir
# In lib/my_app_web/endpoint.ex

defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # ... other plugs ...

  # Add LocaleExtractor BEFORE the Router
  plug PhoenixKitWeb.Plugs.LocaleExtractor

  plug MyAppWeb.Router
end
```

### Phase 3: Update Routes.path/2

**File: `lib/phoenix_kit/utils/routes.ex`**

Update to never add locale prefix to admin paths:

```elixir
def path(url_path, opts \\ []) do
  if String.starts_with?(url_path, "/") do
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_path = if url_prefix === "/", do: "", else: url_prefix

    # Admin paths NEVER get locale prefix
    if admin_path?(url_path) do
      "#{base_path}#{url_path}"
    else
      locale = resolve_locale_option(opts)
      build_path_with_locale(base_path, url_path, locale)
    end
  else
    raise "URL path must start with /"
  end
end

defp admin_path?(path), do: String.starts_with?(path, "/admin")

defp build_path_with_locale(base_path, url_path, locale) do
  case locale do
    :none -> "#{base_path}#{url_path}"
    nil -> "#{base_path}#{url_path}"
    locale_value ->
      if default_locale?(locale_value) do
        "#{base_path}#{url_path}"
      else
        "#{base_path}/#{locale_value}#{url_path}"
      end
  end
end
```

### Phase 4: Remove Duplicate Locale Routes

Once LocaleExtractor is in place, remove duplicate `/:locale` scoped routes from `integration.ex`:

- `:phoenix_kit_publishing_localized` live_session
- `:phoenix_kit_tickets_admin_localized` live_session
- `:phoenix_kit_tickets_user_localized` live_session
- `:phoenix_kit_referral_codes_localized` live_session
- Localized POST routes for auth
- Shop localized routes (already added, can be removed)

Keep only non-localized versions - they now work with any locale prefix.

### Phase 5: Update Blog Route Handling

**File: `lib/modules/publishing/web/controller.ex`**

Validate blog exists before rendering:

```elixir
def show(conn, %{"blog" => blog_slug} = params) do
  case Publishing.get_group(blog_slug) do
    {:ok, _blog} ->
      render_blog_content(conn, blog_slug, params)

    {:error, :not_found} ->
      conn
      |> put_status(:not_found)
      |> put_view(PhoenixKitWeb.ErrorHTML)
      |> render("404.html")
  end
end
```

### Phase 6: Remove locale: from Publishing Admin Paths

Remove `locale:` option from all admin paths in Publishing module:

**Files to update:**
- `lib/modules/publishing/web/index.ex`
- `lib/modules/publishing/web/index.html.heex`
- `lib/modules/publishing/web/listing.ex`
- `lib/modules/publishing/web/listing.html.heex`
- `lib/modules/publishing/web/settings.ex`
- `lib/modules/publishing/web/settings.html.heex`
- `lib/modules/publishing/web/new.ex`
- `lib/modules/publishing/web/new.html.heex`
- `lib/modules/publishing/web/edit.ex`
- `lib/modules/publishing/web/edit.html.heex`
- `lib/modules/publishing/web/editor.html.heex`

**Pattern:**
```elixir
# Before
Routes.path("/admin/publishing/#{slug}", locale: @current_locale)

# After
Routes.path("/admin/publishing/#{slug}")
```

---

## Testing Checklist

After implementation, verify:

- [ ] `/phoenix_kit/admin/publishing` works (no locale in URL)
- [ ] `/phoenix_kit/es/shop` routes to Shop module (not Publishing)
- [ ] `/phoenix_kit/es/admin/billing` routes to Billing (not Publishing)
- [ ] `/phoenix_kit/docs` routes to "docs" blog (if configured)
- [ ] `/phoenix_kit/es/docs` routes to "docs" blog with Spanish locale
- [ ] `/phoenix_kit/nonexistent` returns 404 (not blog error)
- [ ] Admin navigation links don't include locale prefixes
- [ ] Public content links include locale for non-default languages
- [ ] Language switcher works correctly

---

## Backward Compatibility

- Existing bookmarked URLs with locale prefixes continue to work
- Default locale URLs remain clean (no prefix)
- Admin routes remain clean (no prefix)
- No breaking changes to existing functionality

---

## Migration Notes

### For Existing Installations

1. Add `plug PhoenixKitWeb.Plugs.LocaleExtractor` to Endpoint
2. Duplicate locale routes can be removed (optional, they still work)
3. No database migrations required

### For New Installations

The installer should automatically add the plug to the Endpoint.

---

## Related Files

- `lib/phoenix_kit_web/plugs/locale_extractor.ex` (new)
- `lib/phoenix_kit/utils/routes.ex` (modified)
- `lib/phoenix_kit_web/integration.ex` (simplified)
- `lib/modules/publishing/web/*.ex` (remove locale: from admin paths)
- `docs/LANGUAGE_ROUTING_ISSUE.md` (original problem analysis)

---

**Author:** PhoenixKit Team
**Date:** 2026-01-23
**Status:** Partial - Immediate fix implemented, LocaleExtractor deferred

## Implementation Summary

### Completed (Immediate Fix)

1. **Routes.path/2 Update** - ✅ Admin paths automatically skip locale prefix via `admin_path?/1` check
2. **Publishing Admin Paths** - ✅ Removed `locale:` from 54+ instances across all Publishing web files

This fixes the immediate bug where admin routes were getting locale prefixes (e.g., `/phoenix_kit/en-US/admin/publishing`), which crossed live_session boundaries and broke layouts.

### Deferred (LocaleExtractor Plug)

The LocaleExtractor plug approach has been **deferred** for the following reasons:

1. **Requires user code changes** - The plug must run in the Endpoint BEFORE the Router, which means users would need to modify their `endpoint.ex` file. This violates PhoenixKit's goal of working out-of-the-box with zero user changes.

2. **Breaks downstream locale handling** - If wired in, the plug strips the locale from `path_info`, but downstream code (`phoenix_kit_locale_validation`, LiveView mounts) still reads `params["locale"]` which would be `nil`.

3. **Not strictly necessary** - The existing duplicate route approach (`/shop` and `/:locale/shop`) works fine. Route ordering ensures specific module routes match before the blog catch-all.

**Future consideration:** If we implement installer changes that can automatically inject the plug into users' Endpoints, we can revisit this approach.

### Files Modified

- `lib/phoenix_kit/utils/routes.ex` (added admin_path? check)
- `lib/modules/publishing/web/index.ex`
- `lib/modules/publishing/web/index.html.heex`
- `lib/modules/publishing/web/settings.ex`
- `lib/modules/publishing/web/settings.html.heex`
- `lib/modules/publishing/web/new.ex`
- `lib/modules/publishing/web/new.html.heex`
- `lib/modules/publishing/web/edit.ex`
- `lib/modules/publishing/web/edit.html.heex`
- `lib/modules/publishing/web/listing.ex`
- `lib/modules/publishing/web/listing.html.heex`
- `lib/modules/publishing/web/editor.ex`
- `lib/modules/publishing/web/editor.html.heex`
- `lib/modules/publishing/web/preview.ex`
