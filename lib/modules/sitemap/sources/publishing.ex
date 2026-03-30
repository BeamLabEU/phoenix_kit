defmodule PhoenixKit.Modules.Sitemap.Sources.Publishing do
  @moduledoc """
  Publishing source for sitemap generation.

  Collects published posts from the PhoenixKit Publishing system.
  Includes both group listing pages and individual post pages.

  ## URL Structure

  Uses PhoenixKit URL prefix from config:
  - Group listing: `/{prefix}/{group_slug}` (default language)
  - Group listing: `/{prefix}/{lang}/{group_slug}` (non-default language)

  For slug mode posts:
  - `/{prefix}/{group_slug}/{post_slug}` (default language)
  - `/{prefix}/{lang}/{group_slug}/{post_slug}` (non-default language)

  For timestamp mode posts:
  - Single post on date: `/{prefix}/{group_slug}/{date}` (e.g., /blog/2025-12-09)
  - Multiple posts on date: `/{prefix}/{group_slug}/{date}/{time}` (e.g., /blog/2025-12-09/16:26)

  ## Exclusion

  Posts can be excluded by setting `post.metadata.sitemap_exclude = true`.

  ## Sitemap Properties

  - Group listings:
    - Priority: 0.7
    - Change frequency: daily
    - Category: Group name

  - Individual posts:
    - Priority: 0.8
    - Change frequency: weekly
    - Category: Group name
    - Last modified: Post's date_updated or timestamp
  """

  @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

  @compile {:no_warn_undefined,
            [
              {PhoenixKit.Modules.Publishing, :enabled?, 0},
              {PhoenixKit.Modules.Publishing, :list_groups, 0},
              {PhoenixKit.Modules.Publishing, :list_posts, 2}
            ]}

  require Logger

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @publishing_mod PhoenixKit.Modules.Publishing

  @default_locale Config.default_locale()

  # Future: Hook into Publishing post creation/update to invalidate sitemap-publishing

  @impl true
  def source_name, do: :publishing

  @impl true
  def sitemap_filename, do: "sitemap-publishing"

  @doc """
  When `sitemap_publishing_split_by_group` is enabled, returns per-group sub-sitemaps.
  Otherwise returns nil (single file).
  """
  @impl true
  def sub_sitemaps(opts) do
    if split_by_group?() and enabled?() do
      base_url = Keyword.get(opts, :base_url)
      language = Keyword.get(opts, :language)
      is_default = Keyword.get(opts, :is_default_language, true)

      groups = @publishing_mod.list_groups()
      included_groups = Enum.reject(groups, &group_excluded?/1)

      sub_maps =
        included_groups
        |> Enum.map(fn group ->
          slug = group["slug"]

          entries =
            collect_group_listings([group], language, is_default, base_url) ++
              collect_group_posts(group, language, is_default, base_url)

          {slug, entries}
        end)
        |> Enum.reject(fn {_slug, entries} -> entries == [] end)

      if sub_maps == [], do: nil, else: sub_maps
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp split_by_group? do
    PhoenixKit.Settings.get_boolean_setting("sitemap_publishing_split_by_group", false)
  rescue
    _ -> false
  end

  @impl true
  def enabled? do
    Code.ensure_loaded?(@publishing_mod) and
      function_exported?(@publishing_mod, :enabled?, 0) and
      @publishing_mod.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    if enabled?() do
      base_url = Keyword.get(opts, :base_url)
      language = Keyword.get(opts, :language)
      is_default = Keyword.get(opts, :is_default_language, true)

      groups = @publishing_mod.list_groups()

      # Filter out groups with sitemap_exclude setting
      included_groups = Enum.reject(groups, &group_excluded?/1)

      group_listings = collect_group_listings(included_groups, language, is_default, base_url)

      group_posts =
        Enum.flat_map(included_groups, fn group ->
          collect_group_posts(group, language, is_default, base_url)
        end)

      group_listings ++ group_posts
    else
      []
    end
  rescue
    error ->
      Logger.warning("Publishing sitemap source failed to collect: #{inspect(error)}")

      []
  end

  # Check if group is excluded from sitemap via settings
  defp group_excluded?(group) do
    case group do
      %{"sitemap_exclude" => true} -> true
      %{"sitemap_exclude" => "true"} -> true
      %{"settings" => %{"sitemap_exclude" => true}} -> true
      %{"settings" => %{"sitemap_exclude" => "true"}} -> true
      _ -> false
    end
  end

  defp collect_group_listings(groups, language, is_default, base_url) do
    groups
    |> Enum.filter(fn group -> group_has_posts_for_language?(group, language) end)
    |> Enum.map(fn group ->
      slug = group["slug"]
      name = group["name"]
      # Canonical path without language prefix (for hreflang grouping)
      canonical_path = build_group_path([slug], nil, true)
      path = build_group_path([slug], language, is_default)
      url = build_url(path, base_url)

      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: "daily",
        priority: 0.7,
        title: name,
        category: name,
        source: :publishing,
        canonical_path: canonical_path
      })
    end)
  rescue
    error ->
      Logger.warning("Failed to collect group listings: #{inspect(error)}")

      []
  end

  # Check if a group has at least one published post for the given language
  defp group_has_posts_for_language?(group, language) do
    slug = group["slug"]
    post_language = language || get_default_language()

    @publishing_mod.list_posts(slug, post_language)
    |> Enum.filter(&published?/1)
    |> Enum.reject(&excluded?/1)
    |> Enum.any?(fn post -> has_translation?(post, language) end)
  rescue
    _ -> false
  end

  defp collect_group_posts(group, language, is_default, base_url) do
    slug = group["slug"]
    name = group["name"]
    post_language = language || get_default_language()

    posts =
      @publishing_mod.list_posts(slug, post_language)
      |> Enum.filter(&published?/1)
      |> Enum.reject(&excluded?/1)
      |> Enum.filter(fn post -> has_translation?(post, language) end)

    # Optimization: Pre-compute date counts for timestamp mode posts
    date_counts = build_date_counts_cache(posts)

    Enum.map(posts, fn post ->
      build_post_entry(post, slug, name, language, is_default, base_url, date_counts)
    end)
  rescue
    error ->
      Logger.warning(
        "Failed to collect posts for group #{inspect(group["slug"])}: #{inspect(error)}"
      )

      []
  end

  # Build a map of date -> post count for timestamp mode posts
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

  defp build_post_entry(post, group_slug, group_name, language, is_default, base_url, date_counts) do
    # Canonical path without language prefix (for hreflang grouping)
    canonical_path = build_post_path(post, group_slug, nil, true, date_counts)
    path = build_post_path(post, group_slug, language, is_default, date_counts)
    url = build_url(path, base_url)

    title = get_post_title(post)
    lastmod = get_post_lastmod(post)

    UrlEntry.new(%{
      loc: url,
      lastmod: lastmod,
      changefreq: "weekly",
      priority: 0.8,
      title: title,
      category: group_name,
      source: :publishing,
      canonical_path: canonical_path
    })
  end

  # Build post path based on mode (slug vs timestamp)
  # Uses pre-computed date_counts cache instead of per-post queries
  defp build_post_path(post, group_slug, language, is_default, date_counts) do
    case post.mode do
      :timestamp ->
        # For timestamp mode, use date (and time if multiple posts on same date)
        date = extract_date_for_url(post)
        post_count = Map.get(date_counts, date, 1)

        if post_count > 1 do
          # Multiple posts on this date - include time
          time = extract_time_for_url(post)
          build_group_path([group_slug, date, time], language, is_default)
        else
          # Single post on this date - date only
          build_group_path([group_slug, date], language, is_default)
        end

      :slug ->
        # For slug mode, use the post slug
        post_slug = post.slug || extract_slug_from_path(post.path)
        build_group_path([group_slug, post_slug], language, is_default)

      _ ->
        # Fallback to slug mode behavior
        post_slug = post.slug || extract_slug_from_path(post.path)
        build_group_path([group_slug, post_slug], language, is_default)
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
      _ -> "Post"
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

  # Build group path with PhoenixKit prefix and optional language
  # Format: /{prefix}/{lang?}/{segments...}
  # When in single language mode, no language prefix is added for anyone
  # When in multi-language mode, ALL languages get prefix (including default)
  defp build_group_path(segments, language, _is_default) do
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
  # Mirrors PublishingHTML.single_language_mode?/0 logic
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
