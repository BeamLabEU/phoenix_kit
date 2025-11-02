defmodule PhoenixKitWeb.Live.Modules.Blogging do
  @moduledoc """
  Blogging module for managing site blogs and their posts.

  This keeps content in the filesystem while providing an admin-friendly UI
  for creating timestamped markdown blog posts.
  """

  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  # Delegate language info function to Storage
  defdelegate get_language_info(language_code), to: Storage

  @enabled_key "blogging_enabled"
  @blogs_key "blogging_blogs"
  @legacy_categories_key "blogging_categories"
  @default_blog_mode "timestamp"

  @type blog :: map()

  @doc """
  Returns true when the blogging module is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    settings_call(:get_boolean_setting, [@enabled_key, false])
  end

  @doc """
  Enables the blogging module.
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    settings_call(:update_boolean_setting, [@enabled_key, true])
  end

  @doc """
  Disables the blogging module.
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    settings_call(:update_boolean_setting, [@enabled_key, false])
  end

  @doc """
  Returns all configured blogs.
  """
  @spec list_blogs() :: [blog()]
  def list_blogs do
    case settings_call(:get_json_setting, [@blogs_key, nil]) do
      %{"blogs" => blogs} when is_list(blogs) ->
        normalize_blogs(blogs)

      list when is_list(list) ->
        normalize_blogs(list)

      _ ->
        legacy =
          case settings_call(:get_json_setting, [@legacy_categories_key, %{"types" => []}]) do
            %{"types" => types} when is_list(types) -> types
            other when is_list(other) -> other
            _ -> []
          end

        if legacy != [] do
          settings_call(:update_json_setting, [@blogs_key, %{"blogs" => legacy}])
        end

        normalize_blogs(legacy)
    end
  end

  @doc """
  Adds a new blog.
  """
  @spec add_blog(String.t(), String.t()) :: {:ok, blog()} | {:error, atom()}
  def add_blog(name, mode \\ @default_blog_mode) when is_binary(name) do
    trimmed = String.trim(name)
    mode = normalize_mode(mode)

    cond do
      trimmed == "" ->
        {:error, :invalid_name}

      is_nil(mode) ->
        {:error, :invalid_mode}

      true ->
        blogs = list_blogs()
        slug = slugify(trimmed)

        if Enum.any?(blogs, &(&1["slug"] == slug)) do
          {:error, :already_exists}
        else
          blog = %{"name" => trimmed, "slug" => slug, "mode" => mode}
          updated = blogs ++ [blog]
          payload = %{"blogs" => updated}

          with {:ok, _} <- settings_call(:update_json_setting, [@blogs_key, payload]),
               :ok <- Storage.ensure_blog_root(slug) do
            {:ok, blog}
          end
        end
    end
  end

  @doc """
  Removes a blog by slug.
  """
  @spec remove_blog(String.t()) :: {:ok, any()} | {:error, any()}
  def remove_blog(slug) when is_binary(slug) do
    updated =
      list_blogs()
      |> Enum.reject(&(&1["slug"] == slug))

    settings_call(:update_json_setting, [@blogs_key, %{"blogs" => updated}])
  end

  @doc """
  Moves a blog to trash by renaming its directory with timestamp.
  The blog is removed from the active blogs list and its directory is renamed to:
  BLOGNAME-YYYY-MM-DD-HH-MM-SS
  """
  @spec trash_blog(String.t()) :: {:ok, String.t()} | {:error, any()}
  def trash_blog(slug) when is_binary(slug) do
    with {:ok, _} <- remove_blog(slug),
         {:ok, trashed_name} <- Storage.move_blog_to_trash(slug) do
      {:ok, trashed_name}
    end
  end

  @doc """
  Looks up a blog name from its slug.
  """
  @spec blog_name(String.t()) :: String.t() | nil
  def blog_name(slug) do
    Enum.find_value(list_blogs(), fn blog ->
      if blog["slug"] == slug, do: blog["name"]
    end)
  end

  @doc """
  Returns the configured storage mode for a blog slug.
  """
  @spec get_blog_mode(String.t()) :: String.t()
  def get_blog_mode(blog_slug) do
    list_blogs()
    |> Enum.find(%{}, &(&1["slug"] == blog_slug))
    |> Map.get("mode", @default_blog_mode)
  end

  @doc """
  Lists blog posts for a given blog slug.
  Accepts optional preferred_language to show titles in user's language.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [Storage.post()]
  def list_posts(blog_slug, preferred_language \\ nil) do
    case get_blog_mode(blog_slug) do
      "slug" -> Storage.list_posts_slug_mode(blog_slug, preferred_language)
      _ -> Storage.list_posts(blog_slug, preferred_language)
    end
  end

  @doc """
  Creates a new blog post for the given blog using the current timestamp.
  """
  @spec create_post(String.t(), map() | keyword()) :: {:ok, Storage.post()} | {:error, any()}
  def create_post(blog_slug, opts \\ %{}) do
    case get_blog_mode(blog_slug) do
      "slug" ->
        title = fetch_option(opts, :title)
        slug = fetch_option(opts, :slug)
        Storage.create_post_slug_mode(blog_slug, title, slug)

      _ ->
        Storage.create_post(blog_slug)
    end
  end

  @doc """
  Reads an existing blog post.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil) ::
          {:ok, Storage.post()} | {:error, any()}
  def read_post(blog_slug, identifier, language \\ nil) do
    case get_blog_mode(blog_slug) do
      "slug" ->
        {post_slug, inferred_language} = extract_slug_and_language(blog_slug, identifier)
        Storage.read_post_slug_mode(blog_slug, post_slug, language || inferred_language)

      _ ->
        Storage.read_post(blog_slug, identifier)
    end
  end

  @doc """
  Updates a blog post and moves the file if the publication timestamp changes.
  """
  @spec update_post(String.t(), Storage.post(), map()) ::
          {:ok, Storage.post()} | {:error, any()}
  def update_post(blog_slug, post, params) do
    mode =
      Map.get(post, :mode) ||
        Map.get(post, "mode") ||
        mode_atom(get_blog_mode(blog_slug))

    case mode do
      :slug -> Storage.update_post_slug_mode(blog_slug, post, params)
      _ -> Storage.update_post(blog_slug, post, params)
    end
  end

  @doc """
  Adds a new language file to an existing post.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t()) ::
          {:ok, Storage.post()} | {:error, any()}
  def add_language_to_post(blog_slug, identifier, language_code) do
    case get_blog_mode(blog_slug) do
      "slug" ->
        {post_slug, _} = extract_slug_and_language(blog_slug, identifier)
        Storage.add_language_to_post_slug_mode(blog_slug, post_slug, language_code)

      _ ->
        Storage.add_language_to_post(blog_slug, identifier, language_code)
    end
  end

  # Legacy wrappers (deprecated)
  def list_entries(blog_slug, preferred_language \\ nil),
    do: list_posts(blog_slug, preferred_language)

  def create_entry(blog_slug), do: create_post(blog_slug)

  def read_entry(blog_slug, relative_path), do: read_post(blog_slug, relative_path)

  def update_entry(blog_slug, post, params), do: update_post(blog_slug, post, params)

  def add_language_to_entry(blog_slug, post_path, language_code),
    do: add_language_to_post(blog_slug, post_path, language_code)

  @doc """
  Generates a slug from a user-provided blog name.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "blog"
      slug -> slug
    end
  end

  defp settings_module do
    Application.get_env(:phoenix_kit, :blogging_settings_module, PhoenixKit.Settings)
  end

  defp settings_call(fun, args) do
    apply(settings_module(), fun, args)
  end

  defp normalize_blogs(blogs) do
    Enum.map(blogs, fn
      %{"mode" => mode} = blog when mode in ["timestamp", "slug"] ->
        blog

      blog ->
        Map.put(blog, "mode", @default_blog_mode)
    end)
  end

  defp normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.downcase()
    |> case do
      "slug" -> "slug"
      "timestamp" -> "timestamp"
      _ -> nil
    end
  end

  defp normalize_mode(mode) when is_atom(mode), do: normalize_mode(Atom.to_string(mode))
  defp normalize_mode(_), do: nil

  defp fetch_option(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp fetch_option(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Keyword.get(opts, key)
    else
      nil
    end
  end

  defp fetch_option(_, _), do: nil

  defp mode_atom("slug"), do: :slug
  defp mode_atom(_), do: :timestamp

  defp extract_slug_and_language(_blog_slug, nil), do: {"", nil}

  defp extract_slug_and_language(blog_slug, identifier) do
    identifier
    |> to_string()
    |> String.trim()
    |> String.trim_leading("/")
    |> String.split("/", trim: true)
    |> drop_blog_prefix(blog_slug)
    |> case do
      [] ->
        {"", nil}

      [slug] ->
        {slug, nil}

      [slug | rest] ->
        language =
          rest
          |> List.first()
          |> case do
            nil -> nil
            <<>> -> nil
            lang_file -> String.replace_suffix(lang_file, ".phk", "")
          end

        {slug, language}
    end
  end

  defp drop_blog_prefix([blog_slug | rest], blog_slug), do: rest
  defp drop_blog_prefix(list, _), do: list
end
