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
  alias PhoenixKit.Modules.Publishing.Storage.Deletion
  alias PhoenixKit.Modules.Publishing.Storage.Helpers
  alias PhoenixKit.Modules.Publishing.Storage.Languages
  alias PhoenixKit.Modules.Publishing.Storage.Paths
  alias PhoenixKit.Modules.Publishing.Storage.Slugs
  alias PhoenixKit.Modules.Publishing.Storage.Versions
  alias PhoenixKit.Settings

  require Logger

  # Suppress dialyzer false positives for pattern matches
  @dialyzer {:nowarn_function, add_language_to_post: 3}
  @dialyzer {:nowarn_function, add_language_to_post_slug_mode: 4}
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
  defdelegate update_post_primary_language(group_slug, post_slug, new_primary), to: Languages
  defdelegate get_language_info(language_code), to: Languages
  defdelegate language_enabled?(language_code, enabled_languages), to: Languages
  defdelegate get_display_code(language_code, enabled_languages), to: Languages
  defdelegate order_languages_for_display(available, enabled, primary \\ nil), to: Languages
  defdelegate detect_available_languages(dir_path, primary \\ nil), to: Languages
  defdelegate load_language_statuses(post_dir, available_languages), to: Languages

  defdelegate propagate_status_to_translations(post_dir, primary_language, new_status),
    to: Languages

  # ============================================================================
  # Delegated Functions - Paths
  # ============================================================================

  defdelegate root_path(), to: Paths
  defdelegate group_path(group_slug), to: Paths
  defdelegate write_root_path(), to: Paths
  defdelegate new_root_path(), to: Paths
  defdelegate legacy_root_path(), to: Paths
  defdelegate legacy_group?(group_slug), to: Paths
  defdelegate migrate_group(group_slug), to: Paths
  defdelegate cleanup_empty_legacy_root(), to: Paths
  defdelegate has_legacy_groups?(), to: Paths
  defdelegate ensure_group_root(group_slug), to: Paths
  defdelegate absolute_path(relative_path), to: Paths

  # ============================================================================
  # Delegated Functions - Slugs
  # ============================================================================

  defdelegate validate_slug(slug), to: Slugs
  defdelegate valid_slug?(slug), to: Slugs
  defdelegate validate_url_slug(group_slug, url_slug, language, exclude \\ nil), to: Slugs
  defdelegate slug_exists?(group_slug, post_slug), to: Slugs
  defdelegate generate_unique_slug(group_slug, title, preferred \\ nil, opts \\ []), to: Slugs
  defdelegate clear_url_slug_from_post(group_slug, post_slug, url_slug), to: Slugs

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
  # Delegated Functions - Deletion
  # ============================================================================

  defdelegate trash_post(group_slug, post_identifier), to: Deletion
  defdelegate trash_language(group_slug, relative_path), to: Deletion
  defdelegate delete_language(group_slug, post_id, language, version \\ nil), to: Deletion
  defdelegate delete_version(group_slug, post_id, version), to: Deletion

  # ============================================================================
  # Timestamp Mode Operations
  # ============================================================================

  @doc """
  Counts the number of posts on a specific date for a blog.
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
  Lists all time folders (posts) for a specific date in a blog.
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
  Lists posts for the given blog (timestamp mode).
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
  Creates a new post (timestamp mode), returning its metadata and content.
  """
  @spec create_post(String.t(), map() | keyword()) :: {:ok, post()} | {:error, any()}
  def create_post(group_slug, audit_meta \\ %{})

  def create_post(group_slug, audit_meta) when is_list(audit_meta) do
    create_post(group_slug, Map.new(audit_meta))
  end

  def create_post(group_slug, audit_meta) do
    audit_meta = Map.new(audit_meta)

    now =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> Helpers.floor_to_minute()

    date = DateTime.to_date(now)
    time = DateTime.to_time(now)
    primary_language = Languages.get_primary_language()

    slug = group_slug || "default"

    time_dir =
      Path.join([Paths.group_path(slug), Date.to_iso8601(date), Helpers.format_time_folder(time)])

    v1_dir = Path.join(time_dir, "v1")
    File.mkdir_p!(v1_dir)

    metadata =
      Metadata.default_metadata()
      |> Map.put(:status, "draft")
      |> Map.put(:published_at, DateTime.to_iso8601(now))
      |> Map.put(:slug, Helpers.format_time_folder(time))
      |> Map.put(:version, 1)
      |> Map.put(:version_created_at, DateTime.to_iso8601(now))
      |> Map.put(:primary_language, primary_language)
      |> Helpers.apply_creation_audit_metadata(audit_meta)

    content = Metadata.serialize(metadata) <> "\n\n"

    primary_lang_path = Path.join(v1_dir, Languages.language_filename(primary_language))

    case File.write(primary_lang_path, content) do
      :ok ->
        group_slug_for_path = group_slug || slug

        primary_path =
          Helpers.relative_path_with_language_versioned(
            group_slug_for_path,
            date,
            time,
            1,
            primary_language
          )

        full_path = Paths.absolute_path(primary_path)

        {:ok,
         %{
           group: group_slug_for_path,
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
           is_legacy_structure: false,
           primary_language: primary_language
         }}

      {:error, reason} ->
        {:error, reason}
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

  @doc """
  Adds a new language file to an existing post (timestamp mode).
  """
  @spec add_language_to_post(String.t(), String.t(), String.t()) ::
          {:ok, post()} | {:error, any()}
  def add_language_to_post(group_slug, post_path, language_code) do
    with {:ok, original_post} <- read_post(group_slug, post_path),
         time_dir <- Path.dirname(original_post.full_path),
         new_file_path <- Path.join(time_dir, Languages.language_filename(language_code)),
         false <- File.exists?(new_file_path) do
      metadata =
        original_post.metadata
        |> Map.put(:title, "")
        |> Map.put(:status, "draft")

      # Inherit published_at from original post (don't set to nil)

      content = Metadata.serialize(metadata) <> "\n\n"

      case File.write(new_file_path, content) do
        :ok ->
          new_relative_path =
            if original_post.is_legacy_structure do
              Helpers.relative_path_with_language(
                group_slug,
                original_post.date,
                original_post.time,
                language_code
              )
            else
              Helpers.relative_path_with_language_versioned(
                group_slug,
                original_post.date,
                original_post.time,
                original_post.version || 1,
                language_code
              )
            end

          read_post(group_slug, new_relative_path)

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates a post's metadata/content (timestamp mode).
  """
  @spec update_post(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def update_post(_group_slug, post, params, audit_meta \\ %{})

  def update_post(group_slug, post, params, audit_meta) when is_list(audit_meta) do
    update_post(group_slug, post, params, Map.new(audit_meta))
  end

  def update_post(_group_slug, post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)

    featured_image_id = Helpers.resolve_featured_image_id(params, post.metadata)
    current_status = Map.get(post.metadata, :status, "draft")
    new_status = Map.get(params, "status", current_status)
    is_primary_language = Map.get(audit_meta, :is_primary_language, true)
    status_changing = new_status != current_status

    new_metadata =
      post.metadata
      |> Map.put(:title, Map.get(params, "title", post.metadata.title))
      |> Map.put(:status, new_status)
      |> Map.put(:published_at, Map.get(params, "published_at", post.metadata.published_at))
      |> Map.put(:featured_image_id, featured_image_id)
      |> Helpers.apply_update_audit_metadata(audit_meta)

    new_content = Map.get(params, "content", post.content)
    new_path = post.path
    full_new_path = Paths.absolute_path(new_path)

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
          Paths.cleanup_empty_dirs(post.full_path)
        end

        {date, time} = Helpers.date_time_from_path!(new_path)
        time_dir = Path.dirname(full_new_path)
        available_languages = Languages.detect_available_languages(time_dir)

        if status_changing and is_primary_language do
          Languages.propagate_status_to_translations(time_dir, post.language, new_status)
        end

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

  # ============================================================================
  # Slug Mode Operations
  # ============================================================================

  @doc """
  Creates a slug-mode post, returning metadata and paths for the primary language.
  """
  @spec create_post_slug_mode(String.t(), String.t() | nil, String.t() | nil, map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def create_post_slug_mode(group_slug, title \\ nil, preferred_slug \\ nil, audit_meta \\ %{})

  def create_post_slug_mode(group_slug, title, preferred_slug, audit_meta)
      when is_list(audit_meta) do
    create_post_slug_mode(group_slug, title, preferred_slug, Map.new(audit_meta))
  end

  def create_post_slug_mode(group_slug, title, preferred_slug, audit_meta) do
    audit_meta = Map.new(audit_meta)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Slugs.generate_unique_slug(group_slug, title || "", preferred_slug) do
      {:ok, post_slug} ->
        create_post_with_slug(group_slug, post_slug, title, audit_meta, now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_post_with_slug(group_slug, post_slug, title, audit_meta, now) do
    primary_language = Languages.get_primary_language()
    version = 1

    version_dir = Path.join([Paths.group_path(group_slug), post_slug, "v#{version}"])
    File.mkdir_p!(version_dir)

    metadata =
      %{
        slug: post_slug,
        title: title || "",
        description: nil,
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        created_at: DateTime.to_iso8601(now),
        version: version,
        version_created_at: DateTime.to_iso8601(now),
        version_created_from: nil,
        allow_version_access: false,
        primary_language: primary_language
      }
      |> Helpers.apply_creation_audit_metadata(audit_meta)

    content = Metadata.serialize(metadata) <> "\n\n"
    primary_lang_path = Path.join(version_dir, Languages.language_filename(primary_language))

    case File.write(primary_lang_path, content) do
      :ok ->
        # Clear any custom url_slugs that conflict with this new directory slug
        # Directory slugs have priority over custom url_slugs
        Slugs.clear_conflicting_url_slugs(group_slug, post_slug)

        {:ok,
         %{
           group: group_slug,
           slug: post_slug,
           url_slug: post_slug,
           date: nil,
           time: nil,
           path:
             Path.join([
               group_slug,
               post_slug,
               "v#{version}",
               Languages.language_filename(primary_language)
             ]),
           full_path: primary_lang_path,
           metadata: metadata,
           content: "",
           language: primary_language,
           available_languages: [primary_language],
           language_statuses: %{primary_language => "draft"},
           mode: :slug,
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

  @doc """
  Updates slug-mode posts.
  """
  @spec update_post_slug_mode(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def update_post_slug_mode(group_slug, post, params, audit_meta \\ %{})

  def update_post_slug_mode(group_slug, post, params, audit_meta) when is_list(audit_meta) do
    update_post_slug_mode(group_slug, post, params, Map.new(audit_meta))
  end

  def update_post_slug_mode(group_slug, post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)
    desired_slug = Map.get(params, "slug", post.slug)

    if desired_slug == post.slug do
      update_post_slug_in_place(group_slug, post, params, audit_meta)
    else
      case Slugs.validate_slug(desired_slug) do
        {:ok, _valid_slug} ->
          if Slugs.slug_exists?(group_slug, desired_slug) do
            {:error, :slug_already_exists}
          else
            move_post_to_new_slug(group_slug, post, desired_slug, params, audit_meta)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Updates slug-mode posts in place (no slug change).
  """
  @spec update_post_slug_in_place(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def update_post_slug_in_place(_group_slug, post, params, audit_meta \\ %{})

  def update_post_slug_in_place(group_slug, post, params, audit_meta) when is_list(audit_meta) do
    update_post_slug_in_place(group_slug, post, params, Map.new(audit_meta))
  end

  def update_post_slug_in_place(_group_slug, post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)

    current_status = Helpers.metadata_value(post.metadata, :status, "draft")
    new_status = Map.get(params, "status", current_status)
    becoming_published? = current_status != "published" and new_status == "published"
    status_changing = new_status != current_status
    is_primary_language = Map.get(audit_meta, :is_primary_language, true)

    metadata = Helpers.build_update_metadata(post, params, audit_meta, becoming_published?)
    content = Map.get(params, "content", post.content)
    serialized = Metadata.serialize(metadata) <> "\n\n" <> String.trim_leading(content)

    case File.write(post.full_path, serialized <> "\n") do
      :ok ->
        if status_changing and is_primary_language do
          version_dir = Path.dirname(post.full_path)
          Languages.propagate_status_to_translations(version_dir, post.language, new_status)
        end

        {:ok, %{post | metadata: metadata, content: content}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Moves a slug-mode post to a new slug.
  """
  @spec move_post_to_new_slug(String.t(), post(), String.t(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def move_post_to_new_slug(group_slug, post, new_slug, params, audit_meta \\ %{})

  def move_post_to_new_slug(group_slug, post, new_slug, params, audit_meta)
      when is_list(audit_meta) do
    move_post_to_new_slug(group_slug, post, new_slug, params, Map.new(audit_meta))
  end

  def move_post_to_new_slug(group_slug, post, new_slug, params, audit_meta) do
    audit_meta = Map.new(audit_meta)
    old_dir = Path.join([Paths.group_path(group_slug), post.slug])
    new_dir = Path.join([Paths.group_path(group_slug), new_slug])
    structure = Versions.detect_post_structure(old_dir)

    case structure do
      :versioned ->
        move_versioned_post_to_new_slug(
          group_slug,
          post,
          new_slug,
          params,
          audit_meta,
          old_dir,
          new_dir
        )

      _ ->
        move_legacy_post_to_new_slug(
          group_slug,
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
         group_slug,
         post,
         new_slug,
         params,
         audit_meta,
         old_dir,
         new_dir
       ) do
    :ok = File.rename(old_dir, new_dir)
    update_slug_in_all_versions(new_dir, new_slug, post, params, audit_meta)

    version = post.version || 1

    new_path =
      Path.join([group_slug, new_slug, "v#{version}", Languages.language_filename(post.language)])

    new_full_path =
      Path.join([new_dir, "v#{version}", Languages.language_filename(post.language)])

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
         available_languages:
           Languages.detect_available_languages(Path.join(new_dir, "v#{version}"))
     }}
  end

  defp update_slug_in_all_versions(new_dir, new_slug, post, params, audit_meta) do
    version_dirs =
      new_dir
      |> File.ls!()
      |> Enum.filter(&String.match?(&1, ~r/^v\d+$/))
      |> Enum.map(&Path.join(new_dir, &1))

    Enum.each(version_dirs, fn version_dir ->
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

        base_metadata = Map.put(metadata, :slug, new_slug)

        {final_metadata, final_content} =
          if lang_code == post.language and Path.basename(version_dir) == "v#{post.version || 1}" do
            featured_image_id = Helpers.resolve_featured_image_id(params, metadata)

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

        final_metadata = Helpers.apply_update_audit_metadata(final_metadata, audit_meta)

        serialized =
          Metadata.serialize(final_metadata) <> "\n\n" <> String.trim_leading(final_content)

        File.write!(file_path, serialized <> "\n")
      end)
    end)
  end

  defp move_legacy_post_to_new_slug(
         group_slug,
         post,
         new_slug,
         params,
         audit_meta,
         old_dir,
         new_dir
       ) do
    File.mkdir_p!(new_dir)

    Enum.each(post.available_languages, fn lang_code ->
      old_file = Path.join(old_dir, Languages.language_filename(lang_code))
      new_file = Path.join(new_dir, Languages.language_filename(lang_code))

      if File.exists?(old_file) do
        {:ok, metadata, content} =
          old_file
          |> File.read!()
          |> Metadata.parse_with_content()

        base_metadata = Map.put(metadata, :slug, new_slug)

        {final_metadata, final_content} =
          if lang_code == post.language do
            featured_image_id = Helpers.resolve_featured_image_id(params, metadata)

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

        final_metadata = Helpers.apply_update_audit_metadata(final_metadata, audit_meta)

        serialized =
          Metadata.serialize(final_metadata) <> "\n\n" <> String.trim_leading(final_content)

        File.write!(new_file, serialized <> "\n")
        File.rm!(old_file)
      end
    end)

    File.rmdir!(old_dir)

    new_path = Path.join([group_slug, new_slug, Languages.language_filename(post.language)])
    new_full_path = Path.join(new_dir, Languages.language_filename(post.language))

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
         available_languages: Languages.detect_available_languages(new_dir)
     }}
  end

  @doc """
  Adds a new language file to a slug-mode post.
  """
  @spec add_language_to_post_slug_mode(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, post()} | {:error, any()}
  def add_language_to_post_slug_mode(group_slug, post_slug, language_code, version \\ nil) do
    primary_language = Languages.get_post_primary_language(group_slug, post_slug, version)

    with {:ok, original_post} <-
           read_post_slug_mode(group_slug, post_slug, primary_language, version),
         post_dir <- Path.dirname(original_post.full_path),
         target_path <- Path.join(post_dir, Languages.language_filename(language_code)),
         false <- File.exists?(target_path) do
      metadata =
        original_post.metadata
        |> Map.take([
          :slug,
          :published_at,
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

      serialized = Metadata.serialize(metadata) <> "\n\n"

      case File.write(target_path, serialized <> "\n") do
        :ok ->
          read_post_slug_mode(group_slug, post_slug, language_code, version)

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Version Creation Operations
  # ============================================================================

  @doc """
  Creates a new version of a post from a specified source version or blank.
  """
  @spec create_version_from(String.t(), String.t(), integer() | nil, map(), map()) ::
          {:ok, post()} | {:error, any()}
  def create_version_from(group_slug, post_slug, source_version, params \\ %{}, audit_meta \\ %{})

  def create_version_from(group_slug, post_slug, nil, params, audit_meta) do
    create_blank_version(group_slug, post_slug, params, audit_meta)
  end

  def create_version_from(group_slug, post_slug, source_version, params, audit_meta)
      when is_integer(source_version) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    source_dir = Path.join(post_path, "v#{source_version}")

    if File.dir?(source_dir) do
      create_version_from_source(group_slug, post_slug, source_version, params, audit_meta)
    else
      {:error, :source_version_not_found}
    end
  end

  defp create_blank_version(group_slug, post_slug, params, audit_meta) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    versions = Versions.list_versions(group_slug, post_slug)
    new_version = if versions == [], do: 1, else: Enum.max(versions) + 1

    new_version_dir = Path.join(post_path, "v#{new_version}")
    primary_language = Languages.get_post_primary_language(group_slug, post_slug, nil)

    case File.mkdir(new_version_dir) do
      :ok ->
        metadata =
          %{
            status: "draft",
            slug: post_slug,
            title: Map.get(params, "title", ""),
            published_at: DateTime.to_iso8601(now),
            version: new_version,
            version_created_at: DateTime.to_iso8601(now),
            version_created_from: nil,
            allow_version_access: false,
            primary_language: primary_language
          }
          |> Helpers.apply_creation_audit_metadata(audit_meta)

        content = Map.get(params, "content", "")
        serialized = Metadata.serialize(metadata) <> "\n\n" <> String.trim_leading(content)

        primary_file = Path.join(new_version_dir, Languages.language_filename(primary_language))
        File.write!(primary_file, serialized <> "\n")

        read_post_slug_mode(group_slug, post_slug, primary_language, new_version)

      {:error, :eexist} ->
        create_blank_version(group_slug, post_slug, params, audit_meta)

      {:error, :enoent} ->
        File.mkdir_p!(post_path)
        create_blank_version(group_slug, post_slug, params, audit_meta)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_version_from_source(group_slug, post_slug, source_version, params, audit_meta) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    source_dir = Path.join(post_path, "v#{source_version}")
    versions = Versions.list_versions(group_slug, post_slug)
    new_version = Enum.max(versions) + 1
    new_version_dir = Path.join(post_path, "v#{new_version}")
    primary_language = Languages.get_post_primary_language(group_slug, post_slug, source_version)

    case File.mkdir(new_version_dir) do
      :ok ->
        {:ok, files} = File.ls(source_dir)
        phk_files = Enum.filter(files, &String.ends_with?(&1, ".phk"))

        Enum.each(phk_files, fn file ->
          source_file = Path.join(source_dir, file)
          target_file = Path.join(new_version_dir, file)
          language = Path.rootname(file)
          is_primary = language == primary_language

          copy_file_for_branching(
            source_file,
            target_file,
            new_version,
            source_version,
            now,
            is_primary,
            params,
            audit_meta
          )
        end)

        read_post_slug_mode(group_slug, post_slug, primary_language, new_version)

      {:error, :eexist} ->
        create_version_from_source(group_slug, post_slug, source_version, params, audit_meta)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_file_for_branching(
         source,
         target,
         new_ver,
         source_ver,
         now,
         is_primary,
         params,
         audit_meta
       ) do
    {:ok, content} = File.read(source)
    {:ok, metadata, body} = Metadata.parse_with_content(content)

    new_metadata =
      metadata
      |> Map.put(:version, new_ver)
      |> Map.put(:version_created_at, DateTime.to_iso8601(now))
      |> Map.put(:version_created_from, source_ver)
      |> Map.put(:status, "draft")
      |> Map.delete(:is_live)
      |> Map.delete(:legacy_is_live)
      |> Helpers.apply_creation_audit_metadata(audit_meta)

    new_metadata =
      if is_primary do
        new_metadata
        |> Map.put(:title, Map.get(params, "title", Map.get(metadata, :title, "")))
        |> Map.put(:featured_image_id, Helpers.resolve_featured_image_id(params, metadata))
      else
        new_metadata
      end

    new_content = if is_primary, do: Map.get(params, "content", body), else: body

    serialized = Metadata.serialize(new_metadata) <> "\n\n" <> String.trim_leading(new_content)
    File.write!(target, serialized <> "\n")
  end

  @doc """
  Creates a new version of a post by copying from the source version.
  """
  @spec create_new_version(String.t(), post(), map(), map() | keyword()) ::
          {:ok, post()} | {:error, any()}
  def create_new_version(group_slug, source_post, params \\ %{}, audit_meta \\ %{})

  def create_new_version(group_slug, source_post, params, audit_meta) when is_list(audit_meta) do
    create_new_version(group_slug, source_post, params, Map.new(audit_meta))
  end

  def create_new_version(group_slug, source_post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case source_post.mode do
      :slug ->
        create_new_version_slug_mode(group_slug, source_post, params, audit_meta, now)

      :timestamp ->
        create_new_version_timestamp_mode(group_slug, source_post, params, audit_meta, now)

      _ ->
        {:error, :unsupported_mode}
    end
  end

  defp create_new_version_slug_mode(group_slug, source_post, params, audit_meta, now) do
    current_versions = Versions.list_versions(group_slug, source_post.slug)
    new_version = Enum.max(current_versions, fn -> 0 end) + 1
    new_version_dir = Versions.version_path(group_slug, source_post.slug, new_version)

    case File.mkdir(new_version_dir) do
      :ok ->
        copy_language_files_to_new_version(
          source_post,
          new_version_dir,
          new_version,
          params,
          audit_meta,
          now
        )

        primary_language = Languages.get_primary_language()
        read_post_slug_mode(group_slug, source_post.slug, primary_language, new_version)

      {:error, :eexist} ->
        create_new_version_slug_mode(group_slug, source_post, params, audit_meta, now)

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(new_version_dir))
        create_new_version_slug_mode(group_slug, source_post, params, audit_meta, now)

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp create_new_version_timestamp_mode(group_slug, source_post, params, audit_meta, now) do
    post_dir = Path.dirname(Path.dirname(source_post.full_path))
    current_versions = list_versions_for_timestamp(post_dir)
    new_version = Enum.max(current_versions, fn -> 0 end) + 1
    new_version_dir = Path.join(post_dir, "v#{new_version}")

    case File.mkdir(new_version_dir) do
      :ok ->
        copy_language_files_to_new_version(
          source_post,
          new_version_dir,
          new_version,
          params,
          audit_meta,
          now
        )

        primary_language = Languages.get_primary_language()

        new_relative_path =
          Helpers.relative_path_with_language_versioned(
            group_slug,
            source_post.date,
            source_post.time,
            new_version,
            primary_language
          )

        read_post(group_slug, new_relative_path)

      {:error, :eexist} ->
        create_new_version_timestamp_mode(group_slug, source_post, params, audit_meta, now)

      {:error, :enoent} ->
        File.mkdir_p!(post_dir)
        create_new_version_timestamp_mode(group_slug, source_post, params, audit_meta, now)

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
    primary_language = Languages.get_primary_language()
    source_file = Path.join(source_version_dir, Languages.language_filename(primary_language))
    target_file = Path.join(new_version_dir, Languages.language_filename(primary_language))

    if File.exists?(source_file) do
      {:ok, source_metadata, source_content} =
        source_file
        |> File.read!()
        |> Metadata.parse_with_content()

      editing_primary? = source_post.language == primary_language

      new_metadata =
        source_metadata
        |> Map.put(:version, new_version)
        |> Map.put(:version_created_at, DateTime.to_iso8601(now))
        |> Map.put(:version_created_from, source_post.version || 1)
        |> Map.put(:status, "draft")
        |> Map.delete(:is_live)
        |> Map.delete(:legacy_is_live)
        |> then(fn meta ->
          if editing_primary? do
            meta
            |> Map.put(:title, Map.get(params, "title", source_metadata.title))
            |> Map.put(
              :featured_image_id,
              Helpers.resolve_featured_image_id(params, source_metadata)
            )
          else
            meta
          end
        end)
        |> Helpers.apply_creation_audit_metadata(audit_meta)

      new_content =
        if editing_primary?, do: Map.get(params, "content", source_content), else: source_content

      serialized =
        Metadata.serialize(new_metadata) <> "\n\n" <> String.trim_leading(new_content)

      File.write!(target_file, serialized <> "\n")
    end
  end

  @doc """
  Publishes a version, atomically archiving all other versions.
  """
  @spec publish_version(String.t(), String.t(), integer()) :: :ok | {:error, any()}
  def publish_version(group_slug, post_slug, version_to_publish) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])
    versions = Versions.list_versions(group_slug, post_slug)

    if version_to_publish in versions do
      do_publish_version(group_slug, post_slug, post_path, versions, version_to_publish)
    else
      {:error, :version_not_found}
    end
  end

  defp do_publish_version(group_slug, post_slug, post_path, versions, version_to_publish) do
    primary_language =
      Languages.get_post_primary_language(group_slug, post_slug, version_to_publish)

    results =
      Enum.flat_map(versions, fn version ->
        version_dir = get_version_dir(post_path, version)

        update_version_files_for_publish(
          version_dir,
          version,
          version_to_publish,
          primary_language
        )
      end)

    case Enum.find(results, &(&1 != :ok)) do
      nil -> :ok
      error -> error
    end
  end

  defp get_version_dir(post_path, version) do
    case Versions.detect_post_structure(post_path) do
      :versioned -> Path.join(post_path, "v#{version}")
      :legacy -> post_path
    end
  end

  defp update_version_files_for_publish(
         version_dir,
         version,
         version_to_publish,
         primary_language
       ) do
    case File.ls(version_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".phk"))
        |> Enum.map(
          &update_phk_file_for_publish(
            &1,
            version_dir,
            version,
            version_to_publish,
            primary_language
          )
        )

      {:error, _} ->
        []
    end
  end

  defp update_phk_file_for_publish(
         file,
         version_dir,
         version,
         version_to_publish,
         primary_language
       ) do
    file_path = Path.join(version_dir, file)
    language = Path.rootname(file)

    update_file_for_publish(file_path, %{
      is_primary: language == primary_language,
      is_target_version: version == version_to_publish
    })
  end

  defp update_file_for_publish(file_path, opts) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, metadata, body} = Metadata.parse_with_content(content)
        new_status = calculate_publish_status(metadata, opts)

        updated_metadata =
          metadata
          |> Map.put(:status, new_status)
          |> Map.delete(:is_live)
          |> Map.delete(:legacy_is_live)

        serialized =
          Metadata.serialize(updated_metadata) <> "\n\n" <> String.trim_leading(body)

        File.write(file_path, serialized <> "\n")

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp calculate_publish_status(metadata, opts) do
    current_status = Map.get(metadata, :status, "draft")

    cond do
      # Target version: all files (primary and translations) get published
      opts.is_target_version ->
        "published"

      # Non-target version: archive if was published, otherwise keep current
      current_status == "published" ->
        "archived"

      true ->
        current_status
    end
  end

  @doc """
  Deprecated: Use publish_version/3 instead.
  """
  @deprecated "Use publish_version/3 instead"
  @spec set_version_live(String.t(), String.t(), integer()) :: :ok | {:error, any()}
  def set_version_live(group_slug, post_slug, version) do
    publish_version(group_slug, post_slug, version)
  end

  # ============================================================================
  # Migration Operations
  # ============================================================================

  @doc """
  Migrates a single post from legacy structure to versioned structure.
  """
  @spec migrate_post_to_versioned(post(), String.t() | nil) :: {:ok, post()} | {:error, any()}
  def migrate_post_to_versioned(post, language \\ nil) do
    language = language || post.language
    post_dir = Path.dirname(post.full_path)

    if post.is_legacy_structure do
      do_migrate_post_to_versioned(post, post_dir, language)
    else
      {:ok, post}
    end
  end

  defp do_migrate_post_to_versioned(post, post_dir, language) do
    v1_dir = Path.join(post_dir, "v1")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with :ok <- File.mkdir_p(v1_dir),
         {:ok, phk_files} <- list_phk_files(post_dir),
         :ok <- migrate_files_to_v1(post_dir, v1_dir, phk_files, now, post.metadata) do
      new_path =
        case post.mode do
          :slug ->
            Path.join([post.group, post.slug, "v1", Languages.language_filename(language)])

          :timestamp ->
            Helpers.relative_path_with_language_versioned(
              post.group,
              post.date,
              post.time,
              1,
              language
            )
        end

      new_full_path = Path.join(v1_dir, Languages.language_filename(language))

      {:ok, new_metadata, new_content} =
        new_full_path
        |> File.read!()
        |> Metadata.parse_with_content()

      {:ok,
       %{
         post
         | path: new_path,
           full_path: new_full_path,
           metadata: new_metadata,
           content: new_content,
           version: 1,
           available_versions: [1],
           version_statuses: %{1 => new_metadata[:status] || "draft"},
           is_legacy_structure: false
       }}
    end
  end

  defp list_phk_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        phk_files = Enum.filter(files, &String.ends_with?(&1, ".phk"))
        {:ok, phk_files}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp migrate_files_to_v1(post_dir, v1_dir, phk_files, now, original_metadata) do
    primary_language = Languages.get_primary_language()

    Enum.each(phk_files, fn file ->
      source_path = Path.join(post_dir, file)
      target_path = Path.join(v1_dir, file)

      {:ok, metadata, content} =
        source_path
        |> File.read!()
        |> Metadata.parse_with_content()

      updated_metadata =
        metadata
        |> Map.put(:version, 1)
        |> Map.put(:version_created_at, DateTime.to_iso8601(now))
        |> Map.put(:primary_language, original_metadata[:primary_language] || primary_language)

      serialized = Metadata.serialize(updated_metadata) <> "\n\n" <> String.trim_leading(content)

      File.write!(target_path, serialized <> "\n")
      File.rm!(source_path)
    end)

    :ok
  end

  # ============================================================================
  # Translation Status
  # ============================================================================

  @doc """
  Sets the status of a specific translation (language file) in a version.
  """
  @spec set_translation_status(String.t(), String.t(), integer(), String.t(), String.t()) ::
          :ok | {:error, any()}
  def set_translation_status(group_slug, post_slug, version, language, status) do
    post_path = Path.join([Paths.group_path(group_slug), post_slug])

    file_path =
      case Versions.detect_post_structure(post_path) do
        :versioned -> Path.join([post_path, "v#{version}", Languages.language_filename(language)])
        :legacy -> Path.join([post_path, Languages.language_filename(language)])
      end

    case File.read(file_path) do
      {:ok, content} ->
        {:ok, metadata, body} = Metadata.parse_with_content(content)

        updated_metadata =
          metadata
          |> Map.put(:status, status)
          |> Map.delete(:is_live)
          |> Map.delete(:legacy_is_live)

        serialized =
          Metadata.serialize(updated_metadata) <> "\n\n" <> String.trim_leading(body)

        case File.write(file_path, serialized <> "\n") do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  @doc """
  Moves an entire publishing group to the trash folder.
  """
  @spec move_group_to_trash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def move_group_to_trash(group_slug) do
    source = Paths.group_path(group_slug)

    if File.dir?(source) do
      trash_dir = Path.join(Paths.root_path(), "trash")
      File.mkdir_p!(trash_dir)

      timestamp =
        DateTime.utc_now()
        |> Calendar.strftime("%Y-%m-%d-%H-%M-%S")

      new_name = "#{group_slug}-#{timestamp}"
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
  Renames a publishing group directory on disk when the slug changes.
  """
  @spec rename_group_directory(String.t(), String.t()) :: :ok | {:error, term()}
  def rename_group_directory(old_slug, new_slug) when old_slug == new_slug, do: :ok

  def rename_group_directory(old_slug, new_slug) do
    source = Paths.group_path(old_slug)
    destination = Path.join(Path.dirname(source), new_slug)

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
end
