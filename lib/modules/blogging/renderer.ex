defmodule PhoenixKit.Modules.Blogging.Renderer do
  @moduledoc """
  Renders blog post markdown to HTML with caching support.

  Uses PhoenixKit.Cache for performance optimization of markdown rendering.
  Cache keys include content hashes for automatic invalidation.
  """

  require Logger

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Blogging.Components.EntityForm
  alias PhoenixKit.Modules.Blogging.Components.Image
  alias PhoenixKit.Modules.Blogging.Components.Video
  alias PhoenixKit.Modules.Blogging.PageBuilder
  alias PhoenixKit.Settings

  @cache_name :blog_posts
  @cache_version "v1"
  @global_cache_key "blogging_render_cache_enabled"
  @component_regex ~r/<(Image|Hero|CTA|Headline|Subheadline|Video|EntityForm)\s+([^>]*?)\/>/s
  @component_block_regex ~r/<(Hero|CTA|Headline|Subheadline|Video|EntityForm)\s*([^>]*)>(.*?)<\/\1>/s

  @doc """
  Renders a post's markdown content to HTML.

  Caches the result for published posts using content-hash-based keys.
  Lazy-loads cache (only caches after first render).

  Respects `blogging_render_cache_enabled` (global) and
  `blogging_render_cache_enabled_{blog_slug}` (per-blog) settings.

  ## Examples

      {:ok, html} = Renderer.render_post(post)

  """
  def render_post(post) do
    if post.metadata.status == "published" and render_cache_enabled?(post.blog) do
      cache_key = build_cache_key(post)

      case get_cached(cache_key) do
        {:ok, html} ->
          {:ok, html}

        :miss ->
          render_and_cache(post, cache_key)
      end
    else
      # Don't cache drafts, archived posts, or when cache is disabled
      {:ok, render_markdown(post.content)}
    end
  end

  @doc """
  Returns whether render caching is enabled for a blog.

  Checks both the global setting and per-blog setting.
  Both must be enabled (or default to enabled) for caching to work.
  """
  @spec render_cache_enabled?(String.t()) :: boolean()
  def render_cache_enabled?(blog_slug) do
    global_enabled = Settings.get_setting_cached(@global_cache_key, "true") == "true"
    per_blog_key = "blogging_render_cache_enabled_#{blog_slug}"
    per_blog_enabled = Settings.get_setting_cached(per_blog_key, "true") == "true"

    global_enabled and per_blog_enabled
  end

  @doc """
  Returns whether the global render cache is enabled.
  """
  @spec global_render_cache_enabled?() :: boolean()
  def global_render_cache_enabled? do
    Settings.get_setting_cached(@global_cache_key, "true") == "true"
  end

  @doc """
  Returns whether render cache is enabled for a specific blog.
  Does not check the global setting.
  """
  @spec blog_render_cache_enabled?(String.t()) :: boolean()
  def blog_render_cache_enabled?(blog_slug) do
    per_blog_key = "blogging_render_cache_enabled_#{blog_slug}"
    Settings.get_setting_cached(per_blog_key, "true") == "true"
  end

  @doc """
  Renders markdown or .phk content directly without caching.

  Automatically detects .phk XML format and routes to PageBuilder.
  Falls back to Earmark markdown rendering for non-XML content.

  ## Examples

      html = Renderer.render_markdown(content)

  """
  def render_markdown(content) when is_binary(content) do
    {time, result} =
      :timer.tc(fn ->
        cond do
          pure_phk_content?(content) ->
            render_phk_content(content)

          has_embedded_components?(content) ->
            render_mixed_content(content)

          true ->
            render_earmark_markdown(content)
        end
      end)

    Logger.debug("Content render time: #{time}μs", content_size: byte_size(content))
    result
  end

  def render_markdown(_), do: ""

  # Detect if content is pure .phk XML format (starts with <Page> or <Hero>)
  defp pure_phk_content?(content) do
    trimmed = String.trim(content)
    String.starts_with?(trimmed, "<Page") || String.starts_with?(trimmed, "<Hero")
  end

  # Detect if markdown content has embedded XML components
  defp has_embedded_components?(content) do
    String.contains?(content, "<Image ") ||
      String.contains?(content, "<Hero") ||
      String.contains?(content, "<CTA") ||
      String.contains?(content, "<Headline") ||
      String.contains?(content, "<Subheadline") ||
      String.contains?(content, "<Video") ||
      String.contains?(content, "<EntityForm")
  end

  # Render .phk content using PageBuilder
  defp render_phk_content(content) do
    case PageBuilder.render_content(content) do
      {:ok, html} ->
        # Convert Phoenix.LiveView.Rendered to string
        html
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Logger.warning("PHK render error: #{inspect(reason)}")
        "<p>Error rendering page content</p>"
    end
  end

  # Render markdown using Earmark
  defp render_earmark_markdown(content) do
    content = normalize_markdown(content)

    case Earmark.as_html(content, %Earmark.Options{
           code_class_prefix: "language-",
           smartypants: true,
           gfm: true,
           escape: false
         }) do
      {:ok, html, _warnings} -> html
      {:error, _html, _errors} -> "<p>Error rendering markdown</p>"
    end
  end

  defp normalize_markdown(content) when is_binary(content) do
    # Remove leading indentation before Markdown headings (e.g., "  ## Title")
    Regex.replace(~r/^[ \t]+(?=#)/m, content, "")
  end

  # Render mixed content: markdown with embedded XML components
  defp render_mixed_content(content) when content == "" or is_nil(content), do: ""

  defp render_mixed_content(content) do
    content
    |> render_mixed_segments([])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp render_mixed_segments("", acc), do: acc

  defp render_mixed_segments(content, acc) do
    case next_component_match(content) do
      nil ->
        [render_earmark_markdown(content) | acc]

      {:self_closing, [{match_start, match_len}, {tag_start, tag_len}, {attrs_start, attrs_len}]} ->
        before = binary_part(content, 0, match_start)
        after_index = match_start + match_len
        rest_content = binary_part(content, after_index, byte_size(content) - after_index)
        tag = binary_part(content, tag_start, tag_len)
        attrs = binary_part(content, attrs_start, attrs_len)

        acc =
          acc
          |> maybe_add_markdown(before)
          |> add_component(tag, attrs)

        render_mixed_segments(rest_content, acc)

      {:block, indexes} ->
        [{match_start, match_len} | _rest] = indexes
        before = binary_part(content, 0, match_start)
        after_index = match_start + match_len
        rest_content = binary_part(content, after_index, byte_size(content) - after_index)
        fragment = binary_part(content, match_start, match_len)

        acc =
          acc
          |> maybe_add_markdown(before)
          |> add_block_component(fragment)

        render_mixed_segments(rest_content, acc)
    end
  end

  defp next_component_match(content) do
    self_match = Regex.run(@component_regex, content, return: :index)
    block_match = Regex.run(@component_block_regex, content, return: :index)

    case {self_match, block_match} do
      {nil, nil} ->
        nil

      {nil, block} ->
        {:block, block}

      {self, nil} ->
        {:self_closing, self}

      {self, block} ->
        self_start = self |> hd() |> elem(0)
        block_start = block |> hd() |> elem(0)

        if self_start <= block_start do
          {:self_closing, self}
        else
          {:block, block}
        end
    end
  end

  defp maybe_add_markdown(acc, ""), do: acc

  defp maybe_add_markdown(acc, text) do
    [render_earmark_markdown(text) | acc]
  end

  defp add_component(acc, tag, attrs) do
    [render_inline_component(tag, attrs) | acc]
  end

  defp add_block_component(acc, fragment) do
    [render_block_component(fragment) | acc]
  end

  # Render individual inline component
  defp render_inline_component("Image", attrs) do
    # Parse attributes
    attr_map = parse_xml_attributes(attrs)

    assigns = %{
      __changed__: nil,
      attributes: attr_map,
      variant: "default",
      content: nil,
      children: []
    }

    Image.render(assigns)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering Image component: #{inspect(error)}")
      "<div class='error'>Error rendering image</div>"
  end

  defp render_inline_component("Video", attrs) do
    attr_map = parse_xml_attributes(attrs)

    assigns = %{
      __changed__: nil,
      attributes: attr_map,
      variant: Map.get(attr_map, "variant", "default"),
      content: Map.get(attr_map, "caption"),
      children: []
    }

    Video.render(assigns)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering Video component: #{inspect(error)}")
      "<div class='error'>Error rendering video</div>"
  end

  defp render_inline_component("EntityForm", attrs) do
    attr_map = parse_xml_attributes(attrs)

    assigns = %{
      __changed__: nil,
      attributes: attr_map,
      variant: Map.get(attr_map, "variant", "default"),
      content: nil,
      children: []
    }

    EntityForm.render(assigns)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering EntityForm component: #{inspect(error)}")
      "<div class='error'>Error rendering entity form</div>"
  end

  defp render_inline_component(tag, _attrs) do
    # Fallback for other components
    Logger.warning("Inline component not supported yet: #{tag}")
    ""
  end

  defp render_block_component(fragment) do
    fragment
    |> PageBuilder.render_content()
    |> case do
      {:ok, html} ->
        html
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Logger.warning("Error rendering block component: #{inspect(reason)}")
        "<div class='error'>Error rendering component</div>"
    end
  end

  # Parse XML attribute string into a map
  defp parse_xml_attributes(attrs_string) do
    # Match key="value" or key='value' patterns
    attr_regex = ~r/(\w+)=["']([^"']+)["']/

    Regex.scan(attr_regex, attrs_string)
    |> Enum.map(fn [_, key, value] -> {key, value} end)
    |> Enum.into(%{})
  end

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
    PhoenixKit.Cache.clear(@cache_name)
    Logger.info("Cleared all blog post caches")
    :ok
  rescue
    _ ->
      Logger.warning("Blog cache not available for clearing")
      :ok
  end

  @doc """
  Clears the render cache for a specific blog.

  Returns `{:ok, count}` with the number of entries cleared.

  ## Examples

      Renderer.clear_blog_cache("my-blog")
      # => {:ok, 15}

  """
  @spec clear_blog_cache(String.t()) :: {:ok, non_neg_integer()} | {:error, any()}
  def clear_blog_cache(blog_slug) do
    prefix = "#{@cache_version}:blog_post:#{blog_slug}:"

    case PhoenixKit.Cache.clear_by_prefix(@cache_name, prefix) do
      {:ok, count} = result ->
        Logger.info("Cleared #{count} cached posts for blog: #{blog_slug}")
        result

      {:error, _} = error ->
        error
    end
  rescue
    _ ->
      Logger.warning("Blog cache not available for clearing")
      {:ok, 0}
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
