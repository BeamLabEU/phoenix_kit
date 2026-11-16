defmodule PhoenixKitWeb.OAuth.FlowTest do
  @moduledoc """
  The whole authorization code flow of a pre-registered client through the real endpoint:
  authorize, the login redirect, consent, the code, the token endpoint, the MCP endpoint with the
  access token, refresh, rotation and the replay of an old refresh token.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [setup_api: 0]

  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.Test.Repo

  @read "testkit.items:read"
  @write "testkit.items:write"

  setup do
    setup_api()
    enable_oauth!()
    {user, role} = holder(["dashboard", "settings"])
    %{user: user, role: role, client: client!()}
  end

  describe "the whole flow" do
    test "authorize, consent, token, MCP, refresh, rotation, replay", %{
      user: user,
      client: client
    } do
      {verifier, challenge} = pkce()
      params = authorize_params(client, challenge, %{"scope" => nil})

      # Authorize: no login needed, a short consent URL comes back.
      conn = authorize(browser(), params)
      assert conn.status == 302
      assert location(conn) =~ ~r|/oauth/consent/[A-Za-z0-9_-]{43}\z|
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      id = consent_id(conn)

      # The consent page: reading is on, writing is off.
      page = consent(browser(user), id)
      assert page.status == 200
      html = Floki.parse_document!(page.resp_body)
      assert [_] = Floki.find(html, "#consent-form")
      assert [_] = Floki.find(html, ~s(input[name="scopes[]"][value="#{@read}"][checked]))
      assert [_] = Floki.find(html, ~s(input[name="scopes[]"][value="#{@write}"]))
      assert [] = Floki.find(html, ~s(input[name="scopes[]"][value="#{@write}"][checked]))
      assert [_] = Floki.find(html, "#consent-host")

      # Allow the reading scope: the browser goes back to the client with code, state and iss.
      answer =
        decide(browser(user), id, %{"decision" => "allow", "scopes" => [@read], "days" => "30"})

      assert answer.status == 302
      assert String.starts_with?(location(answer), hd(client.redirect_uris) <> "?")
      %{"code" => code, "state" => state, "iss" => iss} = location_params(answer)
      assert state == params["state"]
      assert iss == Resource.issuer()

      # The code buys a pair of tokens.
      flow = %{
        code: code,
        verifier: verifier,
        client: client,
        redirect_uri: params["redirect_uri"]
      }

      tokens = exchange_code(flow)
      assert tokens.status == 200
      assert get_resp_header(tokens, "cache-control") == ["no-store"]
      assert get_resp_header(tokens, "pragma") == ["no-cache"]

      assert %{
               "access_token" => "pkoa_" <> _ = access,
               "refresh_token" => "pkor_" <> _ = refresh1,
               "token_type" => "Bearer",
               "expires_in" => expires_in,
               "scope" => @read
             } = body(tokens)

      assert expires_in in 3500..3600

      # The access token works on the MCP endpoint, with the granted scope only.
      listed = tools_list(access)
      assert listed.status == 200
      assert "testkit_read_items" in tool_names(listed)
      refute "testkit_write_item" in tool_names(listed)

      # Refresh: a new pair; the old refresh token is spent.
      second = refresh(client, refresh1)
      assert second.status == 200
      assert %{"access_token" => access2, "refresh_token" => refresh2} = body(second)
      assert refresh2 != refresh1
      assert tools_list(access2).status == 200

      # R2 is used: R3 exists.
      third = refresh(client, refresh2)
      assert third.status == 200
      assert %{"access_token" => access3, "refresh_token" => refresh3} = body(third)

      # The old refresh token comes back although its successor was used: theft. The grant ends.
      replay = refresh(client, refresh1)
      assert replay.status == 400
      assert %{"error" => "invalid_grant"} = body(replay)
      assert tools_list(access3).status == 401
      assert %{"error" => "invalid_grant"} = refresh(client, refresh3) |> body()
      assert [%Grant{revoked_at: %DateTime{}}] = Repo.all(Grant)
    end

    test "the grant of an allowed request is the grant of the scope the person chose", %{
      user: user,
      client: client
    } do
      flow = code_for(user, client, [@read, @write])
      assert %{"scope" => scope} = flow |> exchange_code() |> body()
      assert scope |> String.split(" ") |> Enum.sort() == [@read, @write]
    end
  end

  describe "sign-in" do
    test "an anonymous visitor on the consent URL is sent to the sign-in and brought back", %{
      client: client
    } do
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(client, challenge)) |> consent_id()

      conn = consent(browser(), id)
      assert redirected_to(conn, 302) =~ "/users/log-in"
      assert get_session(conn, :user_return_to) == path("/consent/" <> id)
    end

    test "the consent POST of an anonymous visitor goes to the sign-in too", %{client: client} do
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(client, challenge)) |> consent_id()

      conn = decide(browser(), id, %{"decision" => "allow", "scopes" => [@read]})
      assert redirected_to(conn, 302) =~ "/users/log-in"
    end

    test "a magic link opened in another browser finds no session: the page says start again", %{
      user: user
    } do
      # The id lives in the first browser's session only; a second browser has no request.
      conn = consent(browser(user), String.duplicate("A", 43))
      assert conn.status == 400
      assert [_] = conn.resp_body |> Floki.parse_document!() |> Floki.find("h1")
    end
  end

  describe "the scope of a request" do
    test "a client that names its scope gets it preselected, and only it offered", %{
      user: user,
      client: client
    } do
      {_verifier, challenge} = pkce()
      params = authorize_params(client, challenge, %{"scope" => @write <> " unknown.thing:read"})
      id = browser() |> authorize(params) |> consent_id()

      html =
        id
        |> then(&consent(browser(user), &1))
        |> Map.fetch!(:resp_body)
        |> Floki.parse_document!()

      assert [_] = Floki.find(html, ~s(input[name="scopes[]"][value="#{@write}"][checked]))
      assert [] = Floki.find(html, ~s(input[name="scopes[]"][value="#{@read}"]))
    end

    test "a scope outside what was offered is dropped; with nothing left the screen asks again",
         %{
           user: user,
           client: client
         } do
      {_verifier, challenge} = pkce()
      id = browser() |> authorize(authorize_params(client, challenge)) |> consent_id()

      conn =
        decide(browser(user), id, %{"decision" => "allow", "scopes" => ["forged.thing:write"]})

      assert conn.status == 422
      assert [_] = conn.resp_body |> Floki.parse_document!() |> Floki.find("#consent-error")
      # The request is still usable.
      assert consent(browser(user), id).status == 200
    end
  end

  describe "deny" do
    test "access_denied goes to the client with state and iss, and the request is used up", %{
      user: user,
      client: client
    } do
      {_verifier, challenge} = pkce()
      params = authorize_params(client, challenge)
      id = browser() |> authorize(params) |> consent_id()

      conn = decide(browser(user), id, %{"decision" => "deny"})
      assert %{"error" => "access_denied", "state" => state, "iss" => iss} = location_params(conn)
      assert state == params["state"]
      assert iss == Resource.issuer()
      assert Repo.all(Grant) == []

      assert consent(browser(user), id).status == 400
    end
  end

  describe "refresh" do
    setup %{user: user, client: client} do
      flow = code_for(user, client, [@read])
      tokens = flow |> exchange_code() |> body()
      %{tokens: tokens}
    end

    test "a retry inside the window gets a fresh pair and ends the unused successor", %{
      client: client,
      tokens: tokens
    } do
      %{"refresh_token" => r1} = tokens
      assert %{"refresh_token" => r2, "access_token" => a2} = client |> refresh(r1) |> body()

      # R1 comes again, R2 untouched, a moment later: a network retry.
      retry = refresh(client, r1)
      assert retry.status == 200
      assert %{"refresh_token" => r3, "access_token" => a3} = body(retry)

      assert tools_list(a2).status == 401
      assert tools_list(a3).status == 200
      # R2 was handed out by the retry's predecessor and then superseded: it ends the grant.
      assert refresh(client, r2).status == 400
      assert tools_list(a3).status == 401
      assert refresh(client, r3).status == 400
    end

    test "a repeat of R1 after the window ends the grant", %{client: client, tokens: tokens} do
      %{"refresh_token" => r1} = tokens
      assert %{"access_token" => a2} = client |> refresh(r1) |> body()

      Repo.update_all(Token, set: [used_at: DateTime.add(DateTime.utc_now(), -30, :second)])
      # `used_at` of R1 only matters: the others are unused (nil) and stay so.
      assert refresh(client, r1).status == 400
      assert tools_list(a2).status == 401
    end

    test "another client cannot use the refresh token", %{tokens: tokens} do
      other = client!()
      assert %{"error" => "invalid_grant"} = other |> refresh(tokens["refresh_token"]) |> body()
    end

    test "a request cannot widen the scope; the response says what the grant holds", %{
      client: client,
      tokens: tokens
    } do
      wider = refresh(client, tokens["refresh_token"], %{"scope" => @read <> " " <> @write})
      assert wider.status == 400
      assert %{"error" => "invalid_scope"} = body(wider)

      same = refresh(client, tokens["refresh_token"], %{"scope" => @read})
      assert same.status == 200
      assert %{"scope" => @read} = body(same)
    end

    test "a foreign resource is invalid_target", %{client: client, tokens: tokens} do
      conn =
        refresh(client, tokens["refresh_token"], %{"resource" => "https://elsewhere.example/mcp"})

      assert %{"error" => "invalid_target"} = body(conn)
    end
  end

  describe "revoke" do
    test "ends the grant whatever token names it, and always says 200", %{
      user: user,
      client: client
    } do
      flow = code_for(user, client, [@read])
      tokens = flow |> exchange_code() |> body()

      assert revoke(%{"token" => tokens["refresh_token"], "client_id" => client.client_id}).status ==
               200

      assert tools_list(tokens["access_token"]).status == 401
      assert revoke(%{"token" => "pkor_unknown"}).status == 200
      assert revoke(%{}).status == 200
    end

    test "another client's id leaves the grant alone", %{user: user, client: client} do
      tokens = user |> code_for(client, [@read]) |> exchange_code() |> body()
      other = client!()

      assert revoke(%{"token" => tokens["access_token"], "client_id" => other.client_id}).status ==
               200

      assert tools_list(tokens["access_token"]).status == 200
    end
  end
end
