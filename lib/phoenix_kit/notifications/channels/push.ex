defmodule PhoenixKit.Notifications.Channels.Push do
  @moduledoc """
  Browser push notification channel (`PhoenixKit.Notifications.Push`).

  Available once the account turned push on in a browser (the "Browser"
  card of the notification settings) while the site offers it
  (`push_enabled`). `deliver/2` does not send: it queues the notice for the
  account's next grouped push. A notification the reader can no longer see
  (`visible: false` in the envelope, the type's `visible` check) is not
  pushed at all.
  """

  @behaviour PhoenixKit.Notifications.Channel

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Utils.Routes

  @impl true
  def key, do: "push"

  @impl true
  def label, do: gettext("Browser")

  @impl true
  def icon, do: "hero-computer-desktop"

  @impl true
  def configured?(user_uuid, _config), do: Push.enabled?() and Push.any_device?(user_uuid)

  @impl true
  def deliver(%{visible: false}, _config), do: :ok

  def deliver(envelope, _config) do
    case Push.queue(envelope) do
      :ok -> :ok
      {:error, reason} -> {:error, {:transient, reason}}
    end
  end

  @impl true
  def validate_config(config) when is_map(config), do: {:ok, config}

  @impl true
  def connect_path do
    if Push.enabled?(),
      do: Routes.path("/profile/settings/notifications") <> "#push-notifications-card"
  rescue
    _ -> nil
  end
end
