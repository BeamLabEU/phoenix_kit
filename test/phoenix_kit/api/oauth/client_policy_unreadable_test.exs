defmodule PhoenixKit.API.OAuth.ClientPolicyUnreadableTest do
  @moduledoc """
  A policy value or an allow-list that cannot be read refuses the client (fail closed), and a
  pre-registered client is still the administrator's own choice. The Settings store is replaced by
  a repo that raises for the lists, the way `ConfigUnreadableTest` does it.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.ClientPolicy

  @claude_id "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @claude_uris ["https://claude.ai/api/mcp/auth_callback"]

  defmodule UnreadableRepo do
    def get_by(_schema, key: key)
        when key in ["api_oauth_client_allow_hosts", "api_oauth_client_policy"] do
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
    # The Settings store only queries a repo whose process is running: register one under the
    # name of the module, so that the read fails by raising and not by "no repo".
    start_supervised!(%{
      id: UnreadableRepo,
      start: {Agent, :start_link, [fn -> nil end, [name: UnreadableRepo]]}
    })

    Application.put_env(:phoenix_kit, :repo, UnreadableRepo)
    Application.put_env(:phoenix_kit, :update_mode, false)

    on_exit(fn ->
      Application.put_env(:phoenix_kit, :repo, previous_repo)
      Application.put_env(:phoenix_kit, :update_mode, previous_mode)
    end)

    :ok
  end

  @tag capture_log: true
  test "a policy value that cannot be read is the allow-list policy, and the client is refused" do
    assert Config.oauth_client_policy() == :allow_list

    refute ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
    refute ClientPolicy.allowed?("dcr", "dcr_x", @claude_uris)
    refute ClientPolicy.allowed?("cimd", "https://evil.example/c", ["https://evil.example/cb"])
  end

  @tag capture_log: true
  test "a policy that is not set at all stays the default policy" do
    Process.put({:read, "api_oauth_client_policy"}, :missing)

    assert Config.oauth_client_policy() == :any
    assert ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
    assert ClientPolicy.allowed?("dcr", "dcr_x", @claude_uris)
  end

  @tag capture_log: true
  test "an allow-list that cannot be read refuses under a readable allow-list policy" do
    PhoenixKit.Cache.put(:settings, "api_oauth_client_policy", "allow_list")

    refute ClientPolicy.allowed?("cimd", @claude_id, @claude_uris)
  end

  @tag capture_log: true
  test "a pre-registered client does not depend on the lists" do
    assert ClientPolicy.allowed?("preregistered", "pre_x", @claude_uris)
  end
end
