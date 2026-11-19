defmodule PhoenixKit.API.OAuth.ClientPolicyTest do
  @moduledoc """
  Which clients may use the server and how they are judged: any https client (`any`), only the
  hosts of an allow-list (`allow_list`), or the listed hosts at once and every other client after
  an owner's approval (`approval`, the default).
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.ClientPolicy
  alias PhoenixKit.Settings

  @claude_id "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @claude_uris ["https://claude.ai/api/mcp/auth_callback"]

  setup do
    setup_api()
  end

  describe "the policy `any`" do
    setup do
      put_setting("api_oauth_client_policy", "any")
    end

    test "any https client is allowed" do
      assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
      assert ClientPolicy.allowed?("dcr", "dcr_x", ["https://anything.example/cb"])
      assert ClientPolicy.allowed?("dcr", "dcr_x", ["http://127.0.0.1:8080/cb"])
    end

    test "every client is trusted, listed or not" do
      assert ClientPolicy.judge("cimd", @claude_id, @claude_uris) == :trusted
      assert ClientPolicy.judge("dcr", "dcr_x", ["https://anything.example/cb"]) == :trusted

      put_setting("api_oauth_client_allow_hosts", "chatgpt.com")
      assert ClientPolicy.judge("dcr", "dcr_x", ["https://anything.example/cb"]) == :trusted
    end
  end

  describe "the default policy" do
    @describetag :capture_log

    test "a setting that is not there is `approval`" do
      {:ok, _} = Settings.delete_setting("api_oauth_client_policy")
      assert Config.oauth_client_policy() == :approval
    end

    test "an empty list under it asks for approval for every client" do
      {:ok, _} = Settings.delete_setting("api_oauth_client_policy")

      assert ClientPolicy.judge("cimd", @claude_id, @claude_uris) == :needs_approval

      assert ClientPolicy.judge("dcr", "dcr_x", ["https://anything.example/cb"]) ==
               :needs_approval

      assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
    end
  end

  describe "the policy `approval`" do
    setup do
      put_setting("api_oauth_client_policy", "approval")
      put_setting("api_oauth_client_allow_hosts", "claude.ai\nchatgpt.com")
    end

    test "a client whose every host is listed is trusted" do
      assert ClientPolicy.judge("cimd", @claude_id, @claude_uris) == :trusted
      assert ClientPolicy.judge("dcr", "dcr_x", @claude_uris) == :trusted
    end

    test "a client with a host outside the list waits for approval, and is still allowed in" do
      uris = ["https://elsewhere.example/cb"]

      assert ClientPolicy.judge("cimd", @claude_id, uris) == :needs_approval

      assert ClientPolicy.judge("cimd", "https://elsewhere.example/c.json", @claude_uris) ==
               :needs_approval

      assert ClientPolicy.judge("dcr", "dcr_x", @claude_uris ++ uris) == :needs_approval
      assert ClientPolicy.allowed?("dcr", "dcr_x", uris)
    end

    test "a client with no host at all waits for approval" do
      assert ClientPolicy.judge("dcr", "dcr_x", []) == :needs_approval
    end

    test "a pre-registered client is trusted whatever the list says" do
      assert ClientPolicy.judge("preregistered", "https://elsewhere.example/c", [
               "https://elsewhere.example/cb"
             ]) == :trusted
    end

    test "an unknown policy value is the allow-list, never an approval" do
      put_setting("api_oauth_client_policy", "banana")

      assert ClientPolicy.judge("cimd", @claude_id, @claude_uris) == :trusted
      assert ClientPolicy.judge("cimd", @claude_id, ["https://elsewhere.example/cb"]) == :refused
    end
  end

  describe "how an allow-list entry is read" do
    setup do
      put_setting("api_oauth_client_policy", "allow_list")
    end

    test "in any case" do
      put_setting("api_oauth_client_allow_hosts", "Claude.AI")

      assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
      assert ClientPolicy.allowed?("cimd", "https://CLAUDE.ai/c.json", ["https://Claude.ai/cb"])
    end

    test "an entry written as a URL counts as its host" do
      put_setting("api_oauth_client_allow_hosts", "https://claude.ai/path")
      assert ClientPolicy.allowed?("dcr", "dcr_x", @claude_uris)
    end

    test "a trailing dot (the same name to the resolver) is no other host, on either side" do
      put_setting("api_oauth_client_allow_hosts", "claude.ai")

      assert ClientPolicy.allowed?("dcr", "dcr_x", ["https://claude.ai./cb"])
      assert ClientPolicy.allowed?("cimd", "https://CLAUDE.ai./c.json", @claude_uris)

      put_setting("api_oauth_client_allow_hosts", "claude.ai.")
      assert ClientPolicy.allowed?("dcr", "dcr_x", @claude_uris)
    end

    test "an IPv6 entry written in brackets, with or without a port, counts as its address" do
      for entry <- ["[2001:db8::1]", "[2001:DB8::1]:8443", "https://[2001:db8::1]"] do
        put_setting("api_oauth_client_allow_hosts", entry)
        assert ClientPolicy.allowed?("dcr", "dcr_x", ["https://[2001:db8::1]/cb"]), entry
        refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://[2001:db8::2]/cb"]), entry
      end
    end

    test "an entry written with a port counts as its host" do
      put_setting("api_oauth_client_allow_hosts", "claude.ai:8443")
      assert ClientPolicy.allowed?("dcr", "dcr_x", @claude_uris)
    end

    test "a host that merely ends with an entry is not the entry" do
      put_setting("api_oauth_client_allow_hosts", "claude.ai")

      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://evilclaude.ai/cb"])
      refute ClientPolicy.allowed?("dcr", "dcr_x", ["https://claude.ai.evil.example/cb"])
    end
  end

  describe "there is no deny-list" do
    test "a setting of that old name changes nothing" do
      put_setting("api_oauth_client_policy", "any")
      put_setting("api_oauth_client_deny_hosts", "claude.ai")
      assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
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

    test "judge: listed is trusted, anything else is refused, never waiting" do
      assert ClientPolicy.judge("cimd", @claude_id, @claude_uris) == :trusted

      assert ClientPolicy.judge("cimd", @claude_id, ["https://elsewhere.example/cb"]) ==
               :refused

      assert ClientPolicy.judge("dcr", "dcr_x", []) == :refused
    end
  end
end
