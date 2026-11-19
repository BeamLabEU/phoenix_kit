defmodule PhoenixKit.Notifications.DeliveryWorker do
  @moduledoc """
  Delivers one notification to one external channel (Telegram, …), off the hot
  path. Enqueued transactionally from the notification creation choke point —
  one job per `{source, channel}` — so a slow bot API call never blocks the
  business action that logged the activity.

  ## Job args

      %{"channel" => "telegram",
        "recipient_uuid" => "<uuid>",
        "type_key" => "posts.likes",
        # exactly ONE source:
        "activity_uuid" => "<uuid>"    # activity-driven (renders from the Entry)
        # or
        "notification_uuid" => "<uuid>"}  # standalone (renders from the row)

  ## Retry / failure policy

  The channel returns a permanent/transient verdict:

    * `:ok` — done.
    * `{:error, {:transient, _}}` / `{:error, {:transient, _}, retry_ms}` — Oban
      retries (with a snooze on `retry_ms`), up to `max_attempts`.
    * `{:error, {:permanent, reason}}` — **soft-disable** the channel in the
      user's config (`enabled: false`, `status`, `disabled_reason`) and stop.
      A bot the user blocked shouldn't retry-storm.

  A channel/user/source that's gone by run time is discarded (`:ok`), not
  retried. The channel resolves its own credentials owner-scoped to the
  recipient, so this worker never handles a token.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    # One job per source+recipient+channel — dedupes a double-logged activity
    # or a re-run of the creation path without collapsing a fan-out (one
    # source routed to N recipients) onto its first recipient. (Retries of
    # THIS job reuse the same row.)
    unique: [keys: [:source_uuid, :recipient_uuid, :channel], period: 300]

  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Channels
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Notifications.Render
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @doc """
  Builds the Oban job changeset for a delivery, stamping the `source_uuid` used
  by the unique key (whichever of activity/notification uuid is present). String
  keys throughout (JSONB args). Callers pass this to `Oban.insert/*`.
  """
  @spec build(map()) :: Ecto.Changeset.t()
  def build(args) when is_map(args) do
    args = Map.new(args, fn {k, v} -> {to_string(k), v} end)
    source_uuid = args["activity_uuid"] || args["notification_uuid"]

    args
    |> Map.put("source_uuid", source_uuid)
    |> new()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel" => channel_key, "recipient_uuid" => recipient} = args}) do
    type_key = args["type_key"]

    with {:ok, channel} <- fetch_channel(channel_key),
         {:ok, user} <- fetch_user(recipient),
         config = ChannelConfig.for_channel(user, channel_key),
         true <- deliverable?(channel, user, config, type_key),
         {:ok, notification} <- load_source(args) do
      envelope = build_envelope(notification, user, recipient, type_key)
      handle(channel.deliver(envelope, config), user, channel_key)
    else
      # Channel/user/source gone, or the user turned the channel/type off
      # between enqueue and run — discard, don't retry.
      _ -> :ok
    end
  end

  def perform(_job), do: :ok

  # --- Delivery result handling ---------------------------------------------

  defp handle(:ok, _user, _channel_key), do: :ok

  defp handle({:error, {:transient, reason}}, _user, _channel_key),
    do: {:error, reason}

  defp handle({:error, {:transient, _reason}, retry_ms}, _user, _channel_key)
       when is_integer(retry_ms),
       do: {:snooze, max(1, div(retry_ms, 1000))}

  defp handle({:error, {:permanent, reason}}, user, channel_key) do
    soft_disable(user, channel_key, reason)
    # Discard — a permanent failure must not consume retries.
    :ok
  end

  defp handle(other, _user, _channel_key) do
    Logger.warning("[DeliveryWorker] unexpected deliver/2 result: #{inspect(other)}")
    :ok
  end

  # Turn the channel off + record why, so the user sees it in settings and we
  # stop hammering a dead destination. `reason` is a channel-supplied
  # description/atom (never a raw error carrying a token).
  defp soft_disable(user, channel_key, reason) do
    ChannelConfig.update(user, channel_key, fn config ->
      config
      |> Map.put("enabled", false)
      |> Map.put("status", "disabled")
      |> Map.put("disabled_reason", describe(reason))
    end)
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # --- Loading + rendering ---------------------------------------------------

  defp fetch_channel(key) do
    case Channels.get(key) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  defp fetch_user(uuid) do
    case Auth.get_user(uuid) do
      %{} = user -> {:ok, user}
      _ -> :error
    end
  end

  # Re-check the user's CURRENT config: honor a channel/type turned off after
  # the job was enqueued (least-surprising — a disabled channel stops sending).
  defp deliverable?(channel, user, config, type_key) do
    ChannelConfig.enabled?(config) and
      (is_nil(type_key) or ChannelConfig.type_enabled?(config, type_key)) and
      channel.configured?(user.uuid, config)
  end

  # Standalone → load the persisted row (recipient-scoped). Activity-driven →
  # load the Entry and wrap it in a transient notification so `Render` takes the
  # activity path (the inbox row may not exist when in-app was muted).
  defp load_source(%{"notification_uuid" => uuid, "recipient_uuid" => recipient})
       when is_binary(uuid) do
    case Notifications.get_notification(recipient, uuid) do
      %Notification{} = n -> {:ok, n}
      _ -> :error
    end
  end

  defp load_source(%{"activity_uuid" => uuid, "recipient_uuid" => recipient})
       when is_binary(uuid) do
    case Activity.get_entry(uuid) do
      nil ->
        :error

      entry ->
        {:ok,
         %Notification{
           activity: entry,
           recipient_uuid: recipient,
           metadata: entry.metadata || %{}
         }}
    end
  end

  defp load_source(_), do: :error

  defp build_envelope(notification, user, recipient, type_key) do
    locale = RecipientLocale.base(user)
    rendered = Render.render(notification, locale)
    why = Render.reason(notification, user, locale)
    quoted = Render.quote(notification)

    %{
      recipient_uuid: recipient,
      type_key: type_key,
      notification_uuid: Map.get(notification, :uuid),
      locale: locale,
      icon: rendered.icon,
      title: nil,
      text: rendered.text,
      url: absolutize(rendered.link),
      reason: why && why.text,
      reason_url: why && absolutize(why.link),
      quote: Render.quote_text(quoted, quote_author(quoted))
    }
  end

  # The quote's writer as the reader sees them: their display name, else the
  # name the module stored.
  defp quote_author(nil), do: nil

  defp quote_author(%{author_uuid: uuid, author_name: name}) do
    case is_binary(uuid) && Auth.get_user(uuid) do
      %{} = writer -> User.display_name(writer)
      _ -> name
    end
  end

  # A notification `link` is already url-/locale-prefixed (or nil). Prepend the
  # bare base; never pass it back through `Routes.url/1` (double-prefix).
  defp absolutize(nil), do: nil
  defp absolutize(link) when is_binary(link), do: Routes.base_url() <> link
end
