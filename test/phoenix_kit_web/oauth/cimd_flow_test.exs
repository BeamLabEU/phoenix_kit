defmodule PhoenixKitWeb.OAuth.CimdFlowTest do
  @moduledoc """
  The authorization flow of a client that names itself by the URL of a metadata document, through
  the real endpoint: the documents of Claude and ChatGPT (served by a stub of the HTTP layer, no
  socket is opened), the exact redirect check against the document, the consent screen built from
  the document, what a changed document does between the request and the token, and the
  refusals that all look the same from outside.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuthCimdStub, as: Stub
  alias PhoenixKit.Test.ApiHarness
  alias PhoenixKit.Test.Repo

  @claude Stub.claude_id()
  @chatgpt Stub.chatgpt_id()
  @claude_redirect "https://claude.ai/api/mcp/auth_callback"
  @chatgpt_redirect "https://chatgpt.com/connector_platform_oauth_redirect"
  @read "testkit.items:read"

  setup do
    setup_api()
    enable_oauth!()
    Stub.install!()
    Stub.put(@claude, Stub.claude_document())
    Stub.put(@chatgpt, Stub.chatgpt_document())
    for id <- [@claude, @chatgpt], do: Limits.reset(:cimd_client, id)

    {user, _role} = holder(["dashboard", "settings"])
    {_verifier, challenge} = pkce()
    %{user: user, challenge: challenge}
  end

  defp claude, do: %{client_id: @claude, redirect_uris: [@claude_redirect]}
  defp chatgpt, do: %{client_id: @chatgpt, redirect_uris: [@chatgpt_redirect]}

  defp expire_cache! do
    past = DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.truncate(:second)

    {_n, _} =
      Repo.update_all(from(c in Client, where: c.kind == "cimd"),
        set: [metadata_expires_at: past]
      )
  end

  # The document now names another redirect and another name; the cache ran out, and a second
  # authorization request (for the new redirect) made the server read it again.
  defp change_document_and_refetch!(challenge) do
    Stub.put(
      @claude,
      Stub.claude_document()
      |> Map.put("redirect_uris", ["https://claude.ai/moved"])
      |> Map.put("client_name", "Somebody else")
    )

    expire_cache!()
    moved = %{client_id: @claude, redirect_uris: ["https://claude.ai/moved"]}
    assert authorize(browser(), authorize_params(moved, challenge)).status == 302
    assert length(Stub.calls(@claude)) == 2
  end

  defp page_error?(conn) do
    assert conn.status == 400
    assert get_resp_header(conn, "location") == []
    conn.resp_body
  end

  describe "a valid request of the two live clients" do
    test "Claude: stored on the server, the consent URL leads to a page built from the document",
         %{
           user: user,
           challenge: challenge
         } do
      conn = authorize(browser(), authorize_params(claude(), challenge, %{"scope" => nil}))
      assert conn.status == 302
      id = consent_id(conn)

      assert %Request{client_snapshot: snapshot} = Repo.one(Request)
      assert snapshot["client_id"] == @claude
      assert snapshot["client_name"] == "Claude"
      assert snapshot["redirect_uris"] == [@claude_redirect]

      html = consent(browser(user), id).resp_body |> Floki.parse_document!()
      assert Floki.find(html, "#consent-title") |> Floki.text() =~ "Claude"
      assert Floki.find(html, "#consent-host") |> Floki.text() |> String.trim() == "claude.ai"
      assert [_] = Floki.find(html, "#consent-unverified")
      assert Floki.find(html, "#consent-client-address") |> Floki.text() =~ "claude.ai"
      assert [] = Floki.find(html, "#consent-loopback")
    end

    test "ChatGPT (private_key_jwt, jwks_uri): the same, and no logo is shown", %{
      user: user,
      challenge: challenge
    } do
      conn = authorize(browser(), authorize_params(chatgpt(), challenge, %{"scope" => nil}))
      assert conn.status == 302

      page = consent(browser(user), consent_id(conn))
      html = Floki.parse_document!(page.resp_body)

      assert Floki.find(html, "#consent-title") |> Floki.text() =~ "ChatGPT"
      assert Floki.find(html, "#consent-host") |> Floki.text() |> String.trim() == "chatgpt.com"
      assert [] = Floki.find(html, "img")
      refute page.resp_body =~ "logo.png"
    end

    test "a pre-registered client's page has no unverified-name notice", %{
      user: user,
      challenge: challenge
    } do
      client = client!()
      conn = authorize(browser(), authorize_params(client, challenge))
      html = consent(browser(user), consent_id(conn)).resp_body |> Floki.parse_document!()

      assert [] = Floki.find(html, "#consent-unverified")
      assert [] = Floki.find(html, "#consent-client-address")
    end

    test "a request whose snapshot names no kind is shown as unverified, not as trusted", %{
      user: user,
      challenge: challenge
    } do
      id = browser() |> authorize(authorize_params(claude(), challenge)) |> consent_id()

      request = Repo.one(Request)
      snapshot = Map.delete(request.client_snapshot, "kind")
      request |> Ecto.Changeset.change(client_snapshot: snapshot) |> Repo.update!()

      html = consent(browser(user), id).resp_body |> Floki.parse_document!()
      assert [_] = Floki.find(html, "#consent-unverified")
    end

    test "the name on the page is the document's own text, escaped and cut", %{
      user: user,
      challenge: challenge
    } do
      name = "<script>alert(1)</script>" <> String.duplicate("x", 200)
      Stub.put(@claude, Map.put(Stub.claude_document(), "client_name", name))

      conn = authorize(browser(), authorize_params(claude(), challenge))
      page = consent(browser(user), consent_id(conn))

      refute page.resp_body =~ "<script>alert"
      assert page.resp_body =~ "&lt;script&gt;"

      title =
        page.resp_body |> Floki.parse_document!() |> Floki.find("#consent-title") |> Floki.text()

      refute String.length(title) > 160
    end

    test "a name of combining marks does not break the store: it is cut by code points", %{
      challenge: challenge
    } do
      name = String.duplicate("a\u0301\u0302\u0303", 160)
      Stub.put(@claude, Map.put(Stub.claude_document(), "client_name", name))

      assert authorize(browser(), authorize_params(claude(), challenge)).status == 302

      assert %Client{client_name: stored} = Repo.get_by(Client, client_id: @claude)
      assert length(String.codepoints(stored)) <= 160
      assert String.starts_with?(stored, "a\u0301")
    end

    test "the person allows, the client gets a code, and the token endpoint takes the URL id", %{
      user: user,
      challenge: _challenge
    } do
      flow = code_for(user, claude(), [@read])
      assert String.starts_with?(location_for(flow), @claude_redirect)

      conn = exchange_code(flow)
      assert conn.status == 200
      assert %{"access_token" => "pkoa_" <> _, "refresh_token" => "pkor_" <> _} = body(conn)

      # The token endpoint never fetches: the client is the row that is already there.
      assert length(Stub.calls(@claude)) == 1
    end
  end

  defp location_for(%{redirect_uri: uri}), do: uri

  describe "the redirect URI is the document's, compared exactly" do
    test "any other URI is an error page, never a redirect", %{challenge: challenge} do
      for uri <- [
            "https://claude.ai/api/mcp/auth_callback/",
            "https://claude.ai/api/mcp/auth_callback?x=1",
            "https://claude.ai/api/mcp/other",
            "https://www.claude.ai/api/mcp/auth_callback",
            "http://claude.ai/api/mcp/auth_callback",
            "https://evil.example/api/mcp/auth_callback",
            "https://claude.ai:8443/api/mcp/auth_callback",
            "https://claude.ai/api/mcp/auth_callback#frag",
            "https://user@claude.ai/api/mcp/auth_callback",
            "cursor://anysphere.cursor-retrieval/oauth"
          ] do
        params = authorize_params(claude(), challenge, %{"redirect_uri" => uri})
        page_error?(authorize(browser(), params))
      end

      assert Repo.aggregate(Request, :count) == 0
    end

    test "the page of a foreign redirect is the page of an unknown client", %{
      challenge: challenge
    } do
      foreign =
        authorize(
          browser(),
          authorize_params(claude(), challenge, %{"redirect_uri" => "https://x.example/cb"})
        )

      Stub.put("https://nobody.example/c.json", {:error, {:http_status, 404}})

      unknown =
        authorize(
          browser(),
          authorize_params(
            %{
              client_id: "https://nobody.example/c.json",
              redirect_uris: ["https://x.example/cb"]
            },
            challenge
          )
        )

      assert page_error?(foreign) == page_error?(unknown)
    end

    test "a loopback redirect from the document may take another port", %{challenge: challenge} do
      Stub.put(
        @claude,
        Map.put(Stub.claude_document(), "redirect_uris", [
          "http://127.0.0.1/callback",
          @claude_redirect
        ])
      )

      params =
        authorize_params(claude(), challenge, %{
          "redirect_uri" => "http://127.0.0.1:53124/callback"
        })

      assert authorize(browser(), params).status == 302
    end

    test "an error after the redirect is confirmed goes to that redirect with state and iss", %{
      challenge: challenge
    } do
      params =
        authorize_params(claude(), challenge, %{
          "code_challenge_method" => "plain",
          "state" => "abc"
        })

      conn = authorize(browser(), params)
      assert conn.status == 302
      assert String.starts_with?(location(conn), @claude_redirect <> "?")
      assert %{"error" => "invalid_request", "state" => "abc", "iss" => _} = location_params(conn)
    end
  end

  describe "a document that changes" do
    test "between authorize and token changes nothing for that request", %{
      user: user,
      challenge: challenge
    } do
      {verifier, challenge_a} = pkce()
      params_a = authorize_params(claude(), challenge_a)
      id_a = browser() |> authorize(params_a) |> consent_id()

      change_document_and_refetch!(challenge)

      # The row is the new one now: a second request is the proof the document was read again.
      assert %Client{redirect_uris: ["https://claude.ai/moved"], client_name: "Somebody else"} =
               Repo.get_by(Client, client_id: @claude)

      # Request A still holds the document it was made from: the person allows it ...
      answer =
        decide(browser(user), id_a, %{
          "decision" => "allow",
          "scopes" => [@read],
          "days" => "30"
        })

      assert answer.status == 302
      assert String.starts_with?(location(answer), @claude_redirect <> "?")
      %{"code" => code} = location_params(answer)

      # ... and the code is exchanged for the very redirect it was asked for.
      flow = %{
        code: code,
        verifier: verifier,
        client: claude(),
        redirect_uri: params_a["redirect_uri"]
      }

      conn = exchange_code(flow)
      assert conn.status == 200
      assert %{"access_token" => "pkoa_" <> _} = body(conn)
    end

    test "while the consent page is open it keeps the name and address it was made with", %{
      user: user,
      challenge: challenge
    } do
      {_verifier, challenge_a} = pkce()
      id_a = browser() |> authorize(authorize_params(claude(), challenge_a)) |> consent_id()

      change_document_and_refetch!(challenge)

      page = consent(browser(user), id_a)
      assert page.status == 200
      html = Floki.parse_document!(page.resp_body)
      assert Floki.find(html, "#consent-title") |> Floki.text() =~ "Claude"
      refute page.resp_body =~ "Somebody else"
      assert Floki.find(html, "#consent-host") |> Floki.text() |> String.trim() == "claude.ai"
    end

    test "after the cache runs out a new request is judged by the new document", %{
      challenge: challenge
    } do
      assert authorize(browser(), authorize_params(claude(), challenge)).status == 302

      Stub.put(
        @claude,
        Map.put(Stub.claude_document(), "redirect_uris", ["https://claude.ai/moved"])
      )

      # Still the cached document until it expires.
      assert authorize(browser(), authorize_params(claude(), challenge)).status == 302

      expire_cache!()
      page_error?(authorize(browser(), authorize_params(claude(), challenge)))

      moved = %{client_id: @claude, redirect_uris: ["https://claude.ai/moved"]}
      assert authorize(browser(), authorize_params(moved, challenge)).status == 302
    end
  end

  describe "what is refused looks the same" do
    test "a document that cannot be had, a secret in it, a mismatch, a denied host", %{
      challenge: challenge
    } do
      bodies =
        for setup <- [
              fn -> Stub.put(@claude, {:error, :blocked_host}) end,
              fn -> Stub.put(@claude, Map.put(Stub.claude_document(), "client_secret", "s")) end,
              fn ->
                Stub.put(
                  @claude,
                  Map.put(Stub.claude_document(), "client_id", "https://evil.example/x")
                )
              end,
              fn -> Stub.put(@claude, Map.put(Stub.claude_document(), "redirect_uris", [])) end,
              fn ->
                Stub.put(@claude, Stub.claude_document())
                put_setting("api_oauth_client_deny_hosts", "claude.ai")
              end
            ] do
          setup.()
          conn = authorize(browser(), authorize_params(claude(), challenge))
          page_error?(conn)
        end

      assert [_] = Enum.uniq(bodies)
      assert Repo.aggregate(Client, :count) == 0
    end

    test "an identifier of the wrong form is never fetched", %{challenge: challenge} do
      for id <- [
            "http://claude.ai/x",
            "https://claude.ai",
            "https://claude.ai/a/../b",
            "https://claude.ai/x#f"
          ] do
        page_error?(
          authorize(
            browser(),
            authorize_params(%{client_id: id, redirect_uris: [@claude_redirect]}, challenge)
          )
        )
      end

      assert Stub.calls() == []
    end
  end

  describe "the limits" do
    test "too many fetches of one client in a minute: 429 and a page", %{challenge: challenge} do
      put_setting("api_oauth_cimd_client_per_min", 1)
      Stub.put(@claude, {:error, {:http_status, 500}})

      assert page_error?(authorize(browser(), authorize_params(claude(), challenge)))

      conn = authorize(browser(), authorize_params(claude(), challenge))
      assert conn.status == 429
      assert [_] = get_resp_header(conn, "retry-after")
      assert length(Stub.calls(@claude)) == 1
    end

    test "too many fetches from one network in a minute: 429 and retry-after 60", %{
      challenge: challenge
    } do
      put_setting("api_oauth_cimd_per_min", 1)
      ip = unique_ip()
      first = "https://client.example/ip-#{System.unique_integer([:positive])}"
      second = "https://client.example/ip-#{System.unique_integer([:positive])}"
      Stub.put(first, {:error, {:http_status, 500}})

      from_ip = fn id ->
        conn = build_conn() |> ApiHarness.with_client_ip(ip)
        params = %{client_id: id, redirect_uris: ["https://client.example/cb"]}
        authorize(conn, authorize_params(params, challenge))
      end

      assert page_error?(from_ip.(first))

      conn = from_ip.(second)
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]
      assert Stub.calls(second) == []
    end

    test "four fetches already running: 503 and retry-after 5, nothing fetched", %{
      challenge: challenge
    } do
      test_pid = self()

      blocking = fn _opts ->
        send(test_pid, {:started, self()})

        receive do
          :go -> {:error, {:http_status, 500}}
        end
      end

      urls =
        for n <- 1..5,
            do: "https://client.example/busy-#{n}-#{System.unique_integer([:positive])}"

      for url <- urls, do: Stub.put(url, blocking)

      tasks =
        for url <- Enum.take(urls, 4) do
          task = Task.async(fn -> Clients.resolve(url, ip: unique_ip()) end)
          assert_receive {:started, _pid}, 2_000
          task
        end

      fifth = List.last(urls)
      params = %{client_id: fifth, redirect_uris: ["https://client.example/cb"]}
      conn = authorize(browser(), authorize_params(params, challenge))

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]
      assert Stub.calls(fifth) == []

      for pid <- Task.Supervisor.children(PhoenixKit.API.OAuth.FetchSupervisor),
          do: send(pid, :go)

      assert Enum.map(tasks, &Task.await/1) == List.duplicate({:error, :fetch_failed}, 4)
    end

    test "a stored client costs no fetch and no limit", %{challenge: challenge} do
      put_setting("api_oauth_cimd_client_per_min", 1)

      for _n <- 1..3 do
        assert authorize(browser(), authorize_params(claude(), challenge)).status == 302
      end

      assert length(Stub.calls(@claude)) == 1
    end
  end

  describe "the switch" do
    test "with OAuth off nothing is fetched", %{challenge: challenge} do
      put_setting("api_oauth_enabled", "false")

      assert authorize(browser(), authorize_params(claude(), challenge)).status == 404
      assert Stub.calls() == []
    end
  end
end
