defmodule PhoenixKit.Modules.Publishing do
  @moduledoc """
  Publishing module for managing content groups and their posts.

  This keeps content in the filesystem while providing an admin-friendly UI
  for creating timestamped or slug-based markdown posts with multi-language support.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Users.Auth.Scope

  # Suppress dialyzer false positives for pattern matches
  @dialyzer :no_match
  @dialyzer {:nowarn_function, create_post: 2}
  @dialyzer {:nowarn_function, add_language_to_post: 4}
  @dialyzer {:nowarn_function, parse_version_directory: 1}

  # Delegate language info function to Storage
  defdelegate get_language_info(language_code), to: Storage

  # Delegate version functions to Storage
  defdelegate list_versions(group_slug, post_slug), to: Storage
  defdelegate get_latest_version(group_slug, post_slug), to: Storage
  defdelegate get_latest_published_version(group_slug, post_slug), to: Storage
  defdelegate get_published_version(group_slug, post_slug), to: Storage
  defdelegate get_version_status(group_slug, post_slug, version, language), to: Storage

  # Deprecated: Use get_published_version/2 instead
  @doc false
  @deprecated "Use get_published_version/2 instead"
  def get_live_version(group_slug, post_slug),
    do: Storage.get_published_version(group_slug, post_slug)

  defdelegate detect_post_structure(post_path), to: Storage
  defdelegate content_changed?(post, params), to: Storage
  defdelegate status_change_only?(post, params), to: Storage
  defdelegate should_create_new_version?(post, params, editing_language), to: Storage

  # Delegate slug utilities to Storage
  defdelegate validate_slug(slug), to: Storage
  defdelegate slug_exists?(group_slug, post_slug), to: Storage
  defdelegate generate_unique_slug(group_slug, title), to: Storage
  defdelegate generate_unique_slug(group_slug, title, preferred_slug), to: Storage
  defdelegate generate_unique_slug(group_slug, title, preferred_slug, opts), to: Storage

  # Delegate language utilities to Storage
  defdelegate enabled_language_codes(), to: Storage
  defdelegate get_primary_language(), to: Storage

  @doc false
  @deprecated "Use get_primary_language/0 instead"
  defdelegate get_master_language(), to: Storage

  defdelegate language_enabled?(language_code, enabled_languages), to: Storage
  defdelegate get_display_code(language_code, enabled_languages), to: Storage
  defdelegate order_languages_for_display(available_languages, enabled_languages), to: Storage

  # Delegate version metadata to Storage
  defdelegate get_version_metadata(group_slug, post_slug, version, language), to: Storage
  defdelegate migrate_post_to_versioned(post), to: Storage
  defdelegate migrate_post_to_versioned(post, language), to: Storage

  # Delegate cache operations to ListingCache
  defdelegate regenerate_cache(group_slug), to: ListingCache, as: :regenerate
  defdelegate invalidate_cache(group_slug), to: ListingCache, as: :invalidate
  defdelegate cache_exists?(group_slug), to: ListingCache, as: :exists?
  defdelegate find_cached_post(group_slug, post_slug), to: ListingCache, as: :find_post

  defdelegate find_cached_post_by_path(group_slug, date, time),
    to: ListingCache,
    as: :find_post_by_path

  # Delegate storage path functions
  defdelegate legacy_group?(group_slug), to: Storage
  defdelegate migrate_group(group_slug), to: Storage
  defdelegate has_legacy_groups?(), to: Storage

  # New settings keys (write to these)
  @publishing_enabled_key "publishing_enabled"
  @publishing_groups_key "publishing_groups"

  # Legacy settings keys (read from these as fallback)
  @legacy_enabled_key "blogging_enabled"
  @legacy_blogs_key "blogging_blogs"
  @legacy_categories_key "blogging_categories"

  @default_group_mode "timestamp"
  @default_group_type "blogging"
  @preset_types ["blogging", "faq", "legal"]
  @slug_regex ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @type_regex ~r/^[a-z][a-z0-9-]{0,31}$/

  # Default item names for preset types (singular, plural)
  # Note: "blogging" type value kept for backward compatibility
  @type_item_names %{
    "blogging" => {"post", "posts"},
    "faq" => {"question", "questions"},
    "legal" => {"document", "documents"}
  }
  @default_item_singular "item"
  @default_item_plural "items"

  @type group :: map()

  @doc """
  Returns true when the publishing module is enabled.
  Checks new key first, falls back to legacy key.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    # Check new key first using get_setting (allows nil default)
    case settings_call(:get_setting, [@publishing_enabled_key, nil]) do
      nil ->
        # Fall back to legacy key
        settings_call(:get_boolean_setting, [@legacy_enabled_key, false])

      "true" ->
        true

      true ->
        true

      _ ->
        false
    end
  end

  @doc """
  Enables the publishing module.
  Always writes to the new key.
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    settings_call(:update_boolean_setting, [@publishing_enabled_key, true])
  end

  @doc """
  Disables the publishing module.
  Always writes to the new key.
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    settings_call(:update_boolean_setting, [@publishing_enabled_key, false])
  end

  @doc """
  Returns all configured publishing groups.
  Checks new key first, falls back to legacy keys.
  """
  @spec list_groups() :: [group()]
  def list_groups do
    # Try new key first
    case settings_call(:get_json_setting_cached, [@publishing_groups_key, nil]) do
      %{"publishing_groups" => groups} when is_list(groups) ->
        normalize_groups(groups)

      %{"blogs" => groups} when is_list(groups) ->
        # Handle if someone wrote with old structure to new key
        normalize_groups(groups)

      list when is_list(list) ->
        normalize_groups(list)

      _ ->
        # Fall back to legacy blogging_blogs key
        case settings_call(:get_json_setting_cached, [@legacy_blogs_key, nil]) do
          %{"blogs" => groups} when is_list(groups) ->
            normalize_groups(groups)

          list when is_list(list) ->
            normalize_groups(list)

          _ ->
            # Fall back to oldest legacy key (blogging_categories)
            legacy =
              case settings_call(:get_json_setting_cached, [@legacy_categories_key, nil]) do
                %{"types" => types} when is_list(types) -> types
                other when is_list(other) -> other
                _ -> []
              end

            normalize_groups(legacy)
        end
    end
  end

  @doc """
  Gets a publishing group by slug.

  ## Examples

      iex> Publishing.get_group("news")
      {:ok, %{"name" => "News", "slug" => "news", ...}}

      iex> Publishing.get_group("nonexistent")
      {:error, :not_found}
  """
  @spec get_group(String.t()) :: {:ok, group()} | {:error, :not_found}
  def get_group(slug) when is_binary(slug) do
    case Enum.find(list_groups(), &(&1["slug"] == slug)) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  @doc """
  Adds a new publishing group.

  ## Parameters

    * `name` - Display name for the group
    * `opts` - Keyword list or map with options:
      * `:mode` - Storage mode: "timestamp" or "slug" (default: "timestamp")
      * `:slug` - Optional custom slug, auto-generated from name if nil
      * `:type` - Content type: "blogging", "faq", "legal", or custom (default: "blogging")
      * `:item_singular` - Singular name for items (default: based on type, e.g., "post")
      * `:item_plural` - Plural name for items (default: based on type, e.g., "posts")

  ## Examples

      iex> Publishing.add_group("News")
      {:ok, %{"name" => "News", "slug" => "news", "mode" => "timestamp", "type" => "blogging", ...}}

      iex> Publishing.add_group("FAQ", type: "faq", mode: "slug")
      {:ok, %{"name" => "FAQ", "slug" => "faq", "mode" => "slug", "type" => "faq", "item_singular" => "question", ...}}

      iex> Publishing.add_group("Recipes", type: "custom", item_singular: "recipe", item_plural: "recipes")
      {:ok, %{"name" => "Recipes", ..., "item_singular" => "recipe", "item_plural" => "recipes"}}
  """
  @spec add_group(String.t(), keyword() | map()) :: {:ok, group()} | {:error, atom()}
  def add_group(name, opts \\ [])

  def add_group(name, opts) when is_binary(name) and (is_list(opts) or is_map(opts)) do
    trimmed = String.trim(name)
    mode = opts |> fetch_option(:mode) |> normalize_mode_with_default()
    normalized_type = opts |> fetch_option(:type) |> normalize_type()

    cond do
      trimmed == "" ->
        {:error, :invalid_name}

      is_nil(mode) ->
        {:error, :invalid_mode}

      is_nil(normalized_type) ->
        {:error, :invalid_type}

      true ->
        groups = list_groups()
        preferred_slug = fetch_option(opts, :slug)

        with {:ok, requested_slug} <- derive_requested_slug(preferred_slug, trimmed),
             :ok <- check_slug_availability(requested_slug, groups, preferred_slug) do
          slug = ensure_unique_slug(requested_slug, groups)

          # Get item names - use provided values or defaults based on type
          {default_singular, default_plural} = default_item_names(normalized_type)

          item_singular =
            opts
            |> fetch_option(:item_singular)
            |> normalize_item_name(default_singular)

          item_plural =
            opts
            |> fetch_option(:item_plural)
            |> normalize_item_name(default_plural)

          group = %{
            "name" => trimmed,
            "slug" => slug,
            "mode" => mode,
            "type" => normalized_type,
            "item_singular" => item_singular,
            "item_plural" => item_plural
          }

          updated = groups ++ [group]
          payload = %{"publishing_groups" => updated}

          # Always write to new key
          with {:ok, _} <- settings_call(:update_json_setting, [@publishing_groups_key, payload]),
               :ok <- Storage.ensure_group_root(slug) do
            {:ok, group}
          end
        end
    end
  end

  # Legacy 4-arity version for backward compatibility
  @doc false
  @spec add_group(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, group()} | {:error, atom()}
  def add_group(name, mode, preferred_slug, type)
      when is_binary(name) and is_binary(mode) do
    add_group(name, mode: mode, slug: preferred_slug, type: type)
  end

  @doc """
  Removes a publishing group by slug.
  """
  @spec remove_group(String.t()) :: {:ok, any()} | {:error, any()}
  def remove_group(slug) when is_binary(slug) do
    updated =
      list_groups()
      |> Enum.reject(&(&1["slug"] == slug))

    settings_call(:update_json_setting, [
      @publishing_groups_key,
      %{"publishing_groups" => updated}
    ])
  end

  @doc """
  Updates a publishing group's display name and slug.
  """
  @spec update_group(String.t(), map() | keyword()) :: {:ok, group()} | {:error, atom()}
  def update_group(slug, params) when is_binary(slug) do
    groups = list_groups()

    case Enum.find(groups, &(&1["slug"] == slug)) do
      nil -> {:error, :not_found}
      group -> process_group_update(group, groups, params)
    end
  end

  defp process_group_update(group, groups, params) do
    with {:ok, name} <- extract_and_validate_name(group, params),
         {:ok, sanitized_slug} <- extract_and_validate_slug(group, params, name),
         :ok <- check_slug_uniqueness(group, groups, sanitized_slug) do
      apply_group_update(group, groups, name, sanitized_slug)
    end
  end

  defp extract_and_validate_name(group, params) do
    name =
      params
      |> fetch_option(:name)
      |> case do
        nil -> group["name"]
        value -> String.trim(to_string(value || ""))
      end

    if name == "", do: {:error, :invalid_name}, else: {:ok, name}
  end

  defp extract_and_validate_slug(group, params, name) do
    desired_slug =
      params
      |> fetch_option(:slug)
      |> case do
        nil -> group["slug"]
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

  defp check_slug_uniqueness(group, groups, sanitized_slug) do
    if sanitized_slug != group["slug"] and Enum.any?(groups, &(&1["slug"] == sanitized_slug)) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp apply_group_update(group, groups, name, sanitized_slug) do
    updated_group =
      group
      |> Map.put("name", name)
      |> Map.put("slug", sanitized_slug)

    with :ok <- Storage.rename_group_directory(group["slug"], sanitized_slug),
         {:ok, _} <- persist_group_update(groups, group["slug"], updated_group) do
      {:ok, updated_group}
    end
  end

  @doc """
  Moves a publishing group to trash by renaming its directory with timestamp.
  The group is removed from the active groups list and its directory is renamed to:
  GROUPNAME-YYYY-MM-DD-HH-MM-SS
  """
  @spec trash_group(String.t()) :: {:ok, String.t()} | {:error, any()}
  def trash_group(slug) when is_binary(slug) do
    with {:ok, _} <- remove_group(slug) do
      Storage.move_group_to_trash(slug)
    end
  end

  @doc """
  Looks up a publishing group name from its slug.
  """
  @spec group_name(String.t()) :: String.t() | nil
  def group_name(slug) do
    Enum.find_value(list_groups(), fn group ->
      if group["slug"] == slug, do: group["name"]
    end)
  end

  @doc """
  Returns the configured storage mode for a publishing group slug.
  """
  @spec get_group_mode(String.t()) :: String.t()
  def get_group_mode(group_slug) do
    list_groups()
    |> Enum.find(%{}, &(&1["slug"] == group_slug))
    |> Map.get("mode", @default_group_mode)
  end

  @doc """
  Lists posts for a given publishing group slug.
  Accepts optional preferred_language to show titles in user's language.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [Storage.post()]
  def list_posts(group_slug, preferred_language \\ nil) do
    case get_group_mode(group_slug) do
      "slug" -> Storage.list_posts_slug_mode(group_slug, preferred_language)
      _ -> Storage.list_posts(group_slug, preferred_language)
    end
  end

  @doc """
  Creates a new post for the given publishing group using the current timestamp.
  """
  @spec create_post(String.t(), map() | keyword()) :: {:ok, Storage.post()} | {:error, any()}
  def create_post(group_slug, opts \\ %{}) do
    scope = fetch_option(opts, :scope)
    audit_meta = audit_metadata(scope, :create)

    result =
      case get_group_mode(group_slug) do
        "slug" ->
          title = fetch_option(opts, :title)
          slug = fetch_option(opts, :slug)
          Storage.create_post_slug_mode(group_slug, title, slug, audit_meta)

        _ ->
          Storage.create_post(group_slug, audit_meta)
      end

    # Regenerate listing cache and broadcast on success
    with {:ok, post} <- result do
      ListingCache.regenerate(group_slug)
      PublishingPubSub.broadcast_post_created(group_slug, post)
    end

    result
  end

  @doc """
  Reads an existing post.

  For slug-mode groups, accepts an optional version parameter.
  If version is nil, reads the latest version.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, Storage.post()} | {:error, any()}
  def read_post(group_slug, identifier, language \\ nil, version \\ nil) do
    case get_group_mode(group_slug) do
      "slug" ->
        {post_slug, inferred_version, inferred_language} =
          extract_slug_version_and_language(group_slug, identifier)

        # Use explicit parameters if provided, otherwise use inferred values from path
        final_language = language || inferred_language
        final_version = version || inferred_version

        Storage.read_post_slug_mode(group_slug, post_slug, final_language, final_version)

      _ ->
        Storage.read_post(group_slug, identifier)
    end
  end

  @doc """
  Updates a post and moves the file if the publication timestamp changes.
  """
  @spec update_post(String.t(), Storage.post(), map(), map() | keyword()) ::
          {:ok, Storage.post()} | {:error, any()}
  def update_post(group_slug, post, params, opts \\ %{}) do
    # Normalize opts to map (callers may pass keyword list or map)
    opts_map = if Keyword.keyword?(opts), do: Map.new(opts), else: opts

    audit_meta =
      opts_map
      |> fetch_option(:scope)
      |> audit_metadata(:update)
      # Include is_primary_language so storage can set status_manual correctly
      |> Map.put(:is_primary_language, Map.get(opts_map, :is_primary_language, true))

    mode =
      Map.get(post, :mode) ||
        Map.get(post, "mode") ||
        mode_atom(get_group_mode(group_slug))

    result =
      case mode do
        :slug -> Storage.update_post_slug_mode(group_slug, post, params, audit_meta)
        _ -> Storage.update_post(group_slug, post, params, audit_meta)
      end

    # Regenerate listing cache on success, but only if the post is live
    # (For versioned posts, non-live versions don't affect public listings)
    # Always broadcast so all viewers of any version see updates
    with {:ok, updated_post} <- result do
      if should_regenerate_cache?(updated_post) do
        ListingCache.regenerate(group_slug)
      end

      PublishingPubSub.broadcast_post_updated(group_slug, updated_post)
    end

    result
  end

  @doc """
  Creates a new version of a slug-mode post by copying from the latest version.

  The new version starts as draft with status: "draft".
  Content and metadata updates from params are applied to the new version.

  Note: For more control over which version to branch from, use `create_version_from/5`.
  """
  @spec create_new_version(String.t(), Storage.post(), map(), map() | keyword()) ::
          {:ok, Storage.post()} | {:error, any()}
  def create_new_version(group_slug, source_post, params \\ %{}, opts \\ %{}) do
    audit_meta =
      opts
      |> fetch_option(:scope)
      |> audit_metadata(:create)

    result = Storage.create_new_version(group_slug, source_post, params, audit_meta)

    # Note: New versions start as drafts (status: "draft"), so we don't
    # regenerate the cache here. Cache will be regenerated when the
    # version is published via publish_version/3.
    # Always broadcast so all viewers see the new version exists
    with {:ok, new_version} <- result do
      post_slug = new_version[:slug]
      PublishingPubSub.broadcast_version_created(group_slug, new_version)
      # Also broadcast to post-level topic for editors
      if post_slug do
        version_info = %{
          version: new_version[:current_version],
          available_versions: new_version[:available_versions] || []
        }

        PublishingPubSub.broadcast_post_version_created(group_slug, post_slug, version_info)
      end
    end

    result
  end

  @doc """
  Publishes a version, making it the only published version.

  Sets the target version's primary language to `status: "published"`.
  Archives ALL other versions (`status: "archived"`).

  Translation status logic:
  - If `status_manual: true` → keep translation's current status
  - If `status_manual: false` AND has content → inherit primary status
  - If no content → remain unchanged

  ## Examples

      iex> Publishing.publish_version("blog", "my-post", 2)
      :ok

      iex> Publishing.publish_version("blog", "nonexistent", 1)
      {:error, :not_found}
  """
  @spec publish_version(String.t(), String.t(), integer()) :: :ok | {:error, any()}
  def publish_version(group_slug, post_slug, version) do
    result = Storage.publish_version(group_slug, post_slug, version)

    # Regenerate listing cache and broadcast on success
    if result == :ok do
      ListingCache.regenerate(group_slug)
      PublishingPubSub.broadcast_version_live_changed(group_slug, post_slug, version)
      # Also broadcast to post-level topic for editors
      PublishingPubSub.broadcast_post_version_published(group_slug, post_slug, version)
    end

    result
  end

  @doc """
  Creates a new version from an existing version or blank.

  ## Parameters

    * `group_slug` - The publishing group slug
    * `post_slug` - The post slug
    * `source_version` - Version to copy from, or `nil` for blank version
    * `params` - Optional parameters for the new version
    * `opts` - Options including `:scope` for audit metadata

  ## Examples

      # Create blank version
      iex> Publishing.create_version_from("blog", "my-post", nil, %{}, scope: scope)
      {:ok, %{version: 3, ...}}

      # Branch from version 1
      iex> Publishing.create_version_from("blog", "my-post", 1, %{}, scope: scope)
      {:ok, %{version: 3, ...}}
  """
  @spec create_version_from(String.t(), String.t(), integer() | nil, map(), map() | keyword()) ::
          {:ok, Storage.post()} | {:error, any()}
  def create_version_from(group_slug, post_slug, source_version, params \\ %{}, opts \\ %{}) do
    audit_meta =
      opts
      |> fetch_option(:scope)
      |> audit_metadata(:create)

    result =
      Storage.create_version_from(group_slug, post_slug, source_version, params, audit_meta)

    # Broadcast on success so all viewers see the new version exists
    with {:ok, new_version} <- result do
      PublishingPubSub.broadcast_version_created(group_slug, new_version)
      # Also broadcast to post-level topic for editors
      version_info = %{
        version: new_version[:current_version],
        available_versions: new_version[:available_versions] || []
      }

      PublishingPubSub.broadcast_post_version_created(group_slug, post_slug, version_info)
    end

    result
  end

  @doc """
  Sets a translation's status and marks it as manually overridden.

  When a translation status is set manually, it will NOT inherit status
  changes from the primary language when publishing.

  ## Examples

      iex> Publishing.set_translation_status("blog", "my-post", 2, "es", "draft")
      :ok
  """
  @spec set_translation_status(String.t(), String.t(), integer(), String.t(), String.t()) ::
          :ok | {:error, any()}
  def set_translation_status(group_slug, post_slug, version, language, status) do
    result = Storage.set_translation_status(group_slug, post_slug, version, language, status)

    # Regenerate cache if setting to published
    if result == :ok and status == "published" do
      ListingCache.regenerate(group_slug)
    end

    result
  end

  @doc false
  @deprecated "Use publish_version/3 instead"
  @spec set_version_live(String.t(), String.t(), integer()) :: :ok | {:error, any()}
  def set_version_live(group_slug, post_slug, version) do
    result = Storage.publish_version(group_slug, post_slug, version)

    # Regenerate listing cache and broadcast on success
    if result == :ok do
      ListingCache.regenerate(group_slug)
      PublishingPubSub.broadcast_version_live_changed(group_slug, post_slug, version)
      # Also broadcast to post-level topic for editors
      PublishingPubSub.broadcast_post_version_published(group_slug, post_slug, version)
    end

    result
  end

  @doc """
  Adds a new language file to an existing post.

  For slug-mode groups, accepts an optional version parameter to specify which
  version to add the translation to. If not specified, uses the version from
  the identifier path (if present) or defaults to the latest version.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, Storage.post()} | {:error, any()}
  def add_language_to_post(group_slug, identifier, language_code, version \\ nil) do
    result =
      case get_group_mode(group_slug) do
        "slug" ->
          {post_slug, inferred_version, _language} =
            extract_slug_version_and_language(group_slug, identifier)

          # Use explicit version if provided, otherwise use version from path
          target_version = version || inferred_version

          Storage.add_language_to_post_slug_mode(
            group_slug,
            post_slug,
            language_code,
            target_version
          )

        _ ->
          Storage.add_language_to_post(group_slug, identifier, language_code)
      end

    # Regenerate listing cache on success, but only if the post is live
    # Always broadcast so all viewers see the new translation
    with {:ok, new_post} <- result do
      if should_regenerate_cache?(new_post) do
        ListingCache.regenerate(group_slug)
      end

      # Broadcast translation created
      if new_post.slug do
        PublishingPubSub.broadcast_translation_created(group_slug, new_post.slug, language_code)
      end
    end

    result
  end

  @doc """
  Moves a post to the trash folder.

  For slug-mode groups, provide the post slug.
  For timestamp-mode groups, provide the date/time path (e.g., "2025-01-15/14:30").

  Returns {:ok, trash_path} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_post(group_slug, post_identifier) do
    result = Storage.trash_post(group_slug, post_identifier)

    with {:ok, _trash_path} <- result do
      ListingCache.regenerate(group_slug)
      PublishingPubSub.broadcast_post_deleted(group_slug, post_identifier)
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
  def delete_language(group_slug, post_identifier, language_code, version \\ nil) do
    result = Storage.delete_language(group_slug, post_identifier, language_code, version)

    if result == :ok do
      ListingCache.regenerate(group_slug)
      PublishingPubSub.broadcast_translation_deleted(group_slug, post_identifier, language_code)
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
  def delete_version(group_slug, post_identifier, version) do
    result = Storage.delete_version(group_slug, post_identifier, version)

    if result == :ok do
      # Only regenerate cache if deleting affected the live version
      # (but we already prevent deleting live version, so this is just for safety)
      ListingCache.regenerate(group_slug)
      PublishingPubSub.broadcast_version_deleted(group_slug, post_identifier, version)
      # Also broadcast to post-level topic for editors
      PublishingPubSub.broadcast_post_version_deleted(group_slug, post_identifier, version)
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
  Generates a slug from a user-provided group name.
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

  Group slugs cannot be language codes (like 'en', 'es', 'fr') to prevent routing ambiguity.
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
  # For versioned posts (slug mode with version info), only regenerate if the post is published.
  # For non-versioned posts (timestamp mode or legacy), always regenerate.
  defp should_regenerate_cache?(post) do
    mode = Map.get(post, :mode)
    metadata = Map.get(post, :metadata, %{})
    status = Map.get(metadata, :status)
    version = Map.get(metadata, :version) || Map.get(post, :version)

    cond do
      # Timestamp mode posts always regenerate (no versioning)
      mode == :timestamp -> true
      # Slug mode posts without version info (legacy) always regenerate
      is_nil(version) -> true
      # Slug mode posts: always regenerate to keep language_slugs current
      # The cache stores url_slugs for ALL translations, so any edit
      # (even to drafts) should update the cache for URL generation
      mode == :slug -> true
      # Published posts always regenerate
      status == "published" -> true
      # Fallback: don't regenerate for unknown modes with non-published status
      true -> false
    end
  end

  defp settings_module do
    # Check new key first, fall back to legacy key for backward compatibility
    case PhoenixKit.Config.get(:publishing_settings_module) do
      :not_found -> PhoenixKit.Config.get(:blogging_settings_module, PhoenixKit.Settings)
      {:ok, module} -> module
    end
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

  defp normalize_groups(groups) do
    groups
    |> Enum.map(&normalize_group_keys/1)
    |> Enum.map(fn group ->
      group
      |> ensure_mode()
      |> ensure_type()
    end)
  end

  defp ensure_mode(%{"mode" => mode} = group) when mode in ["timestamp", "slug"], do: group
  defp ensure_mode(group), do: Map.put(group, "mode", @default_group_mode)

  # Ensure type field exists, defaulting to "blogging" for backward compatibility
  # Also ensures item_singular and item_plural are set based on the type
  defp ensure_type(group) do
    type = Map.get(group, "type")
    type = if is_binary(type) and type != "", do: type, else: @default_group_type

    {default_singular, default_plural} =
      Map.get(@type_item_names, type, {@default_item_singular, @default_item_plural})

    group
    |> Map.put("type", type)
    |> Map.put_new("item_singular", default_singular)
    |> Map.put_new("item_plural", default_plural)
  end

  defp normalize_group_keys(group) when is_map(group) do
    Enum.reduce(group, %{}, fn
      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_group_keys(other), do: other

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

  # Normalize mode with default fallback
  defp normalize_mode_with_default(nil), do: @default_group_mode
  defp normalize_mode_with_default(mode), do: normalize_mode(mode) || @default_group_mode

  # Normalize and validate type
  # Preset types are passed through, custom types are validated and normalized
  defp normalize_type(nil), do: @default_group_type

  defp normalize_type(type) when is_binary(type) do
    trimmed = String.trim(type)
    downcased = String.downcase(trimmed)

    cond do
      # Preset type - pass through as-is
      downcased in @preset_types ->
        downcased

      # Empty after trim - use default
      trimmed == "" ->
        @default_group_type

      # Custom type - validate format
      true ->
        # Normalize: downcase, replace spaces/underscores with hyphens
        normalized =
          downcased
          |> String.replace(~r/[\s_]+/, "-")
          |> String.replace(~r/[^a-z0-9-]/, "")
          |> String.slice(0, 32)

        # Validate against type regex
        if Regex.match?(@type_regex, normalized) do
          normalized
        else
          nil
        end
    end
  end

  defp normalize_type(type) when is_atom(type), do: normalize_type(Atom.to_string(type))
  defp normalize_type(_), do: nil

  # Get default item names for a type
  defp default_item_names(type) do
    Map.get(@type_item_names, type, {@default_item_singular, @default_item_plural})
  end

  # Normalize item name, using default if nil/empty
  defp normalize_item_name(nil, default), do: default
  defp normalize_item_name("", default), do: default

  defp normalize_item_name(name, default) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: default, else: trimmed
  end

  defp normalize_item_name(_, default), do: default

  @doc """
  Returns the preset content types with their default item names.

  ## Examples

      iex> Publishing.preset_types()
      [
        %{type: "blogging", label: "Blog", item_singular: "post", item_plural: "posts"},
        %{type: "faq", label: "FAQ", item_singular: "question", item_plural: "questions"},
        %{type: "legal", label: "Legal", item_singular: "document", item_plural: "documents"}
      ]
  """
  @spec preset_types() :: [map()]
  def preset_types do
    [
      # Note: type value "blogging" kept for backward compatibility, label is "Blog"
      %{type: "blogging", label: "Blog", item_singular: "post", item_plural: "posts"},
      %{type: "faq", label: "FAQ", item_singular: "question", item_plural: "questions"},
      %{type: "legal", label: "Legal", item_singular: "document", item_plural: "documents"}
    ]
  end

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

  defp persist_group_update(groups, slug, updated_group) do
    updated =
      Enum.map(groups, fn
        %{"slug" => ^slug} -> updated_group
        other -> other
      end)

    settings_call(:update_json_setting, [
      @publishing_groups_key,
      %{"publishing_groups" => updated}
    ])
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
  #   - "group/post-slug/v2/am.phk" → {"post-slug", 2, "am"}
  defp extract_slug_version_and_language(_group_slug, nil), do: {"", nil, nil}

  defp extract_slug_version_and_language(group_slug, identifier) do
    parts =
      identifier
      |> to_string()
      |> String.trim()
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> drop_group_prefix(group_slug)

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

  # Only drop group prefix if there are more elements after it
  # This prevents dropping the post slug when it matches the group slug
  defp drop_group_prefix([group_slug | rest], group_slug) when rest != [], do: rest
  defp drop_group_prefix(list, _), do: list

  # ============================================================================
  # AI Translation
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

  @doc """
  Enqueues an Oban job to translate a post to all enabled languages using AI.

  This creates a background job that will:
  1. Read the source post in the primary language
  2. Translate the content to each target language using the AI module
  3. Create or update translation files for each language

  ## Options

  - `:endpoint_id` - AI endpoint ID to use for translation (required if not set in settings)
  - `:source_language` - Source language to translate from (defaults to primary language)
  - `:target_languages` - List of target language codes (defaults to all enabled except source)
  - `:version` - Version number to translate (defaults to latest/published)
  - `:user_id` - User ID for audit trail

  ## Configuration

  Set the default AI endpoint for translations:

      PhoenixKit.Settings.update_setting("publishing_translation_endpoint_id", "1")

  ## Examples

      # Translate to all enabled languages using default endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "getting-started")

      # Translate with specific endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "getting-started",
        endpoint_id: 1
      )

      # Translate to specific languages only
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "getting-started",
        endpoint_id: 1,
        target_languages: ["es", "fr", "de"]
      )

  ## Returns

  - `{:ok, %Oban.Job{}}` - Job was successfully enqueued
  - `{:error, changeset}` - Failed to enqueue job

  """
  @spec translate_post_to_all_languages(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def translate_post_to_all_languages(group_slug, post_slug, opts \\ []) do
    TranslatePostWorker.enqueue(group_slug, post_slug, opts)
  end

  # ============================================================================
  # Backward compatibility aliases (deprecated)
  # These functions delegate to the new "group" terminology functions
  # ============================================================================

  @doc false
  @deprecated "Use list_groups/0 instead"
  def list_blogs, do: list_groups()

  @doc false
  @deprecated "Use get_group/1 instead"
  def get_blog(slug), do: get_group(slug)

  @doc false
  @deprecated "Use add_group/2 instead"
  def add_blog(name, opts \\ []), do: add_group(name, opts)

  @doc false
  @deprecated "Use remove_group/1 instead"
  def remove_blog(slug), do: remove_group(slug)

  @doc false
  @deprecated "Use update_group/2 instead"
  def update_blog(slug, params), do: update_group(slug, params)

  @doc false
  @deprecated "Use trash_group/1 instead"
  def trash_blog(slug), do: trash_group(slug)

  @doc false
  @deprecated "Use group_name/1 instead"
  def blog_name(slug), do: group_name(slug)

  @doc false
  @deprecated "Use get_group_mode/1 instead"
  def get_blog_mode(group_slug), do: get_group_mode(group_slug)

  @doc false
  @deprecated "Use legacy_group?/1 instead"
  def legacy_blog?(group_slug), do: legacy_group?(group_slug)

  @doc false
  @deprecated "Use migrate_group/1 instead"
  def migrate_blog(group_slug), do: migrate_group(group_slug)

  @doc false
  @deprecated "Use has_legacy_groups?/0 instead"
  def has_legacy_blogs?, do: has_legacy_groups?()
end
