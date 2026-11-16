defmodule PhoenixKitWeb.OAuth.ConsentTest do
  @moduledoc """
  The consent screen through the real endpoint: who may use it, what a forged or replayed answer
  does, the headers of the page (the host's CSP is kept, `frame-ancestors` is replaced), the CSRF
  check, the ceiling of connections and its "disconnect" flow, the account gate and the website
  gate.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport

  import PhoenixKit.API.OAuthTestSupport,
    only: [client!: 0, client!: 1, enable_oauth!: 0, pkce: 0]

  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.OAuth.Responses

  @read "testkit.items:read"

  setup do
    setup_api()
    enable_oauth!()
    {user, role} = holder(["dashboard", "settings"])
    {_verifier, challenge} = pkce()
    %{user: user, role: role, client: client!(), challenge: challenge}
  end

  defp request_id(client, challenge, overrides \\ %{}),
    do: browser() |> authorize(authorize_params(client, challenge, overrides)) |> consent_id()

  defp allow_form(scopes \\ [@read]),
    do: %{"decision" => "allow", "scopes" => scopes, "days" => "30"}

  describe "who may connect an application" do
    test "a person with neither api_personal_keys nor api gets a page and no code", %{
      client: client,
      challenge: challenge
    } do
      {user, _role} = KeyTestSupport.user_without_api(["dashboard"])
      id = request_id(client, challenge)

      page = consent(browser(user), id)
      assert page.status == 403
      assert get_resp_header(page, "location") == []
      assert [] = page.resp_body |> Floki.parse_document!() |> Floki.find("#consent-form")

      answer = decide(browser(user), id, allow_form())
      assert answer.status == 403
      assert get_resp_header(answer, "location") == []
      assert Repo.all(Grant) == []
      assert Requests.live_count() == 1
    end

    test "an impersonated session is refused", %{user: user, client: client, challenge: challenge} do
      id = request_id(client, challenge)
      root = KeyTestSupport.owner_user()
      root_token = Auth.generate_user_session_token(root)
      token = Auth.generate_user_session_token(user)

      conn =
        browser()
        |> init_test_session(%{
          "user_token" => token,
          "pk_session_accounts" => [root_token, token]
        })

      page = consent(conn, id)
      assert page.status == 403

      conn = decide(conn, id, allow_form())
      assert conn.status == 403
      assert Repo.all(Grant) == []
    end

    test "a service account (api_only) is refused", %{client: client, challenge: challenge} do
      {role, _} = KeyTestSupport.role_with(["api_personal_keys", "dashboard"])
      service = KeyTestSupport.service_user_with([role.name])
      id = request_id(client, challenge)

      # A service account has no browser session at all: the person is asked to sign in, and
      # no connection is made for it.
      conn = decide(browser(service), id, allow_form())
      assert redirected_to(conn, 302) =~ "/users/log-in"
      assert Repo.all(Grant) == []
    end

    test "a managed organization is refused", %{user: user, client: client, challenge: challenge} do
      id = request_id(client, challenge)

      user
      |> Ecto.Changeset.change(account_type: "organization", managed_by_members: true)
      |> Repo.update!()

      conn = decide(browser(user), id, allow_form())
      refute conn.status == 302 and location(conn) =~ client.client_id
      assert Repo.all(Grant) == []
    end

    test "the right taken away between the page and the answer: no code, the request survives", %{
      user: user,
      role: role,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      assert consent(browser(user), id).status == 200

      :ok = Permissions.revoke_permission(role.uuid, "api_personal_keys")

      answer = decide(browser(user), id, allow_form())
      assert answer.status == 403
      assert get_resp_header(answer, "location") == []
      assert Repo.all(Grant) == []
      assert Repo.all(Code) == []
      assert Requests.live_count() == 1
    end
  end

  describe "an answer is judged on the stored request, once" do
    test "a second answer meets the start-again page and makes no second grant", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      assert decide(browser(user), id, allow_form()).status == 302

      again = decide(browser(user), id, allow_form())
      assert again.status == 400
      assert get_resp_header(again, "location") == []
      assert length(Repo.all(Grant)) == 1
      assert length(Repo.all(Code)) == 1
    end

    test "fields of the form that name a client, a redirect, a resource or a scope are not read",
         %{
           user: user,
           client: client,
           challenge: challenge
         } do
      other = client!(%{redirect_uris: ["https://evil.example/cb"]})
      id = request_id(client, challenge)

      forged =
        Map.merge(allow_form(), %{
          "client_id" => other.client_id,
          "redirect_uri" => "https://evil.example/cb",
          "resource" => "https://evil.example/mcp",
          "code_challenge" => "X",
          "user_uuid" => KeyTestSupport.owner_user().uuid,
          "state" => "forged"
        })

      conn = decide(browser(user), id, forged)
      assert String.starts_with?(location(conn), hd(client.redirect_uris) <> "?")
      refute location_params(conn)["state"] == "forged"

      assert [%Grant{} = grant] = Repo.all(Grant)
      assert grant.client_uuid == client.uuid
      assert grant.user_uuid == user.uuid
    end

    test "an unknown decision is not an answer", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      assert decide(browser(user), id, %{"decision" => "maybe"}).status == 400
      assert Requests.live_count() == 1
    end

    test "a request that ran out is gone", %{user: user, client: client, challenge: challenge} do
      id = request_id(client, challenge)

      Repo.update_all(PhoenixKit.API.OAuth.Request,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

      assert consent(browser(user), id).status == 400
      assert decide(browser(user), id, allow_form()).status == 400
      assert Repo.all(Grant) == []
    end

    test "a malformed id is the start-again page, not an error", %{user: user} do
      for id <- ["x", String.duplicate("A", 42), String.duplicate("A", 44), "../../etc"] do
        conn = consent(browser(user), id)
        assert conn.status in [400, 404], id
      end
    end

    test "days are clamped to the ceiling of personal keys, and the grant is made for that long",
         %{
           user: user,
           client: client,
           challenge: challenge
         } do
      put_setting("api_personal_key_max_days", "10")
      id = request_id(client, challenge)

      conn = decide(browser(user), id, Map.put(allow_form(), "days", "9999"))
      assert conn.status == 302
      assert [%Grant{expires_at: expires_at}] = Repo.all(Grant)
      assert DateTime.diff(expires_at, DateTime.utc_now(), :day) in 9..10
    end
  end

  describe "the page's headers" do
    test "the host's policy is kept and only frame-ancestors is replaced", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)

      conn =
        user
        |> browser()
        |> put_resp_header(
          "content-security-policy",
          "default-src 'self'; frame-ancestors https://partner.example; script-src 'self'"
        )
        |> consent(id)

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      assert csp =~ "frame-ancestors 'none'"
      refute csp =~ "partner.example"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a host with no policy gets one that carries frame-ancestors", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      conn = consent(browser(user), id)
      # The host's own default policy (`put_secure_browser_headers`) survives; only its
      # `frame-ancestors 'self'` is replaced.
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "base-uri 'self'"
      assert csp =~ "frame-ancestors 'none'"
      refute csp =~ "frame-ancestors 'self'"
    end

    test "a host policy without frame-ancestors gets the directive appended" do
      assert Responses.replace_directive("default-src 'self'") ==
               "default-src 'self'; frame-ancestors 'none'"

      assert Responses.replace_directive("frame-ancestors *; img-src data:") ==
               "img-src data:; frame-ancestors 'none'"

      assert Responses.replace_directive("FRAME-ANCESTORS 'self'") == "frame-ancestors 'none'"
    end

    test "every page of the flow is not cacheable and not for a robot", %{
      client: client,
      challenge: challenge
    } do
      conn = authorize(browser(), authorize_params(client, challenge, %{"client_id" => "nope"}))
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end
  end

  describe "CSRF" do
    test "a POST without the token is refused and uses nothing up", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)

      conn =
        user
        |> browser()
        |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent 403, fn -> decide(conn, id, allow_form()) end
      assert Repo.all(Grant) == []
      assert Requests.live_count() == 1
    end
  end

  describe "the account gate" do
    test "an unconfirmed person is sent to confirm the e-mail, with the consent URL kept", %{
      client: client,
      challenge: challenge,
      role: role
    } do
      {:ok, user} =
        Auth.register_user(
          %{
            email: "unconfirmed#{System.unique_integer([:positive])}@example.com",
            password: "ValidPassword123!"
          },
          nil
        )

      {:ok, _} = Roles.assign_role(user, role.name)
      id = request_id(client, challenge)

      conn = consent(browser(user), id)
      assert redirected_to(conn, 302) =~ "/users/confirm"
      assert get_session(conn, :user_return_to) == path("/consent/" <> id)
      assert Repo.all(Grant) == []
    end
  end

  describe "the website gate" do
    # The gate is a plug of the host's `:browser` pipeline (`PhoenixKitWeb.Plugs.Integration`); the
    # test router does not carry it, so what is checked is the pipeline each route sits in: the
    # two pages in the browser pipeline (behind the gate), the two machine endpoints and the
    # metadata documents outside it (a client has no cookie to unlock the gate with).
    test "the pages are in the browser pipeline, the machine endpoints are not" do
      info = &Phoenix.Router.route_info(PhoenixKitWeb.Router, &1, path(&2), "localhost")

      for {verb, rest} <- [{"GET", "/authorize"}, {"GET", "/consent/x"}, {"POST", "/consent/x"}] do
        assert :browser in info.(verb, rest).pipe_through, rest
      end

      for {verb, rest} <- [{"POST", "/token"}, {"POST", "/revoke"}] do
        refute :browser in info.(verb, rest).pipe_through, rest
        assert :phoenix_kit_api_v1 in info.(verb, rest).pipe_through, rest
      end

      for path <- ["/.well-known/oauth-authorization-server"] do
        assert %{pipe_through: pipes} =
                 Phoenix.Router.route_info(PhoenixKitWeb.Router, "GET", path, "localhost")

        refute :browser in pipes
      end
    end
  end

  describe "the ceiling of connections" do
    setup %{user: user, client: client} do
      put_setting("api_oauth_grants_per_person", "2")
      flows = for _ <- 1..2, do: code_for(user, client, [@read])
      %{flows: flows}
    end

    test "unfinished consents (a live code, no exchange) count; the page lists them", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      page = consent(browser(user), id)
      assert page.status == 200
      html = Floki.parse_document!(page.resp_body)
      assert [] = Floki.find(html, "#consent-form")
      assert [_, _] = Floki.find(html, "#grants-table tbody tr")
    end

    test "an answer at the ceiling is refused, nothing is made, the request is not used up", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      conn = decide(browser(user), id, allow_form())
      assert conn.status == 409
      assert get_resp_header(conn, "location") == []
      assert length(Repo.all(Grant)) == 2
      assert length(Repo.all(Code)) == 2
      assert Requests.live_count() == 1
    end

    test "disconnecting one grant lets the same request go on", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = request_id(client, challenge)
      [grant | _] = Grants.list_live(user.uuid)

      conn = disconnect(browser(user), id, %{"grant" => grant.uuid})
      assert redirected_to(conn, 302) == path("/consent/" <> id)
      assert %DateTime{} = Repo.reload!(grant).revoked_at

      assert consent(browser(user), id).status == 200
      answer = decide(browser(user), id, allow_form())
      assert answer.status == 302
      assert %{"code" => _} = location_params(answer)
    end

    test "somebody else's grant cannot be disconnected from here", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      {other, _role} = holder(["dashboard"])
      other_flow = code_for(other, client, [@read])
      assert other_flow.code
      [foreign] = Repo.all(from(g in Grant, where: g.user_uuid == ^other.uuid))

      id = request_id(client, challenge)
      disconnect(browser(user), id, %{"grant" => foreign.uuid})
      assert is_nil(Repo.reload!(foreign).revoked_at)
    end

    test "a consent nobody finished stops counting when its code has run out", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      Repo.update_all(Code, set: [expires_at: DateTime.add(DateTime.utc_now(), -5, :second)])
      assert Grants.count_live(user.uuid) == 0

      id = request_id(client, challenge)
      assert consent(browser(user), id).status == 200
    end

    test "grants of other people do not count", %{client: client, challenge: challenge} do
      {other, _role} = holder(["dashboard"])
      id = request_id(client, challenge)
      assert consent(browser(other), id).status == 200
    end
  end
end
