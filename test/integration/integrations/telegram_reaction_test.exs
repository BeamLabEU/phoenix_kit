defmodule PhoenixKit.Integration.Integrations.TelegramReactionTest do
  @moduledoc """
  `Telegram.set_message_reaction/5` — `setMessageReaction` through a stored
  connection. Telegram is stubbed with `Req.Test` (`:telegram_req_options`);
  nothing here opens a socket.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram

  @stub __MODULE__.Telegram

  setup do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)

    {:ok, %{uuid: uuid}} = Integrations.add_connection("telegram", "reaction bot")
    {:ok, _} = Integrations.save_setup(uuid, %{"bot_token" => "123:ABC"})

    %{connection: uuid}
  end

  defp stub_ok(test_pid \\ self()) do
    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:telegram, List.last(String.split(conn.request_path, "/")), Jason.decode!(raw)}
      )

      Req.Test.json(conn, %{"ok" => true, "result" => true})
    end)
  end

  describe "set_message_reaction/5" do
    test "sends one emoji reaction for the message", %{connection: connection} do
      stub_ok()

      assert {:ok, true} = Telegram.set_message_reaction(connection, 428_897_538, 77, "👍")

      assert_received {:telegram, "setMessageReaction", body}

      assert body == %{
               "chat_id" => 428_897_538,
               "message_id" => 77,
               "reaction" => [%{"type" => "emoji", "emoji" => "👍"}]
             }
    end

    test "an empty reaction clears the message's reactions", %{connection: connection} do
      stub_ok()

      assert {:ok, true} = Telegram.set_message_reaction(connection, 1, 2, nil)
      assert_received {:telegram, "setMessageReaction", %{"reaction" => []}}

      assert {:ok, true} = Telegram.set_message_reaction(connection, 1, 2, "")
      assert_received {:telegram, "setMessageReaction", %{"reaction" => []}}
    end

    test "returns the API's description when Telegram refuses (message gone)",
         %{connection: connection} do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "ok" => false,
          "description" => "Bad Request: message to react not found"
        })
      end)

      assert {:error, "Bad Request: message to react not found"} =
               Telegram.set_message_reaction(connection, 1, 2, "👍")
    end

    test "an owner that does not own the connection gets an error and no request",
         %{connection: connection} do
      stub_ok()

      assert {:error, _} =
               Telegram.set_message_reaction(connection, 1, 2, "👍",
                 owner: {:user, Ecto.UUID.generate()}
               )

      refute_received {:telegram, _, _}
    end

    test "an unknown connection is an error, not a request" do
      stub_ok()

      assert {:error, _} = Telegram.set_message_reaction(Ecto.UUID.generate(), 1, 2, "👍")
      refute_received {:telegram, _, _}
    end
  end
end
