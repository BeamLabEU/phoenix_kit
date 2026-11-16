defmodule PhoenixKit.API.OAuth.ResourceTest do
  @moduledoc """
  The resource and issuer identifiers (`PhoenixKit.API.OAuth.Resource`) and the normalization a
  `resource` parameter goes through (RFC 8707).
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.MCP.Origin
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Utils.Routes

  setup do
    start_cache_registry!()

    start_supervised!(
      Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
    )

    :persistent_term.erase({Origin, :fallback_warned})
    :ok
  end

  describe "the identifiers" do
    test "the resource is the canonical origin and the admin MCP path under the URL prefix" do
      assert Resource.resource() == Origin.canonical_origin() <> Routes.path("/mcp/admin")
      assert Resource.path() == Routes.path("/mcp/admin")
      assert Resource.issuer() == Origin.canonical_origin()
      refute String.ends_with?(Resource.issuer(), "/")
      refute String.ends_with?(Resource.resource(), "/")
    end

    test "the metadata document sits between the host and the path of the resource (RFC 9728)" do
      assert Resource.metadata_url() ==
               Origin.canonical_origin() <>
                 "/.well-known/oauth-protected-resource" <> Resource.path()

      assert Resource.metadata_path() ==
               "/.well-known/oauth-protected-resource" <> Resource.path()
    end

    test "the site_url setting decides the origin, not the request" do
      put_setting("site_url", "https://Example.COM:443/")

      assert Resource.issuer() == "https://example.com"
      assert Resource.resource() == "https://example.com" <> Routes.path("/mcp/admin")
      assert Resource.matches?("https://EXAMPLE.com" <> Routes.path("/mcp/admin") <> "/")
    end
  end

  describe "normalize/1" do
    test "lowers scheme and host, drops the default port, the trailing slash" do
      assert Resource.normalize("HTTPS://Host.Example:443/mcp/admin/") ==
               {:ok, "https://host.example/mcp/admin"}

      assert Resource.normalize("http://host.example:80/a") == {:ok, "http://host.example/a"}

      assert Resource.normalize("https://host.example:8443/a") ==
               {:ok, "https://host.example:8443/a"}

      assert Resource.normalize("https://host.example") == {:ok, "https://host.example"}
      assert Resource.normalize("https://host.example/") == {:ok, "https://host.example"}
      assert Resource.normalize("https://[::1]:8080/a") == {:ok, "https://[::1]:8080/a"}
    end

    test "keeps the path's case and a query" do
      assert Resource.normalize("https://h.example/MCP/Admin?x=1") ==
               {:ok, "https://h.example/MCP/Admin?x=1"}
    end

    test "refuses what is not an absolute http(s) URL, or has a fragment or userinfo" do
      for bad <- [
            nil,
            1,
            "",
            "mcp/admin",
            "/mcp/admin",
            "ftp://h.example/a",
            "https:///a",
            "https://h.example/a#frag",
            "https://u:p@h.example/a",
            "javascript:alert(1)"
          ] do
        assert Resource.normalize(bad) == :error
      end
    end
  end

  describe "matches?/1" do
    test "is true only for this install's resource, after normalization" do
      own = Resource.resource()
      assert Resource.matches?(own)
      assert Resource.matches?(own <> "/")

      assert Resource.matches?(
               String.upcase(String.slice(own, 0, 8)) <> String.slice(own, 8..-1//1)
             )

      refute Resource.matches?(own <> "/x")
      refute Resource.matches?(own <> "#f")
      refute Resource.matches?("https://other.example" <> Resource.path())
      refute Resource.matches?(Resource.issuer())
      refute Resource.matches?(nil)
    end
  end
end
