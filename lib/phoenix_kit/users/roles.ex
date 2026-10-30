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

  ## Who may change roles

  Every entry point that gives a role, takes one away or deletes one accepts an
  `:actor` (a `%User{}` or a `%Scope{}`; omitted or `:system` = unrestricted, for
  seeding and system callers). With a real actor the rule is
  `can_manage_role?/2`: an Owner may do anything; anyone else only for a role
  that is neither Owner nor Admin and whose every permission key they hold
  themselves (a role holding `"*"` only by a holder of `"*"`). Nobody but an
  Owner changes their own roles (`{:error, :cannot_modify_own_roles}`).

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
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.{Role, RoleAssignment, ScopeNotifier}
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @doc """
  Assigns a role to a user.

  ## Security

  The Owner role cannot be assigned through this function to maintain system security.
  Only one Owner is automatically assigned during initialization.

  ## Parameters

  - `user`: The user to assign the role to
  - `role_name`: The name of the role to assign
  - `assigned_by` (optional): The user who is assigning the role
  - `opts`: `:broadcast` (default `true`); `:actor` — the acting `%User{}` or
    `%Scope{}`, checked against `can_manage_role?/2` and the own-roles rule
    (`{:error, :not_permitted}` / `{:error, :cannot_modify_own_roles}`).
    Omitted = a system caller, unchecked.

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

    cond do
      # Prevent manual assignment of Owner role
      role_name == roles.owner ->
        {:error, :owner_role_protected}

      (refusal = actor_refusal(Keyword.get(opts, :actor, :system), user, role_name)) != :ok ->
        refusal

      true ->
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
        repo.transaction(fn ->
          # Conversion and assignment share the user-row lock. Recheck policy
          # after acquiring it: a form may still hold an unmanaged struct.
          repo.one(from(u in User, where: u.uuid == ^user.uuid, lock: "FOR NO KEY UPDATE"))

          with :ok <- managed_role_allowed(user, role),
               {:ok, assignment} <-
                 insert_role_assignment(repo, user, role, assigned_by, broadcast?) do
            assignment
          else
            {:error, reason} -> repo.rollback(reason)
          end
        end)
    end
  end

  defp managed_role_allowed(user, role) do
    case RepoHelper.repo().get(User, user.uuid) do
      %User{managed_by_members: true} ->
        with false <- Scope.managed_ceiling_role?(role.name),
             {:ok, keys} <- Permissions.fetch_permissions_for_role(to_string(role.uuid)),
             false <- Enum.any?(keys, &Scope.managed_ceiling_key?/1) do
          :ok
        else
          _ -> {:error, :managed_organization_role_not_allowed}
        end

      %User{} ->
        :ok

      nil ->
        {:error, :user_not_found}
    end
  end

  defp insert_role_assignment(repo, user, role, assigned_by, broadcast?) do
    attrs = %{
      user_uuid: user.uuid,
      role_uuid: role.uuid,
      assigned_by_uuid: assigned_by && assigned_by.uuid
    }

    # Use upsert with ON CONFLICT DO NOTHING for idempotency
    # This prevents duplicate role assignment errors during concurrent operations
    %RoleAssignment{}
    |> RoleAssignment.changeset(attrs)
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_uuid, :role_uuid]
    )
    |> case do
      {:ok, assignment} ->
        if broadcast? do
          Events.broadcast_user_role_assigned(user, role.name)
          ScopeNotifier.broadcast_roles_updated(user)
        end

        {:ok, assignment}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Removes a role from a user by deleting the assignment.

  ## Parameters

  - `user`: The user to remove the role from
  - `role_name`: The name of the role to remove
  - `opts`: `:broadcast` (default `true`); `:actor`, as for `assign_role/4`

  ## Examples

      iex> remove_role(user, "Admin")
      {:ok, %RoleAssignment{}}

      iex> remove_role(user, "NonexistentRole")
      {:error, :assignment_not_found}
  """
  def remove_role(%User{} = user, role_name, opts \\ []) when is_binary(role_name) do
    repo = RepoHelper.repo()
    broadcast? = Keyword.get(opts, :broadcast, true)

    with :ok <- actor_refusal(Keyword.get(opts, :actor, :system), user, role_name) do
      do_remove_role(repo, user, role_name, broadcast?)
    end
  end

  defp do_remove_role(repo, user, role_name, broadcast?) do
    case get_assignment(user.uuid, role_name) do
      nil ->
        {:error, :assignment_not_found}

      assignment ->
        case repo.delete(assignment) do
          {:ok, deleted_assignment} ->
            # A session ACTING as the removed role is signed out rather than
            # silently moved to another role (`PhoenixKit.Users.ActiveRole`):
            # the person starts over and lands in whatever they still hold.
            # Sessions in another role keep going and get the refresh below.
            Sessions.revoke_user_sessions_in_role(user, deleted_assignment.role_uuid)

            if broadcast? do
              Events.broadcast_user_role_removed(user, role_name)
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
        where: assignment.user_uuid == ^user.uuid,
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
        where: assignment.user_uuid == ^user.uuid,
        select: role.name,
        order_by: role.name

    repo.all(query)
  end

  @doc """
  Gets the roles a user holds as `%{uuid, name}` maps, in **role order**
  (`position`, then name).

  The same query as `get_user_roles/1`, keeping the uuid: the active-role
  resolution in `PhoenixKit.Users.ActiveRole` identifies roles by uuid, because
  role names are editable — and relies on this order: the first switchable
  role here is a session's default.
  """
  @spec get_user_role_records(User.t()) :: [%{uuid: String.t(), name: String.t()}]
  def get_user_role_records(%User{} = user) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        join: role in assoc(assignment, :role),
        where: assignment.user_uuid == ^user.uuid,
        select: %{uuid: role.uuid, name: role.name},
        order_by: [asc: role.position, asc: role.name]

    repo.all(query)
  end

  @doc """
  `get_user_role_records/1` for many users at once: `%{user_uuid => [role]}`,
  each list in role order. Users holding no role are absent.
  """
  @spec get_role_records_for_users([String.t()]) :: %{
          optional(String.t()) => [%{uuid: String.t(), name: String.t()}]
        }
  def get_role_records_for_users([]), do: %{}

  def get_role_records_for_users(user_uuids) when is_list(user_uuids) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        join: role in assoc(assignment, :role),
        where: assignment.user_uuid in ^Enum.uniq(user_uuids),
        select: {assignment.user_uuid, %{uuid: role.uuid, name: role.name}},
        order_by: [asc: role.position, asc: role.name]

    query
    |> repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
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
        distinct: user.uuid,
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

    case %Role{position: next_position(repo)}
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
  Gets a single role by its UUID.

  Returns `nil` if no role is found.

  ## Parameters

  - `uuid`: The UUID of the role to find

  ## Examples

      iex> get_role_by_uuid("01234567-89ab-cdef-0123-456789abcdef")
      %Role{uuid: "01234567-89ab-cdef-0123-456789abcdef", name: "Editor"}

      iex> get_role_by_uuid("nonexistent-uuid")
      nil
  """
  def get_role_by_uuid(uuid) when is_binary(uuid) do
    repo = RepoHelper.repo()
    repo.get_by(Role, uuid: uuid)
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
        order_by: [asc: role.position, asc: role.name]

    repo.all(query)
  end

  @doc """
  One page of roles for the admin list, system roles first, then by name.

  Options `:page` (default 1) and `:per_page` (default 25). Returns
  `%{roles: [...], total_count: n, total_pages: n, page: n}` — `page` is
  clamped into `[1, total_pages]` before the offset is applied, so a link
  past the end (the last custom role on the last page was just deleted)
  shows the last page rather than an empty one.
  """
  def list_roles_paginated(opts \\ []) do
    repo = RepoHelper.repo()
    per_page = Keyword.get(opts, :per_page, 25)

    total_count = repo.aggregate(Role, :count)
    total_pages = max(div(total_count + per_page - 1, per_page), 1)
    page = opts |> Keyword.get(:page, 1) |> max(1) |> min(total_pages)

    roles =
      from(role in Role,
        order_by: [asc: role.position, asc: role.name],
        limit: ^per_page,
        offset: ^((page - 1) * per_page)
      )
      |> repo.all()

    %{roles: roles, total_count: total_count, total_pages: total_pages, page: page}
  end

  @doc """
  Role counts for the admin list's summary cards: `%{total: n, system: n, custom: n}`.
  """
  def count_roles do
    repo = RepoHelper.repo()

    {total, system} =
      repo.one(
        from(role in Role,
          select: {count(role.uuid), count(role.uuid) |> filter(role.is_system_role)}
        )
      )

    %{total: total, system: system, custom: total - system}
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

    total_users_query = from(u in User, select: count(u.uuid))
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
        JOIN phoenix_kit_user_roles r ON r.uuid = ra.role_uuid
        WHERE r.name = $1
      ), 0) as owner_count,
      COALESCE((
        SELECT COUNT(*)
        FROM phoenix_kit_user_role_assignments ra
        JOIN phoenix_kit_user_roles r ON r.uuid = ra.role_uuid
        WHERE r.name = $2
      ), 0) as admin_count,
      COALESCE((
        SELECT COUNT(*)
        FROM phoenix_kit_user_role_assignments ra
        JOIN phoenix_kit_user_roles r ON r.uuid = ra.role_uuid
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
    active_users = repo.one(from u in User, where: u.is_active == true, select: count(u.uuid))
    inactive_users = repo.one(from u in User, where: u.is_active == false, select: count(u.uuid))

    # Confirmation stats
    confirmed_users =
      repo.one(from u in User, where: not is_nil(u.confirmed_at), select: count(u.uuid))

    pending_users = repo.one(from u in User, where: is_nil(u.confirmed_at), select: count(u.uuid))

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
        select: count(assignment.uuid)

    repo.one(query) || 0
  end

  @doc """
  Promotes a user to admin role.

  ## Parameters

  - `user`: The user to promote
  - `assigned_by` (optional): The user who is doing the promotion
  - `opts`: `:actor` — as for `assign_role/4`. Admin is a system role, so only
    an Owner actor may promote (`{:error, :not_permitted}` otherwise). Omitted =
    a system caller (seeding, fixtures), unchecked — no web page calls this.

  ## Examples

      iex> promote_to_admin(user)
      {:ok, %RoleAssignment{}}
  """
  def promote_to_admin(%User{} = user, assigned_by \\ nil, opts \\ []) do
    roles = Role.system_roles()

    with :ok <- actor_refusal(Keyword.get(opts, :actor, :system), user, roles.admin) do
      assign_role_internal(user, roles.admin, assigned_by)
    end
  end

  @doc """
  Safely demotes a user from Admin or Owner role with protection.

  Prevents demotion of last Owner to maintain system security.

  ## Parameters

  - `user`: The user to demote
  - `opts`: `:actor` — as for `remove_role/3`: only an Owner actor may take
    Owner or Admin away. Omitted = a system caller, unchecked.

  ## Examples

      iex> demote_to_user(admin_user)
      {:ok, %RoleAssignment{}}

      iex> demote_to_user(last_owner)
      {:error, :cannot_demote_last_owner}
  """
  def demote_to_user(%User{} = user, opts \\ []) do
    roles = Role.system_roles()

    cond do
      user_has_role?(user, roles.owner) ->
        # Use safe removal for Owner role
        safely_remove_role(user, roles.owner, opts)

      user_has_role?(user, roles.admin) ->
        # Admin can be demoted safely
        remove_role(user, roles.admin, opts)

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
        select: count(user.uuid)

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
            where: is_nil(assignment.uuid),
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

  Concurrent registrations are serialized by a row lock on the Owner role row,
  taken only while no active Owner exists yet — see the transaction body.

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
      # Once an active Owner exists the answer can never flip to "you are the
      # first user", so the overwhelmingly common path — every registration
      # after the bootstrap one — decides from an unlocked read and takes no
      # lock at all. Only a genuine 0-owner install pays for the serialization.
      owner_count =
        case count_active_owners_by_name(repo, roles.owner, lock: false) do
          0 -> count_active_owners_by_name(repo, roles.owner, lock: true)
          count -> count
        end

      case owner_count do
        0 ->
          # No active owners exist, make this user Owner
          case assign_role_internal(user, roles.owner) do
            {:ok, _assignment} ->
              # Activate and confirm first owner
              activate_first_owner(user, :owner, repo)

            {:error, reason} ->
              repo.rollback(reason)
          end

        count when is_integer(count) and count > 0 ->
          # Active owners exist, assign default role
          default_role_name = default_role_for_new_users()

          case assign_role_internal(user, default_role_name) do
            {:ok, _assignment} ->
              String.to_atom(String.downcase(default_role_name))

            {:error, reason} ->
              repo.rollback(reason)
          end
      end
    end)
  end

  # Active users holding the Owner role.
  #
  # With `lock: true` the Owner role row is locked first, so that a concurrent
  # registration cannot read the same zero count and mint a second Owner. The
  # mode is FOR NO KEY UPDATE, not FOR UPDATE: these paths never touch the
  # role's key, and FOR UPDATE additionally conflicts with the FOR KEY SHARE
  # that Postgres takes on this very row for the foreign key of every
  # `phoenix_kit_user_role_assignments` insert. That made unrelated role
  # assignments queue behind registrations — and, crossed with the identical
  # lock in `Permissions.lock_role_for_update/2` on a different role row,
  # produced 40P01 deadlocks. FOR NO KEY UPDATE still excludes the other
  # writers of this row while leaving FK checks free to proceed.
  defp count_active_owners_by_name(repo, owner_role_name, opts) do
    if Keyword.fetch!(opts, :lock) do
      repo.one(
        from r in Role,
          where: r.name == ^owner_role_name,
          select: r.uuid,
          lock: "FOR NO KEY UPDATE"
      )
    end

    repo.one(
      from assignment in RoleAssignment,
        join: u in User,
        on: assignment.user_uuid == u.uuid and u.is_active == true,
        join: r in Role,
        on: r.uuid == assignment.role_uuid,
        where: r.name == ^owner_role_name,
        select: count(u.uuid)
    ) || 0
  end

  # Activate and confirm first owner
  defp activate_first_owner(user, role_type, repo) do
    changes = build_owner_changes(user)
    apply_owner_changes(user, changes, role_type, repo)
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
    Map.put(changes, :confirmed_at, UtilsDate.utc_now())
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
  - `opts`: `:actor` — as for `remove_role/3`. Omitted = a system caller.

  ## Examples

      iex> safely_remove_role(owner_user, "Owner")
      {:error, :cannot_remove_last_owner}

      iex> safely_remove_role(admin_user, "Admin")
      {:ok, %RoleAssignment{}}
  """
  def safely_remove_role(user, role_name, opts \\ [])

  def safely_remove_role(%User{} = user, "Owner" = role_name, opts) do
    repo = RepoHelper.repo()

    with :ok <- actor_refusal(Keyword.get(opts, :actor, :system), user, role_name) do
      remove_last_safe_owner(repo, user, role_name)
    end
  end

  def safely_remove_role(%User{} = user, role_name, opts) do
    # Non-Owner roles can be removed safely
    remove_role(user, role_name, opts)
  end

  defp remove_last_safe_owner(repo, user, role_name) do
    repo.transaction(fn ->
      remaining_owners = count_remaining_owners(repo, user.uuid)

      if remaining_owners < 1 do
        repo.rollback(:cannot_remove_last_owner)
      else
        execute_role_removal(user, role_name, repo)
      end
    end)
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

  defp count_remaining_owners(repo, excluding_user_uuid) do
    # Serialize EVERY Owner-removal decision at this shared chokepoint (sync,
    # safely_remove_role/demote all count here before removing an Owner), so two
    # concurrent removals can't both observe one remaining Owner and leave zero.
    # Transaction-scoped advisory lock, released on the outer commit/rollback.
    repo.query!("SELECT pg_advisory_xact_lock(hashtext('phoenix_kit_last_owner_guard'))")

    roles = Role.system_roles()

    repo.one(
      from u in User,
        join: assignment in assoc(u, :role_assignments),
        join: role in assoc(assignment, :role),
        where: role.name == ^roles.owner,
        where: u.is_active == true,
        where: u.uuid != ^excluding_user_uuid,
        select: count(u.uuid)
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
  - `opts`: `:actor` — the acting `%User{}` or `%Scope{}`. Only an actor who
    holds every key of the role may delete it (`can_manage_role?/2`; an Owner
    always): `{:error, :not_permitted}` otherwise. Omitted = a system caller.

  ## Examples

      iex> delete_role(custom_role)
      {:ok, %Role{}}

      iex> delete_role(system_role)
      {:error, :system_role_protected}

      iex> delete_role(role_with_users)
      {:error, :role_in_use}
  """
  def delete_role(%Role{} = role, opts \\ []) do
    repo = RepoHelper.repo()

    cond do
      role.is_system_role ->
        {:error, :system_role_protected}

      not can_manage_role?(Keyword.get(opts, :actor, :system), role) ->
        {:error, :not_permitted}

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

  ## Authorization (`:actor` option)

  This is the authorization boundary for role changes — **never** trust the
  caller UI to have gated it. Pass `actor: %User{}` (the acting admin) and:

  - Changes to the **system roles** (Owner, Admin) are applied only when the
    actor is an Owner. A non-Owner's attempt to grant Owner/Admin to another
    account (privilege escalation) or to strip them (the disabled-checkbox
    form drops Owner from the submitted set, which would otherwise read as a
    removal) is DROPPED — that role is left exactly as it was.
  - Any other role is changed only when the actor may manage it
    (`can_manage_role?/2`: the actor holds every permission key of the role).
    A change the actor may not make is DROPPED like a system-role change and
    its role name is returned in `:refused`, so the caller can say so.
  - A non-Owner actor may not change **their own** roles at all: the whole
    call fails with `{:error, :cannot_modify_own_roles}` when it would change
    anything.
  - The **last Owner** can never be removed, regardless of actor, via the
    same guard as `safely_remove_role/2`.

  Omitting `:actor` (or `actor: :system`) skips the actor gate — for
  seeding/system callers only — but the last-Owner guard still applies.

  ## Parameters

  - `user`: The user to synchronize roles for
  - `role_names`: List of role names the user should have
  - `opts`: `:actor` — the acting `%User{}` or `%Scope{}` (see above)

  Returns `{:ok, %{assignments: [...], roles_before: [...], roles_after: [...],
  refused: [...]}}` on success — `roles_before`/`roles_after` are the role-name lists captured
  inside the transaction, so callers can audit the exact delta this transaction
  applied (which can differ from what was submitted when unauthorized changes
  are dropped or a concurrent edit intervened).

  ## Examples

      iex> sync_user_roles(user, ["Admin", "Manager"], actor: current_user)
      {:ok, %{assignments: [%RoleAssignment{}], roles_before: ["Manager"], roles_after: ["Admin", "Manager"]}}
  """
  def sync_user_roles(user, role_names, opts \\ [])

  def sync_user_roles(%User{} = user, role_names, opts) when is_list(role_names) do
    repo = RepoHelper.repo()
    actor = actor_context(Keyword.get(opts, :actor, :system))

    case Revocation.transaction(fn ->
           # Serialize concurrent role edits for THIS user (per-user key, so
           # different users never contend), so before/after reflect only this
           # transaction's changes — an exact audit, and no interleaving.
           repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
             "pk_user_roles:#{user.uuid}"
           ])

           # The role set BEFORE this transaction's changes (read inside the
           # transaction, so it's the true baseline for an exact audit diff).
           roles_before = get_user_roles(user)

           # Determine roles to add and remove
           roles_to_add = Enum.uniq(role_names) -- roles_before
           roles_to_remove = roles_before -- role_names

           if own_roles_refused?(actor, user) and (roles_to_add != [] or roles_to_remove != []) do
             repo.rollback(:cannot_modify_own_roles)
           end

           # Drop changes the actor isn't authorized to make (system-role
           # grants/revocations require Owner; any other role needs every one
           # of its keys). Leaving them unchanged matches the disabled-checkbox
           # UI intent and blocks both escalation and the Owner-wipe; the
           # dropped names come back in `:refused`.
           {roles_to_add, refused_add} = authorize_role_changes(roles_to_add, actor)
           {roles_to_remove, refused_remove} = authorize_role_changes(roles_to_remove, actor)

           # Guard the last Owner before any removal runs
           guard_last_owner_removal(repo, user, roles_to_remove)

           # Remove roles that should not be present
           Enum.each(roles_to_remove, &remove_role_or_rollback(user, &1, repo))

           # Add roles that should be present
           assignments = Enum.map(roles_to_add, &assign_role_or_rollback(user, &1, repo))

           # The role set AFTER, still inside the transaction.
           roles_after = get_user_roles(user)

           %{
             assignments: assignments,
             roles_before: roles_before,
             roles_after: roles_after,
             refused: Enum.uniq(refused_add ++ refused_remove)
           }
         end) do
      {:ok, %{roles_after: roles_after} = result} ->
        Events.broadcast_user_roles_synced(user, roles_after)
        ScopeNotifier.broadcast_roles_updated(user)

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether `actor` may give `role` to someone, take it away from someone, delete
  it, or make it the new-user default.

  `actor` is a `%User{}`, a `%Scope{}` or `:system` (always true). An Owner (by
  their real, held roles) may manage any role. Anyone else may manage a role
  only when it is neither Owner nor Admin and they hold every permission key
  the role holds — checked against their effective permissions (the active
  role, when they act as one), so a role holding `"*"` needs `"*"`. `role` is a
  `%Role{}` or a role name; an unknown name answers false.
  """
  @spec can_manage_role?(User.t() | Scope.t() | :system, Role.t() | String.t()) :: boolean()
  def can_manage_role?(:system, _role), do: true

  def can_manage_role?(actor, role_name) when is_binary(role_name) do
    case get_role_by_name(role_name) do
      nil -> false
      role -> can_manage_role?(actor, role)
    end
  end

  def can_manage_role?(actor, %Role{} = role) do
    case actor_context(actor) do
      :system -> true
      ctx -> role_manageable?(ctx, role)
    end
  end

  @doc """
  The names of the roles `actor` may manage (`can_manage_role?/2`), in role
  order. One permissions query for all roles — for a UI that disables the rest.
  """
  @spec manageable_role_names(User.t() | Scope.t() | :system) :: [String.t()]
  def manageable_role_names(actor) do
    roles = list_roles()

    case actor_context(actor) do
      :system ->
        Enum.map(roles, & &1.name)

      %{owner?: true} ->
        Enum.map(roles, & &1.name)

      ctx ->
        case Permissions.fetch_permissions_matrix() do
          {:ok, matrix} ->
            for role <- roles,
                role_manageable?(
                  ctx,
                  role,
                  matrix |> Map.get(to_string(role.uuid)) |> keys_list()
                ),
                do: role.name

          # Unknown keys: offer nothing rather than everything.
          {:error, _} ->
            []
        end
    end
  end

  defp keys_list(nil), do: []
  defp keys_list(%MapSet{} = set), do: MapSet.to_list(set)
  defp keys_list(list) when is_list(list), do: list

  # The actor as the rules need it: who they are, whether they really hold
  # Owner, and the scope their effective permissions are read from.
  defp actor_context(:system), do: :system

  # A managed organization is never an Owner here either: `held_roles` are the
  # real role rows, and the scope's ceiling does not filter them.
  defp actor_context(%Scope{user: %User{managed_by_members: true} = user} = scope) do
    %{user: user, owner?: false, scope: scope}
  end

  defp actor_context(%Scope{user: %User{} = user} = scope) do
    %{user: user, owner?: Role.system_roles().owner in Scope.held_roles(scope), scope: scope}
  end

  defp actor_context(%User{} = user) do
    %{user: user, owner?: owner?(user), scope: Scope.for_user(user)}
  end

  # `nil`, or a scope with no user, is no actor at all: it may manage nothing.
  # (Only an omitted `:actor` or an explicit `:system` is unrestricted.)
  defp actor_context(_other), do: %{user: nil, owner?: false, scope: nil}

  # The role's keys are read without the `[]`-on-error fallback: a failed read
  # refuses, it never passes the subset check as an empty role.
  defp role_manageable?(%{owner?: true}, _role), do: true

  defp role_manageable?(ctx, role) do
    case Permissions.fetch_permissions_for_role(to_string(role.uuid)) do
      {:ok, keys} -> role_manageable?(ctx, role, keys)
      {:error, _} -> false
    end
  end

  defp role_manageable?(%{scope: scope}, %Role{name: name}, keys) do
    system = Role.system_roles()

    name not in [system.owner, system.admin] and scope != nil and
      Scope.has_all_module_access?(scope, keys)
  end

  defp own_roles_refused?(:system, _user), do: false
  defp own_roles_refused?(%{owner?: true}, _user), do: false
  defp own_roles_refused?(%{user: %User{uuid: uuid}}, %User{uuid: uuid}), do: true
  defp own_roles_refused?(_ctx, _user), do: false

  # The single-role check `assign_role/4` / `remove_role/3` apply for `:actor`.
  defp actor_refusal(actor, user, role_name) do
    case actor_context(actor) do
      :system ->
        :ok

      ctx ->
        cond do
          own_roles_refused?(ctx, user) -> {:error, :cannot_modify_own_roles}
          role_name_manageable?(ctx, role_name) -> :ok
          true -> {:error, :not_permitted}
        end
    end
  end

  defp role_name_manageable?(ctx, role_name) do
    case get_role_by_name(role_name) do
      # Unknown roles fall through to the caller's own `:role_not_found`.
      nil -> true
      role -> role_manageable?(ctx, role)
    end
  end

  # Splits the changes into `{allowed, refused}`. A system caller may change
  # any role; an unknown role name is passed on so the assignment reports
  # `:role_not_found` as before.
  defp authorize_role_changes(role_names, :system), do: {role_names, []}

  defp authorize_role_changes(role_names, ctx) do
    Enum.split_with(role_names, &role_name_manageable?(ctx, &1))
  end

  defp owner?(%User{managed_by_members: true}), do: false
  defp owner?(%User{} = user), do: Role.system_roles().owner in get_user_roles(user)

  # Blocks removing the final active Owner, mirroring safely_remove_role/2.
  defp guard_last_owner_removal(repo, %User{} = user, roles_to_remove) do
    owner = Role.system_roles().owner

    # count_remaining_owners/2 takes the shared advisory lock, so the
    # count-then-delete here is atomic against every other Owner-removal path.
    if owner in roles_to_remove and count_remaining_owners(repo, user.uuid) < 1 do
      repo.rollback(:cannot_remove_last_owner)
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
        order_by: [asc: role.position, asc: role.name]

    repo.all(query)
  end

  @doc """
  Sets the role order (`position`) to the order of `ordered_uuids`; any role
  not listed keeps its relative order after them.

  The order decides the default role of a new session and how the role
  switcher lists roles (`PhoenixKit.Users.ActiveRole`). Broadcasts
  `:role_updated` for the roles whose position changed.
  """
  @spec reorder_roles([String.t()]) :: :ok
  def reorder_roles(ordered_uuids) when is_list(ordered_uuids) do
    repo = RepoHelper.repo()
    roles = list_roles()
    listed = Enum.filter(ordered_uuids, fn uuid -> Enum.any?(roles, &(&1.uuid == uuid)) end)
    rest = roles |> Enum.map(& &1.uuid) |> Kernel.--(listed)

    changed =
      (listed ++ rest)
      |> Enum.with_index()
      |> Enum.flat_map(fn {uuid, position} ->
        role = Enum.find(roles, &(&1.uuid == uuid))

        if role.position == position do
          []
        else
          from(r in Role, where: r.uuid == ^uuid)
          |> repo.update_all(set: [position: position, updated_at: UtilsDate.utc_now()])

          [%{role | position: position}]
        end
      end)

    Enum.each(changed, &Events.broadcast_role_updated/1)
    :ok
  end

  @doc """
  Moves one role one step `:up` or `:down` in role order. A move past either
  end is a no-op.
  """
  @spec move_role(String.t(), :up | :down) :: :ok
  def move_role(role_uuid, direction) when direction in [:up, :down] do
    uuids = list_roles() |> Enum.map(& &1.uuid)

    case Enum.find_index(uuids, &(&1 == role_uuid)) do
      nil ->
        :ok

      index ->
        target = if direction == :up, do: index - 1, else: index + 1

        if target in 0..(length(uuids) - 1)//1 do
          uuids
          |> List.delete_at(index)
          |> List.insert_at(target, role_uuid)
          |> reorder_roles()
        else
          :ok
        end
    end
  end

  # Private helper functions

  defp next_position(repo) do
    case repo.one(from(r in Role, select: max(r.position))) do
      nil -> 0
      max -> max + 1
    end
  end

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
        where: assignment.role_uuid == ^role.uuid

    repo.exists?(query)
  end

  defp get_assignment(user_uuid, role_name) when is_binary(user_uuid) do
    repo = RepoHelper.repo()

    query =
      from assignment in RoleAssignment,
        join: role in assoc(assignment, :role),
        where: assignment.user_uuid == ^user_uuid,
        where: role.name == ^role_name

    repo.one(query)
  end

  @doc """
  The role a new self-registered account gets: the `new_user_default_role`
  setting when it names an existing role other than Owner and Admin, else
  "User". Owner is reserved for the first user, and Admin would hand every
  self-registered account the admin panel, so a stored value naming either is
  never used.
  """
  @spec default_role_for_new_users() :: String.t()
  def default_role_for_new_users do
    roles = Role.system_roles()

    # Get configured role with fallback to "User"
    configured_role = PhoenixKit.Settings.get_setting("new_user_default_role", roles.user)

    # Validate the setting value against all non-Owner roles for security
    all_roles = list_roles()

    allowed_roles =
      all_roles
      |> Enum.reject(fn role -> role.name in [roles.owner, roles.admin] end)
      |> Enum.map(fn role -> role.name end)

    if configured_role in allowed_roles do
      configured_role
    else
      # Safe fallback if setting is corrupted, invalid, or set to Owner/Admin
      roles.user
    end
  end
end
