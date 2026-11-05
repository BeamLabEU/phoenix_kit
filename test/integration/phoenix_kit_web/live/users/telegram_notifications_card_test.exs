defmodule PhoenixKitWeb.Live.Users.TelegramNotificationsCardTest do
  @moduledoc """
  The Telegram card on `/profile/settings/notifications`: an ordinary user
  (no admin area, no `integrations` permission) links their chat to the
  website bot with a one-time link, picks what goes there, and disconnects.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Test.TelegramCardHostLive, as: Host

  @stub __MODULE__.Telegram
  @path Routes.path("/profile/settings/notifications")

  setup %{conn: conn} do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
    Application.put_env(:phoenix_kit, :telegram_card_min_interval_ms, 0)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :telegram_req_options)
      Application.delete_env(:phoenix_kit, :telegram_card_min_interval_ms)
    end)

    Req.Test.set_req_test_to_shared(%{})

    test_pid = self()
    {:ok, pending} = Agent.start_link(fn -> [] end)
    {:ok, flags} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(@stub, fn conn ->
      method = conn.request_path |> String.split("/") |> List.last()
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      send(test_pid, {:telegram, method, body})

      if method == "getMe" and Agent.get(flags, & &1[:get_me_fails]) == true do
        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{"ok" => false, "description" => "Bad Gateway"})
      else
        result =
          case method do
            "getUpdates" -> Agent.get(pending, & &1)
            "getMe" -> %{"username" => "shop_bot"}
            _ -> %{"message_id" => 1}
          end

        Req.Test.json(conn, %{"ok" => true, "result" => result})
      end
    end)

    {:ok, user} =
      Auth.register_user(%{
        email: "card_#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)

    {:ok, %{uuid: site}} = Integrations.add_connection("telegram", "site bot")
    {:ok, _} = Integrations.save_setup(site, %{"bot_token" => "111:SITE"})

    %{conn: log_in_user(conn, user), user: user, site: site, pending: pending, flags: flags}
  end

  defp config(user), do: ChannelConfig.for_channel(Auth.get_user!(user.uuid), "telegram")

  defp token_from(html) do
    [_, token] = Regex.run(~r{https://t\.me/shop_bot\?start=([A-Za-z0-9_-]+)}, html)
    token
  end

  describe "when the admin has not chosen a website bot" do
    test "the card is not shown", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)

      refute html =~ "Connect Telegram"
    end
  end

  describe "connecting" do
    setup %{site: site},
      do:
        (
          :ok = SiteBot.select(site)
          :ok
        )

    test "offers Connect to a user who has not linked", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)

      assert html =~ "Connect Telegram"
    end

    test "Connect shows a one-time link to the site's bot", %{conn: conn, user: user, site: site} do
      {:ok, view, _html} = live(conn, @path)

      html = view |> element("button", "Connect Telegram") |> render_click()

      token = token_from(html)
      assert html =~ "expires in 15 minutes"
      assert {:ok, %{user_uuid: uuid}} = Linking.consume_token(token, site)
      assert uuid == user.uuid
    end

    test "pressing Start links the chat, and the card says so", %{
      conn: conn,
      user: user,
      pending: pending
    } do
      {:ok, view, _html} = live(conn, @path)
      html = view |> element("button", "Connect Telegram") |> render_click()
      token = token_from(html)

      Agent.update(pending, fn _ ->
        [
          %{
            "update_id" => 1,
            "message" => %{
              "chat" => %{"id" => 9_001, "type" => "private"},
              "text" => "/start " <> token
            }
          }
        ]
      end)

      view |> element("button", "I've sent it") |> render_click()
      html = render_async(view, 3_000)

      assert html =~ "Connected"
      assert config(user)["site_chat_id"] == "9001"
    end

    test "a link nobody used leaves the user unlinked", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      view |> element("button", "Connect Telegram") |> render_click()

      view |> element("button", "I've sent it") |> render_click()
      render_async(view, 3_000)

      assert config(user)["site_chat_id"] == nil
    end

    test "reopening the page while a link is pending says it is waiting", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, _} = Linking.create_token(user, site)

      {:ok, _view, html} = live(conn, @path)

      assert html =~ "Waiting for you to press Start"
      assert html =~ "Get a new link"
    end

    test "the page finishes a link whose Start came after it was closed", %{
      conn: conn,
      user: user,
      site: site,
      pending: pending
    } do
      {:ok, token} = Linking.create_token(user, site)

      Agent.update(pending, fn _ ->
        [
          %{
            "update_id" => 5,
            "message" => %{
              "chat" => %{"id" => 77, "type" => "private"},
              "text" => "/start " <> token
            }
          }
        ]
      end)

      {:ok, view, _html} = live(conn, @path)
      html = render_async(view, 3_000)

      assert html =~ "Connected"
      assert config(user)["site_chat_id"] == "77"
    end
  end

  describe "when linked" do
    setup %{site: site, user: user} do
      :ok = SiteBot.select(site)
      {:ok, _} = Linking.link_chat(user, site, 9_001)
      :ok
    end

    test "shows Connected and a Disconnect button", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)

      assert html =~ "Connected"
      assert html =~ "Disconnect"
      refute html =~ "Connect Telegram"
    end

    test "Disconnect unlinks but keeps the user's choices", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)

      html = view |> element("button", "Disconnect") |> render_click()

      assert html =~ "Telegram disconnected"
      assert config(user)["site_chat_id"] == nil
      assert is_map(config(user)["types"])
    end

    test "saving the types stores exactly what was ticked", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      [first | _] = types_list = Types.list()

      # The form posts what it shows, so a type the first link switched on stays
      # on unless the test unticks it.
      ticked =
        types_list
        |> Enum.flat_map(fn type -> [type.key | Enum.map(type.sub_types, & &1.key)] end)
        |> Map.new(&{&1, if(&1 == first.key, do: "true", else: "false")})

      view
      |> form("#telegram-notifications-card-types", %{"telegram_types" => ticked})
      |> render_submit()

      types = config(user)["types"]
      assert types[first.key] == true

      for {key, value} <- types, key != first.key, do: assert(value == false)
    end

    test "a link to a bot that is no longer the site's is not shown as connected", %{
      conn: conn,
      site: site
    } do
      {:ok, %{uuid: other}} = Integrations.add_connection("telegram", "new bot")
      {:ok, _} = Integrations.save_setup(other, %{"bot_token" => "222:NEW"})
      :ok = SiteBot.select(other)
      assert site != other

      {:ok, _view, html} = live(conn, @path)

      assert html =~ "Connect Telegram"
      refute html =~ "Disconnect"
    end
  end

  defp start_update(update_id, chat_id, token) do
    %{
      "update_id" => update_id,
      "message" => %{
        "chat" => %{"id" => chat_id, "type" => "private"},
        "text" => "/start " <> token
      }
    }
  end

  defp register(prefix) do
    {:ok, user} =
      Auth.register_user(%{
        email: "#{prefix}_#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    user
  end

  # What DeliveryWorker.soft_disable/3 writes after a blocked chat.
  defp soft_disable(user) do
    {:ok, _} =
      ChannelConfig.update(Auth.get_user!(user.uuid), "telegram", fn config ->
        config
        |> Map.put("enabled", false)
        |> Map.put("status", "disabled")
        |> Map.put("disabled_reason", "Forbidden: bot was blocked by the user")
      end)
  end

  defp age_tokens(user) do
    old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)

    RepoHelper.repo().update_all(
      from(t in UserToken, where: t.context == "telegram_link" and t.user_uuid == ^user.uuid),
      set: [inserted_at: old]
    )
  end

  # The card's `poll_timer` assign, found in the LiveView process's state.
  defp poll_timer(view) do
    find_key(:sys.get_state(view.pid), :poll_timer)
  end

  defp find_key(%{poll_timer: ref}, :poll_timer), do: ref

  defp find_key(%{} = map, key),
    do: map |> Map.to_list() |> find_key(key)

  defp find_key(tuple, key) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> find_key(key)

  defp find_key(list, key) when is_list(list) do
    Enum.find_value(list, fn item -> find_key(item, key) end)
  end

  defp find_key(_other, _key), do: nil

  defp count_received(message) do
    receive do
      ^message -> 1 + count_received(message)
    after
      0 -> 0
    end
  end

  describe "a link the delivery switched off" do
    setup %{site: site, user: user} do
      :ok = SiteBot.select(site)
      {:ok, _} = Linking.link_chat(user, site, 9_001)
      soft_disable(user)
      :ok
    end

    test "shows as switched off, with Reconnect", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)

      assert html =~ "Switched off"
      assert html =~ "Reconnect"
      refute html =~ "badge-success"
    end

    test "Reconnect, then Start, turns delivery back on", %{
      conn: conn,
      user: user,
      pending: pending
    } do
      {:ok, view, _html} = live(conn, @path)
      html = view |> element("button", "Reconnect") |> render_click()
      token = token_from(html)

      Agent.update(pending, fn _ -> [start_update(1, 9_002, token)] end)
      view |> element("button", "I've sent it") |> render_click()
      html = render_async(view, 3_000)

      assert html =~ "Telegram connected"
      refute html =~ "Switched off"
      assert ChannelConfig.enabled?(config(user))
      assert config(user)["site_chat_id"] == "9002"
      refute Map.has_key?(config(user), "status")
    end
  end

  describe "a link that runs out" do
    setup %{site: site},
      do:
        (
          :ok = SiteBot.select(site)
          :ok
        )

    test "says it expired instead of waiting for nothing", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      view |> element("button", "Connect Telegram") |> render_click()

      age_tokens(user)
      view |> element("button", "I've sent it") |> render_click()
      html = render_async(view, 3_000)

      assert html =~ "The link expired"
      assert html =~ "Connect Telegram"
      refute html =~ "Open Telegram"
    end
  end

  describe "asking Telegram" do
    setup %{site: site},
      do:
        (
          :ok = SiteBot.select(site)
          :ok
        )

    test "a card with no link pending never reads the bot's updates", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view |> with_target("#telegram-notifications-card") |> render_click("check", %{})
      render_async(view, 1_000)

      refute_received {:telegram, "getUpdates", _}
    end

    test "Connect clicked again at once reaches Telegram once", %{conn: conn} do
      Application.put_env(:phoenix_kit, :telegram_card_min_interval_ms, 60_000)
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "Connect Telegram") |> render_click()
      view |> with_target("#telegram-notifications-card") |> render_click("connect", %{})

      assert count_received({:telegram, "getMe", %{}}) == 1
    end

    test "pressing Connect again replaces the poll timer instead of adding one", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "Connect Telegram") |> render_click()
      first = poll_timer(view)
      assert is_reference(first)
      assert is_integer(Process.read_timer(first))

      view |> with_target("#telegram-notifications-card") |> render_click("connect", %{})
      second = poll_timer(view)

      assert is_reference(second) and second != first
      assert Process.read_timer(first) == false
      assert is_integer(Process.read_timer(second))
    end

    test "a bot that does not answer leaves the link the user already has", %{
      conn: conn,
      user: user,
      site: site,
      flags: flags
    } do
      {:ok, token} = Linking.create_token(user, site)
      Agent.update(flags, &Map.put(&1, :get_me_fails, true))

      {:ok, view, _html} = live(conn, @path)
      html = view |> element("button", "Get a new link") |> render_click()

      assert html =~ "Telegram is not available right now"
      assert {:ok, _} = Linking.consume_token(token, site)
    end

    test "a link made for another bot does not keep the card waiting", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, %{uuid: other}} = Integrations.add_connection("telegram", "new bot")
      {:ok, _} = Integrations.save_setup(other, %{"bot_token" => "222:NEW"})
      {:ok, _} = Linking.create_token(user, other)
      assert site != other

      {:ok, _view, html} = live(conn, @path)

      refute html =~ "Waiting for you to press Start"
      assert html =~ "Connect Telegram"
    end
  end

  describe "several users" do
    setup %{site: site},
      do:
        (
          :ok = SiteBot.select(site)
          :ok
        )

    test "Disconnect unlinks only the one who pressed it", %{conn: conn, user: user, site: site} do
      other = register("other")
      {:ok, _} = Linking.link_chat(user, site, 9_001)
      {:ok, _} = Linking.link_chat(other, site, 5_555)

      {:ok, view, _html} = live(conn, @path)
      view |> element("button", "Disconnect") |> render_click()

      assert config(user)["site_chat_id"] == nil
      assert config(other)["site_chat_id"] == "5555"
      assert config(other)["site_connection_uuid"] == site
    end

    test "saving the types does not put back an older copy of the config", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, _} = Linking.link_chat(user, site, 9_001)
      {:ok, view, _html} = live(conn, @path)

      # Changed after the page loaded, e.g. in another tab.
      {:ok, _} =
        ChannelConfig.update(Auth.get_user!(user.uuid), "telegram", &Map.put(&1, "later", "kept"))

      view
      |> form("#telegram-notifications-card-types", %{"telegram_types" => %{}})
      |> render_submit()

      assert config(user)["later"] == "kept"
    end
  end

  describe "where a link is not made" do
    setup %{site: site},
      do:
        (
          :ok = SiteBot.select(site)
          :ok
        )

    defp host(conn, user, session),
      do: live_isolated(conn, Host, session: Map.put(session, "user_uuid", user.uuid))

    defp forge_connect(view),
      do: view |> with_target("#telegram-notifications-card") |> render_hook("connect", %{})

    defp link_tokens(user),
      do:
        RepoHelper.repo().aggregate(
          from(t in UserToken, where: t.user_uuid == ^user.uuid and t.context == "telegram_link"),
          :count
        )

    test "a host that says the session is not borrowed gets the card", %{conn: conn, user: user} do
      {:ok, view, html} = host(conn, user, %{"impersonated" => false})

      assert html =~ "Connect Telegram"
      assert forge_connect(view) =~ "t.me/shop_bot?start="
      assert link_tokens(user) == 1
    end

    test "a borrowed session offers no Connect, and a forged connect mints nothing", %{
      conn: conn,
      user: user
    } do
      {:ok, view, html} = host(conn, user, %{"impersonated" => true})

      refute html =~ "Connect Telegram"
      assert html =~ "can&#39;t be connected from this session"

      html = forge_connect(view)

      assert html =~ "can&#39;t be connected from this session"
      refute html =~ "t.me/shop_bot"
      assert link_tokens(user) == 0
      refute_received {:telegram, "getMe", _}
    end

    test "a host that does not say is refused like a borrowed session", %{conn: conn, user: user} do
      for session <- [%{}, %{"impersonated" => nil}, %{"impersonated" => "false"}] do
        {:ok, view, html} = host(conn, user, session)

        refute html =~ "Connect Telegram"
        # The host forgot the attribute; that is not the session's fault.
        assert html =~ "can&#39;t be connected on this page"
        refute html =~ "from this session"
        forge_connect(view)
        assert link_tokens(user) == 0
      end
    end

    test "the profile page itself refuses to connect in an impersonated session", %{
      conn: conn,
      user: user
    } do
      root_token = Auth.generate_user_session_token(register("root"))
      active_token = Plug.Conn.get_session(conn, :user_token)
      borrowed = Plug.Conn.put_session(conn, :pk_session_accounts, [root_token, active_token])

      {:ok, view, html} = live(borrowed, @path)

      refute html =~ "Connect Telegram"
      assert html =~ "can&#39;t be connected from this session"

      forge_connect(view)
      assert link_tokens(user) == 0
      refute_received {:telegram, "getMe", _}

      # The same page in the person's own session offers it.
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "Connect Telegram"
    end

    test "a borrowed session does not offer to reconnect or get a new link", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, _} = Linking.link_chat(user, site, 9_001)

      {:ok, _} =
        ChannelConfig.update(
          Auth.get_user!(user.uuid),
          "telegram",
          &Map.put(&1, "status", "disabled")
        )

      {:ok, view, html} = host(conn, user, %{"impersonated" => true})

      assert html =~ "Switched off"
      refute html =~ "Reconnect"
      forge_connect(view)
      assert link_tokens(user) == 0

      # Disconnecting stays possible, as revoking a key does.
      view |> element("button", "Disconnect") |> render_click()
      assert config(user)["site_chat_id"] == nil
    end

    test "a managed organization is shown no card, whatever event is forged", %{
      conn: conn,
      user: user
    } do
      RepoHelper.repo().update_all(from(u in Auth.User, where: u.uuid == ^user.uuid),
        set: [managed_by_members: true, account_type: "organization"]
      )

      {:ok, view, html} = host(conn, user, %{"impersonated" => false})

      refute html =~ "Telegram"
      forge_connect(view)
      view |> with_target("#telegram-notifications-card") |> render_hook("check", %{})
      assert link_tokens(user) == 0
      refute_received {:telegram, "getMe", _}
    end

    test "a managed organization with a link stored earlier can only disconnect it", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, _} = Linking.link_chat(user, site, 9_100)

      RepoHelper.repo().update_all(from(u in Auth.User, where: u.uuid == ^user.uuid),
        set: [managed_by_members: true, account_type: "organization"]
      )

      {:ok, view, html} = host(conn, user, %{"impersonated" => false})

      assert html =~ "Disconnect"
      refute html =~ "Connect Telegram"
      refute html =~ "Reconnect"
      refute html =~ "telegram_types"

      forge_connect(view)
      assert link_tokens(user) == 0

      view
      |> with_target("#telegram-notifications-card")
      |> render_hook("save_types", %{"telegram_types" => %{"x" => "true"}})

      refute Map.has_key?(config(user)["types"] || %{}, "x")

      view |> element("button", "Disconnect") |> render_click()
      assert config(user)["site_chat_id"] == nil
      refute render(view) =~ "Telegram"
    end
  end

  describe "a link that was dropped" do
    setup %{site: site},
      do:
        (
          :ok = SiteBot.select(site)
          :ok
        )

    test "the card says it was disconnected and must be connected again", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, _} = Linking.link_chat(user, site, 9_200)
      Sessions.revoke_user_sessions(Auth.get_user!(user.uuid))

      {:ok, _view, html} = live(log_in_user(conn, user), @path)

      assert html =~ "was disconnected"
      assert html =~ "Connect Telegram"

      # Connecting again clears the note.
      {:ok, _} = Linking.link_chat(Auth.get_user!(user.uuid), site, 9_200)
      {:ok, _view, html} = live(log_in_user(conn, user), @path)
      refute html =~ "was disconnected"
      assert html =~ "Connected"
    end

    test "a user who never had a link is not told anything", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      refute html =~ "was disconnected"
    end
  end
end
