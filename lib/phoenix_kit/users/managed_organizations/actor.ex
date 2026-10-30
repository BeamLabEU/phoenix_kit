defmodule PhoenixKit.Users.ManagedOrganizations.Actor do
  @moduledoc """
  Internal browser authority for organization lifecycle operations.

  Construct only from the trusted signed cookie session, in a controller or a
  connected LiveView mount. Never accept this credential or its references from
  request parameters/events. A bare User or Scope cannot prove that an Admin is
  in their own account rather than a borrowed account in a session stack.

  References carry no raw tokens. Contexts lock the organization and the actor's
  user row before `authorize/2`; authority is rebuilt from live session rows on
  every mutation. This is not a public creation or switching surface.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitWeb.Users.MultiSession

  @enforce_keys [:current, :root]
  defstruct [:current, :root]

  def from_session(session) when is_map(session) do
    with {:ok, current} <- SessionRef.from_session(session),
         [root_token | _] <- MultiSession.stack_tokens(session),
         {:ok, root} <- SessionRef.from_session(%{"user_token" => root_token}) do
      {:ok, %__MODULE__{current: current, root: root}}
    else
      _ -> {:error, :forbidden}
    end
  end

  def from_session(_), do: {:error, :forbidden}

  def person_uuid(%__MODULE__{root: {_token, uuid}}) when is_binary(uuid), do: uuid
  def person_uuid(_), do: nil

  def authorize(actor, organization_uuid \\ nil)

  def authorize(%__MODULE__{current: {token, user}, root: {parent, person}} = actor, org) do
    with true <- Enum.all?([token, user, parent, person], &UUIDUtils.valid?/1),
         %UserToken{} = root <- lock_token(parent),
         true <- root.user_uuid == person,
         :ok <- lock_grant(actor, org),
         %UserToken{} <- lock_token(token),
         {:ok, root_scope} <- SessionRef.scope_for_session(parent, person),
         {:ok, scope} <- SessionRef.scope_for_session(token, user) do
      authority(actor, org, root_scope, scope)
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(_, _), do: {:error, :forbidden}

  def admin(actor) do
    case authorize(actor) do
      {:ok, %{kind: :admin} = authority} -> {:ok, authority}
      _ -> {:error, :forbidden}
    end
  end

  defp lock_token(uuid) do
    RepoHelper.repo().one(from(t in UserToken, where: t.uuid == ^uuid, lock: "FOR KEY SHARE"),
      log: false
    )
  end

  defp lock_grant(%{current: ref, root: ref}, _org), do: :ok

  defp lock_grant(%{root: {_parent, person}}, org) when is_binary(org) do
    case RepoHelper.repo().one(
           from(m in OrganizationManager,
             where: m.organization_uuid == ^org and m.user_uuid == ^person,
             lock: "FOR KEY SHARE"
           )
         ) do
      %OrganizationManager{} -> :ok
      _ -> :error
    end
  end

  defp lock_grant(_, _), do: :error

  defp authority(%{current: ref, root: ref}, _org, _root, scope) do
    if not scope.user.managed_by_members and
         (Scope.owner?(scope) or Scope.has_role?(scope, "Admin")) do
      {:ok,
       %{kind: :admin, scope: scope, person_uuid: scope.user.uuid, actor_uuid: scope.user.uuid}}
    else
      {:error, :forbidden}
    end
  end

  defp authority(%{root: {parent, person}}, org, root, scope) do
    user = scope.user

    if user.uuid == org and user.managed_by_members and user.acting_user_uuid == person and
         user.acting_session_uuid == parent and root.user.account_type == "person" do
      {:ok, %{kind: :manager, scope: scope, person_uuid: person, actor_uuid: user.uuid}}
    else
      {:error, :forbidden}
    end
  end
end
