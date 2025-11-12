defmodule PhoenixKit.Users.Roles do
  @moduledoc """
  API for managing user roles in PhoenixKit.

  This module provides functions for assigning, removing, and querying user roles.
  It works with the role system to provide authorization capabilities.

  ## Role Management

  - Assign and remove roles from users
  - Query users by role
  - Check user permissions
  - Bulk role operations

  ## System Roles

  PhoenixKit includes three built-in system roles:

  - **Owner**: System owner with full access (assigned automatically to first user)
  - **Admin**: Administrator with elevated privileges
  - **User**: Standard user with basic access (default for new users)

  ## Examples

      # Check if user has a role
      iex> user_has_role?(user, "Admin")
      true

      # Get all user roles
      iex> get_user_roles(user)
      ["Admin", "User"]

      # Assign a role to user
      iex> assign_role(user, "Admin")
      {:ok, %RoleAssignment{}}

      # Get all users with a specific role
      iex> users_with_role("Admin")
      [%User{}, %User{}]
  """

  import Ecto.Query, warn: false
  alias Ecto.Adapters.SQL
  alias PhoenixKit.Admin.Events
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.{Role, RoleAssignment, ScopeNotifier}

  @doc """
  Assigns a role to a user.

  ## Security

  The Owner role cannot be assigned through this function to maintain system security.
  Only one Owner is automatically assigned during initialization.

  ## Parameters

  - `user`: The user to assign the role to
  - `role_name`: The name of the role to assign
  - `assigned_by` (optional): The user who is assigning the role

  ## Examples

      iex> assign_role(user, "Admin")
      {:ok, %RoleAssignment{}}

      iex> assign_role(user, "Admin", assigned_by_user)
      {:ok, %RoleAssignment{}}

      iex> assign_role(user, "Owner")
      {:error, :owner_role_protected}

      iex> assign_role(user, "NonexistentRole")
      {:error, :role_not_found}
  """
  def assign_role(%User{} = user, role_name, assigned_by \\ nil, opts \\ [])
      when is_binary(role_name) do
    roles = Role.system_roles()

    # Prevent manual assignment of Owner role
    if role_name == roles.owner do
      {:error, :owner_role_protected}
    else
      assign_role_internal(user, role_name, assigned_by, opts)
    end
  end

  # Internal function for assigning roles without Owner protection
  # Used by system functions like ensure_first_user_is_owner/1
  defp assign_role_internal(%User{} = user, role_name, assigned_by \\ nil, opts \\ [])
       when is_binary(role_name) do
    repo = RepoHelper.repo()
    broadcast? = Keyword.get(opts, :broadcast, true)

    case get_role_by_name(role_name) do
      nil ->
        {:error, :role_not_found}

      role ->
        attrs = %{
          user_id: user.id,
          role_id: role.id,
          assigned_by: assigned_by && assigned_by.id
        }

        # Use upsert with ON CONFLICT DO NOTHING for idempotency
        # This prevents duplicate role assignment errors during concurrent operations
        %RoleAssignment{}
        |> RoleAssignment.changeset(attrs)
        |> repo.insert(
          on_conflict: :nothing,
          conflict_target: [:user_id, :role_id]
        )
        |> case do
          {:ok, assignment} ->
            if broadcast? do
              # Broadcast role assignment event
              Events.broadcast_user_role_assigned(user, role_name)
              # Notify active LiveView sessions to refresh cached scope
              ScopeNotifier.broadcast_roles_updated(user)
            end

            {:ok, assignment}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Removes a role from a user by deleting the assignment.

  ## Parameters

  - `user`: The user to remove the role from
  - `role_name`: The name of the role to remove

  ## Examples

      iex> remove_role(user, "Admin")
      {:ok, %RoleAssignment{}}

      iex> remove_role(user, "NonexistentRole")
      {:error, :assignment_not_found}
  """
  def remove_role(%User{} = user, role_name, opts \\ []) when is_binary(role_name) do
    repo = RepoHelper.repo()
    broadcast? = Keyword.get(opts, :broadcast, true)

    case get_assignment(user.id, role_name) do
      nil ->
        {:error, :assignment_not_found}

      assignment ->
        case repo.delete(assignment) do
          {:ok, deleted_assignment} ->
            if broadcast? do
              # Broadcast role removal event
              Events.broadcast_user_role_removed(user, role_name)
              # Notify active LiveView sessions to refresh cached scope
              ScopeNotifier.broadcast_roles_updated(user)
            end

            {:ok, deleted_assignment}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Checks if a user has a specific role.

  ## Parameters

  - `user`: The user to check
  - `role_name`: The name of the role to check for

  ## Examples

      iex> user_has_role?(user, "Admin")
      true

      iex> user_has_role?(user, "Owner")
      false
  """
  def user_has_role?(%User{} = user, role_name) when is_binary(role_name) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        join: role in assoc(assignment, :role),
        where: assignment.user_id == ^user.id,
        where: role.name == ^role_name

    repo.exists?(query)
  end

  @doc """
  Checks if a user has an "Owner" role.

  ## Parameters

  - `user`: The user to check

  ## Examples

      iex> user_has_role_owner?(user)
      true
  """
  def user_has_role_owner?(%User{} = user) do
    roles = Role.system_roles()
    user_has_role?(user, roles.owner)
  end

  @doc """
  Checks if a user has an "Admin" role.

  ## Parameters

  - `user`: The user to check

  ## Examples

      iex> user_has_role_admin?(user)
      true
  """
  def user_has_role_admin?(%User{} = user) do
    roles = Role.system_roles()
    user_has_role?(user, roles.admin)
  end

  @doc """
  Gets all active roles for a user.

  ## Parameters

  - `user`: The user to get roles for

  ## Examples

      iex> get_user_roles(user)
      ["Admin", "User"]

      iex> get_user_roles(user_with_no_roles)
      []
  """
  def get_user_roles(%User{} = user) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        join: role in assoc(assignment, :role),
        where: assignment.user_id == ^user.id,
        select: role.name,
        order_by: role.name

    repo.all(query)
  end

  @doc """
  Gets all users who have a specific role.

  ## Parameters

  - `role_name`: The name of the role to search for

  ## Examples

      iex> users_with_role("Admin")
      [%User{}, %User{}]

      iex> users_with_role("NonexistentRole")
      []
  """
  def users_with_role(role_name) when is_binary(role_name) do
    repo = RepoHelper.repo()

    query =
      from user in User,
        join: assignment in assoc(user, :role_assignments),
        join: role in assoc(assignment, :role),
        where: role.name == ^role_name,
        distinct: user.id,
        order_by: user.email

    repo.all(query)
  end

  @doc """
  Creates a new role.

  ## Parameters

  - `attrs`: Attributes for the new role

  ## Examples

      iex> create_role(%{name: "Manager", description: "Department manager"})
      {:ok, %Role{}}

      iex> create_role(%{name: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_role(attrs \\ %{}) do
    repo = RepoHelper.repo()

    case %Role{}
         |> Role.changeset(attrs)
         |> repo.insert() do
      {:ok, role} ->
        # Broadcast role creation event
        Events.broadcast_role_created(role)
        {:ok, role}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets a role by its name.

  ## Parameters

  - `name`: The name of the role

  ## Examples

      iex> get_role_by_name("Admin")
      %Role{name: "Admin"}

      iex> get_role_by_name("NonexistentRole")
      nil
  """
  def get_role_by_name(name) when is_binary(name) do
    repo = RepoHelper.repo()
    repo.get_by(Role, name: name)
  end

  @doc """
  Lists all roles.

  ## Examples

      iex> list_roles()
      [%Role{}, %Role{}, %Role{}]
  """
  def list_roles do
    repo = RepoHelper.repo()

    query =
      from role in Role,
        order_by: [desc: role.is_system_role, asc: role.name]

    repo.all(query)
  end

  @doc """
  Gets role statistics for dashboard display.

  ## Examples

      iex> get_role_stats()
      %{
        total_users: 10,
        owner_count: 1,
        admin_count: 2,
        user_count: 7
      }
  """
  def get_role_stats do
    repo = RepoHelper.repo()

    roles = Role.system_roles()

    total_users_query = from(u in User, select: count(u.id))
    total_users = repo.one(total_users_query)

    owner_count = count_users_with_role(roles.owner)
    admin_count = count_users_with_role(roles.admin)
    user_count = count_users_with_role(roles.user)

    %{
      total_users: total_users,
      owner_count: owner_count,
      admin_count: admin_count,
      user_count: user_count
    }
  end

  @doc """
  Gets comprehensive user statistics including activity and confirmation status.

  ## Examples

      iex> get_extended_stats()
      %{
        total_users: 10,
        owner_count: 1,
        admin_count: 2,
        user_count: 7,
        active_users: 8,
        inactive_users: 2,
        confirmed_users: 9,
        pending_users: 1
      }
  """
  def get_extended_stats do
    repo = RepoHelper.repo()

    # Single optimized query combining all statistics
    query = """
    SELECT
      COUNT(*) as total_users,
      COUNT(*) FILTER (WHERE is_active = true) as active_users,
      COUNT(*) FILTER (WHERE is_active = false) as inactive_users,
      COUNT(*) FILTER (WHERE confirmed_at IS NOT NULL) as confirmed_users,
      COUNT(*) FILTER (WHERE confirmed_at IS NULL) as pending_users,
      COALESCE((
        SELECT COUNT(*)
        FROM phoenix_kit_user_role_assignments ra
        JOIN phoenix_kit_user_roles r ON r.id = ra.role_id
        WHERE r.name = $1
      ), 0) as owner_count,
      COALESCE((
        SELECT COUNT(*)
        FROM phoenix_kit_user_role_assignments ra
        JOIN phoenix_kit_user_roles r ON r.id = ra.role_id
        WHERE r.name = $2
      ), 0) as admin_count,
      COALESCE((
        SELECT COUNT(*)
        FROM phoenix_kit_user_role_assignments ra
        JOIN phoenix_kit_user_roles r ON r.id = ra.role_id
        WHERE r.name = $3
      ), 0) as user_count
    FROM phoenix_kit_users;
    """

    roles = Role.system_roles()

    result =
      SQL.query!(repo, query, [
        roles.owner,
        roles.admin,
        roles.user
      ])

    case result.rows do
      [
        [
          total_users,
          active_users,
          inactive_users,
          confirmed_users,
          pending_users,
          owner_count,
          admin_count,
          user_count
        ]
      ] ->
        %{
          total_users: total_users,
          active_users: active_users,
          inactive_users: inactive_users,
          confirmed_users: confirmed_users,
          pending_users: pending_users,
          owner_count: owner_count,
          admin_count: admin_count,
          user_count: user_count
        }

      _ ->
        # Fallback to individual queries if the optimized query fails
        get_extended_stats_fallback()
    end
  end

  # Fallback function using original approach
  defp get_extended_stats_fallback do
    repo = RepoHelper.repo()

    # Basic role stats
    base_stats = get_role_stats()

    # Activity stats
    active_users = repo.one(from u in User, where: u.is_active == true, select: count(u.id))
    inactive_users = repo.one(from u in User, where: u.is_active == false, select: count(u.id))

    # Confirmation stats
    confirmed_users =
      repo.one(from u in User, where: not is_nil(u.confirmed_at), select: count(u.id))

    pending_users = repo.one(from u in User, where: is_nil(u.confirmed_at), select: count(u.id))

    Map.merge(base_stats, %{
      active_users: active_users,
      inactive_users: inactive_users,
      confirmed_users: confirmed_users,
      pending_users: pending_users
    })
  end

  @doc """
  Counts users with a specific role.

  ## Parameters

  - `role_name`: The name of the role to count

  ## Examples

      iex> count_users_with_role("Admin")
      3
  """
  def count_users_with_role(role_name) when is_binary(role_name) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        join: role in assoc(assignment, :role),
        where: role.name == ^role_name,
        select: count(assignment.id)

    repo.one(query) || 0
  end

  @doc """
  Promotes a user to admin role.

  ## Parameters

  - `user`: The user to promote
  - `assigned_by` (optional): The user who is doing the promotion

  ## Examples

      iex> promote_to_admin(user)
      {:ok, %RoleAssignment{}}
  """
  def promote_to_admin(%User{} = user, assigned_by \\ nil) do
    # Admin role can be assigned through normal process
    roles = Role.system_roles()
    assign_role_internal(user, roles.admin, assigned_by)
  end

  @doc """
  Safely demotes a user from Admin or Owner role with protection.

  Prevents demotion of last Owner to maintain system security.

  ## Parameters

  - `user`: The user to demote

  ## Examples

      iex> demote_to_user(admin_user)
      {:ok, %RoleAssignment{}}

      iex> demote_to_user(last_owner)
      {:error, :cannot_demote_last_owner}
  """
  def demote_to_user(%User{} = user) do
    roles = Role.system_roles()

    cond do
      user_has_role?(user, roles.owner) ->
        # Use safe removal for Owner role
        safely_remove_role(user, roles.owner)

      user_has_role?(user, roles.admin) ->
        # Admin can be demoted safely
        remove_role(user, roles.admin)

      true ->
        # User has no roles to demote from
        {:error, :no_role_to_demote}
    end
  end

  @doc """
  Counts active users with Owner role.

  Critical security function - ensures we never have zero owners.

  ## Examples

      iex> count_active_owners()
      1
  """
  def count_active_owners do
    repo = RepoHelper.repo()

    roles = Role.system_roles()

    query =
      from user in User,
        join: assignment in assoc(user, :role_assignments),
        join: role in assoc(assignment, :role),
        where: role.name == ^roles.owner,
        where: user.is_active == true,
        select: count(user.id)

    repo.one(query) || 0
  end

  @doc """
  Assigns roles to existing users who don't have any PhoenixKit roles.

  This is useful for migration scenarios where PhoenixKit is installed
  into an existing application with users.

  ## Parameters

  - `opts`: Options for role assignment
    - `:make_first_owner` (default: true) - Make first user without roles an Owner

  ## Returns

  - `{:ok, stats}` with assignment statistics
  - `{:error, reason}` on failure

  ## Examples

      iex> assign_roles_to_existing_users()
      {:ok, %{assigned_owner: 1, assigned_users: 5, total_processed: 6}}
  """
  def assign_roles_to_existing_users(opts \\ []) do
    repo = RepoHelper.repo()
    make_first_owner = Keyword.get(opts, :make_first_owner, true)

    repo.transaction(fn ->
      # Find users without any role assignments
      users_without_roles =
        repo.all(
          from u in User,
            left_join: assignment in assoc(u, :role_assignments),
            where: is_nil(assignment.id),
            where: u.is_active == true,
            order_by: u.inserted_at
        )

      case users_without_roles do
        [] ->
          %{assigned_owner: 0, assigned_users: 0, total_processed: 0}

        users ->
          # Check if we need to assign Owner role
          existing_owner_count = count_active_owners()

          {owner_assignments, user_assignments} =
            assign_roles_to_users(users, make_first_owner, existing_owner_count)

          %{
            assigned_owner: owner_assignments,
            assigned_users: user_assignments,
            total_processed: length(users)
          }
      end
    end)
  end

  # Private helper to assign roles to users with reduced nesting
  defp assign_roles_to_users(users, make_first_owner, existing_owner_count) do
    roles = Role.system_roles()

    if make_first_owner && existing_owner_count == 0 do
      # Assign Owner to first user, User to rest
      [first_user | rest_users] = users
      owner_result = assign_role_internal(first_user, roles.owner)
      user_results = Enum.map(rest_users, &assign_role_internal(&1, roles.user))

      {
        if(match?({:ok, _}, owner_result), do: 1, else: 0),
        Enum.count(user_results, &match?({:ok, _}, &1))
      }
    else
      # Assign User role to all
      user_results = Enum.map(users, &assign_role_internal(&1, roles.user))
      {0, Enum.count(user_results, &match?({:ok, _}, &1))}
    end
  end

  @doc """
  Safely assigns Owner role to first user using database transaction.

  This function prevents race conditions by using FOR UPDATE lock.

  ## Parameters

  - `user`: The user to potentially make Owner

  ## Returns

  - `{:ok, :owner}` if user became Owner
  - `{:ok, :user}` if user became regular User
  - `{:error, reason}` on failure

  ## Examples

      iex> ensure_first_user_is_owner(user)
      {:ok, :owner}
  """
  def ensure_first_user_is_owner(%User{} = user) do
    repo = RepoHelper.repo()

    roles = Role.system_roles()

    repo.transaction(fn ->
      # Lock the Owner role AND count existing active owners in a single atomic query
      # This prevents race conditions during concurrent user registrations
      result =
        repo.one(
          from r in Role,
            left_join: assignment in RoleAssignment,
            on: assignment.role_id == r.id,
            left_join: u in User,
            on: assignment.user_id == u.id and u.is_active == true,
            where: r.name == ^roles.owner,
            lock: "FOR UPDATE",
            select: {r, count(u.id)}
        )

      case result do
        {_owner_role, 0} ->
          # No active owners exist, make this user Owner
          case assign_role_internal(user, roles.owner) do
            {:ok, _assignment} ->
              # Activate and confirm first owner
              maybe_activate_first_owner(user, true, :owner, repo)

            {:error, reason} ->
              repo.rollback(reason)
          end

        {_owner_role, _count} ->
          # Active owners exist, assign default role
          default_role_name = get_safe_default_role()

          case assign_role_internal(user, default_role_name) do
            {:ok, _assignment} ->
              String.to_atom(String.downcase(default_role_name))

            {:error, reason} ->
              repo.rollback(reason)
          end
      end
    end)
  end

  # Activate and confirm first owner if needed
  defp maybe_activate_first_owner(user, is_first_owner, role_type, repo) do
    if is_first_owner do
      changes = build_owner_changes(user)
      apply_owner_changes(user, changes, role_type, repo)
    else
      role_type
    end
  end

  # Build changes map for first owner (activation and email confirmation)
  defp build_owner_changes(user) do
    %{}
    |> maybe_add_is_active(user.is_active)
    |> maybe_add_confirmed_at(user.confirmed_at)
  end

  # Add is_active flag if user is not active
  defp maybe_add_is_active(changes, true), do: changes
  defp maybe_add_is_active(changes, false), do: Map.put(changes, :is_active, true)

  # Add confirmed_at timestamp if user email is not confirmed
  defp maybe_add_confirmed_at(changes, nil) do
    Map.put(changes, :confirmed_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end

  defp maybe_add_confirmed_at(changes, _confirmed_at), do: changes

  # Apply changes to user if any exist
  defp apply_owner_changes(user, changes, role_type, repo) when map_size(changes) > 0 do
    case repo.update(Ecto.Changeset.change(user, changes)) do
      {:ok, _updated_user} -> role_type
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp apply_owner_changes(_user, _changes, role_type, _repo), do: role_type

  @doc """
  Safely removes role with Owner protection.

  Prevents removal of Owner role if it would leave system without owners.

  ## Parameters

  - `user`: User to remove role from
  - `role_name`: Name of role to remove

  ## Examples

      iex> safely_remove_role(owner_user, "Owner")
      {:error, :cannot_remove_last_owner}

      iex> safely_remove_role(admin_user, "Admin")
      {:ok, %RoleAssignment{}}
  """
  def safely_remove_role(%User{} = user, role_name) when role_name == "Owner" do
    repo = RepoHelper.repo()

    repo.transaction(fn ->
      remaining_owners = count_remaining_owners(repo, user.id)

      if remaining_owners < 1 do
        repo.rollback(:cannot_remove_last_owner)
      else
        execute_role_removal(user, role_name, repo)
      end
    end)
  end

  def safely_remove_role(%User{} = user, role_name) do
    # Non-Owner roles can be removed safely
    remove_role(user, role_name)
  end

  @doc """
  Checks if user can be deactivated safely.

  Prevents deactivation of last active Owner.

  ## Parameters

  - `user`: User to check for deactivation

  ## Examples

      iex> can_deactivate_user?(last_owner)
      {:error, :cannot_deactivate_last_owner}

      iex> can_deactivate_user?(regular_user)
      :ok
  """
  def can_deactivate_user?(%User{} = user) do
    roles = Role.system_roles()

    if user_has_role?(user, roles.owner) do
      case count_active_owners() do
        count when count <= 1 -> {:error, :cannot_deactivate_last_owner}
        _ -> :ok
      end
    else
      :ok
    end
  end

  # Private helper functions

  defp execute_role_removal(user, role_name, repo) do
    case remove_role(user, role_name) do
      {:ok, assignment} -> assignment
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp count_remaining_owners(repo, excluding_user_id) do
    roles = Role.system_roles()

    repo.one(
      from u in User,
        join: assignment in assoc(u, :role_assignments),
        join: role in assoc(assignment, :role),
        where: role.name == ^roles.owner,
        where: u.is_active == true,
        where: u.id != ^excluding_user_id,
        select: count(u.id)
    ) || 0
  end

  @doc """
  Updates a role.

  ## Parameters

  - `role`: The role to update
  - `attrs`: Attributes to update

  ## Examples

      iex> update_role(role, %{description: "Updated description"})
      {:ok, %Role{}}

      iex> update_role(system_role, %{name: "NewName"})
      {:error, %Ecto.Changeset{}}
  """
  def update_role(%Role{} = role, attrs) do
    repo = RepoHelper.repo()

    case role
         |> Role.changeset(attrs)
         |> repo.update() do
      {:ok, updated_role} ->
        # Broadcast role update event
        Events.broadcast_role_updated(updated_role)
        {:ok, updated_role}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a role safely.

  Prevents deletion of system roles and roles currently assigned to users.

  ## Parameters

  - `role`: The role to delete

  ## Examples

      iex> delete_role(custom_role)
      {:ok, %Role{}}

      iex> delete_role(system_role)
      {:error, :system_role_protected}

      iex> delete_role(role_with_users)
      {:error, :role_in_use}
  """
  def delete_role(%Role{} = role) do
    repo = RepoHelper.repo()

    cond do
      role.is_system_role ->
        {:error, :system_role_protected}

      role_has_assignments?(role) ->
        {:error, :role_in_use}

      true ->
        case repo.delete(role) do
          {:ok, deleted_role} ->
            # Broadcast role deletion event
            Events.broadcast_role_deleted(deleted_role)
            {:ok, deleted_role}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Synchronizes user roles with a given list of role names.

  This function ensures the user has exactly the specified roles.

  ## Parameters

  - `user`: The user to synchronize roles for
  - `role_names`: List of role names the user should have

  ## Examples

      iex> sync_user_roles(user, ["Admin", "Manager"])
      {:ok, [%RoleAssignment{}, %RoleAssignment{}]}
  """
  def sync_user_roles(%User{} = user, role_names) when is_list(role_names) do
    repo = RepoHelper.repo()

    case repo.transaction(fn ->
           # Get current user roles
           current_roles = get_user_roles(user)

           # Determine roles to add and remove
           roles_to_add = role_names -- current_roles
           roles_to_remove = current_roles -- role_names

           # Remove roles that should not be present
           Enum.each(roles_to_remove, &remove_role_or_rollback(user, &1, repo))

           # Add roles that should be present
           assignments = Enum.map(roles_to_add, &assign_role_or_rollback(user, &1, repo))

           new_user_roles = get_user_roles(user)

           %{assignments: assignments, new_user_roles: new_user_roles}
         end) do
      {:ok, %{assignments: assignments, new_user_roles: new_user_roles}} ->
        Events.broadcast_user_roles_synced(user, new_user_roles)
        ScopeNotifier.broadcast_roles_updated(user)

        {:ok, assignments}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets only custom (non-system) roles.

  ## Examples

      iex> get_custom_roles()
      [%Role{name: "Manager"}, %Role{name: "Editor"}]
  """
  def get_custom_roles do
    repo = RepoHelper.repo()

    query =
      from role in Role,
        where: role.is_system_role == false,
        order_by: role.name

    repo.all(query)
  end

  # Private helper functions

  defp remove_role_or_rollback(user, role_name, repo) do
    case remove_role(user, role_name, broadcast: false) do
      {:ok, _} -> :ok
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp assign_role_or_rollback(user, role_name, repo) do
    case assign_role(user, role_name, nil, broadcast: false) do
      {:ok, assignment} -> assignment
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp role_has_assignments?(%Role{} = role) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        where: assignment.role_id == ^role.id

    repo.exists?(query)
  end

  defp get_assignment(user_id, role_name) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        join: role in assoc(assignment, :role),
        where: assignment.user_id == ^user_id,
        where: role.name == ^role_name

    repo.one(query)
  end

  # Gets the safe default role for new users from settings
  # Always falls back to "User" role if setting is invalid or missing
  # Allows any valid role except Owner (which is reserved for first user)
  defp get_safe_default_role do
    roles = Role.system_roles()

    # Get configured role with fallback to "User"
    configured_role = PhoenixKit.Settings.get_setting("new_user_default_role", roles.user)

    # Validate the setting value against all non-Owner roles for security
    all_roles = list_roles()

    allowed_roles =
      all_roles
      |> Enum.reject(fn role -> role.name == roles.owner end)
      |> Enum.map(fn role -> role.name end)

    if configured_role in allowed_roles do
      configured_role
    else
      # Safe fallback if setting is corrupted, invalid, or somehow set to Owner
      roles.user
    end
  end
end
