defmodule PhoenixKit.API.OAuth.BodyGuardTest do
  @moduledoc """
  `PhoenixKit.API.BodyGuard` on the authorization server's endpoints: the per-path table, the
  switch (`api_oauth_enabled`, not an audience's), the two decoding modes, the 16 KB limit and
  the RFC 6749 shape of every refusal.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.OAuthTestSupport, only: [enable_oauth!: 0]
  import PhoenixKit.Test.ApiHarness, only: [switch: 2]
  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.API.BodyGuard
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Utils.Routes

  @max 16_384

  setup do
    KeyTestSupport.start_cache_registry!()
    enable_oauth!()
  end

  defp oauth_path(name), do: Routes.prefix_base() <> "/oauth/" <> name

  defp run(method, path, body, headers \\ []) do
    conn = conn(method, path, body)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)

    BodyGuard.call(conn, BodyGuard.init([]))
  end

  defp form(path, body),
    do: run(:post, path, body, [{"content-type", "application/x-www-form-urlencoded"}])

  defp refusal(conn) do
    assert conn.halted
    assert conn.status == 400
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert ["no-store"] = get_resp_header(conn, "cache-control")
    assert ["no-cache"] = get_resp_header(conn, "pragma")
    body = JSON.decode!(conn.resp_body)
    assert body["error"] == "invalid_request"
    body
  end

  describe "the table" do
    test "/token and /revoke are form paths, /register a JSON path, nothing else is guarded" do
      for name <- ~w(token revoke register) do
        assert BodyGuard.oauth_guarded?(conn(:post, oauth_path(name), ""))
      end

      for name <- ~w(authorize consent token/extra tokens) do
        refute BodyGuard.oauth_guarded?(conn(:post, oauth_path(name), "")), name
      end

      refute BodyGuard.oauth_guarded?(conn(:post, "/oauth/token-not", ""))
    end

    test "guarded?/1 stays about the machine API" do
      refute BodyGuard.guarded?(conn(:post, oauth_path("token"), ""))
    end

    test "path segments are percent-decoded before they are matched" do
      conn = form(Routes.prefix_base() <> "/oauth/%74oken", "grant_type=refresh_token")
      assert conn.body_params == %{"grant_type" => "refresh_token"}
      assert BodyGuard.oauth_guarded?(conn(:post, Routes.prefix_base() <> "/%6Fauth/%74oken", ""))
    end

    test "a path with a malformed escape matches nothing and crashes nothing" do
      refute BodyGuard.oauth_guarded?(conn(:post, oauth_path("to%zzken"), ""))
    end
  end

  describe "form mode (/oauth/token, /oauth/revoke)" do
    test "decodes the body into params and body_params, and only the body" do
      for name <- ~w(token revoke) do
        conn =
          form(
            oauth_path(name) <> "?code=from_query",
            "grant_type=authorization_code&code=abc&state=%C3%B5"
          )

        refute conn.halted

        assert conn.body_params == %{
                 "grant_type" => "authorization_code",
                 "code" => "abc",
                 "state" => "õ"
               }

        assert conn.params == conn.body_params
      end
    end

    test "a repeated parameter, or one written as a list or a map, is refused" do
      for name <- ~w(token revoke),
          body <- [
            "code=a&code=b",
            "a=1&b=2&a=3",
            "code[]=a",
            "code[]=a&code[]=b",
            "code[x]=a",
            "a&a"
          ] do
        refusal(form(oauth_path(name), body))
      end

      for body <- ["a=1&&b=2", "a=1&b", "a=&b=", "a=1&b=1"] do
        refute form(oauth_path("token"), body).halted, body
      end
    end

    test "ignores what the content-type says" do
      conn = run(:post, oauth_path("token"), "a=1", [{"content-type", "application/json"}])
      assert conn.body_params == %{"a" => "1"}
    end

    test "an empty or blank body is %{}" do
      assert form(oauth_path("token"), "").body_params == %{}
      assert form(oauth_path("token"), "  \n").body_params == %{}
    end

    test "a body of exactly the limit passes, one byte more is refused" do
      pad = String.duplicate("a", @max - String.length("k="))
      assert %{"k" => ^pad} = form(oauth_path("token"), "k=" <> pad).body_params

      body = refusal(form(oauth_path("token"), "k=" <> pad <> "a"))
      assert body["error_description"] =~ "too large"
    end

    test "a declared length over the limit is refused without reading" do
      conn =
        conn(:post, oauth_path("token"), "a=1")
        |> put_req_header("content-length", Integer.to_string(@max + 1))
        |> BodyGuard.call(BodyGuard.init([]))

      refusal(conn)
    end

    test "a body of 2 MB is refused, not read to the end by Plug.Parsers" do
      refusal(form(oauth_path("token"), "k=" <> String.duplicate("a", 2_000_000)))
    end

    test "invalid UTF-8 is refused, raw or percent-encoded" do
      refusal(form(oauth_path("token"), "a=" <> <<0xFF, 0xFE>>))
      refusal(form(oauth_path("token"), "a=%FF%FE"))
    end

    test "the host's Plug.Parsers, which runs next, merges the query string into params" do
      conn =
        form(oauth_path("token") <> "?code=from_query", "grant_type=refresh_token&code=from_body")

      # What a controller sees: `params` carries the query too, `body_params` the body only.
      parsed = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded]))

      assert parsed.body_params == %{"grant_type" => "refresh_token", "code" => "from_body"}
      assert parsed.params["code"] == "from_body"
      assert parsed.query_params == %{"code" => "from_query"}

      query_only = form(oauth_path("token") <> "?code=from_query", "")
      parsed = Plug.Parsers.call(query_only, Plug.Parsers.init(parsers: [:urlencoded]))
      assert parsed.body_params == %{}
      assert parsed.params["code"] == "from_query"
    end

    test "a malformed escape is accepted and kept as it was sent, as Plug.Parsers reads it" do
      conn = form(oauth_path("token"), "a=%zz")

      refute conn.halted
      assert conn.status == nil
      assert conn.body_params == %{"a" => "%zz"}
    end

    test "the refusal never repeats the body" do
      body = refusal(form(oauth_path("token"), "code=SECRETCODE&a=%FF"))
      refute inspect(body) =~ "SECRETCODE"
    end

    test "GET and other methods that carry no body pass untouched" do
      conn = run(:get, oauth_path("token"), nil)
      refute conn.halted
      assert match?(%Plug.Conn.Unfetched{}, conn.body_params)
    end
  end

  describe "JSON mode (/oauth/register)" do
    defp json_post(body),
      do: run(:post, oauth_path("register"), body, [{"content-type", "application/json"}])

    test "decodes a JSON object" do
      conn = json_post(~s({"client_name":"x","redirect_uris":["https://c.example/cb"]}))

      assert conn.body_params == %{
               "client_name" => "x",
               "redirect_uris" => ["https://c.example/cb"]
             }

      assert conn.params == conn.body_params
    end

    test "an empty body is %{}" do
      assert json_post("").body_params == %{}
    end

    test "anything that is not a JSON object is refused" do
      for body <- [
            "[1,2]",
            "3",
            ~s("s"),
            "{",
            "not json",
            ~s({"a":1}x),
            "9" <> String.duplicate("9", 100_000)
          ] do
        refusal(json_post(body))
      end
    end

    test "over 16 KB is refused" do
      refusal(json_post(~s({"client_name":") <> String.duplicate("x", @max) <> ~s("})))
    end
  end

  describe "the switch" do
    test "OAuth off: the body is never read, params are %{}, and nothing is refused" do
      switch(:admin, false)
      huge = String.duplicate("a", 100_000)

      for name <- ~w(token revoke register) do
        conn = form(oauth_path(name), huge <> "=%FF")
        refute conn.halted
        assert conn.body_params == %{}
        assert conn.params == %{}
      end
    end

    test "the admin API off switches OAuth off with it" do
      switch(:admin, false)
      conn = form(oauth_path("token"), "a=1")
      assert conn.body_params == %{}
    end

    test "a body already parsed is left alone" do
      conn = %{conn(:post, oauth_path("token"), "a=1") | body_params: %{"x" => "y"}}
      assert BodyGuard.call(conn, BodyGuard.init([])).body_params == %{"x" => "y"}
    end
  end
end
