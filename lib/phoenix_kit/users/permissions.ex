defmodule PhoenixKit.Users.Permissions do
  @moduledoc """
  Context for module-level permissions in PhoenixKit.

  Controls which roles can access which admin sections and feature modules.
  Uses an allowlist model: row present = granted, absent = denied.
  Owner role always has full access (enforced in code, no DB rows needed).

  ## Permission Keys

  Core sections: dashboard, users, media, settings, modules
  Feature modules: billing, shop, emails, entities, tickets, posts, comments,
    ai, sync, publishing, referrals, sitemap, seo, maintenance, storage,
    languages, connections, legal, db, jobs

  ## Constants & Metadata

      Permissions.all_module_keys()        # 25 built-in + any custom keys
      Permissions.core_section_keys()      # 5 core keys
      Permissions.feature_module_keys()    # 20 feature keys
      Permissions.enabled_module_keys()    # Core + enabled features + custom keys
      Permissions.valid_module_key?("ai")  # true
      Permissions.feature_enabled?("ai")   # true/false based on module status
      Permissions.module_label("shop")     # "E-Commerce"
      Permissions.module_icon("shop")      # "hero-shopping-cart"
      Permissions.module_description("shop") # "Product catalog, orders, ..."

  ## Query API

      Permissions.get_permissions_for_user(user)        # User's keys via roles
      Permissions.get_permissions_for_role(role_id)      # Keys for a role
      Permissions.role_has_permission?(role_id, "billing") # Single check
      Permissions.get_permissions_matrix()               # All roles → MapSet
      Permissions.roles_with_permission("billing")       # Role IDs with key
      Permissions.users_with_permission("billing")       # User IDs with key
      Permissions.count_permissions_for_role(role_id)     # Efficient count
      Permissions.diff_permissions(role_a, role_b)        # Compare two roles

  ## Mutation API

      Permissions.grant_permission(role_id, "billing", granted_by_id)
      Permissions.revoke_permission(role_id, "billing")
      Permissions.set_permissions(role_id, ["dashboard", "users"], granted_by_id)
      Permissions.grant_all_permissions(role_id, granted_by_id)
      Permissions.revoke_all_permissions(role_id)
      Permissions.copy_permissions(source_role_id, target_role_id, granted_by_id)

  ## Custom Keys API

  Parent apps can register custom permission keys for custom admin tabs:

      Permissions.register_custom_key("analytics", label: "Analytics", icon: "hero-chart-bar")
      Permissions.unregister_custom_key("analytics")
      Permissions.custom_keys()              # List of registered custom key strings
      Permissions.custom_view_permissions()   # %{ViewModule => "key"} mapping

  Custom keys are always treated as "enabled" (no module toggle) and appear
  in the permission matrix UI under a "Custom" group.

  ## Edit Protection

      Permissions.can_edit_role_permissions?(scope, role) :: :ok | {:error, String.t()}

  Enforces: users cannot edit their own role, only Owner can edit Admin,
  system roles cannot have `is_system_role` changed.
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.ScopeNotifier

  @core_section_keys ~w(dashboard users media settings modules)
  @feature_module_keys ~w(
    billing shop emails entities tickets posts comments ai
    sync publishing referrals sitemap seo maintenance
    storage languages connections legal db jobs
  )
  @all_module_keys @core_section_keys ++ @feature_module_keys

  # Persistent term keys for runtime-registered custom permission keys
  @custom_keys_pterm {PhoenixKit, :custom_permission_keys}
  @custom_views_pterm {PhoenixKit, :custom_view_permissions}
  @valid_key_pattern ~r/^[a-z][a-z0-9_]*$/
  @max_key_length 50
  @max_custom_keys 50
  @max_label_length 100
  @max_icon_length 60
  @max_description_length 255

  # Maps feature module keys to their {Module, :enabled_function} for checking enabled status
  @feature_enabled_checks %{
    "billing" => {PhoenixKit.Modules.Billing, :enabled?},
    "shop" => {PhoenixKit.Modules.Shop, :enabled?},
    "emails" => {PhoenixKit.Modules.Emails, :enabled?},
    "entities" => {PhoenixKit.Modules.Entities, :enabled?},
    "tickets" => {PhoenixKit.Modules.Tickets, :enabled?},
    "posts" => {PhoenixKit.Modules.Posts, :enabled?},
    "comments" => {PhoenixKit.Modules.Comments, :enabled?},
    "ai" => {PhoenixKit.Modules.AI, :enabled?},
    "sync" => {PhoenixKit.Modules.Sync, :enabled?},
    "publishing" => {PhoenixKit.Modules.Publishing, :enabled?},
    "referrals" => {PhoenixKit.Modules.Referrals, :enabled?},
    "sitemap" => {PhoenixKit.Modules.Sitemap, :enabled?},
    "seo" => {PhoenixKit.Modules.SEO, :module_enabled?},
    "maintenance" => {PhoenixKit.Modules.Maintenance, :enabled?},
    "storage" => {PhoenixKit.Modules.Storage, :module_enabled?},
    "languages" => {PhoenixKit.Modules.Languages, :enabled?},
    "connections" => {PhoenixKit.Modules.Connections, :enabled?},
    "legal" => {PhoenixKit.Modules.Legal, :enabled?},
    "db" => {PhoenixKit.Modules.DB, :enabled?},
    "jobs" => {PhoenixKit.Jobs, :enabled?}
  }

  # --- Custom Permission Keys ---

  @doc """
  Registers a custom permission key with metadata.

  Custom keys extend the built-in 25 permission keys, allowing parent apps
  to define new permission scopes for custom admin tabs. Custom keys are
  always treated as "enabled" (no module toggle) and appear in the
  permission matrix UI under "Custom".

  Raises `ArgumentError` if the key collides with a built-in key or has
  an invalid format. Logs a warning on duplicate override.

  ## Options

  - `:label` - Human-readable label (default: capitalized key)
  - `:icon` - Heroicon name (default: `"hero-squares-2x2"`)
  - `:description` - Short description (default: `""`)

  ## Examples

      Permissions.register_custom_key("analytics", label: "Analytics", icon: "hero-chart-bar")
  """
  @spec register_custom_key(String.t(), keyword()) :: :ok
  def register_custom_key(key, opts \\ []) when is_binary(key) do
    if key in @all_module_keys do
      raise ArgumentError,
            "Cannot register custom permission key #{inspect(key)}: conflicts with built-in key"
    end

    unless Regex.match?(@valid_key_pattern, key) do
      raise ArgumentError,
            "Invalid permission key #{inspect(key)}: must match ~r/^[a-z][a-z0-9_]*$/"
    end

    if String.length(key) > @max_key_length do
      raise ArgumentError,
            "Permission key #{inspect(key)} exceeds max length of #{@max_key_length}"
    end

    current = custom_keys_map()

    if Map.has_key?(current, key) do
      Logger.warning(
        "[Permissions] Custom permission key #{inspect(key)} re-registered, overriding previous metadata"
      )
    else
      if map_size(current) >= @max_custom_keys do
        raise ArgumentError,
              "Cannot register more than #{@max_custom_keys} custom permission keys"
      end
    end

    meta = %{
      label:
        opts
        |> Keyword.get(:label)
        |> coerce_string(String.capitalize(key))
        |> String.slice(0, @max_label_length),
      icon:
        opts
        |> Keyword.get(:icon)
        |> coerce_string("hero-squares-2x2")
        |> String.slice(0, @max_icon_length),
      description:
        opts
        |> Keyword.get(:description)
        |> coerce_string("")
        |> String.slice(0, @max_description_length)
    }

    :persistent_term.put(@custom_keys_pterm, Map.put(current, key, meta))

    # Auto-grant custom keys to Admin role so they have access by default.
    # Uses a settings flag to avoid re-granting after Owner explicitly revokes.
    auto_grant_to_admin_roles(key)

    :ok
  end

  @doc """
  Unregisters a custom permission key. Stale DB rows are harmless.
  """
  @spec unregister_custom_key(String.t()) :: :ok
  def unregister_custom_key(key) when is_binary(key) do
    current = custom_keys_map()
    :persistent_term.put(@custom_keys_pterm, Map.delete(current, key))

    # Clean up any view → permission mappings that reference this key
    views = :persistent_term.get(@custom_views_pterm, %{})

    cleaned =
      views
      |> Enum.reject(fn {_mod, perm} -> perm == key end)
      |> Map.new()

    if map_size(cleaned) != map_size(views) do
      :persistent_term.put(@custom_views_pterm, cleaned)
    end

    # Clear auto-grant flag so re-registering the key will auto-grant again
    clear_auto_grant_flag(key)

    :ok
  end

  @doc """
  Returns the map of registered custom permission keys and their metadata.
  """
  @spec custom_keys_map() :: %{String.t() => map()}
  def custom_keys_map do
    :persistent_term.get(@custom_keys_pterm, %{})
  end

  @doc """
  Returns the list of custom permission key strings.
  """
  @spec custom_keys() :: [String.t()]
  def custom_keys do
    Map.keys(custom_keys_map())
  end

  @doc """
  Clears all custom permission keys. For test isolation.
  """
  @spec clear_custom_keys() :: :ok
  def clear_custom_keys do
    :persistent_term.put(@custom_keys_pterm, %{})
    :persistent_term.put(@custom_views_pterm, %{})
    :ok
  end

  @doc """
  Caches a LiveView module → permission key mapping for custom admin tabs.
  Used by the auth system to enforce permissions on custom admin LiveViews
  without reading Application config on every mount.
  """
  @spec cache_custom_view_permission(module(), String.t()) :: :ok
  def cache_custom_view_permission(view_module, permission_key)
      when is_atom(view_module) and is_binary(permission_key) do
    current = :persistent_term.get(@custom_views_pterm, %{})

    case Map.get(current, view_module) do
      nil ->
        :ok

      ^permission_key ->
        :ok

      old_key ->
        Logger.warning(
          "[Permissions] View #{inspect(view_module)} permission changed from #{inspect(old_key)} to #{inspect(permission_key)}"
        )
    end

    :persistent_term.put(@custom_views_pterm, Map.put(current, view_module, permission_key))
    :ok
  end

  @doc """
  Returns the cached custom view → permission mapping.
  """
  @spec custom_view_permissions() :: %{module() => String.t()}
  def custom_view_permissions do
    :persistent_term.get(@custom_views_pterm, %{})
  end

  # --- Constants ---

  @doc "Returns all built-in and custom permission keys."
  @spec all_module_keys() :: [String.t()]
  def all_module_keys, do: @all_module_keys ++ custom_keys()

  @doc "Returns the 5 core section keys."
  @spec core_section_keys() :: [String.t()]
  def core_section_keys, do: @core_section_keys

  @doc "Returns the 20 feature module keys."
  @spec feature_module_keys() :: [String.t()]
  def feature_module_keys, do: @feature_module_keys

  @doc """
  Returns module keys that are currently enabled (core sections + enabled feature modules + custom keys).
  Core sections and custom keys are always included. Feature modules are included only if their
  module reports enabled status.
  """
  @spec enabled_module_keys() :: MapSet.t()
  def enabled_module_keys do
    enabled_features =
      @feature_module_keys
      |> Enum.filter(&do_feature_enabled?/1)

    MapSet.new(@core_section_keys ++ enabled_features ++ custom_keys())
  end

  @doc "Checks whether `key` is a known permission key (built-in or custom)."
  @spec valid_module_key?(String.t()) :: boolean()
  def valid_module_key?(key) when is_binary(key),
    do: key in @all_module_keys or Map.has_key?(custom_keys_map(), key)

  def valid_module_key?(_), do: false

  @doc """
  Checks whether a feature module is currently enabled.

  Core section keys always return `true`. Feature module keys return the
  result of calling the module's `enabled?/0` (or equivalent) function.
  Custom permission keys are always enabled (no module toggle).
  Returns `false` for unknown keys.
  """
  @spec feature_enabled?(String.t()) :: boolean()
  def feature_enabled?(key) when key in @core_section_keys, do: true

  def feature_enabled?(key) when is_binary(key) do
    case Map.get(@feature_enabled_checks, key) do
      {mod, fun} ->
        Code.ensure_loaded?(mod) && apply(mod, fun, [])

      nil ->
        # Custom keys are always "enabled" (no module toggle)
        Map.has_key?(custom_keys_map(), key)
    end
  rescue
    _ -> false
  end

  @labels %{
    "dashboard" => "Dashboard",
    "users" => "Users",
    "media" => "Media",
    "settings" => "Settings",
    "modules" => "Modules",
    "billing" => "Billing",
    "shop" => "E-Commerce",
    "emails" => "Emails",
    "entities" => "Entities",
    "tickets" => "Tickets",
    "posts" => "Posts",
    "comments" => "Comments",
    "ai" => "AI",
    "sync" => "Sync",
    "publishing" => "Publishing",
    "referrals" => "Referrals",
    "sitemap" => "Sitemap",
    "seo" => "SEO",
    "maintenance" => "Maintenance",
    "storage" => "Storage",
    "languages" => "Languages",
    "connections" => "Connections",
    "legal" => "Legal",
    "db" => "DB",
    "jobs" => "Jobs"
  }

  @doc "Returns a human-readable label for a module key."
  @spec module_label(String.t()) :: String.t()
  def module_label(key) do
    case Map.get(@labels, key) do
      nil -> custom_key_metadata(key)[:label] || String.capitalize(key)
      label -> label
    end
  end

  @icons %{
    "dashboard" => "hero-home",
    "users" => "hero-users",
    "media" => "hero-photo",
    "settings" => "hero-cog-6-tooth",
    "modules" => "hero-squares-2x2",
    "billing" => "hero-credit-card",
    "shop" => "hero-shopping-cart",
    "emails" => "hero-envelope",
    "entities" => "hero-cube-transparent",
    "tickets" => "hero-ticket",
    "posts" => "hero-document-text",
    "comments" => "hero-chat-bubble-left-right",
    "ai" => "hero-sparkles",
    "sync" => "hero-arrow-path",
    "publishing" => "hero-document-duplicate",
    "referrals" => "hero-gift",
    "sitemap" => "hero-map",
    "seo" => "hero-magnifying-glass",
    "maintenance" => "hero-wrench-screwdriver",
    "storage" => "hero-circle-stack",
    "languages" => "hero-language",
    "connections" => "hero-link",
    "legal" => "hero-scale",
    "db" => "hero-server-stack",
    "jobs" => "hero-clock"
  }

  @doc "Returns a Heroicon name for a module key."
  @spec module_icon(String.t()) :: String.t()
  def module_icon(key) do
    case Map.get(@icons, key) do
      nil -> custom_key_metadata(key)[:icon] || "hero-squares-2x2"
      icon -> icon
    end
  end

  @descriptions %{
    "dashboard" => "Overview statistics, charts, and system health",
    "users" => "User accounts, roles, and access management",
    "media" => "File uploads, image processing, and storage buckets",
    "settings" => "General, organization, and user preference settings",
    "modules" => "Enable, disable, and configure feature modules",
    "billing" => "Payment providers, subscriptions, and invoices",
    "shop" => "Product catalog, orders, and e-commerce management",
    "emails" => "Email delivery tracking, templates, and analytics",
    "entities" => "Dynamic content types and custom data structures",
    "tickets" => "Support ticket management and customer communication",
    "posts" => "Blog posts, categories, and content publishing",
    "comments" => "Comment moderation, threading, and reactions across all content types",
    "ai" => "AI endpoints, prompts, and usage tracking",
    "sync" => "Peer-to-peer data synchronization and replication",
    "publishing" => "Filesystem-based CMS pages and multi-language content",
    "referrals" => "Referral codes, tracking, and reward programs",
    "sitemap" => "XML sitemap generation and search engine indexing",
    "seo" => "Meta tags, Open Graph, and search optimization",
    "maintenance" => "Maintenance mode and under-construction pages",
    "storage" => "Distributed file storage with multi-location redundancy",
    "languages" => "Multi-language support and locale management",
    "connections" => "External service connections and integrations",
    "legal" => "Legal pages, terms of service, and privacy policies",
    "db" => "Database explorer and schema inspection",
    "jobs" => "Background job queues and task scheduling"
  }

  @doc "Returns a short description for a module key."
  @spec module_description(String.t()) :: String.t()
  def module_description(key) do
    case Map.get(@descriptions, key) do
      nil -> custom_key_metadata(key)[:description] || ""
      desc -> desc
    end
  end

  # --- Query API ---

  @doc """
  Returns the list of module_keys the given user has access to.
  Joins through role_assignments → role_permissions.
  """
  @spec get_permissions_for_user(User.t() | nil) :: [String.t()]
  def get_permissions_for_user(nil), do: []
  def get_permissions_for_user(%User{uuid: nil}), do: []

  def get_permissions_for_user(%User{uuid: user_uuid}) when not is_nil(user_uuid) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      join: ra in RoleAssignment,
      on: ra.role_uuid == rp.role_uuid,
      where: ra.user_uuid == ^user_uuid,
      select: rp.module_key,
      distinct: true
    )
    |> repo.all()
  rescue
    e ->
      if table_missing_error?(e) do
        Logger.error(
          "PhoenixKit: phoenix_kit_role_permissions table not found. " <>
            "Run `mix phoenix_kit.update` to apply V53 migration."
        )
      else
        Logger.warning("Permissions.get_permissions_for_user failed: #{inspect(e)}")
      end

      []
  end

  @doc """
  Checks if a specific role has a specific permission.
  """
  @spec role_has_permission?(integer() | String.t(), String.t()) :: boolean()
  def role_has_permission?(role_id, module_key) do
    repo = RepoHelper.repo()
    role_uuid = resolve_role_uuid(role_id)

    from(rp in RolePermission,
      where: rp.role_uuid == ^role_uuid and rp.module_key == ^module_key,
      select: true
    )
    |> repo.exists?()
  rescue
    e ->
      Logger.warning("Permissions.role_has_permission? failed: #{inspect(e)}")
      false
  end

  @doc """
  Returns the list of module_keys granted to a specific role.
  """
  @spec get_permissions_for_role(integer() | String.t()) :: [String.t()]
  def get_permissions_for_role(role_id) do
    repo = RepoHelper.repo()
    role_uuid = resolve_role_uuid(role_id)

    from(rp in RolePermission,
      where: rp.role_uuid == ^role_uuid,
      select: rp.module_key,
      order_by: [asc: rp.module_key]
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.get_permissions_for_role failed: #{inspect(e)}")
      []
  end

  @doc """
  Returns a matrix of role_id → MapSet of granted keys for all roles.
  """
  @spec get_permissions_matrix() :: %{String.t() => MapSet.t()}
  def get_permissions_matrix do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      select: {rp.role_uuid, rp.module_key}
    )
    |> repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {role_uuid, keys} -> {role_uuid, MapSet.new(keys)} end)
  rescue
    e ->
      Logger.warning("Permissions.get_permissions_matrix failed: #{inspect(e)}")
      %{}
  end

  @doc """
  Returns a list of role_ids that have been granted the given module_key.
  """
  @spec roles_with_permission(String.t()) :: [String.t()]
  def roles_with_permission(module_key) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      where: rp.module_key == ^module_key,
      select: rp.role_uuid,
      order_by: [asc: rp.role_uuid]
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.roles_with_permission failed: #{inspect(e)}")
      []
  end

  @doc """
  Returns a list of user_ids that have access to the given module_key
  (through any of their assigned roles).
  """
  @spec users_with_permission(String.t()) :: [String.t()]
  def users_with_permission(module_key) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      join: ra in RoleAssignment,
      on: ra.role_uuid == rp.role_uuid,
      where: rp.module_key == ^module_key,
      select: ra.user_uuid,
      distinct: true,
      order_by: [asc: ra.user_uuid]
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.users_with_permission failed: #{inspect(e)}")
      []
  end

  @doc """
  Returns the number of permission keys granted to a role.
  More efficient than `length(get_permissions_for_role(role_id))`.
  """
  @spec count_permissions_for_role(integer() | String.t()) :: non_neg_integer()
  def count_permissions_for_role(role_id) do
    repo = RepoHelper.repo()
    role_uuid = resolve_role_uuid(role_id)

    from(rp in RolePermission,
      where: rp.role_uuid == ^role_uuid,
      select: count()
    )
    |> repo.one()
  rescue
    e ->
      Logger.warning("Permissions.count_permissions_for_role failed: #{inspect(e)}")
      0
  end

  @doc """
  Compares permissions between two roles and returns a diff map.

  Returns `%{only_a: MapSet.t(), only_b: MapSet.t(), common: MapSet.t()}`
  where `only_a` are keys role_a has but role_b doesn't, `only_b` is the
  inverse, and `common` are keys both roles share.
  """
  @spec diff_permissions(integer() | String.t(), integer() | String.t()) :: %{
          only_a: MapSet.t(),
          only_b: MapSet.t(),
          common: MapSet.t()
        }
  def diff_permissions(role_id_a, role_id_b) do
    keys_a = get_permissions_for_role(role_id_a) |> MapSet.new()
    keys_b = get_permissions_for_role(role_id_b) |> MapSet.new()

    %{
      only_a: MapSet.difference(keys_a, keys_b),
      only_b: MapSet.difference(keys_b, keys_a),
      common: MapSet.intersection(keys_a, keys_b)
    }
  end

  # --- Mutation API ---

  @doc """
  Grants a single permission to a role. Uses upsert to be idempotent.
  """
  @spec grant_permission(integer() | String.t(), String.t(), integer() | String.t() | nil) ::
          {:ok, RolePermission.t()} | {:error, Ecto.Changeset.t()}
  def grant_permission(role_id, module_key, granted_by_id \\ nil) do
    repo = RepoHelper.repo()

    # Resolve both integer and UUID forms for dual-write
    role_int = resolve_role_id(role_id)
    role_uuid = resolve_role_uuid(role_id)
    granted_by_int = resolve_user_id(granted_by_id)
    granted_by_uuid = resolve_user_uuid(granted_by_id)

    %RolePermission{}
    |> RolePermission.changeset(%{
      role_id: role_int,
      role_uuid: role_uuid,
      module_key: module_key,
      granted_by: granted_by_int,
      granted_by_uuid: granted_by_uuid
    })
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:role_uuid, :module_key]
    )
    |> tap(fn
      {:ok, %{uuid: uuid}} when not is_nil(uuid) ->
        Events.broadcast_permission_granted(role_id, module_key)
        notify_affected_users(role_id)

      _ ->
        :ok
    end)
  end

  @doc """
  Revokes a single permission from a role.
  """
  @spec revoke_permission(integer() | String.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke_permission(role_id, module_key) do
    repo = RepoHelper.repo()

    role_uuid = resolve_role_uuid(role_id)

    from(rp in RolePermission,
      where: rp.role_uuid == ^role_uuid and rp.module_key == ^module_key
    )
    |> repo.delete_all()
    |> case do
      {0, _} ->
        {:error, :not_found}

      {_, _} ->
        Events.broadcast_permission_revoked(role_id, module_key)
        notify_affected_users(role_id)
        :ok
    end
  end

  @doc """
  Syncs permissions for a role: grants missing keys, revokes extras.
  Runs in a transaction.
  """
  @spec set_permissions(integer() | String.t(), [String.t()], integer() | String.t() | nil) ::
          :ok | {:error, term()}
  def set_permissions(role_id, desired_keys, granted_by_id \\ nil) do
    repo = RepoHelper.repo()
    valid_keys = MapSet.new(all_module_keys())

    repo.transaction(fn ->
      # Resolve both integer and UUID forms for dual-write
      role_int = resolve_role_id(role_id)
      role_uuid = resolve_role_uuid(role_id)

      # Lock existing permission rows FOR UPDATE to prevent concurrent set_permissions
      # from reading the same state and computing conflicting diffs.
      current_keys =
        from(rp in RolePermission,
          where: rp.role_uuid == ^role_uuid,
          select: rp.module_key,
          lock: "FOR UPDATE"
        )
        |> repo.all()
        |> MapSet.new()

      # Filter out any invalid keys before processing
      desired_set = desired_keys |> MapSet.new() |> MapSet.intersection(valid_keys)

      # Keys to add
      to_add = MapSet.difference(desired_set, current_keys)

      # Keys to remove
      to_remove = MapSet.difference(current_keys, desired_set)

      # Bulk insert new permissions
      if MapSet.size(to_add) > 0 do
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        granted_by_int = resolve_user_id(granted_by_id)
        granted_by_uuid = resolve_user_uuid(granted_by_id)

        entries =
          Enum.map(to_add, fn key ->
            %{
              uuid: UUIDv7.generate(),
              role_id: role_int,
              role_uuid: role_uuid,
              module_key: key,
              granted_by: granted_by_int,
              granted_by_uuid: granted_by_uuid,
              inserted_at: now
            }
          end)

        repo.insert_all(RolePermission, entries, on_conflict: :nothing)
      end

      # Bulk delete removed permissions
      if MapSet.size(to_remove) > 0 do
        remove_list = MapSet.to_list(to_remove)

        from(rp in RolePermission,
          where: rp.role_uuid == ^role_uuid and rp.module_key in ^remove_list
        )
        |> repo.delete_all()
      end

      MapSet.to_list(desired_set)
    end)
    |> case do
      {:ok, filtered_keys} ->
        Events.broadcast_permissions_synced(role_id, filtered_keys)
        notify_affected_users(role_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Grants all permission keys (built-in + custom) to a role.
  """
  @spec grant_all_permissions(integer() | String.t(), integer() | String.t() | nil) ::
          :ok | {:error, term()}
  def grant_all_permissions(role_id, granted_by_id \\ nil) do
    set_permissions(role_id, all_module_keys(), granted_by_id)
  end

  @doc """
  Revokes all permissions from a role.
  """
  @spec revoke_all_permissions(integer() | String.t()) :: :ok | {:error, term()}
  def revoke_all_permissions(role_id) do
    repo = RepoHelper.repo()

    role_uuid = resolve_role_uuid(role_id)

    from(rp in RolePermission, where: rp.role_uuid == ^role_uuid)
    |> repo.delete_all()

    Events.broadcast_permissions_synced(role_id, [])
    notify_affected_users(role_id)
    :ok
  rescue
    e ->
      require Logger
      Logger.warning("[PhoenixKit.Permissions] revoke_all_permissions failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Copies all permissions from one role to another.

  The target role will end up with the exact same set of permissions as the
  source role. Existing permissions on the target that don't exist on the
  source will be revoked.
  """
  @spec copy_permissions(
          integer() | String.t(),
          integer() | String.t(),
          integer() | String.t() | nil
        ) :: :ok | {:error, term()}
  def copy_permissions(source_role_id, target_role_id, granted_by_id \\ nil) do
    source_keys = get_permissions_for_role(source_role_id)
    set_permissions(target_role_id, source_keys, granted_by_id)
  end

  # --- Access Control ---

  @doc """
  Checks if the given scope can edit the target role's permissions.

  Returns `:ok` if allowed, or `{:error, reason}` if not.

  Rules:
  - Owner role cannot be edited (always has full access)
  - Users cannot edit their own role (prevents self-lockout)
  - Only Owner can edit Admin role (prevents privilege escalation)
  """
  @spec can_edit_role_permissions?(Scope.t() | nil, Role.t()) :: :ok | {:error, String.t()}
  def can_edit_role_permissions?(nil, _role), do: {:error, "Not authenticated"}

  def can_edit_role_permissions?(scope, role) do
    if Scope.authenticated?(scope) do
      can_edit_role_permissions_check(scope, role)
    else
      {:error, "Not authenticated"}
    end
  end

  defp can_edit_role_permissions_check(scope, role) do
    user_roles = Scope.user_roles(scope)

    cond do
      role.name == "Owner" ->
        {:error, "Owner role always has full access and cannot be modified"}

      role.name in user_roles ->
        {:error, "You cannot edit permissions for your own role"}

      role.name == "Admin" and not Scope.owner?(scope) ->
        {:error, "Only the Owner can edit Admin permissions"}

      true ->
        :ok
    end
  end

  # --- Helpers ---

  # Returns metadata for a custom permission key, or nil if not found.
  defp custom_key_metadata(key) do
    Map.get(custom_keys_map(), key)
  end

  defp do_feature_enabled?(key) do
    case Map.get(@feature_enabled_checks, key) do
      {mod, fun} ->
        Code.ensure_loaded?(mod) && apply(mod, fun, [])

      nil ->
        false
    end
  rescue
    _ -> false
  end

  # Detect Postgrex "relation does not exist" errors (table missing)
  defp table_missing_error?(%{postgres: %{code: :undefined_table}}), do: true

  defp table_missing_error?(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: true

  defp table_missing_error?(%{message: msg}) when is_binary(msg) do
    String.contains?(msg, "does not exist")
  end

  defp table_missing_error?(_), do: false

  # Resolves an integer role_id to its UUID for changeset/insert_all use
  defp resolve_role_uuid(nil), do: nil

  defp resolve_role_uuid(role_id) when is_integer(role_id) do
    repo = RepoHelper.repo()

    from(r in Role, where: r.id == ^role_id, select: r.uuid)
    |> repo.one()
  end

  defp resolve_role_uuid(role_id) when is_binary(role_id), do: role_id

  # Resolves a UUID string to the integer role_id for legacy columns
  defp resolve_role_id(nil), do: nil
  defp resolve_role_id(role_id) when is_integer(role_id), do: role_id

  defp resolve_role_id(role_uuid) when is_binary(role_uuid) do
    repo = RepoHelper.repo()

    from(r in Role, where: r.uuid == ^role_uuid, select: r.id)
    |> repo.one()
  end

  # Resolves a UUID string to the integer user_id for legacy columns
  defp resolve_user_id(nil), do: nil
  defp resolve_user_id(user_id) when is_integer(user_id), do: user_id

  defp resolve_user_id(user_uuid) when is_binary(user_uuid) do
    repo = RepoHelper.repo()

    from(u in User, where: u.uuid == ^user_uuid, select: u.id)
    |> repo.one()
  end

  # Resolves an integer user_id to its UUID for changeset use
  defp resolve_user_uuid(nil), do: nil

  defp resolve_user_uuid(user_id) when is_integer(user_id) do
    repo = RepoHelper.repo()

    from(u in User, where: u.id == ^user_id, select: u.uuid)
    |> repo.one()
  end

  defp resolve_user_uuid(user_id) when is_binary(user_id), do: user_id

  # Notify all users with the affected role to refresh their scope
  defp notify_affected_users(role_id) do
    repo = RepoHelper.repo()

    role_uuid = resolve_role_uuid(role_id)

    user_uuids =
      from(ra in RoleAssignment,
        where: ra.role_uuid == ^role_uuid,
        select: ra.user_uuid
      )
      |> repo.all()

    Enum.each(user_uuids, &ScopeNotifier.broadcast_roles_updated/1)
  rescue
    e ->
      Logger.warning("Permissions.notify_affected_users failed: #{inspect(e)}")
      :ok
  end

  # Clears the auto-grant settings flag for a custom key so that
  # re-registering it will trigger a fresh auto-grant to Admin.
  defp clear_auto_grant_flag(key) do
    Settings.update_setting("auto_granted_perm:#{key}", nil)
  rescue
    _ -> :ok
  end

  # Auto-grants a custom permission key to the Admin system role.
  # Stores a flag in phoenix_kit_settings so that if Owner later revokes
  # the key, it won't be re-granted on next application restart.
  defp auto_grant_to_admin_roles(key) do
    flag_key = "auto_granted_perm:#{key}"

    # If already auto-granted before, respect any manual changes
    if Settings.get_setting(flag_key) == "true" do
      :ok
    else
      case Roles.get_role_by_name(Role.system_roles().admin) do
        %{id: admin_id} when not is_nil(admin_id) ->
          case grant_permission(admin_id, key, nil) do
            {:ok, _} ->
              Settings.update_setting(flag_key, "true")

            {:error, _} ->
              Logger.warning(
                "[Permissions] grant_permission failed for Admin role on key #{inspect(key)}, will retry next boot"
              )
          end

          :ok

        _ ->
          # Admin role not found (pre-V53 or missing), skip
          :ok
      end
    end
  rescue
    error ->
      Logger.warning(
        "[Permissions] Failed to auto-grant #{inspect(key)} to Admin role: #{Exception.message(error)}"
      )

      :ok
  end

  # Coerces a value to a string, returning the default for nil.
  # Handles atoms, integers, and other types gracefully via to_string/1.
  defp coerce_string(nil, default), do: default
  defp coerce_string(value, _default) when is_binary(value), do: value
  defp coerce_string(value, _default), do: to_string(value)
end
