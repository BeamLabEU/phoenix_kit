defmodule PhoenixKit.Modules.Publishing.Web.Controller do
  @moduledoc """
  Public post display controller.

  Handles public-facing routes for viewing published posts with multi-language support.

  URL patterns:
    /:language/:group_slug/:post_slug - Slug mode post
    /:language/:group_slug/:date/:time - Timestamp mode post
    /:language/:group_slug - Group listing

  ## Architecture

  This controller delegates to specialized submodules:
  - `Routing` - URL path parsing and segment building
  - `Language` - Language detection and resolution
  - `SlugResolution` - URL slug resolution and redirects
  - `PostFetching` - Post retrieval from cache/filesystem
  - `Listing` - Group listing rendering and pagination
  - `PostRendering` - Post rendering and version handling
  - `Translations` - Translation link building
  - `Fallback` - 404 handling and smart fallback chain
  """

  use PhoenixKitWeb, :controller
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Web.Controller.Fallback
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Modules.Publishing.Web.Controller.Routing
  alias PhoenixKit.Settings

  # ============================================================================
  # Main Entry Points
  # ============================================================================

  @doc """
  Displays a post, group listing, or all groups overview.

  Path parsing determines which action to take:
  - [] -> Invalid request (no group specified)
  - [group_slug] -> Group listing
  - [group_slug, post_slug] -> Slug mode post
  - [group_slug, date] -> Date-only timestamp (resolves to single post or first post)
  - [group_slug, date, time] -> Timestamp mode post
  """
  def show(conn, %{"language" => language_param} = params) do
    # Detect if 'language' param is actually a language code or a group slug
    # This allows the same route to work for both single and multi-language setups
    {language, adjusted_params} = Language.detect_language_or_group(language_param, params)

    conn = assign(conn, :current_language, language)
    set_gettext_locale(language)

    if Publishing.enabled?() and public_enabled?() do
      case Routing.build_segments(adjusted_params) do
        [] ->
          handle_not_found(conn, :invalid_path)

        segments ->
          handle_parsed_path(conn, Routing.parse_path(segments), language)
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # Fallback for routes without language parameter
  # This handles the non-localized route where :group might actually be a language code
  def show(conn, params) do
    if Publishing.enabled?() and public_enabled?() do
      # Check if the first segment (group) is actually a language with content
      case Language.detect_language_in_group_param(params) do
        {:language_detected, language, adjusted_params} ->
          # First segment was a language code with content - use localized logic
          conn = assign(conn, :current_language, language)
          set_gettext_locale(language)
          handle_localized_request(conn, language, adjusted_params)

        :not_a_language ->
          # First segment is a group slug - use default language
          language = Language.get_default_language()
          conn = assign(conn, :current_language, language)
          set_gettext_locale(language)
          handle_non_localized_request(conn, language, params)
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # ============================================================================
  # Request Handlers
  # ============================================================================

  # Handles request after language has been detected
  defp handle_localized_request(conn, language, params) do
    case Routing.build_segments(params) do
      [] ->
        handle_not_found(conn, :invalid_path)

      segments ->
        handle_parsed_path(conn, Routing.parse_path(segments), language)
    end
  end

  # Handles non-localized request with default language
  defp handle_non_localized_request(conn, language, params) do
    case Routing.build_segments(params) do
      [] ->
        handle_not_found(conn, :invalid_path)

      segments ->
        handle_parsed_path(conn, Routing.parse_path(segments), language)
    end
  end

  # Dispatches to appropriate handler based on parsed path
  defp handle_parsed_path(conn, parsed_path, language) do
    case parsed_path do
      {:listing, group_slug} ->
        handle_group_listing(conn, group_slug, language)

      {:slug_post, group_slug, post_slug} ->
        handle_post(conn, group_slug, {:slug, post_slug}, language)

      {:timestamp_post, group_slug, date, time} ->
        handle_post(conn, group_slug, {:timestamp, date, time}, language)

      {:date_only_post, group_slug, date} ->
        handle_date_only_url(conn, group_slug, date, language)

      {:versioned_post, group_slug, post_slug, version} ->
        handle_versioned_post(conn, group_slug, post_slug, version, language)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # ============================================================================
  # Group Listing Handler
  # ============================================================================

  defp handle_group_listing(conn, group_slug, language) do
    case Listing.render_group_listing(conn, group_slug, language, conn.params) do
      {:ok, assigns} ->
        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group, assigns.group)
        |> assign(:posts, assigns.posts)
        |> assign(:current_language, assigns.current_language)
        |> assign(:translations, assigns.translations)
        |> assign(:page, assigns.page)
        |> assign(:per_page, assigns.per_page)
        |> assign(:total_count, assigns.total_count)
        |> assign(:total_pages, assigns.total_pages)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> render(:index)

      {:redirect, url} ->
        redirect(conn, to: url)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # ============================================================================
  # Post Handlers
  # ============================================================================

  defp handle_post(conn, group_slug, identifier, language) do
    case PostRendering.render_post(conn, group_slug, identifier, language) do
      {:ok, assigns} ->
        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group_slug, assigns.group_slug)
        |> assign(:post, assigns.post)
        |> assign(:html_content, assigns.html_content)
        |> assign(:current_language, assigns.current_language)
        |> assign(:translations, assigns.translations)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:version_dropdown, assigns.version_dropdown)
        |> render(:show)

      {:redirect, url} ->
        redirect(conn, to: url)

      {:redirect_301, url} ->
        conn
        |> put_status(301)
        |> redirect(to: url)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  defp handle_versioned_post(conn, group_slug, post_slug, version, language) do
    case PostRendering.render_versioned_post(conn, group_slug, post_slug, version, language) do
      {:ok, assigns} ->
        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group_slug, assigns.group_slug)
        |> assign(:post, assigns.post)
        |> assign(:html_content, assigns.html_content)
        |> assign(:current_language, assigns.current_language)
        |> assign(:translations, assigns.translations)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:canonical_url, assigns.canonical_url)
        |> assign(:is_versioned_view, assigns.is_versioned_view)
        |> assign(:is_live_version, assigns.is_live_version)
        |> assign(:version, assigns.version)
        |> assign(:version_dropdown, assigns.version_dropdown)
        |> render(:show)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  defp handle_date_only_url(conn, group_slug, date, language) do
    case PostRendering.handle_date_only_url(conn, group_slug, date, language) do
      {:ok, assigns} ->
        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group_slug, assigns.group_slug)
        |> assign(:post, assigns.post)
        |> assign(:html_content, assigns.html_content)
        |> assign(:current_language, assigns.current_language)
        |> assign(:translations, assigns.translations)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:version_dropdown, assigns.version_dropdown)
        |> render(:show)

      {:redirect, url} ->
        redirect(conn, to: url)

      {:redirect_301, url} ->
        conn
        |> put_status(301)
        |> redirect(to: url)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  defp handle_not_found(conn, reason) do
    case Fallback.handle_not_found(conn, reason) do
      {:redirect_with_flash, path, message} ->
        conn
        |> put_flash(:info, message)
        |> redirect(to: path)

      {:render_404} ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PhoenixKitWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  # ============================================================================
  # Configuration Helpers
  # ============================================================================

  defp public_enabled? do
    # Check new key first, fallback to legacy
    case Settings.get_setting("publishing_public_enabled") do
      nil -> Settings.get_boolean_setting("blogging_public_enabled", true)
      "true" -> true
      "false" -> false
      _ -> true
    end
  end

  defp set_gettext_locale(language) do
    Gettext.put_locale(PhoenixKitWeb.Gettext, language)
  end
end
