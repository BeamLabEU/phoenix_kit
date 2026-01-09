defmodule PhoenixKitWeb.BlogController do
  @moduledoc """
  Public blog post display controller.

  Handles public-facing routes for viewing published blog posts with multi-language support.

  URL patterns:
    /:language/:blog_slug/:post_slug - Slug mode post
    /:language/:blog_slug/:date/:time - Timestamp mode post
    /:language/:blog_slug - Blog listing
  """

  use PhoenixKitWeb, :controller
  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.BlogHTML

  # Suppress dialyzer false positive for defensive fallback pattern
  @dialyzer {:nowarn_function, render_post_content: 1}

  @doc """
  Displays a blog post, blog listing, or all blogs overview.

  Path parsing determines which action to take:
  - [] -> Invalid request (no blog specified)
  - [blog_slug] -> Blog listing
  - [blog_slug, post_slug] -> Slug mode post
  - [blog_slug, date] -> Date-only timestamp (resolves to single post or first post)
  - [blog_slug, date, time] -> Timestamp mode post
  """
  def show(conn, %{"language" => language_param} = params) do
    # Detect if 'language' param is actually a language code or a blog slug
    # This allows the same route to work for both single and multi-language setups
    {language, adjusted_params} = detect_language_or_blog(language_param, params)

    conn = assign(conn, :current_language, language)

    if Publishing.enabled?() and public_enabled?() do
      case build_segments(adjusted_params) do
        [] ->
          handle_not_found(conn, :invalid_path)

        segments ->
          case parse_path(segments) do
            {:listing, blog_slug} ->
              render_blog_listing(conn, blog_slug, language, conn.params)

            {:slug_post, blog_slug, post_slug} ->
              render_post(conn, blog_slug, {:slug, post_slug}, language)

            {:timestamp_post, blog_slug, date, time} ->
              render_post(conn, blog_slug, {:timestamp, date, time}, language)

            {:date_only_post, blog_slug, date} ->
              handle_date_only_url(conn, blog_slug, date, language)

            {:versioned_post, blog_slug, post_slug, version} ->
              render_versioned_post(conn, blog_slug, post_slug, version, language)

            {:error, reason} ->
              handle_not_found(conn, reason)
          end
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # Fallback for routes without language parameter
  # This handles the non-localized route where :blog might actually be a language code
  def show(conn, params) do
    if Publishing.enabled?() and public_enabled?() do
      # Check if the first segment (blog) is actually a language with content
      case detect_language_in_blog_param(params) do
        {:language_detected, language, adjusted_params} ->
          # First segment was a language code with content - use localized logic
          conn = assign(conn, :current_language, language)
          handle_localized_request(conn, language, adjusted_params)

        :not_a_language ->
          # First segment is a blog slug - use default language
          language = get_default_language()
          conn = assign(conn, :current_language, language)
          handle_non_localized_request(conn, language, params)
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # Handles request after language has been detected
  defp handle_localized_request(conn, language, params) do
    case build_segments(params) do
      [] ->
        handle_not_found(conn, :invalid_path)

      segments ->
        case parse_path(segments) do
          {:listing, blog_slug} ->
            render_blog_listing(conn, blog_slug, language, conn.params)

          {:slug_post, blog_slug, post_slug} ->
            render_post(conn, blog_slug, {:slug, post_slug}, language)

          {:timestamp_post, blog_slug, date, time} ->
            render_post(conn, blog_slug, {:timestamp, date, time}, language)

          {:date_only_post, blog_slug, date} ->
            handle_date_only_url(conn, blog_slug, date, language)

          {:versioned_post, blog_slug, post_slug, version} ->
            render_versioned_post(conn, blog_slug, post_slug, version, language)

          {:error, reason} ->
            handle_not_found(conn, reason)
        end
    end
  end

  # Handles non-localized request with default language
  defp handle_non_localized_request(conn, language, params) do
    case build_segments(params) do
      [] ->
        handle_not_found(conn, :invalid_path)

      segments ->
        case parse_path(segments) do
          {:listing, blog_slug} ->
            render_blog_listing(conn, blog_slug, language, conn.params)

          {:slug_post, blog_slug, post_slug} ->
            render_post(conn, blog_slug, {:slug, post_slug}, language)

          {:timestamp_post, blog_slug, date, time} ->
            render_post(conn, blog_slug, {:timestamp, date, time}, language)

          {:date_only_post, blog_slug, date} ->
            handle_date_only_url(conn, blog_slug, date, language)

          {:versioned_post, blog_slug, post_slug, version} ->
            render_versioned_post(conn, blog_slug, post_slug, version, language)

          {:error, reason} ->
            handle_not_found(conn, reason)
        end
    end
  end

  # Detects if the "blog" param is actually a language code by checking if content exists
  # Returns {:language_detected, language, adjusted_params} or :not_a_language
  defp detect_language_in_blog_param(
         %{"blog" => potential_lang, "path" => [_ | _] = path} = _params
       )
       when is_binary(potential_lang) do
    [actual_blog | rest_path] = path

    blog_exists = blog_exists?(actual_blog)
    has_content = has_content_for_language?(actual_blog, potential_lang)

    # Check if there's a blog with slug matching actual_blog
    # AND if there's content for potential_lang in that blog
    if blog_exists and has_content do
      adjusted_params = %{"blog" => actual_blog, "path" => rest_path}
      {:language_detected, potential_lang, adjusted_params}
    else
      :not_a_language
    end
  end

  defp detect_language_in_blog_param(_params), do: :not_a_language

  # Check if any post in the blog has content for the given language
  # Uses listing cache when available for fast lookups
  defp has_content_for_language?(blog_slug, language) do
    # Try cache first for fast lookup
    case ListingCache.read(blog_slug) do
      {:ok, posts} ->
        Enum.any?(posts, fn post ->
          language in (post.available_languages || [])
        end)

      {:error, _} ->
        # Cache miss - fall back to filesystem scan
        posts = Publishing.list_posts(blog_slug, nil)

        Enum.any?(posts, fn post ->
          language in (post.available_languages || [])
        end)
    end
  rescue
    _ -> false
  end

  # ============================================================================
  # Language Detection
  # ============================================================================

  # Detects whether the 'language' parameter is actually a language code or a blog slug.
  #
  # This allows the same route pattern (/:language/:blog/*path) to work for both:
  # - Multi-language: /en/my-blog/my-post (language=en, blog=my-blog)
  # - Single-language: /my-blog/my-post (language=my-blog, needs adjustment)
  #
  # Returns {detected_language, adjusted_params}
  defp detect_language_or_blog(language_param, params) do
    # First check if it's a known/predefined language
    # Then check if content exists for this language in the blog (handles unknown languages like "af")
    blog_slug = params["blog"]

    cond do
      # Known/predefined language - use as-is
      valid_language?(language_param) ->
        {language_param, params}

      # Unknown language code but content exists for it in this blog
      # This handles files like af.phk, test.phk, etc.
      blog_slug && has_content_for_language?(blog_slug, language_param) ->
        {language_param, params}

      # Not a language - shift parameters (blog slug in language position)
      true ->
        default_language = get_default_language()

        adjusted_params =
          case params do
            # Pattern: %{"language" => blog_slug, "blog" => first_path_segment, "path" => rest}
            %{"blog" => first_segment, "path" => rest} when is_list(rest) ->
              %{"blog" => language_param, "path" => [first_segment | rest]}

            # Pattern: %{"language" => blog_slug, "blog" => first_path_segment}
            %{"blog" => first_segment} ->
              %{"blog" => language_param, "path" => [first_segment]}

            # Pattern: %{"language" => blog_slug} (just listing)
            _ ->
              %{"blog" => language_param}
          end

        {default_language, adjusted_params}
    end
  end

  defp valid_language?(code) when is_binary(code) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Check if it's a language code pattern (enabled, disabled, or even unknown)
    # This allows access to legacy content in disabled languages
    cond do
      # Enabled language - definitely valid
      Languages.language_enabled?(code) ->
        true

      # Base code that maps to an enabled dialect
      String.length(code) == 2 and not String.contains?(code, "-") ->
        dialect = DialectMapper.base_to_dialect(code)

        if Languages.language_enabled?(dialect) do
          true
        else
          # Even if disabled, it's still a valid language code pattern
          # Check if it's a known language
          Languages.get_predefined_language(dialect) != nil
        end

      # Known but disabled language (full dialect like "fr-FR")
      Languages.get_predefined_language(code) != nil ->
        true

      # Check if it looks like a language code pattern (XX or XX-XX format)
      # This allows access to unknown files like legacy imports
      looks_like_language_code?(code) ->
        true

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_language?(_), do: false

  # Check if a string looks like a language code pattern
  # Matches: 2-letter codes (en, fr), or dialect codes (en-US, pt-BR)
  defp looks_like_language_code?(code) when is_binary(code) do
    # 2-letter base code
    # Dialect code pattern (xx-XX or xx-XXX)
    (String.length(code) == 2 and String.match?(code, ~r/^[a-z]{2}$/i)) or
      String.match?(code, ~r/^[a-z]{2,3}-[A-Za-z]{2,4}$/i)
  end

  # ============================================================================
  # Path Parsing
  # ============================================================================

  defp build_segments(%{"blog" => blog} = params) when is_binary(blog) do
    case Map.get(params, "path") do
      nil -> [blog]
      path when is_list(path) -> [blog | path]
      path when is_binary(path) -> [blog, path]
      _ -> [blog]
    end
  end

  defp build_segments(_), do: []

  defp parse_path([]), do: {:error, :invalid_path}
  defp parse_path([blog_slug]), do: {:listing, blog_slug}

  defp parse_path([blog_slug, segment1, segment2]) do
    # Check if this is timestamp mode: segment1 matches date, segment2 matches time
    if date?(segment1) and time?(segment2) do
      {:timestamp_post, blog_slug, segment1, segment2}
    else
      # Invalid format
      {:error, :invalid_path}
    end
  end

  # Version-specific URL: /blog/post-slug/v/2
  defp parse_path([blog_slug, post_slug, "v", version_str]) do
    case Integer.parse(version_str) do
      {version, ""} when version > 0 ->
        {:versioned_post, blog_slug, post_slug, version}

      _ ->
        {:error, :invalid_version}
    end
  end

  defp parse_path([blog_slug, segment]) do
    # Check if segment is a date (for date-only timestamp URLs)
    # If it's a date, treat as date-only timestamp post
    # Otherwise, treat as slug mode post
    if date?(segment) do
      {:date_only_post, blog_slug, segment}
    else
      {:slug_post, blog_slug, segment}
    end
  end

  defp parse_path(_), do: {:error, :invalid_path}

  # Date validation: YYYY-MM-DD
  defp date?(str) when is_binary(str) do
    String.match?(str, ~r/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/)
  end

  defp date?(_), do: false

  # Time validation: HH:MM (24-hour)
  defp time?(str) when is_binary(str) do
    String.match?(str, ~r/^([01]\d|2[0-3]):[0-5]\d$/)
  end

  defp time?(_), do: false

  # ============================================================================
  # Rendering Functions
  # ============================================================================

  defp render_blog_listing(conn, blog_slug, language, params) do
    case fetch_blog(blog_slug) do
      {:ok, blog} ->
        # Check if we need to redirect to canonical URL
        canonical_language = get_canonical_url_language(language)

        if canonical_language != language do
          # Redirect to canonical URL
          canonical_url = BlogHTML.blog_listing_path(canonical_language, blog_slug, params)
          redirect(conn, to: canonical_url)
        else
          page = get_page_param(params)
          per_page = get_per_page_setting()

          # Try cache first, fall back to filesystem scan
          all_posts_unfiltered = fetch_posts_with_cache(blog_slug)

          # Filter to posts that have this EXACT language file and are published
          all_posts =
            all_posts_unfiltered
            |> filter_published()
            |> filter_by_exact_language(blog_slug, language)

          # If no posts exist for this language, return 404
          # This prevents empty blog listing pages for languages without content
          if all_posts == [] do
            handle_not_found(conn, :no_content_for_language)
          else
            total_count = length(all_posts)
            posts = paginate(all_posts, page, per_page)

            breadcrumbs = [
              %{label: blog["name"], url: nil}
            ]

            # Build translation links for blog listing (reuse unfiltered posts)
            translations = build_listing_translations(blog_slug, language, all_posts_unfiltered)

            conn
            |> assign(:page_title, blog["name"])
            |> assign(:blog, blog)
            |> assign(:posts, posts)
            |> assign(:current_language, canonical_language)
            |> assign(:translations, translations)
            |> assign(:page, page)
            |> assign(:per_page, per_page)
            |> assign(:total_count, total_count)
            |> assign(:total_pages, ceil(total_count / per_page))
            |> assign(:breadcrumbs, breadcrumbs)
            |> render(:index)
          end
        end

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # Fetches posts using cache when available, falls back to filesystem scan
  # On cache miss, regenerates cache asynchronously for next request
  defp fetch_posts_with_cache(blog_slug) do
    start_time = System.monotonic_time(:microsecond)

    case ListingCache.read(blog_slug) do
      {:ok, posts} ->
        elapsed_us = System.monotonic_time(:microsecond) - start_time

        Logger.debug(
          "[BlogController] Cache HIT for #{blog_slug} (#{elapsed_us}μs, #{length(posts)} posts)"
        )

        posts

      {:error, :cache_miss} ->
        Logger.warning(
          "[BlogController] Cache MISS for #{blog_slug} - falling back to filesystem scan"
        )

        # Cache miss - scan filesystem and regenerate cache for next request
        all_posts = Publishing.list_posts(blog_slug, nil)

        elapsed_us = System.monotonic_time(:microsecond) - start_time
        elapsed_ms = Float.round(elapsed_us / 1000, 1)

        Logger.warning(
          "[BlogController] Filesystem scan complete for #{blog_slug} (#{elapsed_ms}ms, #{length(all_posts)} posts)"
        )

        # Regenerate cache asynchronously (don't block the request)
        Task.start(fn -> ListingCache.regenerate(blog_slug) end)

        all_posts
    end
  end

  defp render_post(conn, blog_slug, identifier, language) do
    case fetch_post(blog_slug, identifier, language) do
      {:ok, post} ->
        # Check if published
        if post.metadata.status == "published" do
          # Check if we need to redirect to canonical URL
          # The canonical URL uses the display_code (base or full dialect depending on enabled languages)
          canonical_language = get_canonical_url_language_for_post(post.language)

          if canonical_language != language do
            # Redirect to canonical URL
            canonical_url = BlogHTML.build_post_url(blog_slug, post, canonical_language)
            redirect(conn, to: canonical_url)
          else
            # Render markdown (cached for published posts)
            html_content = render_post_content(post)

            # Build translation links
            translations = build_translation_links(blog_slug, post, canonical_language)

            # Build breadcrumbs
            breadcrumbs = build_breadcrumbs(blog_slug, post, canonical_language)

            # Build version dropdown data if allowed
            version_dropdown = build_version_dropdown(blog_slug, post, canonical_language)

            conn
            |> assign(:page_title, post.metadata.title)
            |> assign(:blog_slug, blog_slug)
            |> assign(:post, post)
            |> assign(:html_content, html_content)
            |> assign(:current_language, canonical_language)
            |> assign(:translations, translations)
            |> assign(:breadcrumbs, breadcrumbs)
            |> assign(:version_dropdown, version_dropdown)
            |> render(:show)
          end
        else
          log_404(conn, blog_slug, identifier, language, :unpublished)
          handle_not_found(conn, :unpublished)
        end

      {:error, reason} ->
        log_404(conn, blog_slug, identifier, language, reason)
        handle_not_found(conn, reason)
    end
  end

  # Renders a specific version of a post (for version browsing feature)
  defp render_versioned_post(conn, blog_slug, post_slug, version, language) do
    # Check per-post version access setting (from the live version's metadata)
    # Each post controls its own version access - no global setting required
    if post_allows_version_access?(blog_slug, post_slug, language) do
      # Fetch the specific version
      case Publishing.read_post(blog_slug, post_slug, language, version) do
        {:ok, post} ->
          # Check if version is published
          if post.metadata.status == "published" do
            # Get canonical language
            canonical_language = get_canonical_url_language_for_post(post.language)

            # Render markdown (cached for published posts)
            html_content = render_post_content(post)

            # Build translation links (preserve version in URLs)
            translations =
              build_translation_links(blog_slug, post, canonical_language, version: version)

            # Build breadcrumbs
            breadcrumbs = build_breadcrumbs(blog_slug, post, canonical_language)

            # Build canonical URL (points to main post URL, not versioned URL)
            canonical_url = BlogHTML.build_post_url(blog_slug, post, canonical_language)

            # Build version dropdown data (also gives us the live version)
            version_dropdown = build_version_dropdown(blog_slug, post, canonical_language)

            # Check if this is the live version by comparing to the published version
            # (is_live field was removed from metadata, now derived from status)
            {_allow_access, live_version} = get_cached_version_info(blog_slug, post)
            is_live = version == live_version

            conn
            |> assign(:page_title, post.metadata.title)
            |> assign(:blog_slug, blog_slug)
            |> assign(:post, post)
            |> assign(:html_content, html_content)
            |> assign(:current_language, canonical_language)
            |> assign(:translations, translations)
            |> assign(:breadcrumbs, breadcrumbs)
            |> assign(:canonical_url, canonical_url)
            |> assign(:is_versioned_view, true)
            |> assign(:is_live_version, is_live)
            |> assign(:version, version)
            |> assign(:version_dropdown, version_dropdown)
            |> render(:show)
          else
            log_404(conn, blog_slug, {:slug, post_slug, version}, language, :unpublished)
            handle_not_found(conn, :unpublished)
          end

        {:error, reason} ->
          log_404(conn, blog_slug, {:slug, post_slug, version}, language, reason)
          handle_not_found(conn, reason)
      end
    else
      handle_not_found(conn, :version_access_disabled)
    end
  end

  # Handles date-only URLs (e.g., /blog/2025-12-09)
  # If only one post exists on that date, render it directly
  # If multiple posts exist, redirect to the first one with time in URL
  defp handle_date_only_url(conn, blog_slug, date, language) do
    case fetch_blog(blog_slug) do
      {:ok, _blog} ->
        times = Storage.list_times_on_date(blog_slug, date)

        case times do
          [] ->
            # No posts on this date
            handle_not_found(conn, :post_not_found)

          [single_time] ->
            # Only one post - render it directly
            render_post(conn, blog_slug, {:timestamp, date, single_time}, language)

          [first_time | _rest] ->
            # Multiple posts - redirect to first one with time in URL
            canonical_language = get_canonical_url_language(language)
            redirect_url = build_timestamp_url(blog_slug, date, first_time, canonical_language)
            redirect(conn, to: redirect_url)
        end

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # Builds a timestamp URL with date and time
  defp build_timestamp_url(blog_slug, date, time, language) do
    BlogHTML.build_public_path_with_time(language, blog_slug, date, time)
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp fetch_blog(blog_slug) do
    blog_slug = blog_slug |> to_string() |> String.trim()

    case Enum.find(Publishing.list_groups(), fn blog ->
           case blog["slug"] do
             slug when is_binary(slug) ->
               String.downcase(slug) == String.downcase(blog_slug)

             _ ->
               false
           end
         end) do
      nil -> {:error, :blog_not_found}
      blog -> {:ok, blog}
    end
  end

  # Fetch a slug-mode post - iterates from highest version down, returns first published
  # Falls back to master language or first available if requested language isn't found
  defp fetch_post(blog_slug, {:slug, post_slug}, language) do
    case Storage.list_versions(blog_slug, post_slug) do
      [] ->
        {:error, :post_not_found}

      versions ->
        find_published_slug_post(blog_slug, post_slug, versions, language)
    end
  end

  defp fetch_post(blog_slug, {:timestamp, date, time}, language) do
    # Try cache first for fast lookup (sub-microsecond from :persistent_term)
    case fetch_timestamp_post_from_cache(blog_slug, date, time, language) do
      {:ok, _post} = result ->
        result

      {:error, _} ->
        # Cache miss - fall back to filesystem scan
        post_dir = Path.join([Storage.group_path(blog_slug), date, time])

        case Storage.detect_post_structure(post_dir) do
          :versioned ->
            fetch_versioned_timestamp_post(blog_slug, date, time, language, post_dir)

          :legacy ->
            fetch_legacy_timestamp_post(blog_slug, date, time, language, post_dir)

          :empty ->
            {:error, :post_not_found}
        end
    end
  end

  defp find_published_slug_post(blog_slug, post_slug, versions, language) do
    master_language = Storage.get_master_language()
    post_dir = Path.join([Storage.group_path(blog_slug), post_slug])

    published_result =
      versions
      |> Enum.sort(:desc)
      |> Enum.find_value(
        &find_published_version(&1, blog_slug, post_slug, post_dir, language, master_language)
      )

    published_result || {:error, :post_not_found}
  end

  defp find_published_version(version, blog_slug, post_slug, post_dir, language, master_language) do
    version_dir = Path.join(post_dir, "v#{version}")
    available_languages = detect_available_languages_in_dir(version_dir)
    resolved_language = resolve_language_for_post(language, available_languages)

    languages_to_try =
      [resolved_language, master_language | available_languages]
      |> Enum.uniq()
      |> Enum.filter(&(&1 in available_languages))

    Enum.find_value(languages_to_try, &try_read_published_post(blog_slug, post_slug, &1, version))
  end

  defp try_read_published_post(blog_slug, post_slug, lang, version) do
    case Publishing.read_post(blog_slug, post_slug, lang, version) do
      {:ok, post} when post.metadata.status == "published" -> {:ok, post}
      _ -> nil
    end
  end

  # Fast path: Use cache to get metadata, only read content file
  defp fetch_timestamp_post_from_cache(blog_slug, date, time, language) do
    case ListingCache.find_post_by_path(blog_slug, date, time) do
      {:ok, cached_post} ->
        # Cache has all metadata, we just need to read the content
        # Find the right language file to read
        resolved_language = resolve_language_for_post(language, cached_post.available_languages)

        if resolved_language do
          # Build path to the content file
          # The cached post has the live version's path
          content_path = build_content_path_from_cache(cached_post, resolved_language)

          case read_content_only(content_path) do
            {:ok, content} ->
              # Merge cached metadata with fresh content
              {:ok, merge_cache_with_content(cached_post, content, resolved_language)}

            {:error, _} ->
              {:error, :content_not_found}
          end
        else
          {:error, :language_not_found}
        end

      {:error, _} ->
        {:error, :cache_miss}
    end
  end

  # Build the content file path from cached post data
  defp build_content_path_from_cache(cached_post, language) do
    # The cached post's full_path points to the live version
    # Replace the language portion
    cached_post.full_path
    |> Path.dirname()
    |> Path.join("#{language}.phk")
  end

  # Read just the content from a file (skip expensive metadata operations)
  defp read_content_only(path) do
    with {:ok, file_content} <- File.read(path),
         {:ok, _metadata, body} <- Metadata.parse_with_content(file_content) do
      {:ok, body}
    end
  end

  # Merge cached metadata with fresh content
  defp merge_cache_with_content(cached_post, content, language) do
    %{
      group: cached_post.group,
      slug: cached_post.slug,
      date: cached_post.date,
      time: cached_post.time,
      path: cached_post.path,
      full_path: build_content_path_from_cache(cached_post, language),
      metadata: cached_post.metadata,
      content: content,
      language: language,
      available_languages: cached_post.available_languages,
      language_statuses: cached_post.language_statuses,
      mode: cached_post.mode,
      version: cached_post.version,
      available_versions: cached_post.available_versions,
      version_statuses: cached_post.version_statuses,
      is_legacy_structure: cached_post.is_legacy_structure
    }
  end

  # Fetch a versioned timestamp post (files in v1/, v2/, etc.)
  # Iterates from highest version down, returns first published version found
  # Falls back to master language or first available if requested language isn't found
  defp fetch_versioned_timestamp_post(blog_slug, date, time, language, post_dir) do
    versions = list_timestamp_versions(post_dir) |> Enum.sort(:desc)
    master_language = Storage.get_master_language()

    # Find first published version, starting from highest
    published_result =
      Enum.find_value(versions, fn version ->
        version_dir = Path.join(post_dir, "v#{version}")
        available_languages = detect_available_languages_in_dir(version_dir)

        # Build priority list of languages to try:
        # 1. Resolved version of requested language
        # 2. Master language
        # 3. First available language
        resolved_language = resolve_language_for_post(language, available_languages)

        languages_to_try =
          [resolved_language, master_language | available_languages]
          |> Enum.uniq()
          |> Enum.filter(&(&1 in available_languages))

        Enum.find_value(languages_to_try, fn lang ->
          path = "#{blog_slug}/#{date}/#{time}/v#{version}/#{lang}.phk"

          case Publishing.read_post(blog_slug, path) do
            {:ok, post} when post.metadata.status == "published" -> {:ok, post}
            _ -> nil
          end
        end)
      end)

    published_result || {:error, :post_not_found}
  end

  # Fetch a legacy timestamp post (files directly in post directory)
  # Falls back to master language or first available if requested language isn't found
  defp fetch_legacy_timestamp_post(blog_slug, date, time, language, post_dir) do
    available_languages = detect_available_languages_in_dir(post_dir)
    master_language = Storage.get_master_language()
    resolved_language = resolve_language_for_post(language, available_languages)

    # Build priority list of languages to try
    languages_to_try =
      [resolved_language, master_language | available_languages]
      |> Enum.uniq()
      |> Enum.filter(&(&1 in available_languages))

    Enum.find_value(languages_to_try, fn lang ->
      # Build legacy path: blog/date/time/language.phk
      path = "#{blog_slug}/#{date}/#{time}/#{lang}.phk"

      case Publishing.read_post(blog_slug, path) do
        {:ok, post} -> {:ok, post}
        _ -> nil
      end
    end) || {:error, :post_not_found}
  end

  # List version numbers for a timestamp post directory
  defp list_timestamp_versions(post_dir) do
    case File.ls(post_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^v\d+$/, &1))
        |> Enum.map(&(String.replace_prefix(&1, "v", "") |> String.to_integer()))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # Detect available language files in a directory
  defp detect_available_languages_in_dir(dir_path) do
    case File.ls(dir_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".phk"))
        |> Enum.map(&String.replace_suffix(&1, ".phk", ""))

      {:error, _} ->
        []
    end
  end

  # Detect available languages in a timestamp post directory
  # Handles both versioned (files in v1/, v2/) and legacy (files in root) structures
  defp detect_available_languages_in_timestamp_dir(post_dir) do
    case Storage.detect_post_structure(post_dir) do
      :versioned ->
        # Get languages from the latest version directory
        versions = list_timestamp_versions(post_dir)

        case Enum.max(versions, fn -> nil end) do
          nil ->
            []

          latest_version ->
            version_dir = Path.join(post_dir, "v#{latest_version}")
            detect_available_languages_in_dir(version_dir)
        end

      :legacy ->
        detect_available_languages_in_dir(post_dir)

      :empty ->
        []
    end
  end

  # Resolve a language code to an actual file language
  # Handles base codes by finding a matching dialect in available languages
  defp resolve_language_for_post(language, available_languages) do
    cond do
      # Direct match - language exactly matches an available file
      language in available_languages ->
        language

      # Base code - try to find a dialect that matches
      base_code?(language) ->
        find_dialect_for_base_in_files(language, available_languages) ||
          DialectMapper.base_to_dialect(language)

      # Full dialect code not found - try base code match as fallback
      true ->
        base = DialectMapper.extract_base(language)
        find_dialect_for_base_in_files(base, available_languages) || language
    end
  end

  # Find a dialect in available files that matches the given base code
  defp find_dialect_for_base_in_files(base_code, available_languages) do
    base_lower = String.downcase(base_code)

    Enum.find(available_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  # Renders post content with caching for published posts
  # Uses Renderer.render_post/1 which caches based on content hash
  defp render_post_content(post) do
    case Renderer.render_post(post) do
      {:ok, html} -> html
      # Fallback to uncached rendering if render_post returns unexpected format
      _ -> Renderer.render_markdown(post.content)
    end
  end

  # Gets the canonical URL language code for a given language.
  # If multiple dialects of the same base language are enabled, returns the full dialect.
  # Otherwise returns the base code for cleaner URLs.
  defp get_canonical_url_language(language) do
    enabled_languages = get_enabled_languages()

    # Resolve base code to a specific dialect if needed
    resolved_language =
      if base_code?(language) do
        # Find the matching dialect in enabled languages
        find_dialect_for_base(language, enabled_languages) || language
      else
        language
      end

    # Now determine if we should use base or full dialect code
    Storage.get_display_code(resolved_language, enabled_languages)
  end

  # Gets the canonical URL language code for a post's language.
  # This uses the actual file language (e.g., "en-US") to determine the canonical URL code.
  defp get_canonical_url_language_for_post(post_language) do
    enabled_languages = get_enabled_languages()
    Storage.get_display_code(post_language, enabled_languages)
  end

  defp get_enabled_languages do
    Languages.enabled_locale_codes()
  rescue
    _ -> ["en"]
  end

  defp base_code?(code) when is_binary(code) do
    String.length(code) == 2 and not String.contains?(code, "-")
  end

  defp base_code?(_), do: false

  # Find a dialect in enabled languages that matches the given base code
  defp find_dialect_for_base(base_code, enabled_languages) do
    base_lower = String.downcase(base_code)

    Enum.find(enabled_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  # Build translation links for blog listing page
  # Accepts posts to avoid redundant list_posts calls
  defp build_listing_translations(blog_slug, current_language, posts) do
    # Get enabled languages - these are the ONLY languages that should show
    enabled_languages =
      try do
        Languages.enabled_locale_codes()
      rescue
        _ -> ["en"]
      end

    # Extract base code from current language for comparison
    current_base = DialectMapper.extract_base(current_language)

    # Get the primary/default language
    primary_language = List.first(enabled_languages) || "en"

    # For each enabled language, check if there's published content for it
    # Only show languages that are explicitly enabled (not just base code matches)
    translations =
      enabled_languages
      |> Enum.filter(fn lang ->
        # Check if this specific language has published content (using passed posts)
        has_published_content_for_language?(posts, lang)
      end)
      |> Enum.map(fn lang ->
        # Use display_code helper to determine if we show base or full code
        display_code = Storage.get_display_code(lang, enabled_languages)

        %{
          code: display_code,
          display_code: display_code,
          name: get_language_name(lang),
          flag: get_language_flag(lang),
          url: BlogHTML.blog_listing_path(display_code, blog_slug),
          current: DialectMapper.extract_base(lang) == current_base
        }
      end)

    # Order: primary first, then the rest alphabetically
    if Enum.any?(
         translations,
         &(&1.code == Storage.get_display_code(primary_language, enabled_languages))
       ) do
      primary_display = Storage.get_display_code(primary_language, enabled_languages)
      {primary, others} = Enum.split_with(translations, &(&1.code == primary_display))
      primary ++ Enum.sort_by(others, & &1.code)
    else
      Enum.sort_by(translations, & &1.code)
    end
    |> Enum.uniq_by(& &1.code)
  end

  # Check if a specific enabled language has published content in the blog
  # ONLY checks for EXACT file matches - no base code fallback
  # This ensures only languages with actual files show in the public switcher
  # Uses passed posts to avoid redundant list_posts calls
  defp has_published_content_for_language?(posts, language) do
    Enum.any?(posts, fn post ->
      # Check if there's a published file for this EXACT language only
      # Use preloaded language_statuses map
      language in (post.available_languages || []) and
        Map.get(post.language_statuses, language) == "published"
    end)
  end

  defp build_translation_links(blog_slug, post, current_language, opts \\ []) do
    version = Keyword.get(opts, :version)

    # Get enabled languages
    enabled_languages =
      try do
        Languages.enabled_locale_codes()
      rescue
        _ -> ["en"]
      end

    # Extract base code from current language for comparison
    current_base = DialectMapper.extract_base(current_language)

    # Get the primary/default language
    primary_language = List.first(enabled_languages) || "en"

    # Include ALL available languages that are published
    # This allows legacy/disabled languages to still show in the public switcher
    # (they'll be styled differently by the component based on enabled/known flags)
    available_and_published =
      post.available_languages
      |> normalize_languages(current_language)
      |> Enum.filter(fn lang ->
        translation_published_exact?(blog_slug, post, lang)
      end)

    # Remove legacy base code files when dialect files exist
    # e.g., if both "en" and "en-CA" exist, remove "en" to avoid duplicates
    deduplicated =
      deduplicate_base_and_dialect_files(available_and_published, enabled_languages)

    # Order: primary first (if present), then enabled languages, then disabled ones
    languages = order_languages_for_public(deduplicated, enabled_languages, primary_language)

    Enum.map(languages, fn lang ->
      # Use display_code helper to determine if we show base or full code
      display_code = Storage.get_display_code(lang, enabled_languages)
      is_enabled = language_enabled_for_public?(lang, enabled_languages)
      is_known = Languages.get_predefined_language(lang) != nil

      # Build URL with version if viewing a specific version
      url =
        if version do
          build_version_url(blog_slug, post, display_code, version)
        else
          BlogHTML.build_post_url(blog_slug, post, display_code)
        end

      %{
        code: display_code,
        display_code: display_code,
        name: get_language_name(lang),
        flag: get_language_flag(lang),
        url: url,
        current: DialectMapper.extract_base(lang) == current_base,
        enabled: is_enabled,
        known: is_known
      }
    end)
  end

  # Order languages for public display: primary first, then enabled, then disabled
  defp order_languages_for_public(languages, enabled_languages, primary_language) do
    {enabled, disabled} =
      Enum.split_with(languages, fn lang ->
        language_enabled_for_public?(lang, enabled_languages)
      end)

    # Put primary first if present
    {primary, other_enabled} = Enum.split_with(enabled, &(&1 == primary_language))

    primary ++ Enum.sort(other_enabled) ++ Enum.sort(disabled)
  end

  # Remove legacy base code files when dialect files of the same language exist
  # This prevents showing both "en" and "en-CA" in the switcher
  defp deduplicate_base_and_dialect_files(languages, _enabled_languages) do
    # Separate base codes and dialect codes
    {base_codes, dialect_codes} = Enum.split_with(languages, &base_code?/1)

    # For each base code, check if any dialect files exist for it
    # If so, exclude the base code
    filtered_base_codes =
      Enum.reject(base_codes, fn base ->
        Enum.any?(dialect_codes, fn dialect ->
          DialectMapper.extract_base(dialect) == base
        end)
      end)

    # Return dialect codes plus any base codes that don't have dialect alternatives
    dialect_codes ++ filtered_base_codes
  end

  defp normalize_languages([], current_language), do: [current_language]
  defp normalize_languages(languages, _current_language) when is_list(languages), do: languages

  # Strict check for public display - only shows files that are:
  # 1. Directly in the enabled languages list, OR
  # 2. Base code files where any dialect of that base is enabled
  # This prevents showing en-US, en-GB etc when only en-CA is enabled
  defp language_enabled_for_public?(language, enabled_languages) do
    cond do
      # Direct match - file code exactly matches an enabled language
      language in enabled_languages ->
        true

      # Base code file (e.g., "en") - show if any dialect is enabled
      base_code?(language) ->
        Enum.any?(enabled_languages, fn enabled_lang ->
          DialectMapper.extract_base(enabled_lang) == language
        end)

      # Dialect file (e.g., "en-US") not directly enabled - DON'T show
      # This is the key difference from language_enabled?
      true ->
        false
    end
  end

  # Checks if the exact language file exists and is published
  # Uses preloaded language_statuses map to avoid redundant file reads
  defp translation_published_exact?(_blog_slug, post, language) do
    language in (post.available_languages || []) and
      Map.get(post.language_statuses, language) == "published"
  end

  defp build_breadcrumbs(blog_slug, post, language) do
    blog_name =
      case fetch_blog(blog_slug) do
        {:ok, blog} -> blog["name"]
        {:error, _} -> blog_slug
      end

    [
      %{label: blog_name, url: BlogHTML.blog_listing_path(language, blog_slug)},
      %{label: post.metadata.title, url: nil}
    ]
  end

  defp get_language_name(code) do
    case Languages.get_language(code) do
      %{"name" => name} -> name
      _ -> String.upcase(code)
    end
  end

  defp get_language_flag(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      _ -> "🌐"
    end
  end

  defp get_default_language do
    case Languages.get_default_language() do
      %{"code" => code} -> code
      _ -> "en"
    end
  end

  defp filter_published(posts) do
    Enum.filter(posts, fn post ->
      post.metadata.status == "published"
    end)
  end

  # Filter posts to only include those that have a matching language file
  # Handles both exact matches and base code matches (e.g., "en" matches "en-US")
  # Uses preloaded language_statuses to avoid redundant file reads
  defp filter_by_exact_language(posts, _blog_slug, language) do
    Enum.filter(posts, fn post ->
      # Find the matching language file (exact or base code match)
      matching_language = find_matching_language(language, post.available_languages)

      # Use preloaded status from language_statuses map
      matching_language != nil and
        Map.get(post.language_statuses, matching_language) == "published"
    end)
  end

  # Find a matching language in available languages
  # Handles exact matches and base code matching
  defp find_matching_language(language, available_languages) do
    cond do
      # Direct match
      language in available_languages ->
        language

      # Base code - find a dialect that matches
      base_code?(language) ->
        find_dialect_for_base_in_files(language, available_languages)

      # Full dialect not found - try base code match
      true ->
        base = DialectMapper.extract_base(language)
        find_dialect_for_base_in_files(base, available_languages)
    end
  end

  defp default_blog_listing(language) do
    case Publishing.list_groups() do
      [%{"slug" => slug} | _] -> BlogHTML.blog_listing_path(language, slug)
      _ -> nil
    end
  end

  defp paginate(posts, page, per_page) do
    posts
    |> Enum.drop((page - 1) * per_page)
    |> Enum.take(per_page)
  end

  defp get_page_param(params) do
    case Map.get(params, "page", "1") do
      page when is_binary(page) ->
        case Integer.parse(page) do
          {num, _} when num > 0 -> num
          _ -> 1
        end

      page when is_integer(page) and page > 0 ->
        page

      _ ->
        1
    end
  end

  defp get_per_page_setting do
    # Check new key first, fallback to legacy
    value =
      case Settings.get_setting_cached("publishing_posts_per_page") do
        nil -> Settings.get_setting_cached("blogging_posts_per_page")
        v -> v
      end

    case value do
      nil ->
        20

      v when is_binary(v) ->
        case Integer.parse(v) do
          {num, _} when num > 0 -> num
          _ -> 20
        end

      v when is_integer(v) and v > 0 ->
        v

      _ ->
        20
    end
  end

  defp public_enabled? do
    # Check new key first, fallback to legacy
    case Settings.get_setting("publishing_public_enabled") do
      nil -> Settings.get_boolean_setting("blogging_public_enabled", true)
      "true" -> true
      "false" -> false
      _ -> true
    end
  end

  # Checks if a specific post allows public access to older versions
  # Always reads from the master language's live version to ensure consistency
  defp post_allows_version_access?(blog_slug, post_slug, _language) do
    # Always read from master language to ensure per-post (not per-language) behavior
    master_language = Storage.get_master_language()

    # Read the live version (version: nil means get latest/live)
    case Publishing.read_post(blog_slug, post_slug, master_language, nil) do
      {:ok, post} ->
        Map.get(post.metadata, :allow_version_access, false)

      {:error, _} ->
        # If we can't read the live version, deny access
        false
    end
  end

  # Builds version dropdown data for the public post template
  # Returns nil if version access is disabled or only one published version exists
  # Uses listing cache for fast lookups instead of reading files
  defp build_version_dropdown(blog_slug, post, language) do
    # Try to get cached data first (sub-microsecond from :persistent_term)
    # The cache stores the live version with all version metadata
    {allow_access, live_version} = get_cached_version_info(blog_slug, post)

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
            url = build_version_url(blog_slug, post, language, version)

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

  # Gets version info from cache (allow_version_access and live_version)
  # Falls back to file reads if cache miss
  defp get_cached_version_info(blog_slug, current_post) do
    case ListingCache.find_post(blog_slug, current_post.slug) do
      {:ok, cached_post} ->
        # Cache stores the live version's metadata
        allow_access = Map.get(cached_post.metadata, :allow_version_access, false)
        live_version = cached_post.version
        {allow_access, live_version}

      {:error, _} ->
        # Cache miss - fall back to file reads
        master_language = Storage.get_master_language()
        allow_access = get_allow_access_from_file(blog_slug, current_post, master_language)
        live_version = get_live_version_from_file(blog_slug, current_post.slug)
        {allow_access, live_version}
    end
  end

  # Fallback: Gets allow_version_access from file when cache misses
  defp get_allow_access_from_file(blog_slug, current_post, master_language) do
    if current_post.language == master_language do
      Map.get(current_post.metadata, :allow_version_access, false)
    else
      case Publishing.read_post(blog_slug, current_post.slug, master_language, nil) do
        {:ok, master_post} -> Map.get(master_post.metadata, :allow_version_access, false)
        {:error, _} -> false
      end
    end
  end

  # Fallback: Gets published version from file when cache misses
  defp get_live_version_from_file(blog_slug, post_slug) do
    case Storage.get_published_version(blog_slug, post_slug) do
      {:ok, version} -> version
      {:error, _} -> nil
    end
  end

  # Builds URL for a specific version of a post
  defp build_version_url(blog_slug, post, language, version) do
    base_url = BlogHTML.build_post_url(blog_slug, post, language)
    "#{base_url}/v/#{version}"
  end

  defp log_404(conn, blog_slug, identifier, language, reason) do
    Logger.info("Blog 404",
      blog_slug: blog_slug,
      identifier: inspect(identifier),
      reason: reason,
      language: language,
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      path: conn.request_path
    )
  end

  defp handle_not_found(conn, reason) do
    # Try to fall back to nearest valid parent in the breadcrumb chain
    case attempt_breadcrumb_fallback(conn, reason) do
      {:ok, redirect_path} ->
        conn
        |> put_flash(
          :info,
          gettext("The page you requested was not found. Showing closest match.")
        )
        |> redirect(to: redirect_path)

      :no_fallback ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PhoenixKitWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp attempt_breadcrumb_fallback(conn, reason) do
    language = conn.assigns[:current_language] || "en"
    blog_slug = conn.params["blog"]
    path = conn.params["path"] || []

    # Build full path including blog slug for proper fallback handling
    # Route params are: %{"blog" => "date", "path" => ["2025-12-09", "15:02"]}
    # We need: ["date", "2025-12-09", "15:02"] for pattern matching
    full_path = if blog_slug, do: [blog_slug | path], else: path

    handle_fallback_case(reason, full_path, language)
  end

  # Slug mode posts (2-element path) - try other languages before blog listing
  defp handle_fallback_case(reason, [blog_slug, post_slug], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_to_default_language(blog_slug, post_slug, language)
  end

  # Timestamp mode posts (3-element path) - try other languages before blog listing
  defp handle_fallback_case(reason, [blog_slug, date, time], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_timestamp_to_other_language(blog_slug, date, time, language)
  end

  defp handle_fallback_case(:blog_not_found, [_blog_slug], language) do
    fallback_to_default_blog(language)
  end

  defp handle_fallback_case(:blog_not_found, [], language) do
    fallback_to_default_blog(language)
  end

  defp handle_fallback_case(_reason, _path, _language), do: :no_fallback

  defp fallback_to_default_blog(language) do
    case default_blog_listing(language) do
      nil -> :no_fallback
      path -> {:ok, path}
    end
  end

  defp fallback_to_default_language(blog_slug, post_slug, requested_language) do
    if blog_exists?(blog_slug) do
      find_any_available_language_version(blog_slug, post_slug, requested_language)
    else
      :no_fallback
    end
  end

  # Fallback for timestamp mode posts - comprehensive fallback chain:
  # 1. Try other languages for the exact date/time
  # 2. If time doesn't exist, try other times on the same date
  # 3. If date has no posts, fall back to blog listing
  defp fallback_timestamp_to_other_language(blog_slug, date, time, requested_language) do
    default_lang = get_default_language()

    if blog_exists?(blog_slug) do
      # Step 1: Try other languages for this exact time
      post_dir = Path.join([Storage.group_path(blog_slug), date, time])
      # Use version-aware language detection (handles both versioned and legacy)
      available = detect_available_languages_in_timestamp_dir(post_dir)

      # Time exists with language files - try other languages
      if available != [] do
        languages_to_try =
          ([default_lang | available] -- [requested_language])
          |> Enum.uniq()

        case find_first_published_timestamp_version(blog_slug, date, time, languages_to_try) do
          {:ok, url} ->
            {:ok, url}

          :not_found ->
            # No published version at this time - try other times on this date
            fallback_to_other_time_on_date(blog_slug, date, time, default_lang)
        end
      else
        # Time doesn't exist - try other times on this date
        fallback_to_other_time_on_date(blog_slug, date, time, default_lang)
      end
    else
      :no_fallback
    end
  end

  # Fallback to another time on the same date
  defp fallback_to_other_time_on_date(blog_slug, date, exclude_time, default_lang) do
    case Storage.list_times_on_date(blog_slug, date) do
      [] ->
        # No posts on this date at all - try other dates or fall back to blog listing
        fallback_to_other_date(blog_slug, default_lang)

      times ->
        # Filter out the time we already tried
        other_times = times -- [exclude_time]

        case find_first_published_time(blog_slug, date, other_times, default_lang) do
          {:ok, url} ->
            {:ok, url}

          :not_found ->
            # No published posts on this date - try other dates
            fallback_to_other_date(blog_slug, default_lang)
        end
    end
  end

  # No posts found on this date - fall back to blog listing
  # The blog listing will show all available posts
  defp fallback_to_other_date(blog_slug, default_lang) do
    {:ok, BlogHTML.blog_listing_path(default_lang, blog_slug)}
  end

  # Find the first published post at any of the given times
  defp find_first_published_time(blog_slug, date, times, preferred_lang) do
    Enum.find_value(times, fn time ->
      post_dir = Path.join([Storage.group_path(blog_slug), date, time])
      # Use version-aware language detection (handles both versioned and legacy)
      available = detect_available_languages_in_timestamp_dir(post_dir)

      if available != [] do
        # Try preferred language first, then others
        languages = [preferred_lang | available] |> Enum.uniq()

        case find_first_published_timestamp_version(blog_slug, date, time, languages) do
          {:ok, url} -> {:ok, url}
          :not_found -> nil
        end
      else
        nil
      end
    end) || :not_found
  end

  # Tries each language for timestamp mode until finding a published version
  # Handles both versioned and legacy structures
  defp find_first_published_timestamp_version(blog_slug, date, time, languages) do
    post_dir = Path.join([Storage.group_path(blog_slug), date, time])

    case Storage.detect_post_structure(post_dir) do
      :versioned ->
        find_first_published_versioned_timestamp(blog_slug, date, time, languages, post_dir)

      :legacy ->
        find_first_published_legacy_timestamp(blog_slug, date, time, languages)

      :empty ->
        :not_found
    end
  end

  # Find first published post in versioned timestamp structure
  # Iterates versions from highest to lowest, then tries each language
  defp find_first_published_versioned_timestamp(blog_slug, date, time, languages, post_dir) do
    versions = list_timestamp_versions(post_dir) |> Enum.sort(:desc)

    Enum.find_value(versions, fn version ->
      version_dir = Path.join(post_dir, "v#{version}")
      available_languages = detect_available_languages_in_dir(version_dir)

      # Try preferred languages first, then fall back to what's available
      languages_to_try =
        (languages ++ available_languages)
        |> Enum.uniq()
        |> Enum.filter(&(&1 in available_languages))

      Enum.find_value(languages_to_try, fn lang ->
        path = "#{blog_slug}/#{date}/#{time}/v#{version}/#{lang}.phk"

        case Publishing.read_post(blog_slug, path) do
          {:ok, post} when post.metadata.status == "published" ->
            {:ok, build_timestamp_url(blog_slug, date, time, lang)}

          _ ->
            nil
        end
      end)
    end) || :not_found
  end

  # Find first published post in legacy timestamp structure
  defp find_first_published_legacy_timestamp(blog_slug, date, time, languages) do
    Enum.find_value(languages, fn lang ->
      path = "#{blog_slug}/#{date}/#{time}/#{lang}.phk"

      case Publishing.read_post(blog_slug, path) do
        {:ok, post} when post.metadata.status == "published" ->
          {:ok, build_timestamp_url(blog_slug, date, time, lang)}

        _ ->
          nil
      end
    end) || :not_found
  end

  # Tries to find any available published language version of the post
  # Priority:
  # 1. Check for published versions in the SAME language first (across all versions)
  # 2. Then try other languages
  # 3. Falls back to blog listing if no published versions exist
  #
  # Note: fetch_post now handles finding the latest published version automatically,
  # so we can just use base URLs here (no version-specific URLs needed)
  defp find_any_available_language_version(blog_slug, post_slug, requested_language) do
    default_lang = get_default_language()

    # Find the post in the blog to get available languages
    case find_post_by_slug(blog_slug, post_slug) do
      {:ok, post} ->
        # The initial fetch failed, so we know no published version exists for the requested_language.
        # Proceed directly to trying other available languages.
        try_other_languages(blog_slug, post_slug, post, requested_language, default_lang)

      :not_found ->
        # Post doesn't exist at all - fall back to blog listing
        {:ok, BlogHTML.blog_listing_path(default_lang, blog_slug)}
    end
  end

  # Finds the latest published version for a specific language
  defp find_published_version_for_language(blog_slug, post_slug, language) do
    versions = Storage.list_versions(blog_slug, post_slug)

    published_version =
      versions
      |> Enum.sort(:desc)
      |> Enum.find(fn version ->
        Storage.get_version_status(blog_slug, post_slug, version, language) == "published"
      end)

    case published_version do
      nil -> :not_found
      version -> {:ok, version}
    end
  end

  # Tries other languages when requested language has no published versions
  defp try_other_languages(blog_slug, post_slug, post, requested_language, default_lang) do
    available = post.available_languages || []

    # Build priority list: default first, then others (excluding already-tried language)
    languages_to_try =
      ([default_lang | available] -- [requested_language])
      |> Enum.uniq()

    find_first_published_version(blog_slug, post_slug, post, languages_to_try, default_lang)
  end

  # Finds a post by its slug from the blog's post list
  defp find_post_by_slug(blog_slug, post_slug) do
    posts = Publishing.list_posts(blog_slug, nil)

    case Enum.find(posts, fn p -> p.slug == post_slug end) do
      nil -> :not_found
      post -> {:ok, post}
    end
  end

  # Tries each language in order until finding a published version
  # Uses find_published_version_for_language to check across all versions
  # fetch_post will automatically find the right version when the URL is visited
  defp find_first_published_version(blog_slug, post_slug, post, languages, fallback_lang) do
    result =
      Enum.find_value(languages, fn lang ->
        # Check if any published version exists for this language
        case find_published_version_for_language(blog_slug, post_slug, lang) do
          {:ok, _version} ->
            # Published version exists - use base URL
            # fetch_post will find the right version
            {:ok, BlogHTML.build_post_url(blog_slug, post, lang)}

          :not_found ->
            nil
        end
      end)

    # If no published version found, fall back to blog listing
    result || {:ok, BlogHTML.blog_listing_path(fallback_lang, blog_slug)}
  end

  defp blog_exists?(blog_slug) do
    case fetch_blog(blog_slug) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
