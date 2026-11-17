defmodule PhoenixKit.API.OAuth.RedirectUriTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.OAuth.RedirectUri

  describe "valid?/1" do
    test "https, and http to the loopback, are registrable" do
      for uri <- [
            "https://client.example/callback",
            "https://client.example:8443/cb?x=1",
            "HTTPS://Client.Example/cb",
            "http://127.0.0.1/cb",
            "http://127.0.0.1:53211/cb",
            "http://[::1]:8080/cb",
            "http://localhost:3000/cb"
          ] do
        assert RedirectUri.valid?(uri), uri
      end
    end

    test "plain http beyond the loopback is not" do
      refute RedirectUri.valid?("http://client.example/cb")
      refute RedirectUri.valid?("http://127.0.0.1.example/cb")
      refute RedirectUri.valid?("http://192.168.1.5/cb")
    end

    test "no wildcard, fragment, userinfo, space or control character" do
      for uri <- [
            "*",
            "https://*.client.example/cb",
            "https://client.example/*",
            "https://client.example/cb#frag",
            "https://user:pw@client.example/cb",
            "https://client.example/a b",
            "https://client.example/a\\b",
            "https://client.example/cb\n",
            "https://client.example/\0"
          ] do
        refute RedirectUri.valid?(uri), inspect(uri)
      end
    end

    test "other schemes are not" do
      for uri <- [
            "javascript:alert(1)",
            "data:text/html,x",
            "file:///etc/passwd",
            "cursor://callback",
            "app://cb",
            "//client.example/cb",
            "/cb",
            "client.example/cb",
            ""
          ] do
        refute RedirectUri.valid?(uri), uri
      end
    end

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

    test "no host is no URI, and what is not text or too long is refused" do
      refute RedirectUri.valid?("https:///cb")
      refute RedirectUri.valid?(nil)
      refute RedirectUri.valid?(5)
      refute RedirectUri.valid?(<<0xFF>>)
      refute RedirectUri.valid?("https://client.example/" <> String.duplicate("a", 2048))
      assert RedirectUri.max_length() == 2048
    end
  end
end
