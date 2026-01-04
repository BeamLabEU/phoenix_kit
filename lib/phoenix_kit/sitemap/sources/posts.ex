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
  3. Routes do NOT require authentication (checked via on_mount hooks)

  Routes with the following on_mount hooks are considered private and excluded:
  - `:phoenix_kit_ensure_authenticated_scope` - requires logged-in user
  - `:phoenix_kit_ensure_admin` - requires admin access
  - `:ensure_authenticated` - generic authentication requirement
  - `:require_authenticated_user` - requires authenticated user

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

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap.RouteResolver
  alias PhoenixKit.Sitemap.UrlEntry

  @impl true
  def source_name, do: :posts

  @impl true
  def enabled? do
    # Only check if posts module is enabled
    # Route checks moved to do_collect() for caching optimization
    posts_module_enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect(opts \\ []) do
    is_default = Keyword.get(opts, :is_default_language, true)

    # Posts only generate URLs for the default language
    # Non-default language URLs would lead to 404 errors
    if enabled?() and is_default do
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
    Settings.get_setting_cached("posts_enabled", "true") == "true"
  rescue
    _ -> false
  end

  defp do_collect(opts) do
    # Optimization: Get routes ONCE for all checks
    routes = RouteResolver.get_routes()

    cond do
      # Early exit if no public posts routes exist
      not has_public_posts_route?(routes) ->
        Logger.debug("Sitemap: No public posts routes found, skipping posts source")
        []

      # Early exit if routes require authentication
      posts_route_requires_auth?(routes) ->
        Logger.debug("Sitemap: Posts routes require authentication, skipping")
        []

      # Proceed with collection
      true ->
        do_collect_posts(opts)
    end
  end

  defp do_collect_posts(opts) do
    base_url = Keyword.get(opts, :base_url)
    language = Keyword.get(opts, :language)
    is_default = Keyword.get(opts, :is_default_language, true)

    index_entry = build_index_entry(base_url, language, is_default)
    post_entries = collect_posts(base_url, language, is_default)

    [index_entry | post_entries]
    |> Enum.reject(&is_nil/1)
  end

  # Check if posts route exists in cached routes
  defp has_public_posts_route?(routes) do
    find_posts_content_route(routes) != nil
  end

  # Check if posts route requires auth using cached routes
  defp posts_route_requires_auth?(routes) do
    case find_posts_content_route(routes) do
      nil -> false
      route -> RouteResolver.route_requires_auth?(route)
    end
  end

  # Find posts content route in cached routes (reusable)
  defp find_posts_content_route(routes) do
    Enum.find(routes, fn route ->
      route.verb == :get and
        (String.contains?(route.path, ":slug") or String.contains?(route.path, ":id")) and
        posts_route_match?(route)
    end)
  end

  defp posts_route_match?(route) do
    path_lower = String.downcase(route.path)
    plug_name = route.plug |> to_string() |> String.downcase()

    String.contains?(path_lower, "/posts/") or
      String.starts_with?(path_lower, "/posts/") or
      (String.contains?(plug_name, "post") and not String.contains?(plug_name, "page"))
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
    posts = Posts.list_public_posts(preload: [])

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

  # Add language prefix to path when in multi-language mode
  # Single language: no prefix for anyone
  # Multiple languages: ALL languages get prefix (including default)
  defp build_path_with_language(path, language, _is_default) do
    if language && !single_language_mode?() do
      "/#{Languages.DialectMapper.extract_base(language)}#{path}"
    else
      path
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
