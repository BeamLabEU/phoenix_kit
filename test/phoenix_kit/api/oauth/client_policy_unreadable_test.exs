defmodule PhoenixKit.API.OAuth.ClientPolicyUnreadableTest do
  @moduledoc """
  An allow-list that cannot be read refuses the client (fail closed), and a
  pre-registered client is still the administrator's own choice. The Settings store is replaced by
  a repo that raises for the lists, the way `ConfigUnreadableTest` does it.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.OAuth.ClientPolicy

  @claude_id "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @claude_uris ["https://claude.ai/api/mcp/auth_callback"]

  defmodule UnreadableRepo do
    def get_by(_schema, key: key)
        when key == "api_oauth_client_allow_hosts" do
      case Process.get({:read, key}) do
        :missing -> nil
        _ -> raise DBConnection.ConnectionError, message: "database unavailable"
      end
    end

    def get_by(_schema, _clauses), do: nil
  end

  setup do
    previous_repo = Application.get_env(:phoenix_kit, :repo)
    previous_mode = Application.get_env(:phoenix_kit, :update_mode, false)
    start_supervised!(PhoenixKit.Cache.Registry)
    start_supervised!({PhoenixKit.Cache, name: :settings})
    Application.put_env(:phoenix_kit, :repo, UnreadableRepo)
    Application.put_env(:phoenix_kit, :update_mode, false)

    on_exit(fn ->
      Application.put_env(:phoenix_kit, :repo, previous_repo)
      Application.put_env(:phoenix_kit, :update_mode, previous_mode)
    end)

    :ok
  end

  @tag capture_log: true
  test "the default policy does not read the list at all" do
    assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
    assert ClientPolicy.allowed?("dcr", "dcr_x", @claude_uris)
  end

  @tag capture_log: true
  test "an allow-list that cannot be read refuses under the allow-list policy" do
    PhoenixKit.Cache.put(:settings, "api_oauth_client_policy", "allow_list")

    refute ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
  end

  @tag capture_log: true
  test "a pre-registered client does not depend on the lists" do
    assert ClientPolicy.allowed?("preregistered", "pre_x", @claude_uris)
  end
end
