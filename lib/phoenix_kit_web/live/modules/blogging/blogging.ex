defmodule PhoenixKitWeb.Live.Modules.Blogging do
  @moduledoc """
  Blogging module for managing site blogs and their posts.

  This keeps content in the filesystem while providing an admin-friendly UI
  for creating timestamped markdown blog posts.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Live.Modules.Blogging.ListingCache
  alias PhoenixKitWeb.Live.Modules.Blogging.PubSub, as: BloggingPubSub
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  # Suppress dialyzer false positives for pattern matches
  @dialyzer :no_match
  @dialyzer {:nowarn_function, create_post: 2}
  @dialyzer {:nowarn_function, add_language_to_post: 4}
  @dialyzer {:nowarn_function, parse_version_directory: 1}

  # Delegate language info function to Storage
  defdelegate get_language_info(language_code), to: Storage

  # Delegate version functions to Storage
  defdelegate list_versions(blog_slug, post_slug), to: Storage
  defdelegate get_latest_version(blog_slug, post_slug), to: Storage
  defdelegate get_latest_published_version(blog_slug, post_slug), to: Storage
  defdelegate get_live_version(blog_slug, post_slug), to: Storage
  defdelegate get_version_status(blog_slug, post_slug, version, language), to: Storage
  defdelegate detect_post_structure(post_path), to: Storage
  defdelegate content_changed?(post, params), to: Storage
  defdelegate status_change_only?(post, params), to: Storage
  defdelegate should_create_new_version?(post, params, editing_language), to: Storage

  # Delegate slug utilities to Storage
  defdelegate validate_slug(slug), to: Storage
  defdelegate slug_exists?(blog_slug, post_slug), to: Storage
  defdelegate generate_unique_slug(blog_slug, title), to: Storage
  defdelegate generate_unique_slug(blog_slug, title, preferred_slug), to: Storage
  defdelegate generate_unique_slug(blog_slug, title, preferred_slug, opts), to: Storage

  # Delegate language utilities to Storage
  defdelegate enabled_language_codes(), to: Storage
  defdelegate get_master_language(), to: Storage
  defdelegate language_enabled?(language_code, enabled_languages), to: Storage
  defdelegate get_display_code(language_code, enabled_languages), to: Storage
  defdelegate order_languages_for_display(available_languages, enabled_languages), to: Storage

  # Delegate version metadata to Storage
  defdelegate get_version_metadata(blog_slug, post_slug, version, language), to: Storage
  defdelegate migrate_post_to_versioned(post), to: Storage
  defdelegate migrate_post_to_versioned(post, language), to: Storage

  # Delegate cache operations to ListingCache
  defdelegate regenerate_cache(blog_slug), to: ListingCache, as: :regenerate
  defdelegate invalidate_cache(blog_slug), to: ListingCache, as: :invalidate
  defdelegate cache_exists?(blog_slug), to: ListingCache, as: :exists?
  defdelegate find_cached_post(blog_slug, post_slug), to: ListingCache, as: :find_post

  defdelegate find_cached_post_by_path(blog_slug, date, time),
    to: ListingCache,
    as: :find_post_by_path

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
    case settings_call(:get_json_setting_cached, [@blogs_key, nil]) do
      %{"blogs" => blogs} when is_list(blogs) ->
        normalize_blogs(blogs)

      list when is_list(list) ->
        normalize_blogs(list)

      _ ->
        legacy =
          case settings_call(:get_json_setting_cached, [@legacy_categories_key, %{"types" => []}]) do
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
  Gets a blog by slug.

  ## Examples

      iex> Blogging.get_blog("news")
      {:ok, %{"name" => "News", "slug" => "news", ...}}

      iex> Blogging.get_blog("nonexistent")
      {:error, :not_found}
  """
  @spec get_blog(String.t()) :: {:ok, blog()} | {:error, :not_found}
  def get_blog(slug) when is_binary(slug) do
    case Enum.find(list_blogs(), &(&1["slug"] == slug)) do
      nil -> {:error, :not_found}
      blog -> {:ok, blog}
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

        with {:ok, requested_slug} <- derive_requested_slug(preferred_slug, trimmed),
             :ok <- check_slug_availability(requested_slug, blogs, preferred_slug) do
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

    result =
      case get_blog_mode(blog_slug) do
        "slug" ->
          title = fetch_option(opts, :title)
          slug = fetch_option(opts, :slug)
          Storage.create_post_slug_mode(blog_slug, title, slug, audit_meta)

        _ ->
          Storage.create_post(blog_slug, audit_meta)
      end

    # Regenerate listing cache and broadcast on success
    with {:ok, post} <- result do
      ListingCache.regenerate(blog_slug)
      BloggingPubSub.broadcast_post_created(blog_slug, post)
    end

    result
  end

  @doc """
  Reads an existing blog post.

  For slug-mode blogs, accepts an optional version parameter.
  If version is nil, reads the latest version.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, Storage.post()} | {:error, any()}
  def read_post(blog_slug, identifier, language \\ nil, version \\ nil) do
    case get_blog_mode(blog_slug) do
      "slug" ->
        {post_slug, inferred_version, inferred_language} =
          extract_slug_version_and_language(blog_slug, identifier)

        # Use explicit parameters if provided, otherwise use inferred values from path
        final_language = language || inferred_language
        final_version = version || inferred_version

        Storage.read_post_slug_mode(blog_slug, post_slug, final_language, final_version)

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

    result =
      case mode do
        :slug -> Storage.update_post_slug_mode(blog_slug, post, params, audit_meta)
        _ -> Storage.update_post(blog_slug, post, params, audit_meta)
      end

    # Regenerate listing cache on success, but only if the post is live
    # (For versioned posts, non-live versions don't affect public listings)
    # Always broadcast so all viewers of any version see updates
    with {:ok, updated_post} <- result do
      if should_regenerate_cache?(updated_post) do
        ListingCache.regenerate(blog_slug)
      end

      BloggingPubSub.broadcast_post_updated(blog_slug, updated_post)
    end

    result
  end

  @doc """
  Creates a new version of a slug-mode post by copying from the source version.

  The new version starts as draft with is_live: false.
  Content and metadata updates from params are applied to the new version.
  """
  @spec create_new_version(String.t(), Storage.post(), map(), map() | keyword()) ::
          {:ok, Storage.post()} | {:error, any()}
  def create_new_version(blog_slug, source_post, params \\ %{}, opts \\ %{}) do
    audit_meta =
      opts
      |> fetch_option(:scope)
      |> audit_metadata(:create)

    result = Storage.create_new_version(blog_slug, source_post, params, audit_meta)

    # Note: New versions start as drafts (is_live: false), so we don't
    # regenerate the cache here. Cache will be regenerated when the
    # version is set live or published.
    # Always broadcast so all viewers see the new version exists
    with {:ok, new_version} <- result do
      BloggingPubSub.broadcast_version_created(blog_slug, new_version)
    end

    result
  end

  @doc """
  Sets a version as the live version for a post.
  Clears is_live from all other versions.
  """
  @spec set_version_live(String.t(), String.t(), integer()) :: :ok | {:error, any()}
  def set_version_live(blog_slug, post_slug, version) do
    result = Storage.set_version_live(blog_slug, post_slug, version)

    # Regenerate listing cache and broadcast on success
    if result == :ok do
      ListingCache.regenerate(blog_slug)
      BloggingPubSub.broadcast_version_live_changed(blog_slug, post_slug, version)
    end

    result
  end

  @doc """
  Adds a new language file to an existing post.

  For slug-mode blogs, accepts an optional version parameter to specify which
  version to add the translation to. If not specified, uses the version from
  the identifier path (if present) or defaults to the latest version.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, Storage.post()} | {:error, any()}
  def add_language_to_post(blog_slug, identifier, language_code, version \\ nil) do
    result =
      case get_blog_mode(blog_slug) do
        "slug" ->
          {post_slug, inferred_version, _language} =
            extract_slug_version_and_language(blog_slug, identifier)

          # Use explicit version if provided, otherwise use version from path
          target_version = version || inferred_version

          Storage.add_language_to_post_slug_mode(
            blog_slug,
            post_slug,
            language_code,
            target_version
          )

        _ ->
          Storage.add_language_to_post(blog_slug, identifier, language_code)
      end

    # Regenerate listing cache on success, but only if the post is live
    # Always broadcast so all viewers see the new translation
    with {:ok, new_post} <- result do
      if should_regenerate_cache?(new_post) do
        ListingCache.regenerate(blog_slug)
      end

      # Broadcast translation created
      if new_post.slug do
        BloggingPubSub.broadcast_translation_created(blog_slug, new_post.slug, language_code)
      end
    end

    result
  end

  @doc """
  Moves a post to the trash folder.

  For slug-mode blogs, provide the post slug.
  For timestamp-mode blogs, provide the date/time path (e.g., "2025-01-15/14:30").

  Returns {:ok, trash_path} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_post(blog_slug, post_identifier) do
    result = Storage.trash_post(blog_slug, post_identifier)

    with {:ok, _trash_path} <- result do
      ListingCache.regenerate(blog_slug)
      BloggingPubSub.broadcast_post_deleted(blog_slug, post_identifier)
    end

    result
  end

  @doc """
  Deletes a specific language translation from a post.

  For versioned posts, specify the version. For legacy posts, version is ignored.
  Refuses to delete the last remaining language file.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_language(String.t(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, term()}
  def delete_language(blog_slug, post_identifier, language_code, version \\ nil) do
    result = Storage.delete_language(blog_slug, post_identifier, language_code, version)

    if result == :ok do
      ListingCache.regenerate(blog_slug)
      BloggingPubSub.broadcast_translation_deleted(blog_slug, post_identifier, language_code)
    end

    result
  end

  @doc """
  Deletes an entire version of a post.

  Moves the version folder to trash instead of permanent deletion.
  Refuses to delete the last remaining version or the live version.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_version(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def delete_version(blog_slug, post_identifier, version) do
    result = Storage.delete_version(blog_slug, post_identifier, version)

    if result == :ok do
      # Only regenerate cache if deleting affected the live version
      # (but we already prevent deleting live version, so this is just for safety)
      ListingCache.regenerate(blog_slug)
      BloggingPubSub.broadcast_version_deleted(blog_slug, post_identifier, version)
    end

    result
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

  # Determines if a post update should trigger cache regeneration.
  # For versioned posts (slug mode with version info), only regenerate if the post is live.
  # For non-versioned posts (timestamp mode or legacy), always regenerate.
  defp should_regenerate_cache?(post) do
    mode = Map.get(post, :mode)
    metadata = Map.get(post, :metadata, %{})
    is_live = Map.get(metadata, :is_live)
    version = Map.get(metadata, :version) || Map.get(post, :version)

    cond do
      # Timestamp mode posts always regenerate (no versioning)
      mode == :timestamp -> true
      # Slug mode posts without version info (legacy) always regenerate
      is_nil(version) -> true
      # Slug mode posts: only regenerate if this is the live version
      is_live == true -> true
      # Non-live versioned posts don't affect public listings
      true -> false
    end
  end

  defp settings_module do
    PhoenixKit.Config.get(:blogging_settings_module, PhoenixKit.Settings)
  end

  defp settings_call(fun, args) do
    module = settings_module()

    # For cached functions, fall back to uncached if custom module doesn't implement them
    case fun do
      :get_json_setting_cached ->
        if function_exported?(module, :get_json_setting_cached, length(args)) do
          apply(module, :get_json_setting_cached, args)
        else
          apply(module, :get_json_setting, args)
        end

      _ ->
        apply(module, fun, args)
    end
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

  # Check if explicit slug already exists (only when preferred_slug is provided)
  defp check_slug_availability(slug, blogs, preferred_slug) when not is_nil(preferred_slug) do
    if Enum.any?(blogs, &(&1["slug"] == slug)) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp check_slug_availability(_slug, _blogs, nil), do: :ok

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

  # Extract slug, version, and language from a path identifier
  # Handles paths like:
  #   - "post-slug" → {"post-slug", nil, nil}
  #   - "post-slug/en.phk" → {"post-slug", nil, "en"}
  #   - "post-slug/v1/en.phk" → {"post-slug", 1, "en"}
  #   - "blog/post-slug/v2/am.phk" → {"post-slug", 2, "am"}
  defp extract_slug_version_and_language(_blog_slug, nil), do: {"", nil, nil}

  defp extract_slug_version_and_language(blog_slug, identifier) do
    parts =
      identifier
      |> to_string()
      |> String.trim()
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> drop_blog_prefix(blog_slug)

    case parts do
      [] ->
        {"", nil, nil}

      [slug] ->
        {slug, nil, nil}

      [slug | rest] ->
        # Extract version if present (v1, v2, v3, etc.)
        {version, rest_after_version} = extract_version_from_parts(rest)

        # Extract language from remaining parts
        language =
          rest_after_version
          |> List.first()
          |> case do
            nil -> nil
            <<>> -> nil
            lang_file -> String.replace_suffix(lang_file, ".phk", "")
          end

        {slug, version, language}
    end
  end

  # Extract version number from path parts if present
  # Returns {version_integer | nil, remaining_parts}
  defp extract_version_from_parts([]), do: {nil, []}

  defp extract_version_from_parts([first | rest] = parts) do
    case parse_version_directory(first) do
      {:ok, version} -> {version, rest}
      :error -> {nil, parts}
    end
  end

  # Parse a version directory like "v1", "v2", etc. to an integer
  defp parse_version_directory(segment) when is_binary(segment) do
    case Regex.run(~r/^v(\d+)$/, segment) do
      [_, num_str] -> {:ok, String.to_integer(num_str)}
      nil -> :error
    end
  end

  defp parse_version_directory(_), do: :error

  # Only drop blog prefix if there are more elements after it
  # This prevents dropping the post slug when it matches the blog slug
  defp drop_blog_prefix([blog_slug | rest], blog_slug) when rest != [], do: rest
  defp drop_blog_prefix(list, _), do: list
end
