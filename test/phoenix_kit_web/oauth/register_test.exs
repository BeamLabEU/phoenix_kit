defmodule PhoenixKitWeb.OAuth.RegisterTest do
  @moduledoc """
  `POST /oauth/register` (RFC 7591, Dynamic Client Registration) through the real endpoint, body
  guard and database: off by default, public clients only, what is ignored and what is refused,
  the answer, the limits, the log and the activity entry; and a client registered this way
  through the whole flow.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.OAuthFlowSupport

  import PhoenixKit.API.OAuthTestSupport,
    only: [enable_oauth!: 0, pkce: 0]

  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Utils.Routes

  @read "testkit.items:read"
  @redirect "https://app.example/oauth/callback"

  setup do
    setup_api()
    enable_oauth!()
    put_setting("api_oauth_dcr_enabled", "true")
    Limits.reset(:register_global, nil)
    :ok
  end

  defp valid(extra \\ %{}),
    do: Map.merge(%{"redirect_uris" => [@redirect], "client_name" => "My Agent"}, extra)

  defp error_of(conn, status) do
    assert conn.status == status
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    body(conn)
  end

  describe "the switches" do
    test "off by default: 404 and nothing is stored" do
      put_setting("api_oauth_dcr_enabled", "false")

      conn = register(valid())
      assert conn.status == 404
      assert Repo.aggregate(Client, :count) == 0
    end

    test "with OAuth itself off: 404" do
      put_setting("api_oauth_enabled", "false")
      assert register(valid()).status == 404
    end

    test "the setting must read exactly true" do
      put_setting("api_oauth_dcr_enabled", "yes")
      assert register(valid()).status == 404
    end
  end

  describe "a registration" do
    test "answers 201 with the RFC 7591 document of a public client" do
      conn = register(valid(%{"client_uri" => "https://app.example"}))
      body = error_of(conn, 201)

      assert "dcr_" <> _ = body["client_id"]
      assert is_integer(body["client_id_issued_at"])
      assert abs(body["client_id_issued_at"] - System.os_time(:second)) < 30
      assert body["redirect_uris"] == [@redirect]
      assert body["client_name"] == "My Agent"
      assert body["client_uri"] == "https://app.example"
      assert body["token_endpoint_auth_method"] == "none"
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
      assert body["response_types"] == ["code"]
      refute Map.has_key?(body, "client_secret")
      refute Map.has_key?(body, "client_secret_expires_at")

      assert [%Client{kind: "dcr", client_id: id, redirect_uris: [@redirect]}] = Repo.all(Client)
      assert id == body["client_id"]
    end

    test "every registration gets an id of its own, not guessable from the last one" do
      ids = for _n <- 1..3, do: register(valid()) |> body() |> Map.fetch!("client_id")
      assert length(Enum.uniq(ids)) == 3
      assert Enum.all?(ids, &(byte_size(&1) >= 20))
    end

    test "secrets, keys and auth methods the client sends are ignored, the client stays public" do
      conn =
        register(
          valid(%{
            "client_secret" => "s3cret",
            "client_secret_expires_at" => 0,
            "jwks" => %{"keys" => []},
            "jwks_uri" => "https://app.example/jwks.json",
            "token_endpoint_auth_method" => "client_secret_basic",
            "grant_types" => ["client_credentials"],
            "response_types" => ["token"],
            "scope" => "everything",
            "software_statement" => "abc"
          })
        )

      body = error_of(conn, 201)
      assert body["token_endpoint_auth_method"] == "none"
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
      refute inspect(body) =~ "s3cret"
      refute Map.has_key?(body, "jwks")
      refute Map.has_key?(body, "scope")
    end

    test "the name is cleaned and cut; a home page that is not https is left out" do
      name = "  Ag\u0000ent\u202E " <> String.duplicate("n", 300)

      body =
        register(valid(%{"client_name" => name, "client_uri" => "http://app.example"}))
        |> error_of(201)

      assert String.length(body["client_name"]) == 160
      assert String.starts_with?(body["client_name"], "Agent")
      refute Map.has_key?(body, "client_uri")
    end

    test "a name of combining marks is cut by code points as well, not by the column" do
      # 160 graphemes of 4 code points: the column (character varying(160)) counts code points.
      name = String.duplicate("a\u0301\u0302\u0303", 160)
      assert String.length(name) == 160

      body = register(valid(%{"client_name" => name})) |> error_of(201)

      assert length(String.codepoints(body["client_name"])) <= 160
      assert String.starts_with?(body["client_name"], "a\u0301")
      assert [%Client{client_name: stored}] = Repo.all(from(c in Client, where: c.kind == "dcr"))
      assert stored == body["client_name"]
    end

    test "a registration without a name is fine" do
      body = register(%{"redirect_uris" => [@redirect]}) |> error_of(201)
      refute Map.has_key?(body, "client_name")
    end

    test "a loopback redirect is accepted" do
      body = register(%{"redirect_uris" => ["http://127.0.0.1:33418/callback"]}) |> error_of(201)
      assert body["redirect_uris"] == ["http://127.0.0.1:33418/callback"]
    end

    test "writes an activity entry that names no secret and no redirect" do
      body = register(valid()) |> body()

      assert [entry] =
               Repo.all(
                 from(e in Entry,
                   where:
                     e.action == "oauth.client_registered" and e.resource_type == "oauth_client",
                   order_by: [desc: e.inserted_at],
                   limit: 1
                 )
               )

      client = Repo.get_by!(Client, client_id: body["client_id"])
      assert entry.resource_uuid == client.uuid
      assert entry.metadata["kind"] == "dcr"
      # anyone can write this row without logging in: the pruning job has to be able to remove it
      refute entry.permanent
      refute inspect(entry.metadata) =~ @redirect
    end
  end

  describe "what is refused" do
    test "redirect URIs that are missing or may not be registered: invalid_redirect_uri" do
      for bad <- [
            nil,
            [],
            "https://app.example/cb",
            [5],
            [""],
            ["cursor://x/y"],
            ["vscode://x/y"],
            ["http://app.example/cb"],
            ["https://app.example/cb#frag"],
            ["https://*.app.example/cb"],
            ["https://app.example/cb", "app://x"],
            Enum.map(1..11, &"https://app.example/cb/#{&1}")
          ] do
        params = if is_nil(bad), do: %{}, else: %{"redirect_uris" => bad}
        body = error_of(register(params), 400)
        assert body["error"] == "invalid_redirect_uri", inspect(bad)
      end

      assert Repo.aggregate(Client, :count) == 0
    end

    test "metadata of the wrong type: invalid_client_metadata" do
      for extra <- [%{"client_name" => 42}, %{"client_name" => ["a"]}, %{"client_uri" => 5}] do
        body = error_of(register(valid(extra)), 400)
        assert body["error"] == "invalid_client_metadata", inspect(extra)
      end
    end

    test "a body that is not a JSON object, or is too large: invalid_request" do
      for raw <- ["not json", "[]", "\"x\"", "{"] do
        body = error_of(register(raw), 400)
        assert body["error"] == "invalid_request", raw
      end

      big = JSON.encode!(valid(%{"client_name" => String.duplicate("x", 20_000)}))
      assert error_of(register(big), 400)["error"] == "invalid_request"
      assert Repo.aggregate(Client, :count) == 0
    end

    test "an empty body is a registration without redirect URIs" do
      assert error_of(register(""), 400)["error"] == "invalid_redirect_uri"
    end

    test "the answers never repeat what the client sent" do
      marker = "CONTROLMARK-#{System.unique_integer([:positive])}"
      conn = register(%{"redirect_uris" => ["cursor://" <> marker]})
      refute conn.resp_body =~ marker
    end
  end

  describe "the policy" do
    test "under the allow-list only listed redirect hosts are accepted" do
      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "claude.ai")

      assert error_of(register(valid()), 400)["error"] == "invalid_redirect_uri"

      assert register(%{"redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]}).status ==
               201
    end
  end

  describe "the limits" do
    test "a network may register so many clients an hour" do
      put_setting("api_oauth_register_per_hour", 2)
      ip = unique_ip()

      assert register(valid(), ip: ip).status == 201
      assert register(valid(), ip: ip).status == 201

      conn = register(valid(), ip: ip)
      body = error_of(conn, 429)
      assert body["error"] == "invalid_request"
      assert [_] = get_resp_header(conn, "retry-after")

      # Another network is not affected.
      assert register(valid()).status == 201
      assert Repo.aggregate(Client, :count) == 3
    end

    test "the whole install may register so many clients a day" do
      put_setting("api_oauth_register_per_day", 2)

      assert register(valid()).status == 201
      assert register(valid()).status == 201
      assert error_of(register(valid()), 429)["error"] == "invalid_request"
      assert Repo.aggregate(Client, :count) == 2
    end

    test "a refused registration still counts: a client cannot probe for free" do
      put_setting("api_oauth_register_per_hour", 2)
      ip = unique_ip()

      assert register(%{}, ip: ip).status == 400
      assert register(%{}, ip: ip).status == 400
      assert register(valid(), ip: ip).status == 429
    end
  end

  describe "the log" do
    test "what a registration carries does not reach the route log" do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      marker = "https://marker-#{System.unique_integer([:positive])}.example/cb"

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          register(%{"redirect_uris" => [marker], "client_secret" => "SECRETMARK"})

          # A control: the same logger does print the parameters of a route without `log: false`.
          Phoenix.ConnTest.dispatch(
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
      refute Enum.any?(route_lines, &(&1 =~ "SECRETMARK" or &1 =~ marker))
    end
  end

  describe "a client that registered itself, through the flow" do
    test "authorize, consent (the name is marked as unchecked), code, token" do
      client = register(valid()) |> body()
      {user, _role} = holder(["dashboard", "settings"])
      app = %{client_id: client["client_id"], redirect_uris: client["redirect_uris"]}

      {_verifier, challenge} = pkce()
      conn = authorize(browser(), authorize_params(app, challenge))
      assert conn.status == 302

      html = consent(browser(user), consent_id(conn)).resp_body |> Floki.parse_document!()
      assert [_] = Floki.find(html, "#consent-unverified")
      assert Floki.find(html, "#consent-host") |> Floki.text() |> String.trim() == "app.example"
      assert [] = Floki.find(html, "#consent-client-address")

      flow = code_for(user, app, [@read])
      token = exchange_code(flow)
      assert token.status == 200
      assert %{"access_token" => "pkoa_" <> _} = body(token)
    end

    test "a redirect it did not register is an error page" do
      client = register(valid()) |> body()
      {_verifier, challenge} = pkce()
      app = %{client_id: client["client_id"], redirect_uris: ["https://elsewhere.example/cb"]}

      assert authorize(browser(), authorize_params(app, challenge)).status == 400
    end

    test "a new policy applies to clients already registered" do
      client = register(valid()) |> body()
      {_verifier, challenge} = pkce()
      app = %{client_id: client["client_id"], redirect_uris: client["redirect_uris"]}
      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "other.example")

      assert authorize(browser(), authorize_params(app, challenge)).status == 400
    end
  end
end
