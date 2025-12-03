defmodule PhoenixKit.Sitemap.Sources.Blogging do
  @moduledoc """
  Blogging source for sitemap generation.

  Collects published blog posts from the PhoenixKit Blogging system.
  Includes both blog listing pages and individual post pages.

  ## URL Structure

  Uses PhoenixKit URL prefix from config:
  - Blog listing: `/{prefix}/{blog_slug}` (default language)
  - Blog listing: `/{prefix}/{lang}/{blog_slug}` (non-default language)
  - Individual posts: `/{prefix}/{blog_slug}/{post_slug}` (default language)
  - Individual posts: `/{prefix}/{lang}/{blog_slug}/{post_slug}` (non-default language)

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

  @behaviour PhoenixKit.Sitemap.Sources.Source

  alias PhoenixKit.Config
  alias PhoenixKit.Sitemap.UrlEntry
  alias PhoenixKitWeb.Live.Modules.Blogging

  @impl true
  def source_name, do: :blogging

  @impl true
  def enabled? do
    Blogging.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    if enabled?() do
      base_url = Keyword.get(opts, :base_url)
      language = Keyword.get(opts, :language)

      blogs = Blogging.list_blogs()

      blog_listings = collect_blog_listings(blogs, language, base_url)

      blog_posts =
        Enum.flat_map(blogs, fn blog -> collect_blog_posts(blog, language, base_url) end)

      blog_listings ++ blog_posts
    else
      []
    end
  rescue
    error ->
      require Logger

      Logger.warning("Blogging sitemap source failed to collect: #{inspect(error)}")

      []
  end

  defp collect_blog_listings(blogs, language, base_url) do
    Enum.map(blogs, fn blog ->
      slug = blog["slug"]
      name = blog["name"]
      path = build_blog_path([slug], language)
      url = build_url(path, base_url)

      UrlEntry.new(%{
        loc: url,
        lastmod: nil,
        changefreq: "daily",
        priority: 0.7,
        title: "#{name} - Blog",
        category: name,
        source: :blogging
      })
    end)
  rescue
    error ->
      require Logger

      Logger.warning("Failed to collect blog listings: #{inspect(error)}")

      []
  end

  defp collect_blog_posts(blog, language, base_url) do
    slug = blog["slug"]
    name = blog["name"]
    post_language = language || get_default_language()

    Blogging.list_posts(slug, post_language)
    |> Enum.filter(&published?/1)
    |> Enum.reject(&excluded?/1)
    |> Enum.map(fn post ->
      build_post_entry(post, slug, name, language, base_url)
    end)
  rescue
    error ->
      require Logger

      Logger.warning(
        "Failed to collect posts for blog #{inspect(blog["slug"])}: #{inspect(error)}"
      )

      []
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

  defp build_post_entry(post, blog_slug, blog_name, language, base_url) do
    post_slug = post.slug || extract_slug_from_path(post.path)
    path = build_blog_path([blog_slug, post_slug], language)
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
      source: :blogging
    })
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
      %{metadata: %{date_updated: dt}} -> parse_datetime(dt)
      %{metadata: %{"date_updated" => dt}} -> parse_datetime(dt)
      %{metadata: %{updated_at: dt}} -> parse_datetime(dt)
      %{metadata: %{"updated_at" => dt}} -> parse_datetime(dt)
      %{date: date, time: time} when not is_nil(date) -> combine_date_time(date, time)
      %{date: date} when not is_nil(date) -> date
      _ -> nil
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
  defp build_blog_path(segments, language) do
    prefix_parts = url_prefix_segments()

    # Add language if not default
    lang_parts =
      if language && not default_language?(language) do
        [language]
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

  # Check if language is the default (first admin language)
  defp default_language?(language) do
    default = get_default_language()
    language == default or extract_base(language) == extract_base(default)
  end

  # Get default language from admin settings
  defp get_default_language do
    admin_languages_json =
      PhoenixKit.Settings.get_setting("admin_languages", Jason.encode!(["en-US"]))

    case Jason.decode(admin_languages_json) do
      {:ok, [first | _]} -> extract_base(first)
      _ -> "en"
    end
  end

  # Extract base language code (e.g., "en" from "en-US")
  defp extract_base(code) when is_binary(code) do
    code |> String.split("-") |> List.first() |> String.downcase()
  end

  defp extract_base(_), do: "en"

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
