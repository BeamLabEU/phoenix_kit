defmodule PhoenixKit.Users.ScopeNotifier do
  @moduledoc """
  Handles PubSub notifications for user scope refreshes.

  When a user's roles change, we broadcast a message on a user-specific topic
  so any connected LiveViews can refresh their cached authentication scope
  without requiring a full reconnect.
  """

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  @topic_prefix "phoenix_kit:user_scope:"

  @doc """
  Broadcasts a scope refresh notification for the given user.
  """
  @spec broadcast_roles_updated(User.t() | integer() | binary() | nil) :: :ok
  def broadcast_roles_updated(nil), do: :ok

  def broadcast_roles_updated(%User{id: user_id}) do
    broadcast_roles_updated(user_id)
  end

  def broadcast_roles_updated(user_id) when is_integer(user_id) do
    Manager.broadcast(topic(user_id), {:phoenix_kit_scope_roles_updated, user_id})
  end

  def broadcast_roles_updated(user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> broadcast_roles_updated(int_id)
      _ -> resolve_and_broadcast(user_id)
    end
  end

  def broadcast_roles_updated(_), do: :ok

  @doc """
  Subscribes the current process to scope refresh notifications for the user.
  """
  @spec subscribe(User.t() | integer() | binary()) :: :ok | {:error, term()}
  def subscribe(%User{id: user_id}), do: subscribe(user_id)

  def subscribe(user_id) when is_integer(user_id) do
    Manager.subscribe(topic(user_id))
  end

  def subscribe(user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> subscribe(int_id)
      _ -> resolve_and_subscribe(user_id)
    end
  end

  def subscribe(_), do: :ok

  @doc """
  Unsubscribes the current process from scope refresh notifications.
  """
  @spec unsubscribe(User.t() | integer() | binary() | nil) :: :ok
  def unsubscribe(nil), do: :ok

  def unsubscribe(%User{id: user_id}) do
    unsubscribe(user_id)
  end

  def unsubscribe(user_id) when is_integer(user_id) do
    Manager.unsubscribe(topic(user_id))
  end

  def unsubscribe(user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> unsubscribe(int_id)
      _ -> resolve_and_unsubscribe(user_id)
    end
  end

  def unsubscribe(_), do: :ok

  defp topic(user_id), do: "#{@topic_prefix}#{user_id}"

  # Resolve UUID string to integer user ID, then delegate
  defp resolve_and_broadcast(uuid) do
    case Auth.get_user!(uuid) do
      %User{id: int_id} -> broadcast_roles_updated(int_id)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp resolve_and_subscribe(uuid) do
    case Auth.get_user!(uuid) do
      %User{id: int_id} -> subscribe(int_id)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp resolve_and_unsubscribe(uuid) do
    case Auth.get_user!(uuid) do
      %User{id: int_id} -> unsubscribe(int_id)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end
end
