defmodule PhoenixKit.Users.ActingLink do
  @moduledoc """
  What a person's link to an organization gives them while they act for it.

  An acting session belongs to the organization, so its roles are the organization's.
  The link narrows them: `narrow/2` keeps the roles the organization holds that are
  also on the link, and a link can never give what the organization does not have.

  `PhoenixKit.Users.Auth.Scope.for_user/2`, `PhoenixKit.Users.ActiveRole` and the
  session lists all go through here, so they cannot disagree.

  The link reaches a scope through `%User{organization_manager_uuid: _}`, a virtual
  field only the session token loader fills. A link named there that is gone gives `nil`,
  and `narrow/2` answers no roles.

  ## Outside a session

  A scope built from a bare organization (a background job, a module checking an
  account by uuid) has no link to go by. `outside_session/1` limits it to the roles
  **every** link allows, so it is never wider than any person's session could be. While
  nobody is narrowed that is all the organization's roles, as it always was: a site that
  never narrows sees no change.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Role

  @type t :: %{
          uuid: String.t(),
          organization_uuid: String.t(),
          type_key: String.t(),
          can_manage?: boolean(),
          all_roles?: boolean(),
          role_uuids: [String.t()]
        }

  @doc "The link of the session `user` was loaded from, or `nil`."
  @spec for_user(User.t()) :: t() | nil
  def for_user(%User{managed_by_members: true, organization_manager_uuid: uuid} = user)
      when is_binary(uuid) do
    case load_many([uuid]) do
      %{^uuid => %{organization_uuid: organization} = link} when organization == user.uuid -> link
      _ -> nil
    end
  end

  def for_user(%User{}), do: nil

  @doc """
  Whether `user` is a session acting for an organization through a link that does not
  manage it (staff). Staff keep their own preferences but do not change the company's
  profile. Read from the link each time, so a link changed during the session counts at
  once.
  """
  @spec staff?(User.t()) :: boolean()
  def staff?(%User{organization_manager_uuid: uuid} = user) when is_binary(uuid),
    do: not match?(%{can_manage?: true}, for_user(user))

  def staff?(%User{}), do: false

  @doc """
  What limits a managed organization's roles when `user` did not come from a session, to
  give `narrow/2`: every narrowed link's list in common. See the module documentation.

  A user that names a link did come from a session, so `for_user/1` answers for it; if
  that found nothing, the link is gone and this is `nil` as well.
  """
  @spec outside_session(User.t()) :: %{all_roles?: boolean(), role_uuids: [String.t()]} | nil
  def outside_session(%User{organization_manager_uuid: uuid}) when is_binary(uuid), do: nil

  def outside_session(%User{uuid: organization}) do
    lists =
      RepoHelper.repo().all(
        from(m in OrganizationManager,
          left_join: role in assoc(m, :role_links),
          where: m.organization_uuid == ^organization and not m.all_roles,
          select: {m.uuid, role.role_uuid}
        )
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.values()

    case lists do
      [] ->
        %{all_roles?: true, role_uuids: []}

      lists ->
        common =
          lists
          |> Enum.map(&MapSet.new(Enum.reject(&1, fn role -> is_nil(role) end)))
          |> Enum.reduce(&MapSet.intersection/2)

        %{all_roles?: false, role_uuids: MapSet.to_list(common)}
    end
  end

  @doc "The links with these uuids, keyed by uuid. `nil`s are ignored."
  @spec load_many([String.t() | nil]) :: %{optional(String.t()) => t()}
  def load_many(uuids) when is_list(uuids) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> %{}
      uuids -> uuids |> rows() |> Enum.group_by(&elem(&1, 0)) |> Map.new(&to_link/1)
    end
  end

  defp rows(uuids) do
    RepoHelper.repo().all(
      from(m in OrganizationManager,
        join: type in assoc(m, :relationship_type),
        left_join: role in assoc(m, :role_links),
        where: m.uuid in ^uuids,
        select:
          {m.uuid, m.organization_uuid, type.key, type.can_manage, m.all_roles, role.role_uuid}
      )
    )
  end

  defp to_link({uuid, [{_, organization, key, can_manage, all_roles, _} | _] = rows}) do
    {uuid,
     %{
       uuid: uuid,
       organization_uuid: organization,
       type_key: key,
       can_manage?: can_manage,
       all_roles?: all_roles,
       role_uuids: for({_, _, _, _, _, role} <- rows, role, do: role)
     }}
  end

  @doc """
  The roles of `roles` that `link` allows: all of them for an `all_roles` link, else
  the listed ones. The `User` system role stays, as it does through the role switcher:
  it is a baseline, not something to tick. No link means no roles.
  """
  @spec narrow([role], %{all_roles?: boolean(), role_uuids: [String.t()]} | nil) :: [role]
        when role: %{uuid: String.t(), name: String.t()}
  def narrow(_roles, nil), do: []
  def narrow(roles, %{all_roles?: true}), do: roles

  def narrow(roles, %{role_uuids: listed}) do
    base = Role.system_roles().user
    Enum.filter(roles, &(&1.name == base or &1.uuid in listed))
  end
end
