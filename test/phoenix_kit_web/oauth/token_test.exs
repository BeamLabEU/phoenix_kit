defmodule PhoenixKitWeb.OAuth.TokenTest do
  @moduledoc """
  `POST /oauth/token` through the real endpoint: what a code exchange refuses, that a replayed
  code kills the grant, the shape and the headers of an answer, the limit, the switch, and that
  nothing is read from the URL.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Utils.Routes

  @read "testkit.items:read"

  setup do
    setup_api()
    enable_oauth!()
    {user, _role} = holder(["dashboard"])
    client = client!()
    %{user: user, client: client, flow: code_for(user, client, [@read])}
  end

  defp error_of(conn), do: body(conn)["error"]

  describe "a good exchange" do
    test "answers with the pair, the scopes and no-store headers", %{flow: flow} do
      conn = exchange_code(flow)
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "pragma") == ["no-cache"]
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      assert %{
               "access_token" => access,
               "refresh_token" => refresh,
               "token_type" => "Bearer",
               "expires_in" => expires_in,
               "scope" => @read
             } = body(conn)

      assert String.starts_with?(access, "pkoa_")
      assert is_binary(refresh) and refresh != access
      assert expires_in in 1..3600
    end

    test "the grant is activated by it, and the resource is the server's own", %{flow: flow} do
      assert [%Grant{activated_at: nil}] = Repo.all(Grant)
      assert exchange_code(flow).status == 200
      assert [%Grant{activated_at: %DateTime{}, resource: resource}] = Repo.all(Grant)
      assert resource == Resource.resource()
    end

    test "the resource parameter, when sent, must be the server's own", %{flow: flow} do
      conn = exchange_code(flow, %{"resource" => "https://elsewhere.example/mcp"})
      assert conn.status == 400
      assert error_of(conn) == "invalid_target"
    end

    test "a client_secret and other unknown fields are ignored", %{flow: flow} do
      assert exchange_code(flow, %{"client_secret" => "x", "foo" => "bar"}).status == 200
    end
  end

  describe "what is refused" do
    test "a wrong verifier burns the code and is invalid_grant", %{flow: flow} do
      conn = exchange_code(flow, %{"code_verifier" => String.duplicate("a", 43)})
      assert conn.status == 400
      assert error_of(conn) == "invalid_grant"

      # The code was spent by the attempt: the right verifier does not help any more.
      assert error_of(exchange_code(flow)) == "invalid_grant"
    end

    test "a verifier of the wrong length is invalid_request", %{flow: flow} do
      for verifier <- ["short", String.duplicate("a", 129), String.duplicate("é", 50)] do
        conn = exchange_code(flow, %{"code_verifier" => verifier})
        assert conn.status == 400
        assert error_of(conn) in ["invalid_request", "invalid_grant"]
      end
    end

    test "another redirect_uri is invalid_grant", %{flow: flow} do
      conn = exchange_code(flow, %{"redirect_uri" => "https://client.example/other"})
      assert conn.status == 400
      assert error_of(conn) == "invalid_grant"
    end

    test "the code of another client is invalid_grant", %{flow: flow} do
      other = client!()
      conn = exchange_code(flow, %{"client_id" => other.client_id})
      assert conn.status == 400
      assert error_of(conn) == "invalid_grant"
    end

    test "an unknown client is invalid_client: 400, and 401 with a challenge only when the client sent credentials",
         %{flow: flow} do
      conn = exchange_code(flow, %{"client_id" => "nope"})
      assert conn.status == 400
      assert error_of(conn) == "invalid_client"
      assert get_resp_header(conn, "www-authenticate") == []

      attempted =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("nope:secret"))
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Plug.Conn.put_req_header("x-forwarded-for", unique_ip())
        |> Phoenix.ConnTest.dispatch(
          @endpoint,
          :post,
          path("/token"),
          URI.encode_query(%{
            "grant_type" => "authorization_code",
            "code" => flow.code,
            "code_verifier" => flow.verifier,
            "redirect_uri" => flow.redirect_uri,
            "client_id" => "nope"
          })
        )

      assert attempted.status == 401
      assert [challenge] = get_resp_header(attempted, "www-authenticate")
      assert challenge =~ "Basic"
    end

    test "a code that ran out is invalid_grant", %{flow: flow} do
      Repo.update_all(Code, set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])
      conn = exchange_code(flow)
      assert conn.status == 400
      assert error_of(conn) == "invalid_grant"
    end

    test "a made-up code is invalid_grant", %{flow: flow} do
      conn = exchange_code(flow, %{"code" => String.duplicate("A", 43)})
      assert conn.status == 400
      assert error_of(conn) == "invalid_grant"
    end

    test "missing parameters are invalid_request", %{flow: flow} do
      for name <- ["code", "code_verifier", "redirect_uri", "client_id"] do
        conn = exchange_code(flow, %{name => nil})
        assert conn.status == 400, name
        assert error_of(conn) == "invalid_request", name
      end

      assert error_of(token(%{})) == "invalid_request"
      assert error_of(token(%{"grant_type" => "refresh_token"})) == "invalid_request"
    end

    test "other grant types are unsupported_grant_type", %{flow: flow} do
      for type <- ["password", "client_credentials", "implicit"] do
        conn = token(%{"grant_type" => type, "client_id" => flow.client.client_id})
        assert conn.status == 400
        assert error_of(conn) == "unsupported_grant_type"
      end
    end

    test "a repeated parameter is refused", %{flow: flow} do
      query = URI.encode_query(Map.delete(exchange_params(flow), "code")) <> "&code=a&code=b"
      conn = token(query)
      assert conn.status == 400
      assert error_of(conn) == "invalid_request"
    end

    test "a parameter in the URL is not read", %{flow: flow} do
      params = exchange_params(flow)
      url_only = Map.drop(params, ["code"])

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-forwarded-for", unique_ip())
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Phoenix.ConnTest.dispatch(
          @endpoint,
          :post,
          path("/token") <> "?code=" <> flow.code,
          URI.encode_query(url_only)
        )

      assert conn.status == 400
      assert error_of(conn) == "invalid_request"
    end

    test "a JSON body is refused, not guessed", %{flow: flow} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-forwarded-for", unique_ip())
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(
          @endpoint,
          :post,
          path("/token"),
          JSON.encode!(exchange_params(flow))
        )

      assert conn.status in [400, 415]
    end

    test "a GET is not a token request" do
      conn =
        Phoenix.ConnTest.dispatch(
          Phoenix.ConnTest.build_conn(),
          @endpoint,
          :get,
          path("/token"),
          nil
        )

      assert conn.status in [404, 405]
    end
  end

  describe "a replayed code" do
    test "revokes the grant: the tokens of the first exchange die with it", %{flow: flow} do
      first = exchange_code(flow)
      assert first.status == 200
      %{"access_token" => access, "refresh_token" => refresh} = body(first)
      assert tools_list(access).status == 200

      replay = exchange_code(flow)
      assert replay.status == 400
      assert error_of(replay) == "invalid_grant"

      assert [%Grant{revoked_at: %DateTime{}}] = Repo.all(Grant)
      assert tools_list(access).status == 401
      assert error_of(refresh(flow.client, refresh)) == "invalid_grant"
    end
  end

  describe "the limit and the switch" do
    test "the network's minute runs out: 429 with Retry-After", %{flow: flow} do
      put_setting("api_oauth_token_per_min", "2")
      ip = unique_ip()

      statuses =
        for _ <- 1..3 do
          conn = token(%{"grant_type" => "refresh_token"}, ip: ip)
          {conn.status, get_resp_header(conn, "retry-after")}
        end

      assert [{400, []}, {400, []}, {429, [retry]}] = statuses
      assert String.to_integer(retry) in 1..60
      # Other networks are not affected.
      assert exchange_code(flow).status == 200
    end

    test "OAuth off: 404 for the token and the revoke endpoints", %{flow: flow} do
      put_setting("api_oauth_enabled", "false")
      assert exchange_code(flow).status == 404
      assert revoke(%{"token" => "x"}).status == 404
    end
  end

  describe "the log" do
    test "the parameters of a token request do not reach the route log", %{flow: flow} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          exchange_code(flow)

          # A control: the same logger does print the parameters of a route without `log: false`.
          dispatch(
            browser(),
            @endpoint,
            :get,
            Routes.path("/api/consent-config") <> "?marker=CONTROLMARK",
            nil
          )
        end)

      route_lines =
        log
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "Processing with" or &1 =~ "Parameters:"))

      assert Enum.any?(route_lines, &(&1 =~ "CONTROLMARK"))
      refute Enum.any?(route_lines, &(&1 =~ flow.code or &1 =~ flow.verifier))
    end
  end

  defp exchange_params(flow) do
    %{
      "grant_type" => "authorization_code",
      "code" => flow.code,
      "code_verifier" => flow.verifier,
      "redirect_uri" => flow.redirect_uri,
      "client_id" => flow.client.client_id
    }
  end
end
