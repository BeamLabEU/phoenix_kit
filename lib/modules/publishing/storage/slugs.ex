defmodule PhoenixKit.Modules.Publishing.Storage.Slugs do
  @moduledoc """
  Slug validation and generation for publishing storage.

  Handles slug format validation, uniqueness checking,
  URL slug validation for per-language slugs, and slug generation.
  """

  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Storage.Languages
  alias PhoenixKit.Modules.Publishing.Storage.Paths
  alias PhoenixKit.Modules.Publishing.Storage.Versions
  alias PhoenixKit.Utils.Slug

  require Logger

  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  # Reserved route words that cannot be used as URL slugs
  @reserved_route_words ~w(admin api assets phoenix_kit auth login logout register settings)

  @doc """
  Validates whether the given string is a valid slug format and not a reserved language code.

  Returns:
  - `{:ok, slug}` if valid
  - `{:error, :invalid_format}` if format is invalid
  - `{:error, :reserved_language_code}` if slug is a language code

  Blog slugs cannot be language codes (like 'en', 'es', 'fr') to prevent routing ambiguity.
  """
  @spec validate_slug(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_format | :reserved_language_code}
  def validate_slug(slug) when is_binary(slug) do
    cond do
      not Regex.match?(@slug_pattern, slug) ->
        {:error, :invalid_format}

      Languages.reserved_language_code?(slug) ->
        {:error, :reserved_language_code}

      true ->
        {:ok, slug}
    end
  end

  @doc """
  Validates whether the given string is a slug and not a reserved language code.

  Blog slugs cannot be language codes (like 'en', 'es', 'fr') to prevent routing ambiguity.
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

  URL slugs have the same format requirements as directory slugs, plus:
  - Cannot be reserved route words (admin, api, assets, etc.)
  - Must be unique within the group+language combination

  ## Parameters
  - `group_slug` - The publishing group
  - `url_slug` - The URL slug to validate
  - `language` - The language code
  - `exclude_post_slug` - Optional post slug to exclude from uniqueness check (for updates)

  ## Returns
  - `{:ok, url_slug}` - Valid and unique
  - `{:error, :invalid_format}` - Invalid format
  - `{:error, :reserved_language_code}` - Is a language code
  - `{:error, :reserved_route_word}` - Is a reserved route word
  - `{:error, :slug_already_exists}` - Already in use for this language
  - `{:error, :conflicts_with_directory_slug}` - Conflicts with another post's directory slug
  """
  @spec validate_url_slug(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def validate_url_slug(group_slug, url_slug, language, exclude_post_slug \\ nil) do
    cond do
      not Regex.match?(@slug_pattern, url_slug) ->
        {:error, :invalid_format}

      Languages.reserved_language_code?(url_slug) ->
        {:error, :reserved_language_code}

      url_slug in @reserved_route_words ->
        {:error, :reserved_route_word}

      # Directory slugs have priority - can't use another post's directory slug as your url_slug
      conflicts_with_directory_slug?(group_slug, url_slug, exclude_post_slug) ->
        {:error, :conflicts_with_directory_slug}

      url_slug_exists?(group_slug, url_slug, language, exclude_post_slug) ->
        {:error, :slug_already_exists}

      true ->
        {:ok, url_slug}
    end
  end

  # Check if the url_slug matches any other post's directory slug
  defp conflicts_with_directory_slug?(group_slug, url_slug, exclude_post_slug) do
    # If the url_slug equals the post's own directory slug, that's fine
    if url_slug == exclude_post_slug do
      false
    else
      # Check if any other post has this as their directory slug
      slug_exists?(group_slug, url_slug)
    end
  end

  defp url_slug_exists?(group_slug, url_slug, language, exclude_post_slug) do
    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        Enum.any?(posts, fn post ->
          # Skip the post being edited and skip posts whose directory slug equals the url_slug
          # (directory slugs are checked separately and have priority)
          post.slug != exclude_post_slug and
            post.slug != url_slug and
            Map.get(post.language_slugs || %{}, language) == url_slug
        end)

      {:error, _} ->
        url_slug_exists_in_filesystem?(group_slug, url_slug, language, exclude_post_slug)
    end
  end

  defp url_slug_exists_in_filesystem?(group_slug, url_slug, language, exclude_post_slug) do
    group_path = Paths.group_path(group_slug)

    if File.dir?(group_path) do
      group_path
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(group_path, &1)))
      |> Enum.reject(&(&1 == exclude_post_slug))
      |> Enum.any?(fn post_slug ->
        case read_post_url_slug(group_slug, post_slug, language) do
          {:ok, existing_url_slug} -> existing_url_slug == url_slug
          _ -> false
        end
      end)
    else
      false
    end
  end

  defp read_post_url_slug(group_slug, post_slug, language) do
    alias PhoenixKit.Modules.Publishing.Storage

    case Storage.read_post_slug_mode(group_slug, post_slug, language, nil) do
      {:ok, post} ->
        url_slug = Map.get(post.metadata, :url_slug) || post_slug
        {:ok, url_slug}

      error ->
        error
    end
  end

  @doc """
  Checks if a slug already exists within the given publishing group.
  """
  @spec slug_exists?(String.t(), String.t()) :: boolean()
  def slug_exists?(group_slug, post_slug) do
    Path.join([Paths.group_path(group_slug), post_slug])
    |> File.dir?()
  end

  @doc """
  Clears custom url_slugs that conflict with a given directory slug.

  When a new post is created with directory slug X, any other posts that have
  custom url_slug = X need to have their url_slugs cleared (so they fall back
  to their own directory slug). Directory slugs have priority.

  Returns the list of {post_slug, language} tuples that were cleared.
  """
  @spec clear_conflicting_url_slugs(String.t(), String.t()) :: [{String.t(), String.t()}]
  def clear_conflicting_url_slugs(group_slug, directory_slug) do
    case ListingCache.read(group_slug) do
      {:ok, posts} ->
        # Find posts with custom url_slugs matching the directory slug
        conflicts =
          Enum.flat_map(posts, fn post ->
            # Skip the post with this directory slug itself
            if post.slug == directory_slug do
              []
            else
              # Find languages where url_slug matches the directory slug
              (post.language_slugs || %{})
              |> Enum.filter(fn {_lang, url_slug} -> url_slug == directory_slug end)
              |> Enum.map(fn {lang, _} -> {post.slug, lang} end)
            end
          end)

        # Clear each conflicting url_slug
        Enum.each(conflicts, fn {post_slug, language} ->
          clear_url_slug_for_language(group_slug, post_slug, language)
        end)

        if conflicts != [] do
          Logger.warning(
            "[Slugs] Cleared conflicting url_slugs for directory slug '#{directory_slug}': #{inspect(conflicts)}"
          )
        end

        conflicts

      {:error, _} ->
        []
    end
  end

  # Clears the url_slug for a specific post/language by removing it from metadata
  defp clear_url_slug_for_language(group_slug, post_slug, language) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    structure = Versions.detect_post_structure(post_path)

    # Get all versions and clear url_slug in each
    versions = Versions.list_versions(group_slug, post_slug)

    Enum.each(versions, fn version ->
      version_dir =
        case structure do
          :versioned -> Path.join(post_path, "v#{version}")
          :legacy -> post_path
          _ -> nil
        end

      if version_dir do
        file_path = Path.join(version_dir, Languages.language_filename(language))

        if File.exists?(file_path) do
          case File.read(file_path) do
            {:ok, content} ->
              case Metadata.parse_with_content(content) do
                {:ok, metadata, body} ->
                  # Remove url_slug from metadata
                  new_metadata = Map.delete(metadata, :url_slug)
                  new_content = Metadata.serialize(new_metadata) <> body
                  File.write(file_path, new_content)

                _ ->
                  :ok
              end

            _ ->
              :ok
          end
        end
      end
    end)
  end

  @doc """
  Clears a specific url_slug from all translations of a single post.

  This is used when saving a post with a conflicting url_slug - we clear the
  url_slug from all translations of the same post that have that value.

  Returns the list of language codes that were cleared.
  """
  @spec clear_url_slug_from_post(String.t(), String.t(), String.t()) :: [String.t()]
  def clear_url_slug_from_post(group_slug, post_slug, url_slug_to_clear) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    structure = Versions.detect_post_structure(post_path)
    versions = Versions.list_versions(group_slug, post_slug)

    # Collect all languages that have this url_slug across all versions
    languages_to_clear =
      Enum.flat_map(versions, fn version ->
        version_dir =
          case structure do
            :versioned -> Path.join(post_path, "v#{version}")
            :legacy -> post_path
            _ -> nil
          end

        if version_dir && File.dir?(version_dir) do
          Languages.detect_available_languages(version_dir)
          |> Enum.filter(fn lang ->
            file_path = Path.join(version_dir, Languages.language_filename(lang))

            case File.read(file_path) do
              {:ok, content} ->
                case Metadata.parse_with_content(content) do
                  {:ok, metadata, _body} ->
                    Map.get(metadata, :url_slug) == url_slug_to_clear

                  _ ->
                    false
                end

              _ ->
                false
            end
          end)
        else
          []
        end
      end)
      |> Enum.uniq()

    # Clear url_slug from each language
    Enum.each(languages_to_clear, fn language ->
      clear_url_slug_for_language(group_slug, post_slug, language)
    end)

    if languages_to_clear != [] do
      Logger.info(
        "[Slugs] Cleared url_slug '#{url_slug_to_clear}' from post '#{post_slug}' languages: #{inspect(languages_to_clear)}"
      )
    end

    languages_to_clear
  end

  @doc """
  Generates a unique slug based on title and optional preferred slug.

  Returns `{:ok, slug}` or `{:error, reason}` where reason can be:
  - `:invalid_format` - slug has invalid format
  - `:reserved_language_code` - slug is a reserved language code
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
              {:ok, valid_slug} ->
                {:ok, valid_slug}

              {:error, reason} ->
                {:error, reason}
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

  defp slug_exists_for_generation?(_group_slug, candidate, current_slug)
       when not is_nil(current_slug) and candidate == current_slug,
       do: false

  defp slug_exists_for_generation?(group_slug, candidate, _current_slug) do
    slug_exists?(group_slug, candidate)
  end
end
