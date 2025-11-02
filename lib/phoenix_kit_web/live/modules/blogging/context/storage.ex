defmodule PhoenixKitWeb.Live.Modules.Blogging.Storage do
  @moduledoc """
  Filesystem storage helpers for blogging posts.

  Content is stored under:

      priv/static/blogging/<blog>/<YYYY-MM-DD>/<HH:MM>/<language>.phk

  Where <language> is determined by the site's content language setting.
  Files use the .phk (PhoenixKit) format, which supports XML-style
  component markup for building pages with swappable design variants.
  """

  alias PhoenixKitWeb.Live.Modules.Blogging.Metadata
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
  Gets language details (name, flag) for a given language code.
  """
  @spec get_language_info(String.t()) ::
          %{code: String.t(), name: String.t(), flag: String.t()} | nil
  def get_language_info(language_code) do
    all_languages = Languages.get_available_languages()
    Enum.find(all_languages, fn lang -> lang.code == language_code end)
  end

  @slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @doc """
  Validates whether the given string is a slug.
  """
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    Regex.match?(@slug_pattern, slug)
  end

  @doc """
  Checks if a slug already exists within the given blog.
  """
  @spec slug_exists?(String.t(), String.t()) :: boolean()
  def slug_exists?(blog_slug, post_slug) do
    Path.join([root_path(), blog_slug, post_slug])
    |> File.dir?()
  end

  @doc """
  Generates a unique slug based on title and optional preferred slug.
  """
  @spec generate_unique_slug(String.t(), String.t(), String.t() | nil) :: String.t()
  def generate_unique_slug(blog_slug, title, preferred_slug \\ nil) do
    base_slug =
      case preferred_slug do
        nil ->
          generate_slug_from_title(title)

        slug when is_binary(slug) ->
          sanitized = sanitize_slug(slug)

          cond do
            sanitized == "" ->
              generate_slug_from_title(title)

            valid_slug?(sanitized) ->
              sanitized

            true ->
              generate_slug_from_title(title)
          end
      end

    ensure_unique_slug(blog_slug, base_slug)
  end

  defp generate_slug_from_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> case do
      "" -> fallback_slug()
      slug -> slug
    end
  end

  defp sanitize_slug(slug) do
    slug
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp ensure_unique_slug(blog_slug, base_slug) do
    if slug_exists?(blog_slug, base_slug) do
      find_available_slug(blog_slug, base_slug, 2)
    else
      base_slug
    end
  end

  defp find_available_slug(blog_slug, base_slug, counter) do
    candidate = "#{base_slug}-#{counter}"

    if slug_exists?(blog_slug, candidate) do
      find_available_slug(blog_slug, base_slug, counter + 1)
    else
      candidate
    end
  end

  defp fallback_slug do
    "post-#{System.unique_integer([:positive])}"
  end

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
          mode: :slug | :timestamp | nil
        }

  @doc """
  Returns the blogging root directory, creating it if needed.
  Always uses the parent application's priv directory.
  """
  @spec root_path() :: String.t()
  def root_path do
    parent_app = PhoenixKit.Config.get_parent_app() || :phoenix_kit

    # Get the parent app's priv directory
    # This ensures files are always stored in the parent app, not in PhoenixKit's deps folder
    base_priv = Application.app_dir(parent_app, "priv")
    base = Path.join(base_priv, "static/blogging")

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

          with {:ok, time} <- parse_time_folder(time_folder),
               available_languages <- detect_available_languages(time_path),
               false <- Enum.empty?(available_languages),
               display_language <-
                 select_display_language(available_languages, preferred_language),
               post_path <- Path.join(time_path, language_filename(display_language)),
               {:ok, metadata, content} <-
                 post_path
                 |> File.read!()
                 |> Metadata.parse_with_content() do
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
                mode: :timestamp
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

  defp resolve_language(available_languages, preferred_language) do
    code =
      if preferred_language && preferred_language in available_languages do
        preferred_language
      else
        select_display_language(available_languages, preferred_language)
      end

    {:ok, code}
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
  @spec create_post_slug_mode(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, post()} | {:error, any()}
  def create_post_slug_mode(blog_slug, title \\ nil, preferred_slug \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    post_slug = generate_unique_slug(blog_slug, title || "", preferred_slug)
    primary_language = hd(enabled_language_codes())

    post_dir = Path.join([root_path(), blog_slug, post_slug])
    File.mkdir_p!(post_dir)

    metadata = %{
      slug: post_slug,
      title: title || "",
      status: "draft",
      published_at: DateTime.to_iso8601(now),
      created_at: DateTime.to_iso8601(now)
    }

    content = Metadata.serialize(metadata) <> "\n\n"
    primary_lang_path = Path.join(post_dir, language_filename(primary_language))

    case File.write(primary_lang_path, content) do
      :ok ->
        {:ok,
         %{
           blog: blog_slug,
           slug: post_slug,
           date: nil,
           time: nil,
           path: Path.join([blog_slug, post_slug, language_filename(primary_language)]),
           full_path: primary_lang_path,
           metadata: metadata,
           content: "",
           language: primary_language,
           available_languages: [primary_language],
           mode: :slug
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
    cond do
      not File.dir?(post_path) ->
        []

      true ->
        available_languages = detect_available_languages(post_path)

        if Enum.empty?(available_languages) do
          []
        else
          display_language = select_display_language(available_languages, preferred_language)
          file_path = Path.join(post_path, language_filename(display_language))

          with {:ok, metadata, content} <-
                 file_path
                 |> File.read!()
                 |> Metadata.parse_with_content() do
            [
              %{
                blog: blog_slug,
                slug: post_slug,
                date: nil,
                time: nil,
                path: Path.join([blog_slug, post_slug, language_filename(display_language)]),
                full_path: file_path,
                metadata: metadata,
                content: content,
                language: display_language,
                available_languages: available_languages,
                mode: :slug
              }
            ]
          else
            _ -> []
          end
        end
    end
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
  Reads a slug-mode post, optionally for a specific language.
  """
  @spec read_post_slug_mode(String.t(), String.t(), String.t() | nil) ::
          {:ok, post()} | {:error, any()}
  def read_post_slug_mode(blog_slug, post_slug, language \\ nil) do
    post_dir = Path.join([root_path(), blog_slug, post_slug])

    with true <- File.dir?(post_dir),
         available_languages <- detect_available_languages(post_dir),
         false <- Enum.empty?(available_languages),
         {:ok, language_code} <- resolve_language(available_languages, language),
         file_path <- Path.join(post_dir, language_filename(language_code)),
         true <- File.exists?(file_path),
         {:ok, metadata, content} <-
           File.read!(file_path)
           |> Metadata.parse_with_content() do
      {:ok,
       %{
         blog: blog_slug,
         slug: post_slug,
         date: nil,
         time: nil,
         path: Path.join([blog_slug, post_slug, language_filename(language_code)]),
         full_path: file_path,
         metadata: metadata,
         content: content,
         language: language_code,
         available_languages: available_languages,
         mode: :slug
       }}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates slug-mode posts in-place or moves them when the slug changes.
  """
  @spec update_post_slug_mode(String.t(), post(), map()) :: {:ok, post()} | {:error, any()}
  def update_post_slug_mode(blog_slug, post, params) do
    desired_slug = Map.get(params, "slug", post.slug)

    cond do
      desired_slug == post.slug ->
        update_post_slug_in_place(blog_slug, post, params)

      not valid_slug?(desired_slug) ->
        {:error, :invalid_slug}

      slug_exists?(blog_slug, desired_slug) ->
        {:error, :slug_already_exists}

      true ->
        move_post_to_new_slug(blog_slug, post, desired_slug, params)
    end
  end

  @doc """
  Updates slug-mode posts without moving them (slug unchanged).
  """
  @spec update_post_slug_in_place(String.t(), post(), map()) :: {:ok, post()} | {:error, any()}
  def update_post_slug_in_place(_blog_slug, post, params) do
    metadata =
      post.metadata
      |> Map.put(:title, Map.get(params, "title", post.metadata.title))
      |> Map.put(:status, Map.get(params, "status", post.metadata.status))
      |> Map.put(:published_at, Map.get(params, "published_at", post.metadata.published_at))
      |> Map.put(:created_at, Map.get(post.metadata, :created_at))
      |> Map.put(:slug, post.slug)

    content = Map.get(params, "content", post.content)
    serialized = Metadata.serialize(metadata) <> "\n\n" <> String.trim_leading(content)

    case File.write(post.full_path, serialized <> "\n") do
      :ok ->
        {:ok, %{post | metadata: metadata, content: content}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Moves slug-mode post files to a new slug directory.
  """
  @spec move_post_to_new_slug(String.t(), post(), String.t(), map()) ::
          {:ok, post()} | {:error, any()}
  def move_post_to_new_slug(blog_slug, post, new_slug, params) do
    old_dir = Path.join([root_path(), blog_slug, post.slug])
    new_dir = Path.join([root_path(), blog_slug, new_slug])

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
            updated_metadata =
              base_metadata
              |> Map.put(:title, Map.get(params, "title", metadata.title))
              |> Map.put(:status, Map.get(params, "status", metadata.status))
              |> Map.put(:published_at, Map.get(params, "published_at", metadata.published_at))

            {updated_metadata, Map.get(params, "content", content)}
          else
            {base_metadata, content}
          end

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
  """
  @spec add_language_to_post_slug_mode(String.t(), String.t(), String.t()) ::
          {:ok, post()} | {:error, any()}
  def add_language_to_post_slug_mode(blog_slug, post_slug, language_code) do
    with {:ok, original_post} <- read_post_slug_mode(blog_slug, post_slug),
         post_dir <- Path.dirname(original_post.full_path),
         target_path <- Path.join(post_dir, language_filename(language_code)),
         false <- File.exists?(target_path) do
      metadata =
        original_post.metadata
        |> Map.put(:title, "")

      serialized = Metadata.serialize(metadata) <> "\n\n"

      case File.write(target_path, serialized <> "\n") do
        :ok ->
          read_post_slug_mode(blog_slug, post_slug, language_code)

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
  @spec create_post(String.t()) :: {:ok, post()} | {:error, any()}
  def create_post(blog_slug) do
    now =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> floor_to_minute()

    date = DateTime.to_date(now)
    time = DateTime.to_time(now)
    primary_language = hd(enabled_language_codes())

    # Create directory structure
    slug = blog_slug || "blog"

    time_dir =
      Path.join([root_path(), slug, Date.to_iso8601(date), format_time_folder(time)])

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
        blog_slug_for_path = blog_slug || slug

        primary_path =
          relative_path_with_language(blog_slug_for_path, date, time, primary_language)

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
           mode: :timestamp
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads a post for a specific language.
  """
  @spec read_post(String.t(), String.t()) :: {:ok, post()} | {:error, any()}
  def read_post(blog_slug, relative_path) do
    full_path = absolute_path(relative_path)
    language = extract_language_from_path(relative_path)

    with true <- File.exists?(full_path),
         {:ok, metadata, content} <- File.read!(full_path) |> Metadata.parse_with_content(),
         {:ok, {date, time}} <- date_time_from_path(relative_path),
         time_dir <- Path.dirname(full_path),
         available_languages <- detect_available_languages(time_dir) do
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
         mode: :timestamp
       }}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
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
      # Create new file with same metadata but empty content
      metadata = Map.put(original_post.metadata, :title, "")
      content = Metadata.serialize(metadata) <> "\n\n"

      case File.write(new_file_path, content) do
        :ok ->
          # Return the newly created post
          new_relative_path =
            relative_path_with_language(
              blog_slug,
              original_post.date,
              original_post.time,
              language_code
            )

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
  @spec update_post(String.t(), post(), map()) :: {:ok, post()} | {:error, any()}
  def update_post(_blog_slug, post, params) do
    new_metadata =
      post.metadata
      |> Map.put(:title, Map.get(params, "title", post.metadata.title))
      |> Map.put(:status, Map.get(params, "status", post.metadata.status))
      |> Map.put(:published_at, Map.get(params, "published_at", post.metadata.published_at))

    new_content = Map.get(params, "content", post.content)
    new_path = new_path_for(post, params)
    full_new_path = absolute_path(new_path)

    File.mkdir_p!(Path.dirname(full_new_path))

    metadata_for_file =
      Map.put(new_metadata, :slug, Path.basename(Path.dirname(new_path)))

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

  defp new_path_for(post, params) do
    case Map.get(params, "published_at") do
      nil -> post.path
      value -> path_for_timestamp(post.blog, value, post.language)
    end
  end

  defp path_for_timestamp(blog_slug, timestamp, language_code) do
    with {:ok, dt, _} <- DateTime.from_iso8601(timestamp) do
      floored = floor_to_minute(dt)

      relative_path_with_language(
        blog_slug,
        DateTime.to_date(floored),
        DateTime.to_time(floored),
        language_code
      )
    else
      _ ->
        now = DateTime.utc_now() |> floor_to_minute()

        relative_path_with_language(
          blog_slug,
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
