defmodule PhoenixKit.Integration.Integrations.TelegramChatsTest do
  @moduledoc """
  What a host's bot that works in groups needs from `PhoenixKit.Integrations.Telegram`:
  `get_chat/3`, `get_chat_member/4`, `leave_chat/3`, `set_my_commands/3`, and that a file
  download (`download_file/3`) goes to the configured Bot API server too. Telegram is
  stubbed with `Req.Test` (`:telegram_req_options`); nothing here opens a socket.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram

  @stub __MODULE__.Telegram

  setup do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :telegram_req_options)
      Application.delete_env(:phoenix_kit, :telegram_api_base)
    end)

    {:ok, %{uuid: uuid}} = Integrations.add_connection("telegram", "chats bot")
    {:ok, _} = Integrations.save_setup(uuid, %{"bot_token" => "123:ABC"})
    %{connection: uuid}
  end

  # Answers every Bot API method with `result`, and tells the test what was asked.
  defp stub_method(result, test_pid \\ self()) do
    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:telegram, List.last(String.split(conn.request_path, "/")), Jason.decode!(raw)}
      )

      Req.Test.json(conn, %{"ok" => true, "result" => result})
    end)
  end

  test "a file download goes to the configured Bot API server", %{connection: connection} do
    Application.put_env(:phoenix_kit, :telegram_api_base, "http://bot-api.test:8081/")
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, {:asked, conn.scheme, conn.host, conn.port, conn.request_path})

      case conn.request_path do
        "/bot123:ABC/getFile" ->
          Req.Test.json(conn, %{
            "ok" => true,
            "result" => %{"file_path" => "photos/file_0.jpg", "file_size" => 9}
          })

        _file ->
          Plug.Conn.send_resp(conn, 200, "JPEGBYTES")
      end
    end)

    assert {:ok, "JPEGBYTES"} = Telegram.download_file(connection, "F1")
    assert_received {:asked, :http, "bot-api.test", 8081, "/bot123:ABC/getFile"}
    assert_received {:asked, :http, "bot-api.test", 8081, "/file/bot123:ABC/photos/file_0.jpg"}
  end

  describe "chats and commands" do
    test "get_chat/3 asks for the chat", %{connection: connection} do
      stub_method(%{"id" => -400, "type" => "group", "has_protected_content" => true})

      assert {:ok, %{"has_protected_content" => true}} = Telegram.get_chat(connection, -400)
      assert_received {:telegram, "getChat", %{"chat_id" => -400}}
    end

    test "get_chat_member/4 asks for one member of the chat", %{connection: connection} do
      stub_method(%{"status" => "administrator", "user" => %{"id" => 7}})

      assert {:ok, %{"status" => "administrator"}} =
               Telegram.get_chat_member(connection, -400, 7)

      assert_received {:telegram, "getChatMember", %{"chat_id" => -400, "user_id" => 7}}
    end

    test "leave_chat/3 leaves the chat", %{connection: connection} do
      stub_method(true)

      assert {:ok, true} = Telegram.leave_chat(connection, -400)
      assert_received {:telegram, "leaveChat", %{"chat_id" => -400}}
    end

    test "set_my_commands/3 sends the list, with a scope and a language when given",
         %{connection: connection} do
      stub_method(true)
      commands = [%{command: "fotki", description: "Where photos from here go"}]

      assert {:ok, true} = Telegram.set_my_commands(connection, commands)

      assert_received {:telegram, "setMyCommands", body}

      assert body == %{
               "commands" => [
                 %{"command" => "fotki", "description" => "Where photos from here go"}
               ]
             }

      assert {:ok, true} =
               Telegram.set_my_commands(connection, commands,
                 scope: %{type: "all_group_chats"},
                 language_code: "et"
               )

      assert_received {:telegram, "setMyCommands",
                       %{"scope" => %{"type" => "all_group_chats"}, "language_code" => "et"}}
    end
  end
end
