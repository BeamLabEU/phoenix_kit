defmodule PhoenixKit.API.ServiceUsers do
  @moduledoc """
  Service users: accounts that exist only to own API keys.

  A service user is an ordinary `phoenix_kit_users` row with `api_only: true`, a
  non-deliverable address `api-<uuid>@service.invalid` (the `.invalid` TLD never
  resolves) and a random password hash nobody knows. It holds the roles its
  creator chose, so a key owned by it is limited by those roles' permissions
  exactly as a key owned by a person is. Every web authentication entry point
  refuses `api_only` users (see the `api_only` guards in `PhoenixKit.Users.Auth`
  and `PhoenixKitWeb.Users.Auth`), so the account can never obtain a session.

  ## Which roles a creator may give

  Only roles whose permissions are a **subset of the creator's own**, and never
  the Owner role. An `api` holder with narrow rights therefore cannot build a
  more powerful identity than themselves.

  The user is created directly, not through `Auth.register_user/2`: that path
  would promote it to Owner on an install without one, add the default `User`
  role, send mail and rate-limit the creator.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles

  @email_domain "service.invalid"
  @default_name "API service user"
  @max_name_length 100

  @doc """
  Creates a service user holding `roles` (a list of role names) on behalf of the
  person behind `creator_scope`.

  `attrs` takes `roles` and an optional `name` (shown in the user list).

  Errors: `:forbidden` when the creator does not hold `api`;
  `:role_not_allowed` when any role is unknown, is the Owner role or carries a
  permission the creator lacks (nothing is created); a changeset when the name is
  invalid.
  """
  @spec create(Scope.t(), %{optional(:name) => String.t(), roles: [String.t()]}) ::
          {:ok, User.t()} | {:error, :forbidden | :role_not_allowed | Ecto.Changeset.t()}
  def create(%Scope{} = creator_scope, attrs) when is_map(attrs) do
    role_names = Map.get(attrs, :roles, [])

    with :ok <- authorize(creator_scope),
         :ok <- check_roles(creator_scope, role_names),
         {:ok, user} <- insert(creator_scope.user, Map.get(attrs, :name), role_names) do
      log_created(user, role_names, creator_scope.user.uuid)
      {:ok, user}
    end
  end

  @doc """
  The roles the person behind `creator_scope` may give to a service user: not the
  Owner role, and only roles whose permissions the creator holds in full. Empty
  for someone who does not hold `api`.
  """
  @spec allowed_roles(Scope.t()) :: [Role.t()]
  def allowed_roles(%Scope{} = creator_scope) do
    case authorize(creator_scope) do
      :ok -> Enum.filter(Roles.list_roles(), &assignable?(creator_scope, &1))
      {:error, :forbidden} -> []
    end
  end

  @doc """
  The service users the person behind `scope` may see and hand keys to: all of
  them for an Owner, the ones they created for any other holder of `api`, none
  for someone without `api`. Oldest first.
  """
  @spec list(Scope.t()) :: [User.t()]
  def list(%Scope{user: %User{uuid: user_uuid}} = scope) do
    base = from(u in User, where: u.api_only == true, order_by: [asc: u.inserted_at, asc: u.uuid])

    cond do
      not Scope.can?(scope, "api") -> []
      Scope.owner?(scope) -> repo().all(base)
      true -> repo().all(from(u in base, where: u.created_by_uuid == ^user_uuid))
    end
  end

  def list(_scope), do: []

  defp authorize(%Scope{user: %User{managed_by_members: true}}), do: {:error, :forbidden}

  defp authorize(%Scope{user: %User{}} = scope) do
    if Scope.can?(scope, "api"), do: :ok, else: {:error, :forbidden}
  end

  defp authorize(_scope), do: {:error, :forbidden}

  defp check_roles(_scope, role_names) when not is_list(role_names),
    do: {:error, :role_not_allowed}

  defp check_roles(creator_scope, role_names) do
    allowed = creator_scope |> allowed_roles() |> MapSet.new(& &1.name)

    if Enum.all?(role_names, &(is_binary(&1) and MapSet.member?(allowed, &1))),
      do: :ok,
      else: {:error, :role_not_allowed}
  end

  # A failed read of the role's keys refuses (not `[]`, which would pass).
  defp assignable?(creator_scope, %Role{name: name} = role) do
    name != Role.system_roles().owner and
      case Permissions.fetch_permissions_for_role(to_string(role.uuid)) do
        {:ok, keys} -> Scope.has_all_module_access?(creator_scope, keys)
        {:error, _} -> false
      end
  end

  defp insert(creator, name, role_names) do
    repo().transaction(fn ->
      with {:ok, user} <- repo().insert(user_changeset(creator, name)),
           :ok <- assign_roles(user, role_names, creator) do
        user
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp user_changeset(creator, name) do
    id = UUIDv7.generate()

    %User{uuid: id}
    |> Ecto.Changeset.change(%{
      email: "api-#{id}@#{@email_domain}",
      username: "api_" <> String.slice(id, -12, 12),
      first_name: display_name(name),
      hashed_password: random_password_hash(),
      confirmed_at: DateTime.truncate(DateTime.utc_now(), :second),
      is_active: true,
      api_only: true,
      created_by_uuid: creator.uuid
    })
    |> Ecto.Changeset.validate_length(:first_name, max: @max_name_length)
    |> Ecto.Changeset.unique_constraint(:email)
    |> Ecto.Changeset.unique_constraint(:username, name: :phoenix_kit_users_username_uidx)
  end

  defp display_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> @default_name
      trimmed -> trimmed
    end
  end

  defp display_name(_name), do: @default_name

  # The account has no password anyone knows: the hash is of random bytes.
  defp random_password_hash do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> Bcrypt.hash_pwd_salt()
  end

  defp assign_roles(user, role_names, creator) do
    Enum.reduce_while(role_names, :ok, fn role_name, :ok ->
      case Roles.assign_role(user, role_name, creator, broadcast: false) do
        {:ok, _assignment} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp log_created(user, role_names, creator_uuid) do
    Activity.log("api", "api.service_user_created",
      actor_uuid: creator_uuid,
      resource_type: "user",
      resource_uuid: user.uuid,
      permanent: true,
      metadata: %{"name" => user.first_name, "email" => user.email, "roles" => role_names}
    )
  end

  defp repo, do: RepoHelper.repo()
end
