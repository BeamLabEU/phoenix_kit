defmodule PhoenixKit.Sitemap.Sources.Posts do
  @moduledoc """
  Posts source for sitemap generation.

  Collects public posts from the PhoenixKit Posts system.
  Automatically detects if public routes exist for posts.

  ## URL Structure

  - Posts index: `/posts` (or with language prefix for non-default: `/et/posts`)
  - Individual posts: `/posts/:slug` (or `/et/posts/:slug`)

  ## Enabling

  This source is enabled when:
  1. Posts module is enabled (`posts_enabled` setting)
  2. Public routes exist for posts in the parent router

  ## Exclusion

  Posts can be excluded by setting `post.metadata["sitemap_exclude"] = true`.

  ## Sitemap Properties

  - Posts index:
    - Priority: 0.7
    - Change frequency: daily
    - Category: "Posts"

  - Individual posts:
    - Priority: 0.8
    - Change frequency: weekly
    - Category: "Posts"
    - Last modified: Post's updated_at or published_at
  """

  @behaviour PhoenixKit.Sitemap.Sources.Source

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap.RouteResolver
  alias PhoenixKit.Sitemap.UrlEntry

  @impl true
  def source_name, do: :posts

  @impl true
  def enabled? do
    posts_module_enabled?() and has_public_routes?()
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    if enabled?() do
      do_collect(opts)
    else
      []
    end
  rescue
    error ->
      Logger.warning("Posts sitemap source failed to collect: #{inspect(error)}")
      []
  end

  defp posts_module_enabled? do
    Settings.get_setting("posts_enabled", "true") == "true"
  rescue
    _ -> false
  end

  defp has_public_routes? do
    # Check if parent router has posts routes
    case RouteResolver.find_content_route(:posts, nil) do
      nil -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  defp do_collect(opts) do
    base_url = Keyword.get(opts, :base_url)
    language = Keyword.get(opts, :language)
    is_default = Keyword.get(opts, :is_default_language, true)

    index_entry = build_index_entry(base_url, language, is_default)
    post_entries = collect_posts(base_url, language, is_default)

    [index_entry | post_entries]
    |> Enum.reject(&is_nil/1)
  end

  defp build_index_entry(base_url, language, is_default) do
    # Canonical path without language prefix (for hreflang grouping)
    canonical_path = "/posts"
    path = build_path_with_language(canonical_path, language, is_default)
    url = build_url(path, base_url)

    UrlEntry.new(%{
      loc: url,
      lastmod: nil,
      changefreq: "daily",
      priority: 0.7,
      title: "Posts",
      category: "Posts",
      source: :posts,
      canonical_path: canonical_path
    })
  end

  defp collect_posts(base_url, language, is_default) do
    posts = PhoenixKit.Posts.list_public_posts(preload: [])

    posts
    |> Enum.reject(&excluded?/1)
    |> Enum.map(fn post ->
      build_post_entry(post, base_url, language, is_default)
    end)
  rescue
    error ->
      Logger.warning("Failed to collect posts: #{inspect(error)}")
      []
  end

  defp build_post_entry(post, base_url, language, is_default) do
    slug = post.slug || to_string(post.id)
    # Canonical path without language prefix (for hreflang grouping)
    canonical_path = "/posts/#{slug}"
    path = build_path_with_language(canonical_path, language, is_default)
    url = build_url(path, base_url)

    lastmod = post.updated_at || post.published_at

    UrlEntry.new(%{
      loc: url,
      lastmod: lastmod,
      changefreq: "weekly",
      priority: 0.8,
      title: post.title,
      category: "Posts",
      source: :posts,
      canonical_path: canonical_path
    })
  end

  defp excluded?(post) do
    case post.metadata do
      %{"sitemap_exclude" => true} -> true
      %{"sitemap_exclude" => "true"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # Add language prefix to path if not default language
  defp build_path_with_language(path, language, is_default) do
    if language && !is_default do
      "/#{extract_base(language)}#{path}"
    else
      path
    end
  end

  # Extract base language code (e.g., "en" from "en-US")
  defp extract_base(code) when is_binary(code) do
    code |> String.split("-") |> List.first() |> String.downcase()
  end

  defp extract_base(_), do: "en"

  defp build_url(path, nil) do
    # Fallback to site_url from settings
    base = Settings.get_setting("site_url", "")
    normalized_base = String.trim_trailing(base, "/")
    "#{normalized_base}#{path}"
  end

  defp build_url(path, base_url) when is_binary(base_url) do
    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{path}"
  end
end
