defmodule PhoenixKitWeb.Live.Modules.Publishing.Storage do
  @moduledoc """
  Filesystem storage helpers for publishing entries.

  Content is stored under:

      priv/static/publishing/<type>/<YYYY-MM-DD>/<HH:MM>/<language>.phk

  Where <language> is determined by the site's content language setting.
  Files use the .phk (PhoenixKit) format, which supports XML-style
  component markup for building pages with swappable design variants.
  """

  alias PhoenixKitWeb.Live.Modules.Publishing.Metadata
  alias PhoenixKit.Settings
  alias PhoenixKit.Module.Languages

  @doc """
  Returns the filename for a specific language code.
  """
  @spec language_filename(String.t()) :: String.t()
  def language_filename(language_code) do
    "#{language_code}.phk"
  end

  @doc """
  Returns the filename for language-specific entries based on the site's
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
  Gets language details (name, flag) for a given language code.
  """
  @spec get_language_info(String.t()) ::
          %{code: String.t(), name: String.t(), flag: String.t()} | nil
  def get_language_info(language_code) do
    all_languages = Languages.get_available_languages()
    Enum.find(all_languages, fn lang -> lang.code == language_code end)
  end

  @type entry :: %{
          type: String.t(),
          date: Date.t(),
          time: Time.t(),
          path: String.t(),
          full_path: String.t(),
          metadata: map(),
          content: String.t(),
          language: String.t(),
          available_languages: [String.t()]
        }

  @doc """
  Returns the publishing root directory, creating it if needed.
  Always uses the parent application's priv directory.
  """
  @spec root_path() :: String.t()
  def root_path do
    parent_app = PhoenixKit.Config.get_parent_app() || :phoenix_kit

    # Get the parent app's priv directory
    # This ensures files are always stored in the parent app, not in PhoenixKit's deps folder
    base_priv = Application.app_dir(parent_app, "priv")
    base = Path.join(base_priv, "static/publishing")

    File.mkdir_p!(base)
    base
  end

  @doc """
  Ensures the folder for a type exists.
  """
  @spec ensure_type_root(String.t()) :: :ok | {:error, term()}
  def ensure_type_root(type_slug) do
    Path.join(root_path(), type_slug)
    |> File.mkdir_p()
  end

  @doc """
  Lists entries for the given type.
  Accepts optional preferred_language to show titles in user's language.
  Falls back to content language, then first available language.
  """
  @spec list_entries(String.t(), String.t() | nil) :: [entry()]
  def list_entries(type_slug, preferred_language \\ nil) do
    type_root = Path.join(root_path(), type_slug)

    if File.dir?(type_root) do
      type_root
      |> File.ls!()
      |> Enum.flat_map(
        &entries_for_date(type_slug, &1, Path.join(type_root, &1), preferred_language)
      )
      |> Enum.sort_by(&{&1.date, &1.time}, :desc)
    else
      []
    end
  end

  defp entries_for_date(type_slug, date_folder, date_path, preferred_language) do
    case Date.from_iso8601(date_folder) do
      {:ok, date} ->
        list_times(type_slug, date, date_path, preferred_language)

      _ ->
        []
    end
  end

  defp list_times(type_slug, date, date_path, preferred_language) do
    case File.ls(date_path) do
      {:ok, time_folders} ->
        Enum.flat_map(time_folders, fn time_folder ->
          time_path = Path.join(date_path, time_folder)

          with {:ok, time} <- parse_time_folder(time_folder),
               available_languages <- detect_available_languages(time_path),
               false <- Enum.empty?(available_languages),
               display_language <-
                 select_display_language(available_languages, preferred_language),
               entry_path <- Path.join(time_path, language_filename(display_language)),
               {:ok, metadata, content} <-
                 entry_path
                 |> File.read!()
                 |> Metadata.parse_with_content() do
            [
              %{
                type: type_slug,
                date: date,
                time: time,
                path: relative_path_with_language(type_slug, date, time, display_language),
                full_path: entry_path,
                metadata: metadata,
                content: content,
                language: display_language,
                available_languages: available_languages
              }
            ]
          else
            _ -> []
          end
        end)

      {:error, _} ->
        []
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

  defp extract_language_from_path(relative_path) do
    relative_path
    |> Path.basename()
    |> String.replace_suffix(".phk", "")
  end

  @doc """
  Creates a new entry, returning its metadata and content.
  Creates only the primary language file. Additional languages can be added later.
  """
  @spec create_entry(String.t()) :: {:ok, entry()} | {:error, any()}
  def create_entry(type_slug) do
    now =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> floor_to_minute()

    date = DateTime.to_date(now)
    time = DateTime.to_time(now)
    primary_language = hd(enabled_language_codes())

    # Create directory structure
    time_dir =
      Path.join([root_path(), type_slug, Date.to_iso8601(date), format_time_folder(time)])

    File.mkdir_p!(time_dir)

    metadata =
      Metadata.default_metadata()
      |> Map.put(:status, "draft")
      |> Map.put(:published_at, DateTime.to_iso8601(now))
      |> Map.put(:slug, format_time_folder(time))

    content = Metadata.serialize(metadata) <> "\n\n"

    # Create only primary language file
    primary_lang_path = Path.join(time_dir, language_filename(primary_language))

    case File.write(primary_lang_path, content) do
      :ok ->
        primary_path = relative_path_with_language(type_slug, date, time, primary_language)
        full_path = absolute_path(primary_path)

        {:ok,
         %{
           type: type_slug,
           date: date,
           time: time,
           path: primary_path,
           full_path: full_path,
           metadata: metadata,
           content: "",
           language: primary_language,
           available_languages: [primary_language]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads an entry for a specific language.
  """
  @spec read_entry(String.t(), String.t()) :: {:ok, entry()} | {:error, any()}
  def read_entry(type_slug, relative_path) do
    full_path = absolute_path(relative_path)
    language = extract_language_from_path(relative_path)

    with true <- File.exists?(full_path),
         {:ok, metadata, content} <- File.read!(full_path) |> Metadata.parse_with_content(),
         {:ok, {date, time}} <- date_time_from_path(relative_path),
         time_dir <- Path.dirname(full_path),
         available_languages <- detect_available_languages(time_dir) do
      {:ok,
       %{
         type: type_slug,
         date: date,
         time: time,
         path: relative_path,
         full_path: full_path,
         metadata: metadata,
         content: content,
         language: language,
         available_languages: available_languages
       }}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Adds a new language file to an existing entry by copying metadata from an existing language.
  """
  @spec add_language_to_entry(String.t(), String.t(), String.t()) ::
          {:ok, entry()} | {:error, any()}
  def add_language_to_entry(type_slug, entry_path, language_code) do
    # Read the original entry to get its metadata and structure
    with {:ok, original_entry} <- read_entry(type_slug, entry_path),
         time_dir <- Path.dirname(original_entry.full_path),
         new_file_path <- Path.join(time_dir, language_filename(language_code)),
         false <- File.exists?(new_file_path) do
      # Create new file with same metadata but empty content
      metadata = Map.put(original_entry.metadata, :title, "")
      content = Metadata.serialize(metadata) <> "\n\n"

      case File.write(new_file_path, content) do
        :ok ->
          # Return the newly created entry
          new_relative_path =
            relative_path_with_language(
              type_slug,
              original_entry.date,
              original_entry.time,
              language_code
            )

          read_entry(type_slug, new_relative_path)

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates an entry's metadata/content, moving files if needed.
  Preserves language and detects available languages.
  """
  @spec update_entry(String.t(), entry(), map()) :: {:ok, entry()} | {:error, any()}
  def update_entry(_type_slug, entry, params) do
    new_metadata =
      entry.metadata
      |> Map.put(:title, Map.get(params, "title", entry.metadata.title))
      |> Map.put(:status, Map.get(params, "status", entry.metadata.status))
      |> Map.put(:published_at, Map.get(params, "published_at", entry.metadata.published_at))

    new_content = Map.get(params, "content", entry.content)
    new_path = new_path_for(entry, params)
    full_new_path = absolute_path(new_path)

    File.mkdir_p!(Path.dirname(full_new_path))

    metadata_for_file =
      Map.put(new_metadata, :slug, Path.basename(Path.dirname(new_path)))

    serialized =
      Metadata.serialize(metadata_for_file) <> "\n\n" <> String.trim_leading(new_content)

    case File.write(full_new_path, serialized <> "\n") do
      :ok ->
        if full_new_path != entry.full_path do
          File.rm(entry.full_path)
          cleanup_empty_dirs(entry.full_path)
        end

        {date, time} = date_time_from_path!(new_path)
        time_dir = Path.dirname(full_new_path)
        available_languages = detect_available_languages(time_dir)

        {:ok,
         %{
           entry
           | path: new_path,
             full_path: full_new_path,
             metadata: metadata_for_file,
             content: new_content,
             date: date,
             time: time,
             available_languages: available_languages
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the absolute path for a relative publishing path.
  """
  @spec absolute_path(String.t()) :: String.t()
  def absolute_path(relative_path) do
    Path.join(root_path(), String.trim_leading(relative_path, "/"))
  end

  defp relative_path_with_language(type_slug, date, time, language_code) do
    date_part = Date.to_iso8601(date)
    time_part = format_time_folder(time)

    Path.join([type_slug, date_part, time_part, language_filename(language_code)])
  end

  defp new_path_for(entry, params) do
    case Map.get(params, "published_at") do
      nil -> entry.path
      value -> path_for_timestamp(entry.type, value, entry.language)
    end
  end

  defp path_for_timestamp(type_slug, timestamp, language_code) do
    with {:ok, dt, _} <- DateTime.from_iso8601(timestamp) do
      floored = floor_to_minute(dt)

      relative_path_with_language(
        type_slug,
        DateTime.to_date(floored),
        DateTime.to_time(floored),
        language_code
      )
    else
      _ ->
        now = DateTime.utc_now() |> floor_to_minute()

        relative_path_with_language(
          type_slug,
          DateTime.to_date(now),
          DateTime.to_time(now),
          language_code
        )
    end
  end

  defp date_time_from_path(path) do
    [_type, date_part, time_part, _file] = String.split(path, "/", trim: true)

    with {:ok, date} <- Date.from_iso8601(date_part),
         {:ok, time} <- parse_time_folder(time_part) do
      {:ok, {date, time}}
    else
      _ -> {:error, :invalid_path}
    end
  rescue
    _ -> {:error, :invalid_path}
  end

  defp date_time_from_path!(path) do
    case date_time_from_path(path) do
      {:ok, result} -> result
      _ -> raise ArgumentError, "invalid publishing path #{inspect(path)}"
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
end
