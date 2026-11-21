defmodule PhoenixKit.Integration.Notifications.TelegramChannelSiteBotTest do
  @moduledoc """
  The Telegram notification channel delivering through the website bot: for a
  user who linked their chat to it, and only while the admin has chosen it.
  A personal bot, where there is one, still wins.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Channels.Telegram, as: Channel
  alias PhoenixKit.Notifications.DeliveryWorker
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth

  @stub __MODULE__.Telegram

  setup do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)

    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram, conn.request_path, Jason.decode!(raw)})
      Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
    end)

    {:ok, %{uuid: site}} = Integrations.add_connection("telegram", "site bot")
    {:ok, _} = Integrations.save_setup(site, %{"bot_token" => "111:SITE"})

    user = user()
    %{site: site, user: user}
  end

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        email: "chan_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp envelope(user), do: %{recipient_uuid: user.uuid, text: "Order paid", url: nil}

  defp link(user, connection_uuid, chat_id) do
    {:ok, _} = Linking.link_chat(user, connection_uuid, chat_id)
    ChannelConfig.for_channel(Auth.get_user!(user.uuid), "telegram")
  end

  describe "with the site bot chosen" do
    test "a user who linked their chat is reachable and gets the message there", %{
      site: site,
      user: user
    } do
      :ok = SiteBot.select(site)
      config = link(user, site, 4242)

      assert Channel.configured?(user.uuid, config)
      assert :ok = Channel.deliver(envelope(user), config)

      assert_received {:telegram, path, %{"chat_id" => "4242", "text" => "Order paid"}}
      assert path =~ "/bot111:SITE/sendMessage"
    end

    test "a user who never linked is not reachable", %{site: site, user: user} do
      :ok = SiteBot.select(site)

      refute Channel.configured?(user.uuid, %{})
      assert {:error, {:permanent, :not_configured}} = Channel.deliver(envelope(user), %{})
    end
  end

  describe "with the site bot off" do
    test "a linked chat is not used", %{site: site, user: user} do
      config = link(user, site, 4242)

      refute Channel.configured?(user.uuid, config)
      assert {:error, {:permanent, :not_configured}} = Channel.deliver(envelope(user), config)
      refute_received {:telegram, _, _}
    end

    test "turning it off again stops delivery", %{site: site, user: user} do
      :ok = SiteBot.select(site)
      config = link(user, site, 4242)
      :ok = SiteBot.clear()

      refute Channel.configured?(user.uuid, config)
    end
  end

  describe "when the site's bot changes" do
    test "a chat linked to the previous bot is not sent through the new one", %{
      site: site,
      user: user
    } do
      :ok = SiteBot.select(site)
      config = link(user, site, 4242)

      {:ok, %{uuid: other}} = Integrations.add_connection("telegram", "new bot")
      {:ok, _} = Integrations.save_setup(other, %{"bot_token" => "222:NEW"})
      :ok = SiteBot.select(other)

      refute Channel.configured?(user.uuid, config)
      refute_received {:telegram, _, _}
    end

    test "deleting the connection turns the site bot off", %{site: site, user: user} do
      :ok = SiteBot.select(site)
      config = link(user, site, 4242)
      :ok = Integrations.remove_connection(site)

      assert SiteBot.connection_uuid() == nil
      refute Channel.configured?(user.uuid, config)
    end
  end

  # Telegram answers every call with `status` and an API error `description`.
  defp telegram_says(status, description) do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"ok" => false, "description" => description})
    end)
  end

  describe "when sending through the site bot fails" do
    setup %{site: site, user: user} do
      :ok = SiteBot.select(site)
      %{config: link(user, site, 4242)}
    end

    # The bot is at fault, not the chat: every linked user would fail the same
    # way, so none may be switched off for it.
    for {status, description} <- [
          {401, "Unauthorized"},
          {404, "Not Found"},
          {409, "Conflict: terminated by other getUpdates request"}
        ] do
      test "#{description} (bot level) is transient", %{user: user, config: config} do
        telegram_says(unquote(status), unquote(description))

        assert {:error, {:transient, _}} = Channel.deliver(envelope(user), config)
      end
    end

    test "a bot whose token is gone is transient", %{site: site, user: user, config: config} do
      {:ok, _} = Integrations.save_setup(site, %{"bot_token" => ""})

      assert {:error, {:transient, _}} = Channel.deliver(envelope(user), config)
    end

    for description <- [
          "Forbidden: bot was blocked by the user",
          "Bad Request: chat not found",
          "Forbidden: user is deactivated",
          "Forbidden: bot was kicked from the group chat"
        ] do
      test "#{description} (chat level) is permanent", %{user: user, config: config} do
        telegram_says(403, unquote(description))

        assert {:error, {:permanent, _}} = Channel.deliver(envelope(user), config)
      end
    end

    test "a personal bot's revoked token still disables the channel", %{user: user} do
      {:ok, %{uuid: mine}} =
        Integrations.add_connection("telegram", "my bot", user.uuid, owner: {:user, user.uuid})

      {:ok, _} =
        Integrations.save_setup(
          mine,
          %{"bot_token" => "333:MINE", "chat_ids" => ["777"]},
          user.uuid,
          owner: {:user, user.uuid}
        )

      telegram_says(401, "Unauthorized")

      assert {:error, {:permanent, _}} = Channel.deliver(envelope(user), %{})
    end
  end

  describe "the delivery worker with the site bot" do
    setup %{site: site, user: user} do
      :ok = SiteBot.select(site)
      link(user, site, 4242)

      {:ok, %Notifications.Notification{} = n} =
        Notifications.create(%{recipient_uuid: user.uuid, text: "Hi"})

      %{
        job: %Oban.Job{
          args: %{
            "channel" => "telegram",
            "recipient_uuid" => user.uuid,
            "notification_uuid" => n.uuid
          }
        }
      }
    end

    defp channel_state(user), do: ChannelConfig.for_channel(Auth.get_user!(user.uuid), "telegram")

    test "wording follows the site language and then the recipient's exact dialect", %{
      user: user,
      job: job
    } do
      for {lang, text} <- [{"en", "Site wording"}, {"en-GB", "British wording"}] do
        {:ok, _} =
          Settings.update_json_setting("notification_message:*:telegram:" <> lang, %{
            "text" => text
          })
      end

      assert :ok = DeliveryWorker.perform(job)
      assert_received {:telegram, _, %{"text" => "Site wording"}}

      {:ok, _} = Auth.update_user_locale_preference(user, "en-GB")
      assert :ok = DeliveryWorker.perform(job)
      assert_received {:telegram, _, %{"text" => "British wording"}}
    end

    test "a bot-level failure retries and leaves every user connected", %{user: user, job: job} do
      telegram_says(401, "Unauthorized")

      assert {:error, _} = DeliveryWorker.perform(job)

      config = channel_state(user)
      assert ChannelConfig.enabled?(config)
      refute config["status"] == "disabled"
      assert config["site_chat_id"] == "4242"
    end

    test "a blocked chat switches only that user off", %{user: user, job: job} do
      telegram_says(403, "Forbidden: bot was blocked by the user")

      assert :ok = DeliveryWorker.perform(job)

      config = channel_state(user)
      refute ChannelConfig.enabled?(config)
      assert config["status"] == "disabled"
    end
  end

  describe "a personal bot" do
    test "wins over the site bot", %{site: site, user: user} do
      :ok = SiteBot.select(site)
      config = link(user, site, 4242)

      {:ok, %{uuid: mine}} =
        Integrations.add_connection("telegram", "my bot", user.uuid, owner: {:user, user.uuid})

      {:ok, _} =
        Integrations.save_setup(
          mine,
          %{"bot_token" => "333:MINE", "chat_ids" => ["777"]},
          user.uuid,
          owner: {:user, user.uuid}
        )

      assert :ok = Channel.deliver(envelope(user), config)

      assert_received {:telegram, path, %{"chat_id" => "777"}}
      assert path =~ "/bot333:MINE/"
      refute_received {:telegram, _, %{"chat_id" => "4242"}}
    end
  end

  describe "select/2" do
    test "refuses a connection that is not a website Telegram one", %{user: user} do
      {:ok, %{uuid: mine}} =
        Integrations.add_connection("telegram", "my bot", user.uuid, owner: {:user, user.uuid})

      assert {:error, :not_a_site_telegram_connection} = SiteBot.select(mine)
      assert {:error, :not_a_site_telegram_connection} = SiteBot.select(Ecto.UUID.generate())
      assert SiteBot.connection_uuid() == nil
    end

    test "choosing another connection replaces the first", %{site: site} do
      {:ok, %{uuid: other}} = Integrations.add_connection("telegram", "other")

      :ok = SiteBot.select(site)
      :ok = SiteBot.select(other)

      assert SiteBot.connection_uuid() == other
    end
  end

  describe "bot_username/1 and webhook_set?/1" do
    test "reads the username Telegram gave at the last test", %{site: site} do
      Integrations.record_validation(site, {:ok, %{fact: "Connected as @shop_bot"}},
        owner: :system
      )

      assert SiteBot.bot_username(site) == "shop_bot"
    end

    test "asks Telegram when no test ever ran", %{site: site} do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"username" => "asked_bot"}})
      end)

      assert SiteBot.bot_username(site) == "asked_bot"
    end

    test "tells whether a webhook is set", %{site: site} do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"url" => "https://x.example/hook"}})
      end)

      assert SiteBot.webhook_set?(site)

      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"ok" => true, "result" => %{"url" => ""}})
      end)

      refute SiteBot.webhook_set?(site)
    end
  end
end
