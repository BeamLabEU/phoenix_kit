defmodule PhoenixKitWeb.Live.Modules.Blogging.Storage do
  @moduledoc """
  Filesystem storage helpers for blogging posts.

  Content is stored under:

      priv/blogging/<blog>/<YYYY-MM-DD>/<HH:MM>/<language>.phk

  Where <language> is determined by the site's content language setting.
  Files use the .phk (PhoenixKit) format, which supports XML-style
  component markup for building pages with swappable design variants.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitWeb.Live.Modules.Blogging.Metadata

  @doc """
  Returns the filename for a specific language code.
  """
  @spec language_filename(String.t()) :: String.t()
  def language_filename(language_code) do
    "#{language_code}.phk"
  end

  @doc """
  Returns the filename for language-specific posts based on the site's
  primary content language setting.
  """
  @spec language_filename() :: String.t()
  def language_filename do
    language_code = Settings.get_content_language()
    "#{language_code}.phk"
  end

  @doc """
  Returns all enabled language codes for multi-language support.
  Falls back to content language if Languages module is disabled.
  """
  @spec enabled_language_codes() :: [String.t()]
  def enabled_language_codes do
    if Languages.enabled?() do
      Languages.get_enabled_language_codes()
    else
      [Settings.get_content_language()]
    end
  end

  @doc """
  Returns the master/canonical language for versioning.
  This is the explicitly configured content language from Settings.
  Falls back to first enabled language if not configured.

  This should be used instead of `hd(enabled_language_codes())` when
  determining which language controls versioning logic.
  """
  @spec get_master_language() :: String.t()
  def get_master_language do
    # Use explicit content language setting for master language detection
    # This is more reliable than list position which can change
    case Settings.get_content_language() do
      nil ->
        # Fall back to first enabled language, or "en" if none configured
        case enabled_language_codes() do
          [] -> "en"
          [first | _] -> first
        end

      content_lang ->
        content_lang
    end
  end

  @doc """
  Gets language details (name, flag) for a given language code.

  Searches in order:
  1. Predefined languages (BeamLabCountries) - for full locale details
  2. User-configured languages - for custom/less common languages
  """
  @spec get_language_info(String.t()) ::
          %{code: String.t(), name: String.t(), flag: String.t()} | nil
  def get_language_info(language_code) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # First try predefined languages (BeamLabCountries has the most complete info)
    predefined = find_in_predefined_languages(language_code)

    if predefined do
      predefined
    else
      # Fall back to user-configured languages
      # This handles custom language codes like "af" that might not be in BeamLabCountries
      find_in_configured_languages(language_code)
    end
  end

  # Search predefined languages (BeamLabCountries) with base code fallback
  defp find_in_predefined_languages(language_code) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    all_languages = Languages.get_available_languages()

    # First try exact match
    exact_match = Enum.find(all_languages, fn lang -> lang.code == language_code end)

    if exact_match do
      exact_match
    else
      # Try matching by base code (e.g., "en" matches "en-US")
      base_code = DialectMapper.extract_base(language_code)

      Enum.find(all_languages, fn lang ->
        DialectMapper.extract_base(lang.code) == base_code
      end)
    end
  end

  # Search user-configured languages with base code fallback
  defp find_in_configured_languages(language_code) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    configured_languages = Languages.get_languages()

    # First try exact match
    exact_match =
      Enum.find(configured_languages, fn lang -> lang["code"] == language_code end)

    result =
      if exact_match do
        exact_match
      else
        # Try matching by base code
        base_code = DialectMapper.extract_base(language_code)

        Enum.find(configured_languages, fn lang ->
          DialectMapper.extract_base(lang["code"]) == base_code
        end)
      end

    # Convert string-keyed map to atom-keyed map for consistency
    if result do
      %{
        code: result["code"],
        name: result["name"] || result["code"],
        flag: result["flag"] || ""
      }
    else
      nil
    end
  end

  @doc """
  Checks if a language code is enabled, considering base code matching.

  This handles cases where:
  - The file is `en.phk` and enabled languages has `"en-US"` → matches
  - The file is `en-US.phk` and enabled languages has `"en"` → matches
  - The file is `af.phk` and enabled languages has `"af"` → matches
  """
  @spec language_enabled?(String.t(), [String.t()]) :: boolean()
  def language_enabled?(language_code, enabled_languages) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Direct match
    if language_code in enabled_languages do
      true
    else
      # Base code matching
      base_code = DialectMapper.extract_base(language_code)

      Enum.any?(enabled_languages, fn enabled_lang ->
        # Check if enabled language matches directly or by base code
        enabled_lang == language_code or
          DialectMapper.extract_base(enabled_lang) == base_code
      end)
    end
  end

  @doc """
  Determines the display code for a language based on whether multiple dialects
  of the same base language are enabled.

  If only one dialect of a base language is enabled (e.g., just "en-US"),
  returns the base code ("en") for cleaner display.

  If multiple dialects are enabled (e.g., "en-US" and "en-GB"),
  returns the full dialect code ("en-US") to distinguish them.

  ## Parameters
    - `language_code` - the full language/dialect code (e.g., "en-US")
    - `enabled_languages` - list of all enabled language codes

  ## Examples
      # Only en-US enabled
      iex> get_display_code("en-US", ["en-US", "fr-FR"])
      "en"

      # Both en-US and en-GB enabled
      iex> get_display_code("en-US", ["en-US", "en-GB", "fr-FR"])
      "en-US"
  """
  @spec get_display_code(String.t(), [String.t()]) :: String.t()
  def get_display_code(language_code, enabled_languages) do
    base_code = DialectMapper.extract_base(language_code)

    # Count how many enabled languages share this base code
    dialects_count =
      Enum.count(enabled_languages, fn lang ->
        DialectMapper.extract_base(lang) == base_code
      end)

    # If more than one dialect of this base language is enabled, show full code
    if dialects_count > 1 do
      language_code
    else
      base_code
    end
  end

  @doc """
  Orders languages for display in the language switcher.

  Order: primary language first, then languages with translations (sorted),
  then languages without translations (sorted). This ensures consistent order
  across all views regardless of which language is currently being edited.

  ## Parameters
    - `available_languages` - list of language codes that have translations
    - `enabled_languages` - list of all enabled language codes

  ## Returns
    List of language codes in consistent display order.
  """
  @spec order_languages_for_display([String.t()], [String.t()]) :: [String.t()]
  def order_languages_for_display(available_languages, enabled_languages) do
    primary_language = List.first(enabled_languages) || "en"

    # Languages with content (excluding primary), sorted alphabetically
    langs_with_content =
      available_languages
      |> Enum.reject(&(&1 == primary_language))
      |> Enum.sort()

    # Enabled languages without content (excluding primary), sorted alphabetically
    langs_without_content =
      enabled_languages
      |> Enum.reject(&(&1 in available_languages or &1 == primary_language))
      |> Enum.sort()

    # Final order: primary first, then with content, then without
    [primary_language] ++ langs_with_content ++ langs_without_content
  end

  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

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

      reserved_language_code?(slug) ->
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

  # Check if slug is a reserved language code
  defp reserved_language_code?(slug) do
    language_codes =
      try do
        Languages.get_language_codes()
      rescue
        _ -> []
      end

    slug in language_codes
  end

  @doc """
  Checks if a slug already exists within the given blog.
  """
  @spec slug_exists?(String.t(), String.t()) :: boolean()
  def slug_exists?(blog_slug, post_slug) do
    Path.join([root_path(), blog_slug, post_slug])
    |> File.dir?()
  end

  defp slug_exists_for_generation?(_blog_slug, candidate, current_slug)
       when not is_nil(current_slug) and candidate == current_slug,
       do: false

  defp slug_exists_for_generation?(blog_slug, candidate, _current_slug) do
    slug_exists?(blog_slug, candidate)
  end

  @doc """
  Generates a unique slug based on title and optional preferred slug.

  Returns `{:ok, slug}` or `{:error, reason}` where reason can be:
  - `:invalid_format` - slug has invalid format
  - `:reserved_language_code` - slug is a reserved language code
  """
  @spec generate_unique_slug(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, :invalid_format | :reserved_language_code}
  def generate_unique_slug(blog_slug, title, preferred_slug \\ nil, opts \\ []) do
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
            # Validate the sanitized slug
            case validate_slug(sanitized) do
              {:ok, valid_slug} ->
                {:ok, valid_slug}

              {:error, reason} ->
                # Return the specific error instead of falling back
                {:error, reason}
            end
          end
      end

    case base_slug_result do
      {:ok, base_slug} when base_slug != "" ->
        {:ok,
         Slug.ensure_unique(base_slug, fn candidate ->
           slug_exists_for_generation?(blog_slug, candidate, current_slug)
         end)}

      {:ok, ""} ->
        # Empty slug - return empty for auto-generation, will show placeholder
        {:ok, ""}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # slug helpers now handled by PhoenixKit.Utils.Slug

  @typedoc """
  A blog post with metadata and content.

  The `language_statuses` field is preloaded when fetching posts via `list_posts/2`
  or `read_post/2` to avoid redundant file reads. It maps language codes to their
  publication status (e.g., `%{"en" => "published", "es" => "draft"}`).

  Version fields:
  - `version`: Current version number (1, 2, 3...)
  - `available_versions`: List of all version numbers for this post
  - `version_statuses`: Map of version => status for quick lookup
  """
  @type post :: %{
          blog: String.t() | nil,
          slug: String.t() | nil,
          date: Date.t() | nil,
          time: Time.t() | nil,
          path: String.t(),
          full_path: String.t(),
          metadata: map(),
          content: String.t(),
          language: String.t(),
          available_languages: [String.t()],
          language_statuses: %{String.t() => String.t() | nil},
          mode: :slug | :timestamp | nil,
          # Version fields
          version: integer() | nil,
          available_versions: [integer()],
          version_statuses: %{integer() => String.t()},
          version_dates: %{integer() => String.t() | nil},
          is_legacy_structure: boolean()
        }

  @doc """
  Returns the blogging root directory, creating it if needed.
  Always uses the parent application's priv directory.
  """
  @spec root_path() :: String.t()
  def root_path do
    parent_app =
      case PhoenixKit.Config.get_parent_app() do
        nil ->
          raise """
          PhoenixKit parent app not configured.
          Cannot determine storage path for blogging module.

          Please add the following to your config/config.exs:

              config :phoenix_kit, parent_app_name: :your_app_name
          """

        app ->
          app
      end

    # Get the parent app's priv directory
    # This ensures files are always stored in the parent app, not in PhoenixKit's deps folder
    base_priv = Application.app_dir(parent_app, "priv")
    base = Path.join(base_priv, "blogging")

    File.mkdir_p!(base)
    base
  end

  @doc """
  Ensures the folder for a blog exists.
  """
  @spec ensure_blog_root(String.t()) :: :ok | {:error, term()}
  def ensure_blog_root(blog_slug) do
    Path.join(root_path(), blog_slug)
    |> File.mkdir_p()
  end

  # ===========================================================================
  # Version Management Functions
  # ===========================================================================

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

  # Check if a directory name matches version pattern (v1, v2, etc.)
  defp version_dir?(name) do
    Regex.match?(~r/^v\d+$/, name)
  end

  @doc """
  Lists all version numbers for a slug-mode post.
  Returns sorted list of integers (e.g., [1, 2, 3]).
  For legacy posts without version directories, returns [1].
  """
  @spec list_versions(String.t(), String.t()) :: [integer()]
  def list_versions(blog_slug, post_slug) do
    post_path = Path.join([root_path(), blog_slug, post_slug])

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
        # Legacy posts are treated as v1
        [1]

      :empty ->
        []
    end
  end

  # Parse version number from directory name (e.g., "v2" -> 2)
  defp parse_version_number("v" <> num_str) do
    case Integer.parse(num_str) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp parse_version_number(_), do: nil

  @doc """
  Gets the latest (highest) version number for a post.
  """
  @spec get_latest_version(String.t(), String.t()) :: {:ok, integer()} | {:error, :not_found}
  def get_latest_version(blog_slug, post_slug) do
    case list_versions(blog_slug, post_slug) do
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
  def get_latest_published_version(blog_slug, post_slug) do
    versions = list_versions(blog_slug, post_slug)
    primary_language = get_master_language()

    # Check versions in reverse order (newest first)
    published_version =
      versions
      |> Enum.sort(:desc)
      |> Enum.find(fn version ->
        case get_version_status(blog_slug, post_slug, version, primary_language) do
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
  Gets the live version number for a post (the one with is_live: true).
  Falls back to latest published if no version is explicitly marked as live.
  """
  @spec get_live_version(String.t(), String.t()) :: {:ok, integer()} | {:error, :not_found}
  def get_live_version(blog_slug, post_slug) do
    versions = list_versions(blog_slug, post_slug)
    primary_language = get_master_language()

    # Find version marked as live
    live_version =
      Enum.find(versions, fn version ->
        case get_version_metadata(blog_slug, post_slug, version, primary_language) do
          {:ok, metadata} -> metadata[:is_live] == true
          _ -> false
        end
      end)

    case live_version do
      nil ->
        # Fall back to latest published
        get_latest_published_version(blog_slug, post_slug)

      version ->
        {:ok, version}
    end
  end

  @doc """
  Gets the status of a specific version for a language.
  """
  @spec get_version_status(String.t(), String.t(), integer(), String.t()) :: String.t() | nil
  def get_version_status(blog_slug, post_slug, version, language) do
    case get_version_metadata(blog_slug, post_slug, version, language) do
      {:ok, metadata} -> Map.get(metadata, :status)
      _ -> nil
    end
  end

  @doc """
  Gets the metadata for a specific version and language.
  """
  @spec get_version_metadata(String.t(), String.t(), integer(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_version_metadata(blog_slug, post_slug, version, language) do
    post_path = Path.join([root_path(), blog_slug, post_slug])

    file_path =
      case detect_post_structure(post_path) do
        :versioned ->
          Path.join([post_path, "v#{version}", language_filename(language)])

        :legacy when version == 1 ->
          Path.join([post_path, language_filename(language)])

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
  def version_path(blog_slug, post_slug, version) do
    Path.join([root_path(), blog_slug, post_slug, "v#{version}"])
  end

  @doc """
  Loads version statuses for all versions of a post.
  Returns a map of version number => status.
  """
  @spec load_version_statuses(String.t(), String.t(), [integer()]) :: %{integer() => String.t()}
  def load_version_statuses(blog_slug, post_slug, versions) do
    primary_language = get_master_language()

    Enum.reduce(versions, %{}, fn version, acc ->
      status = get_version_status(blog_slug, post_slug, version, primary_language)
      Map.put(acc, version, status)
    end)
  end

  @doc """
  Loads version_created_at dates for all specified versions.
  Returns a map of version number => ISO 8601 date string.
  """
  @spec load_version_dates(String.t(), String.t(), [integer()]) :: %{
          integer() => String.t() | nil
        }
  def load_version_dates(blog_slug, post_slug, versions) do
    primary_language = get_master_language()

    Enum.reduce(versions, %{}, fn version, acc ->
      date = get_version_date(blog_slug, post_slug, version, primary_language)
      Map.put(acc, version, date)
    end)
  end

  @doc """
  Gets the version_created_at date for a specific version.
  """
  @spec get_version_date(String.t(), String.t(), integer(), String.t()) :: String.t() | nil
  def get_version_date(blog_slug, post_slug, version, language) do
    case get_version_metadata(blog_slug, post_slug, version, language) do
      {:ok, metadata} -> Map.get(metadata, :version_created_at)
      _ -> nil
    end
  end

  @doc """
  Creates a new version of a slug-mode post by copying from the source version.

  The new version:
  - Gets the next version number
  - Copies all language files from the source version
  - Starts as draft (is_live: false)
  - Applies any content/metadata updates from params

  Returns the new post struct for the primary language.
  """
  @spec create_new_version(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def create_new_version(blog_slug, source_post, params \\ %{}, audit_meta \\ %{})

  def create_new_version(blog_slug, source_post, params, audit_meta) when is_list(audit_meta) do
    create_new_version(blog_slug, source_post, params, Map.new(audit_meta))
  end

  def create_new_version(blog_slug, source_post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Handle based on post mode
    case source_post.mode do
      :slug ->
        create_new_version_slug_mode(blog_slug, source_post, params, audit_meta, now)

      :timestamp ->
        create_new_version_timestamp_mode(blog_slug, source_post, params, audit_meta, now)

      _ ->
        {:error, :unsupported_mode}
    end
  end

  defp create_new_version_slug_mode(blog_slug, source_post, params, audit_meta, now) do
    create_new_version_slug_mode_with_retry(blog_slug, source_post, params, audit_meta, now, 3)
  end

  # Retry mechanism to handle concurrent version creation
  defp create_new_version_slug_mode_with_retry(
         _blog_slug,
         _source_post,
         _params,
         _audit_meta,
         _now,
         0
       ) do
    {:error, :version_creation_conflict}
  end

  defp create_new_version_slug_mode_with_retry(
         blog_slug,
         source_post,
         params,
         audit_meta,
         now,
         retries
       ) do
    # Get next version number
    current_versions = list_versions(blog_slug, source_post.slug)
    new_version = Enum.max(current_versions, fn -> 0 end) + 1

    # Create new version directory (non-bang version to check for conflict)
    new_version_dir = version_path(blog_slug, source_post.slug, new_version)

    case File.mkdir(new_version_dir) do
      :ok ->
        # Successfully created - proceed with copying files
        copy_language_files_to_new_version(
          source_post,
          new_version_dir,
          new_version,
          params,
          audit_meta,
          now
        )

        # Read back the new version for the master language
        master_language = get_master_language()
        read_post_slug_mode(blog_slug, source_post.slug, master_language, new_version)

      {:error, :eexist} ->
        # Directory already exists (race condition) - retry with fresh version list
        create_new_version_slug_mode_with_retry(
          blog_slug,
          source_post,
          params,
          audit_meta,
          now,
          retries - 1
        )

      {:error, :enoent} ->
        # Parent directory doesn't exist - create it and retry
        File.mkdir_p!(Path.dirname(new_version_dir))

        create_new_version_slug_mode_with_retry(
          blog_slug,
          source_post,
          params,
          audit_meta,
          now,
          retries - 1
        )

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp create_new_version_timestamp_mode(blog_slug, source_post, params, audit_meta, now) do
    post_dir = Path.dirname(Path.dirname(source_post.full_path))

    create_new_version_timestamp_mode_with_retry(
      blog_slug,
      source_post,
      params,
      audit_meta,
      now,
      post_dir,
      3
    )
  end

  # Retry mechanism to handle concurrent version creation for timestamp mode
  defp create_new_version_timestamp_mode_with_retry(
         _blog_slug,
         _source_post,
         _params,
         _audit_meta,
         _now,
         _post_dir,
         0
       ) do
    {:error, :version_creation_conflict}
  end

  defp create_new_version_timestamp_mode_with_retry(
         blog_slug,
         source_post,
         params,
         audit_meta,
         now,
         post_dir,
         retries
       ) do
    # Get next version number for timestamp mode
    current_versions = list_versions_for_timestamp(post_dir)
    new_version = Enum.max(current_versions, fn -> 0 end) + 1

    # Create new version directory (non-bang version to check for conflict)
    new_version_dir = Path.join(post_dir, "v#{new_version}")

    case File.mkdir(new_version_dir) do
      :ok ->
        # Successfully created - proceed with copying files
        copy_language_files_to_new_version(
          source_post,
          new_version_dir,
          new_version,
          params,
          audit_meta,
          now
        )

        # Build new path and read back the new version (use master language)
        master_language = get_master_language()

        new_relative_path =
          relative_path_with_language_versioned(
            blog_slug,
            source_post.date,
            source_post.time,
            new_version,
            master_language
          )

        read_post(blog_slug, new_relative_path)

      {:error, :eexist} ->
        # Directory already exists (race condition) - retry with fresh version list
        create_new_version_timestamp_mode_with_retry(
          blog_slug,
          source_post,
          params,
          audit_meta,
          now,
          post_dir,
          retries - 1
        )

      {:error, :enoent} ->
        # Parent directory doesn't exist - create it and retry
        File.mkdir_p!(post_dir)

        create_new_version_timestamp_mode_with_retry(
          blog_slug,
          source_post,
          params,
          audit_meta,
          now,
          post_dir,
          retries - 1
        )

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp copy_language_files_to_new_version(
         source_post,
         new_version_dir,
         new_version,
         params,
         audit_meta,
         now
       ) do
    source_version_dir = Path.dirname(source_post.full_path)

    # Only copy the master language file to the new version
    # Translations stay with their version - new versions start fresh
    # Use explicit content language setting for master language detection
    master_language = get_master_language()
    source_file = Path.join(source_version_dir, language_filename(master_language))
    target_file = Path.join(new_version_dir, language_filename(master_language))

    if File.exists?(source_file) do
      {:ok, source_metadata, source_content} =
        source_file
        |> File.read!()
        |> Metadata.parse_with_content()

      # Only apply content/title params when editing master language
      # This prevents translation content from leaking to master file
      editing_master? = source_post.language == master_language

      # Apply params updates and version metadata
      new_metadata =
        source_metadata
        |> Map.put(:version, new_version)
        |> Map.put(:version_created_at, DateTime.to_iso8601(now))
        |> Map.put(:version_created_from, source_post.version || 1)
        |> Map.put(:is_live, false)
        |> Map.put(:status, "draft")
        |> then(fn meta ->
          if editing_master? do
            meta
            |> Map.put(:title, Map.get(params, "title", source_metadata.title))
            |> Map.put(:featured_image_id, resolve_featured_image_id(params, source_metadata))
          else
            meta
          end
        end)
        |> apply_creation_audit_metadata(audit_meta)

      new_content =
        if editing_master?, do: Map.get(params, "content", source_content), else: source_content

      serialized =
        Metadata.serialize(new_metadata) <> "\n\n" <> String.trim_leading(new_content)

      File.write!(target_file, serialized <> "\n")
    end
  end

  @doc """
  Sets a version as the live version, clearing is_live from all other versions.
  Called when publishing a new version.
  """
  @spec set_version_live(String.t(), String.t(), integer()) :: :ok | {:error, any()}
  def set_version_live(blog_slug, post_slug, live_version) do
    post_path = Path.join([root_path(), blog_slug, post_slug])
    versions = list_versions(blog_slug, post_slug)

    Enum.each(versions, fn version ->
      version_dir =
        case detect_post_structure(post_path) do
          :versioned -> Path.join(post_path, "v#{version}")
          :legacy -> post_path
        end

      # Update is_live for all language files in this version
      case File.ls(version_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".phk"))
          |> Enum.each(fn file ->
            file_path = Path.join(version_dir, file)
            update_is_live_in_file(file_path, version == live_version)
          end)

        {:error, _} ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Migrates a single post from legacy structure to versioned structure.

  Moves all .phk files from the post directory into a v1/ subdirectory
  and updates metadata to include version fields.

  Works for both slug-mode and timestamp-mode posts.

  Returns the migrated post for the given language.
  """
  @spec migrate_post_to_versioned(post(), String.t() | nil) :: {:ok, post()} | {:error, any()}
  def migrate_post_to_versioned(post, language \\ nil) do
    language = language || post.language
    post_dir = Path.dirname(post.full_path)

    # Only migrate if it's actually a legacy structure
    if post.is_legacy_structure do
      do_migrate_post_to_versioned(post, post_dir, language)
    else
      # Already versioned, just return the post
      {:ok, post}
    end
  end

  defp do_migrate_post_to_versioned(post, post_dir, language) do
    v1_dir = Path.join(post_dir, "v1")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Create v1 directory
    case File.mkdir_p(v1_dir) do
      :ok ->
        # Get all .phk files in the post directory
        case File.ls(post_dir) do
          {:ok, files} ->
            phk_files = Enum.filter(files, &String.ends_with?(&1, ".phk"))

            if phk_files == [] do
              {:error, :no_files}
            else
              # Move each file to v1/ and update metadata
              results =
                Enum.map(phk_files, fn file ->
                  migrate_single_file_to_v1(post_dir, v1_dir, file, now, post.metadata)
                end)

              if Enum.all?(results, &(&1 == :ok)) do
                # Re-read the post from the new location
                case post.mode do
                  :slug ->
                    read_post_slug_mode(post.blog, post.slug, language, 1)

                  :timestamp ->
                    # Build new path for timestamp mode
                    new_relative_path =
                      relative_path_with_language_versioned(
                        post.blog,
                        post.date,
                        post.time,
                        1,
                        language
                      )

                    read_post(post.blog, new_relative_path)

                  _ ->
                    {:error, :unknown_mode}
                end
              else
                errors = Enum.reject(results, &(&1 == :ok))
                {:error, {:migration_failed, errors}}
              end
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp migrate_single_file_to_v1(post_dir, v1_dir, filename, now, source_metadata) do
    source_path = Path.join(post_dir, filename)
    target_path = Path.join(v1_dir, filename)

    case File.read(source_path) do
      {:ok, content} ->
        {:ok, metadata, body} = Metadata.parse_with_content(content)

        # Add version fields, preserving existing values if present
        updated_metadata =
          metadata
          |> Map.put_new(:version, 1)
          |> Map.put_new(:version_created_at, DateTime.to_iso8601(now))
          |> Map.put_new(:version_created_from, nil)
          |> Map.put_new(:is_live, Map.get(source_metadata, :status) == "published")

        # Serialize and write to v1/
        serialized = Metadata.serialize(updated_metadata) <> "\n\n" <> String.trim_leading(body)

        case File.write(target_path, serialized <> "\n") do
          :ok ->
            # Remove original file
            case File.rm(source_path) do
              :ok -> :ok
              {:error, reason} -> {:error, {:rm_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  # Update is_live field in a single file
  defp update_is_live_in_file(file_path, is_live) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, metadata, body} = Metadata.parse_with_content(content)
        updated_metadata = Map.put(metadata, :is_live, is_live)
        serialized = Metadata.serialize(updated_metadata) <> "\n\n" <> String.trim_leading(body)
        File.write!(file_path, serialized <> "\n")

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Checks if the content or title has changed between the post and params.
  Used to determine if a new version should be created.
  """
  @spec content_changed?(post(), map()) :: boolean()
  def content_changed?(post, params) do
    current_content = post.content || ""
    new_content = Map.get(params, "content", current_content)

    current_title = Map.get(post.metadata, :title, "")
    new_title = Map.get(params, "title", current_title)

    # Normalize for comparison
    String.trim(current_content) != String.trim(new_content) or
      String.trim(current_title) != String.trim(new_title)
  end

  @doc """
  Checks if only the status is being changed (no content or title changes).
  Status-only changes don't require a new version.
  """
  @spec status_change_only?(post(), map()) :: boolean()
  def status_change_only?(post, params) do
    # Check if status is changing
    current_status = Map.get(post.metadata, :status, "draft")
    new_status = Map.get(params, "status", current_status)
    status_changing? = current_status != new_status

    # Check if anything else is changing
    content_changing? = content_changed?(post, params)

    # Check if featured_image_id is changing
    current_image = Map.get(post.metadata, :featured_image_id)
    new_image = resolve_featured_image_id(params, post.metadata)
    image_changing? = current_image != new_image

    # Status-only if status is changing but content/title/image are not
    status_changing? and not content_changing? and not image_changing?
  end

  @doc """
  Determines if a new version should be created based on the edit context.

  A new version is created when:
  1. The post is published (status == "published")
  2. Content or title is being changed (not just status change)
  3. This is the master language (translations don't trigger new versions)
  """
  @spec should_create_new_version?(post(), map(), String.t()) :: boolean()
  def should_create_new_version?(post, params, editing_language) do
    # Check if post is currently published
    is_published? = Map.get(post.metadata, :status) == "published"

    # Check if this is the master language (uses explicit content language setting)
    master_language = get_master_language()
    is_master_language? = editing_language == master_language

    # Check if content is changing (not just status)
    content_is_changing? = content_changed?(post, params)

    # Only create new version if all conditions are met
    is_published? and is_master_language? and content_is_changing?
  end

  @doc """
  Renames a blog directory on disk when the slug changes.
  """
  @spec rename_blog_directory(String.t(), String.t()) :: :ok | {:error, term()}
  def rename_blog_directory(old_slug, new_slug) when old_slug == new_slug, do: :ok

  def rename_blog_directory(old_slug, new_slug) do
    source = Path.join(root_path(), old_slug)
    destination = Path.join(root_path(), new_slug)

    cond do
      not File.dir?(source) ->
        :ok

      File.exists?(destination) ->
        {:error, :destination_exists}

      true ->
        case File.rename(source, destination) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Moves a blog directory to trash by renaming it with a timestamp.
  The blog directory is moved to: trash/BLOGNAME-YYYY-MM-DD-HH-MM-SS

  Returns {:ok, new_name} on success or {:error, reason} on failure.
  """
  @spec move_blog_to_trash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def move_blog_to_trash(blog_slug) do
    source = Path.join(root_path(), blog_slug)

    if File.dir?(source) do
      # Ensure trash directory exists
      trash_dir = Path.join(root_path(), "trash")
      File.mkdir_p!(trash_dir)

      timestamp =
        DateTime.utc_now()
        |> Calendar.strftime("%Y-%m-%d-%H-%M-%S")

      new_name = "#{blog_slug}-#{timestamp}"
      destination = Path.join(trash_dir, new_name)

      case File.rename(source, destination) do
        :ok -> {:ok, "trash/#{new_name}"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Moves a post to the trash folder.

  For slug-mode blogs, moves the entire post directory (all versions and languages).
  For timestamp-mode blogs, moves the time folder.

  The post directory is moved to:
    priv/blogging/trash/<blog_slug>/<post_identifier>-<timestamp>/

  Returns {:ok, trash_path} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_post(blog_slug, post_identifier) do
    # Determine the post directory based on mode
    post_dir = resolve_post_directory(blog_slug, post_identifier)

    if File.dir?(post_dir) do
      # Ensure trash directory exists for this blog
      trash_dir = Path.join([root_path(), "trash", blog_slug])
      File.mkdir_p!(trash_dir)

      timestamp =
        DateTime.utc_now()
        |> Calendar.strftime("%Y-%m-%d-%H-%M-%S")

      # Use sanitized identifier for trash folder name
      sanitized_id = sanitize_for_trash(post_identifier)
      new_name = "#{sanitized_id}-#{timestamp}"
      destination = Path.join(trash_dir, new_name)

      case File.rename(post_dir, destination) do
        :ok ->
          # Clean up empty parent directories (for timestamp mode)
          cleanup_empty_dirs(Path.dirname(post_dir))
          {:ok, "trash/#{blog_slug}/#{new_name}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  # Resolve the post directory path based on the identifier format
  defp resolve_post_directory(blog_slug, post_identifier) do
    # Check if it's a date/time path (timestamp mode) or a slug (slug mode)
    if String.contains?(post_identifier, "/") do
      # Could be "2025-01-15/14:30" or "post-slug/v1/en.phk"
      # Take just the main identifier part
      parts = String.split(post_identifier, "/", trim: true)

      case parts do
        [date, time | _] when byte_size(date) == 10 and byte_size(time) >= 4 ->
          # Timestamp mode: date/time format
          Path.join([root_path(), blog_slug, date, time])

        [slug | _] ->
          # Slug mode with path components
          Path.join([root_path(), blog_slug, slug])
      end
    else
      # Simple slug
      Path.join([root_path(), blog_slug, post_identifier])
    end
  end

  # Sanitize identifier for use in trash folder name
  defp sanitize_for_trash(identifier) do
    identifier
    |> String.replace("/", "_")
    |> String.replace(":", "-")
  end

  @doc """
  Deletes a specific language file from a post.

  For versioned posts, specify the version. For legacy posts, version is ignored.
  Refuses to delete the last remaining language file.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_language(String.t(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, term()}
  def delete_language(blog_slug, post_identifier, language_code, version \\ nil) do
    post_dir = resolve_post_directory(blog_slug, post_identifier)

    unless File.dir?(post_dir) do
      {:error, :post_not_found}
    else
      structure = detect_post_structure(post_dir)
      do_delete_language(post_dir, structure, language_code, version, blog_slug, post_identifier)
    end
  end

  defp do_delete_language(post_dir, :versioned, language_code, version, blog_slug, post_identifier) do
    # For versioned posts, we need to know which version
    target_version = version || get_latest_version_number(blog_slug, post_identifier)

    case target_version do
      nil ->
        {:error, :version_not_found}

      v ->
        version_dir = Path.join(post_dir, "v#{v}")
        delete_language_from_directory(version_dir, language_code)
    end
  end

  defp do_delete_language(post_dir, :legacy, language_code, _version, _blog_slug, _post_id) do
    delete_language_from_directory(post_dir, language_code)
  end

  defp do_delete_language(_post_dir, :empty, _language_code, _version, _blog_slug, _post_id) do
    {:error, :post_not_found}
  end

  defp delete_language_from_directory(dir, language_code) do
    file_path = Path.join(dir, "#{language_code}.phk")

    unless File.exists?(file_path) do
      {:error, :language_not_found}
    else
      # Check if this is the last language file
      case File.ls(dir) do
        {:ok, files} ->
          phk_files = Enum.filter(files, &String.ends_with?(&1, ".phk"))

          if length(phk_files) <= 1 do
            {:error, :cannot_delete_last_language}
          else
            case File.rm(file_path) do
              :ok -> :ok
              {:error, reason} -> {:error, reason}
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_latest_version_number(blog_slug, post_identifier) do
    case get_latest_version(blog_slug, post_identifier) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  @doc """
  Deletes an entire version of a post.

  Moves the version folder to trash instead of permanent deletion.
  Refuses to delete the last remaining version or the live version.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_version(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def delete_version(blog_slug, post_identifier, version) do
    post_dir = resolve_post_directory(blog_slug, post_identifier)

    unless File.dir?(post_dir) do
      {:error, :post_not_found}
    else
      structure = detect_post_structure(post_dir)

      case structure do
        :versioned ->
          do_delete_version(post_dir, blog_slug, post_identifier, version)

        :legacy ->
          {:error, :not_versioned}

        :empty ->
          {:error, :post_not_found}
      end
    end
  end

  defp do_delete_version(post_dir, blog_slug, post_identifier, version) do
    version_dir = Path.join(post_dir, "v#{version}")

    cond do
      not File.dir?(version_dir) ->
        {:error, :version_not_found}

      version_is_live?(blog_slug, post_identifier, version) ->
        {:error, :cannot_delete_live_version}

      only_version?(post_dir) ->
        {:error, :cannot_delete_last_version}

      true ->
        # Move to trash instead of permanent deletion
        trash_dir = Path.join([root_path(), "trash", blog_slug, post_identifier])
        File.mkdir_p!(trash_dir)

        timestamp =
          DateTime.utc_now()
          |> Calendar.strftime("%Y-%m-%d-%H-%M-%S")

        destination = Path.join(trash_dir, "v#{version}-#{timestamp}")

        case File.rename(version_dir, destination) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp version_is_live?(blog_slug, post_identifier, version) do
    case get_live_version(blog_slug, post_identifier) do
      {:ok, ^version} -> true
      _ -> false
    end
  end

  defp only_version?(post_dir) do
    case File.ls(post_dir) do
      {:ok, entries} ->
        version_dirs = Enum.filter(entries, &version_dir?/1)
        length(version_dirs) <= 1

      _ ->
        true
    end
  end

  @doc """
  Counts the number of posts on a specific date for a blog.
  Used to determine if time should be included in URLs.
  """
  @spec count_posts_on_date(String.t(), Date.t() | String.t()) :: non_neg_integer()
  def count_posts_on_date(blog_slug, %Date{} = date) do
    count_posts_on_date(blog_slug, Date.to_iso8601(date))
  end

  def count_posts_on_date(blog_slug, date_string) when is_binary(date_string) do
    date_path = Path.join([root_path(), blog_slug, date_string])

    if File.dir?(date_path) do
      case File.ls(date_path) do
        {:ok, time_folders} ->
          # Count folders that look like time folders (HH:MM format)
          Enum.count(time_folders, fn folder ->
            String.match?(folder, ~r/^\d{2}:\d{2}$/)
          end)

        {:error, _} ->
          0
      end
    else
      0
    end
  end

  @doc """
  Lists all time folders (posts) for a specific date in a blog.
  Returns a list of time strings in HH:MM format, sorted.
  """
  @spec list_times_on_date(String.t(), Date.t() | String.t()) :: [String.t()]
  def list_times_on_date(blog_slug, %Date{} = date) do
    list_times_on_date(blog_slug, Date.to_iso8601(date))
  end

  def list_times_on_date(blog_slug, date_string) when is_binary(date_string) do
    date_path = Path.join([root_path(), blog_slug, date_string])

    if File.dir?(date_path) do
      case File.ls(date_path) do
        {:ok, time_folders} ->
          time_folders
          |> Enum.filter(fn folder -> String.match?(folder, ~r/^\d{2}:\d{2}$/) end)
          |> Enum.sort()

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  @doc """
  Lists posts for the given blog.
  Accepts optional preferred_language to show titles in user's language.
  Falls back to content language, then first available language.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [post()]
  def list_posts(blog_slug, preferred_language \\ nil) do
    blog_root = Path.join(root_path(), blog_slug)

    if File.dir?(blog_root) do
      blog_root
      |> File.ls!()
      |> Enum.flat_map(
        &posts_for_date(blog_slug, &1, Path.join(blog_root, &1), preferred_language)
      )
      |> Enum.sort_by(&{&1.date, &1.time}, :desc)
    else
      []
    end
  end

  defp posts_for_date(blog_slug, date_folder, date_path, preferred_language) do
    case Date.from_iso8601(date_folder) do
      {:ok, date} ->
        list_times(blog_slug, date, date_path, preferred_language)

      _ ->
        []
    end
  end

  defp list_times(blog_slug, date, date_path, preferred_language) do
    case File.ls(date_path) do
      {:ok, time_folders} ->
        Enum.flat_map(time_folders, fn time_folder ->
          time_path = Path.join(date_path, time_folder)

          with {:ok, time} <- parse_time_folder(time_folder) do
            # Detect if versioned or legacy structure
            case detect_post_structure(time_path) do
              :versioned ->
                list_versioned_timestamp_post(
                  blog_slug,
                  date,
                  time,
                  time_path,
                  preferred_language
                )

              :legacy ->
                list_legacy_timestamp_post(blog_slug, date, time, time_path, preferred_language)

              :empty ->
                []
            end
          else
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # List a versioned timestamp post (files in v1/, v2/, etc.)
  defp list_versioned_timestamp_post(blog_slug, date, time, time_path, preferred_language) do
    versions = list_versions_for_timestamp(time_path)
    master_language = get_master_language()

    # Get the highest version to display in listing
    latest_version = Enum.max(versions, fn -> 1 end)
    version_dir = Path.join(time_path, "v#{latest_version}")

    available_languages = detect_available_languages(version_dir)

    if Enum.empty?(available_languages) do
      []
    else
      display_language = select_display_language(available_languages, preferred_language)
      post_path = Path.join(version_dir, language_filename(display_language))

      case File.read(post_path) do
        {:ok, file_content} ->
          case Metadata.parse_with_content(file_content) do
            {:ok, metadata, content} ->
              # Load statuses and version info
              version_statuses =
                load_version_statuses_timestamp(time_path, versions, master_language)

              [
                %{
                  blog: blog_slug,
                  slug: Map.get(metadata, :slug, format_time_folder(time)),
                  date: date,
                  time: time,
                  path:
                    relative_path_with_language_versioned(
                      blog_slug,
                      date,
                      time,
                      latest_version,
                      display_language
                    ),
                  full_path: post_path,
                  metadata: metadata,
                  content: content,
                  language: display_language,
                  available_languages: available_languages,
                  language_statuses: load_language_statuses(version_dir, available_languages),
                  available_versions: versions,
                  version_statuses: version_statuses,
                  version: latest_version,
                  is_legacy_structure: false,
                  mode: :timestamp
                }
              ]

            _ ->
              []
          end

        {:error, _} ->
          []
      end
    end
  end

  # List a legacy timestamp post (files directly in time folder)
  defp list_legacy_timestamp_post(blog_slug, date, time, time_path, preferred_language) do
    available_languages = detect_available_languages(time_path)

    if Enum.empty?(available_languages) do
      []
    else
      display_language = select_display_language(available_languages, preferred_language)
      post_path = Path.join(time_path, language_filename(display_language))

      case File.read(post_path) do
        {:ok, file_content} ->
          case Metadata.parse_with_content(file_content) do
            {:ok, metadata, content} ->
              language_statuses = load_language_statuses(time_path, available_languages)

              [
                %{
                  blog: blog_slug,
                  slug: Map.get(metadata, :slug, format_time_folder(time)),
                  date: date,
                  time: time,
                  path: relative_path_with_language(blog_slug, date, time, display_language),
                  full_path: post_path,
                  metadata: metadata,
                  content: content,
                  language: display_language,
                  available_languages: available_languages,
                  language_statuses: language_statuses,
                  is_legacy_structure: true,
                  mode: :timestamp
                }
              ]

            _ ->
              []
          end

        {:error, _} ->
          []
      end
    end
  end

  # Load status for all language files in a post directory
  # Returns a map of language_code => status
  defp load_language_statuses(post_dir, available_languages) do
    Enum.reduce(available_languages, %{}, fn lang, acc ->
      lang_path = Path.join(post_dir, language_filename(lang))

      status =
        case File.read(lang_path) do
          {:ok, content} ->
            {:ok, metadata, _content} = Metadata.parse_with_content(content)
            Map.get(metadata, :status)

          {:error, _} ->
            nil
        end

      Map.put(acc, lang, status)
    end)
  end

  # Load language statuses across ALL versions for a slug-mode post
  # Returns "published" for a language if ANY version has it published
  defp load_language_statuses_across_versions(blog_slug, post_slug, current_version_languages) do
    post_dir = Path.join(root_path(), Path.join(blog_slug, post_slug))
    versions = list_versions(blog_slug, post_slug)

    # Collect all unique languages across all versions
    all_languages =
      versions
      |> Enum.flat_map(fn v ->
        version_dir = Path.join(post_dir, "v#{v}")
        detect_available_languages(version_dir)
      end)
      |> Enum.uniq()
      |> then(fn langs ->
        # Ensure current version languages are included
        Enum.uniq(langs ++ current_version_languages)
      end)

    # For each language, check if ANY version has it published
    Enum.reduce(all_languages, %{}, fn lang, acc ->
      has_published =
        Enum.any?(versions, fn v ->
          version_dir = Path.join(post_dir, "v#{v}")
          lang_path = Path.join(version_dir, language_filename(lang))

          case File.read(lang_path) do
            {:ok, content} ->
              {:ok, metadata, _content} = Metadata.parse_with_content(content)
              Map.get(metadata, :status) == "published"

            {:error, _} ->
              false
          end
        end)

      status = if has_published, do: "published", else: "draft"
      Map.put(acc, lang, status)
    end)
  end

  # Load language statuses across ALL versions for a timestamp-mode post
  defp load_language_statuses_across_versions_timestamp(post_dir, current_version_languages) do
    versions = list_versions_for_timestamp(post_dir)

    if Enum.empty?(versions) do
      # Legacy post - just use current directory
      load_language_statuses(post_dir, current_version_languages)
    else
      # Collect all unique languages across all versions
      all_languages =
        versions
        |> Enum.flat_map(fn v ->
          version_dir = Path.join(post_dir, "v#{v}")
          detect_available_languages(version_dir)
        end)
        |> Enum.uniq()
        |> then(fn langs ->
          Enum.uniq(langs ++ current_version_languages)
        end)

      # For each language, check if ANY version has it published
      Enum.reduce(all_languages, %{}, fn lang, acc ->
        has_published =
          Enum.any?(versions, fn v ->
            version_dir = Path.join(post_dir, "v#{v}")
            lang_path = Path.join(version_dir, language_filename(lang))

            case File.read(lang_path) do
              {:ok, content} ->
                {:ok, metadata, _content} = Metadata.parse_with_content(content)
                Map.get(metadata, :status) == "published"

              {:error, _} ->
                false
            end
          end)

        status = if has_published, do: "published", else: "draft"
        Map.put(acc, lang, status)
      end)
    end
  end

  # Selects the best language to display based on:
  # 1. Preferred language (if available)
  # 2. Content language from settings (if available)
  # 3. First available language
  defp select_display_language(available_languages, preferred_language) do
    cond do
      preferred_language && preferred_language in available_languages ->
        preferred_language

      Settings.get_content_language() in available_languages ->
        Settings.get_content_language()

      true ->
        hd(available_languages)
    end
  end

  defp resolve_language(available_languages, preferred_language) do
    code =
      cond do
        # Direct match - preferred language exactly in available
        preferred_language && preferred_language in available_languages ->
          preferred_language

        # Base code match - try to find a dialect that matches the base code
        # e.g., "en" matches "en-US" in available_languages
        preferred_language && base_code?(preferred_language) ->
          find_dialect_for_base(available_languages, preferred_language) ||
            select_display_language(available_languages, preferred_language)

        # Fallback to selection logic
        true ->
          select_display_language(available_languages, preferred_language)
      end

    {:ok, code}
  end

  # Check if a code is a base code (2 letters, no hyphen)
  defp base_code?(code) when is_binary(code) do
    String.length(code) == 2 and not String.contains?(code, "-")
  end

  defp base_code?(_), do: false

  # Find a dialect in available_languages that matches the given base code
  defp find_dialect_for_base(available_languages, base_code) do
    base_lower = String.downcase(base_code)

    Enum.find(available_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  defp detect_available_languages(time_path) do
    case File.ls(time_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".phk"))
        |> Enum.map(&String.replace_suffix(&1, ".phk", ""))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Creates a slug-mode post, returning metadata and paths for the primary language.
  """
  @spec create_post_slug_mode(String.t(), String.t() | nil, String.t() | nil, map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def create_post_slug_mode(blog_slug, title \\ nil, preferred_slug \\ nil, audit_meta \\ %{})

  def create_post_slug_mode(blog_slug, title, preferred_slug, audit_meta)
      when is_list(audit_meta) do
    create_post_slug_mode(blog_slug, title, preferred_slug, Map.new(audit_meta))
  end

  def create_post_slug_mode(blog_slug, title, preferred_slug, audit_meta) do
    audit_meta = Map.new(audit_meta)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Generate slug with validation
    case generate_unique_slug(blog_slug, title || "", preferred_slug) do
      {:ok, post_slug} ->
        create_post_with_slug(blog_slug, post_slug, title, audit_meta, now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_post_with_slug(blog_slug, post_slug, title, audit_meta, now) do
    primary_language = get_master_language()
    version = 1

    # Create versioned directory structure: blog/post-slug/v1/
    version_dir = Path.join([root_path(), blog_slug, post_slug, "v#{version}"])
    File.mkdir_p!(version_dir)

    metadata =
      %{
        slug: post_slug,
        title: title || "",
        description: nil,
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        created_at: DateTime.to_iso8601(now),
        # Version fields
        version: version,
        version_created_at: DateTime.to_iso8601(now),
        version_created_from: nil,
        is_live: false
      }
      |> apply_creation_audit_metadata(audit_meta)

    content = Metadata.serialize(metadata) <> "\n\n"
    primary_lang_path = Path.join(version_dir, language_filename(primary_language))

    case File.write(primary_lang_path, content) do
      :ok ->
        {:ok,
         %{
           blog: blog_slug,
           slug: post_slug,
           date: nil,
           time: nil,
           path:
             Path.join([blog_slug, post_slug, "v#{version}", language_filename(primary_language)]),
           full_path: primary_lang_path,
           metadata: metadata,
           content: "",
           language: primary_language,
           available_languages: [primary_language],
           language_statuses: %{primary_language => "draft"},
           mode: :slug,
           # Version fields
           version: version,
           available_versions: [version],
           version_statuses: %{version => "draft"},
           is_legacy_structure: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists slug-mode posts for the given blog.
  """
  @spec list_posts_slug_mode(String.t(), String.t() | nil) :: [post()]
  def list_posts_slug_mode(blog_slug, preferred_language \\ nil) do
    blog_root = Path.join(root_path(), blog_slug)

    if File.dir?(blog_root) do
      blog_root
      |> File.ls!()
      |> Enum.flat_map(
        &posts_for_slug(blog_slug, &1, Path.join(blog_root, &1), preferred_language)
      )
      |> Enum.sort_by(&published_at_sort_key(&1.metadata), {:desc, DateTime})
    else
      []
    end
  end

  defp posts_for_slug(blog_slug, post_slug, post_path, preferred_language) do
    if File.dir?(post_path) do
      structure = detect_post_structure(post_path)

      # For listing, we show the latest version
      case resolve_version_dir_for_listing(post_path, structure, blog_slug, post_slug) do
        {:ok, version, content_dir} ->
          available_languages = detect_available_languages(content_dir)

          if Enum.empty?(available_languages) do
            []
          else
            display_language = select_display_language(available_languages, preferred_language)
            file_path = Path.join(content_dir, language_filename(display_language))

            {:ok, metadata, content} =
              file_path
              |> File.read!()
              |> Metadata.parse_with_content()

            # Load all versions info
            available_versions = list_versions(blog_slug, post_slug)
            version_statuses = load_version_statuses(blog_slug, post_slug, available_versions)
            version_dates = load_version_dates(blog_slug, post_slug, available_versions)

            # Load language statuses - for versioned posts, check ALL versions
            language_statuses =
              if structure == :versioned do
                load_language_statuses_across_versions(blog_slug, post_slug, available_languages)
              else
                load_language_statuses(content_dir, available_languages)
              end

            # Build path based on structure
            relative_path =
              case structure do
                :versioned ->
                  Path.join([
                    blog_slug,
                    post_slug,
                    "v#{version}",
                    language_filename(display_language)
                  ])

                :legacy ->
                  Path.join([blog_slug, post_slug, language_filename(display_language)])
              end

            # Check if this is a legacy structure
            is_legacy = detect_post_structure(post_path) == :legacy

            [
              %{
                blog: blog_slug,
                slug: post_slug,
                date: nil,
                time: nil,
                path: relative_path,
                full_path: file_path,
                metadata: metadata,
                content: content,
                language: display_language,
                available_languages: available_languages,
                language_statuses: language_statuses,
                mode: :slug,
                # Version fields
                version: version,
                available_versions: available_versions,
                version_statuses: version_statuses,
                version_dates: version_dates,
                is_legacy_structure: is_legacy
              }
            ]
          end

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  # Resolve version directory for listing (always use latest)
  defp resolve_version_dir_for_listing(post_path, :versioned, blog_slug, post_slug) do
    case get_latest_version(blog_slug, post_slug) do
      {:ok, version} ->
        {:ok, version, Path.join(post_path, "v#{version}")}

      {:error, _} ->
        {:error, :no_versions}
    end
  end

  defp resolve_version_dir_for_listing(post_path, :legacy, _blog_slug, _post_slug) do
    {:ok, 1, post_path}
  end

  defp resolve_version_dir_for_listing(_post_path, :empty, _blog_slug, _post_slug) do
    {:error, :empty}
  end

  defp published_at_sort_key(%{published_at: nil}) do
    DateTime.from_unix!(0)
  end

  defp published_at_sort_key(%{published_at: published_at}) do
    case DateTime.from_iso8601(published_at) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.from_unix!(0)
    end
  end

  @doc """
  Reads a slug-mode post, optionally for a specific language and version.

  If version is nil, reads the latest version.
  Handles both versioned (v1/, v2/) and legacy (files in post root) structures.
  """
  @spec read_post_slug_mode(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, post()} | {:error, any()}
  def read_post_slug_mode(blog_slug, post_slug, language \\ nil, version \\ nil) do
    post_dir = Path.join([root_path(), blog_slug, post_slug])

    with true <- File.dir?(post_dir),
         structure <- detect_post_structure(post_dir),
         {:ok, target_version, content_dir} <-
           resolve_version_dir(post_dir, structure, version, blog_slug, post_slug),
         available_languages <- detect_available_languages(content_dir),
         false <- Enum.empty?(available_languages),
         {:ok, language_code} <- resolve_language(available_languages, language),
         file_path <- Path.join(content_dir, language_filename(language_code)),
         true <- File.exists?(file_path),
         {:ok, metadata, content} <-
           File.read!(file_path)
           |> Metadata.parse_with_content() do
      # Load all versions info
      available_versions = list_versions(blog_slug, post_slug)
      version_statuses = load_version_statuses(blog_slug, post_slug, available_versions)
      version_dates = load_version_dates(blog_slug, post_slug, available_versions)

      # Load language statuses - for versioned posts, check ALL versions
      # so indicator shows green if ANY version has that language published
      language_statuses =
        if structure == :versioned do
          load_language_statuses_across_versions(blog_slug, post_slug, available_languages)
        else
          load_language_statuses(content_dir, available_languages)
        end

      # Build path based on structure
      relative_path =
        case structure do
          :versioned ->
            Path.join([
              blog_slug,
              post_slug,
              "v#{target_version}",
              language_filename(language_code)
            ])

          :legacy ->
            Path.join([blog_slug, post_slug, language_filename(language_code)])

          :empty ->
            Path.join([blog_slug, post_slug, language_filename(language_code)])
        end

      # Check if this is a legacy structure
      is_legacy = structure == :legacy

      {:ok,
       %{
         blog: blog_slug,
         slug: post_slug,
         date: nil,
         time: nil,
         path: relative_path,
         full_path: file_path,
         metadata: metadata,
         content: content,
         language: language_code,
         available_languages: available_languages,
         language_statuses: language_statuses,
         mode: :slug,
         # Version fields
         version: target_version,
         available_versions: available_versions,
         version_statuses: version_statuses,
         version_dates: version_dates,
         is_legacy_structure: is_legacy
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  # Resolve which version directory to read from
  defp resolve_version_dir(post_dir, :versioned, nil, blog_slug, post_slug) do
    # No version specified, use latest
    case get_latest_version(blog_slug, post_slug) do
      {:ok, version} ->
        {:ok, version, Path.join(post_dir, "v#{version}")}

      {:error, _} ->
        {:error, :no_versions}
    end
  end

  defp resolve_version_dir(post_dir, :versioned, version, _blog_slug, _post_slug) do
    version_dir = Path.join(post_dir, "v#{version}")

    if File.dir?(version_dir) do
      {:ok, version, version_dir}
    else
      {:error, :version_not_found}
    end
  end

  defp resolve_version_dir(post_dir, :legacy, _version, _blog_slug, _post_slug) do
    # Legacy posts are always v1, files are in post_dir directly
    {:ok, 1, post_dir}
  end

  defp resolve_version_dir(_post_dir, :empty, _version, _blog_slug, _post_slug) do
    {:error, :not_found}
  end

  @doc """
  Updates slug-mode posts in-place or moves them when the slug changes.
  """
  @spec update_post_slug_mode(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def update_post_slug_mode(blog_slug, post, params, audit_meta \\ %{})

  def update_post_slug_mode(blog_slug, post, params, audit_meta) when is_list(audit_meta) do
    update_post_slug_mode(blog_slug, post, params, Map.new(audit_meta))
  end

  def update_post_slug_mode(blog_slug, post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)
    desired_slug = Map.get(params, "slug", post.slug)

    if desired_slug == post.slug do
      update_post_slug_in_place(blog_slug, post, params, audit_meta)
    else
      # Validate slug and return specific error
      case validate_slug(desired_slug) do
        {:ok, _valid_slug} ->
          # Check if slug already exists
          if slug_exists?(blog_slug, desired_slug) do
            {:error, :slug_already_exists}
          else
            move_post_to_new_slug(blog_slug, post, desired_slug, params, audit_meta)
          end

        {:error, reason} ->
          # Return specific validation error
          {:error, reason}
      end
    end
  end

  @doc """
  Updates slug-mode posts without moving them (slug unchanged).
  """
  @spec update_post_slug_in_place(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def update_post_slug_in_place(_blog_slug, post, params, audit_meta \\ %{})

  def update_post_slug_in_place(blog_slug, post, params, audit_meta) when is_list(audit_meta) do
    update_post_slug_in_place(blog_slug, post, params, Map.new(audit_meta))
  end

  def update_post_slug_in_place(blog_slug, post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)

    current_title =
      metadata_value(post.metadata, :title) ||
        Metadata.extract_title_from_content(post.content || "")

    featured_image_id = resolve_featured_image_id(params, post.metadata)

    current_status = metadata_value(post.metadata, :status, "draft")
    new_status = Map.get(params, "status", current_status)

    # Check if transitioning to published
    becoming_published? = current_status != "published" and new_status == "published"

    # Preserve existing version fields
    version = Map.get(post.metadata, :version, 1)
    version_created_at = Map.get(post.metadata, :version_created_at)
    version_created_from = Map.get(post.metadata, :version_created_from)

    # If becoming published, set is_live to true
    is_live = if becoming_published?, do: true, else: Map.get(post.metadata, :is_live, false)

    # Handle allow_version_access - can be passed as param or preserved from existing
    allow_version_access =
      case Map.get(params, "allow_version_access") do
        nil -> Map.get(post.metadata, :allow_version_access, false)
        value when is_boolean(value) -> value
        "true" -> true
        "false" -> false
        _ -> Map.get(post.metadata, :allow_version_access, false)
      end

    metadata =
      post.metadata
      |> Map.put(:title, Map.get(params, "title", current_title))
      |> Map.put(:status, new_status)
      |> Map.put(
        :published_at,
        Map.get(params, "published_at", metadata_value(post.metadata, :published_at))
      )
      |> Map.put(:featured_image_id, featured_image_id)
      |> Map.put(:created_at, Map.get(post.metadata, :created_at))
      |> Map.put(:slug, post.slug)
      # Preserve version fields
      |> Map.put(:version, version)
      |> Map.put(:version_created_at, version_created_at)
      |> Map.put(:version_created_from, version_created_from)
      |> Map.put(:is_live, is_live)
      |> Map.put(:allow_version_access, allow_version_access)
      |> apply_update_audit_metadata(audit_meta)

    content = Map.get(params, "content", post.content)
    serialized = Metadata.serialize(metadata) <> "\n\n" <> String.trim_leading(content)

    case File.write(post.full_path, serialized <> "\n") do
      :ok ->
        # If becoming published, clear is_live from other versions
        if becoming_published? do
          set_version_live(blog_slug, post.slug, version)
        end

        {:ok, %{post | metadata: metadata, content: content}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Moves slug-mode post files to a new slug directory.
  """
  @spec move_post_to_new_slug(String.t(), post(), String.t(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def move_post_to_new_slug(blog_slug, post, new_slug, params, audit_meta \\ %{})

  def move_post_to_new_slug(blog_slug, post, new_slug, params, audit_meta)
      when is_list(audit_meta) do
    move_post_to_new_slug(blog_slug, post, new_slug, params, Map.new(audit_meta))
  end

  def move_post_to_new_slug(blog_slug, post, new_slug, params, audit_meta) do
    audit_meta = Map.new(audit_meta)
    old_dir = Path.join([root_path(), blog_slug, post.slug])
    new_dir = Path.join([root_path(), blog_slug, new_slug])

    # Detect if this is a versioned post structure
    structure = detect_post_structure(old_dir)

    case structure do
      :versioned ->
        # For versioned posts, rename the entire directory and update metadata in all files
        move_versioned_post_to_new_slug(
          blog_slug,
          post,
          new_slug,
          params,
          audit_meta,
          old_dir,
          new_dir
        )

      _ ->
        # Legacy posts - move files individually
        move_legacy_post_to_new_slug(
          blog_slug,
          post,
          new_slug,
          params,
          audit_meta,
          old_dir,
          new_dir
        )
    end
  end

  defp move_versioned_post_to_new_slug(
         blog_slug,
         post,
         new_slug,
         params,
         audit_meta,
         old_dir,
         new_dir
       ) do
    # Rename the entire directory
    :ok = File.rename(old_dir, new_dir)

    # Update slug metadata in all .phk files across all versions
    update_slug_in_all_versions(new_dir, new_slug, post, params, audit_meta)

    # Build the new path based on current version
    version = post.version || 1
    new_path = Path.join([blog_slug, new_slug, "v#{version}", language_filename(post.language)])
    new_full_path = Path.join([new_dir, "v#{version}", language_filename(post.language)])

    {:ok, metadata, content} =
      new_full_path
      |> File.read!()
      |> Metadata.parse_with_content()

    {:ok,
     %{
       post
       | slug: new_slug,
         path: new_path,
         full_path: new_full_path,
         metadata: metadata,
         content: content,
         available_languages: detect_available_languages(Path.join(new_dir, "v#{version}"))
     }}
  end

  defp update_slug_in_all_versions(new_dir, new_slug, post, params, audit_meta) do
    # Find all version directories
    version_dirs =
      new_dir
      |> File.ls!()
      |> Enum.filter(&String.match?(&1, ~r/^v\d+$/))
      |> Enum.map(&Path.join(new_dir, &1))

    Enum.each(version_dirs, fn version_dir ->
      # Update all .phk files in this version
      version_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".phk"))
      |> Enum.each(fn filename ->
        file_path = Path.join(version_dir, filename)
        lang_code = String.replace_suffix(filename, ".phk", "")

        {:ok, metadata, content} =
          file_path
          |> File.read!()
          |> Metadata.parse_with_content()

        # Update slug in metadata
        base_metadata = Map.put(metadata, :slug, new_slug)

        # For the current language being edited, apply params too
        {final_metadata, final_content} =
          if lang_code == post.language and Path.basename(version_dir) == "v#{post.version || 1}" do
            featured_image_id = resolve_featured_image_id(params, metadata)

            updated_metadata =
              base_metadata
              |> Map.put(:title, Map.get(params, "title", metadata.title))
              |> Map.put(:status, Map.get(params, "status", metadata.status))
              |> Map.put(:published_at, Map.get(params, "published_at", metadata.published_at))
              |> Map.put(:featured_image_id, featured_image_id)

            {updated_metadata, Map.get(params, "content", content)}
          else
            {base_metadata, content}
          end

        final_metadata = apply_update_audit_metadata(final_metadata, audit_meta)

        serialized =
          Metadata.serialize(final_metadata) <> "\n\n" <> String.trim_leading(final_content)

        File.write!(file_path, serialized <> "\n")
      end)
    end)
  end

  defp move_legacy_post_to_new_slug(
         blog_slug,
         post,
         new_slug,
         params,
         audit_meta,
         old_dir,
         new_dir
       ) do
    File.mkdir_p!(new_dir)

    Enum.each(post.available_languages, fn lang_code ->
      old_file = Path.join(old_dir, language_filename(lang_code))
      new_file = Path.join(new_dir, language_filename(lang_code))

      if File.exists?(old_file) do
        {:ok, metadata, content} =
          old_file
          |> File.read!()
          |> Metadata.parse_with_content()

        base_metadata = Map.put(metadata, :slug, new_slug)

        {final_metadata, final_content} =
          if lang_code == post.language do
            featured_image_id = resolve_featured_image_id(params, metadata)

            updated_metadata =
              base_metadata
              |> Map.put(:title, Map.get(params, "title", metadata.title))
              |> Map.put(:status, Map.get(params, "status", metadata.status))
              |> Map.put(:published_at, Map.get(params, "published_at", metadata.published_at))
              |> Map.put(:featured_image_id, featured_image_id)

            {updated_metadata, Map.get(params, "content", content)}
          else
            {base_metadata, content}
          end

        final_metadata = apply_update_audit_metadata(final_metadata, audit_meta)

        serialized =
          Metadata.serialize(final_metadata) <> "\n\n" <> String.trim_leading(final_content)

        File.write!(new_file, serialized <> "\n")
        File.rm!(old_file)
      end
    end)

    File.rmdir!(old_dir)

    new_path = Path.join([blog_slug, new_slug, language_filename(post.language)])
    new_full_path = Path.join(new_dir, language_filename(post.language))

    {:ok, metadata, content} =
      new_full_path
      |> File.read!()
      |> Metadata.parse_with_content()

    {:ok,
     %{
       post
       | slug: new_slug,
         path: new_path,
         full_path: new_full_path,
         metadata: metadata,
         content: content,
         available_languages: detect_available_languages(new_dir)
     }}
  end

  @doc """
  Adds a new language file to a slug-mode post.

  Accepts an optional version parameter to specify which version to add the
  translation to. If not specified, adds to the latest version.
  """
  @spec add_language_to_post_slug_mode(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, post()} | {:error, any()}
  def add_language_to_post_slug_mode(blog_slug, post_slug, language_code, version \\ nil) do
    # Read the specific version (or latest if nil) of the MASTER language post
    # to get the correct metadata and directory path.
    master_language = get_master_language()

    with {:ok, original_post} <-
           read_post_slug_mode(blog_slug, post_slug, master_language, version),
         post_dir <- Path.dirname(original_post.full_path),
         target_path <- Path.join(post_dir, language_filename(language_code)),
         false <- File.exists?(target_path) do
      # Create metadata for the new translation.
      # We copy essential fields but reset content-specific ones like title.
      # The version information is preserved from the original post.
      # IMPORTANT: New translations always start as drafts to prevent
      # blank content from being served publicly.
      metadata =
        original_post.metadata
        |> Map.take([
          :slug,
          :created_at,
          :version,
          :version_created_at,
          :version_created_from,
          :allow_version_access,
          :created_by_id,
          :created_by_email,
          :updated_by_id,
          :updated_by_email
        ])
        |> Map.put(:title, "")
        |> Map.put(:description, nil)
        |> Map.put(:featured_image_id, nil)
        |> Map.put(:status, "draft")
        |> Map.put(:is_live, false)
        |> Map.put(:published_at, nil)

      serialized = Metadata.serialize(metadata) <> "\n\n"

      case File.write(target_path, serialized <> "\n") do
        :ok ->
          # Read back the specific version with the new language
          read_post_slug_mode(blog_slug, post_slug, language_code, version)

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_language_from_path(relative_path) do
    relative_path
    |> Path.basename()
    |> String.replace_suffix(".phk", "")
  end

  @doc """
  Creates a new post, returning its metadata and content.
  Creates only the primary language file. Additional languages can be added later.
  """
  @spec create_post(String.t(), map() | keyword()) :: {:ok, post()} | {:error, any()}
  def create_post(blog_slug, audit_meta \\ %{})

  def create_post(blog_slug, audit_meta) when is_list(audit_meta) do
    create_post(blog_slug, Map.new(audit_meta))
  end

  def create_post(blog_slug, audit_meta) do
    audit_meta = Map.new(audit_meta)

    now =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> floor_to_minute()

    date = DateTime.to_date(now)
    time = DateTime.to_time(now)
    primary_language = get_master_language()

    # Create directory structure with v1/ for versioning
    slug = blog_slug || "blog"

    time_dir =
      Path.join([root_path(), slug, Date.to_iso8601(date), format_time_folder(time)])

    # Create v1 directory for versioning
    v1_dir = Path.join(time_dir, "v1")
    File.mkdir_p!(v1_dir)

    metadata =
      Metadata.default_metadata()
      |> Map.put(:status, "draft")
      |> Map.put(:published_at, DateTime.to_iso8601(now))
      |> Map.put(:slug, format_time_folder(time))
      |> Map.put(:version, 1)
      |> Map.put(:version_created_at, DateTime.to_iso8601(now))
      |> Map.put(:is_live, false)
      |> apply_creation_audit_metadata(audit_meta)

    content = Metadata.serialize(metadata) <> "\n\n"

    # Create only primary language file in v1/
    primary_lang_path = Path.join(v1_dir, language_filename(primary_language))

    case File.write(primary_lang_path, content) do
      :ok ->
        blog_slug_for_path = blog_slug || slug

        primary_path =
          relative_path_with_language_versioned(
            blog_slug_for_path,
            date,
            time,
            1,
            primary_language
          )

        full_path = absolute_path(primary_path)

        {:ok,
         %{
           blog: blog_slug_for_path,
           slug: metadata.slug,
           date: date,
           time: time,
           path: primary_path,
           full_path: full_path,
           metadata: metadata,
           content: "",
           language: primary_language,
           available_languages: [primary_language],
           mode: :timestamp,
           version: 1,
           available_versions: [1],
           version_statuses: %{1 => "draft"},
           is_legacy_structure: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads a post for a specific language (timestamp mode).
  Supports both versioned and legacy post structures.
  """
  @spec read_post(String.t(), String.t()) :: {:ok, post()} | {:error, any()}
  def read_post(blog_slug, relative_path) do
    full_path = absolute_path(relative_path)
    language = extract_language_from_path(relative_path)

    with true <- File.exists?(full_path),
         {:ok, metadata, content} <- File.read!(full_path) |> Metadata.parse_with_content(),
         {:ok, {date, time}} <- date_time_from_path(relative_path) do
      # Determine the directory containing language files
      lang_dir = Path.dirname(full_path)

      # Check if this is a versioned path (contains /v1/, /v2/, etc.)
      {is_versioned, version, post_dir} = detect_version_from_path(relative_path, lang_dir)

      available_languages = detect_available_languages(lang_dir)

      # Get version info
      {available_versions, version_statuses} =
        if is_versioned do
          versions = list_versions_for_timestamp(post_dir)
          statuses = load_version_statuses_timestamp(post_dir, versions, language)
          {versions, statuses}
        else
          # Legacy post - treat as v1 but mark as needing migration
          {[], %{}}
        end

      # Load language statuses - for versioned posts, check ALL versions
      language_statuses =
        if is_versioned do
          load_language_statuses_across_versions_timestamp(post_dir, available_languages)
        else
          load_language_statuses(lang_dir, available_languages)
        end

      {:ok,
       %{
         blog: blog_slug,
         slug: Map.get(metadata, :slug, Path.basename(Path.dirname(relative_path))),
         date: date,
         time: time,
         path: relative_path,
         full_path: full_path,
         metadata: metadata,
         content: content,
         language: language,
         available_languages: available_languages,
         language_statuses: language_statuses,
         mode: :timestamp,
         version: version,
         available_versions: available_versions,
         version_statuses: version_statuses,
         is_legacy_structure: not is_versioned
       }}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Detect if path contains version directory and extract version number
  defp detect_version_from_path(relative_path, lang_dir) do
    path_parts = Path.split(relative_path)

    # Look for v1, v2, etc. in the path
    version_part = Enum.find(path_parts, &version_dir?/1)

    if version_part do
      version = String.replace_prefix(version_part, "v", "") |> String.to_integer()
      # Post directory is parent of version directory
      post_dir = Path.dirname(lang_dir)
      {true, version, post_dir}
    else
      # Legacy structure - no version directory
      {false, 1, lang_dir}
    end
  end

  # List versions for a timestamp-mode post
  defp list_versions_for_timestamp(post_dir) do
    case File.ls(post_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&version_dir?/1)
        |> Enum.map(fn dir -> String.replace_prefix(dir, "v", "") |> String.to_integer() end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # Load version statuses for timestamp-mode post
  defp load_version_statuses_timestamp(post_dir, versions, language) do
    Enum.reduce(versions, %{}, fn version, acc ->
      version_dir = Path.join(post_dir, "v#{version}")
      lang_file = Path.join(version_dir, language_filename(language))

      status =
        if File.exists?(lang_file) do
          case File.read(lang_file) do
            {:ok, content} ->
              {:ok, metadata, _} = Metadata.parse_with_content(content)
              Map.get(metadata, :status, "draft")

            _ ->
              "draft"
          end
        else
          # Try to find any language file to get status
          case File.ls(version_dir) do
            {:ok, files} ->
              phk_file = Enum.find(files, &String.ends_with?(&1, ".phk"))

              if phk_file do
                case File.read(Path.join(version_dir, phk_file)) do
                  {:ok, content} ->
                    {:ok, metadata, _} = Metadata.parse_with_content(content)
                    Map.get(metadata, :status, "draft")

                  _ ->
                    "draft"
                end
              else
                "draft"
              end

            _ ->
              "draft"
          end
        end

      Map.put(acc, version, status)
    end)
  end

  @doc """
  Adds a new language file to an existing post by copying metadata from an existing language.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t()) ::
          {:ok, post()} | {:error, any()}
  def add_language_to_post(blog_slug, post_path, language_code) do
    # Read the original post to get its metadata and structure
    with {:ok, original_post} <- read_post(blog_slug, post_path),
         time_dir <- Path.dirname(original_post.full_path),
         new_file_path <- Path.join(time_dir, language_filename(language_code)),
         false <- File.exists?(new_file_path) do
      # Create new file with same metadata but empty content.
      # IMPORTANT: New translations always start as drafts to prevent
      # blank content from being served publicly.
      metadata =
        original_post.metadata
        |> Map.put(:title, "")
        |> Map.put(:status, "draft")
        |> Map.put(:is_live, false)
        |> Map.put(:published_at, nil)

      content = Metadata.serialize(metadata) <> "\n\n"

      case File.write(new_file_path, content) do
        :ok ->
          # Build the correct relative path based on post structure
          new_relative_path =
            if original_post.is_legacy_structure do
              relative_path_with_language(
                blog_slug,
                original_post.date,
                original_post.time,
                language_code
              )
            else
              relative_path_with_language_versioned(
                blog_slug,
                original_post.date,
                original_post.time,
                original_post.version || 1,
                language_code
              )
            end

          read_post(blog_slug, new_relative_path)

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates a post's metadata/content, moving files if needed.
  Preserves language and detects available languages.
  """
  @spec update_post(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def update_post(_blog_slug, post, params, audit_meta \\ %{})

  def update_post(blog_slug, post, params, audit_meta) when is_list(audit_meta) do
    update_post(blog_slug, post, params, Map.new(audit_meta))
  end

  def update_post(_blog_slug, post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)

    featured_image_id = resolve_featured_image_id(params, post.metadata)

    new_metadata =
      post.metadata
      |> Map.put(:title, Map.get(params, "title", post.metadata.title))
      |> Map.put(:status, Map.get(params, "status", post.metadata.status))
      |> Map.put(:published_at, Map.get(params, "published_at", post.metadata.published_at))
      |> Map.put(:featured_image_id, featured_image_id)
      |> apply_update_audit_metadata(audit_meta)

    new_content = Map.get(params, "content", post.content)
    new_path = new_path_for(post, params)
    full_new_path = absolute_path(new_path)

    File.mkdir_p!(Path.dirname(full_new_path))

    metadata_for_file =
      new_metadata
      |> Map.put(:slug, Path.basename(Path.dirname(new_path)))

    serialized =
      Metadata.serialize(metadata_for_file) <> "\n\n" <> String.trim_leading(new_content)

    case File.write(full_new_path, serialized <> "\n") do
      :ok ->
        if full_new_path != post.full_path do
          File.rm(post.full_path)
          cleanup_empty_dirs(post.full_path)
        end

        {date, time} = date_time_from_path!(new_path)
        time_dir = Path.dirname(full_new_path)
        available_languages = detect_available_languages(time_dir)

        {:ok,
         %{
           post
           | path: new_path,
             full_path: full_new_path,
             metadata: metadata_for_file,
             content: new_content,
             date: date,
             time: time,
             available_languages: available_languages,
             slug: metadata_for_file.slug,
             mode: post.mode || :timestamp
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the absolute path for a relative blogging path.
  """
  @spec absolute_path(String.t()) :: String.t()
  def absolute_path(relative_path) do
    Path.join(root_path(), String.trim_leading(relative_path, "/"))
  end

  defp relative_path_with_language(blog_slug, date, time, language_code) do
    date_part = Date.to_iso8601(date)
    time_part = format_time_folder(time)

    Path.join([blog_slug, date_part, time_part, language_filename(language_code)])
  end

  defp relative_path_with_language_versioned(blog_slug, date, time, version, language_code) do
    date_part = Date.to_iso8601(date)
    time_part = format_time_folder(time)

    Path.join([blog_slug, date_part, time_part, "v#{version}", language_filename(language_code)])
  end

  defp new_path_for(post, params) do
    case Map.get(params, "published_at") do
      nil ->
        post.path

      value ->
        path_for_timestamp(
          post.blog,
          value,
          post.language,
          post.version,
          post.is_legacy_structure
        )
    end
  end

  defp path_for_timestamp(blog_slug, timestamp, language_code, version, is_legacy) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} ->
        floored = floor_to_minute(dt)

        # Use versioned path for non-legacy posts, legacy path otherwise
        if is_legacy do
          relative_path_with_language(
            blog_slug,
            DateTime.to_date(floored),
            DateTime.to_time(floored),
            language_code
          )
        else
          relative_path_with_language_versioned(
            blog_slug,
            DateTime.to_date(floored),
            DateTime.to_time(floored),
            version || 1,
            language_code
          )
        end

      _ ->
        now = DateTime.utc_now() |> floor_to_minute()

        if is_legacy do
          relative_path_with_language(
            blog_slug,
            DateTime.to_date(now),
            DateTime.to_time(now),
            language_code
          )
        else
          relative_path_with_language_versioned(
            blog_slug,
            DateTime.to_date(now),
            DateTime.to_time(now),
            version || 1,
            language_code
          )
        end
    end
  end

  defp date_time_from_path(path) do
    parts = String.split(path, "/", trim: true)

    # Handle both legacy (4 parts) and versioned (5 parts) paths:
    # Legacy:    blog/date/time/file.phk
    # Versioned: blog/date/time/v1/file.phk
    {date_part, time_part} =
      case parts do
        [_type, date_part, time_part, _file] ->
          {date_part, time_part}

        [_type, date_part, time_part, _version, _file] ->
          {date_part, time_part}

        _ ->
          {nil, nil}
      end

    if date_part && time_part do
      with {:ok, date} <- Date.from_iso8601(date_part),
           {:ok, time} <- parse_time_folder(time_part) do
        {:ok, {date, time}}
      else
        _ -> {:error, :invalid_path}
      end
    else
      {:error, :invalid_path}
    end
  rescue
    _ -> {:error, :invalid_path}
  end

  defp date_time_from_path!(path) do
    case date_time_from_path(path) do
      {:ok, result} -> result
      _ -> raise ArgumentError, "invalid blogging path #{inspect(path)}"
    end
  end

  defp parse_time_folder(folder) do
    case String.split(folder, ":") do
      [hour, minute] ->
        with {h, ""} <- Integer.parse(hour),
             {m, ""} <- Integer.parse(minute),
             true <- h in 0..23,
             true <- m in 0..59 do
          {:ok, Time.new!(h, m, 0)}
        else
          _ -> {:error, :invalid_time}
        end

      _ ->
        {:error, :invalid_time}
    end
  end

  defp format_time_folder(%Time{} = time) do
    {hour, minute, _second} = Time.to_erl(time)
    "#{pad(hour)}:#{pad(minute)}"
  end

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: Integer.to_string(value)

  defp apply_creation_audit_metadata(metadata, audit_meta) do
    created_id = audit_value(audit_meta, :created_by_id)
    created_email = audit_value(audit_meta, :created_by_email)
    updated_id = audit_value(audit_meta, :updated_by_id) || created_id
    updated_email = audit_value(audit_meta, :updated_by_email) || created_email

    metadata
    |> maybe_put_audit_field(:created_by_id, created_id)
    |> maybe_put_audit_field(:created_by_email, created_email)
    |> maybe_put_audit_field(:updated_by_id, updated_id)
    |> maybe_put_audit_field(:updated_by_email, updated_email)
  end

  defp apply_update_audit_metadata(metadata, audit_meta) do
    metadata
    |> maybe_put_audit_field(:updated_by_id, audit_value(audit_meta, :updated_by_id))
    |> maybe_put_audit_field(:updated_by_email, audit_value(audit_meta, :updated_by_email))
  end

  defp audit_value(audit_meta, key) do
    audit_meta
    |> Map.get(key)
    |> case do
      nil -> Map.get(audit_meta, Atom.to_string(key))
      value -> value
    end
    |> normalize_audit_value()
  end

  defp maybe_put_audit_field(metadata, _key, nil), do: metadata

  defp maybe_put_audit_field(metadata, key, value) do
    Map.put(metadata, key, value)
  end

  defp normalize_audit_value(nil), do: nil

  defp normalize_audit_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_audit_value(value), do: to_string(value)

  defp cleanup_empty_dirs(path) do
    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&String.starts_with?(&1, root_path()))
    |> Enum.each(fn dir ->
      case File.ls(dir) do
        {:ok, []} -> File.rmdir(dir)
        _ -> :ok
      end
    end)
  end

  defp floor_to_minute(%DateTime{} = datetime) do
    %DateTime{datetime | second: 0, microsecond: {0, 0}}
  end

  defp resolve_featured_image_id(params, metadata) do
    case Map.fetch(params, "featured_image_id") do
      {:ok, value} -> normalize_featured_image_id(value)
      :error -> metadata_value(metadata, :featured_image_id)
    end
  end

  defp normalize_featured_image_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_featured_image_id(_), do: nil

  defp metadata_value(metadata, key, fallback \\ nil) do
    Map.get(metadata, key) ||
      Map.get(metadata, Atom.to_string(key)) ||
      fallback
  end
end
