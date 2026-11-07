defmodule PhoenixKit.Users.ActingLink do
  @moduledoc """
  What a person's link to an organization gives them while they act for it.

  An acting session belongs to the organization, so its roles are the organization's.
  The link narrows them: `narrow/2` keeps the roles the organization holds that are
  also on the link, and a link can never give what the organization does not have.

  `PhoenixKit.Users.Auth.Scope.for_user/2`, `PhoenixKit.Users.ActiveRole` and the
  session lists all go through here, so they cannot disagree.

  The link reaches a scope through `%User{organization_manager_uuid: _}`, a virtual
  field only the session token loader fills. An organization has no session of its
  own, so a user with no link there, or a link that is gone, gets `nil` and `narrow/2`
  answers no roles: a scope must never be wider than a session could be.
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
        select: {m.uuid, m.organization_uuid, type.key, type.can_manage, m.all_roles, role.role_uuid}
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
  @spec narrow([role], t() | nil) :: [role] when role: %{uuid: String.t(), name: String.t()}
  def narrow(_roles, nil), do: []
  def narrow(roles, %{all_roles?: true}), do: roles

  def narrow(roles, %{role_uuids: listed}) do
    base = Role.system_roles().user
    Enum.filter(roles, &(&1.name == base or &1.uuid in listed))
  end
end
