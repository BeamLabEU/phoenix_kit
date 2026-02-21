defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostRendering do
  @moduledoc """
  Post rendering functionality for the publishing controller.

  Handles rendering individual posts including:
  - Content rendering with caching
  - Versioned post display
  - Date-only URL handling
  - Version dropdown building
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostFetching
  alias PhoenixKit.Modules.Publishing.Web.Controller.SlugResolution
  alias PhoenixKit.Modules.Publishing.Web.Controller.Translations
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  # Suppress dialyzer false positive for defensive fallback pattern
  @dialyzer {:nowarn_function, render_post_content: 1}

  # ============================================================================
  # Main Rendering Functions
  # ============================================================================

  @doc """
  Renders a post after resolving URL slugs.
  """
  def render_post(conn, group_slug, identifier, language) do
    # For slug mode, resolve URL slug to internal slug first
    # This enables per-language URL slugs and 301 redirects for old slugs
    case SlugResolution.resolve_url_slug(group_slug, identifier, language) do
      {:redirect, redirect_url} ->
        # Old URL slug - 301 redirect to current URL
        {:redirect_301, redirect_url}

      {:ok, resolved_identifier} ->
        render_resolved_post(conn, group_slug, resolved_identifier, language)

      :passthrough ->
        render_resolved_post(conn, group_slug, identifier, language)
    end
  end

  @doc """
  Renders a post after identifier has been resolved.
  """
  def render_resolved_post(conn, group_slug, identifier, language) do
    case PostFetching.fetch_post(group_slug, identifier, language) do
      {:ok, post} ->
        # Check if published
        if post.metadata.status == "published" do
          # Check if we need to redirect to canonical URL
          # The canonical URL uses the display_code (base or full dialect depending on enabled languages)
          canonical_language = Language.get_canonical_url_language_for_post(post.language)

          if canonical_language != language do
            # Redirect to canonical URL
            canonical_url = PublishingHTML.build_post_url(group_slug, post, canonical_language)
            {:redirect, canonical_url}
          else
            # Render markdown (cached for published posts)
            html_content = render_post_content(post)

            # Build translation links
            translations =
              Translations.build_translation_links(group_slug, post, canonical_language)

            # Build breadcrumbs
            breadcrumbs = build_breadcrumbs(group_slug, post, canonical_language)

            # Build version dropdown data if allowed
            version_dropdown = build_version_dropdown(group_slug, post, canonical_language)

            {:ok,
             %{
               page_title: post.metadata.title,
               group_slug: group_slug,
               post: post,
               html_content: html_content,
               current_language: canonical_language,
               translations: translations,
               breadcrumbs: breadcrumbs,
               version_dropdown: version_dropdown
             }}
          end
        else
          log_404(conn, group_slug, identifier, language, :unpublished)
          {:error, :unpublished}
        end

      {:error, reason} ->
        log_404(conn, group_slug, identifier, language, reason)
        {:error, reason}
    end
  end

  @doc """
  Renders a specific version of a post (for version browsing feature).
  """
  def render_versioned_post(conn, group_slug, url_slug, version, language) do
    # Resolve URL slug to internal slug (handles per-language custom slugs)
    internal_slug = SlugResolution.resolve_url_slug_to_internal(group_slug, url_slug, language)

    # Check per-post version access setting (from the live version's metadata)
    # Each post controls its own version access - no global setting required
    if post_allows_version_access?(group_slug, internal_slug, language) do
      # Resolve language to actual file language (e.g., "en" -> "en-US")
      # This matches the behavior in PostFetching.fetch_post
      version_dir = Path.join([Storage.group_path(group_slug), internal_slug, "v#{version}"])
      available_languages = PostFetching.detect_available_languages_in_dir(version_dir)
      resolved_language = Language.resolve_language_for_post(language, available_languages)

      # Fetch the specific version with resolved language
      case Publishing.read_post(group_slug, internal_slug, resolved_language, version) do
        {:ok, post} ->
          # Check if version is published
          if post.metadata.status == "published" do
            # Get canonical language
            canonical_language = Language.get_canonical_url_language_for_post(post.language)

            # Render markdown (cached for published posts)
            html_content = render_post_content(post)

            # Build translation links (preserve version in URLs)
            translations =
              Translations.build_translation_links(group_slug, post, canonical_language,
                version: version
              )

            # Build breadcrumbs
            breadcrumbs = build_breadcrumbs(group_slug, post, canonical_language)

            # Build canonical URL (points to main post URL, not versioned URL)
            canonical_url = PublishingHTML.build_post_url(group_slug, post, canonical_language)

            # Build version dropdown data (also gives us the live version)
            version_dropdown = build_version_dropdown(group_slug, post, canonical_language)

            # Check if this is the live version by comparing to the published version
            # (is_live field was removed from metadata, now derived from status)
            {_allow_access, live_version} = get_cached_version_info(group_slug, post)
            is_live = version == live_version

            {:ok,
             %{
               page_title: post.metadata.title,
               group_slug: group_slug,
               post: post,
               html_content: html_content,
               current_language: canonical_language,
               translations: translations,
               breadcrumbs: breadcrumbs,
               canonical_url: canonical_url,
               is_versioned_view: true,
               is_live_version: is_live,
               version: version,
               version_dropdown: version_dropdown
             }}
          else
            log_404(conn, group_slug, {:slug, internal_slug, version}, language, :unpublished)
            {:error, :unpublished}
          end

        {:error, reason} ->
          log_404(conn, group_slug, {:slug, internal_slug, version}, language, reason)
          {:error, reason}
      end
    else
      {:error, :version_access_disabled}
    end
  end

  @doc """
  Handles date-only URLs (e.g., /group/2025-12-09).
  If only one post exists on that date, render it directly.
  If multiple posts exist, redirect to the first one with time in URL.
  """
  def handle_date_only_url(conn, group_slug, date, language) do
    case Listing.fetch_group(group_slug) do
      {:ok, _group} ->
        times = Storage.list_times_on_date(group_slug, date)

        case times do
          [] ->
            # No posts on this date
            {:error, :post_not_found}

          [single_time] ->
            # Only one post - render it directly
            render_post(conn, group_slug, {:timestamp, date, single_time}, language)

          [first_time | _rest] ->
            # Multiple posts - redirect to first one with time in URL
            canonical_language = Language.get_canonical_url_language(language)
            redirect_url = build_timestamp_url(group_slug, date, first_time, canonical_language)
            {:redirect, redirect_url}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Content Rendering
  # ============================================================================

  @doc """
  Renders post content with caching for published posts.
  Uses Renderer.render_post/1 which caches based on content hash.
  """
  def render_post_content(post) do
    case Renderer.render_post(post) do
      {:ok, html} -> html
      # Fallback to uncached rendering if render_post returns unexpected format
      _ -> Renderer.render_markdown(post.content)
    end
  end

  # ============================================================================
  # Version Dropdown
  # ============================================================================

  @doc """
  Builds version dropdown data for the public post template.
  Returns nil if version access is disabled or only one published version exists.
  Uses listing cache for fast lookups instead of reading files.
  """
  def build_version_dropdown(group_slug, post, language) do
    # Try to get cached data first (sub-microsecond from :persistent_term)
    # The cache stores the live version with all version metadata
    {allow_access, live_version} = get_cached_version_info(group_slug, post)

    version_statuses = Map.get(post, :version_statuses, %{})
    current_version = Map.get(post, :version, 1)

    if allow_access and map_size(version_statuses) > 0 do
      # Filter to only published versions
      published_versions =
        version_statuses
        |> Enum.filter(fn {_v, status} -> status == "published" end)
        |> Enum.map(fn {v, _status} -> v end)
        |> Enum.sort(:desc)

      # Only show dropdown if there are multiple published versions
      if length(published_versions) > 1 do
        versions_with_urls =
          Enum.map(published_versions, fn version ->
            url = build_version_url(group_slug, post, language, version)

            %{
              version: version,
              url: url,
              is_current: version == current_version,
              is_live: version == live_version
            }
          end)

        %{
          versions: versions_with_urls,
          current_version: current_version
        }
      else
        nil
      end
    else
      nil
    end
  end

  @doc """
  Gets version info from cache (allow_version_access and live_version).
  Falls back to file reads if cache miss.
  """
  def get_cached_version_info(group_slug, current_post) do
    # Use appropriate cache lookup based on post mode
    cache_result = find_cached_post(group_slug, current_post)

    case cache_result do
      {:ok, cached_post} ->
        # Cache stores the live version's metadata
        allow_access = Map.get(cached_post.metadata, :allow_version_access, false)
        live_version = cached_post.version
        {allow_access, live_version}

      {:error, _} ->
        # Cache miss - fall back to file reads
        post_identifier = get_post_identifier(current_post)

        # Use post's stored primary language, not global
        primary_language =
          current_post[:primary_language] ||
            Storage.get_post_primary_language(group_slug, post_identifier)

        allow_access = get_allow_access_from_file(group_slug, current_post, primary_language)
        live_version = get_live_version_from_file(group_slug, post_identifier)
        {allow_access, live_version}
    end
  end

  # Find cached post using appropriate method based on post mode
  defp find_cached_post(group_slug, post) do
    case Map.get(post, :mode) do
      :timestamp ->
        # For timestamp mode, use date/time lookup
        date = post[:date]
        time = post[:time]

        if date && time do
          date_str = if is_struct(date, Date), do: Date.to_iso8601(date), else: to_string(date)
          time_str = format_time_for_cache(time)
          ListingCache.find_post_by_path(group_slug, date_str, time_str)
        else
          {:error, :not_found}
        end

      _ ->
        # For slug mode, use slug lookup
        ListingCache.find_post(group_slug, post.slug)
    end
  end

  defp format_time_for_cache(%Time{} = time) do
    time |> Time.to_string() |> String.slice(0, 5)
  end

  defp format_time_for_cache(time) when is_binary(time), do: String.slice(time, 0, 5)
  defp format_time_for_cache(_), do: ""

  # Get the correct post identifier based on mode
  defp get_post_identifier(post) do
    case Map.get(post, :mode) do
      :timestamp -> extract_timestamp_identifier(post.path)
      _ -> post.slug
    end
  end

  # Extract timestamp identifier (date/time) from a timestamp mode path
  defp extract_timestamp_identifier(path) when is_binary(path) do
    case Regex.run(~r/(\d{4}-\d{2}-\d{2}\/\d{2}:\d{2})/, path) do
      [_, timestamp] -> timestamp
      nil -> path
    end
  end

  defp extract_timestamp_identifier(path), do: path

  # Fallback: Gets allow_version_access from file when cache misses
  defp get_allow_access_from_file(group_slug, current_post, primary_language) do
    if current_post.language == primary_language do
      Map.get(current_post.metadata, :allow_version_access, false)
    else
      post_identifier = get_post_identifier(current_post)

      case Publishing.read_post(group_slug, post_identifier, primary_language, nil) do
        {:ok, primary_post} -> Map.get(primary_post.metadata, :allow_version_access, false)
        {:error, _} -> false
      end
    end
  end

  # Fallback: Gets published version from file when cache misses
  defp get_live_version_from_file(group_slug, post_identifier) do
    case Storage.get_published_version(group_slug, post_identifier) do
      {:ok, version} -> version
      {:error, _} -> nil
    end
  end

  @doc """
  Checks if a specific post allows public access to older versions.
  Always reads from the primary language's live version to ensure consistency.
  """
  def post_allows_version_access?(group_slug, post_slug, _language) do
    # Always read from post's stored primary language to ensure per-post behavior
    primary_language = Storage.get_post_primary_language(group_slug, post_slug)

    # Read the live version (version: nil means get latest/live)
    case Publishing.read_post(group_slug, post_slug, primary_language, nil) do
      {:ok, post} ->
        Map.get(post.metadata, :allow_version_access, false)

      {:error, _} ->
        # If we can't read the live version, deny access
        false
    end
  end

  # ============================================================================
  # URL Building
  # ============================================================================

  @doc """
  Builds URL for a specific version of a post.
  """
  def build_version_url(group_slug, post, language, version) do
    base_url = PublishingHTML.build_post_url(group_slug, post, language)
    "#{base_url}/v/#{version}"
  end

  @doc """
  Builds a timestamp URL with date and time.
  """
  def build_timestamp_url(group_slug, date, time, language) do
    PublishingHTML.build_public_path_with_time(language, group_slug, date, time)
  end

  # ============================================================================
  # Breadcrumbs
  # ============================================================================

  @doc """
  Builds breadcrumbs for a post page.
  """
  def build_breadcrumbs(group_slug, post, language) do
    group_name =
      case Listing.fetch_group(group_slug) do
        {:ok, group} -> group["name"]
        {:error, _} -> group_slug
      end

    [
      %{label: group_name, url: PublishingHTML.group_listing_path(language, group_slug)},
      %{label: post.metadata.title, url: nil}
    ]
  end

  # ============================================================================
  # Logging
  # ============================================================================

  defp log_404(conn, group_slug, identifier, language, reason) do
    Logger.info("Publishing 404",
      group_slug: group_slug,
      identifier: inspect(identifier),
      reason: reason,
      language: language,
      user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
      path: conn.request_path
    )
  end
end
