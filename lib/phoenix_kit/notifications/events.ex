defmodule PhoenixKit.Notifications.Events do
  @moduledoc """
  PubSub topic helpers for the notifications feature.

  Each recipient has their own topic so broadcasts don't fan out to unrelated
  LiveViews. Topic shape: `"phoenix_kit:notifications:<user_uuid>"`.

  Events sent to these topics:

    * `{:notification_created, %Notification{}}`
    * `{:notification_seen, %Notification{}}`
    * `{:notification_dismissed, %Notification{}}`
  """

  alias PhoenixKit.PubSub.Manager, as: PubSub

  @topic_prefix "phoenix_kit:notifications"

  @doc "Returns the per-user PubSub topic."
  def topic_for_user(user_uuid) when is_binary(user_uuid) do
    "#{@topic_prefix}:#{user_uuid}"
  end

  @doc "Subscribes the calling process to a user's notification topic."
  def subscribe(user_uuid) when is_binary(user_uuid) do
    PubSub.subscribe(topic_for_user(user_uuid))
  end

  @doc "Unsubscribes the calling process from a user's notification topic."
  def unsubscribe(user_uuid) when is_binary(user_uuid) do
    PubSub.unsubscribe(topic_for_user(user_uuid))
  end

  @doc "Broadcasts an event to a user's notification topic. Never raises."
  def broadcast(user_uuid, message) when is_binary(user_uuid) do
    PubSub.broadcast(topic_for_user(user_uuid), message)
  rescue
    _ -> :ok
  end
end
