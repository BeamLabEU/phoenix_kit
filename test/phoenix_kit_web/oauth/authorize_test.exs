defmodule PhoenixKitWeb.OAuth.AuthorizeTest do
  @moduledoc """
  `GET /oauth/authorize` through the real endpoint: what it accepts, which errors go to the client
  and which only to the browser (never a redirect to a redirect URI nobody confirmed), the limits,
  the switch, and what it writes to the log.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.API.OAuthFlowSupport

  import PhoenixKit.API.OAuthTestSupport,
    only: [client!: 0, client!: 1, enable_oauth!: 0, pkce: 0]

  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0, switch: 2]

  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Utils.Routes

  setup do
    setup_api()
    enable_oauth!()
    {_verifier, challenge} = pkce()
    %{client: client!(), challenge: challenge}
  end

  defp redirect_error(conn) do
    assert conn.status == 302
    location_params(conn)
  end

  describe "a valid request" do
    test "is stored on the server and leads to a consent URL that is not the row's uuid", %{
      client: client,
      challenge: challenge
    } do
      conn = authorize(browser(), authorize_params(client, challenge, %{"scope" => nil}))
      assert conn.status == 302
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      id = consent_id(conn)
      assert [%Request{} = request] = Repo.all(Request)
      refute id =~ request.uuid
      # Only the hash of the token is stored.
      assert request.request_token_hash ==
               :crypto.hash(:sha256, Base.url_decode64!(id, padding: false))

      assert request.resource == Resource.resource()
      assert request.client_snapshot["client_id"] == client.client_id
      assert DateTime.diff(request.expires_at, DateTime.utc_now()) in 595..600
    end

    test "the client is marked as seen", %{client: client, challenge: challenge} do
      assert is_nil(client.last_seen_at)
      authorize(browser(), authorize_params(client, challenge))
      assert %DateTime{} = Repo.reload!(client).last_seen_at
    end

    test "a client seen within the hour is not written again, an older one is", %{
      client: client,
      challenge: challenge
    } do
      recent = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      Repo.update_all(PhoenixKit.API.OAuth.Client, set: [last_seen_at: recent])

      authorize(browser(), authorize_params(client, challenge))
      assert Repo.reload!(client).last_seen_at == recent

      stale = DateTime.add(recent, -2 * 3600, :second)
      Repo.update_all(PhoenixKit.API.OAuth.Client, set: [last_seen_at: stale])

      authorize(browser(), authorize_params(client, challenge))
      assert DateTime.compare(Repo.reload!(client).last_seen_at, recent) == :gt
    end

    test "an own resource written with another case and a trailing slash is accepted", %{
      client: client,
      challenge: challenge
    } do
      uri = URI.parse(Resource.resource())
      resource = "#{String.upcase(uri.scheme)}://#{String.upcase(uri.host)}#{uri.path}/"
      params = authorize_params(client, challenge, %{"resource" => resource})
      assert authorize(browser(), params).status == 302
      assert [%Request{resource: stored}] = Repo.all(Request)
      assert stored == Resource.resource()
    end

    test "unknown scopes are dropped, known ones kept", %{client: client, challenge: challenge} do
      params =
        authorize_params(client, challenge, %{"scope" => "testkit.items:read nope.x:read"})

      authorize(browser(), params)
      assert [%Request{requested_scopes: ["testkit.items:read"]}] = Repo.all(Request)
    end

    test "prompt and id_token_hint are ignored", %{client: client, challenge: challenge} do
      params = authorize_params(client, challenge, %{"prompt" => "none", "id_token_hint" => "x"})
      assert authorize(browser(), params).status == 302
    end

    test "an anonymous visitor is not sent to the sign-in by authorize itself", %{
      client: client,
      challenge: challenge
    } do
      conn = authorize(browser(), authorize_params(client, challenge))
      assert location(conn) =~ "/oauth/consent/"
      refute location(conn) =~ "log-in"
    end
  end

  describe "errors that are never redirected" do
    test "an unknown client and a foreign redirect URI give the very same page", %{
      client: client,
      challenge: challenge
    } do
      no_client =
        authorize(browser(), authorize_params(client, challenge, %{"client_id" => "nope"}))

      foreign =
        authorize(
          browser(),
          authorize_params(client, challenge, %{"redirect_uri" => "https://evil.example/cb"})
        )

      assert no_client.status == 400
      assert foreign.status == 400
      assert get_resp_header(no_client, "location") == []
      assert get_resp_header(foreign, "location") == []
      assert no_client.resp_body == foreign.resp_body
    end

    test "a missing client_id or redirect_uri, a custom scheme and a fragment are pages too", %{
      client: client,
      challenge: challenge
    } do
      for overrides <- [
            %{"client_id" => nil},
            %{"redirect_uri" => nil},
            %{"redirect_uri" => "app://callback"},
            %{"redirect_uri" => hd(client.redirect_uris) <> "#frag"},
            %{"redirect_uri" => "javascript:alert(1)"},
            %{"redirect_uri" => ""}
          ] do
        conn = authorize(browser(), authorize_params(client, challenge, overrides))
        assert conn.status == 400, inspect(overrides)
        assert get_resp_header(conn, "location") == []
      end

      assert Repo.all(Request) == []
    end

    test "a repeated parameter is a page, whichever it is", %{
      client: client,
      challenge: challenge
    } do
      query =
        authorize_params(client, challenge)
        |> URI.encode_query()
        |> Kernel.<>("&redirect_uri=" <> URI.encode_www_form("https://evil.example/cb"))

      conn = dispatch(browser(), @endpoint, :get, path("/authorize") <> "?" <> query, nil)
      assert conn.status == 400
      assert get_resp_header(conn, "location") == []

      conn =
        dispatch(browser(), @endpoint, :get, path("/authorize") <> "?scope[]=a&scope[]=b", nil)

      assert conn.status == 400
    end

    test "the redirect URI is compared exactly, but the host's case does not matter", %{
      challenge: challenge
    } do
      client = client!(%{redirect_uris: ["https://client.example/cb?x=1"]})

      for uri <- [
            "https://client.example/cb",
            "https://client.example/cb?x=2",
            "https://client.example/CB?x=1",
            "https://client.example/%63b?x=1",
            "http://client.example/cb?x=1",
            "https://client.example:8443/cb?x=1"
          ] do
        conn = authorize(browser(), authorize_params(client, challenge, %{"redirect_uri" => uri}))
        assert conn.status == 400, uri
      end

      ok =
        authorize_params(client, challenge, %{"redirect_uri" => "https://CLIENT.example/cb?x=1"})

      assert authorize(browser(), ok).status == 302
    end

    test "a loopback address ignores the port, localhost does not", %{challenge: challenge} do
      client =
        client!(%{
          redirect_uris: ["http://127.0.0.1/cb", "http://localhost:3000/cb"]
        })

      for uri <- ["http://127.0.0.1:51789/cb", "http://127.0.0.1/cb"] do
        params = authorize_params(client, challenge, %{"redirect_uri" => uri})
        assert authorize(browser(), params).status == 302, uri
      end

      params =
        authorize_params(client, challenge, %{"redirect_uri" => "http://localhost:3001/cb"})

      assert authorize(browser(), params).status == 400

      params =
        authorize_params(client, challenge, %{"redirect_uri" => "http://localhost:3000/cb"})

      assert authorize(browser(), params).status == 302

      params =
        authorize_params(client, challenge, %{"redirect_uri" => "http://127.0.0.1:1/other"})

      assert authorize(browser(), params).status == 400
    end
  end

  describe "errors that go to the client (the redirect URI is confirmed)" do
    test "every one carries state and iss", %{client: client, challenge: challenge} do
      cases = [
        {%{"response_type" => "token"}, "unsupported_response_type"},
        {%{"code_challenge_method" => "plain"}, "invalid_request"},
        {%{"code_challenge_method" => nil}, "invalid_request"},
        {%{"code_challenge" => nil}, "invalid_request"},
        {%{"code_challenge" => "short"}, "invalid_request"},
        {%{"resource" => "https://elsewhere.example/mcp/admin"}, "invalid_target"},
        {%{"request" => "eyJ"}, "request_not_supported"},
        {%{"request_uri" => "https://x.example/r"}, "request_uri_not_supported"}
      ]

      for {overrides, error} <- cases do
        params = authorize_params(client, challenge, overrides)
        got = authorize(browser(), params) |> redirect_error()

        assert got["error"] == error, inspect(overrides)
        assert got["state"] == params["state"]
        assert got["iss"] == Resource.issuer()

        assert String.starts_with?(
                 location_of(overrides, client, challenge),
                 hd(client.redirect_uris)
               )
      end

      assert Repo.all(Request) == []
    end

    defp location_of(overrides, client, challenge),
      do: authorize(browser(), authorize_params(client, challenge, overrides)) |> location()

    test "a state longer than 512 is refused and not echoed", %{
      client: client,
      challenge: challenge
    } do
      params = authorize_params(client, challenge, %{"state" => String.duplicate("s", 513)})
      got = authorize(browser(), params) |> redirect_error()
      assert got["error"] == "invalid_request"
      refute Map.has_key?(got, "state")
    end

    test "a redirect URI that already has a query keeps it", %{challenge: challenge} do
      client = client!(%{redirect_uris: ["https://client.example/cb?tenant=7"]})
      params = authorize_params(client, challenge, %{"response_type" => "token"})
      conn = authorize(browser(), params)
      assert location(conn) =~ ~r{\Ahttps://client.example/cb\?tenant=7&}
      assert location_params(conn)["tenant"] == "7"
    end
  end

  describe "limits and the switch" do
    test "the network's minute runs out: 429 and Retry-After, no request stored", %{
      client: client,
      challenge: challenge
    } do
      put_setting("api_oauth_authorize_per_min", "2")
      ip = unique_ip()
      params = authorize_params(client, challenge)

      statuses =
        for _ <- 1..3 do
          conn = browser() |> put_req_header("x-forwarded-for", ip) |> authorize(params)
          {conn.status, get_resp_header(conn, "retry-after")}
        end

      assert [{302, []}, {302, []}, {429, [retry]}] = statuses
      assert String.to_integer(retry) in 1..60
      assert length(Repo.all(Request)) == 2

      # Another network is not affected.
      assert authorize(browser(), params).status == 302
    end

    test "the ceiling of waiting requests: 503 and no row", %{
      client: client,
      challenge: challenge
    } do
      put_setting("api_oauth_requests_ceiling", "1")
      params = authorize_params(client, challenge)
      assert authorize(browser(), params).status == 302

      conn = authorize(browser(), params)
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["30"]
      assert length(Repo.all(Request)) == 1
    end

    test "OAuth off: 404, nothing stored", %{client: client, challenge: challenge} do
      put_setting("api_oauth_enabled", "false")
      conn = authorize(browser(), authorize_params(client, challenge))
      assert conn.status == 404
      assert Repo.all(Request) == []
    end

    test "the admin API off switches OAuth off with it", %{client: client, challenge: challenge} do
      switch(:admin, false)
      assert authorize(browser(), authorize_params(client, challenge)).status == 404
    end
  end

  describe "the log" do
    test "no parameter of the request reaches Phoenix's route log (log: false), another route's do",
         %{client: client, challenge: challenge} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      params = authorize_params(client, challenge, %{"state" => "SECRETSTATE0123"})

      log =
        capture_log([level: :debug], fn ->
          conn = authorize(browser(), params)
          id = consent_id(conn)
          consent(browser(), id)

          # A control: the same logger does print the parameters of a route without `log: false`.
          dispatch(
            browser(),
            @endpoint,
            :get,
            Routes.path("/api/consent-config") <> "?marker=CONTROLMARK",
            nil
          )
        end)

      # What Phoenix itself writes about a dispatched route; Ecto's own debug lines of the
      # queries (which carry bound values in development only) are not what `log: false` governs.
      route_lines =
        log
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "Processing with" or &1 =~ "Parameters:"))

      assert Enum.any?(route_lines, &(&1 =~ "CONTROLMARK"))
      refute Enum.any?(route_lines, &(&1 =~ "OAuth"))
      refute Enum.any?(route_lines, &(&1 =~ "SECRETSTATE0123" or &1 =~ challenge))
    end
  end
end
