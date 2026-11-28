defmodule PhoenixKit.Plugs.RateLimitTest do
  @moduledoc """
  `PhoenixKit.Plugs.RateLimit`, the rate limit for the host's own routes: options checked
  at init, the per-key buckets, the `429` with `retry-after`, and failing open.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Plugs.RateLimit
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  defmodule Keys do
    @moduledoc false
    def tenant(conn), do: conn |> Plug.Conn.get_req_header("x-tenant") |> List.first()
    def raises(_conn), do: raise(ArgumentError, "secret-#{System.unique_integer()}")
    def odd(_conn), do: %{a: 1}
  end

  setup do
    KeyTestSupport.wait_for_window_room()
    %{bucket: "test_#{System.unique_integer([:positive])}"}
  end

  defp peer, do: {10, 77, rem(System.unique_integer([:positive]), 250), 1}

  defp request(opts, conn \\ nil) do
    conn = conn || %{conn(:get, "/thing") | remote_ip: peer()}
    RateLimit.call(conn, RateLimit.init(opts))
  end

  describe "init/1" do
    test "takes the documented shapes" do
      assert %{count: 60, scale: 60_000, cost: 1} =
               RateLimit.init(bucket: :api, key: :ip, limit: {60, :minute})

      assert %{scale: 1_500} = RateLimit.init(bucket: "x", key: :user, limit: {1, 1_500})
      assert %{key: fun} = RateLimit.init(bucket: :x, key: &Keys.tenant/1, limit: {1, :day})
      assert is_function(fun, 1)
    end

    test "refuses anything else at compile time" do
      bad = [
        [key: :ip, limit: {1, :minute}],
        [bucket: :x, key: :nope, limit: {1, :minute}],
        [bucket: :x, key: :ip, limit: {0, :minute}],
        [bucket: :x, key: :ip, limit: {1, :week}],
        [bucket: :x, key: :ip, limit: 5],
        [bucket: :x, key: :ip, limit: {1, :minute}, cost: 0],
        [bucket: nil, key: :ip, limit: {1, :minute}]
      ]

      for opts <- bad do
        assert_raise ArgumentError, ~r/PhoenixKit.Plugs.RateLimit/, fn -> RateLimit.init(opts) end
      end
    end
  end

  describe "call/2" do
    test "lets requests through up to the limit, with the headers", %{bucket: bucket} do
      opts = [bucket: bucket, key: :ip, limit: {2, :minute}]
      conn = %{conn(:get, "/thing") | remote_ip: peer()}

      first = request(opts, conn)
      refute first.halted
      assert get_resp_header(first, "ratelimit-limit") == ["2"]
      assert get_resp_header(first, "ratelimit-remaining") == ["1"]

      second = request(opts, conn)
      refute second.halted
      assert get_resp_header(second, "ratelimit-remaining") == ["0"]

      third = request(opts, conn)
      assert third.halted
      assert third.status == 429
      assert [retry] = get_resp_header(third, "retry-after")
      assert String.to_integer(retry) in 1..60
      assert third.resp_body == "Too Many Requests"
    end

    test "answers JSON to a JSON client", %{bucket: bucket} do
      opts = [bucket: bucket, key: :ip, limit: {1, :minute}]

      conn =
        %{conn(:get, "/thing") | remote_ip: peer()}
        |> put_req_header("accept", "application/json")

      request(opts, conn)
      denied = request(opts, conn)

      assert denied.status == 429
      assert %{"error" => "rate_limited", "retry_after" => n} = Jason.decode!(denied.resp_body)
      assert is_integer(n)
    end

    test "each address has its own bucket", %{bucket: bucket} do
      opts = [bucket: bucket, key: :ip, limit: {1, :minute}]
      refute request(opts).halted
      refute request(opts).halted
    end

    test "two buckets never share a counter", %{bucket: bucket} do
      conn = %{conn(:get, "/thing") | remote_ip: peer()}
      refute request([bucket: bucket, key: :ip, limit: {1, :minute}], conn).halted
      refute request([bucket: bucket <> "_other", key: :ip, limit: {1, :minute}], conn).halted
    end

    test ":user counts a signed-in user, and an anonymous visitor by network", %{bucket: bucket} do
      opts = [bucket: bucket, key: :user, limit: {1, :minute}]
      scope = %Scope{user: %User{uuid: UUIDv7.generate()}, authenticated?: true}

      signed_in = fn ->
        %{conn(:get, "/") | remote_ip: peer()} |> assign(:phoenix_kit_current_scope, scope)
      end

      refute request(opts, signed_in.()).halted
      # Another address, same user: the same bucket.
      assert request(opts, signed_in.()).halted

      anon = %{conn(:get, "/") | remote_ip: peer()}
      refute request(opts, anon).halted
    end

    test "a key function decides the bucket; nil lets the request through uncounted",
         %{bucket: bucket} do
      opts = [bucket: bucket, key: &Keys.tenant/1, limit: {1, :minute}]
      tenant = fn name -> conn(:get, "/") |> put_req_header("x-tenant", name) end

      refute request(opts, tenant.("a")).halted
      assert request(opts, tenant.("a")).halted
      refute request(opts, tenant.("b")).halted

      for _ <- 1..3, do: refute(request(opts, conn(:get, "/")).halted)
    end

    test "fails open, with a warning that holds no request data", %{bucket: bucket} do
      for fun <- [&Keys.raises/1, &Keys.odd/1] do
        log =
          capture_log(fn ->
            conn = request(bucket: bucket, key: fun, limit: {1, :minute})
            refute conn.halted
            assert conn.status == nil
          end)

        assert log =~ "the request was let through"
        refute log =~ "secret-"
      end
    end
  end
end
