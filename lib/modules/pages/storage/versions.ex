defmodule PhoenixKit.Modules.Pages.Storage.Versions do
  @moduledoc """
  Version management for pages storage.

  Handles version detection, listing, status management,
  and version creation operations for posts.
  """

  alias PhoenixKit.Modules.Pages.Metadata
  alias PhoenixKit.Modules.Pages.Storage.Languages
  alias PhoenixKit.Modules.Pages.Storage.Paths

  @doc """
  Detects whether a post directory uses versioned structure (v1/, v2/, etc.)
  or legacy structure (files directly in post directory).

  Returns:
  - `:versioned` if v1/ or any vN/ directory exists
  - `:legacy` if .phk files exist directly in the directory
  - `:empty` if neither exists
  """
  @spec detect_post_structure(String.t()) :: :versioned | :legacy | :empty
  def detect_post_structure(post_path) do
    if File.dir?(post_path) do
      case File.ls(post_path) do
        {:ok, entries} ->
          has_version_dirs = Enum.any?(entries, &version_dir?/1)
          has_phk_files = Enum.any?(entries, &String.ends_with?(&1, ".phk"))

          cond do
            has_version_dirs -> :versioned
            has_phk_files -> :legacy
            true -> :empty
          end

        {:error, _} ->
          :empty
      end
    else
      :empty
    end
  end

  @doc """
  Check if a directory name matches version pattern (v1, v2, etc.)
  """
  @spec version_dir?(String.t()) :: boolean()
  def version_dir?(name) do
    Regex.match?(~r/^v\d+$/, name)
  end

  @doc """
  Lists all version numbers for a slug-mode post.
  Returns sorted list of integers (e.g., [1, 2, 3]).
  For legacy posts without version directories, returns [1].
  """
  @spec list_versions(String.t(), String.t()) :: [integer()]
  def list_versions(group_slug, post_slug) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])

    case detect_post_structure(post_path) do
      :versioned ->
        case File.ls(post_path) do
          {:ok, entries} ->
            entries
            |> Enum.filter(&version_dir?/1)
            |> Enum.map(&parse_version_number/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.sort()

          {:error, _} ->
            []
        end

      :legacy ->
        [1]

      :empty ->
        []
    end
  end

  @doc """
  Parse version number from directory name (e.g., "v2" -> 2)
  """
  @spec parse_version_number(String.t()) :: integer() | nil
  def parse_version_number("v" <> num_str) do
    case Integer.parse(num_str) do
      {num, ""} -> num
      _ -> nil
    end
  end

  def parse_version_number(_), do: nil

  @doc """
  Gets the latest (highest) version number for a post.
  """
  @spec get_latest_version(String.t(), String.t()) :: {:ok, integer()} | {:error, :not_found}
  def get_latest_version(group_slug, post_slug) do
    case list_versions(group_slug, post_slug) do
      [] -> {:error, :not_found}
      versions -> {:ok, Enum.max(versions)}
    end
  end

  @doc """
  Gets the latest published version number for a post.
  Checks each version's primary language file for status.
  """
  @spec get_latest_published_version(String.t(), String.t()) ::
          {:ok, integer()} | {:error, :not_found}
  def get_latest_published_version(group_slug, post_slug) do
    versions = list_versions(group_slug, post_slug)
    primary_language = Languages.get_post_primary_language(group_slug, post_slug, nil)

    published_version =
      versions
      |> Enum.sort(:desc)
      |> Enum.find(fn version ->
        case get_version_status(group_slug, post_slug, version, primary_language) do
          "published" -> true
          _ -> false
        end
      end)

    case published_version do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc """
  Gets the published version number for a post.
  Only ONE version can have status: "published" at a time in the variant versioning model.
  Falls back to checking legacy is_live field for unmigrated posts.
  """
  @spec get_published_version(String.t(), String.t()) :: {:ok, integer()} | {:error, :not_found}
  def get_published_version(group_slug, post_slug) do
    versions = list_versions(group_slug, post_slug)
    primary_language = Languages.get_post_primary_language(group_slug, post_slug, nil)

    published_version =
      Enum.find(versions, fn version ->
        case get_version_metadata(group_slug, post_slug, version, primary_language) do
          {:ok, metadata} -> Map.get(metadata, :status) == "published"
          _ -> false
        end
      end)

    # Fall back to legacy is_live for unmigrated posts
    published_version =
      published_version ||
        Enum.find(versions, fn version ->
          case get_version_metadata(group_slug, post_slug, version, primary_language) do
            {:ok, metadata} -> Map.get(metadata, :legacy_is_live) == true
            _ -> false
          end
        end)

    case published_version do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc """
  Deprecated: Use get_published_version/2 instead.
  """
  @deprecated "Use get_published_version/2 instead"
  @spec get_live_version(String.t(), String.t()) :: {:ok, integer()} | {:error, :not_found}
  def get_live_version(group_slug, post_slug) do
    get_published_version(group_slug, post_slug)
  end

  @doc """
  Gets the status of a specific version for a language.
  """
  @spec get_version_status(String.t(), String.t(), integer(), String.t()) :: String.t() | nil
  def get_version_status(group_slug, post_slug, version, language) do
    case get_version_metadata(group_slug, post_slug, version, language) do
      {:ok, metadata} -> Map.get(metadata, :status)
      _ -> nil
    end
  end

  @doc """
  Gets the metadata for a specific version and language.
  """
  @spec get_version_metadata(String.t(), String.t(), integer(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_version_metadata(group_slug, post_slug, version, language) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])

    file_path =
      case detect_post_structure(post_path) do
        :versioned ->
          Path.join([post_path, "v#{version}", Languages.language_filename(language)])

        :legacy when version == 1 ->
          Path.join([post_path, Languages.language_filename(language)])

        _ ->
          nil
      end

    if file_path && File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} ->
          {:ok, metadata, _body} = Metadata.parse_with_content(content)
          {:ok, metadata}

        {:error, _} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns the version directory path for a post.
  """
  @spec version_path(String.t(), String.t(), integer()) :: String.t()
  def version_path(group_slug, post_slug, version) do
    Path.join([Paths.group_path(group_slug), post_slug, "v#{version}"])
  end

  @doc """
  Loads version statuses for all versions of a post.
  Returns a map of version number => status.
  """
  @spec load_version_statuses(String.t(), String.t(), [integer()], String.t() | nil) ::
          %{integer() => String.t()}
  def load_version_statuses(group_slug, post_slug, versions, primary_language \\ nil) do
    primary_lang = primary_language || Languages.get_primary_language()

    Enum.reduce(versions, %{}, fn version, acc ->
      status = get_version_status(group_slug, post_slug, version, primary_lang)
      Map.put(acc, version, status)
    end)
  end

  @doc """
  Loads version_created_at dates for all specified versions.
  Returns a map of version number => ISO 8601 date string.
  """
  @spec load_version_dates(String.t(), String.t(), [integer()], String.t() | nil) :: %{
          integer() => String.t() | nil
        }
  def load_version_dates(group_slug, post_slug, versions, primary_language \\ nil) do
    primary_lang = primary_language || Languages.get_primary_language()

    Enum.reduce(versions, %{}, fn version, acc ->
      date = get_version_date(group_slug, post_slug, version, primary_lang)
      Map.put(acc, version, date)
    end)
  end

  @doc """
  Loads available languages for each version of a post.
  Returns a map of version number => list of language codes.

  This is useful for showing which translations exist for a specific version,
  e.g., to display the published version's translations in the listing.
  """
  @spec load_version_languages(String.t(), String.t(), [integer()]) :: %{
          integer() => [String.t()]
        }
  def load_version_languages(group_slug, post_slug, versions) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    structure = detect_post_structure(post_path)

    Enum.reduce(versions, %{}, fn version, acc ->
      languages = get_version_languages(post_path, structure, version)
      Map.put(acc, version, languages)
    end)
  end

  # Gets the available languages for a specific version
  defp get_version_languages(post_path, :versioned, version) do
    version_dir = Path.join(post_path, "v#{version}")
    Languages.detect_available_languages(version_dir)
  end

  defp get_version_languages(post_path, :legacy, 1) do
    Languages.detect_available_languages(post_path)
  end

  defp get_version_languages(_post_path, _structure, _version), do: []

  @doc """
  Gets the version_created_at date for a specific version.
  """
  @spec get_version_date(String.t(), String.t(), integer(), String.t()) :: String.t() | nil
  def get_version_date(group_slug, post_slug, version, language) do
    case get_version_metadata(group_slug, post_slug, version, language) do
      {:ok, metadata} -> Map.get(metadata, :version_created_at)
      _ -> nil
    end
  end

  @doc """
  Resolves which version directory to read from.
  """
  @spec resolve_version_dir(
          String.t(),
          :versioned | :legacy | :empty,
          integer() | nil,
          String.t(),
          String.t()
        ) ::
          {:ok, integer(), String.t()} | {:error, atom()}
  def resolve_version_dir(post_dir, :versioned, nil, group_slug, post_slug) do
    case get_latest_version(group_slug, post_slug) do
      {:ok, version} ->
        {:ok, version, Path.join(post_dir, "v#{version}")}

      {:error, _} ->
        {:error, :no_versions}
    end
  end

  def resolve_version_dir(post_dir, :versioned, version, _group_slug, _post_slug) do
    version_dir = Path.join(post_dir, "v#{version}")

    if File.dir?(version_dir) do
      {:ok, version, version_dir}
    else
      {:error, :version_not_found}
    end
  end

  def resolve_version_dir(post_dir, :legacy, _version, _group_slug, _post_slug) do
    {:ok, 1, post_dir}
  end

  def resolve_version_dir(_post_dir, :empty, _version, _group_slug, _post_slug) do
    {:error, :not_found}
  end

  @doc """
  Resolves the version directory for listing operations.
  Returns {:ok, version, content_dir} or {:error, reason}.
  """
  @spec resolve_version_dir_for_listing(
          String.t(),
          :versioned | :legacy | :empty,
          String.t(),
          String.t()
        ) ::
          {:ok, integer(), String.t()} | {:error, atom()}
  def resolve_version_dir_for_listing(post_path, :versioned, group_slug, post_slug) do
    case get_latest_version(group_slug, post_slug) do
      {:ok, version} ->
        {:ok, version, Path.join(post_path, "v#{version}")}

      {:error, _} ->
        {:error, :no_versions}
    end
  end

  def resolve_version_dir_for_listing(post_path, :legacy, _group_slug, _post_slug) do
    {:ok, 1, post_path}
  end

  def resolve_version_dir_for_listing(_post_path, :empty, _group_slug, _post_slug) do
    {:error, :empty}
  end

  @doc """
  Checks if a version is the published (live) version.
  """
  @spec version_is_published?(String.t(), String.t(), integer()) :: boolean()
  def version_is_published?(group_slug, post_identifier, version) do
    case get_published_version(group_slug, post_identifier) do
      {:ok, ^version} -> true
      _ -> false
    end
  end

  @doc """
  Checks if a post has only one version.
  """
  @spec only_version?(String.t()) :: boolean()
  def only_version?(post_dir) do
    case File.ls(post_dir) do
      {:ok, entries} ->
        version_dirs = Enum.filter(entries, &version_dir?/1)
        length(version_dirs) <= 1

      _ ->
        true
    end
  end
end
