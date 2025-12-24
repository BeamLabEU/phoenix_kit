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
            # Preload language statuses to avoid re-reading files in the listing
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

  # Load status for all language files in a post directory
  # Returns a map of language_code => status
  defp load_language_statuses(post_dir, available_languages) do
    Enum.reduce(available_languages, %{}, fn lang, acc ->
      lang_path = Path.join(post_dir, language_filename(lang))

      status =
        case File.read(lang_path) do
          {:ok, content} ->
            case Metadata.parse_with_content(content) do
              {:ok, metadata, _content} -> Map.get(metadata, :status)
              _ -> nil
            end

          _ ->
            nil
        end

      Map.put(acc, lang, status)
    end)
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
    primary_language = hd(enabled_language_codes())

    post_dir = Path.join([root_path(), blog_slug, post_slug])
    File.mkdir_p!(post_dir)

    metadata =
      %{
        slug: post_slug,
        title: title || "",
        description: nil,
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        created_at: DateTime.to_iso8601(now)
      }
      |> apply_creation_audit_metadata(audit_meta)

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
    if File.dir?(post_path) do
      available_languages = detect_available_languages(post_path)

      if Enum.empty?(available_languages) do
        []
      else
        display_language = select_display_language(available_languages, preferred_language)
        file_path = Path.join(post_path, language_filename(display_language))

        {:ok, metadata, content} =
          file_path
          |> File.read!()
          |> Metadata.parse_with_content()

        # Preload language statuses to avoid re-reading files in the listing
        language_statuses = load_language_statuses(post_path, available_languages)

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
            language_statuses: language_statuses,
            mode: :slug
          }
        ]
      end
    else
      []
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
      # Preload language statuses to avoid re-reading files in editor/listing
      language_statuses = load_language_statuses(post_dir, available_languages)

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
         language_statuses: language_statuses,
         mode: :slug
       }}
    else
      _ -> {:error, :not_found}
    end
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

  def update_post_slug_in_place(_blog_slug, post, params, audit_meta) do
    audit_meta = Map.new(audit_meta)

    current_title =
      metadata_value(post.metadata, :title) ||
        Metadata.extract_title_from_content(post.content || "")

    featured_image_id = resolve_featured_image_id(params, post.metadata)

    metadata =
      post.metadata
      |> Map.put(:title, Map.get(params, "title", current_title))
      |> Map.put(
        :status,
        Map.get(params, "status", metadata_value(post.metadata, :status, "draft"))
      )
      |> Map.put(
        :published_at,
        Map.get(params, "published_at", metadata_value(post.metadata, :published_at))
      )
      |> Map.put(:featured_image_id, featured_image_id)
      |> Map.put(:created_at, Map.get(post.metadata, :created_at))
      |> Map.put(:slug, post.slug)
      |> apply_update_audit_metadata(audit_meta)

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
      |> apply_creation_audit_metadata(audit_meta)

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
      # Preload language statuses to avoid re-reading files in editor/listing
      language_statuses = load_language_statuses(time_dir, available_languages)

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

  defp new_path_for(post, params) do
    case Map.get(params, "published_at") do
      nil -> post.path
      value -> path_for_timestamp(post.blog, value, post.language)
    end
  end

  defp path_for_timestamp(blog_slug, timestamp, language_code) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} ->
        floored = floor_to_minute(dt)

        relative_path_with_language(
          blog_slug,
          DateTime.to_date(floored),
          DateTime.to_time(floored),
          language_code
        )

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
