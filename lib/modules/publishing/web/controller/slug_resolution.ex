defmodule PhoenixKit.Modules.Publishing.Web.Controller.SlugResolution do
  @moduledoc """
  URL slug resolution for the publishing controller.

  Handles resolving URL slugs to internal slugs, including:
  - Per-language custom URL slugs
  - Previous URL slugs for 301 redirects
  - Filesystem fallback when cache is unavailable
  """

  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  # ============================================================================
  # URL Slug Resolution
  # ============================================================================

  @doc """
  Resolves URL slug to internal slug using cache.

  Returns:
  - {:redirect, url} for 301 redirect to new URL
  - {:ok, identifier} for resolved internal slug
  - :passthrough for direct use
  """
  def resolve_url_slug(blog_slug, {:slug, url_slug}, language) do
    case ListingCache.find_by_url_slug(blog_slug, language, url_slug) do
      {:ok, cached_post} ->
        internal_slug = cached_post.slug

        if internal_slug == url_slug do
          # URL slug matches internal slug - no resolution needed
          :passthrough
        else
          # URL slug differs from internal slug - use resolved identifier
          {:ok, {:slug, internal_slug}}
        end

      {:error, :not_found} ->
        # Not found in current slugs - check previous slugs for 301 redirect
        case ListingCache.find_by_previous_url_slug(blog_slug, language, url_slug) do
          {:ok, cached_post} ->
            # Found in previous slugs - redirect to current URL
            current_url_slug =
              Map.get(cached_post.language_slugs || %{}, language, cached_post.slug)

            redirect_url =
              build_post_redirect_url(blog_slug, cached_post, language, current_url_slug)

            {:redirect, redirect_url}

          {:error, _} ->
            # Not found in cache - try filesystem fallback
            resolve_url_slug_from_filesystem(blog_slug, url_slug, language)
        end

      {:error, :cache_miss} ->
        # Cache not available - try filesystem fallback
        resolve_url_slug_from_filesystem(blog_slug, url_slug, language)
    end
  end

  # Non-slug modes pass through directly
  def resolve_url_slug(_blog_slug, _identifier, _language), do: :passthrough

  @doc """
  Resolves a URL slug to the internal directory slug.
  Used by versioned URL handler and other places that need the internal slug.
  """
  def resolve_url_slug_to_internal(blog_slug, url_slug, language) do
    case ListingCache.find_by_url_slug(blog_slug, language, url_slug) do
      {:ok, cached_post} ->
        cached_post.slug

      {:error, _} ->
        # Fallback: try filesystem scan for custom slug
        case find_internal_slug_from_filesystem(blog_slug, url_slug, language) do
          {:ok, internal_slug} -> internal_slug
          {:error, _} -> url_slug
        end
    end
  end

  # ============================================================================
  # Filesystem Fallback
  # ============================================================================

  @doc """
  Filesystem fallback for URL slug resolution when cache is unavailable.
  Also handles 301 redirects for previous_url_slugs.
  """
  def resolve_url_slug_from_filesystem(blog_slug, url_slug, language) do
    case find_slug_in_filesystem(blog_slug, url_slug, language) do
      {:current, internal_slug} when internal_slug != url_slug ->
        # Found as current url_slug - resolve to internal slug
        {:ok, {:slug, internal_slug}}

      {:current, _same_slug} ->
        # URL slug matches internal slug - passthrough
        :passthrough

      {:previous, internal_slug, current_url_slug} ->
        # Found in previous_url_slugs - redirect to current URL
        redirect_url =
          build_redirect_url_from_slugs(blog_slug, internal_slug, language, current_url_slug)

        {:redirect, redirect_url}

      {:error, _} ->
        # Not found - passthrough for normal handling
        :passthrough
    end
  end

  @doc """
  Scans filesystem to find a post with matching url_slug or previous_url_slugs.

  Returns:
  - {:current, internal_slug} - found as current url_slug
  - {:previous, internal_slug, current_url_slug} - found in previous_url_slugs (for redirect)
  - {:error, reason} - not found
  """
  def find_slug_in_filesystem(blog_slug, url_slug, language) do
    group_path = Storage.group_path(blog_slug)

    with true <- File.dir?(group_path),
         dirs <- File.ls!(group_path),
         result when not is_nil(result) <-
           scan_posts_for_slug(group_path, dirs, url_slug, language) do
      result
    else
      false -> {:error, :group_not_found}
      nil -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :scan_failed}
  end

  # ============================================================================
  # Slug Scanning Helpers
  # ============================================================================

  defp scan_posts_for_slug(group_path, dirs, url_slug, language) do
    Enum.find_value(dirs, fn post_dir ->
      post_path = Path.join(group_path, post_dir)

      if File.dir?(post_path) do
        check_post_for_slug(post_path, post_dir, url_slug, language)
      end
    end)
  end

  defp check_post_for_slug(post_path, post_dir, url_slug, language) do
    case read_slug_data_from_post(post_path, language) do
      {:ok, current_slug, previous_slugs} ->
        match_slug_data(post_dir, url_slug, current_slug, previous_slugs)

      _ ->
        nil
    end
  end

  defp match_slug_data(post_dir, url_slug, current_slug, previous_slugs) do
    cond do
      current_slug == url_slug ->
        {:current, post_dir}

      url_slug in (previous_slugs || []) ->
        {:previous, post_dir, current_slug || post_dir}

      true ->
        nil
    end
  end

  # Legacy function for resolve_url_slug_to_internal (only needs current slug)
  defp find_internal_slug_from_filesystem(blog_slug, url_slug, language) do
    case find_slug_in_filesystem(blog_slug, url_slug, language) do
      {:current, internal_slug} -> {:ok, internal_slug}
      {:previous, internal_slug, _current} -> {:ok, internal_slug}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Slug Data Reading
  # ============================================================================

  @doc """
  Reads url_slug and previous_url_slugs from a post's language file metadata.
  """
  def read_slug_data_from_post(post_path, language) do
    # Try versioned structure first, then legacy
    content_dir =
      case find_latest_version_dir(post_path) do
        {:ok, version_dir} -> version_dir
        {:error, _} -> post_path
      end

    file_path = Path.join(content_dir, "#{language}.phk")

    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} ->
          case Metadata.parse_with_content(content) do
            {:ok, metadata, _content} ->
              url_slug = Map.get(metadata, :url_slug)
              previous_slugs = Map.get(metadata, :previous_url_slugs) || []
              {:ok, url_slug, previous_slugs}

            _ ->
              {:error, :parse_failed}
          end

        _ ->
          {:error, :read_failed}
      end
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Finds the latest version directory in a versioned post structure.
  """
  def find_latest_version_dir(post_path) do
    versions =
      post_path
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "v"))
      |> Enum.map(fn dir ->
        case Integer.parse(String.trim_leading(dir, "v")) do
          {num, ""} -> num
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(:desc)

    case versions do
      [latest | _] -> {:ok, Path.join(post_path, "v#{latest}")}
      [] -> {:error, :no_versions}
    end
  rescue
    _ -> {:error, :scan_failed}
  end

  # ============================================================================
  # Redirect URL Building
  # ============================================================================

  @doc """
  Builds redirect URL for 301 redirects from cached post data.
  """
  def build_post_redirect_url(blog_slug, cached_post, language, url_slug) do
    # Build post struct with minimal fields needed for URL generation
    post = %{
      slug: cached_post.slug,
      url_slug: url_slug,
      mode: cached_post.mode,
      date: cached_post.date,
      time: cached_post.time,
      language_slugs: cached_post.language_slugs
    }

    PublishingHTML.build_post_url(blog_slug, post, language)
  end

  @doc """
  Builds redirect URL when we only have slug data (no full post struct).
  """
  def build_redirect_url_from_slugs(blog_slug, internal_slug, language, current_url_slug) do
    # Build minimal post struct for URL generation
    post = %{
      slug: internal_slug,
      url_slug: current_url_slug,
      mode: :slug,
      language_slugs: %{language => current_url_slug}
    }

    PublishingHTML.build_post_url(blog_slug, post, language)
  end
end
