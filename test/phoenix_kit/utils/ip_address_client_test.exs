defmodule PhoenixKit.Utils.IpAddressClientTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.IpAddress

  defp conn(ip, headers \\ []), do: %Plug.Conn{remote_ip: ip, req_headers: headers}

  test "a public peer is the address, whatever the headers say" do
    assert IpAddress.client_address(conn({203, 0, 113, 7})) == "203.0.113.7"

    assert IpAddress.client_address(conn({203, 0, 113, 7}, [{"x-forwarded-for", "1.1.1.1"}])) ==
             "203.0.113.7"
  end

  test "behind a local proxy the LAST forwarded entry wins" do
    headers = [{"x-forwarded-for", "9.9.9.9, 203.0.113.7"}]
    assert IpAddress.client_address(conn({127, 0, 0, 1}, headers)) == "203.0.113.7"
    assert IpAddress.client_address(conn({172, 18, 0, 1}, headers)) == "203.0.113.7"
    assert IpAddress.client_address(conn({10, 0, 0, 5}, headers)) == "203.0.113.7"
    assert IpAddress.client_address(conn({0, 0, 0, 0, 0, 0, 0, 1}, headers)) == "203.0.113.7"
  end

  test "two header lines are one list; the last entry still wins" do
    headers = [{"x-forwarded-for", "203.0.113.10"}, {"x-forwarded-for", "198.51.100.20"}]
    assert IpAddress.client_address(conn({127, 0, 0, 1}, headers)) == "198.51.100.20"
  end

  test "x-real-ip is the fallback; junk is nobody" do
    assert IpAddress.client_address(conn({127, 0, 0, 1}, [{"x-real-ip", "203.0.113.9"}])) ==
             "203.0.113.9"

    assert IpAddress.client_address(conn({127, 0, 0, 1}, [{"x-forwarded-for", "not an ip"}])) ==
             "127.0.0.1"

    assert IpAddress.client_address(conn({127, 0, 0, 1})) == "127.0.0.1"
  end

  test "IPv6 is formatted the usual way" do
    assert IpAddress.client_address(conn({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})) == "2001:db8::1"
  end

  # Caddy's `{remote}` — what a Caddyfile writes into `header_up` — is the
  # address WITH the port it saw. Unread, every visitor became the proxy.
  describe "a forwarded address with a port" do
    defp forwarded(value), do: IpAddress.client_address(conn({172, 18, 0, 8}, value))

    test "IPv4 with a port is the address" do
      assert forwarded([{"x-forwarded-for", "203.0.113.7:28858"}]) == "203.0.113.7"
    end

    test "bracketed IPv6, with or without a port, is the address" do
      assert forwarded([{"x-forwarded-for", "[2001:db8::7]:28858"}]) == "2001:db8::7"
      assert forwarded([{"x-forwarded-for", "[2001:db8::7]"}]) == "2001:db8::7"
    end

    test "a bare IPv6 address is never cut — its last group is not a port" do
      assert forwarded([{"x-forwarded-for", "2001:db8::1:443"}]) == "2001:db8::1:443"
    end

    test "junk around a colon is nobody" do
      assert forwarded([{"x-forwarded-for", "203.0.113.7:abc"}]) == "172.18.0.8"
      assert forwarded([{"x-forwarded-for", ":80"}]) == "172.18.0.8"
      assert forwarded([{"x-forwarded-for", "[not-an-ip]:80"}]) == "172.18.0.8"
    end

    test "the last entry of a chain may carry the port" do
      assert forwarded([{"x-forwarded-for", "9.9.9.9, 203.0.113.7:28858"}]) == "203.0.113.7"
    end

    test "x-real-ip with a port is the address" do
      assert forwarded([{"x-real-ip", "203.0.113.9:443"}]) == "203.0.113.9"
    end
  end

  describe "an IPv4-mapped address is reported as IPv4" do
    test "a public peer on a dual-stack listener" do
      assert IpAddress.client_address(conn({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107})) ==
               "203.0.113.7"
    end

    test "a forwarded one" do
      headers = [{"x-forwarded-for", "::ffff:203.0.113.7"}]
      assert IpAddress.client_address(conn({127, 0, 0, 1}, headers)) == "203.0.113.7"
    end
  end

  describe "client_address_from_socket/1" do
    defp socket(ip, x_headers) do
      %Phoenix.LiveView.Socket{
        private: %{connect_info: %{peer_data: %{address: ip}, x_headers: x_headers}}
      }
    end

    test "behind a local proxy, a forwarded address with a port is the address" do
      assert IpAddress.client_address_from_socket(
               socket({172, 18, 0, 8}, [{"x-forwarded-for", "203.0.113.7:28858"}])
             ) == "203.0.113.7"

      assert IpAddress.client_address_from_socket(
               socket({172, 18, 0, 8}, [{"x-real-ip", "[2001:db8::7]:28858"}])
             ) == "2001:db8::7"
    end

    test "a public IPv4-mapped peer is reported as IPv4" do
      assert IpAddress.client_address_from_socket(
               socket({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}, nil)
             ) == "203.0.113.7"
    end
  end

  test "local_address?/1 names the addresses a proxy connects from" do
    assert IpAddress.local_address?("127.0.0.1")
    assert IpAddress.local_address?("172.18.0.8")
    assert IpAddress.local_address?("::ffff:10.0.0.5")
    refute IpAddress.local_address?("203.0.113.7")
    refute IpAddress.local_address?("unknown")
    refute IpAddress.local_address?(nil)
  end
end
