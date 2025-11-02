defmodule PhoenixKit.Blogging.Renderer do
  @moduledoc """
  Renders blog post markdown to HTML with caching support.

  Uses PhoenixKit.Cache for performance optimization of markdown rendering.
  Cache keys include content hashes for automatic invalidation.
  """

  require Logger

  @cache_name :blog_posts
  @cache_version "v1"

  @doc """
  Renders a post's markdown content to HTML.

  Caches the result for published posts using content-hash-based keys.
  Lazy-loads cache (only caches after first render).

  ## Examples

      {:ok, html} = Renderer.render_post(post)

  """
  def render_post(post) do
    if post.metadata.status == "published" do
      cache_key = build_cache_key(post)

      case get_cached(cache_key) do
        {:ok, html} ->
          {:ok, html}

        :miss ->
          render_and_cache(post, cache_key)
      end
    else
      # Don't cache drafts or archived posts
      {:ok, render_markdown(post.content)}
    end
  end

  @doc """
  Renders markdown content directly without caching.

  ## Examples

      html = Renderer.render_markdown(content)

  """
  def render_markdown(content) when is_binary(content) do
    {time, result} =
      :timer.tc(fn ->
        case Earmark.as_html(content, %Earmark.Options{
               code_class_prefix: "language-",
               smartypants: true,
               gfm: true
             }) do
          {:ok, html, _warnings} -> html
          {:error, _html, _errors} -> "<p>Error rendering markdown</p>"
        end
      end)

    Logger.debug("Markdown render time: #{time}μs", content_size: byte_size(content))
    result
  end

  def render_markdown(_), do: ""

  @doc """
  Invalidates cache for a specific post.

  Called when a post is updated in the admin editor.

  ## Examples

      Renderer.invalidate_cache("docs", "getting-started", "en")

  """
  def invalidate_cache(blog_slug, identifier, language) do
    # Build pattern to match all cache keys for this post
    # We don't know the content hash, so we invalidate by prefix
    pattern = "#{@cache_version}:blog_post:#{blog_slug}:#{identifier}:#{language}:"

    # Since PhoenixKit.Cache doesn't support pattern matching,
    # we'll just log this for now and rely on content hash changes
    Logger.info("Cache invalidation requested",
      blog: blog_slug,
      identifier: identifier,
      language: language,
      pattern: pattern
    )

    # The content hash in the key will change automatically when content changes
    # So we don't need to explicitly delete old entries
    :ok
  end

  @doc """
  Clears all blog post caches.

  Useful for testing or when doing bulk updates.
  """
  def clear_all_cache do
    try do
      PhoenixKit.Cache.clear(@cache_name)
      Logger.info("Cleared all blog post caches")
      :ok
    rescue
      _ ->
        Logger.warning("Blog cache not available for clearing")
        :ok
    end
  end

  # Private Functions

  defp render_and_cache(post, cache_key) do
    html = render_markdown(post.content)

    # Cache the rendered HTML
    put_cached(cache_key, html)

    {:ok, html}
  end

  defp build_cache_key(post) do
    # Build content hash from content + metadata
    content_to_hash = post.content <> inspect(post.metadata)

    content_hash =
      :crypto.hash(:md5, content_to_hash)
      |> Base.encode16(case: :lower)
      |> String.slice(0..7)

    identifier = post.slug || extract_identifier_from_path(post.path)

    "#{@cache_version}:blog_post:#{post.blog}:#{identifier}:#{post.language}:#{content_hash}"
  end

  defp extract_identifier_from_path(path) when is_binary(path) do
    # For timestamp mode: "blog/2025-01-15/09:30/en.phk" -> "2025-01-15/09:30"
    # For slug mode: "blog/getting-started/en.phk" -> "getting-started"
    path
    |> String.split("/")
    # Remove language.phk
    |> Enum.drop(-1)
    # Remove blog name
    |> Enum.drop(1)
    |> Enum.join("/")
  end

  defp extract_identifier_from_path(_), do: "unknown"

  defp get_cached(key) do
    case PhoenixKit.Cache.get(@cache_name, key) do
      nil -> :miss
      html -> {:ok, html}
    end
  rescue
    _ ->
      # Cache not available (tests, compilation)
      :miss
  end

  defp put_cached(key, value) do
    PhoenixKit.Cache.put(@cache_name, key, value)
  rescue
    error ->
      Logger.debug("Cache unavailable, skipping: #{inspect(error)}")
      :ok
  end
end
