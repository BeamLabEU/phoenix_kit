defmodule PhoenixKit.Utils.IpAddressNetworkTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.IpAddress

  describe "network/1" do
    test "an IPv6 address is its /64" do
      assert IpAddress.network("2a0d:3344:6a:c310:88f8:482c:e41a:9ef5") ==
               "2a0d:3344:6a:c310::/64"

      assert IpAddress.network("2a0d:3344:6a:c310::1") == "2a0d:3344:6a:c310::/64"
      assert IpAddress.network("2a0d:3344:6a:c311::1") == "2a0d:3344:6a:c311::/64"
    end

    test "an IPv4 address is itself, mapped or not" do
      assert IpAddress.network("203.0.113.7") == "203.0.113.7"
      assert IpAddress.network("::ffff:203.0.113.7") == "203.0.113.7"
    end

    test "loopback, unspecified, and link-local are the address itself" do
      assert IpAddress.network("::1") == "::1"
      assert IpAddress.network("::") == "::"
      assert IpAddress.network("fe80::1") == "fe80::1"
      assert IpAddress.network("fe80::2") == "fe80::2"
      assert IpAddress.network("febf::1") == "febf::1"
    end

    test "NAT64 and IPv4-compatible unmap to the embedded IPv4" do
      assert IpAddress.network("64:ff9b::203.0.113.7") == "203.0.113.7"
      assert IpAddress.network("::203.0.113.7") == "203.0.113.7"
    end

    test "anything unparseable comes back unchanged" do
      assert IpAddress.network("unknown") == "unknown"
      assert IpAddress.network("") == ""
      assert IpAddress.network(nil) == nil
    end
  end

  describe "extract_ip_address/1" do
    test "formats IPv6 in standard hex" do
      assert IpAddress.extract_ip_address(%{address: {0x2001, 0xDB8, 1, 0, 0, 0, 0, 1}}) ==
               "2001:db8:1::1"
    end

    test "still formats IPv4 and rejects junk" do
      assert IpAddress.extract_ip_address(%{address: {192, 168, 1, 1}}) == "192.168.1.1"
      assert IpAddress.extract_ip_address(%{address: {:a, :b, :c, :d}}) == "unknown"
      assert IpAddress.extract_ip_address(nil) == "unknown"
    end

    test "reports an IPv4-mapped peer as IPv4, like client_address/1" do
      assert IpAddress.extract_ip_address(%{address: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}}) ==
               "203.0.113.7"
    end
  end
end
