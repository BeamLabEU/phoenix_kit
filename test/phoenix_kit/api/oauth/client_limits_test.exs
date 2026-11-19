defmodule PhoenixKit.API.OAuth.ClientLimitsTest do
  @moduledoc """
  The buckets of the client side of the OAuth server (`PhoenixKit.API.OAuth.Limits`): metadata
  fetches per network and per client, registrations per network and for the whole install.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0, unique_ip: 0]

  alias PhoenixKit.API.OAuth.Limits

  setup do
    setup_api()
  end

  test "metadata fetches are counted per network" do
    put_setting("api_oauth_cimd_per_min", 2)
    ip = unique_ip()

    assert :ok = Limits.hit(:cimd_ip, ip)
    assert :ok = Limits.hit(:cimd_ip, ip)
    assert {:error, seconds} = Limits.hit(:cimd_ip, ip)
    assert seconds in 1..60

    # Another network has its own count.
    assert :ok = Limits.hit(:cimd_ip, unique_ip())
  end

  test "metadata fetches are counted per client, whatever the network" do
    put_setting("api_oauth_cimd_client_per_min", 2)
    client_id = "https://client.example/#{System.unique_integer([:positive])}"

    assert :ok = Limits.hit(:cimd_client, client_id)
    assert :ok = Limits.hit(:cimd_client, client_id)
    assert {:error, _seconds} = Limits.hit(:cimd_client, client_id)

    assert :ok = Limits.hit(:cimd_client, client_id <> "/other")
  end

  test "registrations are counted per network over an hour" do
    put_setting("api_oauth_register_per_hour", 1)
    ip = unique_ip()

    assert :ok = Limits.hit(:register_ip, ip)
    assert {:error, seconds} = Limits.hit(:register_ip, ip)
    assert_window_end(seconds, 3600)
  end

  test "registrations are counted for the whole install over a day" do
    Limits.reset(:register_global, nil)
    put_setting("api_oauth_register_per_day", 2)

    assert :ok = Limits.hit(:register_global, nil)
    assert :ok = Limits.hit(:register_global, nil)
    assert {:error, seconds} = Limits.hit(:register_global, nil)
    assert_window_end(seconds, 86_400)

    Limits.reset(:register_global, nil)
    assert :ok = Limits.hit(:register_global, nil)
  end

  test "the existing buckets keep working with a network" do
    put_setting("api_oauth_authorize_per_min", 1)
    ip = unique_ip()

    assert :ok = Limits.hit(:authorize, ip)
    assert {:error, _seconds} = Limits.hit(:authorize, ip)
  end

  # The windows are fixed and aligned to the clock: the wait is what is left of the hour (or the
  # day) the answer came in, a few seconds either way. Late in the hour that is under a minute, so
  # a bare "more than a minute" would fail by the time of day.
  defp assert_window_end(seconds, window) do
    left = window - rem(System.os_time(:second), window)
    assert abs(seconds - left) <= 5, "waits #{seconds} s, the window has #{left} s left"
  end
end
