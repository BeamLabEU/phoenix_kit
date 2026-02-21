defmodule PhoenixKit.Modules.Publishing.Storage do
  @moduledoc """
  Filesystem storage helpers for publishing posts.

  Content is stored under:

      priv/publishing/<group>/<YYYY-MM-DD>/<HH:MM>/<language>.phk

  Where <language> is determined by the site's content language setting.
  Files use the .phk (PhoenixKit) format, which supports XML-style
  component markup for building pages with swappable design variants.

  ## Submodules

  This module delegates to specialized submodules for better organization:

  - `Storage.Paths` - Path management and resolution
  - `Storage.Languages` - Language operations and i18n
  - `Storage.Slugs` - Slug validation and generation
  - `Storage.Versions` - Version management
  - `Storage.Deletion` - Trash and delete operations
  - `Storage.Helpers` - Shared utilities
  """

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Storage.Helpers
  alias PhoenixKit.Modules.Publishing.Storage.Languages
  alias PhoenixKit.Modules.Publishing.Storage.Paths
  alias PhoenixKit.Modules.Publishing.Storage.Slugs
  alias PhoenixKit.Modules.Publishing.Storage.Versions
  alias PhoenixKit.Settings

  require Logger

  # Suppress dialyzer false positives for pattern matches
  @dialyzer {:nowarn_function, list_versioned_timestamp_post: 5}
  @dialyzer {:nowarn_function, list_legacy_timestamp_post: 5}

  # ============================================================================
  # Type Definitions
  # ============================================================================

  @typedoc """
  A post with metadata and content.

  The `language_statuses` field is preloaded when fetching posts via `list_posts/2`
  or `read_post/2` to avoid redundant file reads. It maps language codes to their
  publication status (e.g., `%{"en" => "published", "es" => "draft"}`).

  Version fields:
  - `version`: Current version number (1, 2, 3...)
  - `available_versions`: List of all version numbers for this post
  - `version_statuses`: Map of version => status for quick lookup
  """
  @type post :: %{
          group: String.t() | nil,
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
          version: integer() | nil,
          available_versions: [integer()],
          version_statuses: %{integer() => String.t()},
          version_dates: %{integer() => String.t() | nil},
          is_legacy_structure: boolean()
        }

  # ============================================================================
  # Delegated Functions - Languages
  # ============================================================================

  defdelegate language_filename(language_code), to: Languages
  defdelegate language_filename(), to: Languages
  defdelegate enabled_language_codes(), to: Languages
  defdelegate get_primary_language(), to: Languages
  defdelegate get_post_primary_language(group_slug, post_slug, version \\ nil), to: Languages
  defdelegate check_primary_language_status(group_slug, post_slug), to: Languages
  defdelegate get_language_info(language_code), to: Languages
  defdelegate language_enabled?(language_code, enabled_languages), to: Languages
  defdelegate get_display_code(language_code, enabled_languages), to: Languages
  defdelegate order_languages_for_display(available, enabled, primary \\ nil), to: Languages
  defdelegate detect_available_languages(dir_path, primary \\ nil), to: Languages
  defdelegate load_language_statuses(post_dir, available_languages), to: Languages

  # ============================================================================
  # Delegated Functions - Paths
  # ============================================================================

  defdelegate root_path(), to: Paths
  defdelegate group_path(group_slug), to: Paths
  defdelegate write_root_path(), to: Paths
  defdelegate new_root_path(), to: Paths
  defdelegate legacy_root_path(), to: Paths
  defdelegate legacy_group?(group_slug), to: Paths
  defdelegate has_legacy_groups?(), to: Paths
  defdelegate absolute_path(relative_path), to: Paths

  # ============================================================================
  # Delegated Functions - Slugs
  # ============================================================================

  defdelegate validate_slug(slug), to: Slugs
  defdelegate valid_slug?(slug), to: Slugs
  defdelegate validate_url_slug(group_slug, url_slug, language, exclude \\ nil), to: Slugs
  defdelegate slug_exists?(group_slug, post_slug), to: Slugs
  defdelegate generate_unique_slug(group_slug, title, preferred \\ nil, opts \\ []), to: Slugs

  # ============================================================================
  # Delegated Functions - Versions
  # ============================================================================

  defdelegate detect_post_structure(post_path), to: Versions
  defdelegate version_dir?(name), to: Versions
  defdelegate list_versions(group_slug, post_slug), to: Versions
  defdelegate parse_version_number(name), to: Versions
  defdelegate get_latest_version(group_slug, post_slug), to: Versions
  defdelegate get_latest_published_version(group_slug, post_slug), to: Versions
  defdelegate get_published_version(group_slug, post_slug), to: Versions
  defdelegate get_version_status(group_slug, post_slug, version, language), to: Versions
  defdelegate get_version_metadata(group_slug, post_slug, version, language), to: Versions
  defdelegate version_path(group_slug, post_slug, version), to: Versions
  defdelegate load_version_statuses(group_slug, post_slug, versions, primary \\ nil), to: Versions
  defdelegate load_version_dates(group_slug, post_slug, versions, primary \\ nil), to: Versions
  defdelegate get_version_date(group_slug, post_slug, version, language), to: Versions

  # ============================================================================
  # Timestamp Mode Operations
  # ============================================================================

  @doc """
  Counts the number of posts on a specific date for a group.
  Used to determine if time should be included in URLs.
  """
  @spec count_posts_on_date(String.t(), Date.t() | String.t()) :: non_neg_integer()
  def count_posts_on_date(group_slug, %Date{} = date) do
    count_posts_on_date(group_slug, Date.to_iso8601(date))
  end

  def count_posts_on_date(group_slug, date_string) when is_binary(date_string) do
    date_path = Path.join([Paths.group_path(group_slug), date_string])

    if File.dir?(date_path) do
      case File.ls(date_path) do
        {:ok, time_folders} ->
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
  Lists all time folders (posts) for a specific date in a group.
  Returns a list of time strings in HH:MM format, sorted.
  """
  @spec list_times_on_date(String.t(), Date.t() | String.t()) :: [String.t()]
  def list_times_on_date(group_slug, %Date{} = date) do
    list_times_on_date(group_slug, Date.to_iso8601(date))
  end

  def list_times_on_date(group_slug, date_string) when is_binary(date_string) do
    date_path = Path.join([Paths.group_path(group_slug), date_string])

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
  Lists posts for the given group (timestamp mode).
  Accepts optional preferred_language to show titles in user's language.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [post()]
  def list_posts(group_slug, preferred_language \\ nil) do
    group_root = Paths.group_path(group_slug)

    if File.dir?(group_root) do
      group_root
      |> File.ls!()
      |> Enum.flat_map(
        &posts_for_date(group_slug, &1, Path.join(group_root, &1), preferred_language)
      )
      |> Enum.sort_by(&{&1.date, &1.time}, :desc)
    else
      []
    end
  end

  defp posts_for_date(group_slug, date_folder, date_path, preferred_language) do
    case Date.from_iso8601(date_folder) do
      {:ok, date} ->
        list_times(group_slug, date, date_path, preferred_language)

      _ ->
        []
    end
  end

  defp list_times(group_slug, date, date_path, preferred_language) do
    case File.ls(date_path) do
      {:ok, time_folders} ->
        Enum.flat_map(
          time_folders,
          &process_time_folder(&1, group_slug, date, date_path, preferred_language)
        )

      {:error, _} ->
        []
    end
  end

  defp process_time_folder(time_folder, group_slug, date, date_path, preferred_language) do
    time_path = Path.join(date_path, time_folder)

    case Helpers.parse_time_folder(time_folder) do
      {:ok, time} ->
        list_post_for_structure(group_slug, date, time, time_path, preferred_language)

      _ ->
        []
    end
  end

  defp list_post_for_structure(group_slug, date, time, time_path, preferred_language) do
    case Versions.detect_post_structure(time_path) do
      :versioned ->
        list_versioned_timestamp_post(group_slug, date, time, time_path, preferred_language)

      :legacy ->
        list_legacy_timestamp_post(group_slug, date, time, time_path, preferred_language)

      :empty ->
        []
    end
  end

  defp list_versioned_timestamp_post(group_slug, date, time, time_path, preferred_language) do
    versions = list_versions_for_timestamp(time_path)
    primary_language = Languages.get_primary_language()
    latest_version = Enum.max(versions, fn -> 1 end)
    version_dir = Path.join(time_path, "v#{latest_version}")

    available_languages = Languages.detect_available_languages(version_dir)

    if Enum.empty?(available_languages) do
      []
    else
      display_language = select_display_language(available_languages, preferred_language)
      post_path = Path.join(version_dir, Languages.language_filename(display_language))

      case File.read(post_path) do
        {:ok, file_content} ->
          case Metadata.parse_with_content(file_content) do
            {:ok, metadata, content} ->
              version_statuses =
                load_version_statuses_timestamp(time_path, versions, primary_language)

              [
                %{
                  group: group_slug,
                  slug:
                    Helpers.get_slug_with_fallback(metadata, Helpers.format_time_folder(time)),
                  date: date,
                  time: time,
                  path:
                    Helpers.relative_path_with_language_versioned(
                      group_slug,
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
                  language_statuses:
                    Languages.load_language_statuses(version_dir, available_languages),
                  available_versions: versions,
                  version_statuses: version_statuses,
                  version: latest_version,
                  is_legacy_structure: false,
                  mode: :timestamp,
                  primary_language:
                    Map.get(metadata, :primary_language) || Languages.get_primary_language()
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

  defp list_legacy_timestamp_post(group_slug, date, time, time_path, preferred_language) do
    available_languages = Languages.detect_available_languages(time_path)

    if Enum.empty?(available_languages) do
      []
    else
      display_language = select_display_language(available_languages, preferred_language)
      post_path = Path.join(time_path, Languages.language_filename(display_language))

      case File.read(post_path) do
        {:ok, file_content} ->
          case Metadata.parse_with_content(file_content) do
            {:ok, metadata, content} ->
              language_statuses = Languages.load_language_statuses(time_path, available_languages)

              [
                %{
                  group: group_slug,
                  slug:
                    Helpers.get_slug_with_fallback(metadata, Helpers.format_time_folder(time)),
                  date: date,
                  time: time,
                  path:
                    Helpers.relative_path_with_language(group_slug, date, time, display_language),
                  full_path: post_path,
                  metadata: metadata,
                  content: content,
                  language: display_language,
                  available_languages: available_languages,
                  language_statuses: language_statuses,
                  is_legacy_structure: true,
                  mode: :timestamp,
                  primary_language:
                    Map.get(metadata, :primary_language) || Languages.get_primary_language()
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

  defp list_versions_for_timestamp(post_dir) do
    case File.ls(post_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Versions.version_dir?/1)
        |> Enum.map(fn dir -> String.replace_prefix(dir, "v", "") |> String.to_integer() end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp load_version_statuses_timestamp(post_dir, versions, language) do
    Enum.reduce(versions, %{}, fn version, acc ->
      version_dir = Path.join(post_dir, "v#{version}")
      status = get_timestamp_version_status(version_dir, language)
      Map.put(acc, version, status)
    end)
  end

  defp get_timestamp_version_status(version_dir, language) do
    lang_file = Path.join(version_dir, Languages.language_filename(language))

    if File.exists?(lang_file) do
      read_status_from_file(lang_file)
    else
      read_status_from_any_language(version_dir)
    end
  end

  defp read_status_from_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, metadata, _} = Metadata.parse_with_content(content)
        Map.get(metadata, :status, "draft")

      _ ->
        "draft"
    end
  end

  defp read_status_from_any_language(version_dir) do
    case File.ls(version_dir) do
      {:ok, files} ->
        phk_file = Enum.find(files, &String.ends_with?(&1, ".phk"))
        if phk_file, do: read_status_from_file(Path.join(version_dir, phk_file)), else: "draft"

      _ ->
        "draft"
    end
  end

  @doc """
  Reads a post for a specific language (timestamp mode).
  """
  @spec read_post(String.t(), String.t()) :: {:ok, post()} | {:error, any()}
  def read_post(group_slug, relative_path) do
    full_path = Paths.absolute_path(relative_path)
    language = Helpers.extract_language_from_path(relative_path)

    {actual_path, actual_language, is_new_translation} =
      if File.exists?(full_path) do
        {full_path, language, false}
      else
        lang_dir = Path.dirname(full_path)

        if File.dir?(lang_dir) do
          case Languages.detect_available_languages(lang_dir) do
            [first_lang | _] ->
              fallback_path = Path.join(lang_dir, "#{first_lang}.phk")
              {fallback_path, first_lang, true}

            [] ->
              {full_path, language, false}
          end
        else
          {full_path, language, false}
        end
      end

    with true <- File.exists?(actual_path),
         {:ok, metadata, content} <- File.read!(actual_path) |> Metadata.parse_with_content(),
         {:ok, {date, time}} <- Helpers.date_time_from_path(relative_path) do
      lang_dir = Path.dirname(full_path)
      {is_versioned, version, post_dir} = detect_version_from_path(relative_path, lang_dir)
      available_languages = Languages.detect_available_languages(lang_dir)

      {available_versions, version_statuses} =
        if is_versioned do
          versions = list_versions_for_timestamp(post_dir)
          statuses = load_version_statuses_timestamp(post_dir, versions, language)
          {versions, statuses}
        else
          {[], %{}}
        end

      language_statuses = Languages.load_language_statuses(lang_dir, available_languages)

      {final_language, final_content, final_path} =
        if is_new_translation do
          {language, "", relative_path}
        else
          {actual_language, content, relative_path}
        end

      {:ok,
       %{
         group: group_slug,
         slug:
           Helpers.get_slug_with_fallback(metadata, Path.basename(Path.dirname(relative_path))),
         date: date,
         time: time,
         path: final_path,
         full_path: full_path,
         metadata: metadata,
         content: final_content,
         language: final_language,
         available_languages: available_languages,
         language_statuses: language_statuses,
         mode: :timestamp,
         version: version,
         available_versions: available_versions,
         version_statuses: version_statuses,
         is_legacy_structure: not is_versioned,
         is_new_translation: is_new_translation,
         primary_language:
           Map.get(metadata, :primary_language) || Languages.get_primary_language()
       }}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp detect_version_from_path(relative_path, lang_dir) do
    path_parts = Path.split(relative_path)
    version_part = Enum.find(path_parts, &Versions.version_dir?/1)

    if version_part do
      version = String.replace_prefix(version_part, "v", "") |> String.to_integer()
      post_dir = Path.dirname(lang_dir)
      {true, version, post_dir}
    else
      {false, 1, lang_dir}
    end
  end

  # ============================================================================
  # Slug Mode Operations
  # ============================================================================

  @doc """
  Lists slug-mode posts for the given group.
  """
  @spec list_posts_slug_mode(String.t(), String.t() | nil) :: [post()]
  def list_posts_slug_mode(group_slug, preferred_language \\ nil) do
    group_root = Paths.group_path(group_slug)

    if File.dir?(group_root) do
      group_root
      |> File.ls!()
      |> Enum.flat_map(
        &posts_for_slug(group_slug, &1, Path.join(group_root, &1), preferred_language)
      )
      |> Enum.sort_by(&published_at_sort_key(&1.metadata), {:desc, DateTime})
    else
      []
    end
  end

  defp posts_for_slug(group_slug, post_slug, post_path, preferred_language) do
    if File.dir?(post_path) do
      do_posts_for_slug(group_slug, post_slug, post_path, preferred_language)
    else
      []
    end
  end

  defp do_posts_for_slug(group_slug, post_slug, post_path, preferred_language) do
    structure = Versions.detect_post_structure(post_path)

    with {:ok, version, content_dir} <-
           Versions.resolve_version_dir_for_listing(post_path, structure, group_slug, post_slug),
         available_languages when available_languages != [] <-
           Languages.detect_available_languages(content_dir),
         {:ok, display_language} <- resolve_language(available_languages, preferred_language),
         file_path <- Path.join(content_dir, Languages.language_filename(display_language)),
         true <- File.exists?(file_path),
         {:ok, metadata, content} <- File.read!(file_path) |> Metadata.parse_with_content() do
      is_legacy = structure == :legacy
      primary_language = Map.get(metadata, :primary_language) || Languages.get_primary_language()
      all_versions = Versions.list_versions(group_slug, post_slug)

      version_statuses =
        Versions.load_version_statuses(group_slug, post_slug, all_versions, primary_language)

      version_dates =
        Versions.load_version_dates(group_slug, post_slug, all_versions, primary_language)

      version_languages =
        Versions.load_version_languages(group_slug, post_slug, all_versions)

      [
        %{
          group: group_slug,
          slug: post_slug,
          date: nil,
          time: nil,
          path:
            build_slug_relative_path(group_slug, post_slug, version, display_language, structure),
          full_path: file_path,
          metadata: metadata,
          content: content,
          language: display_language,
          available_languages: available_languages,
          language_statuses: Languages.load_language_statuses(content_dir, available_languages),
          mode: :slug,
          version: version,
          available_versions: all_versions,
          version_statuses: version_statuses,
          version_dates: version_dates,
          version_languages: version_languages,
          is_legacy_structure: is_legacy,
          primary_language: primary_language
        }
      ]
    else
      _ -> []
    end
  end

  defp build_slug_relative_path(group_slug, post_slug, version, display_language, :versioned) do
    Path.join([
      group_slug,
      post_slug,
      "v#{version}",
      Languages.language_filename(display_language)
    ])
  end

  defp build_slug_relative_path(group_slug, post_slug, _version, display_language, :legacy) do
    Path.join([group_slug, post_slug, Languages.language_filename(display_language)])
  end

  defp resolve_language(available_languages, preferred_language) do
    code =
      cond do
        preferred_language && preferred_language in available_languages ->
          preferred_language

        preferred_language && base_code?(preferred_language) ->
          find_dialect_for_base(available_languages, preferred_language) ||
            select_display_language(available_languages, preferred_language)

        true ->
          select_display_language(available_languages, preferred_language)
      end

    {:ok, code}
  end

  defp base_code?(code) when is_binary(code) do
    String.length(code) == 2 and not String.contains?(code, "-")
  end

  defp base_code?(_), do: false

  defp find_dialect_for_base(available_languages, base_code) do
    base_lower = String.downcase(base_code)

    Enum.find(available_languages, fn lang ->
      DialectMapper.extract_base(lang) == base_lower
    end)
  end

  defp published_at_sort_key(%{published_at: nil}) do
    ~U[1970-01-01 00:00:00Z]
  end

  defp published_at_sort_key(%{published_at: published_at}) do
    case DateTime.from_iso8601(published_at) do
      {:ok, datetime, _} -> datetime
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  @doc """
  Reads a slug-mode post.
  """
  @spec read_post_slug_mode(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, post()} | {:error, any()}
  def read_post_slug_mode(group_slug, post_slug, language \\ nil, version \\ nil) do
    language = language || Languages.get_primary_language()
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    structure = Versions.detect_post_structure(post_path)

    with {:ok, target_version, version_dir} <-
           Versions.resolve_version_dir(post_path, structure, version, group_slug, post_slug),
         available_languages when available_languages != [] <-
           Languages.detect_available_languages(version_dir),
         display_language <- select_language_or_fallback(language, available_languages),
         file_path <- Path.join(version_dir, Languages.language_filename(display_language)),
         true <- File.exists?(file_path),
         {:ok, metadata, content} <- File.read!(file_path) |> Metadata.parse_with_content() do
      is_legacy = structure == :legacy
      is_new_translation = display_language != language
      primary_language = Map.get(metadata, :primary_language) || Languages.get_primary_language()
      all_versions = Versions.list_versions(group_slug, post_slug)

      version_statuses =
        Versions.load_version_statuses(group_slug, post_slug, all_versions, primary_language)

      version_dates =
        Versions.load_version_dates(group_slug, post_slug, all_versions, primary_language)

      {:ok,
       %{
         group: group_slug,
         slug: post_slug,
         date: nil,
         time: nil,
         path:
           build_slug_relative_path(
             group_slug,
             post_slug,
             target_version,
             display_language,
             structure
           ),
         full_path: file_path,
         metadata: metadata,
         content: if(is_new_translation, do: "", else: content),
         language: if(is_new_translation, do: language, else: display_language),
         available_languages: available_languages,
         language_statuses: Languages.load_language_statuses(version_dir, available_languages),
         mode: :slug,
         version: target_version,
         available_versions: all_versions,
         version_statuses: version_statuses,
         version_dates: version_dates,
         is_legacy_structure: is_legacy,
         is_new_translation: is_new_translation,
         primary_language: primary_language
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp select_language_or_fallback(language, available_languages) do
    if language in available_languages do
      language
    else
      hd(available_languages)
    end
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Checks if the content or title has changed.
  """
  @spec content_changed?(post(), map()) :: boolean()
  def content_changed?(post, params) do
    current_content = post.content || ""
    new_content = Map.get(params, "content", current_content)

    current_title = Map.get(post.metadata, :title, "")
    new_title = Map.get(params, "title", current_title)

    String.trim(current_content) != String.trim(new_content) or
      String.trim(current_title) != String.trim(new_title)
  end

  @doc """
  Checks if only the status is being changed (no content or title changes).
  Status-only changes don't require a new version.
  """
  @spec status_change_only?(post(), map()) :: boolean()
  def status_change_only?(post, params) do
    current_status = Map.get(post.metadata, :status, "draft")
    new_status = Map.get(params, "status", current_status)
    status_changing? = current_status != new_status

    content_changing? = content_changed?(post, params)

    current_image = Map.get(post.metadata, :featured_image_id)
    new_image = Helpers.resolve_featured_image_id(params, post.metadata)
    image_changing? = current_image != new_image

    status_changing? and not content_changing? and not image_changing?
  end

  @doc """
  Checks whether a new version should be created based on changes.
  Currently always returns false - users create new versions explicitly.
  """
  @spec should_create_new_version?(post(), map(), String.t()) :: boolean()
  def should_create_new_version?(_post, _params, _editing_language) do
    # Auto-version creation disabled - users create new versions explicitly
    false
  end
end
