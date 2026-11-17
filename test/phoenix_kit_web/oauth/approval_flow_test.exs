defmodule PhoenixKitWeb.OAuth.ApprovalFlowTest do
  @moduledoc """
  The policy `approval` through the real endpoint, from the authorization request to a tool call:
  a client of a listed host works at once, a pre-registered client too, and any other client signs
  in, consents and gets its tokens as usual but runs nothing until its connection is approved;
  the answer the agent gets tells it what to do, and the same access token works the moment the
  approval is recorded.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.Test.Repo

  @read "testkit.items:read"
  @write "testkit.items:write"

  setup do
    setup_api()
    enable_oauth!()
    put_setting("api_oauth_client_policy", "approval")
    {user, _role} = holder(["dashboard", "settings"])

    app =
      Repo.insert!(%Client{
        kind: "dcr",
        client_id: "dcr_approval_#{System.unique_integer([:positive])}",
        redirect_uris: ["https://app.example/cb"]
      })

    %{user: user, app: app}
  end

  defp connect!(user, client) do
    flow = code_for(user, client, [@read, @write])
    answer = exchange_code(flow)
    assert answer.status == 200
    %{flow: flow, tokens: body(answer)}
  end

  defp grant!, do: Repo.one!(Grant)

  defp approve!(grant) do
    {1, _} =
      Repo.update_all(from(g in Grant, where: g.uuid == ^grant.uuid),
        set: [approved_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )
  end

  defp tool_error(conn) do
    assert conn.status == 200
    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text} | _]}} = body(conn)
    text
  end

  describe "a client outside the list" do
    test "signs in and consents as usual, and its tokens are as usual", %{user: user, app: app} do
      %{tokens: tokens} = connect!(user, app)

      assert tokens |> Map.keys() |> Enum.sort() ==
               ~w(access_token expires_in refresh_token scope token_type)

      assert String.starts_with?(tokens["access_token"], "pkoa_")
      assert grant!().approved_at == nil
      assert grant!().activated_at != nil
    end

    test "sees the tool list but runs nothing, and is told what to do", %{user: user, app: app} do
      %{tokens: %{"access_token" => access}} = connect!(user, app)

      listed = tools_list(access)
      assert listed.status == 200
      assert "testkit_read_items" in tool_names(listed)
      assert "testkit_write_item" in tool_names(listed)

      for {name, args} <- [
            {"testkit.read_items", %{}},
            {"testkit.write_item", %{"name" => "x"}},
            {"testkit.nothing_like_it", %{}}
          ] do
        text = access |> tools_call(name, args) |> tool_error()

        assert text =~ "[approval_pending]", name
        assert text =~ "waiting for approval by an Owner of this site", name
      end

      refute_received {:read_items, _, _}
      refute_received {:write_item, _}
    end

    test "works with the very same access token once it is approved", %{user: user, app: app} do
      %{tokens: %{"access_token" => access}} = connect!(user, app)

      assert access |> tools_call("testkit.read_items") |> tool_error() =~ "approval_pending"

      approve!(grant!())

      ok = tools_call(access, "testkit.read_items")
      assert ok.status == 200
      refute body(ok)["result"]["isError"]
      assert_received {:read_items, _, _}
    end

    test "refreshes while it waits, and the new token waits too", %{user: user, app: app} do
      %{tokens: %{"refresh_token" => refresh_token}} = connect!(user, app)

      refreshed = refresh(app, refresh_token)
      assert refreshed.status == 200
      %{"access_token" => access} = body(refreshed)

      assert access |> tools_call("testkit.read_items") |> tool_error() =~ "approval_pending"
    end

    test "is not cut off by a refresh when its host is not on the list (unlike allow_list)", %{
      user: user,
      app: app
    } do
      put_setting("api_oauth_client_allow_hosts", "claude.ai")
      %{tokens: %{"refresh_token" => refresh_token}} = connect!(user, app)

      first = refresh(app, refresh_token)
      assert first.status == 200
      %{"refresh_token" => second_token} = body(first)

      # The same install under the strict policy cuts the client off at the next refresh.
      put_setting("api_oauth_client_policy", "allow_list")
      assert refresh(app, second_token).status == 400
    end
  end

  describe "a client that works at once" do
    test "of a listed host is approved when it consents", %{user: user, app: app} do
      put_setting("api_oauth_client_allow_hosts", "app.example")
      %{tokens: %{"access_token" => access}} = connect!(user, app)

      assert %Grant{approved_at: %DateTime{}} = grant!()

      ok = tools_call(access, "testkit.write_item", %{"name" => "x"})
      refute body(ok)["result"]["isError"]
      assert_received {:write_item, _}
    end

    test "pre-registered by an administrator needs no list", %{user: user} do
      %{tokens: %{"access_token" => access}} = connect!(user, client!())

      assert %Grant{approved_at: %DateTime{}} = grant!()
      refute body(tools_call(access, "testkit.read_items"))["result"]["isError"]
    end

    test "under the policy any, whatever its host", %{user: user, app: app} do
      put_setting("api_oauth_client_policy", "any")
      %{tokens: %{"access_token" => access}} = connect!(user, app)

      assert %Grant{approved_at: %DateTime{}} = grant!()
      refute body(tools_call(access, "testkit.read_items"))["result"]["isError"]
    end
  end

  describe "the verdict is the one of the consent, on the request as it was shown" do
    test "a host listed after the request was made is trusted at the consent", %{
      user: user,
      app: app
    } do
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()

      put_setting("api_oauth_client_allow_hosts", "app.example")

      answer =
        decide(browser(user), id, %{"decision" => "allow", "scopes" => [@read], "days" => "30"})

      assert answer.status == 302
      assert %Grant{approved_at: %DateTime{}} = grant!()
    end

    test "a policy tightened to approval after the request was made waits", %{
      user: user,
      app: app
    } do
      put_setting("api_oauth_client_policy", "any")
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()

      put_setting("api_oauth_client_policy", "approval")

      answer =
        decide(browser(user), id, %{"decision" => "allow", "scopes" => [@read], "days" => "30"})

      assert answer.status == 302
      assert %Grant{approved_at: nil} = grant!()
    end

    test "the allow-list still refuses at the consent", %{user: user, app: app} do
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()

      put_setting("api_oauth_client_policy", "allow_list")

      answer =
        decide(browser(user), id, %{"decision" => "allow", "scopes" => [@read], "days" => "30"})

      assert answer.status == 400
      assert Repo.all(Grant) == []
    end
  end
end
