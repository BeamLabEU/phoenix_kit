defmodule PhoenixKit.API.OAuth.ClientPolicyTest do
  @moduledoc """
  Which clients may use the server: any https client (the default) or only the hosts of an
  allow-list, and never the hosts of the deny-list.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.ClientPolicy

  @claude_id "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @claude_uris ["https://claude.ai/api/mcp/auth_callback"]

  setup do
    setup_api()
  end

  describe "the default policy" do
    test "any https client is allowed" do
      assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
      assert ClientPolicy.allowed?("dcr", "dcr_x", ["https://anything.example/cb"])
      assert ClientPolicy.allowed?("dcr", "dcr_x", ["http://127.0.0.1:8080/cb"])
    end
  end

  describe "the deny-list" do
    test "refuses a client whose id host or redirect host is listed, in any case" do
      put_setting("api_oauth_client_deny_hosts", "Evil.Example\nother.example")

      refute ClientPolicy.allowed?("cimd", "https://evil.example/c.json", @claude_uris)
      refute ClientPolicy.allowed?("cimd", @claude_id, ["https://EVIL.example/cb"])
      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://other.example/cb"])
      assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
    end

    test "an entry written as a URL counts as its host" do
      put_setting("api_oauth_client_deny_hosts", "https://evil.example/path")
      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://evil.example/cb"])
    end

    test "a trailing dot (the same name to the resolver) does not get around an entry" do
      put_setting("api_oauth_client_deny_hosts", "evil.example")

      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://evil.example./cb"])
      refute ClientPolicy.allowed?("cimd", "https://EVIL.example./c.json", @claude_uris)

      put_setting("api_oauth_client_deny_hosts", "evil.example.")
      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://evil.example/cb"])
    end

    test "an IPv6 entry written in brackets, with or without a port, counts as its address" do
      for entry <- ["[2001:db8::1]", "[2001:DB8::1]:8443", "https://[2001:db8::1]"] do
        put_setting("api_oauth_client_deny_hosts", entry)
        refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://[2001:db8::1]/cb"]), entry
      end
    end

    test "an entry written with a port counts as its host" do
      put_setting("api_oauth_client_deny_hosts", "evil.example:8443")
      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://evil.example/cb"])
    end

    test "holds under the allow-list policy too" do
      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "claude.ai")
      put_setting("api_oauth_client_deny_hosts", "claude.ai")

      refute ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
    end
  end

  describe "the allow-list policy" do
    setup do
      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "claude.ai\nchatgpt.com")
    end

    test "allows a client when every host involved is listed" do
      assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)

      assert ClientPolicy.allowed?(
               "cimd",
               "https://chatgpt.com/oauth/client.json",
               ["https://chatgpt.com/connector_platform_oauth_redirect"]
             )
    end

    test "refuses a client that has even one host outside the list" do
      refute ClientPolicy.allowed?("cimd", @claude_id, ["https://elsewhere.example/cb"])
      refute ClientPolicy.allowed?("cimd", "https://elsewhere.example/c.json", @claude_uris)

      refute ClientPolicy.allowed?(
               "dcr",
               "dcr_x",
               @claude_uris ++ ["https://elsewhere.example/cb"]
             )
    end

    test "a registered client is judged by its redirect hosts only" do
      assert ClientPolicy.allowed?("dcr", "dcr_x", @claude_uris)
      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://elsewhere.example/cb"])
    end

    test "an empty list allows nobody, an unknown policy value reads as the allow-list" do
      put_setting("api_oauth_client_allow_hosts", "")
      refute ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)

      put_setting("api_oauth_client_policy", "banana")
      refute ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
    end

    test "a pre-registered client is the administrator's own choice and is exempt from the list" do
      assert ClientPolicy.allowed?("preregistered", "https://elsewhere.example/c", [
               "https://elsewhere.example/cb"
             ])
    end
  end
end
