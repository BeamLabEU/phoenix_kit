defmodule PhoenixKitWeb.OAuth.MalformedInputTest do
  @moduledoc """
  Text the database cannot hold (a NUL byte; bytes that are not UTF-8) in any input of the public
  endpoints of the authorization server gets the endpoint's ordinary refusal and never a database
  error (HTTP 500): the authorization endpoint answers its page, the token endpoints their JSON
  error, the registration its `invalid_client_metadata` or its cleaned answer, the consent screen
  its "start again" page.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.Test.Repo

  @read "testkit.items:read"
  @nul "a\0b"

  setup do
    setup_api()
    enable_oauth!()
    put_setting("api_oauth_dcr_enabled", "true")
    {user, _role} = holder(["dashboard"])
    client = client!()
    {_verifier, challenge} = pkce()

    %{user: user, client: client, challenge: challenge, flow: code_for(user, client, [@read])}
  end

  describe "GET /oauth/authorize" do
    for field <-
          ~w(client_id redirect_uri state scope resource code_challenge code_challenge_method
             response_type prompt login_hint) do
      test "a NUL byte in #{field} is a page, not a 500", %{client: client, challenge: challenge} do
        before = {Repo.aggregate(Request, :count), Repo.aggregate(Client, :count)}
        params = authorize_params(client, challenge, %{unquote(field) => @nul})
        conn = authorize(browser(), params)

        assert conn.status == 400
        assert get_resp_header(conn, "location") == []
        assert {Repo.aggregate(Request, :count), Repo.aggregate(Client, :count)} == before
      end
    end

    test "a NUL byte in a client_id that looks like a metadata document is never fetched", %{
      challenge: challenge
    } do
      params = %{
        "response_type" => "code",
        "client_id" => "https://claude.ai/oauth/\0client",
        "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      }

      assert authorize(browser(), params).status == 400
    end

    test "bytes that are not UTF-8 are refused before the controller" do
      for raw <- ["client_id=%FF", "state=%C3%28", "scope=%80%80"] do
        assert_error_sent 400, fn ->
          Phoenix.ConnTest.dispatch(browser(), @endpoint, :get, path("/authorize") <> "?" <> raw)
        end
      end
    end
  end

  describe "POST /oauth/token and /oauth/revoke" do
    for field <- ~w(client_id code code_verifier redirect_uri resource scope grant_type) do
      test "a NUL byte in #{field} of a code exchange is invalid_request", %{flow: flow} do
        conn = exchange_code(flow, %{unquote(field) => @nul})

        assert conn.status == 400
        assert body(conn)["error"] == "invalid_request"
      end
    end

    for field <- ~w(client_id refresh_token resource scope grant_type) do
      test "a NUL byte in #{field} of a refresh is invalid_request", %{flow: flow} do
        conn =
          refresh(flow.client, "pkor_" <> String.duplicate("A", 43), %{unquote(field) => @nul})

        assert conn.status == 400
        assert body(conn)["error"] == "invalid_request"
      end
    end

    for field <- ~w(token client_id token_type_hint) do
      test "a NUL byte in #{field} of a revocation is invalid_request", %{flow: flow} do
        conn =
          revoke(
            Map.put(
              %{
                "token" => "pkor_" <> String.duplicate("A", 43),
                "client_id" => flow.client.client_id
              },
              unquote(field),
              @nul
            )
          )

        assert conn.status == 400
        assert body(conn)["error"] == "invalid_request"
      end
    end

    test "the refusals carry no-store and say nothing of the input", %{flow: flow} do
      conn = exchange_code(flow, %{"client_id" => "SECRETMARK\0"})
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      refute conn.resp_body =~ "SECRETMARK"
    end

    test "a revocation with a NUL byte revokes nothing", %{flow: flow} do
      assert exchange_code(flow).status == 200
      assert revoke(%{"token" => "x\0y", "client_id" => flow.client.client_id}).status == 400
      assert [%Grant{revoked_at: nil}] = Repo.all(Grant)
    end
  end

  describe "POST /oauth/register" do
    test "a NUL byte in a redirect URI is invalid_redirect_uri" do
      conn = register(%{"redirect_uris" => ["https://app.example/cb\0"]})
      assert conn.status == 400
      assert body(conn)["error"] == "invalid_redirect_uri"
    end

    test "a NUL byte in the name is cleaned away, in the home page it is left out" do
      conn =
        register(%{
          "redirect_uris" => ["https://app.example/cb"],
          "client_name" => "My\0Agent",
          "client_uri" => "https://app.example/\0"
        })

      assert conn.status == 201
      assert %{"client_name" => "MyAgent"} = body = body(conn)
      refute Map.has_key?(body, "client_uri")
    end

    test "a NUL byte in a field the server ignores changes nothing" do
      conn =
        register(%{
          "redirect_uris" => ["https://app.example/cb"],
          "scope\0" => "a\0b",
          "jwks" => %{"k\0" => ["\0"]}
        })

      assert conn.status == 201
    end

    test "a NUL byte in any redirect URI, whichever part or place in the list, is invalid_redirect_uri" do
      for uris <- [
            ["https://app.example/cb\0"],
            ["https://app\0.example/cb"],
            ["https://app.example/\0cb"],
            ["https://app.example/cb?x=\0"],
            ["http://localhost:3000/\0"],
            ["https://app.example/ok", "https://app.example/cb\0"],
            "https://app.example/cb\0",
            ["\0"]
          ] do
        conn = register(%{"redirect_uris" => uris})
        assert conn.status == 400, inspect(uris)
        assert body(conn)["error"] == "invalid_redirect_uri", inspect(uris)
      end

      assert Repo.all(Client) |> Enum.filter(&(&1.kind == "dcr")) == []
    end

    test "a body that is not UTF-8 is a refusal, not a server error" do
      raw = ~s({"redirect_uris":["https://app.example/cb) <> <<0xFF>> <> ~s("]})

      assert register(raw).status == 400
      assert Repo.all(Client) |> Enum.filter(&(&1.kind == "dcr")) == []
    end

    test "a NUL byte in the name or the home page is cleaned or left out, never stored" do
      for {name, uri, expected} <- [
            {"\0", "https://app.example/", nil},
            {"A\0\0B", "https://app\0.example/", "AB"},
            {"\u2800\u3164A\u3000B", "https://app.example/?q=\0", "A B"}
          ] do
        conn =
          register(%{
            "redirect_uris" => ["https://app.example/cb"],
            "client_name" => name,
            "client_uri" => uri
          })

        assert conn.status == 201
        assert body(conn)["client_name"] == expected
      end

      stored = Repo.all(Client) |> Enum.filter(&(&1.kind == "dcr"))
      assert length(stored) == 3

      assert Enum.all?(
               stored,
               &(is_nil(&1.client_uri) or not String.contains?(&1.client_uri, "\0"))
             )

      assert Enum.all?(stored, &(is_nil(&1.client_name) or String.printable?(&1.client_name)))
    end

    test "a NUL byte as text where text is wanted is invalid_client_metadata" do
      conn = register(%{"redirect_uris" => ["https://app.example/cb"], "client_name" => 5})
      assert conn.status == 400
      assert body(conn)["error"] == "invalid_client_metadata"
    end
  end

  describe "the consent screen" do
    test "an id that is not a token is the start-again page", %{user: user} do
      for id <- ["a%00b", String.duplicate("A", 43) <> "%00"] do
        conn = Phoenix.ConnTest.dispatch(browser(user), @endpoint, :get, path("/consent/" <> id))
        assert conn.status == 400, id
      end
    end

    test "a NUL byte in the grant to disconnect is ignored", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = browser() |> authorize(authorize_params(client, challenge)) |> consent_id()

      for grant <- [@nul, ["x\0"], %{"a" => "\0"}] do
        conn = disconnect(browser(user), id, %{"grant" => grant})
        assert conn.status == 302
      end
    end

    test "a NUL byte in the answer is the start-again page, not a grant", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      id = browser() |> authorize(authorize_params(client, challenge)) |> consent_id()

      for params <- [
            %{"decision" => "allow\0", "scopes" => [@read], "days" => "30"},
            %{"decision" => "allow", "scopes" => [@read <> "\0"], "days" => "30"}
          ] do
        conn = decide(browser(user), id, params)
        assert conn.status in [400, 422], inspect(params)
      end

      assert Repo.aggregate(Grant, :count) == 1
    end
  end
end
