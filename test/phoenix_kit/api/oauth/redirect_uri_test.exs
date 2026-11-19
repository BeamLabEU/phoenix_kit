defmodule PhoenixKit.API.OAuth.RedirectUriTest do
  @moduledoc """
  `PhoenixKit.API.OAuth.RedirectUri`: what may be registered, and the exact comparison of a
  requested URI with the registered ones (loopback ports aside).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.OAuth.RedirectUri

  describe "valid?/1" do
    test "https, and http to the loopback" do
      for uri <- [
            "https://client.example/cb",
            "https://client.example:8443/cb?x=1",
            "http://127.0.0.1/cb",
            "http://127.0.0.1:8123/cb",
            "http://[::1]:8123/cb",
            "http://localhost:3000/cb"
          ] do
        assert RedirectUri.valid?(uri), uri
      end
    end

    test "not http to a public host, not a custom scheme, not a fragment, userinfo or wildcard" do
      for uri <- [
            "http://client.example/cb",
            "app://callback",
            "javascript:alert(1)",
            "https://client.example/cb#frag",
            "https://user:pw@client.example/cb",
            "https://*.example/cb",
            "https://client.example/*",
            "https:///cb",
            "/relative",
            "",
            "https://client.example/ cb",
            "https://client.example/cb\\evil",
            "https://client.example/" <> String.duplicate("a", 2100)
          ] do
        refute RedirectUri.valid?(uri), String.slice(uri, 0, 40)
      end

      refute RedirectUri.valid?(nil)
      refute RedirectUri.valid?(42)
    end
  end

  describe "valid?/1 and the port" do
    test "a port that no connection can use is refused" do
      for uri <- [
            "https://client.example:99999/cb",
            "https://client.example:65536/cb",
            "https://client.example:0/cb",
            "https://client.example:/cb",
            "http://127.0.0.1:/cb"
          ] do
        refute RedirectUri.valid?(uri), uri
      end

      assert RedirectUri.valid?("https://client.example:65535/cb")
    end
  end

  describe "allowed?/2" do
    test "an exact match" do
      assert RedirectUri.allowed?("https://client.example/cb", ["https://client.example/cb"])
      refute RedirectUri.allowed?("https://client.example/cb2", ["https://client.example/cb"])
      refute RedirectUri.allowed?("https://client.example/cb/", ["https://client.example/cb"])
      refute RedirectUri.allowed?("https://client.example/cb?x=1", ["https://client.example/cb"])
      refute RedirectUri.allowed?("https://client.example/CB", ["https://client.example/cb"])
      refute RedirectUri.allowed?("https://client.example:8443/cb", ["https://client.example/cb"])
    end

    test "the scheme and the host are compared in lower case, the path as written" do
      assert RedirectUri.allowed?("HTTPS://CLIENT.example/cb", ["https://client.example/cb"])
      refute RedirectUri.allowed?("https://client.example/%63b", ["https://client.example/cb"])
    end

    test "the query is part of the match" do
      registered = ["https://client.example/cb?tenant=7"]
      assert RedirectUri.allowed?("https://client.example/cb?tenant=7", registered)
      refute RedirectUri.allowed?("https://client.example/cb?tenant=8", registered)
      refute RedirectUri.allowed?("https://client.example/cb", registered)
    end

    test "any port on 127.0.0.1 and [::1], an exact one on localhost" do
      assert RedirectUri.allowed?("http://127.0.0.1:51789/cb", ["http://127.0.0.1/cb"])
      assert RedirectUri.allowed?("http://[::1]:1234/cb", ["http://[::1]/cb"])
      refute RedirectUri.allowed?("http://127.0.0.1:51789/other", ["http://127.0.0.1/cb"])
      refute RedirectUri.allowed?("http://localhost:3001/cb", ["http://localhost:3000/cb"])
      assert RedirectUri.allowed?("http://localhost:3000/cb", ["http://localhost:3000/cb"])
      refute RedirectUri.allowed?("http://127.0.0.1:1/cb", ["http://localhost/cb"])
    end

    test "a requested URI that would not be registrable is never allowed" do
      refute RedirectUri.allowed?("https://client.example/cb#f", ["https://client.example/cb#f"])
      refute RedirectUri.allowed?(nil, ["https://client.example/cb"])
      refute RedirectUri.allowed?("https://client.example/cb", nil)
      refute RedirectUri.allowed?("https://client.example/cb", [])
    end
  end

  test "host/1 and loopback?/1" do
    assert RedirectUri.host("https://Client.Example/cb") == "client.example"
    assert RedirectUri.host("nope") == nil
    assert RedirectUri.loopback?("http://127.0.0.1:3/cb")
    assert RedirectUri.loopback?("http://localhost/cb")
    refute RedirectUri.loopback?("https://client.example/cb")
  end

  test "address/1 is the host, the port that is not the scheme's own, and the path" do
    assert RedirectUri.address("https://Pages.Example/users/mallory/cb?x=1") ==
             %{host: "pages.example", port: nil, path: "/users/mallory/cb"}

    assert RedirectUri.address("https://client.example:443/cb").port == nil
    assert RedirectUri.address("https://client.example:8443/cb").port == 8443
    assert RedirectUri.address("http://127.0.0.1:51789/cb").port == 51_789
    assert RedirectUri.address("https://client.example").path == ""
    assert RedirectUri.address("nope") == nil
  end

  test "address/1 writes an IPv6 host in brackets, so the port cannot be read into the address" do
    assert RedirectUri.address("http://[::1]:8080/cb") == %{
             host: "[::1]",
             port: 8080,
             path: "/cb"
           }

    assert RedirectUri.address("https://[2001:db8::1]:8443/x").host == "[2001:db8::1]"

    assert RedirectUri.address("https://[2001:db8::1]/x") == %{
             host: "[2001:db8::1]",
             port: nil,
             path: "/x"
           }
  end
end
