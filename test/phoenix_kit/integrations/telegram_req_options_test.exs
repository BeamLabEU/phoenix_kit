defmodule PhoenixKit.Integrations.TelegramReqOptionsTest do
  @moduledoc """
  `Telegram.req_options/0` is a test seam for routing Bot API calls through
  `Req.Test`. It passes on the `:plug` and nothing else, so a stray config key
  cannot reach a real request (a `:connect_options` or `:headers` entry would).
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Telegram

  setup do
    previous = Application.fetch_env(:phoenix_kit, :telegram_req_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :telegram_req_options, value)
        :error -> Application.delete_env(:phoenix_kit, :telegram_req_options)
      end
    end)

    :ok
  end

  test "is empty when nothing is configured" do
    Application.delete_env(:phoenix_kit, :telegram_req_options)

    assert Telegram.req_options() == []
  end

  test "passes the plug through" do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, __MODULE__})

    assert Telegram.req_options() == [plug: {Req.Test, __MODULE__}]
  end

  test "drops every other option" do
    Application.put_env(:phoenix_kit, :telegram_req_options,
      plug: {Req.Test, __MODULE__},
      headers: [{"x-evil", "1"}],
      connect_options: [proxy: {:http, "evil.example", 80, []}]
    )

    assert Telegram.req_options() == [plug: {Req.Test, __MODULE__}]
  end

  test "the default update peek does not discard updates or change the bot's subscription" do
    stub_updates(%{})

    assert {:ok, []} = Telegram.get_updates_with_token("test-token")
  end

  test "an explicitly requested offset and subscription are sent" do
    stub_updates(%{"offset" => -1, "allowed_updates" => ["message"], "timeout" => 0})

    assert {:ok, []} =
             Telegram.get_updates_with_token("test-token",
               offset: -1,
               allowed_updates: ["message"],
               timeout: 0
             )
  end

  describe "get_updates receive timeout" do
    test "a long poll waits its own timeout plus ten seconds" do
      assert Telegram.receive_timeout(25) == 35_000
      assert Telegram.receive_timeout(30) == 40_000
    end

    test "a short or absent timeout keeps the default wait" do
      assert Telegram.receive_timeout(nil) == 15_000
      assert Telegram.receive_timeout(0) == 15_000
      assert Telegram.receive_timeout(2) == 15_000
    end

    test "a long poll that Telegram answers late is not cut off at the default wait" do
      # Req.Test does not enforce `receive_timeout`, so this only shows a
      # delayed answer is read as an answer; the wait itself is pinned above.
      Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn conn ->
        Process.sleep(150)
        Req.Test.json(conn, %{"ok" => true, "result" => [%{"update_id" => 1}]})
      end)

      assert {:ok, [%{"update_id" => 1}]} =
               Telegram.get_updates_with_token("test-token", timeout: 25)
    end
  end

  defp stub_updates(expected) do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/bottest-token/getUpdates"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == expected
      Req.Test.json(conn, %{"ok" => true, "result" => []})
    end)
  end
end
