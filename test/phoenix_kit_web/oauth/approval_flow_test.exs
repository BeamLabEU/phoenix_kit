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

  alias PhoenixKit.Activity
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
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

  describe "the screens" do
    defp page(conn), do: conn.resp_body |> Floki.parse_document!()

    test "the consent screen of a client outside the list warns that the owner must approve",
         %{user: user, app: app} do
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()

      html = user |> browser() |> consent(id) |> page()

      assert [warning] = Floki.find(html, "#consent-needs-approval")
      assert Floki.text(warning) =~ "approves it"
      assert [_form] = Floki.find(html, "#consent-form")
    end

    test "the consent screen of a client that works at once has no such paragraph", %{
      user: user,
      app: app
    } do
      put_setting("api_oauth_client_allow_hosts", "app.example")
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()

      assert user |> browser() |> consent(id) |> page() |> Floki.find("#consent-needs-approval") ==
               []
    end

    test "the page of the ceiling marks the connection that waits, and not the approved one", %{
      user: user,
      app: app
    } do
      put_setting("api_oauth_grants_per_person", "2")
      connect!(user, app)
      connect!(user, client!())
      assert Repo.aggregate(Grant, :count) == 2

      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()
      html = user |> browser() |> consent(id) |> page()

      assert [_table] = Floki.find(html, "#grants-table")
      waiting = Repo.get_by!(Grant, client_uuid: app.uuid)
      working = Repo.get_by!(Grant, client_uuid: Repo.get_by!(Client, kind: "preregistered").uuid)

      assert [_mark] = Floki.find(html, "#grant-waiting-#{waiting.uuid}")
      assert Floki.find(html, "#grant-waiting-#{working.uuid}") == []
    end
  end

  describe "the whole way of an application outside the list" do
    test "consent with the warning, tokens, a list of tools, a refused call, the approval, a read",
         %{user: user, app: app} do
      # The screen warns before the person decides.
      {verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()

      assert [_] =
               user |> browser() |> consent(id) |> page() |> Floki.find("#consent-needs-approval")

      # The person allows reading and writing; the code and the tokens are as for any client.
      answer =
        decide(browser(user), id, %{
          "decision" => "allow",
          "scopes" => [@read, @write],
          "days" => "30"
        })

      assert answer.status == 302
      %{"code" => code} = location_params(answer)

      flow = %{code: code, verifier: verifier, client: app, redirect_uri: hd(app.redirect_uris)}
      exchange = exchange_code(flow)
      assert exchange.status == 200
      %{"access_token" => access} = body(exchange)

      waiting = grant!()
      assert waiting.approved_at == nil
      assert [pending] = Activity.list(action: "oauth.grant_pending").entries
      assert pending.resource_uuid == waiting.uuid

      # The application starts its session and sees the tools.
      assert mcp_initialize(access).status == 200
      listed = tools_list(access)
      assert listed.status == 200
      assert tool_names(listed) != []

      # A call is refused, whatever it asks, and nothing ran.
      write = tools_call(access, "testkit.write_item", %{"name" => "x"})
      assert tool_error(write) =~ "[approval_pending]"
      assert tool_error(tools_call(access, "testkit.read_items")) =~ "approval_pending"
      refute_received {:write_item, _}
      refute_received {:read_items, _, _}

      # An Owner approves it, and the very same access token runs a read.
      owner = KeyTestSupport.scope_of(KeyTestSupport.owner_user())

      assert {:ok, %Grant{approved_at: %DateTime{}}} =
               Grants.approve(owner, waiting.uuid, impersonated: false)

      assert [approved] = Activity.list(action: "oauth.grant_approved").entries
      assert approved.resource_uuid == waiting.uuid

      read = tools_call(access, "testkit.read_items")
      assert read.status == 200
      refute body(read)["result"]["isError"]
      assert_received {:read_items, _, _}
    end
  end
end
