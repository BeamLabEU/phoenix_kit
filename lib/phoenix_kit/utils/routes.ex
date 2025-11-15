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
        :none -> "#{base_path}#{url_path}"
        "en" -> "#{base_path}#{url_path}"
        locale_value -> "#{base_path}/#{locale_value}#{url_path}"
      end
    else
      raise """
      Url path must start with "/".
      """
    end
  end

  defp determine_locale do
    Process.get(:phoenix_kit_current_locale) ||
      Gettext.get_locale(PhoenixKitWeb.Gettext) ||
      "en"
  end

  @doc """
  Returns a locale-aware path using locale from assigns.

  This function is specifically designed for use in component templates
  where the locale needs to be passed explicitly via assigns.
  """
  def locale_aware_path(assigns, url_path) do
    locale = assigns[:current_locale] || "en"
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
