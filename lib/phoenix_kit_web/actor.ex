defmodule PhoenixKitWeb.Actor do
  @moduledoc """
  Who is acting, read from a LiveView socket, a `Plug.Conn` or an assigns
  map — the one place modules ask, instead of each reading its own assign.

  The admin `live_session` puts both `:phoenix_kit_current_scope` and
  `:phoenix_kit_current_user` on the socket. The scope is the canonical
  one (it is what permission checks read), so it wins; the bare user is
  the fallback for callers that only have that — a test harness, a plain
  controller. Modules used to pick one or the other, so the same action
  could log an actor in one module and none in the next.

      PhoenixKit.Activity.log("crm", "crm.company_updated",
        PhoenixKitWeb.Actor.opts(socket) ++ [resource_uuid: company.uuid])
  """

  alias PhoenixKit.Users.Auth.Scope

  @typedoc "Anything that knows who is acting."
  @type source :: Phoenix.LiveView.Socket.t() | Plug.Conn.t() | Scope.t() | map() | nil

  @doc """
  The acting user's uuid, or `nil` when nobody is signed in.

      PhoenixKitWeb.Actor.uuid(socket)
      PhoenixKitWeb.Actor.uuid(conn)
      PhoenixKitWeb.Actor.uuid(scope)
      PhoenixKitWeb.Actor.uuid(%{phoenix_kit_current_user: user})
  """
  @spec uuid(source()) :: String.t() | nil
  def uuid(%Scope{user: user}), do: user_uuid(user)
  def uuid(%{assigns: %{} = assigns}), do: uuid(assigns)

  def uuid(%{} = assigns) do
    case Map.get(assigns, :phoenix_kit_current_scope) do
      %Scope{} = scope -> uuid(scope)
      _ -> nil
    end || user_uuid(Map.get(assigns, :phoenix_kit_current_user))
  end

  def uuid(_), do: nil

  @doc """
  `[actor_uuid: uuid]` for a context call that logs, or `[]` when nobody
  is signed in. Adds `acting_user_uuid:` while acting for an organization, and
  `impersonated_by_uuid:` in a session someone signed in to as this user;
  `Activity.log/1,3` merges both into metadata alongside the caller's own values.
  """
  @spec opts(source()) :: keyword()
  def opts(source) do
    case uuid(source) do
      nil ->
        []

      uuid ->
        [actor_uuid: uuid]
        |> put_present(:acting_user_uuid, acting_user_uuid(source))
        |> put_present(:impersonated_by_uuid, impersonated_by_uuid(source))
    end
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: opts ++ [{key, value}]

  @doc "Who signed in as this session's person (\"sign in as this user\"), or `nil`."
  def impersonated_by_uuid(%Scope{impersonated_by_uuid: uuid}), do: uuid
  def impersonated_by_uuid(%{assigns: assigns}), do: impersonated_by_uuid(assigns)

  def impersonated_by_uuid(%{} = assigns) do
    case Map.get(assigns, :phoenix_kit_current_scope) do
      %Scope{} = scope -> impersonated_by_uuid(scope)
      _ -> nil
    end
  end

  def impersonated_by_uuid(_), do: nil

  @doc "The real person behind an organization session, from token-loaded provenance."
  def acting_user_uuid(%Scope{} = scope), do: Scope.acting_user_uuid(scope)
  def acting_user_uuid(%{assigns: assigns}), do: acting_user_uuid(assigns)

  def acting_user_uuid(%{} = assigns) do
    case Map.get(assigns, :phoenix_kit_current_scope) do
      %Scope{} = scope -> Scope.acting_user_uuid(scope)
      _ -> Map.get(Map.get(assigns, :phoenix_kit_current_user) || %{}, :acting_user_uuid)
    end
  end

  def acting_user_uuid(_), do: nil

  @doc """
  The name of the role the user is acting as (not PII), or `nil` — for
  audit metadata that wants to say which role acted. With the role
  switcher on, that is the active role, not the always-on roles that ride
  along with it; otherwise the first role held.
  """
  @spec role(source()) :: String.t() | nil
  def role(%Scope{} = scope) do
    case Scope.active_role(scope) do
      %{name: name} when is_binary(name) ->
        name

      _ ->
        case Scope.user_roles(scope) do
          [role | _] when is_binary(role) -> role
          _ -> nil
        end
    end
  end

  def role(%{assigns: %{} = assigns}), do: role(assigns)
  def role(%{} = assigns), do: role(Map.get(assigns, :phoenix_kit_current_scope))

  def role(_), do: nil

  defp user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil
end
