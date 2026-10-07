defmodule PhoenixKit.Utils.SessionFingerprintIpTest do
  @moduledoc """
  `SessionFingerprint.get_ip_address/1` used to trust `x-forwarded-for` /
  `x-real-ip` unconditionally and take the FIRST `x-forwarded-for` entry —
  both client-controlled. Anyone could spoof the IP this module records
  (and that session-hijack detection and "new device" login alerts compare
  against) with a plain header, proxy or no proxy. It now defers to
  `IpAddress.client_address/1`, which only trusts a forwarded header when
  `conn.remote_ip` is itself a loopback/private address, and only the LAST
  entry.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.SessionFingerprint

  defp conn(remote_ip, headers \\ []) do
    Enum.reduce(headers, %Plug.Conn{remote_ip: remote_ip}, fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
  end

  test "a direct public connection cannot be spoofed via x-forwarded-for" do
    assert SessionFingerprint.get_ip_address(
             conn({203, 0, 113, 7}, [
               {"x-forwarded-for", "6.6.6.6"}
             ])
           ) == "203.0.113.7"
  end

  test "a direct public connection cannot be spoofed via x-real-ip" do
    assert SessionFingerprint.get_ip_address(
             conn({203, 0, 113, 7}, [
               {"x-real-ip", "6.6.6.6"}
             ])
           ) == "203.0.113.7"
  end

  test "behind a real local proxy, the LAST forwarded entry is trusted" do
    headers = [{"x-forwarded-for", "6.6.6.6, 203.0.113.7"}]
    assert SessionFingerprint.get_ip_address(conn({127, 0, 0, 1}, headers)) == "203.0.113.7"
  end

  test "no headers, no proxy: the raw peer address" do
    assert SessionFingerprint.get_ip_address(conn({203, 0, 113, 7})) == "203.0.113.7"
  end

  describe "verify_fingerprint/4 with IPv6" do
    test "a rotated address inside the same /64 is the same IP" do
      conn = conn({0x2A0D, 0x3344, 0x6A, 0xC310, 0x1111, 0x2222, 0x3333, 0x4444})

      assert :ok =
               SessionFingerprint.verify_fingerprint(
                 conn,
                 "2a0d:3344:6a:c310:88f8:482c:e41a:9ef5",
                 nil
               )
    end

    test "a different /64 is a changed IP" do
      conn = conn({0x2A0D, 0x3344, 0x6A, 0xC311, 0, 0, 0, 1})

      assert {:warning, :ip_mismatch} =
               SessionFingerprint.verify_fingerprint(
                 conn,
                 "2a0d:3344:6a:c310:88f8:482c:e41a:9ef5",
                 nil
               )
    end
  end

  # Sessions signed in behind a proxy that writes `ip:port` stored the
  # proxy's address; once the visitor's is read, they move to it — once.
  describe "proxy_rebind_address/3" do
    @ua "Mozilla/5.0 same browser"

    defp behind_proxy(forwarded, ua \\ @ua) do
      conn({172, 18, 0, 8}, [{"x-forwarded-for", forwarded}, {"user-agent", ua}])
    end

    defp ua_hash(ua \\ @ua), do: SessionFingerprint.hash_user_agent(behind_proxy("9.9.9.9", ua))

    test "a stored proxy address moves to the public visitor, port and all" do
      assert SessionFingerprint.proxy_rebind_address(
               behind_proxy("9.9.9.9:28858"),
               "172.18.0.8",
               ua_hash()
             ) == "9.9.9.9"

      assert SessionFingerprint.proxy_rebind_address(behind_proxy("9.9.9.9"), "127.0.0.1", nil) ==
               "9.9.9.9"
    end

    test "a stored public address stands" do
      refute SessionFingerprint.proxy_rebind_address(
               behind_proxy("9.9.9.9"),
               "8.8.4.4",
               ua_hash()
             )
    end

    test "a current address that is still local stands" do
      conn = conn({172, 18, 0, 8}, [{"user-agent", @ua}])
      refute SessionFingerprint.proxy_rebind_address(conn, "172.18.0.8", ua_hash())
      refute SessionFingerprint.proxy_rebind_address(conn, "10.0.0.9", ua_hash())
    end

    test "a request straight from a public peer is not moved — only one through the proxy" do
      conn = conn({9, 9, 9, 9}, [{"user-agent", @ua}])

      refute SessionFingerprint.proxy_rebind_address(conn, "172.18.0.8", ua_hash())

      assert {:warning, :ip_mismatch} =
               SessionFingerprint.verify_fingerprint(conn, "172.18.0.8", ua_hash())
    end

    test "another browser is not moved" do
      refute SessionFingerprint.proxy_rebind_address(
               behind_proxy("9.9.9.9", "Other/1.0"),
               "172.18.0.8",
               ua_hash()
             )
    end

    test "a stored public address against another public one is still a changed IP" do
      assert {:warning, :ip_mismatch} =
               SessionFingerprint.verify_fingerprint(
                 behind_proxy("9.9.9.9"),
                 "8.8.4.4",
                 ua_hash()
               )
    end
  end
end
