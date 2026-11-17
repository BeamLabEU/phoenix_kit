defmodule PhoenixKit.API.OAuthConfigTest do
  @moduledoc """
  The form of Settings -> API -> OAuth: the numbers (inside the ceilings of the spec), the client
  policy and the list of allowed hosts. All or nothing, only what changed is written, each write
  a permanent `setting.changed` entry.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuthConfig
  alias PhoenixKit.Settings

  setup do
    start_cache_registry!()
    :ok
  end

  defp params(overrides \\ %{}), do: Map.merge(OAuthConfig.current(), overrides)

  defp activity(setting), do: Settings.history(setting)

  describe "current/0" do
    test "shows the defaults of a fresh install as text" do
      current = OAuthConfig.current()

      assert current["access_ttl_seconds"] == "3600"
      assert current["grants_per_person"] == "10"
      assert current["authorize_per_min"] == "30"
      assert current["token_per_min"] == "60"
      assert current["requests_ceiling"] == "1000"
      assert current["cimd_per_min"] == "20"
      assert current["cimd_client_per_min"] == "5"
      assert current["cimd_concurrency"] == "4"
      assert current["register_per_hour"] == "10"
      assert current["register_per_day"] == "200"
      assert current["client_policy"] == "any"
      assert current["allow_hosts"] == ""
    end

    test "has a field for every number of the table and nothing the form does not show" do
      assert Enum.sort(Map.keys(OAuthConfig.current())) ==
               Enum.sort([
                 "client_policy",
                 "allow_hosts" | Enum.map(OAuthConfig.fields(), & &1.field)
               ])
    end
  end

  describe "validate/1" do
    test "accepts the current values" do
      assert {:ok, _} = OAuthConfig.validate(params())
    end

    test "the downloads of metadata documents at once stay between 1 and 64" do
      assert {:ok, _} = OAuthConfig.validate(params(%{"cimd_concurrency" => "1"}))
      assert {:ok, _} = OAuthConfig.validate(params(%{"cimd_concurrency" => "64"}))

      assert {:error, ["cimd_concurrency"]} =
               OAuthConfig.validate(params(%{"cimd_concurrency" => "0"}))

      assert {:error, ["cimd_concurrency"]} =
               OAuthConfig.validate(params(%{"cimd_concurrency" => "65"}))
    end

    test "the access token life stays between 5 minutes and 24 hours" do
      assert {:ok, _} = OAuthConfig.validate(params(%{"access_ttl_seconds" => "300"}))
      assert {:ok, _} = OAuthConfig.validate(params(%{"access_ttl_seconds" => "86400"}))

      assert {:error, ["access_ttl_seconds"]} =
               OAuthConfig.validate(params(%{"access_ttl_seconds" => "299"}))

      assert {:error, ["access_ttl_seconds"]} =
               OAuthConfig.validate(params(%{"access_ttl_seconds" => "86401"}))
    end

    test "a number is whole, in range and not text, and every bad field is named" do
      bad =
        params(%{
          "grants_per_person" => "0",
          "token_per_min" => "1.5",
          "register_per_day" => "x",
          "authorize_per_min" => ""
        })

      assert {:error, fields} = OAuthConfig.validate(bad)

      assert Enum.sort(fields) ==
               ~w(authorize_per_min grants_per_person register_per_day token_per_min)
    end

    test "a missing field is bad, not the default" do
      assert {:error, fields} = OAuthConfig.validate(Map.delete(params(), "token_per_min"))
      assert "token_per_min" in fields
    end

    test "the policy is one of the two values" do
      assert {:ok, _} = OAuthConfig.validate(params(%{"client_policy" => "allow_list"}))

      assert {:error, ["client_policy"]} =
               OAuthConfig.validate(params(%{"client_policy" => "none"}))
    end

    test "the allowed hosts are plain host names, one per line" do
      good = "claude.ai\r\nChatGPT.com\n\n  example.org  "
      assert {:ok, _} = OAuthConfig.validate(params(%{"allow_hosts" => good}))

      for bad <- [
            "https://claude.ai/path",
            "two words",
            "a\0b",
            <<255>>,
            "x" <> String.duplicate("a", 300)
          ] do
        assert {:error, ["allow_hosts"]} = OAuthConfig.validate(params(%{"allow_hosts" => bad})),
               inspect(bad)
      end
    end

    test "the list is not longer than 100 hosts" do
      many = Enum.map_join(1..101, "\n", &"h#{&1}.example")
      assert {:error, ["allow_hosts"]} = OAuthConfig.validate(params(%{"allow_hosts" => many}))
    end

    test "something that is not a map is every field bad" do
      assert {:error, fields} = OAuthConfig.validate(nil)
      assert "access_ttl_seconds" in fields and "client_policy" in fields
    end
  end

  describe "save/2" do
    test "writes only what changed, each as a setting.changed entry" do
      before_ttl = length(activity("api_oauth_access_ttl_seconds"))
      before_token = length(activity("api_oauth_token_per_min"))

      assert {:ok, changed} =
               OAuthConfig.save(
                 params(%{"access_ttl_seconds" => "1800", "client_policy" => "allow_list"}),
                 []
               )

      assert Enum.sort(changed) == ["api_oauth_access_ttl_seconds", "api_oauth_client_policy"]
      assert Config.oauth_access_ttl_seconds() == 1800
      assert Config.oauth_client_policy() == :allow_list
      assert length(activity("api_oauth_access_ttl_seconds")) == before_ttl + 1
      assert length(activity("api_oauth_token_per_min")) == before_token
    end

    test "saves the allowed hosts as the normalized list" do
      {:ok, _} =
        OAuthConfig.save(
          params(%{"allow_hosts" => "claude.ai\r\n\r\nchatgpt.com\nclaude.ai"}),
          []
        )

      assert {:ok, ["claude.ai", "chatgpt.com"]} = Config.fetch_oauth_allow_hosts()
      assert OAuthConfig.current()["allow_hosts"] == "claude.ai\nchatgpt.com"
    end

    test "one bad field saves nothing" do
      assert {:error, ["token_per_min"]} =
               OAuthConfig.save(
                 params(%{"access_ttl_seconds" => "900", "token_per_min" => "0"}),
                 []
               )

      assert Config.oauth_access_ttl_seconds() == 3600
    end

    test "saving the form as it stands changes and logs nothing" do
      assert {:ok, []} = OAuthConfig.save(params(), [])
    end

    test "the history options reach the activity entry" do
      {user, _role} = user_with([])

      {:ok, _} =
        OAuthConfig.save(params(%{"grants_per_person" => "5"}),
          actor_uuid: user.uuid,
          source: "settings"
        )

      assert [entry | _] = activity("api_oauth_grants_per_person")
      assert entry.actor_uuid == user.uuid
    end
  end
end
