defmodule PhoenixKitWeb.Live.Modules.Posts.Settings do
  @moduledoc """
  LiveView for posts module configuration and settings management.

  This module provides a comprehensive interface for managing all aspects
  of the PhoenixKit posts system, including:

  - **Content Limits**: Configure max media, title length, subtitle, content, mentions, tags
  - **Module Configuration**: Enable/disable module, set pagination, default status
  - **Feature Toggles**: Control comments, likes, scheduling, groups, reposts, SEO
  - **Moderation**: Configure post approval and comment moderation

  ## Route

  This LiveView is mounted at `{prefix}/admin/posts/settings` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Features

  - Real-time settings updates with immediate effect
  - Input validation with user-friendly error messages
  - Preview of limits and examples
  - Organized by category for easy navigation

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings

  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_project_title()

    # Load all posts settings
    socket =
      socket
      |> assign(:page_title, "Posts Settings")
      |> assign(:project_title, project_title)
      |> assign(:saving, false)
      |> load_settings()

    {:ok, socket}
  end

  def handle_event("save", params, socket) do
    socket = assign(socket, :saving, true)

    # Extract settings from params
    settings = Map.get(params, "settings", %{})

    # Update all settings
    results =
      Enum.map(settings, fn {key, value} ->
        Settings.update_setting(key, value)
      end)

    # Check if all updates succeeded
    socket =
      if Enum.all?(results, fn
           {:ok, _} -> true
           _ -> false
         end) do
        socket
        |> put_flash(:info, "Settings saved successfully")
        |> load_settings()
      else
        put_flash(socket, :error, "Failed to save some settings")
      end

    {:noreply, assign(socket, :saving, false)}
  end

  def handle_event("reset_defaults", _params, socket) do
    # Reset all settings to defaults
    defaults = %{
      # Content Limits
      "posts_max_media" => "10",
      "posts_max_title_length" => "255",
      "posts_max_subtitle_length" => "500",
      "posts_max_content_length" => "50000",
      "posts_max_mentions" => "10",
      "posts_max_tags" => "20",
      # Module Configuration
      "posts_enabled" => "true",
      "posts_per_page" => "20",
      "posts_default_status" => "draft",
      # Feature Toggles
      "posts_comments_enabled" => "true",
      "posts_likes_enabled" => "true",
      "posts_allow_scheduling" => "true",
      "posts_allow_groups" => "true",
      "posts_allow_reposts" => "true",
      "posts_seo_auto_slug" => "true",
      "posts_show_view_count" => "true",
      # Moderation
      "posts_require_approval" => "false",
      "posts_comment_moderation" => "false"
    }

    Enum.each(defaults, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Settings reset to defaults")
     |> load_settings()}
  end

  defp load_settings(socket) do
    socket
    # Content Limits
    |> assign(:posts_max_media, Settings.get_setting("posts_max_media", "10"))
    |> assign(:posts_max_title_length, Settings.get_setting("posts_max_title_length", "255"))
    |> assign(
      :posts_max_subtitle_length,
      Settings.get_setting("posts_max_subtitle_length", "500")
    )
    |> assign(
      :posts_max_content_length,
      Settings.get_setting("posts_max_content_length", "50000")
    )
    |> assign(:posts_max_mentions, Settings.get_setting("posts_max_mentions", "10"))
    |> assign(:posts_max_tags, Settings.get_setting("posts_max_tags", "20"))
    # Module Configuration
    |> assign(:posts_enabled, Settings.get_setting("posts_enabled", "true"))
    |> assign(:posts_per_page, Settings.get_setting("posts_per_page", "20"))
    |> assign(:posts_default_status, Settings.get_setting("posts_default_status", "draft"))
    # Feature Toggles
    |> assign(
      :posts_comments_enabled,
      Settings.get_setting("posts_comments_enabled", "true")
    )
    |> assign(:posts_likes_enabled, Settings.get_setting("posts_likes_enabled", "true"))
    |> assign(
      :posts_allow_scheduling,
      Settings.get_setting("posts_allow_scheduling", "true")
    )
    |> assign(:posts_allow_groups, Settings.get_setting("posts_allow_groups", "true"))
    |> assign(:posts_allow_reposts, Settings.get_setting("posts_allow_reposts", "true"))
    |> assign(:posts_seo_auto_slug, Settings.get_setting("posts_seo_auto_slug", "true"))
    |> assign(:posts_show_view_count, Settings.get_setting("posts_show_view_count", "true"))
    # Moderation
    |> assign(:posts_require_approval, Settings.get_setting("posts_require_approval", "false"))
    |> assign(
      :posts_comment_moderation,
      Settings.get_setting("posts_comment_moderation", "false")
    )
  end
end
