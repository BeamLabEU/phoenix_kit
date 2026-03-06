defmodule PhoenixKit.Modules.Publishing.SlugHelpers do
  @moduledoc """
  Slug validation and generation for the Publishing module.

  Handles slug format validation, uniqueness checking (DB-only),
  URL slug validation for per-language slugs, and slug generation.
  """

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Utils.Slug

  require Logger

  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  # Reserved route words that cannot be used as URL slugs
  @reserved_route_words ~w(admin api assets phoenix_kit auth login logout register settings)

  @doc """
  Validates whether the given string is a valid slug format and not a reserved language code.
  """
  @spec validate_slug(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_format | :reserved_language_code}
  def validate_slug(slug) when is_binary(slug) do
    cond do
      not Regex.match?(@slug_pattern, slug) ->
        {:error, :invalid_format}

      LanguageHelpers.reserved_language_code?(slug) ->
        {:error, :reserved_language_code}

      true ->
        {:ok, slug}
    end
  end

  @doc """
  Validates whether the given string is a slug and not a reserved language code.
  """
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    case validate_slug(slug) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Validates a per-language URL slug for uniqueness within a group+language combination.
  """
  @spec validate_url_slug(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def validate_url_slug(group_slug, url_slug, language, exclude_post_slug \\ nil) do
    cond do
      not Regex.match?(@slug_pattern, url_slug) ->
        {:error, :invalid_format}

      LanguageHelpers.reserved_language_code?(url_slug) ->
        {:error, :reserved_language_code}

      url_slug in @reserved_route_words ->
        {:error, :reserved_route_word}

      conflicts_with_directory_slug?(group_slug, url_slug, exclude_post_slug) ->
        {:error, :conflicts_with_directory_slug}

      url_slug_exists?(group_slug, url_slug, language, exclude_post_slug) ->
        {:error, :slug_already_exists}

      true ->
        {:ok, url_slug}
    end
  end

  @doc """
  Checks if a slug already exists within the given publishing group (DB-only).
  """
  @spec slug_exists?(String.t(), String.t()) :: boolean()
  def slug_exists?(group_slug, post_slug) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil -> false
      _post -> true
    end
  rescue
    _ -> false
  end

  @doc """
  Clears custom url_slugs that conflict with a given directory slug.
  """
  @spec clear_conflicting_url_slugs(String.t(), String.t()) :: [{String.t(), String.t()}]
  def clear_conflicting_url_slugs(group_slug, directory_slug) do
    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        conflicts = find_conflicting_url_slugs(posts, directory_slug)
        clear_url_slugs_for_conflicts(group_slug, directory_slug, conflicts)
        log_cleared_conflicts(conflicts, directory_slug)
        conflicts

      {:error, _} ->
        []
    end
  end

  @doc """
  Clears a specific url_slug from all translations of a single post (DB-only).
  """
  @spec clear_url_slug_from_post(String.t(), String.t(), String.t()) :: [String.t()]
  def clear_url_slug_from_post(group_slug, post_slug, url_slug_to_clear) do
    DBStorage.clear_url_slug_from_post(group_slug, post_slug, url_slug_to_clear)
  end

  @doc """
  Generates a unique slug based on title and optional preferred slug.
  """
  @spec generate_unique_slug(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, :invalid_format | :reserved_language_code}
  def generate_unique_slug(group_slug, title, preferred_slug \\ nil, opts \\ []) do
    current_slug = Keyword.get(opts, :current_slug)

    base_slug_result =
      case preferred_slug do
        nil ->
          {:ok, Slug.slugify(title)}

        slug when is_binary(slug) ->
          sanitized = Slug.slugify(slug)

          if sanitized == "" do
            {:ok, Slug.slugify(title)}
          else
            case validate_slug(sanitized) do
              {:ok, valid_slug} -> {:ok, valid_slug}
              {:error, reason} -> {:error, reason}
            end
          end
      end

    case base_slug_result do
      {:ok, base_slug} when base_slug != "" ->
        {:ok,
         Slug.ensure_unique(base_slug, fn candidate ->
           slug_exists_for_generation?(group_slug, candidate, current_slug)
         end)}

      {:ok, ""} ->
        {:ok,
         Slug.ensure_unique("untitled", fn candidate ->
           slug_exists_for_generation?(group_slug, candidate, current_slug)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp conflicts_with_directory_slug?(group_slug, url_slug, exclude_post_slug) do
    if url_slug == exclude_post_slug do
      false
    else
      slug_exists?(group_slug, url_slug)
    end
  end

  defp url_slug_exists?(group_slug, url_slug, language, exclude_post_slug) do
    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        Enum.any?(posts, fn post ->
          post.slug != exclude_post_slug and
            post.slug != url_slug and
            Map.get(post.language_slugs || %{}, language) == url_slug
        end)

      {:error, _} ->
        # Check via DBStorage
        case DBStorage.find_by_url_slug(group_slug, language, url_slug) do
          nil ->
            false

          content ->
            post_slug = content.version.post.slug
            post_slug != exclude_post_slug and post_slug != url_slug
        end
    end
  rescue
    _ -> false
  end

  defp slug_exists_for_generation?(_group_slug, candidate, current_slug)
       when not is_nil(current_slug) and candidate == current_slug,
       do: false

  defp slug_exists_for_generation?(group_slug, candidate, _current_slug) do
    slug_exists?(group_slug, candidate)
  end

  defp find_conflicting_url_slugs(posts, directory_slug) do
    Enum.flat_map(posts, fn post ->
      if post.slug == directory_slug do
        []
      else
        (post.language_slugs || %{})
        |> Enum.filter(fn {_lang, url_slug} -> url_slug == directory_slug end)
        |> Enum.map(fn {lang, _} -> {post.slug, lang} end)
      end
    end)
  end

  defp clear_url_slugs_for_conflicts(group_slug, directory_slug, conflicts) do
    Enum.each(conflicts, fn {post_slug, _language} ->
      DBStorage.clear_url_slug_from_post(group_slug, post_slug, directory_slug)
    end)
  end

  defp log_cleared_conflicts([], _directory_slug), do: :ok

  defp log_cleared_conflicts(conflicts, directory_slug) do
    Logger.warning(
      "[Slugs] Cleared conflicting url_slugs for directory slug '#{directory_slug}': #{inspect(conflicts)}"
    )
  end
end
