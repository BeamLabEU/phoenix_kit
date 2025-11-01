defmodule PhoenixKitWeb.Live.Modules.Blogging do
  @moduledoc """
  Blogging module for managing site blogs and their posts.

  This keeps content in the filesystem while providing an admin-friendly UI
  for creating timestamped markdown blog posts.
  """

  alias PhoenixKitWeb.Live.Modules.Blogging.Storage
  alias PhoenixKit.Settings

  # Delegate language info function to Storage
  defdelegate get_language_info(language_code), to: Storage

  @enabled_key "blogging_enabled"
  @blogs_key "blogging_blogs"
  @legacy_categories_key "blogging_categories"

  @type blog :: map()

  @doc """
  Returns true when the blogging module is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting(@enabled_key, false)

  @doc """
  Enables the blogging module.
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system, do: Settings.update_boolean_setting(@enabled_key, true)

  @doc """
  Disables the blogging module.
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system, do: Settings.update_boolean_setting(@enabled_key, false)

  @doc """
  Returns all configured blogs.
  """
  @spec list_blogs() :: [blog()]
  def list_blogs do
    case Settings.get_json_setting(@blogs_key, nil) do
      %{"blogs" => blogs} when is_list(blogs) ->
        blogs

      list when is_list(list) ->
        list

      _ ->
        legacy =
          case Settings.get_json_setting(@legacy_categories_key, %{"types" => []}) do
            %{"types" => types} when is_list(types) -> types
            other when is_list(other) -> other
            _ -> []
          end

        if legacy != [] do
          Settings.update_json_setting(@blogs_key, %{"blogs" => legacy})
        end

        legacy
    end
  end

  @doc """
  Adds a new blog.
  """
  @spec add_blog(String.t()) :: {:ok, blog()} | {:error, atom()}
  def add_blog(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, :invalid_name}

      true ->
        blogs = list_blogs()
        slug = slugify(trimmed)

        if Enum.any?(blogs, &(&1["slug"] == slug)) do
          {:error, :already_exists}
        else
          blog = %{"name" => trimmed, "slug" => slug}
          updated = blogs ++ [blog]
          payload = %{"blogs" => updated}

          with {:ok, _} <- Settings.update_json_setting(@blogs_key, payload),
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

    Settings.update_json_setting(@blogs_key, %{"blogs" => updated})
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
  Lists blog posts for a given blog slug.
  Accepts optional preferred_language to show titles in user's language.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [Storage.post()]
  def list_posts(blog_slug, preferred_language \\ nil),
    do: Storage.list_posts(blog_slug, preferred_language)

  @doc """
  Creates a new blog post for the given blog using the current timestamp.
  """
  @spec create_post(String.t()) :: {:ok, Storage.post()} | {:error, any()}
  def create_post(blog_slug), do: Storage.create_post(blog_slug)

  @doc """
  Reads an existing blog post.
  """
  @spec read_post(String.t(), String.t()) :: {:ok, Storage.post()} | {:error, any()}
  def read_post(blog_slug, relative_path), do: Storage.read_post(blog_slug, relative_path)

  @doc """
  Updates a blog post and moves the file if the publication timestamp changes.
  """
  @spec update_post(String.t(), Storage.post(), map()) ::
          {:ok, Storage.post()} | {:error, any()}
  def update_post(blog_slug, post, params),
    do: Storage.update_post(blog_slug, post, params)

  @doc """
  Adds a new language file to an existing post.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t()) ::
          {:ok, Storage.post()} | {:error, any()}
  def add_language_to_post(blog_slug, post_path, language_code),
    do: Storage.add_language_to_post(blog_slug, post_path, language_code)

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
end
