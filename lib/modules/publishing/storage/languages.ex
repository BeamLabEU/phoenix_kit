defmodule PhoenixKit.Modules.Publishing.Storage.Languages do
  @moduledoc """
  Language and internationalization operations for publishing storage.

  Handles language detection, display ordering, language info lookup,
  and primary language management for posts.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Storage.Paths
  alias PhoenixKit.Modules.Publishing.Storage.Versions
  alias PhoenixKit.Settings

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
  Returns the primary/canonical language for versioning.

  Uses the default language from the Languages module (via Settings.get_content_language).
  Falls back to "en" if Languages module is disabled or no default is set.

  This should be used instead of `hd(enabled_language_codes())` when
  determining which language controls versioning logic.
  """
  @spec get_primary_language() :: String.t()
  def get_primary_language do
    Settings.get_content_language()
  end

  @doc false
  @deprecated "Use get_primary_language/0 instead"
  @spec get_master_language() :: String.t()
  def get_master_language, do: get_primary_language()

  @doc """
  Gets the primary language for a specific post.

  Reads the post's metadata to get its stored `primary_language` field.
  Falls back to the global setting if no `primary_language` is stored.

  This ensures posts created before the `primary_language` field was added
  continue to work by using the current global setting.
  """
  @spec get_post_primary_language(String.t(), String.t(), integer() | nil) :: String.t()
  def get_post_primary_language(group_slug, post_slug, version \\ nil)

  def get_post_primary_language(group_slug, post_slug, version) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])

    case Versions.detect_post_structure(post_path) do
      :versioned ->
        version_to_use = version || get_latest_version_number(post_path)
        version_dir = Path.join(post_path, "v#{version_to_use}")
        read_primary_language_from_dir(version_dir)

      :legacy ->
        read_primary_language_from_dir(post_path)

      _ ->
        get_primary_language()
    end
  end

  defp get_latest_version_number(post_path) do
    case File.ls(post_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "v"))
        |> Enum.map(fn "v" <> n -> String.to_integer(n) end)
        |> Enum.max(fn -> 1 end)

      _ ->
        1
    end
  end

  defp read_primary_language_from_dir(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.find(&String.ends_with?(&1, ".phk"))
        |> case do
          nil ->
            get_primary_language()

          file ->
            file_path = Path.join(dir, file)

            case File.read(file_path) do
              {:ok, content} ->
                {:ok, metadata, _} = Metadata.parse_with_content(content)
                Map.get(metadata, :primary_language) || get_primary_language()

              _ ->
                get_primary_language()
            end
        end

      _ ->
        get_primary_language()
    end
  end

  @doc """
  Checks if a post needs primary_language migration.

  A post needs migration if:
  1. It has no `primary_language` stored in metadata (needs backfill), OR
  2. Its stored `primary_language` doesn't match the current global setting (needs migration decision)

  Returns:
  - `{:ok, :current}` if post matches global setting
  - `{:needs_migration, stored_lang}` if post has different primary_language
  - `{:needs_backfill, nil}` if post has no primary_language stored
  """
  @spec check_primary_language_status(String.t(), String.t()) ::
          {:ok, :current} | {:needs_migration, String.t()} | {:needs_backfill, nil}
  def check_primary_language_status(group_slug, post_slug) do
    global_primary = get_primary_language()
    post_path = Path.join([Paths.group_path(group_slug), post_slug])

    case has_stored_primary_language?(post_path) do
      {:ok, stored_primary} when stored_primary == global_primary ->
        {:ok, :current}

      {:ok, stored_primary} ->
        {:needs_migration, stored_primary}

      :not_stored ->
        {:needs_backfill, nil}
    end
  end

  defp has_stored_primary_language?(post_path) do
    case Versions.detect_post_structure(post_path) do
      :versioned ->
        case File.ls(post_path) do
          {:ok, dirs} ->
            version_dir = Enum.find(dirs, &String.starts_with?(&1, "v"))

            if version_dir do
              check_dir_for_stored_primary_language(Path.join(post_path, version_dir))
            else
              :not_stored
            end

          _ ->
            :not_stored
        end

      :legacy ->
        check_dir_for_stored_primary_language(post_path)

      _ ->
        :not_stored
    end
  end

  defp check_dir_for_stored_primary_language(dir) do
    with {:ok, files} <- File.ls(dir),
         file when not is_nil(file) <- Enum.find(files, &String.ends_with?(&1, ".phk")),
         file_path <- Path.join(dir, file),
         {:ok, content} <- File.read(file_path),
         {:ok, metadata, _} <- Metadata.parse_with_content(content) do
      case Map.get(metadata, :primary_language) do
        nil -> :not_stored
        "" -> :not_stored
        stored -> {:ok, stored}
      end
    else
      _ -> :not_stored
    end
  end

  @doc """
  Updates the primary_language field for all language files in a post.

  This is used during migration to set the primary_language to match
  the current global setting. Updates all versions.
  """
  @spec update_post_primary_language(String.t(), String.t(), String.t()) :: :ok | {:error, any()}
  def update_post_primary_language(_group_slug, nil, _new_primary_language),
    do: {:error, :invalid_slug}

  def update_post_primary_language(_group_slug, "", _new_primary_language),
    do: {:error, :invalid_slug}

  def update_post_primary_language(group_slug, post_slug, new_primary_language) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])

    case Versions.detect_post_structure(post_path) do
      :versioned ->
        case File.ls(post_path) do
          {:ok, dirs} ->
            dirs
            |> Enum.filter(&String.starts_with?(&1, "v"))
            |> Enum.each(fn version_dir ->
              update_primary_language_in_dir(
                Path.join(post_path, version_dir),
                new_primary_language
              )
            end)

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      :legacy ->
        update_primary_language_in_dir(post_path, new_primary_language)

      _ ->
        {:error, :post_not_found}
    end
  end

  defp update_primary_language_in_dir(dir, new_primary_language) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".phk"))
        |> Enum.each(fn file ->
          file_path = Path.join(dir, file)

          case File.read(file_path) do
            {:ok, content} ->
              {:ok, metadata, body} = Metadata.parse_with_content(content)
              updated_metadata = Map.put(metadata, :primary_language, new_primary_language)

              new_content =
                Metadata.serialize(updated_metadata) <> "\n\n" <> String.trim_leading(body)

              File.write(file_path, new_content <> "\n")

            _ ->
              :ok
          end
        end)

        :ok

      _ ->
        :ok
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
    predefined = find_in_predefined_languages(language_code)

    if predefined do
      predefined
    else
      find_in_configured_languages(language_code)
    end
  end

  defp find_in_predefined_languages(language_code) do
    case Languages.get_available_language_by_code(language_code) do
      nil ->
        base_code = DialectMapper.extract_base(language_code)
        is_base_code = language_code == base_code and not String.contains?(language_code, "-")
        default_dialect = DialectMapper.base_to_dialect(base_code)

        case Languages.get_available_language_by_code(default_dialect) do
          nil ->
            all_languages = Languages.get_available_languages()

            Enum.find(all_languages, fn lang ->
              DialectMapper.extract_base(lang.code) == base_code
            end)

          default_match ->
            if is_base_code do
              %{default_match | name: extract_base_language_name(default_match.name)}
            else
              default_match
            end
        end

      exact_match ->
        exact_match
    end
  end

  defp extract_base_language_name(name) when is_binary(name) do
    case String.split(name, " (", parts: 2) do
      [base_name, _region] -> base_name
      [base_name] -> base_name
    end
  end

  defp extract_base_language_name(name), do: name

  defp find_in_configured_languages(language_code) do
    configured_languages = Languages.get_languages()

    exact_match =
      Enum.find(configured_languages, fn lang -> lang["code"] == language_code end)

    result =
      if exact_match do
        exact_match
      else
        base_code = DialectMapper.extract_base(language_code)
        default_dialect = DialectMapper.base_to_dialect(base_code)

        default_match =
          Enum.find(configured_languages, fn lang -> lang["code"] == default_dialect end)

        if default_match do
          default_match
        else
          Enum.find(configured_languages, fn lang ->
            DialectMapper.extract_base(lang["code"]) == base_code
          end)
        end
      end

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
  - The file is `en.phk` and enabled languages has `"en-US"` -> matches
  - The file is `en-US.phk` and enabled languages has `"en"` -> matches
  - The file is `af.phk` and enabled languages has `"af"` -> matches
  """
  @spec language_enabled?(String.t(), [String.t()]) :: boolean()
  def language_enabled?(language_code, enabled_languages) do
    if language_code in enabled_languages do
      true
    else
      base_code = DialectMapper.extract_base(language_code)

      Enum.any?(enabled_languages, fn enabled_lang ->
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
  """
  @spec get_display_code(String.t(), [String.t()]) :: String.t()
  def get_display_code(language_code, enabled_languages) do
    base_code = DialectMapper.extract_base(language_code)

    dialects_count =
      Enum.count(enabled_languages, fn lang ->
        DialectMapper.extract_base(lang) == base_code
      end)

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
  """
  @spec order_languages_for_display([String.t()], [String.t()], String.t() | nil) :: [String.t()]
  def order_languages_for_display(available_languages, enabled_languages, primary_language \\ nil) do
    primary_lang = primary_language || get_primary_language()

    langs_with_content =
      available_languages
      |> Enum.reject(&(&1 == primary_lang))
      |> Enum.sort()

    langs_without_content =
      enabled_languages
      |> Enum.reject(&(&1 in available_languages or &1 == primary_lang))
      |> Enum.sort()

    [primary_lang] ++ langs_with_content ++ langs_without_content
  end

  @doc """
  Detects available languages in a directory by looking for .phk files.
  Returns language codes sorted with primary language first.
  """
  @spec detect_available_languages(String.t(), String.t() | nil) :: [String.t()]
  def detect_available_languages(dir_path, primary_language \\ nil) do
    primary_lang = primary_language || get_primary_language()

    case File.ls(dir_path) do
      {:ok, files} ->
        languages =
          files
          |> Enum.filter(&String.ends_with?(&1, ".phk"))
          |> Enum.map(&String.replace_suffix(&1, ".phk", ""))
          |> Enum.sort()

        if primary_lang in languages do
          [primary_lang | Enum.reject(languages, &(&1 == primary_lang))]
        else
          languages
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Loads status for all language files in a post directory.
  Returns a map of language_code => status.
  """
  @spec load_language_statuses(String.t(), [String.t()]) :: %{String.t() => String.t() | nil}
  def load_language_statuses(post_dir, available_languages) do
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

  @doc """
  Propagates status changes from the primary language to all translations.

  When the primary language post status changes, this updates all other
  language files in the same directory to match the new status.
  """
  @spec propagate_status_to_translations(String.t(), String.t(), String.t()) :: :ok
  def propagate_status_to_translations(post_dir, primary_language, new_status) do
    available_languages = detect_available_languages(post_dir)
    translation_languages = Enum.reject(available_languages, &(&1 == primary_language))

    Enum.each(translation_languages, fn lang ->
      lang_path = Path.join(post_dir, language_filename(lang))

      with {:ok, content} <- File.read(lang_path),
           {:ok, metadata, body} <- Metadata.parse_with_content(content) do
        updated_metadata = Map.put(metadata, :status, new_status)
        serialized = Metadata.serialize(updated_metadata) <> "\n\n" <> String.trim_leading(body)
        File.write(lang_path, serialized <> "\n")
      end
    end)

    :ok
  end

  @doc """
  Checks if a language code is reserved (cannot be used as a slug).
  """
  @spec reserved_language_code?(String.t()) :: boolean()
  def reserved_language_code?(slug) do
    language_codes =
      try do
        Languages.get_language_codes()
      rescue
        _ -> []
      end

    slug in language_codes
  end
end
