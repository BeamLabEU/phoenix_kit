defmodule PhoenixKitWeb.Live.Integrations.MyIntegrationFormChatLinkingTest do
  @moduledoc """
  Linking a Telegram chat that capture cannot reach.

  Capture only sees chats whose update is still in Telegram's ~24h queue, and
  before this it only ever looked at PRIVATE chats — so a bot added to a group
  had no path into `chat_ids` at all, and an id the operator already knew had
  nowhere to be typed. These drive the real LiveView events on
  `/profile/settings/integrations/:uuid`.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @group_id "-1001234567890"
  @dm_id "428897538"

  setup %{conn: conn} do
    {user, _token} = create_admin_user()

    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations")

    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("telegram", "shop bot", user.uuid, owner: {:user, user.uuid})

    {:ok, _} =
      Integrations.save_setup(uuid, %{"bot_token" => "123:ABC"}, user.uuid,
        owner: {:user, user.uuid}
      )

    %{conn: log_in_user(conn, user), user: user, uuid: uuid}
  end

  defp edit_path(uuid), do: Routes.path("/profile/settings/integrations/#{uuid}")

  defp linked_ids(uuid, user) do
    [conn] = Integrations.list_connections("telegram", owner: {:user, user.uuid})
    ^uuid = conn.uuid
    conn.data["chat_ids"] || []
  end

  describe "linking a chat by id" do
    test "a group id typed by hand is linked", %{conn: conn, uuid: uuid, user: user} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      html = render_submit(view, "link_chat", %{"chat_id" => @group_id})

      assert linked_ids(uuid, user) == [@group_id]
      assert html =~ @group_id
    end

    test "the linked chat is labelled as a group, not shown as a bare number", %{
      conn: conn,
      uuid: uuid
    } do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      html = render_submit(view, "link_chat", %{"chat_id" => @group_id})

      assert html =~ "Group"
    end

    test "a junk id is refused and nothing is linked", %{conn: conn, uuid: uuid, user: user} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      html = render_submit(view, "link_chat", %{"chat_id" => "not an id"})

      assert linked_ids(uuid, user) == []
      assert html =~ "alert-error"
    end

    test "linking the same chat twice does not duplicate it", %{
      conn: conn,
      uuid: uuid,
      user: user
    } do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_submit(view, "link_chat", %{"chat_id" => @group_id})
      render_submit(view, "link_chat", %{"chat_id" => @group_id})

      assert linked_ids(uuid, user) == [@group_id]
    end
  end

  describe "confirming a group the Test found" do
    # The event only links a group THIS process captured. A forged event naming
    # any other chat must not reach `chat_ids`.
    test "a chat id that was never captured is not linked", %{conn: conn, uuid: uuid, user: user} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "link_candidate", %{"chat_id" => @group_id})

      assert linked_ids(uuid, user) == []
    end
  end

  describe "unlinking one chat" do
    test "removes only the named chat", %{conn: conn, uuid: uuid, user: user} do
      {:ok, _} =
        Integrations.save_setup(uuid, %{"chat_ids" => [@dm_id, @group_id]}, user.uuid,
          owner: {:user, user.uuid}
        )

      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "unlink_chat", %{"chat_id" => @group_id})

      assert linked_ids(uuid, user) == [@dm_id]
    end
  end

  describe "metadata follows the linked chats" do
    test "unlinking a chat drops what was remembered about it", %{
      conn: conn,
      uuid: uuid,
      user: user
    } do
      {:ok, _} =
        Integrations.save_setup(
          uuid,
          %{
            "chat_ids" => [@dm_id, @group_id],
            "chat_meta" => %{
              @dm_id => %{"type" => "private", "title" => nil},
              @group_id => %{"type" => "supergroup", "title" => "Shop"}
            }
          },
          user.uuid,
          owner: {:user, user.uuid}
        )

      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "unlink_chat", %{"chat_id" => @group_id})

      [conn_row] = Integrations.list_connections("telegram", owner: {:user, user.uuid})

      assert Map.keys(conn_row.data["chat_meta"]) == [@dm_id]
    end
  end

  describe "Test in \"Only me\" mode when several people messaged the bot" do
    @stub __MODULE__.Telegram

    # The Test press runs getMe and getUpdates inside the LiveView process.
    setup {Req.Test, :set_req_test_to_shared}

    setup do
      Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
      on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)

      Req.Test.stub(@stub, fn conn ->
        if String.ends_with?(conn.request_path, "/getMe") do
          Req.Test.json(conn, %{"ok" => true, "result" => %{"username" => "shop_bot"}})
        else
          Req.Test.json(conn, %{"ok" => true, "result" => pending_updates()})
        end
      end)

      :ok
    end

    # A, then B, then C sent /start — the order the issue's repro uses.
    defp pending_updates do
      for {update_id, chat_id} <- [{1, 5_550_001}, {2, 5_550_002}, {3, 5_550_003}] do
        %{
          "update_id" => update_id,
          "message" => %{"chat" => %{"id" => chat_id, "type" => "private"}, "text" => "/start"}
        }
      end
    end

    test "links no chat, instead of whoever messaged last", %{conn: conn, uuid: uuid, user: user} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "validate_connection", %{})
      html = render(view)

      assert linked_ids(uuid, user) == []
      assert html =~ "Several people have messaged this bot"
    end

    test "does not show the strangers' chats", %{conn: conn, uuid: uuid} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "validate_connection", %{})
      html = render(view)

      for id <- ~w(5550001 5550002 5550003), do: refute(html =~ id)
    end
  end

  describe "Test in \"Only me\" mode when exactly one person messaged the bot" do
    @one_stub __MODULE__.OneChatTelegram

    setup {Req.Test, :set_req_test_to_shared}

    setup do
      Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @one_stub})
      on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)

      Req.Test.stub(@one_stub, fn conn ->
        if String.ends_with?(conn.request_path, "/getMe") do
          Req.Test.json(conn, %{"ok" => true, "result" => %{"username" => "shop_bot"}})
        else
          update = %{
            "update_id" => 1,
            "message" => %{
              "chat" => %{"id" => 5_550_001, "type" => "private"},
              "text" => "/start"
            }
          }

          Req.Test.json(conn, %{"ok" => true, "result" => [update]})
        end
      end)

      :ok
    end

    test "links that chat and says so", %{conn: conn, uuid: uuid, user: user} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "validate_connection", %{})
      html = render(view)

      assert linked_ids(uuid, user) == ["5550001"]
      assert html =~ "Linked 1 chat(s)"
      refute html =~ "Several people have messaged this bot"
    end
  end

  describe "Test while a resident reader holds the bot" do
    @held_stub __MODULE__.HeldTelegram

    setup {Req.Test, :set_req_test_to_shared}

    setup do
      Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @held_stub})
      Application.put_env(:phoenix_kit, :telegram_updates_reader, {__MODULE__, :holds?, [true]})

      on_exit(fn ->
        Application.delete_env(:phoenix_kit, :telegram_req_options)
        Application.delete_env(:phoenix_kit, :telegram_updates_reader)
      end)

      test_pid = self()

      Req.Test.stub(@held_stub, fn conn ->
        method = conn.request_path |> String.split("/") |> List.last()
        send(test_pid, {:telegram, method})

        result =
          case method do
            "getMe" -> %{"username" => "shop_bot"}
            _ -> pending_updates()
          end

        Req.Test.json(conn, %{"ok" => true, "result" => result})
      end)

      :ok
    end

    def holds?(answer, _connection_uuid), do: answer

    test "does not read the bot's updates, links nothing and says why", %{
      conn: conn,
      uuid: uuid,
      user: user
    } do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "validate_connection", %{})
      html = render(view)

      assert_received {:telegram, "getMe"}
      refute_received {:telegram, "getUpdates"}
      assert linked_ids(uuid, user) == []
      assert html =~ "read by the site, so your chat can"
    end

    test "reads as before when the reader does not hold the bot", %{conn: conn, uuid: uuid} do
      Application.put_env(:phoenix_kit, :telegram_updates_reader, {__MODULE__, :holds?, [false]})
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "validate_connection", %{})
      render(view)

      assert_received {:telegram, "getUpdates"}
    end
  end

  describe "the group is discoverable at all" do
    test "the card tells the operator the command that links a group", %{conn: conn, uuid: uuid} do
      # Telegram privacy mode means plain chatter in a group never reaches the
      # bot: without the command spelled out, pressing Test in a group is a
      # coin flip. This assertion is the whole point of the UI change.
      {:ok, _view, html} = live(conn, edit_path(uuid))

      assert html =~ "/start@"
    end

    test "the personal form keeps the chat-linking instructions", %{conn: conn, uuid: uuid} do
      {:ok, _view, html} = live(conn, edit_path(uuid))

      assert html =~ "Link the chats the bot will message"
      refute html =~ "not used for user notifications"
    end
  end
end
