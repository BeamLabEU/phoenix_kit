defmodule PhoenixKit.Notifications.Channels.Telegram do
  @moduledoc """
  Telegram notification channel — delivers a user's notifications to Telegram,
  through their own bot or through the site's.

  There's nothing to configure on the notifications page: the channel
  **auto-discovers** where to send.

  ## Personal bot

  The recipient's own Telegram integration connections, and the chat(s)
  captured on them (during Test on the integration form). A personal bot wins
  over the site's: someone who set one up wants it used. Each connection carries
  a `mode`:

    * `"single"` — auto-capture locks one private chat (the owner's), so a
      stranger who messages the bot right after them is not picked up.
    * `"multi"` — every chat that has started the bot → a broadcast.

  The mode governs auto-capture only: the owner can also link a chat by id
  (a group, a channel), so `chat_ids` is not capped by it. The channel sends
  to every id on the list and does not care which kind each one is.

  ## Site bot

  When the recipient has no personal bot linked, the site's bot delivers —
  if the admin chose one (`Telegram.SiteBot`) and the recipient linked their
  chat to it (`Telegram.Linking`). The chat id is read from `config`
  (`"site_chat_id"`), and the bot comes from the site setting, never from the
  user's config: a link made to a bot that is no longer the site's bot is not
  honoured, so changing the bot cannot send one person's messages through a
  stranger's.

  A failure of the site bot itself (revoked token, deleted connection, a 401 or
  404) is transient: it hits every linked user alike, so it must not switch
  anyone's channel off. Only errors about the chat (blocked, kicked,
  deactivated, chat not found) are permanent there.

  `configured?/2` is true once the recipient has somewhere to send. Bot tokens
  are resolved owner-scoped at send time — this module never handles them.

  The `config` arg (the `notification_channel:telegram` blob) carries routing/
  cadence and, for the site bot, the linked chat.
  """

  @behaviour PhoenixKit.Notifications.Channel

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram, as: Client
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Utils.Routes

  @impl true
  def key, do: "telegram"

  @impl true
  def label, do: gettext("Telegram")

  @impl true
  def icon, do: "hero-paper-airplane"

  @impl true
  def configured?(user_uuid, config), do: targets(user_uuid, config) != []

  # Linked from the settings table while the site has a bot to link to: the
  # Telegram card on the person's profile settings.
  @impl true
  def connect_path do
    if SiteBot.connection_uuid(),
      do: Routes.path("/profile/settings") <> "#telegram-notifications-card"
  rescue
    _ -> nil
  end

  @impl true
  def deliver(envelope, config) do
    deliver_to(targets(envelope.recipient_uuid, config), envelope)
  end

  @impl true
  def validate_config(config) when is_map(config), do: {:ok, config}

  # --- Discovery ------------------------------------------------------------

  # `{connection_uuid, chat_id, owner}` for every place to send. The user's own
  # bot first; the site bot only when they have none.
  defp targets(user_uuid, config) when is_binary(user_uuid) do
    case personal_targets(user_uuid) do
      [] -> site_targets(config)
      personal -> personal
    end
  end

  defp targets(_user_uuid, _config), do: []

  # Every chat captured on the user's Telegram connections. Single-mode
  # connections contribute one; multi many.
  defp personal_targets(user_uuid) do
    "telegram"
    |> Integrations.list_connections(owner: {:user, user_uuid})
    |> Enum.flat_map(fn %{uuid: uuid, data: data} ->
      Enum.map(chat_ids_of(data), &{uuid, &1, {:user, user_uuid}})
    end)
  rescue
    _ -> []
  end

  # The chat the user linked to the site bot — and only while that is still the
  # site's bot.
  defp site_targets(config) when is_map(config) do
    with chat_id when is_binary(chat_id) and chat_id != "" <- config["site_chat_id"],
         linked when is_binary(linked) <- config["site_connection_uuid"],
         ^linked <- SiteBot.connection_uuid() do
      [{linked, chat_id, :system}]
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp site_targets(_config), do: []

  defp chat_ids_of(data) do
    case data["chat_ids"] do
      list when is_list(list) -> list |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  end

  # --- Delivery -------------------------------------------------------------

  defp deliver_to([], _envelope), do: {:error, {:permanent, :not_configured}}

  # A single target (single mode / one bot, one chat): propagate the error so a
  # blocked chat soft-disables the channel.
  defp deliver_to([{uuid, chat_id, owner}], envelope) do
    case send(uuid, chat_id, owner, envelope) do
      {:ok, _} -> :ok
      {:error, reason} -> classify(reason, owner)
    end
  end

  # Several targets (multi mode / broadcast): best-effort — one blocked
  # subscriber shouldn't disable the whole channel. Retry only if something was
  # transiently unreachable (may re-send to already-delivered chats — Telegram
  # has no idempotency key, so delivery is at-least-once).
  defp deliver_to(targets, envelope) do
    results =
      Enum.map(targets, fn {uuid, chat_id, owner} -> send(uuid, chat_id, owner, envelope) end)

    cond do
      Enum.all?(results, &match?({:ok, _}, &1)) ->
        :ok

      Enum.any?(results, &transient?/1) ->
        {:error, {:transient, :partial}}

      true ->
        # Every send failed permanently (bot blocked/kicked everywhere, bad
        # token, …). We still report :ok so one dead subscriber can't disable a
        # working broadcast — but a wholly-failed send must not look like a
        # success in the logs, or a mis-set token is invisible forever.
        Logger.warning(
          "[Notifications.Telegram] broadcast to #{length(targets)} chat(s) failed permanently: " <>
            inspect(Enum.reject(results, &match?({:ok, _}, &1)))
        )

        :ok
    end
  end

  defp send(uuid, chat_id, owner, envelope) do
    Client.send_message(uuid, chat_id, body(envelope), owner: owner)
  end

  defp transient?({:error, reason}),
    do:
      match?({:error, {:transient, _}}, classify(reason, :personal)) or
        match?({:error, {:transient, _}, _}, classify(reason, :personal))

  defp transient?(_), do: false

  # Plain text (no parse_mode) so notification content can't break Telegram
  # markup. The deep-link goes on its own line.
  defp body(%{text: text} = envelope) do
    [text, present(envelope[:quote]), present(envelope[:url]), reason_line(envelope)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # The setting line that sent it, and where to change it.
  defp reason_line(%{reason: reason} = envelope) when is_binary(reason) and reason != "" do
    case present(envelope[:reason_url]) do
      nil -> reason
      url -> reason <> "\n" <> url
    end
  end

  defp reason_line(_envelope), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # Map the send client's error into the permanent/transient taxonomy.
  #
  # A permanent error soft-disables the recipient's channel. For the site bot
  # (`owner == :system`) that is only right when the failure is about THAT
  # chat — the user blocked the bot, the chat is gone, the account was
  # deactivated. A failure of the bot itself (revoked token, deleted or
  # unconfigured connection, anything Telegram says that is not about the
  # chat) hits every linked user alike: it is transient there, so nobody is
  # switched off for something an admin fixes in one place.
  defp classify(:unreachable, _owner), do: {:error, {:transient, :unreachable}}

  defp classify(reason, :system) when reason in [:not_configured, :deleted],
    do: {:error, {:transient, reason}}

  defp classify(reason, _owner) when reason in [:not_configured, :deleted],
    do: {:error, {:permanent, reason}}

  defp classify(desc, owner) when is_binary(desc) do
    down = String.downcase(desc)

    cond do
      String.contains?(down, "too many requests") ->
        {:error, {:transient, desc}, retry_after_ms(desc)}

      String.contains?(down, [
        "blocked",
        "deactivated",
        "chat not found",
        "bot can't initiate",
        "bot can’t initiate",
        "kicked",
        "forbidden",
        "have no rights",
        "not enough rights"
      ]) ->
        {:error, {:permanent, desc}}

      String.contains?(down, [
        "internal server error",
        "bad gateway",
        "gateway",
        # any 5xx (the client formats a bodyless server error as "Telegram error 5xx")
        "telegram error 5",
        "502",
        "503",
        "504"
      ]) ->
        {:error, {:transient, desc}}

      owner == :system ->
        {:error, {:transient, desc}}

      true ->
        {:error, {:permanent, desc}}
    end
  end

  defp classify(other, :system), do: {:error, {:transient, other}}
  defp classify(other, _owner), do: {:error, {:permanent, other}}

  defp retry_after_ms(desc) do
    case Regex.run(~r/retry after (\d+)/i, desc) do
      [_, seconds] -> String.to_integer(seconds) * 1000
      _ -> 1000
    end
  end
end
