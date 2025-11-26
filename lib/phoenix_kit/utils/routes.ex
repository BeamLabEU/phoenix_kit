defmodule PhoenixKit.Utils.Routes do
  @moduledoc """
  Utility functions for working with PhoenixKit routes and URLs.

  This module provides helpers for constructing URLs with the correct
  PhoenixKit prefix configured in the application.
  """

  # NOTE: Locale override logic below exists for the temporary blogging component system integration.
  # Switch to the upcoming media/storage helpers once they land.
  def path(url_path, opts \\ []) do
    if String.starts_with?(url_path, "/") do
      url_prefix = PhoenixKit.Config.get_url_prefix()
      base_path = if url_prefix === "/", do: "", else: url_prefix

      locale =
        case Keyword.fetch(opts, :locale) do
          {:ok, :none} -> :none
          {:ok, nil} -> determine_locale()
          {:ok, locale_value} -> locale_value
          :error -> determine_locale()
        end

      case locale do
        :none ->
          "#{base_path}#{url_path}"

        locale_value ->
          if default_locale?(locale_value) do
            "#{base_path}#{url_path}"
          else
            "#{base_path}/#{locale_value}#{url_path}"
          end
      end
    else
      raise """
      Url path must start with "/".
      """
    end
  end

  defp determine_locale do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Check if we have base code in process dictionary (preferred)
    case Process.get(:phoenix_kit_current_locale_base) do
      nil ->
        # Fall back to extracting base from full dialect
        full_dialect =
          Process.get(:phoenix_kit_current_locale) ||
            Gettext.get_locale(PhoenixKitWeb.Gettext) ||
            "en-US"

        DialectMapper.extract_base(full_dialect)

      base_code ->
        base_code
    end
  end

  # Check if the given locale is the default (first in admin_languages list)
  # Default locale doesn't need a prefix in URLs for cleaner URLs
  defp default_locale?(locale) do
    default = get_default_admin_language()
    locale == default
  end

  defp get_default_admin_language do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # During mix tasks (like phoenix_kit.install), the database may not have
    # the settings table yet. We detect this by checking if we're in a mix task
    # context and fall back to "en" to avoid database errors.
    if mix_task_context?() do
      "en"
    else
      case PhoenixKit.Settings.get_setting("admin_languages") do
        nil ->
          # No setting exists, default is "en"
          "en"

        json when is_binary(json) ->
          case Jason.decode(json) do
            # Extract base code from full dialect (e.g., "en-US" -> "en")
            {:ok, [first | _]} -> DialectMapper.extract_base(first)
            _ -> "en"
          end
      end
    end
  end

  # Detect if we're running in a mix task context where the database
  # may not be fully set up yet
  defp mix_task_context? do
    # Check if Mix is loaded and we're not in a running application context
    # The settings cache being unavailable is a reliable indicator
    case Process.get(:phoenix_kit_config_status) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Returns a locale-aware path using locale from assigns.

  This function is specifically designed for use in component templates
  where the locale needs to be passed explicitly via assigns.

  Prefers base locale code for URL generation (current_locale_base),
  falls back to extracting base from full dialect code (current_locale).
  """
  def locale_aware_path(assigns, url_path) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Prefer base code, fall back to extracting from full dialect
    locale =
      assigns[:current_locale_base] ||
        DialectMapper.extract_base(assigns[:current_locale] || "en-US")

    path(url_path, locale: locale)
  end

  @doc """
  Returns a full url with preconfigured prefix.

  This function first checks for a configured site URL in Settings,
  then automatically detects the correct URL from the running Phoenix
  application endpoint when possible, falling back to static configuration.
  This ensures that magic links and other email links work correctly in both
  development and production environments, with full control over the base URL
  through the Settings admin panel.
  """
  def url(url_path) do
    base_url = get_base_url_for_emails()
    full_path = path(url_path)

    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{full_path}"
  end

  # Gets the base URL for email links.
  #
  # Priority:
  # 1. site_url setting from Settings (if configured)
  # 2. Dynamic URL from Phoenix endpoint
  # 3. Static configuration fallback
  #
  # This allows administrators to override the email link URLs through
  # the Settings panel, which is especially useful in production.
  defp get_base_url_for_emails do
    case PhoenixKit.Settings.get_setting("site_url", "") do
      "" ->
        PhoenixKit.Config.get_dynamic_base_url()

      site_url when is_binary(site_url) ->
        site_url
    end
  end
end
