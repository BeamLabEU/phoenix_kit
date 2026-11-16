defmodule PhoenixKitWeb.OAuth.ClientPolicyFlowTest do
  @moduledoc """
  The client allow-list is judged at every step a client takes, not only when its authorization
  request arrives: the consent screen and its answer, the exchange of the code and the refresh
  token. A client that stops being allowed cannot be connected and cannot keep a connection alive
  through refreshes; a pre-registered client is the administrator's own choice and is never
  judged.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Floki, only: [find: 2, parse_document!: 1]
  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.Test.Repo

  @read "testkit.items:read"

  setup do
    setup_api()
    enable_oauth!()
    {user, _role} = holder(["dashboard"])
    {_verifier, challenge} = pkce()

    app =
      Repo.insert!(%Client{
        kind: "dcr",
        client_id: "dcr_policy_#{System.unique_integer([:positive])}",
        redirect_uris: ["https://app.example/cb"]
      })

    %{user: user, challenge: challenge, app: app}
  end

  # Only the hosts of the list may be used: the client's host is not in it.
  defp exclude!(host \\ "other.example") do
    put_setting("api_oauth_client_policy", "allow_list")
    put_setting("api_oauth_client_allow_hosts", host)
  end

  defp allow_all!, do: put_setting("api_oauth_client_policy", "any")

  defp allow_form, do: %{"decision" => "allow", "scopes" => [@read], "days" => "30"}

  describe "the consent screen" do
    test "a client that is no longer allowed gets no screen and no grant", %{
      user: user,
      challenge: challenge,
      app: app
    } do
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()
      exclude!()

      page = consent(browser(user), id)
      assert page.status == 400
      assert [] = page.resp_body |> parse_document!() |> find("#consent-form")

      answer = decide(browser(user), id, allow_form())
      assert answer.status == 400
      assert get_resp_header(answer, "location") == []
      assert Repo.all(Grant) == []
      assert Repo.all(Code) == []
    end

    test "the request waits: allowed again, the same screen and answer work", %{
      user: user,
      challenge: challenge,
      app: app
    } do
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()
      exclude!()
      assert decide(browser(user), id, allow_form()).status == 400

      allow_all!()
      assert consent(browser(user), id).status == 200
      assert decide(browser(user), id, allow_form()).status == 302
      assert [%Grant{}] = Repo.all(Grant)
    end

    test "saying no is always possible", %{
      user: user,
      challenge: challenge,
      app: app
    } do
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()
      exclude!()

      conn = decide(browser(user), id, %{"decision" => "deny"})
      assert conn.status == 302
      assert %{"error" => "access_denied"} = location_params(conn)
      assert [%Request{consumed_at: %DateTime{}}] = Repo.all(Request)
    end

    test "a pre-registered client is not judged", %{user: user, challenge: challenge} do
      client = client!()
      id = browser() |> authorize(authorize_params(client, challenge)) |> consent_id()
      exclude!()

      assert consent(browser(user), id).status == 200
      assert decide(browser(user), id, allow_form()).status == 302
    end
  end

  describe "the code" do
    test "is not exchanged for a client that is no longer allowed", %{
      user: user,
      app: app
    } do
      flow = code_for(user, app, [@read])
      exclude!()

      conn = exchange_code(flow)
      assert conn.status == 400
      assert body(conn)["error"] == "invalid_client"
      assert [%Grant{activated_at: nil}] = Repo.all(Grant)

      # Refused before the code was touched: allowed again, it still works.
      allow_all!()
      assert exchange_code(flow).status == 200
    end
  end

  describe "the refresh token" do
    test "is not exchanged for a client that is no longer allowed, and works again when it is",
         %{user: user, app: app} do
      flow = code_for(user, app, [@read])

      %{"refresh_token" => refresh_token, "access_token" => access} =
        flow |> exchange_code() |> body()

      exclude!()

      conn = refresh(app, refresh_token)
      assert conn.status == 400
      assert body(conn)["error"] == "invalid_client"
      assert [%Grant{revoked_at: nil}] = Repo.all(Grant)

      allow_all!()
      assert %{"access_token" => new_access} = app |> refresh(refresh_token) |> body()
      assert new_access != access
    end

    test "a pre-registered client keeps refreshing under any list", %{user: user} do
      client = client!()
      flow = code_for(user, client, [@read])
      %{"refresh_token" => refresh_token} = flow |> exchange_code() |> body()
      exclude!()

      assert refresh(client, refresh_token).status == 200
    end
  end
end
