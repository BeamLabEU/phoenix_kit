defmodule PhoenixKit.Integration.Users.FingerprintProxyRebindTest do
  @moduledoc """
  A session stored with a reverse proxy's address moves to the visitor's.

  Behind a proxy that writes `ip:port` (Caddy's `{remote}`), core could not
  read the forwarded address and stored the proxy's own (`172.18.0.8`) on
  every session token. Once the address is read, every request of every such
  session would be a changed IP — a warning each time, a sign-out under
  strict mode. The first request from the same browser moves the token to
  the visitor's address instead, silently.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.SessionFingerprint
  alias PhoenixKitWeb.Users.Auth, as: AuthPlugs

  @ua "Mozilla/5.0 same browser"

  setup do
    original = Application.get_env(:phoenix_kit, :session_fingerprint_strict)
    Application.put_env(:phoenix_kit, :session_fingerprint_strict, true)
    on_exit(fn -> Application.put_env(:phoenix_kit, :session_fingerprint_strict, original) end)

    # The suite runs at :warning; the "moved" line is :info. A process
    # level cannot go below the global one, a module level can — and only
    # for this module's lines.
    Logger.put_module_level(PhoenixKit.Users.Auth, :info)
    on_exit(fn -> Logger.delete_module_level(PhoenixKit.Users.Auth) end)

    {:ok, user} =
      Auth.register_user(%{
        email: "fp_rebind_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    %{user: user}
  end

  defp token_stored_at(user, ip) do
    fingerprint = %SessionFingerprint{
      ip_address: ip,
      user_agent_hash: SessionFingerprint.hash_user_agent(request("9.9.9.9"))
    }

    Auth.generate_user_session_token(user, fingerprint: fingerprint)
  end

  defp request(forwarded, ua \\ @ua) do
    :get
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, {172, 18, 0, 8})
    |> Plug.Conn.put_req_header("x-forwarded-for", forwarded)
    |> Plug.Conn.put_req_header("user-agent", ua)
  end

  defp direct_request(peer) do
    :get
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, peer)
    |> Plug.Conn.put_req_header("user-agent", @ua)
  end

  defp stored_ip(token), do: Auth.get_session_token_record(token).ip_address

  defp verify(conn, token),
    do: with_log([level: :info], fn -> Auth.verify_session_fingerprint(conn, token) end)

  test "a stored proxy address moves to the visitor, without a warning", %{user: user} do
    token = token_stored_at(user, "172.18.0.8")

    {result, log} = verify(request("9.9.9.9:28858"), token)

    assert result == :ok
    refute log =~ "[warning]"
    refute log =~ "[error]"
    assert stored_ip(token) == "9.9.9.9"
  end

  test "strict mode lets the moved session in", %{user: user} do
    token = token_stored_at(user, "172.18.0.8")

    conn =
      request("9.9.9.9:28858")
      |> Plug.Test.init_test_session(%{"user_token" => token})
      |> AuthPlugs.fetch_phoenix_kit_current_user([])

    assert conn.assigns.phoenix_kit_current_user.uuid == user.uuid
  end

  test "it moves once; from then on the visitor's address is checked as usual", %{user: user} do
    token = token_stored_at(user, "172.18.0.8")

    assert {:ok, _} = verify(request("9.9.9.9"), token)
    assert {{:warning, :ip_mismatch}, _} = verify(request("8.8.4.4"), token)
    assert stored_ip(token) == "9.9.9.9"
  end

  test "a stored public address against another public one is a changed IP", %{user: user} do
    token = token_stored_at(user, "8.8.4.4")

    assert {{:warning, :ip_mismatch}, log} = verify(request("9.9.9.9"), token)
    assert log =~ "changed IP"
    assert stored_ip(token) == "8.8.4.4"
  end

  test "a request straight from a public peer does not move the session", %{user: user} do
    token = token_stored_at(user, "172.18.0.8")

    assert {{:warning, :ip_mismatch}, _} = verify(direct_request({9, 9, 9, 9}), token)
    assert stored_ip(token) == "172.18.0.8"

    conn =
      direct_request({9, 9, 9, 9})
      |> Plug.Test.init_test_session(%{"user_token" => token})
      |> AuthPlugs.fetch_phoenix_kit_current_user([])

    assert conn.assigns.phoenix_kit_current_user == nil
  end

  test "a request that lost the race is checked against the winner's address", %{user: user} do
    token = token_stored_at(user, "172.18.0.8")
    stale = Auth.get_session_token_record(token)

    # Another request moved it first, from another address.
    assert {:ok, log} = verify(request("8.8.4.4"), token)
    assert log =~ "to 8.8.4.4"

    {address, log} =
      with_log([level: :info], fn ->
        Auth.rebind_proxy_address(request("9.9.9.9"), stale, token)
      end)

    assert address == "8.8.4.4"
    assert stored_ip(token) == "8.8.4.4"
    refute log =~ "to 9.9.9.9"
  end

  test "another browser does not move the session", %{user: user} do
    token = token_stored_at(user, "172.18.0.8")

    assert {{:error, :fingerprint_mismatch}, _} = verify(request("9.9.9.9", "Other/1.0"), token)
    assert stored_ip(token) == "172.18.0.8"
  end

  test "only the session's own row is written", %{user: user} do
    token = token_stored_at(user, "172.18.0.8")
    other = token_stored_at(user, "172.18.0.8")

    verify(request("9.9.9.9"), token)

    assert stored_ip(other) == "172.18.0.8"
  end
end
