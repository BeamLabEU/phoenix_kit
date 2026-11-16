defmodule PhoenixKit.API.AuthTest do
  @moduledoc """
  `PhoenixKit.API.Auth`: the API switch, the credential-in-URL refusal, bearer
  parsing, key verification and the failed-authentication throttle.

  Plug level, against the real database, real keys and the real rate limiter.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.Test.ApiHarness
  import Plug.Conn

  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Keys
  alias PhoenixKit.Users.Auth, as: UsersAuth
  alias PhoenixKit.Users.Permissions

  @read_scope "testkit.items:read"

  setup do
    setup_api()
    {owner, role} = user_with(["dashboard"])
    {key, token} = issue_key(owner, [@read_scope])
    %{owner: owner, role: role, key: key, token: token}
  end

  defp admin(conn), do: Auth.call(conn, Auth.init(audience: :admin))
  defp public(conn), do: Auth.call(conn, Auth.init(audience: :public))

  describe "init/1" do
    test "requires a known audience" do
      assert [audience: :admin] = Auth.init(audience: :admin)
      assert_raise ArgumentError, fn -> Auth.init(audience: :other) end
      assert_raise KeyError, fn -> Auth.init([]) end
    end
  end

  describe "a valid key" do
    test "assigns the actor and a request id", %{token: token, key: key, owner: owner} do
      conn = :post |> api_conn("/x", token: token) |> admin()

      refute conn.halted

      assert %Actor{kind: :key, key_prefix: prefix, user_uuid: user_uuid, ip: ip} =
               conn.assigns.phoenix_kit_api_actor

      assert prefix == key.prefix
      assert user_uuid == owner.uuid
      assert is_binary(ip)
      assert is_binary(conn.assigns.phoenix_kit_api_request_id)
      assert get_resp_header(conn, "x-request-id") == [conn.assigns.phoenix_kit_api_request_id]
    end

    test "reuses the x-request-id that Plug.RequestId already set", %{token: token} do
      conn =
        :post
        |> api_conn("/x", token: token)
        |> put_resp_header("x-request-id", "req-from-the-endpoint")
        |> admin()

      assert conn.assigns.phoenix_kit_api_request_id == "req-from-the-endpoint"
    end

    test "replaces an inbound x-request-id that holds characters outside the URL-safe set",
         %{token: token} do
      for bad <- ["req id with spaces and \e[31mcontrol", "req\"quote<b>aaaaaaaaaaaa", ""] do
        conn =
          :post
          |> api_conn("/x", token: token)
          |> put_resp_header("x-request-id", bad)
          |> admin()

        id = conn.assigns.phoenix_kit_api_request_id
        assert id != bad
        assert id =~ ~r/\A[A-Za-z0-9_-]+\z/
        assert get_resp_header(conn, "x-request-id") == [id]
      end
    end

    test "the scheme is case-insensitive", %{token: token} do
      conn =
        :post |> api_conn("/x") |> put_req_header("authorization", "bearer " <> token) |> admin()

      refute conn.halted
    end
  end

  describe "a bad Authorization header is a 401, never a 500" do
    test "empty, truncated, non-pk_ and wrong-scheme credentials", %{token: token} do
      [prefix_part | _] = String.split(token, "_", parts: 3) |> Enum.drop(1)

      headers = [
        "Bearer",
        "Bearer ",
        "Bearer    ",
        "Bearer pk_",
        "Bearer pk_#{prefix_part}",
        "Bearer pk_#{prefix_part}_",
        "Bearer pk_#{prefix_part}_short",
        "Bearer " <> String.slice(token, 0, 20),
        "Bearer not-a-key",
        "Bearer " <> String.replace_prefix(token, "pk_", "xx_"),
        "Basic " <> Base.encode64("user:pass"),
        "Token " <> token,
        token
      ]

      for header <- headers do
        conn = :post |> api_conn("/x") |> put_req_header("authorization", header) |> admin()

        assert conn.halted, header
        assert conn.status == 401, header
        assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
        assert %{"code" => "unauthorized", "status" => 401} = json(conn)
        assert [~s(Bearer error="invalid_token")] = get_resp_header(conn, "www-authenticate")
        refute Map.has_key?(conn.assigns, :phoenix_kit_api_actor)
      end
    end

    test "no header at all, and two headers" do
      assert 401 == (:post |> api_conn("/x") |> admin()).status

      conn =
        %{
          api_conn(:post, "/x")
          | req_headers: [{"authorization", "Bearer a"}, {"authorization", "Bearer b"}]
        }
        |> admin()

      assert conn.status == 401
    end

    test "an unknown but well-formed key and a wrong secret look the same", %{key: key} do
      unknown =
        :post |> api_conn("/x", token: "pk_00000000_" <> String.duplicate("a", 43)) |> admin()

      wrong =
        :post
        |> api_conn("/x", token: "pk_#{key.prefix}_" <> String.duplicate("a", 43))
        |> admin()

      assert unknown.status == 401
      assert wrong.status == 401
      assert json(unknown)["detail"] == json(wrong)["detail"]
    end
  end

  describe "an unexpected exception during authentication" do
    test "is a generic 500 problem with the request id; the log names the exception and the request, not its message",
         %{token: token, key: key} do
      # A struct that is not a key row makes `Keys.verify/2` raise `KeyError` on
      # every Elixir version (a bare binary raises `BadMapError` on 1.19 and
      # `KeyError` on 1.18). Wait for the cache process to drain its
      # invalidation messages first.
      _ = :sys.get_state(Keys.Cache)
      :ok = PhoenixKit.Cache.put(:api_keys, key.prefix, %URI{path: "secret-cache-detail"})

      log =
        capture_log(fn ->
          send(self(), {:conn, :post |> api_conn("/x", token: token) |> admin()})
        end)

      assert_received {:conn, conn}

      assert conn.halted
      assert conn.status == 500
      assert %{"code" => "internal_error", "request_id" => request_id} = json(conn)
      assert request_id == conn.assigns.phoenix_kit_api_request_id
      refute conn.resp_body =~ "secret-cache-detail"
      refute Map.has_key?(conn.assigns, :phoenix_kit_api_actor)

      assert log =~ "authentication failed unexpectedly"
      assert log =~ request_id
      assert log =~ "KeyError"
      refute log =~ "secret-cache-detail"
      refute log =~ token
    end
  end

  describe "a key stops working when its owner changes" do
    test "a blocked owner, with the key row still cached", %{
      token: token,
      key: key,
      owner: owner
    } do
      assert :post |> api_conn("/x", token: token) |> admin() |> Map.fetch!(:halted) == false
      assert_row_cached(key.prefix)

      {:ok, _} = UsersAuth.update_user_status(owner, %{"is_active" => false})
      assert_row_cached(key.prefix)

      conn = :post |> api_conn("/x", token: token) |> admin()
      assert conn.status == 401
      assert json(conn)["code"] == "unauthorized"
    end

    test "a deleted owner, with the key row still cached", %{
      token: token,
      key: key,
      owner: owner
    } do
      refute (:post |> api_conn("/x", token: token) |> admin()).halted
      assert_row_cached(key.prefix)

      {:ok, _} = UsersAuth.delete_user(owner, %{current_user: owner_user()})
      assert_row_cached(key.prefix)

      assert 401 == (:post |> api_conn("/x", token: token) |> admin()).status
    end
  end

  describe "a credential in the URL" do
    test "is refused with 400 token_in_url before the key is looked at", %{token: token} do
      queries = [
        "?api_key=x",
        "?token=x",
        "?access_token=x",
        "?session_token=x",
        "?cart_token=x",
        "?refresh_token=x",
        "?Session_Token=x",
        "?secret=x",
        "?confirm_token=x",
        "?API_KEY=x",
        "?api_key[]=x",
        "?%61pi_key=x",
        "?anything=pk_abcdef01_whatever",
        "?filter[x]=pk_abcdef01_whatever",
        "?apikey=x",
        "?api-key=x",
        "?authorization=x",
        "?bearer=x",
        "?x=PK_abcdef01_whatever",
        "?x=%20pk_abcdef01_whatever",
        "?q=1&token=" <> token
      ]

      for query <- queries do
        # Even with a perfectly valid key in the header.
        conn = :post |> api_conn("/x" <> query, token: token) |> admin()

        assert conn.halted, query
        assert conn.status == 400, query
        assert %{"code" => "token_in_url"} = json(conn)
        refute Map.has_key?(conn.assigns, :phoenix_kit_api_actor)
      end
    end

    test "says the Authorization header for the admin audience", %{token: token} do
      conn = :post |> api_conn("/x?api_key=x", token: token) |> admin()

      assert json(conn)["detail"] ==
               "Credentials must be sent in the Authorization header, never in the URL."
    end

    test "an ordinary query string passes", %{token: token} do
      conn = :post |> api_conn("/x?limit=5&q=pkg_name&note=pk", token: token) |> admin()
      refute conn.halted
    end

    test "a name that only resembles a credential passes", %{token: token} do
      conn =
        :post
        |> api_conn("/x?token_count=5&tokens_issued=1&session-token=x", token: token)
        |> admin()

      refute conn.halted
    end

    test "the OAuth grant parameters are not credentials: ?code= stays a plain filter on REST", %{
      token: token
    } do
      query = "?code=ABC&code_verifier=zzz&postal_code=1&q=pkoa"
      conn = :post |> api_conn("/x" <> query, token: token) |> admin()

      refute conn.halted
      refute Auth.token_in_url?(conn)

      for name <- ~w(code code_verifier postal_code state redirect_uri),
          do: refute(Auth.credential_name?(name), name)

      refute "code" in Auth.credential_params()
    end

    test "credential_name?/1 is the one rule: the listed names and any name ending in _token" do
      for name <- Auth.credential_params(), do: assert(Auth.credential_name?(name), name)

      for name <- ~w(session_token SESSION_TOKEN page_token _token),
          do: assert(Auth.credential_name?(name), name)

      for name <- ~w(token_count tokens session-token tok limit),
          do: refute(Auth.credential_name?(name), name)

      refute Auth.credential_name?(nil)
    end

    test "credential_params/0 keeps the names that feed the log filter" do
      assert ~w(api_key apikey api-key authorization bearer access_token token confirm_token secret) --
               Auth.credential_params() == []
    end

    test "the token never reaches the log, on any path", %{token: token, owner: owner} do
      secret = token |> String.split("_", parts: 3) |> List.last()

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      # `Plug.Logger` stands in for the endpoint's request log: it prints
      # `GET /x` and `Sent <status> in <time>` around every request, so there
      # is a log line for the assertions to look at.
      logged = fn conn ->
        conn |> Plug.Logger.call(Plug.Logger.init([])) |> admin()
      end

      log =
        capture_log([level: :debug], fn ->
          logged.(api_conn(:post, "/x", token: token))
          logged.(api_conn(:post, "/x?token=" <> token, token: token))
          logged.(api_conn(:post, "/x", token: token <> "x"))
          logged.(api_conn(:post, "/x", token: String.slice(token, 0, 12)))

          {:ok, _} = UsersAuth.update_user_status(owner, %{"is_active" => false})
          logged.(api_conn(:post, "/x", token: token))
        end)

      # The capture saw log lines (so the refutations look at something):
      # the `400 token_in_url` and the three `401` answers. The successful
      # request sends no response in this test, so it prints no `Sent` line.
      assert log =~ "Sent 400"
      assert length(String.split(log, "Sent 401")) - 1 == 3

      refute log =~ secret
      refute log =~ token
    end
  end

  describe "the API switch" do
    test "off: a bare 404 problem, for either audience, key or no key", %{token: token} do
      switch(:admin, false)
      switch(:public, false)

      # A credential in the URL must not unmask the endpoint either: the
      # switch is checked before the URL is looked at.
      queries = ["", "?api_key=x", "?token=pk_abc"]

      for {plug, opts} <- [{&admin/1, [token: token]}, {&admin/1, []}, {&public/1, []}],
          query <- queries do
        conn = :post |> api_conn("/x" <> query, opts) |> plug.()

        assert conn.halted
        assert conn.status == 404
        assert %{"code" => "not_found", "detail" => ""} = json(conn)
        refute Map.has_key?(conn.assigns, :phoenix_kit_api_actor)
      end
    end

    test "each audience has its own switch", %{token: token} do
      switch(:public, false)
      refute (:post |> api_conn("/x", token: token) |> admin()).halted
      assert 404 == (:post |> api_conn("/x") |> public()).status

      switch(:public, true)
      switch(:admin, false)
      assert 404 == (:post |> api_conn("/x", token: token) |> admin()).status
      refute (:post |> api_conn("/x") |> public()).halted
    end

    test "off costs no database query once the settings cache is warm" do
      # `setup_api/1` already started `PhoenixKit.Cache.Registry` (with the key
      # cache); starting it again raises. Only the settings cache is new here,
      # and it needs a child id of its own (the key cache uses the default one).
      start_supervised!(
        Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
      )

      switch(:admin, false)
      PhoenixKit.Cache.invalidate_now(:settings, ["api_admin_enabled"])

      # One call warms the cache with the setting.
      assert 404 == (:post |> api_conn("/x") |> admin()).status

      counter = :counters.new(1, [])
      test_pid = self()
      handler = "api-auth-query-count-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:phoenix_kit, :test, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: :counters.add(counter, 1, 1)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert 404 == (:post |> api_conn("/x") |> admin()).status
      assert 404 == (:post |> api_conn("/x", token: "Bearer anything") |> admin()).status
      assert :counters.get(counter, 1) == 0
    end
  end

  describe "the public audience" do
    test "needs no key: an anonymous actor with the client address" do
      conn = :post |> api_conn("/x", ip: "198.51.100.7") |> public()

      refute conn.halted

      assert %Actor{kind: :anonymous, ip: "198.51.100.7", key_uuid: nil} =
               conn.assigns.phoenix_kit_api_actor
    end

    test "ignores an Authorization header, and still refuses a credential in the URL", %{
      token: token
    } do
      conn = :post |> api_conn("/x", token: "garbage") |> public()
      refute conn.halted

      conn = :post |> api_conn("/x?session_token=abc") |> public()
      assert conn.status == 400
      assert json(conn)["code"] == "token_in_url"
      _ = token
    end

    test "tells a public caller to send a credential or client token in the request body" do
      queries = [
        "?session_token=abc",
        "?confirm_token=abc",
        "?api_key=abc",
        "?token=abc",
        "?x=pk_abcdef01_whatever"
      ]

      for query <- queries do
        conn = :post |> api_conn("/x" <> query) |> public()

        assert conn.status == 400, query

        assert json(conn)["detail"] ==
                 "Credentials and client tokens must be sent in the request body, never in the URL.",
               query
      end
    end
  end

  describe "a key used from the wrong address" do
    test "is 403 ip_not_allowed" do
      {owner, _role} = user_with(["dashboard"])
      {_key, token} = issue_key(owner, [@read_scope], %{allowed_ips: ["203.0.113.0/24"]})

      allowed = :post |> api_conn("/x", token: token, ip: "203.0.113.9") |> admin()
      refute allowed.halted

      denied = :post |> api_conn("/x", token: token, ip: "198.51.100.9") |> admin()
      assert denied.status == 403
      assert json(denied)["code"] == "ip_not_allowed"
    end
  end

  describe "the failed-authentication throttle spares a valid key" do
    test "an exhausted IP gets 429 for bad keys and 200 for the good one", %{token: token} do
      put_setting("api_admin_preauth_fail_per_min", 3)
      ip = unique_ip()
      bad = "pk_00000000_" <> String.duplicate("b", 43)

      statuses =
        for _ <- 1..6 do
          (:post |> api_conn("/x", token: bad, ip: ip) |> admin()).status
        end

      # Failures are answered 401 until the IP's bucket (3) is used up, then
      # 429; the bad key is the same all along.
      assert hd(statuses) == 401
      assert List.last(statuses) == 429
      assert Enum.sort(Enum.uniq(statuses)) == [401, 429]
      assert statuses == Enum.sort_by(statuses, &(&1 == 429))

      throttled = :post |> api_conn("/x", token: bad, ip: ip) |> admin()
      assert json(throttled)["code"] == "rate_limited"
      assert [retry_after] = get_resp_header(throttled, "retry-after")
      assert String.to_integer(retry_after) > 0

      # The same IP, a valid key: not locked out.
      good = :post |> api_conn("/x", token: token, ip: ip) |> admin()
      refute good.halted
      assert %Actor{kind: :key} = good.assigns.phoenix_kit_api_actor
    end

    test "successful requests do not count against the bucket", %{token: token} do
      put_setting("api_admin_preauth_fail_per_min", 3)
      ip = unique_ip()

      for _ <- 1..10 do
        refute (:post |> api_conn("/x", token: token, ip: ip) |> admin()).halted
      end

      bad = "pk_00000000_" <> String.duplicate("b", 43)
      assert 401 == (:post |> api_conn("/x", token: bad, ip: ip) |> admin()).status
    end

    test "another IP is not throttled by this one's failures" do
      put_setting("api_admin_preauth_fail_per_min", 2)
      noisy = unique_ip()
      bad = "pk_00000000_" <> String.duplicate("b", 43)

      for _ <- 1..4, do: :post |> api_conn("/x", token: bad, ip: noisy) |> admin()

      assert 401 == (:post |> api_conn("/x", token: bad, ip: unique_ip()) |> admin()).status
    end
  end

  describe "an owner who lost a permission keeps a working key" do
    test "authentication passes; the scope is what disappears", %{
      token: token,
      role: role,
      key: key
    } do
      assert :ok = Permissions.revoke_permission(role.uuid, "dashboard")

      conn = :post |> api_conn("/x", token: token) |> admin()
      refute conn.halted

      assert [] == Keys.effective_scopes(conn.assigns.phoenix_kit_api_actor)
      assert key.prefix == conn.assigns.phoenix_kit_api_actor.key_prefix
    end
  end
end
