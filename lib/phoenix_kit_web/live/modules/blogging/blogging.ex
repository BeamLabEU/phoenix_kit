defmodule PhoenixKitWeb.Live.Modules.Blogging do
  @moduledoc """
  Blogging module for managing site blogs and their posts.

  This keeps content in the filesystem while providing an admin-friendly UI
  for creating timestamped markdown blog posts.
  """

  alias PhoenixKit.Module.Languages
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  # Delegate language info function to Storage
  defdelegate get_language_info(language_code), to: Storage

  @enabled_key "blogging_enabled"
  @blogs_key "blogging_blogs"
  @legacy_categories_key "blogging_categories"
  @default_blog_mode "timestamp"
  @slug_regex ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

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
  @spec add_blog(String.t(), String.t(), String.t() | nil) :: {:ok, blog()} | {:error, atom()}
  def add_blog(name, mode \\ @default_blog_mode, preferred_slug \\ nil) when is_binary(name) do
    trimmed = String.trim(name)
    mode = normalize_mode(mode)

    cond do
      trimmed == "" ->
        {:error, :invalid_name}

      is_nil(mode) ->
        {:error, :invalid_mode}

      true ->
        blogs = list_blogs()

        with {:ok, requested_slug} <- derive_requested_slug(preferred_slug, trimmed) do
          slug = ensure_unique_slug(requested_slug, blogs)

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
  Updates a blog's display name and slug.
  """
  @spec update_blog(String.t(), map() | keyword()) :: {:ok, blog()} | {:error, atom()}
  def update_blog(slug, params) when is_binary(slug) do
    blogs = list_blogs()

    case Enum.find(blogs, &(&1["slug"] == slug)) do
      nil -> {:error, :not_found}
      blog -> process_blog_update(blog, blogs, params)
    end
  end

  defp process_blog_update(blog, blogs, params) do
    with {:ok, name} <- extract_and_validate_name(blog, params),
         {:ok, sanitized_slug} <- extract_and_validate_slug(blog, params, name),
         :ok <- check_slug_uniqueness(blog, blogs, sanitized_slug) do
      apply_blog_update(blog, blogs, name, sanitized_slug)
    end
  end

  defp extract_and_validate_name(blog, params) do
    name =
      params
      |> fetch_option(:name)
      |> case do
        nil -> blog["name"]
        value -> String.trim(to_string(value || ""))
      end

    if name == "", do: {:error, :invalid_name}, else: {:ok, name}
  end

  defp extract_and_validate_slug(blog, params, name) do
    desired_slug =
      params
      |> fetch_option(:slug)
      |> case do
        nil -> blog["slug"]
        value -> String.trim(to_string(value || ""))
      end

    # If slug is empty, auto-generate from name; otherwise validate as-is
    cond do
      desired_slug == "" ->
        auto_slug = slugify(name)
        if valid_slug?(auto_slug), do: {:ok, auto_slug}, else: {:error, :invalid_slug}

      valid_slug?(desired_slug) ->
        {:ok, desired_slug}

      true ->
        {:error, :invalid_slug}
    end
  end

  defp check_slug_uniqueness(blog, blogs, sanitized_slug) do
    if sanitized_slug != blog["slug"] and Enum.any?(blogs, &(&1["slug"] == sanitized_slug)) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp apply_blog_update(blog, blogs, name, sanitized_slug) do
    updated_blog =
      blog
      |> Map.put("name", name)
      |> Map.put("slug", sanitized_slug)

    with :ok <- Storage.rename_blog_directory(blog["slug"], sanitized_slug),
         {:ok, _} <- persist_blog_update(blogs, blog["slug"], updated_blog) do
      {:ok, updated_blog}
    end
  end

  @doc """
  Moves a blog to trash by renaming its directory with timestamp.
  The blog is removed from the active blogs list and its directory is renamed to:
  BLOGNAME-YYYY-MM-DD-HH-MM-SS
  """
  @spec trash_blog(String.t()) :: {:ok, String.t()} | {:error, any()}
  def trash_blog(slug) when is_binary(slug) do
    with {:ok, _} <- remove_blog(slug) do
      Storage.move_blog_to_trash(slug)
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
    scope = fetch_option(opts, :scope)
    audit_meta = audit_metadata(scope, :create)

    case get_blog_mode(blog_slug) do
      "slug" ->
        title = fetch_option(opts, :title)
        slug = fetch_option(opts, :slug)
        Storage.create_post_slug_mode(blog_slug, title, slug, audit_meta)

      _ ->
        Storage.create_post(blog_slug, audit_meta)
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
  @spec update_post(String.t(), Storage.post(), map(), map() | keyword()) ::
          {:ok, Storage.post()} | {:error, any()}
  def update_post(blog_slug, post, params, opts \\ %{}) do
    audit_meta =
      opts
      |> fetch_option(:scope)
      |> audit_metadata(:update)

    mode =
      Map.get(post, :mode) ||
        Map.get(post, "mode") ||
        mode_atom(get_blog_mode(blog_slug))

    case mode do
      :slug -> Storage.update_post_slug_mode(blog_slug, post, params, audit_meta)
      _ -> Storage.update_post(blog_slug, post, params, audit_meta)
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
  Returns empty string if the name contains only invalid characters.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc """
  Returns true when the slug matches the allowed lowercase letters, numbers, and hyphen pattern,
  and is not a reserved language code.

  Blog slugs cannot be language codes (like 'en', 'es', 'fr') to prevent routing ambiguity.
  """
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    slug != "" and Regex.match?(@slug_regex, slug) and not reserved_language_code?(slug)
  end

  def valid_slug?(_), do: false

  # Check if slug is a reserved language code
  # We check against all available language codes from the language system
  defp reserved_language_code?(slug) do
    # Get all available language codes dynamically from the language module
    language_codes =
      try do
        Languages.get_language_codes()
      rescue
        _ -> []
      end

    slug in language_codes
  end

  defp settings_module do
    Application.get_env(:phoenix_kit, :blogging_settings_module, PhoenixKit.Settings)
  end

  defp settings_call(fun, args) do
    apply(settings_module(), fun, args)
  end

  defp normalize_blogs(blogs) do
    blogs
    |> Enum.map(&normalize_blog_keys/1)
    |> Enum.map(fn
      %{"mode" => mode} = blog when mode in ["timestamp", "slug"] ->
        blog

      blog ->
        Map.put(blog, "mode", @default_blog_mode)
    end)
  end

  defp normalize_blog_keys(blog) when is_map(blog) do
    Enum.reduce(blog, %{}, fn
      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_blog_keys(other), do: other

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

  defp audit_metadata(nil, _action), do: %{}

  defp audit_metadata(scope, action) do
    user_id =
      scope
      |> Scope.user_id()
      |> normalize_audit_value()

    user_email =
      scope
      |> Scope.user_email()
      |> normalize_audit_value()

    base =
      case action do
        :create ->
          %{
            created_by_id: user_id,
            created_by_email: user_email
          }

        _ ->
          %{}
      end

    base
    |> maybe_put_audit(:updated_by_id, user_id)
    |> maybe_put_audit(:updated_by_email, user_email)
  end

  defp normalize_audit_value(nil), do: nil
  defp normalize_audit_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_audit_value(value), do: to_string(value)

  defp maybe_put_audit(map, _key, nil), do: map
  defp maybe_put_audit(map, key, value), do: Map.put(map, key, value)

  defp persist_blog_update(blogs, slug, updated_blog) do
    updated =
      Enum.map(blogs, fn
        %{"slug" => ^slug} -> updated_blog
        other -> other
      end)

    settings_call(:update_json_setting, [@blogs_key, %{"blogs" => updated}])
  end

  defp derive_requested_slug(nil, fallback_name) do
    slugified = slugify(fallback_name)
    if slugified == "", do: {:error, :invalid_slug}, else: {:ok, slugified}
  end

  defp derive_requested_slug(slug, fallback_name) when is_binary(slug) do
    trimmed = slug |> String.trim()

    cond do
      trimmed == "" ->
        slugified = slugify(fallback_name)
        if slugified == "", do: {:error, :invalid_slug}, else: {:ok, slugified}

      valid_slug?(trimmed) ->
        {:ok, trimmed}

      true ->
        {:error, :invalid_slug}
    end
  end

  defp derive_requested_slug(_other, fallback_name) do
    slugified = slugify(fallback_name)
    if slugified == "", do: {:error, :invalid_slug}, else: {:ok, slugified}
  end

  defp ensure_unique_slug(slug, blogs), do: ensure_unique_slug(slug, blogs, 2)

  defp ensure_unique_slug(slug, blogs, counter) do
    if Enum.any?(blogs, &(&1["slug"] == slug)) do
      ensure_unique_slug("#{slug}-#{counter}", blogs, counter + 1)
    else
      slug
    end
  end

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

  # Only drop blog prefix if there are more elements after it
  # This prevents dropping the post slug when it matches the blog slug
  defp drop_blog_prefix([blog_slug | rest], blog_slug) when rest != [], do: rest
  defp drop_blog_prefix(list, _), do: list
end
