defmodule PhoenixKit.Modules.Publishing do
  @moduledoc """
  Publishing module for managing content groups and their posts.

  Database-backed CMS for creating timestamped or slug-based posts
  with multi-language support and versioning.
  """

  use PhoenixKit.Module

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Suppress dialyzer false positives for pattern matches
  @dialyzer :no_match
  @dialyzer {:nowarn_function, create_post: 2}
  @dialyzer {:nowarn_function, add_language_to_post: 4}

  # Language utility delegates
  defdelegate get_language_info(language_code), to: LanguageHelpers
  defdelegate enabled_language_codes(), to: LanguageHelpers
  defdelegate get_primary_language(), to: LanguageHelpers
  defdelegate language_enabled?(language_code, enabled_languages), to: LanguageHelpers
  defdelegate get_display_code(language_code, enabled_languages), to: LanguageHelpers

  defdelegate order_languages_for_display(available_languages, enabled_languages),
    to: LanguageHelpers

  defdelegate order_languages_for_display(available_languages, enabled_languages, primary),
    to: LanguageHelpers

  # Slug utility delegates
  defdelegate validate_slug(slug), to: SlugHelpers
  defdelegate slug_exists?(group_slug, post_slug), to: SlugHelpers
  defdelegate generate_unique_slug(group_slug, title), to: SlugHelpers
  defdelegate generate_unique_slug(group_slug, title, preferred_slug), to: SlugHelpers
  defdelegate generate_unique_slug(group_slug, title, preferred_slug, opts), to: SlugHelpers
  defdelegate validate_url_slug(group_slug, url_slug, language, exclude), to: SlugHelpers

  @doc "Always returns false — auto-versioning is disabled."
  def should_create_new_version?(_post, _params, _editing_language), do: false

  @doc "Gets the primary language for a specific post from the database."
  def get_post_primary_language(group_slug, post_slug, _version \\ nil) do
    db_post =
      if uuid_format?(post_slug) do
        DBStorage.get_post_by_uuid(post_slug)
      else
        DBStorage.get_post(group_slug, post_slug)
      end

    case db_post do
      nil -> LanguageHelpers.get_primary_language()
      post -> post.primary_language || LanguageHelpers.get_primary_language()
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_post_primary_language failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      LanguageHelpers.get_primary_language()
  end

  @doc "Checks the primary language migration status for a post."
  def check_primary_language_status(group_slug, post_slug) do
    global_primary = LanguageHelpers.get_primary_language()

    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        {:needs_backfill, nil}

      %{primary_language: nil} ->
        {:needs_backfill, nil}

      %{primary_language: ^global_primary} ->
        {:ok, :current}

      %{primary_language: stored} ->
        {:needs_migration, stored}
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] check_primary_language_status failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      {:needs_backfill, nil}
  end

  @doc "Lists version numbers for a post."
  def list_versions(group_slug, post_slug) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        []

      db_post ->
        db_post.uuid
        |> DBStorage.list_versions()
        |> Enum.map(& &1.version_number)
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] list_versions failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      []
  end

  @doc "Gets the published version number for a post."
  def get_published_version(group_slug, post_slug) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        {:error, :not_found}

      db_post ->
        db_post.uuid
        |> DBStorage.list_versions()
        |> Enum.find(&(&1.status == "published"))
        |> case do
          nil -> {:error, :no_published_version}
          v -> {:ok, v.version_number}
        end
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_published_version failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      {:error, :not_found}
  end

  @doc "Gets the status of a specific version/language."
  def get_version_status(group_slug, post_slug, version_number, language) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_slug),
         db_version when not is_nil(db_version) <-
           DBStorage.get_version(db_post.uuid, version_number),
         content when not is_nil(content) <- DBStorage.get_content(db_version.uuid, language) do
      content.status
    else
      _ -> "draft"
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_version_status failed for #{group_slug}/#{post_slug}/v#{version_number}/#{language}: #{inspect(e)}"
      )

      "draft"
  end

  @doc "Counts posts on a specific date for a group."
  def count_posts_on_date(group_slug, date) do
    group_slug
    |> list_times_on_date(date)
    |> length()
  end

  @doc "Lists time values for posts on a specific date."
  def list_times_on_date(group_slug, date) do
    date = if is_binary(date), do: Date.from_iso8601!(date), else: date

    group_slug
    |> DBStorage.list_posts_timestamp_mode("published")
    |> Enum.filter(&(&1.post_date == date))
    |> Enum.map(&(Time.to_string(&1.post_time) |> String.slice(0, 5)))
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    e ->
      Logger.warning(
        "[Publishing] list_times_on_date failed for #{group_slug}/#{date}: #{inspect(e)}"
      )

      []
  end

  @doc """
  Updates the primary language for a post.
  Accepts a post UUID.
  """
  def update_post_primary_language(_group_slug, post_uuid, new_primary_language) do
    update_primary_language_in_db(post_uuid, new_primary_language)
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

  This updates the `primary_language` field in the database and regenerates
  the listing cache. The migration is idempotent - running it multiple times
  is safe and will skip posts that are already at the current primary language.

  Returns `{:ok, count}` where count is the number of posts updated.
  """
  @spec migrate_posts_to_current_primary_language(String.t()) ::
          {:ok, integer()} | {:error, any()}
  def migrate_posts_to_current_primary_language(group_slug) do
    require Logger
    global_primary = LanguageHelpers.get_primary_language()
    posts = ListingCache.posts_needing_primary_language_migration(group_slug)

    Logger.debug("[PrimaryLangMigration] Found #{length(posts)} posts needing migration")

    if posts == [] do
      {:ok, 0}
    else
      results =
        posts
        |> Enum.map(fn post ->
          post_uuid = post[:uuid]

          if post_uuid do
            update_primary_language_in_db(post_uuid, global_primary)
          else
            Logger.warning("[PrimaryLangMigration] No UUID for post: #{inspect(post[:slug])}")
            {:error, :no_uuid}
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

  # Version metadata lookup (DB-based)
  def get_version_metadata(group_slug, post_slug, version_number, language) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_slug),
         db_version when not is_nil(db_version) <-
           DBStorage.get_version(db_post.uuid, version_number),
         content when not is_nil(content) <- DBStorage.get_content(db_version.uuid, language) do
      %{
        status: content.status,
        title: content.title,
        url_slug: content.url_slug,
        version: version_number
      }
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_version_metadata failed for #{group_slug}/#{post_slug}/v#{version_number}: #{inspect(e)}"
      )

      nil
  end

  # Delegate cache operations to ListingCache
  defdelegate regenerate_cache(group_slug), to: ListingCache, as: :regenerate
  defdelegate invalidate_cache(group_slug), to: ListingCache, as: :invalidate
  defdelegate cache_exists?(group_slug), to: ListingCache, as: :exists?
  defdelegate find_cached_post(group_slug, post_slug), to: ListingCache, as: :find_post

  defdelegate find_cached_post_by_path(group_slug, date, time),
    to: ListingCache,
    as: :find_post_by_path

  @doc """
  Finds a post by URL slug from the database.
  """
  @spec find_by_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_url_slug(group_slug, language, url_slug) do
    case DBStorage.find_by_url_slug(group_slug, language, url_slug) do
      nil -> {:error, :not_found}
      content -> {:ok, db_content_to_post_map(content)}
    end
  end

  @doc """
  Finds a post by a previous URL slug (for 301 redirects).
  """
  @spec find_by_previous_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_previous_url_slug(group_slug, language, url_slug) do
    case DBStorage.find_by_previous_url_slug(group_slug, language, url_slug) do
      nil -> {:error, :not_found}
      content -> {:ok, db_content_to_post_map(content)}
    end
  end

  # Converts a DBStorage content record (with preloaded version/post/group) to a post map
  defp db_content_to_post_map(content) do
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

  @publishing_enabled_key "publishing_enabled"

  @default_group_mode "timestamp"
  @default_group_type "blog"
  @preset_types ["blog", "faq", "legal"]
  @valid_types ["blog", "faq", "legal", "custom"]
  @slug_regex ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @type_regex ~r/^[a-z][a-z0-9-]{0,31}$/

  @type_item_names %{
    "blog" => {"post", "posts"},
    "faq" => {"question", "questions"},
    "legal" => {"document", "documents"}
  }
  @default_item_singular "item"
  @default_item_plural "items"

  @type group :: map()

  @impl PhoenixKit.Module
  @doc """
  Returns true when the publishing module is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    settings_call(:get_boolean_setting, [@publishing_enabled_key, false])
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
  Returns true when the given post is a DB-backed post (has a UUID).
  """
  @spec db_post?(map()) :: boolean()
  def db_post?(post), do: not is_nil(post[:uuid])

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
      groups_count: length(list_groups())
    }
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "publishing",
      label: "Publishing",
      icon: "hero-document-duplicate",
      description: "Database-backed CMS pages and multi-language content"
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
        match: :prefix,
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
    e ->
      Logger.warning("[Publishing] dashboard_tabs failed: #{inspect(e)}")
      []
  end

  defp load_publishing_groups_for_tabs do
    alias PhoenixKit.Settings

    publishing_enabled = Settings.get_boolean_setting("publishing_enabled", false)

    if publishing_enabled do
      alias PhoenixKit.Modules.Publishing.DBStorage

      DBStorage.list_groups()
      |> Enum.map(fn g -> %{"name" => g.name, "slug" => g.slug} end)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[Publishing] load_publishing_groups_for_tabs failed: #{inspect(e)}")
      []
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
  Returns all publishing groups from the database.
  """
  @spec list_groups() :: [group()]
  def list_groups do
    DBStorage.list_groups()
    |> Enum.map(fn group -> group |> fix_stale_group() |> db_group_to_map() end)
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
      * `:mode` - Post mode: "timestamp" or "slug" (default: "timestamp")
      * `:slug` - Optional custom slug, auto-generated from name if nil
      * `:type` - Content type: "blog", "faq", "legal", or custom (default: "blog")
      * `:item_singular` - Singular name for items (default: based on type, e.g., "post")
      * `:item_plural` - Plural name for items (default: based on type, e.g., "posts")

  ## Examples

      iex> Publishing.add_group("News")
      {:ok, %{"name" => "News", "slug" => "news", "mode" => "timestamp", "type" => "blog", ...}}

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

          {default_singular, default_plural} = default_item_names(normalized_type)

          item_singular =
            opts
            |> fetch_option(:item_singular)
            |> normalize_item_name(default_singular)

          item_plural =
            opts
            |> fetch_option(:item_plural)
            |> normalize_item_name(default_plural)

          db_attrs = %{
            name: trimmed,
            slug: slug,
            mode: mode,
            data: %{
              "type" => normalized_type,
              "item_singular" => item_singular,
              "item_plural" => item_plural
            }
          }

          case DBStorage.create_group(db_attrs) do
            {:ok, db_group} ->
              group = db_group_to_map(db_group)
              PublishingPubSub.broadcast_group_created(group)
              {:ok, group}

            {:error, _changeset} ->
              {:error, :already_exists}
          end
        end
    end
  end

  @doc """
  Removes a publishing group by slug.
  """
  @spec remove_group(String.t()) :: {:ok, any()} | {:error, any()}
  def remove_group(slug) when is_binary(slug) do
    remove_group(slug, force: false)
  end

  @doc """
  Removes a publishing group by slug.

  By default, refuses to delete groups that contain posts.
  Pass `force: true` to cascade-delete the group and all its posts.
  """
  def remove_group(slug, opts) when is_binary(slug) do
    force = Keyword.get(opts, :force, false)

    case DBStorage.get_group_by_slug(slug) do
      nil ->
        {:error, :not_found}

      db_group ->
        post_count = DBStorage.count_posts(db_group.slug)

        if post_count > 0 and not force do
          {:error, {:has_posts, post_count}}
        else
          case DBStorage.delete_group(db_group) do
            {:ok, _} ->
              ListingCache.invalidate(slug)
              PublishingPubSub.broadcast_group_deleted(slug)
              {:ok, slug}

            error ->
              error
          end
        end
    end
  end

  @doc """
  Updates a publishing group's display name and slug.
  """
  @spec update_group(String.t(), map() | keyword()) :: {:ok, group()} | {:error, atom()}
  def update_group(slug, params) when is_binary(slug) do
    case DBStorage.get_group_by_slug(slug) do
      nil ->
        {:error, :not_found}

      db_group ->
        with {:ok, name} <- extract_and_validate_name(db_group, params),
             {:ok, sanitized_slug} <- extract_and_validate_slug(db_group, params, name) do
          case DBStorage.update_group(db_group, %{name: name, slug: sanitized_slug}) do
            {:ok, updated} ->
              group = db_group_to_map(updated)
              PublishingPubSub.broadcast_group_updated(group)
              {:ok, group}

            {:error, _} = error ->
              error
          end
        end
    end
  end

  defp extract_and_validate_name(db_group, params) do
    name =
      params
      |> fetch_option(:name)
      |> case do
        nil -> db_group.name
        value -> String.trim(to_string(value || ""))
      end

    if name == "", do: {:error, :invalid_name}, else: {:ok, name}
  end

  defp extract_and_validate_slug(db_group, params, name) do
    desired_slug =
      params
      |> fetch_option(:slug)
      |> case do
        nil -> db_group.slug
        value -> String.trim(to_string(value || ""))
      end

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

  @doc """
  Removes a publishing group and all its posts.
  """
  @spec trash_group(String.t()) :: {:ok, String.t()} | {:error, any()}
  def trash_group(slug) when is_binary(slug) do
    remove_group(slug)
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
  Returns the configured post mode for a publishing group slug.
  """
  @spec get_group_mode(String.t()) :: String.t()
  def get_group_mode(group_slug) do
    list_groups()
    |> Enum.find(%{}, &(&1["slug"] == group_slug))
    |> Map.get("mode", @default_group_mode)
  end

  # ===========================================================================
  # Stale Value Correction
  # ===========================================================================

  @valid_group_modes ["timestamp", "slug"]
  @valid_post_statuses ["draft", "published", "archived", "scheduled"]
  @valid_version_statuses ["draft", "published", "archived"]

  @doc """
  Fixes stale or invalid values on a publishing group record.

  Checks and corrects:
  - `mode` — must be "timestamp" or "slug" (defaults to "timestamp")
  - `data.type` — must be in valid_types (defaults to "custom")
  - `data.item_singular` — must be a non-empty string (defaults based on type)
  - `data.item_plural` — must be a non-empty string (defaults based on type)

  Can be called explicitly or runs lazily when groups are loaded in the admin.
  Returns the group unchanged if no fixes are needed.
  """
  @spec fix_stale_group(PublishingGroup.t()) :: PublishingGroup.t()
  def fix_stale_group(%PublishingGroup{} = group) do
    attrs = build_group_fixes(group)
    apply_stale_fix(group, attrs, &DBStorage.update_group/2)
  end

  defp build_group_fixes(group) do
    data = group.data || %{}
    type = Map.get(data, "type", @default_group_type)
    fixed_type = if type in @valid_types, do: type, else: "custom"
    fixed_mode = if group.mode in @valid_group_modes, do: group.mode, else: @default_group_mode

    {default_singular, default_plural} = default_item_names(fixed_type)
    item_singular = Map.get(data, "item_singular")
    item_plural = Map.get(data, "item_plural")

    fixed_singular = valid_string_or_default(item_singular, default_singular)
    fixed_plural = valid_string_or_default(item_plural, default_plural)

    data_changes =
      data
      |> maybe_update("type", type, fixed_type)
      |> maybe_update("item_singular", item_singular, fixed_singular)
      |> maybe_update("item_plural", item_plural, fixed_plural)

    attrs = if data_changes != data, do: %{data: data_changes}, else: %{}
    if fixed_mode != group.mode, do: Map.put(attrs, :mode, fixed_mode), else: attrs
  end

  defp valid_string_or_default(val, default) do
    if is_binary(val) and val != "", do: val, else: default
  end

  @doc """
  Fixes stale or invalid values on a publishing post record.

  Checks and corrects:
  - `primary_language` — must be a recognized language code. Resolution order:
    1. Tries to resolve a dialect (e.g., "en" → "en-US")
    2. Falls back to the first available language on the post
    3. Falls back to the system primary language
  - `status` — must be a valid post status (defaults to "draft")
  - `mode` — must be "timestamp" or "slug" (defaults to "timestamp")
  - `post_date`/`post_time` — must be present for timestamp mode posts

  Only fixes languages not in the master predefined list — languages that were
  added, used, then removed from enabled are left untouched.
  """
  @spec fix_stale_post(PublishingPost.t()) :: PublishingPost.t()
  def fix_stale_post(%PublishingPost{} = post) do
    attrs = build_post_fixes(post)
    apply_stale_fix(post, attrs, &DBStorage.update_post/2)
  end

  defp build_post_fixes(post) do
    %{}
    |> maybe_fix_post_language(post)
    |> maybe_fix_post_status(post)
    |> maybe_fix_post_mode(post)
    |> maybe_fix_post_timestamp(post)
  end

  defp maybe_fix_post_language(attrs, post) do
    case fix_stale_language(post) do
      nil -> attrs
      fixed_lang -> Map.put(attrs, :primary_language, fixed_lang)
    end
  end

  defp maybe_fix_post_status(attrs, post) do
    if post.status in @valid_post_statuses, do: attrs, else: Map.put(attrs, :status, "draft")
  end

  defp maybe_fix_post_mode(attrs, post) do
    fixed_mode = if post.mode in @valid_group_modes, do: post.mode, else: @default_group_mode
    if fixed_mode != post.mode, do: Map.put(attrs, :mode, fixed_mode), else: attrs
  end

  defp maybe_fix_post_timestamp(attrs, post) do
    if (attrs[:mode] || post.mode) == "timestamp" do
      now = DateTime.utc_now()

      attrs
      |> then(fn a ->
        if is_nil(post.post_date), do: Map.put(a, :post_date, DateTime.to_date(now)), else: a
      end)
      |> then(fn a ->
        if is_nil(post.post_time),
          do: Map.put(a, :post_time, Time.new!(now.hour, now.minute, 0)),
          else: a
      end)
    else
      attrs
    end
  end

  # Returns the fixed language or nil if no fix needed.
  defp fix_stale_language(post) do
    lang = post.primary_language

    if lang && Languages.get_predefined_language(lang) do
      nil
    else
      fixed = resolve_stale_language(lang, post)
      if fixed != lang, do: fixed, else: nil
    end
  end

  defp resolve_stale_language(lang, post) do
    dialect = if lang, do: Languages.DialectMapper.base_to_dialect(lang), else: nil

    if dialect && Languages.get_predefined_language(dialect) do
      dialect
    else
      available = post_available_languages(post)

      if available != [] do
        Enum.find(available, hd(available), fn code ->
          Languages.get_predefined_language(code) != nil
        end)
      else
        LanguageHelpers.get_primary_language()
      end
    end
  end

  defp post_available_languages(post) do
    case DBStorage.list_versions(post.uuid) do
      [] -> []
      versions -> DBStorage.list_languages(hd(versions).uuid)
    end
  end

  defp apply_stale_fix(record, attrs, _update_fn) when attrs == %{}, do: record

  defp apply_stale_fix(record, attrs, update_fn) do
    identifier = Map.get(record, :uuid) || Map.get(record, :slug) || "unknown"

    Logger.info(
      "[Publishing] Fixing stale values for #{record.__struct__} #{identifier}: #{inspect(attrs)}"
    )

    case update_fn.(record, attrs) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning(
          "[Publishing] Failed to fix stale values for #{identifier}: #{inspect(reason)}"
        )

        record
    end
  end

  defp maybe_update(data, key, old_val, new_val) do
    if old_val != new_val, do: Map.put(data, key, new_val), else: data
  end

  @doc """
  Fixes stale values across all groups, posts, versions, and content.
  Also reconciles status consistency between posts, versions, and content.
  Callable via internal API or IEx.
  """
  @spec fix_all_stale_values() :: :ok
  def fix_all_stale_values do
    groups = DBStorage.list_groups()
    Enum.each(groups, &fix_stale_group/1)

    for group <- groups do
      posts = DBStorage.list_posts(group.slug)
      Enum.each(posts, &fix_stale_post/1)

      # Fix versions, content, and status consistency for each post
      for post <- posts do
        versions = DBStorage.list_versions(post.uuid)

        for version <- versions do
          fix_stale_version(version)

          contents = DBStorage.list_contents(version.uuid)
          Enum.each(contents, &fix_stale_content/1)
        end

        # Reconcile status consistency after individual fixes
        reconcile_post_status(post)
      end
    end

    :ok
  end

  @doc false
  def fix_stale_version(version) do
    if version.status not in @valid_version_statuses do
      Logger.info(
        "[Publishing] Fixing stale version #{version.uuid}: status #{inspect(version.status)} → \"draft\""
      )

      DBStorage.update_version(version, %{status: "draft"})
    end
  end

  @doc false
  def fix_stale_content(content) do
    attrs =
      %{}
      |> maybe_fix_content_status(content)
      |> maybe_fix_content_language(content)

    if attrs != %{} do
      Logger.info(
        "[Publishing] Fixing stale content #{content.uuid} (#{content.language}): #{inspect(attrs)}"
      )

      DBStorage.update_content(content, attrs)
    end
  end

  defp maybe_fix_content_status(attrs, content) do
    if content.status in @valid_version_statuses,
      do: attrs,
      else: Map.put(attrs, :status, "draft")
  end

  defp maybe_fix_content_language(attrs, content) do
    if is_binary(content.language) and content.language != "" do
      attrs
    else
      Map.put(attrs, :language, LanguageHelpers.get_primary_language())
    end
  end

  # Reconciles status consistency between a post, its versions, and content.
  #
  # Rules enforced:
  # 1. Post "published" requires at least one "published" version → else demote to "draft"
  # 2. Version "published" requires its post to be "published" → else archive the version
  # 3. Content "published" requires its version to be "published" → else demote to "draft"
  # 4. Non-published versions cannot have "published" content → demote content to "draft"
  #
  # Note: individual translations CAN be "draft" while the version is "published" —
  # this is the normal state for untranslated languages. We only fix content that
  # claims to be "published" when it shouldn't be.
  @doc false
  def reconcile_post_status(%PublishingPost{} = post) do
    # Re-read to get current state after individual fixes
    post = DBStorage.get_post_by_uuid(post.uuid) || post
    versions = DBStorage.list_versions(post.uuid)

    published_versions = Enum.filter(versions, &(&1.status == "published"))

    cond do
      # Post says published but no version backs it up
      post.status == "published" and published_versions == [] ->
        Logger.info(
          "[Publishing] Reconcile: post #{post.uuid} is published but has no published versions, demoting to draft"
        )

        DBStorage.update_post(post, %{status: "draft"})

      # Post is not published but a version claims to be — archive the version
      post.status in ["draft", "archived"] and published_versions != [] ->
        Logger.info(
          "[Publishing] Reconcile: post #{post.uuid} is #{inspect(post.status)} but has #{length(published_versions)} published versions, archiving"
        )

        for v <- published_versions do
          DBStorage.update_version(v, %{status: "archived"})
          demote_published_content(v.uuid)
        end

      true ->
        :ok
    end

    # For ALL non-published versions, no content should be "published"
    non_published_versions = Enum.reject(versions, &(&1.status == "published"))

    for v <- non_published_versions do
      demote_published_content(v.uuid)
    end
  end

  # Demotes any "published" content rows to "draft" within a version.
  # Leaves "draft" and "archived" content untouched.
  defp demote_published_content(version_uuid) do
    contents = DBStorage.list_contents(version_uuid)
    published = Enum.filter(contents, &(&1.status == "published"))

    if published != [] do
      Logger.info(
        "[Publishing] Demoting #{length(published)} published content row(s) to \"draft\" in version #{version_uuid}"
      )

      for content <- published do
        DBStorage.update_content(content, %{status: "draft"})
      end
    end
  end

  @doc """
  Lists posts for a given publishing group slug.

  Queries the database directly via DBStorage.
  The optional second argument is accepted for API compatibility but unused.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [map()]
  def list_posts(group_slug, _preferred_language \\ nil) do
    DBStorage.list_posts_with_metadata(group_slug)
  end

  @doc """
  Creates a new post for the given publishing group using the current timestamp.
  """
  @spec create_post(String.t(), map() | keyword()) :: {:ok, map()} | {:error, any()}
  def create_post(group_slug, opts \\ %{}) do
    create_post_in_db(group_slug, opts)
  end

  defp create_post_in_db(group_slug, opts) do
    scope = fetch_option(opts, :scope)
    group = DBStorage.get_group_by_slug(group_slug) || sync_group_to_db(group_slug)
    unless group, do: throw({:error, :group_not_found})

    mode = get_group_mode(group_slug)
    primary_language = LanguageHelpers.get_primary_language()
    now = UtilsDate.utc_now()

    # Resolve user UUID for audit
    created_by_uuid = resolve_scope_user_uuids(scope)

    # Generate slug for slug-mode groups
    slug_result =
      case mode do
        "slug" ->
          title = fetch_option(opts, :title)
          preferred_slug = fetch_option(opts, :slug)
          SlugHelpers.generate_unique_slug(group_slug, title || "", preferred_slug)

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
        updated_by_uuid: created_by_uuid
      }

      # Add date/time for timestamp mode (truncate seconds since URLs use HH:MM only)
      post_attrs =
        if mode == "timestamp" do
          date = DateTime.to_date(now)
          time = %Time{hour: now.hour, minute: now.minute, second: 0, microsecond: {0, 0}}

          # Find next available minute if this one is taken
          {date, time} = find_available_timestamp(group_slug, date, time)

          Map.merge(post_attrs, %{
            post_date: date,
            post_time: time
          })
        else
          post_attrs
        end

      repo = PhoenixKit.RepoHelper.repo()

      tx_result =
        repo.transaction(fn ->
          with {:ok, db_post} <- DBStorage.create_post(post_attrs),
               {:ok, db_version} <-
                 DBStorage.create_version(%{
                   post_uuid: db_post.uuid,
                   version_number: 1,
                   status: "draft",
                   created_by_uuid: created_by_uuid
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
            db_post
          else
            {:error, reason} -> repo.rollback(reason)
          end
        end)

      with {:ok, db_post} <- tx_result do
        # Read back via mapper to get a proper post map with UUID
        read_result =
          if mode == "timestamp" do
            DBStorage.read_post_by_datetime(
              group_slug,
              db_post.post_date,
              db_post.post_time,
              primary_language,
              1
            )
          else
            DBStorage.read_post(group_slug, db_post.slug, primary_language, 1)
          end

        case read_result do
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
    {:error, reason} ->
      Logger.warning("[Publishing] create_post failed for #{group_slug}: #{inspect(reason)}")
      {:error, reason}
  end

  defp resolve_scope_user_uuids(nil), do: nil

  defp resolve_scope_user_uuids(scope) do
    Scope.user_uuid(scope)
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
        db_post = fix_stale_post(db_post)
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
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("[Publishing] read_post_by_uuid failed for #{post_uuid}: #{inspect(e)}")
      {:error, :not_found}
  end

  @doc """
  Reads an existing post.

  For slug-mode groups, accepts an optional version parameter.
  If version is nil, reads the latest version.

  Reads from the database.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, map()} | {:error, any()}
  def read_post(group_slug, identifier, language \\ nil, version \\ nil) do
    read_post_from_db(group_slug, identifier, language, version)
  end

  defp read_post_from_db(group_slug, identifier, language, version) do
    # If identifier is a UUID, resolve via UUID lookup (handles both modes)
    if uuid_format?(identifier) do
      read_post_by_uuid(identifier, language, version)
    else
      case get_group_mode(group_slug) do
        "timestamp" ->
          read_post_from_db_timestamp(group_slug, identifier, language, version)

        _ ->
          read_post_from_db_slug(group_slug, identifier, language, version)
      end
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

  defp normalize_version_number(v) when is_integer(v) and v > 0, do: v
  defp normalize_version_number(v) when is_integer(v), do: nil

  defp normalize_version_number(v) do
    case Integer.parse("#{v}") do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  # Finds the next available minute for a timestamp-mode post.
  # If the given date/time is already taken, bumps forward by one minute at a time.
  # Limited to 60 attempts to prevent unbounded recursion.
  @max_timestamp_attempts 60

  defp find_available_timestamp(group_slug, date, time, attempts \\ 0)

  defp find_available_timestamp(_group_slug, date, time, @max_timestamp_attempts) do
    {date, time}
  end

  defp find_available_timestamp(group_slug, date, time, attempts) do
    case DBStorage.get_post_by_datetime(group_slug, date, time) do
      nil ->
        {date, time}

      _existing ->
        # Bump by one minute
        total_seconds = time.hour * 3600 + time.minute * 60 + 60

        if total_seconds >= 86_400 do
          # Rolled past midnight — advance to next day at 00:00
          next_date = Date.add(date, 1)
          find_available_timestamp(group_slug, next_date, ~T[00:00:00], attempts + 1)
        else
          next_hour = div(total_seconds, 3600)
          next_minute = div(rem(total_seconds, 3600), 60)
          next_time = %Time{hour: next_hour, minute: next_minute, second: 0, microsecond: {0, 0}}
          find_available_timestamp(group_slug, date, next_time, attempts + 1)
        end
    end
  end

  # Parses timestamp paths like "2026-01-24/04:13/v7/sq" or "2026-01-24/04:13"
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
              lang_code -> lang_code
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

  # Adds a language to a post.
  # Creates a new content row in the database and returns the post map.
  @doc false
  def add_language_to_db(group_slug, post_uuid, language_code, version_number) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
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
      # Read the post back from DB to return a proper post map
      read_back_post(group_slug, post_uuid, db_post, language_code, version.version_number)
    else
      nil ->
        {:error, :not_found}

      %PhoenixKit.Modules.Publishing.PublishingContent{} ->
        # Content already exists for this language - just read the post
        read_back_post(group_slug, post_uuid, nil, language_code, version_number)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning(
        "[Publishing] add_language_to_db failed for #{group_slug}/#{post_uuid}/#{language_code}: #{inspect(e)}"
      )

      {:error, :not_found}
  end

  defp uuid_format?(str) when is_binary(str), do: match?({:ok, _}, UUIDv7.cast(str))
  defp uuid_format?(_), do: false

  # Reads a post back from DB using the appropriate method for the group mode.
  # When db_post is nil and identifier is a UUID, fetches the post from DB first
  # to get its slug, avoiding the bug where a UUID would be used as a slug lookup.
  defp read_back_post(group_slug, identifier, db_post, language, version_number) do
    cond do
      db_post && db_post.mode == "timestamp" && db_post.post_date && db_post.post_time ->
        DBStorage.read_post_by_datetime(
          group_slug,
          db_post.post_date,
          db_post.post_time,
          language,
          version_number
        )

      match?({:ok, _, _, _, _}, is_binary(identifier) && parse_timestamp_path(identifier)) ->
        {:ok, date, time, _v, _l} = parse_timestamp_path(identifier)
        DBStorage.read_post_by_datetime(group_slug, date, time, language, version_number)

      true ->
        slug = resolve_slug(identifier, db_post)
        DBStorage.read_post(group_slug, slug, language, version_number)
    end
  end

  # Resolves the slug for read_back_post. When db_post is nil and the identifier
  # is a UUID, looks up the post to get its actual slug.
  defp resolve_slug(identifier, db_post) do
    cond do
      db_post -> db_post.slug
      is_binary(identifier) && uuid_format?(identifier) -> uuid_to_slug(identifier)
      true -> identifier
    end
  end

  defp uuid_to_slug(uuid) do
    case DBStorage.get_post_by_uuid(uuid, []) do
      %{slug: slug} -> slug
      _ -> uuid
    end
  end

  # Updates a post in the database.
  # Writes directly to the database and returns the updated post map.
  defp update_post_in_db(group_slug, post, params, _audit_meta) do
    db_post = find_db_post_for_update(group_slug, post)

    if db_post do
      if post[:mode] == :timestamp || db_post.mode == "timestamp" do
        # Timestamp-mode posts don't have slugs — skip slug validation
        do_update_post_in_db(db_post, post, params, group_slug, nil)
      else
        # Handle slug changes
        desired_slug = Map.get(params, "slug", post.slug)

        case maybe_update_db_slug(db_post, desired_slug, group_slug) do
          {:ok, final_slug} ->
            do_update_post_in_db(db_post, post, params, group_slug, final_slug)

          {:error, _reason} = error ->
            error
        end
      end
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[Publishing] update_post_in_db failed: #{inspect(e)}")
      {:error, :db_update_failed}
  end

  # Find the DB post record for update, using UUID, date/time, or slug as available
  defp find_db_post_for_update(group_slug, post) do
    cond do
      # If we have a UUID, use it directly (most reliable)
      post[:uuid] ->
        DBStorage.get_post_by_uuid(post[:uuid], [:group])

      # Timestamp-mode: use date/time
      post[:mode] == :timestamp && post[:date] && post[:time] ->
        DBStorage.get_post_by_datetime(group_slug, post[:date], post[:time])

      # Slug-mode: use slug
      post[:slug] ->
        DBStorage.get_post(group_slug, post[:slug])

      true ->
        nil
    end
  end

  defp maybe_update_db_slug(db_post, desired_slug, _group_slug)
       when desired_slug == db_post.slug do
    {:ok, db_post.slug}
  end

  defp maybe_update_db_slug(db_post, desired_slug, group_slug) do
    with {:ok, valid_slug} <- SlugHelpers.validate_slug(desired_slug),
         false <- SlugHelpers.slug_exists?(group_slug, valid_slug),
         {:ok, _} <- DBStorage.update_post(db_post, %{slug: valid_slug}) do
      {:ok, valid_slug}
    else
      true ->
        {:error, :slug_already_exists}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :slug),
          do: {:error, :slug_already_exists},
          else: {:error, :db_update_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_update_post_in_db(db_post, post, params, group_slug, final_slug) do
    version_number = post[:version] || 1
    version = DBStorage.get_version(db_post.uuid, version_number)

    if version do
      language = post[:language] || db_post.primary_language
      post_metadata = post[:metadata] || %{}
      new_status = Map.get(params, "status", post_metadata[:status] || "draft")
      content = Map.get(params, "content", post[:content] || "")
      new_title = resolve_post_title(params, post, content)

      # Title is required for primary language when publishing (drafts can be untitled)
      if language == db_post.primary_language and new_status == "published" and
           new_title in ["", "Untitled"] do
        throw({:post_update_failed, :title_required})
      end

      # Capture old status from DB before updating (editor assigns may already reflect new status)
      old_db_status = db_post.status

      update_post_level_fields!(db_post, new_status, params)
      upsert_post_content(version, language, new_title, content, new_status, params, post)
      maybe_propagate_status(version, language, db_post, new_status, old_db_status)

      if db_post.mode == "timestamp" do
        DBStorage.read_post_by_datetime(
          group_slug,
          db_post.post_date,
          db_post.post_time,
          language,
          version_number
        )
      else
        DBStorage.read_post(group_slug, final_slug, language, version_number)
      end
    else
      {:error, :not_found}
    end
  catch
    {:post_update_failed, reason} ->
      Logger.warning("[Publishing] update_post failed for #{group_slug}: #{inspect(reason)}")
      {:error, reason}
  end

  defp resolve_post_title(params, post, content) do
    extracted_title = Metadata.extract_title_from_content(content)
    post_metadata = post[:metadata] || %{}

    Map.get(params, "title") ||
      if(extracted_title != "Untitled", do: extracted_title) ||
      post_metadata[:title] ||
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

    case DBStorage.upsert_content(%{
           version_uuid: version.uuid,
           language: language,
           title: new_title,
           content: content,
           status: new_status,
           url_slug: resolved_url_slug,
           data: build_content_data(params, post, existing_data)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> throw({:post_update_failed, reason})
    end
  end

  defp maybe_propagate_status(version, language, db_post, new_status, old_db_status) do
    is_primary = language == db_post.primary_language

    if is_primary and new_status != old_db_status do
      propagate_db_status_to_translations(version.uuid, language, new_status)
    end
  end

  # Propagates a status change from the primary language to all other translations
  defp update_primary_language_in_db(post_uuid, new_primary_language) do
    case DBStorage.get_post_by_uuid(post_uuid) do
      nil ->
        {:error, :post_not_found}

      db_post ->
        case DBStorage.update_post(db_post, %{primary_language: new_primary_language}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] update_primary_language_in_db failed for #{post_uuid}: #{inspect(e)}"
      )

      {:error, :post_not_found}
  end

  defp resolve_db_version(db_post, nil), do: DBStorage.get_latest_version(db_post.uuid)

  defp resolve_db_version(db_post, version_number),
    do: DBStorage.get_version(db_post.uuid, version_number)

  defp propagate_db_status_to_translations(version_uuid, primary_language, new_status) do
    DBStorage.update_content_status_except(version_uuid, primary_language, new_status)
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
      case Map.get(params, "featured_image_uuid") do
        nil -> data
        id -> Map.put(data, "featured_image_uuid", id)
      end

    post_metadata = post[:metadata] || %{}

    case Map.get(params, "description", post_metadata[:description]) do
      nil -> data
      desc -> Map.put(data, "description", desc)
    end
  end

  @doc """
  Updates a post in the database.
  """
  @spec update_post(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, any()}
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
  @spec create_new_version(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, any()}
  def create_new_version(group_slug, source_post, params \\ %{}, opts \\ %{}) do
    source_version = source_post[:version] || 1
    create_version_in_db(group_slug, source_post[:uuid], source_version, params, opts)
  end

  @doc """
  Publishes a version, making it the only published version.

  - All content in the target version (primary and translations) → `status: "published"`
  - All content in other versions that were "published" → `status: "archived"`
  - Draft/archived content in other versions keeps its current status

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
  def publish_version(group_slug, post_uuid, version, opts \\ []) do
    db_post = DBStorage.get_post_by_uuid(post_uuid, [:group])
    unless db_post, do: throw({:error, :not_found})

    # Wrap the entire publish operation in a transaction for atomicity
    repo = PhoenixKit.RepoHelper.repo()

    tx_result =
      repo.transaction(fn ->
        # Validate target version exists
        versions = DBStorage.list_versions(db_post.uuid)

        unless Enum.any?(versions, &(&1.version_number == version)) do
          repo.rollback(:version_not_found)
        end

        # Set target version to published, archive previously-published versions
        # Also update content status to match so public rendering works correctly
        update_version_statuses!(repo, versions, version)

        # Update post status and published_at
        update_post_published!(repo, db_post)
      end)

    case tx_result do
      {:ok, _} ->
        source_id = Keyword.get(opts, :source_id)
        broadcast_id = db_post.slug || db_post.uuid
        ListingCache.regenerate(group_slug)
        PublishingPubSub.broadcast_version_live_changed(group_slug, broadcast_id, version)

        PublishingPubSub.broadcast_post_version_published(
          group_slug,
          broadcast_id,
          version,
          source_id
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  catch
    {:error, reason} = err ->
      Logger.warning(
        "[Publishing] publish_version failed for #{group_slug}/#{post_uuid}/v#{version}: #{inspect(reason)}"
      )

      err
  end

  defp update_version_statuses!(repo, versions, target_version) do
    for v <- versions do
      new_status =
        cond do
          v.version_number == target_version -> "published"
          v.status == "published" -> "archived"
          true -> v.status
        end

      if new_status != v.status do
        case DBStorage.update_version(v, %{status: new_status}) do
          {:ok, _} -> :ok
          {:error, reason} -> repo.rollback(reason)
        end

        DBStorage.update_content_status(v.uuid, new_status)
      end
    end
  end

  defp update_post_published!(repo, db_post) do
    case DBStorage.update_post(db_post, %{
           status: "published",
           published_at: db_post.published_at || UtilsDate.utc_now()
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> repo.rollback(reason)
    end
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
          {:ok, map()} | {:error, any()}
  def create_version_from(group_slug, post_uuid, source_version, params \\ %{}, opts \\ %{}) do
    create_version_in_db(group_slug, post_uuid, source_version, params, opts)
  end

  defp create_version_in_db(group_slug, post_uuid, source_version, _params, opts) do
    db_post = DBStorage.get_post_by_uuid(post_uuid, [:group])
    unless db_post, do: throw({:error, :post_not_found})

    scope = fetch_option(opts, :scope)
    created_by_uuid = resolve_scope_user_uuids(scope)

    user_opts = %{created_by_uuid: created_by_uuid}

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
                 created_by_uuid: created_by_uuid
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
      case read_back_post(group_slug, post_uuid, db_post, nil, db_version.version_number) do
        {:ok, post} ->
          broadcast_id = db_post.slug || db_post.uuid
          broadcast_version_created(group_slug, broadcast_id, post)
          {:ok, post}

        {:error, _} = err ->
          err
      end
    end
  catch
    {:error, reason} ->
      Logger.warning(
        "[Publishing] create_version failed for #{group_slug}/#{post_uuid}: #{inspect(reason)}"
      )

      {:error, reason}
  end

  @doc false
  def broadcast_version_created(group_slug, broadcast_id, new_version) do
    PublishingPubSub.broadcast_version_created(group_slug, new_version)

    version_info = %{
      version: new_version[:current_version] || new_version[:version],
      available_versions: new_version[:available_versions] || []
    }

    PublishingPubSub.broadcast_post_version_created(group_slug, broadcast_id, version_info)
  end

  @doc """
  Sets a translation's status and marks it as manually overridden.

  When a translation status is set manually, it will NOT inherit status
  changes from the primary language when publishing.

  Accepts a post UUID or slug as the post identifier.

  ## Examples

      iex> Publishing.set_translation_status("blog", "019cce93-...", 2, "es", "draft")
      :ok
  """
  @spec set_translation_status(String.t(), String.t(), integer(), String.t(), String.t()) ::
          :ok | {:error, any()}
  def set_translation_status(group_slug, post_identifier, version, language, status)
      when status in ["draft", "published", "archived"] do
    db_post =
      if uuid_format?(post_identifier) do
        DBStorage.get_post_by_uuid(post_identifier)
      else
        DBStorage.get_post(group_slug, post_identifier)
      end

    with db_post when not is_nil(db_post) <- db_post,
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

  def set_translation_status(_group_slug, _post_identifier, _version, _language, _status) do
    {:error, :invalid_status}
  end

  @doc """
  Adds a new language translation to an existing post.

  Accepts an optional version parameter to specify which version to add
  the translation to. If not specified, defaults to the latest version.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, map()} | {:error, any()}
  def add_language_to_post(group_slug, post_uuid, language_code, version \\ nil) do
    result = add_language_to_db(group_slug, post_uuid, language_code, version)

    with {:ok, new_post} <- result do
      if should_regenerate_cache?(new_post) do
        ListingCache.regenerate(group_slug)
      end

      broadcast_id = new_post.slug || new_post.uuid

      if broadcast_id do
        PublishingPubSub.broadcast_translation_created(group_slug, broadcast_id, language_code)
      end
    end

    result
  end

  @doc """
  Soft-deletes a post by UUID.

  Returns {:ok, post_uuid} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_post(group_slug, post_uuid) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        {:error, :not_found}

      db_post ->
        case DBStorage.soft_delete_post(db_post) do
          {:ok, _} ->
            broadcast_id = db_post.slug || db_post.uuid
            ListingCache.regenerate(group_slug)
            PublishingPubSub.broadcast_post_deleted(group_slug, broadcast_id)
            {:ok, post_uuid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Deletes a specific language translation from a post.

  For versioned posts, specify the version. For unversioned posts, version is ignored.
  Refuses to delete the last remaining language content.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_language(String.t(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, term()}
  def delete_language(group_slug, post_uuid, language_code, version \\ nil) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         db_version when not is_nil(db_version) <- resolve_db_version(db_post, version),
         content when not is_nil(content) <- DBStorage.get_content(db_version.uuid, language_code) do
      # Don't delete the last active language
      active =
        DBStorage.list_contents(db_version.uuid)
        |> Enum.reject(&(&1.status == "archived"))

      if length(active) <= 1, do: throw({:error, :last_language})

      case DBStorage.update_content(content, %{status: "archived"}) do
        {:ok, _} ->
          broadcast_id = db_post.slug || db_post.uuid
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_translation_deleted(group_slug, broadcast_id, language_code)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  catch
    {:error, reason} = err ->
      Logger.warning(
        "[Publishing] delete_language failed for #{group_slug}/#{post_uuid}/#{language_code}: #{inspect(reason)}"
      )

      err
  end

  @doc """
  Deletes an entire version of a post.

  Archives the version instead of permanent deletion.
  Refuses to delete the last remaining version or the live version.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_version(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def delete_version(group_slug, post_uuid, version) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         db_version when not is_nil(db_version) <- DBStorage.get_version(db_post.uuid, version) do
      if db_version.status == "published", do: throw({:error, :cannot_delete_live})

      active =
        DBStorage.list_versions(db_post.uuid)
        |> Enum.reject(&(&1.status == "archived"))

      if length(active) <= 1, do: throw({:error, :last_version})

      broadcast_id = db_post.slug || db_post.uuid

      case DBStorage.update_version(db_version, %{status: "archived"}) do
        {:ok, _} ->
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_version_deleted(group_slug, broadcast_id, version)
          PublishingPubSub.broadcast_post_version_deleted(group_slug, broadcast_id, version)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  catch
    {:error, reason} = err ->
      Logger.warning(
        "[Publishing] delete_version failed for #{group_slug}/#{post_uuid}/v#{version}: #{inspect(reason)}"
      )

      err
  end

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
        e ->
          Logger.debug(
            "[Publishing] reserved_language_code? check failed, assuming no reserved codes: #{inspect(e)}"
          )

          []
      end

    slug in language_codes
  end

  # Determines if a post update should trigger cache regeneration.
  # For versioned posts (slug mode with version info), only regenerate if the post is published.
  # For non-versioned posts (timestamp mode), always regenerate.
  defp should_regenerate_cache?(post) do
    mode = Map.get(post, :mode)
    metadata = Map.get(post, :metadata, %{})
    status = Map.get(metadata, :status)
    version = Map.get(metadata, :version) || Map.get(post, :version)

    cond do
      # Timestamp mode posts always regenerate (no versioning)
      mode == :timestamp -> true
      # Slug mode posts without version info always regenerate
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
    case PhoenixKit.Config.get(:publishing_settings_module) do
      :not_found -> PhoenixKit.Settings
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

  # Syncs a group from Settings JSON to the DB table.
  # Returns the DB group struct or nil if the group doesn't exist in Settings.
  defp sync_group_to_db(group_slug) do
    case get_group(group_slug) do
      {:ok, group_data} ->
        case DBStorage.upsert_group(build_group_attrs(group_data)) do
          {:ok, db_group} -> db_group
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Builds the attrs map for DBStorage.upsert_group from a group settings map.
  defp build_group_attrs(group) do
    %{
      name: group["name"],
      slug: group["slug"],
      mode: group["mode"],
      data: %{
        "type" => group["type"],
        "item_singular" => group["item_singular"],
        "item_plural" => group["item_plural"]
      }
    }
  end

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
  """
  @spec preset_types() :: [map()]
  def preset_types do
    [
      %{type: "blog", label: "Blog", item_singular: "post", item_plural: "posts"},
      %{type: "faq", label: "FAQ", item_singular: "question", item_plural: "questions"},
      %{type: "legal", label: "Legal", item_singular: "document", item_plural: "documents"}
    ]
  end

  @doc """
  Returns the list of valid group type values.
  """
  @spec valid_types() :: [String.t()]
  def valid_types, do: @valid_types

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
    user_uuid =
      scope
      |> Scope.user_uuid()
      |> normalize_audit_value()

    user_email =
      scope
      |> Scope.user_email()
      |> normalize_audit_value()

    base =
      case action do
        :create ->
          %{
            created_by_uuid: user_uuid,
            created_by_email: user_email
          }

        _ ->
          %{}
      end

    base
    |> maybe_put_audit(:updated_by_uuid, user_uuid)
    |> maybe_put_audit(:updated_by_email, user_email)
  end

  defp normalize_audit_value(nil), do: nil
  defp normalize_audit_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_audit_value(value), do: to_string(value)

  defp maybe_put_audit(map, _key, nil), do: map
  defp maybe_put_audit(map, key, value), do: Map.put(map, key, value)

  defp db_group_to_map(%{name: name, slug: slug, mode: mode, data: data}) do
    %{
      "name" => name,
      "slug" => slug,
      "mode" => mode || @default_group_mode,
      "type" => Map.get(data, "type", @default_group_type),
      "item_singular" => Map.get(data, "item_singular", @default_item_singular),
      "item_plural" => Map.get(data, "item_plural", @default_item_plural)
    }
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
  #   - "post-slug/en" → {"post-slug", nil, "en"}
  #   - "post-slug/v1/en" → {"post-slug", 1, "en"}
  #   - "group/post-slug/v2/am" → {"post-slug", 2, "am"}
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
            lang_code -> lang_code
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
  3. Create or update translation content for each language

  ## Options

  - `:endpoint_uuid` - AI endpoint UUID to use for translation (required if not set in settings)
  - `:source_language` - Source language to translate from (defaults to primary language)
  - `:target_languages` - List of target language codes (defaults to all enabled except source)
  - `:version` - Version number to translate (defaults to latest/published)
  - `:user_uuid` - User UUID for audit trail

  ## Configuration

  Set the default AI endpoint for translations:

      PhoenixKit.Settings.update_setting("publishing_translation_endpoint_uuid", "endpoint-uuid")

  ## Examples

      # Translate to all enabled languages using default endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...")

      # Translate with specific endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...",
        endpoint_uuid: "endpoint-uuid"
      )

      # Translate to specific languages only
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...",
        endpoint_uuid: "endpoint-uuid",
        target_languages: ["es", "fr", "de"]
      )

  ## Returns

  - `{:ok, %Oban.Job{}}` - Job was successfully enqueued
  - `{:error, changeset}` - Failed to enqueue job

  """
  @spec translate_post_to_all_languages(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def translate_post_to_all_languages(group_slug, post_uuid, opts \\ []) do
    TranslatePostWorker.enqueue(group_slug, post_uuid, opts)
  end
end
