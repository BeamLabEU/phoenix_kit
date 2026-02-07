defmodule PhoenixKit.Users.Permissions do
  @moduledoc """
  Context for module-level permissions in PhoenixKit.

  Controls which roles can access which admin sections and feature modules.
  Uses an allowlist model: row present = granted, absent = denied.
  Owner role always has full access (enforced in code, no DB rows needed).

  ## Permission Keys

  Core sections: dashboard, users, media, settings, modules
  Feature modules: billing, shop, emails, entities, tickets, posts, ai,
    sync, publishing, referrals, sitemap, seo, maintenance, storage,
    languages, connections, legal, db, jobs

  ## Usage

      # Check if a role has access to billing
      Permissions.role_has_permission?(role_id, "billing")

      # Get all permissions for a user (via their role assignments)
      Permissions.get_permissions_for_user(user)

      # Grant/revoke in bulk
      Permissions.set_permissions(role_id, ["dashboard", "users"], granted_by_id)
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.ScopeNotifier

  @core_section_keys ~w(dashboard users media settings modules)
  @feature_module_keys ~w(
    billing shop emails entities tickets posts ai
    sync publishing referrals sitemap seo maintenance
    storage languages connections legal db jobs
  )
  @all_module_keys @core_section_keys ++ @feature_module_keys

  # Maps feature module keys to their {Module, :enabled_function} for checking enabled status
  @feature_enabled_checks %{
    "billing" => {PhoenixKit.Modules.Billing, :enabled?},
    "shop" => {PhoenixKit.Modules.Shop, :enabled?},
    "emails" => {PhoenixKit.Modules.Emails, :enabled?},
    "entities" => {PhoenixKit.Modules.Entities, :enabled?},
    "tickets" => {PhoenixKit.Modules.Tickets, :enabled?},
    "posts" => {PhoenixKit.Modules.Posts, :enabled?},
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

  # --- Constants ---

  @doc "Returns all 24 permission keys."
  @spec all_module_keys() :: [String.t()]
  def all_module_keys, do: @all_module_keys

  @doc "Returns the 5 core section keys."
  @spec core_section_keys() :: [String.t()]
  def core_section_keys, do: @core_section_keys

  @doc "Returns the 19 feature module keys."
  @spec feature_module_keys() :: [String.t()]
  def feature_module_keys, do: @feature_module_keys

  @doc """
  Returns module keys that are currently enabled (core sections + enabled feature modules).
  Core sections are always included. Feature modules are included only if their
  module reports enabled status.
  """
  @spec enabled_module_keys() :: MapSet.t()
  def enabled_module_keys do
    enabled_features =
      @feature_module_keys
      |> Enum.filter(&feature_enabled?/1)

    MapSet.new(@core_section_keys ++ enabled_features)
  end

  @doc "Returns a human-readable label for a module key."
  @spec module_label(String.t()) :: String.t()
  def module_label(key) do
    labels = %{
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
      "db" => "DB Explorer",
      "jobs" => "Jobs"
    }

    Map.get(labels, key, String.capitalize(key))
  end

  # --- Query API ---

  @doc """
  Returns the list of module_keys the given user has access to.
  Joins through role_assignments → role_permissions.
  """
  @spec get_permissions_for_user(User.t() | nil) :: [String.t()]
  def get_permissions_for_user(nil), do: []

  def get_permissions_for_user(%User{id: user_id}) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      join: ra in "phoenix_kit_user_role_assignments",
      on: ra.role_id == rp.role_id,
      where: ra.user_id == ^user_id and ra.is_active == true,
      select: rp.module_key,
      distinct: true
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.get_permissions_for_user failed: #{inspect(e)}")
      []
  end

  @doc """
  Checks if a specific role has a specific permission.
  """
  @spec role_has_permission?(integer(), String.t()) :: boolean()
  def role_has_permission?(role_id, module_key) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      where: rp.role_id == ^role_id and rp.module_key == ^module_key,
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
  @spec get_permissions_for_role(integer()) :: [String.t()]
  def get_permissions_for_role(role_id) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      where: rp.role_id == ^role_id,
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
  @spec get_permissions_matrix() :: %{integer() => MapSet.t()}
  def get_permissions_matrix do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      select: {rp.role_id, rp.module_key}
    )
    |> repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {role_id, keys} -> {role_id, MapSet.new(keys)} end)
  rescue
    e ->
      Logger.warning("Permissions.get_permissions_matrix failed: #{inspect(e)}")
      %{}
  end

  # --- Mutation API ---

  @doc """
  Grants a single permission to a role. Uses upsert to be idempotent.
  """
  @spec grant_permission(integer(), String.t(), integer() | nil) ::
          {:ok, RolePermission.t()} | {:error, Ecto.Changeset.t()}
  def grant_permission(role_id, module_key, granted_by_id \\ nil) do
    repo = RepoHelper.repo()

    %RolePermission{}
    |> RolePermission.changeset(%{
      role_id: role_id,
      module_key: module_key,
      granted_by: granted_by_id
    })
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:role_id, :module_key]
    )
    |> tap(fn
      {:ok, %{id: id}} when not is_nil(id) ->
        Events.broadcast_permission_granted(role_id, module_key)
        notify_affected_users(role_id)

      _ ->
        :ok
    end)
  end

  @doc """
  Revokes a single permission from a role.
  """
  @spec revoke_permission(integer(), String.t()) :: :ok | {:error, :not_found}
  def revoke_permission(role_id, module_key) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      where: rp.role_id == ^role_id and rp.module_key == ^module_key
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
  @spec set_permissions(integer(), [String.t()], integer() | nil) :: :ok | {:error, term()}
  def set_permissions(role_id, desired_keys, granted_by_id \\ nil) do
    repo = RepoHelper.repo()
    valid_keys = MapSet.new(@all_module_keys)

    repo.transaction(fn ->
      current_keys = get_permissions_for_role(role_id) |> MapSet.new()
      # Filter out any invalid keys before processing
      desired_set = desired_keys |> MapSet.new() |> MapSet.intersection(valid_keys)

      # Keys to add
      to_add = MapSet.difference(desired_set, current_keys)

      # Keys to remove
      to_remove = MapSet.difference(current_keys, desired_set)

      # Bulk insert new permissions
      if MapSet.size(to_add) > 0 do
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        entries =
          Enum.map(to_add, fn key ->
            %{
              role_id: role_id,
              module_key: key,
              granted_by: granted_by_id,
              inserted_at: now
            }
          end)

        repo.insert_all(RolePermission, entries, on_conflict: :nothing)
      end

      # Bulk delete removed permissions
      if MapSet.size(to_remove) > 0 do
        remove_list = MapSet.to_list(to_remove)

        from(rp in RolePermission,
          where: rp.role_id == ^role_id and rp.module_key in ^remove_list
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
  Grants all 24 permission keys to a role.
  """
  @spec grant_all_permissions(integer(), integer() | nil) :: :ok | {:error, term()}
  def grant_all_permissions(role_id, granted_by_id \\ nil) do
    set_permissions(role_id, @all_module_keys, granted_by_id)
  end

  @doc """
  Revokes all permissions from a role.
  """
  @spec revoke_all_permissions(integer()) :: :ok
  def revoke_all_permissions(role_id) do
    repo = RepoHelper.repo()

    from(rp in RolePermission, where: rp.role_id == ^role_id)
    |> repo.delete_all()

    Events.broadcast_permissions_synced(role_id, [])
    notify_affected_users(role_id)
    :ok
  end

  # --- Helpers ---

  defp feature_enabled?(key) do
    case Map.get(@feature_enabled_checks, key) do
      {mod, fun} ->
        Code.ensure_loaded?(mod) && apply(mod, fun, [])

      nil ->
        false
    end
  rescue
    _ -> false
  end

  # Notify all users with the affected role to refresh their scope
  defp notify_affected_users(role_id) do
    repo = RepoHelper.repo()

    user_ids =
      from(ra in "phoenix_kit_user_role_assignments",
        where: ra.role_id == ^role_id and ra.is_active == true,
        select: ra.user_id
      )
      |> repo.all()

    Enum.each(user_ids, &ScopeNotifier.broadcast_roles_updated/1)
  rescue
    e ->
      Logger.warning("Permissions.notify_affected_users failed: #{inspect(e)}")
      :ok
  end
end
