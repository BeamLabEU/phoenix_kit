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

  alias PhoenixKit.Blogging.Renderer
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.BlogHTML
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

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

    if Blogging.enabled?() and public_enabled?() do
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

            {:error, reason} ->
              handle_not_found(conn, reason)
          end
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # Fallback for routes without language parameter (shouldn't happen with new routing)
  def show(conn, params) do
    language = get_default_language()
    conn = assign(conn, :current_language, language)

    if Blogging.enabled?() and public_enabled?() do
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

            {:error, reason} ->
              handle_not_found(conn, reason)
          end
      end
    else
      handle_not_found(conn, :module_disabled)
    end
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
    # Check if this looks like a valid language code
    if valid_language?(language_param) do
      # It's a real language code - use as-is
      {language_param, params}
    else
      # It's actually a blog slug - shift parameters
      # language_param becomes the blog, and what was 'blog' becomes part of path
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

    # Check if it's an enabled language code (full dialect like en-US)
    # OR if it's a valid base code (like en) that maps to an enabled dialect
    cond do
      Languages.language_enabled?(code) ->
        true

      # Check if it's a base code that maps to an enabled dialect
      String.length(code) == 2 and not String.contains?(code, "-") ->
        dialect = DialectMapper.base_to_dialect(code)
        Languages.language_enabled?(dialect)

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_language?(_), do: false

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

          # List posts that have this EXACT language file and are published
          all_posts =
            Blogging.list_posts(blog_slug, language)
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

            # Build translation links for blog listing
            translations = build_listing_translations(blog_slug, language)

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
            # Render markdown
            html_content = render_markdown(post.content)

            # Build translation links
            translations = build_translation_links(blog_slug, post, canonical_language)

            # Build breadcrumbs
            breadcrumbs = build_breadcrumbs(blog_slug, post, canonical_language)

            conn
            |> assign(:page_title, post.metadata.title)
            |> assign(:blog_slug, blog_slug)
            |> assign(:post, post)
            |> assign(:html_content, html_content)
            |> assign(:current_language, canonical_language)
            |> assign(:translations, translations)
            |> assign(:breadcrumbs, breadcrumbs)
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

    case Enum.find(Blogging.list_blogs(), fn blog ->
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

  defp fetch_post(blog_slug, {:slug, post_slug}, language) do
    case Blogging.read_post(blog_slug, post_slug, language) do
      {:ok, post} -> {:ok, post}
      _ -> {:error, :post_not_found}
    end
  end

  defp fetch_post(blog_slug, {:timestamp, date, time}, language) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # First, detect available languages for this post
    post_dir = Path.join([Storage.root_path(), blog_slug, date, time])
    available_languages = detect_available_languages_in_dir(post_dir)

    # Resolve the language - find matching dialect in available languages
    resolved_language = resolve_language_for_post(language, available_languages)

    # Build path for timestamp mode: blog/date/time/language.phk
    path = "#{blog_slug}/#{date}/#{time}/#{resolved_language}.phk"

    case Blogging.read_post(blog_slug, path) do
      {:ok, post} -> {:ok, post}
      _ -> {:error, :post_not_found}
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

  # Resolve a language code to an actual file language
  # Handles base codes by finding a matching dialect in available languages
  defp resolve_language_for_post(language, available_languages) do
    alias PhoenixKit.Modules.Languages.DialectMapper

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
    alias PhoenixKit.Modules.Languages.DialectMapper
    base_lower = String.downcase(base_code)

    Enum.find(available_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  defp render_markdown(content) do
    Renderer.render_markdown(content)
  end

  # Gets the canonical URL language code for a given language.
  # If multiple dialects of the same base language are enabled, returns the full dialect.
  # Otherwise returns the base code for cleaner URLs.
  defp get_canonical_url_language(language) do
    alias PhoenixKit.Modules.Languages.DialectMapper

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
    alias PhoenixKit.Modules.Languages.DialectMapper
    base_lower = String.downcase(base_code)

    Enum.find(enabled_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  defp build_listing_translations(blog_slug, current_language) do
    alias PhoenixKit.Modules.Languages.DialectMapper
    alias PhoenixKitWeb.Live.Modules.Blogging.Storage

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
        # Check if this specific language has published content
        has_published_content_for_language?(blog_slug, lang)
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
  defp has_published_content_for_language?(blog_slug, language) do
    # Get all posts and check if any have published content for this EXACT language
    all_posts = Blogging.list_posts(blog_slug, nil)

    Enum.any?(all_posts, fn post ->
      # Check if there's a published file for this EXACT language only
      post.available_languages
      |> Enum.any?(fn file_lang ->
        # Only match exact language - no base code matching
        file_lang == language and lang_published?(blog_slug, post, file_lang)
      end)
    end)
  end

  # Check if a specific language version of a post is published
  defp lang_published?(blog_slug, post, language) do
    # If this is the post's current language, check its metadata directly
    if post.language == language do
      post.metadata.status == "published"
    else
      # Need to read the language-specific file to check its status
      lang_path =
        case post.mode do
          :slug ->
            "#{blog_slug}/#{post.slug}/#{language}.phk"

          :timestamp when not is_nil(post.date) and not is_nil(post.time) ->
            date_str = Date.to_iso8601(post.date)
            time_str = post.time |> Time.to_string() |> String.slice(0..4)
            "#{blog_slug}/#{date_str}/#{time_str}/#{language}.phk"

          _ ->
            # Can't build path for timestamp mode without date/time
            nil
        end

      if lang_path do
        case Blogging.read_post(blog_slug, lang_path) do
          {:ok, lang_post} -> lang_post.metadata.status == "published"
          _ -> false
        end
      else
        false
      end
    end
  end

  defp build_translation_links(blog_slug, post, current_language) do
    alias PhoenixKit.Modules.Languages.DialectMapper
    alias PhoenixKitWeb.Live.Modules.Blogging.Storage

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

    # Filter available languages to only show ones that:
    # 1. Actually exist as files (from post.available_languages)
    # 2. Are directly enabled OR are a base code with an enabled dialect
    # 3. Are published (exact file check, no fallback)
    available_and_published =
      post.available_languages
      |> normalize_languages(current_language)
      |> Enum.filter(fn lang ->
        language_enabled_for_public?(lang, enabled_languages) and
          translation_published_exact?(blog_slug, post, lang)
      end)

    # Remove legacy base code files when dialect files exist
    # e.g., if both "en" and "en-CA" exist, remove "en" to avoid duplicates
    deduplicated =
      deduplicate_base_and_dialect_files(available_and_published, enabled_languages)

    # Order: primary first, then the rest alphabetically
    languages =
      if primary_language in deduplicated do
        others =
          deduplicated
          |> Enum.reject(&(&1 == primary_language))
          |> Enum.sort()

        [primary_language] ++ others
      else
        Enum.sort(deduplicated)
      end

    Enum.map(languages, fn lang ->
      # Use display_code helper to determine if we show base or full code
      display_code = Storage.get_display_code(lang, enabled_languages)

      %{
        code: display_code,
        display_code: display_code,
        name: get_language_name(lang),
        flag: get_language_flag(lang),
        url: BlogHTML.build_post_url(blog_slug, post, display_code),
        current: DialectMapper.extract_base(lang) == current_base
      }
    end)
  end

  # Remove legacy base code files when dialect files of the same language exist
  # This prevents showing both "en" and "en-CA" in the switcher
  defp deduplicate_base_and_dialect_files(languages, _enabled_languages) do
    alias PhoenixKit.Modules.Languages.DialectMapper

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
    alias PhoenixKit.Modules.Languages.DialectMapper

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
  # Does not consider fallback/alias files - only the exact file path
  # Used for building public translation links to show only actual files
  defp translation_published_exact?(_blog_slug, post, language) do
    alias PhoenixKitWeb.Live.Modules.Blogging.Metadata

    # Build the exact file path from the post's full_path
    # Replace the language portion of the filename
    exact_file_path =
      post.full_path
      |> Path.dirname()
      |> Path.join("#{language}.phk")

    # Check if the exact file exists and is published
    with true <- File.exists?(exact_file_path),
         {:ok, contents} <- File.read(exact_file_path),
         {:ok, metadata, _content} <- Metadata.parse_with_content(contents) do
      metadata[:status] == "published"
    else
      _ -> false
    end
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
  defp filter_by_exact_language(posts, blog_slug, language) do
    Enum.filter(posts, fn post ->
      # Find the matching language file (exact or base code match)
      matching_language = find_matching_language(language, post.available_languages)

      matching_language != nil and lang_published?(blog_slug, post, matching_language)
    end)
  end

  # Find a matching language in available languages
  # Handles exact matches and base code matching
  defp find_matching_language(language, available_languages) do
    alias PhoenixKit.Modules.Languages.DialectMapper

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
    case Blogging.list_blogs() do
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
    case Settings.get_setting("blogging_posts_per_page") do
      nil ->
        20

      value when is_binary(value) ->
        case Integer.parse(value) do
          {num, _} when num > 0 -> num
          _ -> 20
        end

      value when is_integer(value) and value > 0 ->
        value

      _ ->
        20
    end
  end

  defp public_enabled? do
    Settings.get_boolean_setting("blogging_public_enabled", true)
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

  defp handle_fallback_case(reason, [blog_slug, _post_identifier], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_to_blog_or_overview(blog_slug, language)
  end

  defp handle_fallback_case(reason, [blog_slug, _date, _time], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_to_blog_or_overview(blog_slug, language)
  end

  defp handle_fallback_case(:blog_not_found, [_blog_slug], language) do
    fallback_to_default_blog(language)
  end

  defp handle_fallback_case(:blog_not_found, [], language) do
    fallback_to_default_blog(language)
  end

  defp handle_fallback_case(:post_not_found, [blog_slug, post_slug], language) do
    fallback_to_default_language(blog_slug, post_slug, language)
  end

  defp handle_fallback_case(_reason, _path, _language), do: :no_fallback

  defp fallback_to_default_blog(language) do
    case default_blog_listing(language) do
      nil -> :no_fallback
      path -> {:ok, path}
    end
  end

  defp fallback_to_blog_or_overview(blog_slug, language) do
    if blog_exists?(blog_slug) do
      {:ok, BlogHTML.blog_listing_path(language, blog_slug)}
    else
      case default_blog_listing(language) do
        nil -> :no_fallback
        path -> {:ok, path}
      end
    end
  end

  defp fallback_to_default_language(blog_slug, post_slug, language) do
    default_lang = get_default_language()

    if language != default_lang and blog_exists?(blog_slug) do
      # Try the post in default language
      case Blogging.read_post(blog_slug, post_slug, default_lang) do
        {:ok, post} when post.metadata.status == "published" ->
          {:ok, BlogHTML.build_post_url(blog_slug, post, default_lang)}

        _ ->
          # Post doesn't exist in default language either, go to blog listing
          {:ok, BlogHTML.blog_listing_path(default_lang, blog_slug)}
      end
    else
      :no_fallback
    end
  end

  defp blog_exists?(blog_slug) do
    case fetch_blog(blog_slug) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
