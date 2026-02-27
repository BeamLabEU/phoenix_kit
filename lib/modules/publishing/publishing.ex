defmodule PhoenixKit.Modules.Publishing do
  @moduledoc """
  Publishing module for managing content groups and their posts.

  This keeps content in the filesystem while providing an admin-friendly UI
  for creating timestamped or slug-based markdown posts with multi-language support.
  """

  use PhoenixKit.Module

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.DualWrite
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate

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
  def get_master_language, do: get_primary_language()

  # Post-specific primary language functions
  defdelegate get_post_primary_language(group_slug, post_slug, version \\ nil), to: Storage
  defdelegate check_primary_language_status(group_slug, post_slug), to: Storage

  @doc """
  Updates the primary language for a post. Falls back to DB for DB-only posts.
  """
  def update_post_primary_language(group_slug, post_slug, new_primary_language) do
    update_primary_language_in_db(group_slug, post_slug, new_primary_language)
  end

  # Migration detection functions (via ListingCache)
  defdelegate posts_needing_primary_language_migration(group_slug), to: ListingCache
  defdelegate count_primary_language_status(group_slug), to: ListingCache

  @doc """
  Checks if any posts in a group need primary_language migration.
  """
  @spec posts_need_primary_language_migration?(String.t()) :: boolean()
  def posts_need_primary_language_migration?(group_slug) do
    ListingCache.posts_needing_primary_language_migration(group_slug) != []
  end

  @doc """
  Returns count of posts by primary_language status.
  Alias for `count_primary_language_status/1`.
  """
  @spec get_primary_language_migration_status(String.t()) :: map()
  def get_primary_language_migration_status(group_slug) do
    ListingCache.count_primary_language_status(group_slug)
  end

  @doc """
  Migrates all posts in a group to use the current global primary_language.

  This updates the `primary_language` field in all .phk files and regenerates
  the listing cache. The migration is idempotent - running it multiple times
  is safe and will skip posts that are already at the current primary language.

  Returns `{:ok, count}` where count is the number of posts updated.
  """
  @spec migrate_posts_to_current_primary_language(String.t()) ::
          {:ok, integer()} | {:error, any()}
  def migrate_posts_to_current_primary_language(group_slug) do
    require Logger
    global_primary = Storage.get_primary_language()
    posts = ListingCache.posts_needing_primary_language_migration(group_slug)

    Logger.debug("[PrimaryLangMigration] Found #{length(posts)} posts needing migration")

    if posts == [] do
      {:ok, 0}
    else
      results =
        posts
        |> Enum.map(fn post ->
          # Get slug from post (using atom keys since posts are normalized)
          post_slug = get_post_slug(post)

          Logger.debug(
            "[PrimaryLangMigration] Post path=#{inspect(post[:path])} slug=#{inspect(post_slug)}"
          )

          if post_slug do
            result = update_primary_language_in_db(group_slug, post_slug, global_primary)
            Logger.debug("[PrimaryLangMigration] Result for #{post_slug}: #{inspect(result)}")
            result
          else
            Logger.warning("[PrimaryLangMigration] No slug for post: #{inspect(post[:path])}")
            {:error, :no_slug}
          end
        end)

      success_count = Enum.count(results, &(&1 == :ok))
      error_count = length(results) - success_count

      Logger.debug("[PrimaryLangMigration] Success: #{success_count}, Errors: #{error_count}")

      # Regenerate cache with updated primary_language values
      # Note: ListingCache.regenerate/1 broadcasts cache_changed internally
      ListingCache.regenerate(group_slug)

      if error_count > 0 and success_count == 0 do
        {:error, :all_migrations_failed}
      else
        {:ok, success_count}
      end
    end
  end

  # Get post directory path from cached post
  # For slug mode: returns the slug (e.g., "hello")
  # For timestamp mode: returns the date/time path (e.g., "2025-12-31/03:42")
  # Uses atom keys since cached posts are normalized
  defp get_post_slug(post) do
    case post[:mode] do
      :timestamp -> derive_timestamp_post_dir(post[:path])
      "timestamp" -> derive_timestamp_post_dir(post[:path])
      _ -> post[:slug] || derive_slug_from_path(post[:path])
    end
  end

  # For timestamp mode, extract date/time from path like "group/date/time/version/file.phk"
  defp derive_timestamp_post_dir(nil), do: nil
  defp derive_timestamp_post_dir(""), do: nil

  defp derive_timestamp_post_dir(path) do
    parts = Path.split(path)

    case parts do
      # Versioned: group/date/time/v1/lang.phk
      [_group, date, time, "v" <> _, _lang_file] -> Path.join(date, time)
      # Legacy: group/date/time/lang.phk
      [_group, date, time, _lang_file] -> Path.join(date, time)
      _ -> nil
    end
  end

  # For slug mode, extract slug from path
  defp derive_slug_from_path(nil), do: nil
  defp derive_slug_from_path(""), do: nil

  defp derive_slug_from_path(path) do
    parts = Path.split(path)

    case parts do
      # Versioned: group/slug/v1/lang.phk
      [_group, slug, "v" <> _, _lang_file] -> slug
      # Legacy: group/slug/lang.phk
      [_group, slug, _lang_file] -> slug
      _ -> nil
    end
  end

  # ===========================================================================
  # Legacy Structure Migration
  # ===========================================================================

  # Migration detection functions (via ListingCache)
  defdelegate posts_needing_version_migration(group_slug), to: ListingCache
  defdelegate count_legacy_structure_status(group_slug), to: ListingCache

  @doc """
  Checks if any posts in a group need version structure migration.
  """
  @spec posts_need_version_migration?(String.t()) :: boolean()
  def posts_need_version_migration?(group_slug) do
    ListingCache.posts_needing_version_migration(group_slug) != []
  end

  @doc """
  Returns count of posts by version structure status.
  """
  @spec get_legacy_structure_status(String.t()) :: map()
  def get_legacy_structure_status(group_slug) do
    ListingCache.count_legacy_structure_status(group_slug)
  end

  @doc """
  Migrates all legacy structure posts in a group to versioned structure.

  No-op in DB-only mode — database posts are inherently versioned.
  Kept for API compatibility with listing UI and workers.
  """
  @spec migrate_posts_to_versioned_structure(String.t()) ::
          {:ok, integer()} | {:error, any()}
  def migrate_posts_to_versioned_structure(_group_slug) do
    # DB posts are inherently versioned — no filesystem migration needed
    {:ok, 0}
  end

  defdelegate language_enabled?(language_code, enabled_languages), to: Storage
  defdelegate get_display_code(language_code, enabled_languages), to: Storage
  defdelegate order_languages_for_display(available_languages, enabled_languages), to: Storage

  # Delegate version metadata to Storage
  defdelegate get_version_metadata(group_slug, post_slug, version, language), to: Storage

  # Delegate cache operations to ListingCache
  defdelegate regenerate_cache(group_slug), to: ListingCache, as: :regenerate
  defdelegate invalidate_cache(group_slug), to: ListingCache, as: :invalidate
  defdelegate cache_exists?(group_slug), to: ListingCache, as: :exists?
  defdelegate find_cached_post(group_slug, post_slug), to: ListingCache, as: :find_post

  defdelegate find_cached_post_by_path(group_slug, date, time),
    to: ListingCache,
    as: :find_post_by_path

  @doc """
  Finds a post by URL slug, checking DB or ListingCache based on storage mode.
  """
  @spec find_by_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_url_slug(group_slug, language, url_slug) do
    case storage_mode() do
      :db ->
        case DBStorage.find_by_url_slug(group_slug, language, url_slug) do
          nil -> {:error, :not_found}
          content -> {:ok, db_content_to_legacy_post(content, group_slug, language)}
        end

      :filesystem ->
        ListingCache.find_by_url_slug(group_slug, language, url_slug)
    end
  end

  @doc """
  Finds a post by a previous URL slug (for 301 redirects).
  """
  @spec find_by_previous_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_previous_url_slug(group_slug, language, url_slug) do
    case storage_mode() do
      :db ->
        # Query content rows where data.previous_url_slugs contains the slug
        case DBStorage.find_by_previous_url_slug(group_slug, language, url_slug) do
          nil -> {:error, :not_found}
          content -> {:ok, db_content_to_legacy_post(content, group_slug, language)}
        end

      :filesystem ->
        ListingCache.find_by_previous_url_slug(group_slug, language, url_slug)
    end
  end

  # Converts a DBStorage content record (with preloaded version/post/group) to a legacy post map
  defp db_content_to_legacy_post(content, _group_slug, _language) do
    version = content.version
    post = version.post

    %{
      slug: post.slug,
      url_slug: content.url_slug,
      language: content.language,
      metadata: %{
        title: content.title,
        status: content.status,
        description: (content.data || %{})["description"]
      }
    }
  end

  # Delegate storage path functions
  defdelegate legacy_group?(group_slug), to: Storage
  defdelegate has_legacy_groups?(), to: Storage

  # New settings keys (write to these)
  @publishing_enabled_key "publishing_enabled"
  @publishing_groups_key "publishing_groups"

  # Legacy settings keys (read from these as fallback)
  @legacy_enabled_key "blogging_enabled"
  @legacy_blogs_key "blogging_blogs"
  @legacy_categories_key "blogging_categories"

  @publishing_storage_key "publishing_storage"

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

  @impl PhoenixKit.Module
  @doc """
  Returns true when the publishing module is enabled.
  Checks new key first, falls back to legacy key.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    # Check new key first, then fall back to legacy key
    # Uses get_boolean_setting (cached) to avoid DB queries on every sidebar render
    settings_call(:get_boolean_setting, [@publishing_enabled_key, false]) or
      settings_call(:get_boolean_setting, [@legacy_enabled_key, false])
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the publishing module.
  Always writes to the new key.
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    settings_call(:update_boolean_setting, [@publishing_enabled_key, true])
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the publishing module.
  Always writes to the new key.
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    settings_call(:update_boolean_setting, [@publishing_enabled_key, false])
  end

  @doc """
  Returns the current storage mode for publishing reads.

  - `:filesystem` (default) — reads from filesystem via Storage/ListingCache
  - `:db` — reads from database via DBStorage

  Controlled by the `publishing_storage` setting (seeded by V59 migration).
  """
  @spec storage_mode() :: :filesystem | :db
  def storage_mode do
    case settings_call(:get_setting_cached, [@publishing_storage_key, "filesystem"]) do
      "db" -> :db
      _ -> :filesystem
    end
  end

  @doc """
  Returns true when reads are served from the database.
  """
  @spec db_storage?() :: boolean()
  def db_storage?, do: storage_mode() == :db

  @doc """
  Returns true when the DB says storage mode is "db", bypassing the cache.
  Used by the editor migration gate to avoid stale cache issues.
  """
  @spec db_storage_direct?() :: boolean()
  def db_storage_direct? do
    case settings_call(:get_setting, [@publishing_storage_key]) do
      "db" -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Returns true when the given post is a DB-backed post (has a UUID).

  Use this to discriminate individual posts. Use `db_storage?/0` for
  global storage mode decisions.
  """
  @spec db_post?(map()) :: boolean()
  def db_post?(post), do: not is_nil(post[:uuid])

  @doc """
  Returns true if any publishing group has filesystem posts.
  Used to detect whether FS→DB migration is needed (fresh installs have none).
  """
  @spec has_any_fs_posts?() :: boolean()
  def has_any_fs_posts? do
    list_groups()
    |> Enum.any?(fn g -> list_posts(g["slug"]) != [] end)
  end

  @doc """
  Switches storage mode to database. Called automatically when migration
  completes or when a fresh install (no FS posts) is detected.
  """
  def enable_db_storage! do
    settings_call(:update_setting, ["publishing_storage", "db"])

    # Clear stale FS-mode cache entries so DB-mode regeneration starts fresh
    Enum.each(list_groups(), fn g ->
      ListingCache.invalidate(g["slug"])
    end)
  rescue
    # Don't let cache cleanup failure prevent the mode switch
    _ -> :ok
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "publishing"

  @impl PhoenixKit.Module
  def module_name, do: "Publishing"

  @impl PhoenixKit.Module
  def get_config do
    %{
      enabled: enabled?(),
      storage_mode: storage_mode(),
      groups_count: length(list_groups())
    }
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "publishing",
      label: "Publishing",
      icon: "hero-document-duplicate",
      description: "Filesystem-based CMS pages and multi-language content"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_publishing,
        label: "Publishing",
        icon: "hero-document-text",
        path: "publishing",
        priority: 600,
        level: :admin,
        permission: "publishing",
        match: :exact,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        dynamic_children: &__MODULE__.publishing_children/1
      )
    ]
  end

  @doc "Dynamic children function for Publishing sidebar tabs."
  def publishing_children(_scope) do
    groups = load_publishing_groups_for_tabs()

    groups
    |> Enum.with_index()
    |> Enum.map(fn {group, idx} ->
      slug = group["slug"] || ""
      name = group["name"] || slug
      hash = :erlang.phash2(slug) |> Integer.to_string(16) |> String.downcase()
      sanitized = slug |> String.replace(~r/[^a-zA-Z0-9_]/, "_") |> String.slice(0, 50)

      %Tab{
        id: :"admin_publishing_#{sanitized}_#{hash}",
        label: name,
        icon: "hero-document-text",
        path: "publishing/#{slug}",
        priority: 601 + idx,
        level: :admin,
        permission: "publishing",
        match: :prefix,
        parent: :admin_publishing
      }
    end)
  rescue
    _ -> []
  end

  defp load_publishing_groups_for_tabs do
    alias PhoenixKit.Settings

    publishing_enabled =
      Settings.get_boolean_setting("publishing_enabled", false) or
        Settings.get_boolean_setting("blogging_enabled", false)

    if publishing_enabled do
      alias PhoenixKit.Modules.Publishing.DBStorage

      DBStorage.list_groups()
      |> Enum.map(fn g -> %{"name" => g.name, "slug" => g.slug} end)
    else
      []
    end
  rescue
    _ -> []
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_publishing,
        label: "Publishing",
        icon: "hero-document-text",
        path: "publishing",
        priority: 921,
        level: :admin,
        parent: :admin_settings,
        permission: "publishing"
      )
    ]
  end

  @impl PhoenixKit.Module
  def children, do: [PhoenixKit.Modules.Publishing.Presence]

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitWeb.Routes.PublishingRoutes

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
          with {:ok, _} <- settings_call(:update_json_setting, [@publishing_groups_key, payload]) do
            DualWrite.sync_group_created(group)
            PublishingPubSub.broadcast_group_created(group)
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

    result =
      settings_call(:update_json_setting, [
        @publishing_groups_key,
        %{"publishing_groups" => updated}
      ])

    # Broadcast after successful deletion
    if match?({:ok, _}, result) do
      DualWrite.sync_group_deleted(slug)
      PublishingPubSub.broadcast_group_deleted(slug)
    end

    result
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

    with {:ok, _} <- persist_group_update(groups, group["slug"], updated_group) do
      DualWrite.sync_group_updated(group["slug"], updated_group)
      PublishingPubSub.broadcast_group_updated(updated_group)
      {:ok, updated_group}
    end
  end

  @doc """
  Removes a publishing group. The group is removed from the active groups list
  and soft-deleted in the database.
  """
  @spec trash_group(String.t()) :: {:ok, String.t()} | {:error, any()}
  def trash_group(slug) when is_binary(slug) do
    with {:ok, _} <- remove_group(slug) do
      {:ok, slug}
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

  When `publishing_storage` is `:db`, queries the database directly.
  Otherwise uses the ListingCache for fast lookups, falling back to
  filesystem scan on cache miss.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [Storage.post()]
  def list_posts(group_slug, preferred_language \\ nil) do
    case storage_mode() do
      :db -> list_posts_from_db(group_slug)
      :filesystem -> list_posts_from_cache(group_slug, preferred_language)
    end
  end

  defp list_posts_from_db(group_slug) do
    DBStorage.list_posts_with_metadata(group_slug)
  end

  defp list_posts_from_cache(group_slug, preferred_language) do
    start_time = System.monotonic_time(:millisecond)

    # Try cache first for fast response
    result =
      case ListingCache.read(group_slug) do
        {:ok, cached_posts} ->
          elapsed = System.monotonic_time(:millisecond) - start_time

          Logger.debug(
            "[Publishing.list_posts] CACHE HIT for #{group_slug} (#{length(cached_posts)} posts) in #{elapsed}ms"
          )

          cached_posts

        {:error, :cache_miss} ->
          # Cache miss - regenerate cache synchronously to prevent race condition
          Logger.debug(
            "[Publishing.list_posts] CACHE MISS for #{group_slug}, regenerating cache..."
          )

          case ListingCache.regenerate_if_not_in_progress(group_slug) do
            :ok ->
              elapsed = System.monotonic_time(:millisecond) - start_time

              Logger.debug(
                "[Publishing.list_posts] Cache regenerated for #{group_slug} in #{elapsed}ms"
              )

              case ListingCache.read(group_slug) do
                {:ok, posts} -> posts
                {:error, _} -> list_posts_from_storage(group_slug, preferred_language)
              end

            :already_in_progress ->
              posts = list_posts_from_storage(group_slug, preferred_language)
              elapsed = System.monotonic_time(:millisecond) - start_time

              Logger.debug(
                "[Publishing.list_posts] Regeneration in progress, filesystem scan for #{group_slug} (#{length(posts)} posts) in #{elapsed}ms"
              )

              posts

            {:error, _reason} ->
              posts = list_posts_from_storage(group_slug, preferred_language)
              elapsed = System.monotonic_time(:millisecond) - start_time

              Logger.debug(
                "[Publishing.list_posts] Regeneration failed, filesystem scan for #{group_slug} (#{length(posts)} posts) in #{elapsed}ms"
              )

              posts
          end
      end

    result
  end

  # Direct filesystem scan (used on cache miss)
  defp list_posts_from_storage(group_slug, preferred_language) do
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
    create_post_in_db(group_slug, opts)
  end

  defp create_post_in_db(group_slug, opts) do
    alias PhoenixKit.Modules.Publishing.Storage.Slugs

    scope = fetch_option(opts, :scope)
    group = DBStorage.get_group_by_slug(group_slug)
    unless group, do: throw({:error, :group_not_found})

    mode = get_group_mode(group_slug)
    primary_language = Storage.get_primary_language()
    now = UtilsDate.utc_now()

    # Resolve user IDs for audit
    {created_by_uuid, created_by_id} = resolve_scope_user_ids(scope)

    # Generate slug for slug-mode groups
    slug_result =
      case mode do
        "slug" ->
          title = fetch_option(opts, :title)
          preferred_slug = fetch_option(opts, :slug)
          Slugs.generate_unique_slug(group_slug, title || "", preferred_slug)

        _ ->
          {:ok, nil}
      end

    with {:ok, post_slug} <- slug_result do
      # Build post attributes
      post_attrs = %{
        group_uuid: group.uuid,
        slug: post_slug,
        status: "draft",
        mode: mode,
        primary_language: primary_language,
        published_at: now,
        created_by_uuid: created_by_uuid,
        created_by_id: created_by_id,
        updated_by_uuid: created_by_uuid,
        updated_by_id: created_by_id
      }

      # Add date/time for timestamp mode
      post_attrs =
        if mode == "timestamp" do
          Map.merge(post_attrs, %{
            post_date: DateTime.to_date(now),
            post_time: DateTime.to_time(now)
          })
        else
          post_attrs
        end

      with {:ok, db_post} <- DBStorage.create_post(post_attrs),
           {:ok, db_version} <-
             DBStorage.create_version(%{
               post_uuid: db_post.uuid,
               version_number: 1,
               status: "draft",
               created_by_uuid: created_by_uuid,
               created_by_id: created_by_id
             }),
           {:ok, _content} <-
             DBStorage.create_content(%{
               version_uuid: db_version.uuid,
               language: primary_language,
               title: fetch_option(opts, :title) || "",
               content: fetch_option(opts, :content) || "",
               status: "draft",
               url_slug: post_slug
             }) do
        # Read back via mapper to get a proper legacy map with UUID
        case DBStorage.read_post(group_slug, db_post.slug, primary_language, 1) do
          {:ok, post} ->
            ListingCache.regenerate(group_slug)
            PublishingPubSub.broadcast_post_created(group_slug, post)
            {:ok, post}

          {:error, _} = err ->
            err
        end
      end
    end
  catch
    {:error, reason} -> {:error, reason}
  end

  defp resolve_scope_user_ids(nil), do: {nil, nil}

  defp resolve_scope_user_ids(scope) do
    user_id = Scope.user_id(scope)
    user_uuid = if scope.user, do: scope.user.uuid, else: nil
    {user_uuid, user_id}
  end

  @doc """
  Reads a post by its database UUID.

  Resolves the UUID to a group slug and post slug, then delegates to `read_post/4`.
  Invalid version/language params gracefully fall back to latest/primary.
  """
  def read_post_by_uuid(post_uuid, language \\ nil, version \\ nil) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        {:error, :not_found}

      db_post ->
        group_slug = db_post.group.slug
        version_number = if version, do: normalize_version_number(version), else: nil

        if db_post.post_date && db_post.post_time do
          DBStorage.read_post_by_datetime(
            group_slug,
            db_post.post_date,
            db_post.post_time,
            language,
            version_number
          )
        else
          DBStorage.read_post(group_slug, db_post.slug, language, version_number)
        end
    end
  rescue
    Ecto.QueryError -> {:error, :not_found}
    DBConnection.ConnectionError -> {:error, :not_found}
  end

  @doc """
  Reads an existing post.

  For slug-mode groups, accepts an optional version parameter.
  If version is nil, reads the latest version.

  When `publishing_storage` is `:db`, reads from the database.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, Storage.post()} | {:error, any()}
  def read_post(group_slug, identifier, language \\ nil, version \\ nil) do
    case storage_mode() do
      :db ->
        read_post_from_db(group_slug, identifier, language, version)

      :filesystem ->
        case read_post_from_filesystem(group_slug, identifier, language, version) do
          {:ok, _} = success ->
            success

          {:error, _} ->
            # Fallback to DB for groups that were imported but don't exist on filesystem
            read_post_from_db(group_slug, identifier, language, version)
        end
    end
  end

  defp read_post_from_db(group_slug, identifier, language, version) do
    case get_group_mode(group_slug) do
      "timestamp" ->
        read_post_from_db_timestamp(group_slug, identifier, language, version)

      _ ->
        read_post_from_db_slug(group_slug, identifier, language, version)
    end
  end

  defp read_post_from_db_timestamp(group_slug, identifier, language, version) do
    case parse_timestamp_path(identifier) do
      {:ok, date, time, inferred_version, inferred_language} ->
        final_language = language || inferred_language
        final_version = version || inferred_version
        version_number = normalize_version_number(final_version)

        DBStorage.read_post_by_datetime(
          group_slug,
          date,
          time,
          final_language,
          version_number
        )

      :error ->
        # Fallback: try as slug-based lookup
        read_post_from_db_slug(group_slug, identifier, language, version)
    end
  end

  defp read_post_from_db_slug(group_slug, identifier, language, version) do
    {post_slug, inferred_version, inferred_language} =
      extract_slug_version_and_language(group_slug, identifier)

    final_language = language || inferred_language
    final_version = version || inferred_version
    version_number = normalize_version_number(final_version)

    DBStorage.read_post(group_slug, post_slug, final_language, version_number)
  end

  defp normalize_version_number(nil), do: nil

  defp normalize_version_number(v) when is_integer(v), do: v

  defp normalize_version_number(v) do
    case Integer.parse("#{v}") do
      {n, _} -> n
      :error -> nil
    end
  end

  # Parses timestamp paths like "2026-01-24/04:13/v7/sq.phk" or "2026-01-24/04:13"
  defp parse_timestamp_path(identifier) do
    parts =
      identifier
      |> to_string()
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    case parts do
      [date_str, time_str] ->
        with {:ok, date} <- Date.from_iso8601(date_str),
             {:ok, time} <- parse_time(time_str) do
          {:ok, date, time, nil, nil}
        else
          _ -> :error
        end

      [date_str, time_str | rest] ->
        with {:ok, date} <- Date.from_iso8601(date_str),
             {:ok, time} <- parse_time(time_str) do
          {version, rest_after} = extract_version_from_parts(rest)

          lang =
            rest_after
            |> List.first()
            |> case do
              nil -> nil
              "" -> nil
              lang_file -> String.replace_suffix(lang_file, ".phk", "")
            end

          {:ok, date, time, version, lang}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_time(time_str) do
    # Handle "HH:MM" format
    case Time.from_iso8601(time_str <> ":00") do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  defp read_post_from_filesystem(group_slug, identifier, language, version) do
    case get_group_mode(group_slug) do
      "slug" ->
        {post_slug, inferred_version, inferred_language} =
          extract_slug_version_and_language(group_slug, identifier)

        final_language = language || inferred_language
        final_version = version || inferred_version

        Storage.read_post_slug_mode(group_slug, post_slug, final_language, final_version)

      _ ->
        read_post_timestamp_mode(group_slug, identifier, language, version)
    end
  end

  # Handle timestamp mode posts - identifier can be:
  # - Full path like "blog/2025-12-31/03:42/v2/en.phk"
  # - Timestamp identifier like "2025-12-31/03:42"
  defp read_post_timestamp_mode(group_slug, identifier, language, version) do
    # If identifier looks like a full path (contains .phk), use it directly
    if String.contains?(identifier, ".phk") do
      Storage.read_post(group_slug, identifier)
    else
      # Build full path from timestamp identifier + language + version
      final_language = language || Storage.get_primary_language()
      final_version = version || get_latest_timestamp_version(group_slug, identifier)

      full_path =
        Path.join([group_slug, identifier, "v#{final_version}", "#{final_language}.phk"])

      Storage.read_post(group_slug, full_path)
    end
  end

  # Get the latest version number for a timestamp mode post
  defp get_latest_timestamp_version(group_slug, timestamp_id) do
    post_dir = Path.join([Storage.group_path(group_slug), timestamp_id])

    case File.ls(post_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.match?(&1, ~r/^v\d+$/))
        |> Enum.map(fn "v" <> n -> String.to_integer(n) end)
        |> Enum.max(fn -> 1 end)

      _ ->
        1
    end
  end

  # Adds a language to a DB-only post (no filesystem counterpart).
  # Creates a new content row in the database and returns the legacy map.
  @doc false
  def add_language_to_db(group_slug, post_slug, language_code, version_number) do
    with db_post when not is_nil(db_post) <- resolve_db_post(group_slug, post_slug),
         version when not is_nil(version) <-
           if(version_number,
             do: DBStorage.get_version(db_post.uuid, version_number),
             else: DBStorage.get_latest_version(db_post.uuid)
           ),
         # Check if content already exists for this language
         nil <- DBStorage.get_content(version.uuid, language_code),
         {:ok, _content} <-
           DBStorage.create_content(%{
             version_uuid: version.uuid,
             language: language_code,
             title: "Untitled",
             content: "",
             status: "draft"
           }) do
      # Read the post back from DB to return a proper legacy map
      read_back_post(group_slug, post_slug, db_post, language_code, version.version_number)
    else
      nil ->
        {:error, :not_found}

      %PhoenixKit.Modules.Publishing.PublishingContent{} ->
        # Content already exists for this language - just read the post
        read_back_post(group_slug, post_slug, nil, language_code, version_number)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    Ecto.QueryError -> {:error, :not_found}
    DBConnection.ConnectionError -> {:error, :not_found}
  end

  # Resolves a DB post by slug or datetime depending on group mode
  defp resolve_db_post(group_slug, identifier) do
    # Try slug-based lookup first
    case DBStorage.get_post(group_slug, identifier) do
      nil ->
        # For timestamp-mode posts, the identifier may be "YYYY-MM-DD/HH:MM"
        case parse_timestamp_path(identifier) do
          {:ok, date, time, _version, _lang} ->
            DBStorage.get_post_by_datetime(group_slug, date, time)

          :error ->
            nil
        end

      db_post ->
        db_post
    end
  end

  # Reads a post back from DB using the appropriate method for the group mode
  defp read_back_post(group_slug, identifier, db_post, language, version_number) do
    case parse_timestamp_path(identifier) do
      {:ok, date, time, _v, _l} ->
        DBStorage.read_post_by_datetime(group_slug, date, time, language, version_number)

      :error ->
        slug = if db_post, do: db_post.slug, else: identifier
        DBStorage.read_post(group_slug, slug, language, version_number)
    end
  end

  # Updates a DB-only post (no filesystem counterpart).
  # Writes directly to the database and returns the updated legacy map.
  defp update_post_in_db(group_slug, post, params, _audit_meta) do
    db_post = DBStorage.get_post(group_slug, post.slug)

    if db_post do
      # Handle slug changes (same validation as FS path)
      desired_slug = Map.get(params, "slug", post.slug)

      case maybe_update_db_slug(db_post, desired_slug, group_slug) do
        {:ok, final_slug} ->
          do_update_post_in_db(db_post, post, params, group_slug, final_slug)

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[Publishing] update_post_in_db failed: #{inspect(e)}")
      {:error, :db_update_failed}
  end

  defp maybe_update_db_slug(db_post, desired_slug, _group_slug)
       when desired_slug == db_post.slug do
    {:ok, db_post.slug}
  end

  defp maybe_update_db_slug(db_post, desired_slug, group_slug) do
    alias PhoenixKit.Modules.Publishing.Storage.Slugs

    with {:ok, valid_slug} <- Slugs.validate_slug(desired_slug),
         false <- Slugs.slug_exists?(group_slug, valid_slug),
         {:ok, _} <- DBStorage.update_post(db_post, %{slug: valid_slug}) do
      {:ok, valid_slug}
    else
      true -> {:error, :slug_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_update_post_in_db(db_post, post, params, group_slug, final_slug) do
    version_number = post[:version] || 1
    version = DBStorage.get_version(db_post.uuid, version_number)

    if version do
      language = post[:language] || db_post.primary_language
      new_status = Map.get(params, "status", post[:metadata][:status] || "draft")
      content = Map.get(params, "content", post[:content] || "")
      new_title = resolve_post_title(params, post, content)

      update_post_level_fields!(db_post, new_status, params)
      upsert_post_content(version, language, new_title, content, new_status, params, post)
      maybe_propagate_status(version, language, db_post, new_status, post)

      DBStorage.read_post(group_slug, final_slug, language, version_number)
    else
      {:error, :not_found}
    end
  catch
    {:post_update_failed, reason} -> {:error, reason}
  end

  defp resolve_post_title(params, post, content) do
    extracted_title = Metadata.extract_title_from_content(content)

    Map.get(params, "title") ||
      if(extracted_title != "Untitled", do: extracted_title) ||
      post[:metadata][:title] ||
      "Untitled"
  end

  defp update_post_level_fields!(db_post, new_status, params) do
    case DBStorage.update_post(db_post, %{
           status: new_status,
           published_at: parse_published_at(params, db_post)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> throw({:post_update_failed, reason})
    end
  end

  defp upsert_post_content(version, language, new_title, content, new_status, params, post) do
    existing_content = DBStorage.get_content(version.uuid, language)
    existing_url_slug = if existing_content, do: existing_content.url_slug
    existing_data = if existing_content, do: existing_content.data || %{}, else: %{}

    resolved_url_slug =
      case Map.fetch(params, "url_slug") do
        {:ok, val} -> val
        :error -> existing_url_slug
      end

    DBStorage.upsert_content(%{
      version_uuid: version.uuid,
      language: language,
      title: new_title,
      content: content,
      status: new_status,
      url_slug: resolved_url_slug,
      data: build_content_data(params, post, existing_data)
    })
  end

  defp maybe_propagate_status(version, language, db_post, new_status, post) do
    is_primary = language == db_post.primary_language
    old_status = post[:metadata][:status] || "draft"

    if is_primary and new_status != old_status do
      propagate_db_status_to_translations(version.uuid, language, new_status)
    end
  end

  # Propagates a status change from the primary language to all other translations
  defp update_primary_language_in_db(group_slug, post_slug, new_primary_language) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        {:error, :post_not_found}

      db_post ->
        case DBStorage.update_post(db_post, %{primary_language: new_primary_language}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    _ -> {:error, :post_not_found}
  end

  defp resolve_db_version(db_post, nil), do: DBStorage.get_latest_version(db_post.uuid)

  defp resolve_db_version(db_post, version_number),
    do: DBStorage.get_version(db_post.uuid, version_number)

  defp propagate_db_status_to_translations(version_uuid, primary_language, new_status) do
    DBStorage.list_contents(version_uuid)
    |> Enum.reject(fn c -> c.language == primary_language end)
    |> Enum.each(fn c ->
      DBStorage.update_content(c, %{status: new_status})
    end)
  end

  defp parse_published_at(params, db_post) do
    case Map.get(params, "published_at") do
      nil ->
        db_post.published_at

      "" ->
        db_post.published_at

      dt_string when is_binary(dt_string) ->
        case DateTime.from_iso8601(dt_string) do
          {:ok, dt, _} -> dt
          _ -> db_post.published_at
        end

      dt ->
        dt
    end
  end

  defp build_content_data(params, post, existing_data) do
    # Start from existing data to preserve previous_url_slugs, excerpt, seo_title, etc.
    data = existing_data

    data =
      case Map.get(params, "featured_image_id") do
        nil -> data
        id -> Map.put(data, "featured_image_id", id)
      end

    case Map.get(params, "description", post[:metadata][:description]) do
      nil -> data
      desc -> Map.put(data, "description", desc)
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
      |> Map.put(:is_primary_language, Map.get(opts_map, :is_primary_language, true))

    result = update_post_in_db(group_slug, post, params, audit_meta)

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
    source_version = source_post[:version] || 1
    create_version_in_db(group_slug, source_post.slug, source_version, params, opts)
  end

  @doc """
  Publishes a version, making it the only published version.

  - All files in the target version (primary and translations) → `status: "published"`
  - All files in other versions that were "published" → `status: "archived"`
  - Draft/archived files in other versions keep their current status

  ## Options

  - `:source_id` - ID of the source (e.g., socket.id) to include in broadcasts,
    allowing receivers to ignore their own messages

  ## Examples

      iex> Publishing.publish_version("blog", "my-post", 2)
      :ok

      iex> Publishing.publish_version("blog", "my-post", 2, source_id: "phx-abc123")
      :ok

      iex> Publishing.publish_version("blog", "nonexistent", 1)
      {:error, :not_found}
  """
  @spec publish_version(String.t(), String.t(), integer(), keyword()) :: :ok | {:error, any()}
  def publish_version(group_slug, post_slug, version, opts \\ []) do
    db_post = DBStorage.get_post(group_slug, post_slug)
    unless db_post, do: throw({:error, :not_found})

    # Set target version to published, archive previously-published versions
    for v <- DBStorage.list_versions(db_post.uuid) do
      new_status =
        cond do
          v.version_number == version -> "published"
          v.status == "published" -> "archived"
          true -> v.status
        end

      if new_status != v.status, do: DBStorage.update_version(v, %{status: new_status})
    end

    # Update post status and published_at
    DBStorage.update_post(db_post, %{
      status: "published",
      published_at: db_post.published_at || UtilsDate.utc_now()
    })

    source_id = Keyword.get(opts, :source_id)
    ListingCache.regenerate(group_slug)
    PublishingPubSub.broadcast_version_live_changed(group_slug, post_slug, version)
    PublishingPubSub.broadcast_post_version_published(group_slug, post_slug, version, source_id)

    :ok
  catch
    {:error, _} = err -> err
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
    create_version_in_db(group_slug, post_slug, source_version, params, opts)
  end

  defp create_version_in_db(group_slug, post_slug, source_version, _params, opts) do
    db_post = DBStorage.get_post(group_slug, post_slug)
    unless db_post, do: throw({:error, :post_not_found})

    scope = fetch_option(opts, :scope)
    {created_by_uuid, created_by_id} = resolve_scope_user_ids(scope)

    user_opts = %{created_by_uuid: created_by_uuid, created_by_id: created_by_id}

    result =
      if source_version do
        DBStorage.create_version_from(db_post.uuid, source_version, user_opts)
      else
        # Blank version — create empty version with primary language content
        with {:ok, db_version} <-
               DBStorage.create_version(%{
                 post_uuid: db_post.uuid,
                 version_number: DBStorage.next_version_number(db_post.uuid),
                 status: "draft",
                 created_by_uuid: created_by_uuid,
                 created_by_id: created_by_id
               }),
             {:ok, _content} <-
               DBStorage.create_content(%{
                 version_uuid: db_version.uuid,
                 language: db_post.primary_language,
                 title: "",
                 content: "",
                 status: "draft"
               }) do
          {:ok, db_version}
        end
      end

    with {:ok, db_version} <- result do
      case DBStorage.read_post(group_slug, post_slug, nil, db_version.version_number) do
        {:ok, post} ->
          broadcast_version_created(group_slug, post_slug, post)
          {:ok, post}

        {:error, _} = err ->
          err
      end
    end
  catch
    {:error, reason} -> {:error, reason}
  end

  @doc false
  def broadcast_version_created(group_slug, post_slug, new_version) do
    PublishingPubSub.broadcast_version_created(group_slug, new_version)

    version_info = %{
      version: new_version[:current_version] || new_version[:version],
      available_versions: new_version[:available_versions] || []
    }

    PublishingPubSub.broadcast_post_version_created(group_slug, post_slug, version_info)
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
    with db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_slug),
         db_version when not is_nil(db_version) <- DBStorage.get_version(db_post.uuid, version),
         content when not is_nil(content) <- DBStorage.get_content(db_version.uuid, language) do
      case DBStorage.update_content(content, %{status: status}) do
        {:ok, _} ->
          if status == "published", do: ListingCache.regenerate(group_slug)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc false
  @deprecated "Use publish_version/3 instead"
  @spec set_version_live(String.t(), String.t(), integer()) :: :ok | {:error, any()}
  def set_version_live(group_slug, post_slug, version) do
    publish_version(group_slug, post_slug, version)
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
    post_slug = extract_slug_from_identifier(group_slug, identifier)
    result = add_language_to_db(group_slug, post_slug, language_code, version)

    with {:ok, new_post} <- result do
      if should_regenerate_cache?(new_post) do
        ListingCache.regenerate(group_slug)
      end

      if new_post.slug do
        PublishingPubSub.broadcast_translation_created(group_slug, new_post.slug, language_code)
      end
    end

    result
  end

  defp extract_slug_from_identifier(group_slug, identifier) do
    case get_group_mode(group_slug) do
      "slug" ->
        {post_slug, _version, _language} =
          extract_slug_version_and_language(group_slug, identifier)

        post_slug

      _ ->
        # For timestamp mode, identifier might be the slug directly
        identifier
    end
  end

  @doc """
  Moves a post to the trash folder.

  For slug-mode groups, provide the post slug.
  For timestamp-mode groups, provide the date/time path (e.g., "2025-01-15/14:30").

  Returns {:ok, trash_path} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_post(group_slug, post_identifier) do
    case DBStorage.get_post(group_slug, post_identifier) do
      nil ->
        {:error, :not_found}

      db_post ->
        case DBStorage.soft_delete_post(db_post) do
          {:ok, _} ->
            ListingCache.regenerate(group_slug)
            PublishingPubSub.broadcast_post_deleted(group_slug, post_identifier)
            {:ok, post_identifier}

          {:error, reason} ->
            {:error, reason}
        end
    end
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
    with db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_identifier),
         db_version when not is_nil(db_version) <- resolve_db_version(db_post, version),
         content when not is_nil(content) <- DBStorage.get_content(db_version.uuid, language_code) do
      # Don't delete the last active language
      active =
        DBStorage.list_contents(db_version.uuid)
        |> Enum.reject(&(&1.status == "archived"))

      if length(active) <= 1, do: throw({:error, :last_language})

      case DBStorage.update_content(content, %{status: "archived"}) do
        {:ok, _} ->
          ListingCache.regenerate(group_slug)

          PublishingPubSub.broadcast_translation_deleted(
            group_slug,
            post_identifier,
            language_code
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  catch
    {:error, _} = err -> err
  end

  @doc """
  Deletes an entire version of a post.

  Moves the version folder to trash instead of permanent deletion.
  Refuses to delete the last remaining version or the live version.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_version(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def delete_version(group_slug, post_identifier, version) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_identifier),
         db_version when not is_nil(db_version) <- DBStorage.get_version(db_post.uuid, version) do
      if db_version.status == "published", do: throw({:error, :cannot_delete_live})

      active =
        DBStorage.list_versions(db_post.uuid)
        |> Enum.reject(&(&1.status == "archived"))

      if length(active) <= 1, do: throw({:error, :last_version})

      case DBStorage.update_version(db_version, %{status: "archived"}) do
        {:ok, _} ->
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_version_deleted(group_slug, post_identifier, version)
          PublishingPubSub.broadcast_post_version_deleted(group_slug, post_identifier, version)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  catch
    {:error, _} = err -> err
  end

  # Legacy wrappers (deprecated)
  def list_entries(group_slug, preferred_language \\ nil),
    do: list_posts(group_slug, preferred_language)

  def create_entry(group_slug), do: create_post(group_slug)

  def read_entry(group_slug, relative_path), do: read_post(group_slug, relative_path)

  def update_entry(group_slug, post, params), do: update_post(group_slug, post, params)

  def add_language_to_entry(group_slug, post_path, language_code),
    do: add_language_to_post(group_slug, post_path, language_code)

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

  @doc false
  def fetch_option(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  @doc false
  def fetch_option(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Keyword.get(opts, key)
    else
      nil
    end
  end

  @doc false
  def fetch_option(_, _), do: nil

  @doc false
  def audit_metadata(nil, _action), do: %{}

  @doc false
  def audit_metadata(scope, action) do
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
  defp check_slug_availability(slug, groups, preferred_slug) when not is_nil(preferred_slug) do
    if Enum.any?(groups, &(&1["slug"] == slug)) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp check_slug_availability(_slug, _groups, nil), do: :ok

  defp ensure_unique_slug(slug, groups), do: ensure_unique_slug(slug, groups, 2)

  defp ensure_unique_slug(slug, groups, counter) do
    if Enum.any?(groups, &(&1["slug"] == slug)) do
      ensure_unique_slug("#{slug}-#{counter}", groups, counter + 1)
    else
      slug
    end
  end

  # Extract slug, version, and language from a path identifier
  # Handles paths like:
  #   - "post-slug" → {"post-slug", nil, nil}
  #   - "post-slug/en.phk" → {"post-slug", nil, "en"}
  #   - "post-slug/v1/en.phk" → {"post-slug", 1, "en"}
  #   - "group/post-slug/v2/am.phk" → {"post-slug", 2, "am"}
  @doc false
  def extract_slug_version_and_language(_group_slug, nil), do: {"", nil, nil}

  @doc false
  def extract_slug_version_and_language(group_slug, identifier) do
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
  @deprecated "Use has_legacy_groups?/0 instead"
  def has_legacy_blogs?, do: has_legacy_groups?()
end
