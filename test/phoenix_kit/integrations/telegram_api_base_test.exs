defmodule PhoenixKit.Integrations.TelegramApiBaseTest do
  @moduledoc """
  `Telegram.api_base/0`: which Bot API server every call goes to. A setting
  that is not an http(s) URL raises instead of sending the token elsewhere.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Telegram

  setup do
    previous = Application.fetch_env(:phoenix_kit, :telegram_api_base)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :telegram_api_base, value)
        :error -> Application.delete_env(:phoenix_kit, :telegram_api_base)
      end
    end)

    :ok
  end

  test "is Telegram's cloud when nothing is configured" do
    Application.delete_env(:phoenix_kit, :telegram_api_base)

    assert Telegram.api_base() == "https://api.telegram.org"
  end

  test "is the configured server, without a trailing slash" do
    Application.put_env(:phoenix_kit, :telegram_api_base, "http://telegram-bot-api:8081/")

    assert Telegram.api_base() == "http://telegram-bot-api:8081"
  end

  test "raises for a setting that is not an http(s) URL" do
    for bad <- ["telegram-bot-api:8081", "ftp://bot-api.test", "https://", "", :cloud] do
      Application.put_env(:phoenix_kit, :telegram_api_base, bad)

      assert_raise ArgumentError, fn -> Telegram.api_base() end
    end
  end
end
