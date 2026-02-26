defmodule PhoenixKit.Users.ScopeNotifier do
  @moduledoc """
  Handles PubSub notifications for user scope refreshes.

  When a user's roles change, we broadcast a message on a user-specific topic
  so any connected LiveViews can refresh their cached authentication scope
  without requiring a full reconnect.
  """

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth.User

  @topic_prefix "phoenix_kit:user_scope:"

  @doc """
  Broadcasts a scope refresh notification for the given user.
  """
  @spec broadcast_roles_updated(User.t() | binary() | nil) :: :ok
  def broadcast_roles_updated(nil), do: :ok

  def broadcast_roles_updated(%User{uuid: user_uuid}) when is_binary(user_uuid) do
    broadcast_roles_updated(user_uuid)
  end

  def broadcast_roles_updated(user_uuid) when is_binary(user_uuid) do
    Manager.broadcast(topic(user_uuid), {:phoenix_kit_scope_roles_updated, user_uuid})
  end

  def broadcast_roles_updated(_), do: :ok

  @doc """
  Subscribes the current process to scope refresh notifications for the user.
  """
  @spec subscribe(User.t() | binary()) :: :ok | {:error, term()}
  def subscribe(%User{uuid: user_uuid}) when is_binary(user_uuid), do: subscribe(user_uuid)

  def subscribe(user_uuid) when is_binary(user_uuid) do
    Manager.subscribe(topic(user_uuid))
  end

  def subscribe(_), do: :ok

  @doc """
  Unsubscribes the current process from scope refresh notifications.
  """
  @spec unsubscribe(User.t() | binary() | nil) :: :ok
  def unsubscribe(nil), do: :ok

  def unsubscribe(%User{uuid: user_uuid}) when is_binary(user_uuid) do
    unsubscribe(user_uuid)
  end

  def unsubscribe(user_uuid) when is_binary(user_uuid) do
    Manager.unsubscribe(topic(user_uuid))
  end

  def unsubscribe(_), do: :ok

  defp topic(user_uuid), do: "#{@topic_prefix}#{user_uuid}"
end
