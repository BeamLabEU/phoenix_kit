defmodule PhoenixKit.Modules.Sitemap.Sources.Publishing do
  @moduledoc """
  Publishing source for sitemap generation.

  Collects published posts from the PhoenixKit Publishing system.
  Includes both group listing pages and individual post pages.

  ## URL Structure

  Uses PhoenixKit URL prefix from config:
  - Blog listing: `/{prefix}/{blog_slug}` (default language)
  - Blog listing: `/{prefix}/{lang}/{blog_slug}` (non-default language)

  For slug mode posts:
  - `/{prefix}/{blog_slug}/{post_slug}` (default language)
  - `/{prefix}/{lang}/{blog_slug}/{post_slug}` (non-default language)

  For timestamp mode posts:
  - Single post on date: `/{prefix}/{blog_slug}/{date}` (e.g., /blog/2025-12-09)
  - Multiple posts on date: `/{prefix}/{blog_slug}/{date}/{time}` (e.g., /blog/2025-12-09/16:26)

  ## Exclusion

  Posts can be excluded by setting `post.metadata.sitemap_exclude = true`.

  ## Sitemap Properties

  - Blog listings:
    - Priority: 0.7
    - Change frequency: daily
    - Category: Blog name

  - Individual posts:
    - Priority: 0.8
    - Change frequency: weekly
    - Category: Blog name
    - Last modified: Post's date_updated or timestamp
  """

  @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

  require Logger

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @default_locale Config.default_locale()

  @impl true
  def source_name, do: :publishing

  @impl true
  def enabled? do
    Publishing.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    if enabled?() do
      base_url = Keyword.get(opts, :base_url)
      language = Keyword.get(opts, :language)
      is_default = Keyword.get(opts, :is_default_language, true)

      blogs = Publishing.list_groups()

      # Filter out blogs with sitemap_exclude setting
      included_blogs = Enum.reject(blogs, &blog_excluded?/1)

      blog_listings = collect_blog_listings(included_blogs, language, is_default, base_url)

      blog_posts =
        Enum.flat_map(included_blogs, fn blog ->
          collect_blog_posts(blog, language, is_default, base_url)
        end)

      blog_listings ++ blog_posts
    else
      []
    end
  rescue
    error ->
      Logger.warning("Publishing sitemap source failed to collect: #{inspect(error)}")

      []
  end

  # Check if blog is excluded from sitemap via settings
  defp blog_excluded?(blog) do
    case blog do
      %{"sitemap_exclude" => true} -> true
      %{"sitemap_exclude" => "true"} -> true
      %{"settings" => %{"sitemap_exclude" => true}} -> true
      %{"settings" => %{"sitemap_exclude" => "true"}} -> true
      _ -> false
    end
  end

  defp collect_blog_listings(blogs, language, is_default, base_url) do
    blogs
    |> Enum.filter(fn blog -> blog_has_posts_for_language?(blog, language) end)
    |> Enum.map(fn blog ->
      slug = blog["slug"]
      name = blog["name"]
      # Canonical path without language prefix (for hreflang grouping)
      canonical_path = build_blog_path([slug], nil, true)
      path = build_blog_path([slug], language, is_default)
      url = build_url(path, base_url)

      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: "daily",
        priority: 0.7,
        title: "#{name} - Blog",
        category: name,
        source: :publishing,
        canonical_path: canonical_path
      })
    end)
  rescue
    error ->
      Logger.warning("Failed to collect blog listings: #{inspect(error)}")

      []
  end

  # Check if a blog has at least one published post for the given language
  defp blog_has_posts_for_language?(blog, language) do
    slug = blog["slug"]
    post_language = language || get_default_language()

    Publishing.list_posts(slug, post_language)
    |> Enum.filter(&published?/1)
    |> Enum.reject(&excluded?/1)
    |> Enum.any?(fn post -> has_translation?(post, language) end)
  rescue
    _ -> false
  end

  defp collect_blog_posts(blog, language, is_default, base_url) do
    slug = blog["slug"]
    name = blog["name"]
    post_language = language || get_default_language()

    posts =
      Publishing.list_posts(slug, post_language)
      |> Enum.filter(&published?/1)
      |> Enum.reject(&excluded?/1)
      |> Enum.filter(fn post -> has_translation?(post, language) end)

    # Optimization: Pre-compute date counts for timestamp mode posts
    # This avoids N filesystem reads (one per post) by doing one pass
    date_counts = build_date_counts_cache(posts)

    Enum.map(posts, fn post ->
      build_post_entry(post, slug, name, language, is_default, base_url, date_counts)
    end)
  rescue
    error ->
      Logger.warning(
        "Failed to collect posts for blog #{inspect(blog["slug"])}: #{inspect(error)}"
      )

      []
  end

  # Build a map of date -> post count for timestamp mode posts
  # This replaces N calls to Storage.count_posts_on_date with O(n) in-memory operation
  defp build_date_counts_cache(posts) do
    posts
    |> Enum.filter(fn post -> post.mode == :timestamp end)
    |> Enum.map(&extract_date_for_url/1)
    |> Enum.frequencies()
  end

  defp published?(post) do
    case post do
      %{metadata: %{status: "published"}} -> true
      %{metadata: %{"status" => "published"}} -> true
      _ -> false
    end
  end

  defp excluded?(post) do
    case post do
      %{metadata: %{sitemap_exclude: true}} -> true
      %{metadata: %{"sitemap_exclude" => true}} -> true
      %{metadata: %{sitemap_exclude: "true"}} -> true
      %{metadata: %{"sitemap_exclude" => "true"}} -> true
      _ -> false
    end
  end

  # Check if post has translation for the requested language.
  # Returns true if:
  # - language is nil (default language request, always include)
  # - language matches one of available_languages (exact or base code match)
  defp has_translation?(_post, nil), do: true

  defp has_translation?(post, language) do
    available = Map.get(post, :available_languages, [])
    base_lang = Languages.DialectMapper.extract_base(language)

    Enum.any?(available, fn lang ->
      lang == language || Languages.DialectMapper.extract_base(lang) == base_lang
    end)
  end

  defp build_post_entry(post, blog_slug, blog_name, language, is_default, base_url, date_counts) do
    # Canonical path without language prefix (for hreflang grouping)
    canonical_path = build_post_path(post, blog_slug, nil, true, date_counts)
    path = build_post_path(post, blog_slug, language, is_default, date_counts)
    url = build_url(path, base_url)

    title = get_post_title(post)
    lastmod = get_post_lastmod(post)

    UrlEntry.new(%{
      loc: url,
      lastmod: lastmod,
      changefreq: "weekly",
      priority: 0.8,
      title: title,
      category: blog_name,
      source: :publishing,
      canonical_path: canonical_path
    })
  end

  # Build post path based on mode (slug vs timestamp)
  # Uses pre-computed date_counts cache instead of Storage.count_posts_on_date
  defp build_post_path(post, blog_slug, language, is_default, date_counts) do
    case post.mode do
      :timestamp ->
        # For timestamp mode, use date (and time if multiple posts on same date)
        date = extract_date_for_url(post)
        # Use cached count instead of filesystem read
        post_count = Map.get(date_counts, date, 1)

        if post_count > 1 do
          # Multiple posts on this date - include time
          time = extract_time_for_url(post)
          build_blog_path([blog_slug, date, time], language, is_default)
        else
          # Single post on this date - date only
          build_blog_path([blog_slug, date], language, is_default)
        end

      :slug ->
        # For slug mode, use the post slug
        post_slug = post.slug || extract_slug_from_path(post.path)
        build_blog_path([blog_slug, post_slug], language, is_default)

      _ ->
        # Fallback to slug mode behavior
        post_slug = post.slug || extract_slug_from_path(post.path)
        build_blog_path([blog_slug, post_slug], language, is_default)
    end
  end

  # Extract date string for URL from post (YYYY-MM-DD format)
  defp extract_date_for_url(post) do
    cond do
      # First try post.date (set for timestamp mode posts)
      not is_nil(post.date) ->
        Date.to_iso8601(post.date)

      # Then try metadata.published_at
      is_binary(Map.get(post.metadata, :published_at)) ->
        case DateTime.from_iso8601(post.metadata.published_at) do
          {:ok, dt, _} -> Date.to_iso8601(DateTime.to_date(dt))
          _ -> "2025-01-01"
        end

      is_binary(Map.get(post.metadata, "published_at")) ->
        case DateTime.from_iso8601(post.metadata["published_at"]) do
          {:ok, dt, _} -> Date.to_iso8601(DateTime.to_date(dt))
          _ -> "2025-01-01"
        end

      true ->
        "2025-01-01"
    end
  end

  # Extract time string for URL from post (HH:MM format)
  defp extract_time_for_url(post) do
    cond do
      # First try post.time (set for timestamp mode posts)
      not is_nil(post.time) ->
        post.time |> Time.truncate(:second) |> Time.to_string() |> String.slice(0..4)

      # Then try metadata.published_at
      is_binary(Map.get(post.metadata, :published_at)) ->
        case DateTime.from_iso8601(post.metadata.published_at) do
          {:ok, dt, _} ->
            dt
            |> DateTime.to_time()
            |> Time.truncate(:second)
            |> Time.to_string()
            |> String.slice(0..4)

          _ ->
            "00:00"
        end

      is_binary(Map.get(post.metadata, "published_at")) ->
        case DateTime.from_iso8601(post.metadata["published_at"]) do
          {:ok, dt, _} ->
            dt
            |> DateTime.to_time()
            |> Time.truncate(:second)
            |> Time.to_string()
            |> String.slice(0..4)

          _ ->
            "00:00"
        end

      true ->
        "00:00"
    end
  end

  defp extract_slug_from_path(path) do
    path
    |> Path.basename(".md")
    |> String.trim()
  end

  defp get_post_title(post) do
    case post do
      %{metadata: %{title: title}} when is_binary(title) -> title
      %{metadata: %{"title" => title}} when is_binary(title) -> title
      %{slug: slug} when is_binary(slug) -> format_slug(slug)
      _ -> "Blog Post"
    end
  end

  defp get_post_lastmod(post) do
    case post do
      # Check metadata fields first (PhoenixKit Publishing uses published_at)
      %{metadata: %{published_at: dt}} when not is_nil(dt) and dt != "" ->
        parse_datetime(dt)

      %{metadata: %{"published_at" => dt}} when not is_nil(dt) and dt != "" ->
        parse_datetime(dt)

      %{metadata: %{date_updated: dt}} ->
        parse_datetime(dt)

      %{metadata: %{"date_updated" => dt}} ->
        parse_datetime(dt)

      %{metadata: %{updated_at: dt}} ->
        parse_datetime(dt)

      %{metadata: %{"updated_at" => dt}} ->
        parse_datetime(dt)

      # Fallback to post date/time fields (timestamp mode)
      %{date: date, time: time} when not is_nil(date) ->
        combine_date_time(date, time)

      %{date: date} when not is_nil(date) ->
        date

      _ ->
        nil
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(%Date{} = d), do: d

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        case Date.from_iso8601(str) do
          {:ok, d} -> d
          _ -> nil
        end
    end
  end

  defp parse_datetime(_), do: nil

  defp combine_date_time(%Date{} = date, nil) do
    date
  end

  defp combine_date_time(%Date{} = date, %Time{} = time) do
    DateTime.new!(date, time)
  rescue
    _ -> date
  end

  defp combine_date_time(date, _), do: date

  defp format_slug(slug) do
    slug
    |> String.replace("-", " ")
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Build blog path with PhoenixKit prefix and optional language
  # Format: /{prefix}/{lang?}/{segments...}
  # When in single language mode, no language prefix is added for anyone
  # When in multi-language mode, ALL languages get prefix (including default)
  defp build_blog_path(segments, language, _is_default) do
    prefix_parts = url_prefix_segments()

    # Add language prefix when:
    # 1. Language is specified
    # 2. Multiple languages are enabled (not single language mode)
    lang_parts =
      if language && !single_language_mode?() do
        # Use display code to match controller's canonical URL logic
        # This returns base code ("en") when single dialect enabled,
        # or full code ("en-US") when multiple dialects enabled
        [get_display_code(language)]
      else
        []
      end

    all_parts =
      prefix_parts ++
        lang_parts ++
        (segments
         |> Enum.reject(&(&1 in [nil, ""]))
         |> Enum.map(&to_string/1))

    case all_parts do
      [] -> "/"
      _ -> "/" <> Enum.join(all_parts, "/")
    end
  end

  # Get URL prefix segments from config
  defp url_prefix_segments do
    Config.get_url_prefix()
    |> case do
      "/" -> []
      prefix -> prefix |> String.trim("/") |> String.split("/", trim: true)
    end
  end

  # Check if we're in single language mode (no locale prefix needed)
  # Returns true when languages module is off OR only one language is enabled
  # Mirrors BlogHTML.single_language_mode?/0 logic
  defp single_language_mode? do
    not Languages.enabled?() or length(Languages.get_enabled_languages()) <= 1
  rescue
    _ -> true
  end

  # Get default language from admin settings
  defp get_default_language do
    case PhoenixKit.Settings.get_json_setting_cached("admin_languages", [@default_locale]) do
      [first | _] -> Languages.DialectMapper.extract_base(first)
      _ -> "en"
    end
  end

  # Get the display code for a language, matching the controller's canonical URL logic.
  # Returns base code ("en") when only one dialect is enabled,
  # or full code ("en-US") when multiple dialects of same language are enabled.
  # This mirrors Storage.get_display_code/2 to ensure sitemap URLs match canonical URLs.
  defp get_display_code(language_code) do
    base_code = Languages.DialectMapper.extract_base(language_code)
    enabled_languages = Languages.get_enabled_languages()

    # Count how many enabled languages share this base code
    dialects_count =
      Enum.count(enabled_languages, fn lang ->
        Languages.DialectMapper.extract_base(lang) == base_code
      end)

    # If more than one dialect of this base language is enabled, show full code
    if dialects_count > 1 do
      language_code
    else
      base_code
    end
  rescue
    _ -> Languages.DialectMapper.extract_base(language_code)
  end

  # Build full URL from path and base_url
  defp build_url(path, nil) do
    # Fallback to site_url from settings
    base = PhoenixKit.Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_url(path, base_url) when is_binary(base_url) do
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end
end
