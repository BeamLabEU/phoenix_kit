defmodule PhoenixKit.API.OAuth.AuthTest do
  @moduledoc """
  The resource side of OAuth in `PhoenixKit.API.Auth`, `PhoenixKit.API.Problem` and
  `PhoenixKit.API.MCP`, at plug level and against **seeded** grants: when a `pkoa_` token is
  taken (the admin MCP endpoint, OAuth switched on, and nowhere else), the challenge of every
  401, and the failure bucket that the ordinary steps of the OAuth cycle must not use up.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport, only: [wait_for_window_room: 0]
  import PhoenixKit.API.OAuthTestSupport
  import PhoenixKit.Test.ApiHarness
  import PhoenixKit.Test.McpHarness
  import Plug.Conn

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.RateLimit
  alias PhoenixKit.Users.Permissions

  @read "testkit.items:read"

  setup do
    setup_api()
    {holder, role, scope} = oauth_holder(["dashboard"])
    seed = seed_grant!(scope, scopes: [@read])
    %{holder: holder, role: role, scope: scope, seed: seed}
  end

  defp challenge(conn), do: conn |> get_resp_header("www-authenticate") |> List.first()
  defp metadata, do: ~s(resource_metadata="#{Resource.metadata_url()}")
  defp rest(conn), do: Auth.call(conn, Auth.init(audience: :admin))

  defp fail_limit(n), do: set_limit_setting("api_admin_preauth_fail_per_min", n)
  defp set_limit_setting(key, n), do: put_setting(key, n)

  describe "a valid OAuth token" do
    test "is taken on the admin MCP endpoint, with the scopes of its grant", %{seed: seed} do
      enable_oauth!()
      conn = post_rpc(:admin, message("tools/list"), token: seed.access)

      assert conn.status == 200
      assert "testkit_read_items" in tool_names(conn)
      refute "testkit_write_item" in tool_names(conn)
      assert %{kind: :key, key_uuid: key_uuid} = conn.assigns.phoenix_kit_api_actor
      assert key_uuid == seed.key.uuid
    end

    test "calls a tool its grant allows", %{seed: seed} do
      enable_oauth!()
      conn = post_rpc(:admin, call_message("testkit.read_items", %{}), token: seed.access)
      assert conn.status == 200
      refute result(conn)["isError"]
    end

    test "is not taken once its owner loses api_personal_keys", %{seed: seed, role: role} do
      enable_oauth!()
      :ok = Permissions.revoke_permission(role.uuid, "api_personal_keys")

      conn = post_rpc(:admin, message("tools/list"), token: seed.access)
      assert conn.status == 401
    end
  end

  describe "the switch" do
    test "OAuth off: a pkoa_ token is a token nobody can verify, with today's plain challenge", %{
      seed: seed
    } do
      switch(:admin, true)

      conn = post_rpc(:admin, message("tools/list"), token: seed.access)

      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer error="invalid_token")
      refute Map.has_key?(conn.private, :phoenix_kit_api_oauth_challenge)
    end

    test "OAuth off: no credentials is the plain challenge too" do
      switch(:admin, true)
      conn = post_rpc(:admin, message("tools/list"))
      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer error="invalid_token")
    end

    test "the admin API off: OAuth is off with it", %{seed: seed} do
      enable_oauth!()
      switch(:admin, false)

      conn = post_rpc(:admin, message("tools/list"), token: seed.access)
      assert conn.status == 404
    end
  end

  describe "where a pkoa_ token is taken" do
    setup do
      enable_oauth!()
    end

    test "never on the REST admin endpoint", %{seed: seed} do
      conn = :post |> api_conn("/x", token: seed.access) |> rest()

      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer error="invalid_token")
      refute Map.has_key?(conn.assigns, :phoenix_kit_api_actor)
    end

    test "REST with no credentials has the plain challenge, OAuth on or not" do
      conn = :post |> api_conn("/x") |> rest()
      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer error="invalid_token")
    end

    test "never on the public MCP endpoint", %{seed: seed} do
      switch(:public, true)
      conn = post_rpc(:public, message("tools/list"), token: seed.access)
      # The public audience has no keys: it answers anonymously, and no challenge.
      assert conn.status in [200, 404]
      assert challenge(conn) == nil
    end

    test "a pk_ key still works on the admin MCP endpoint", %{holder: holder} do
      {_key, token} = issue_key(holder_with_api(holder), [@read])
      conn = post_rpc(:admin, message("tools/list"), token: token)
      assert conn.status == 200
    end

    test "Auth.init/1 takes only a boolean oauth option" do
      assert [audience: :admin, oauth: true] = Auth.init(audience: :admin, oauth: true)
      assert_raise ArgumentError, fn -> Auth.init(audience: :admin, oauth: :yes) end
    end
  end

  describe "the challenge, OAuth on" do
    setup do
      enable_oauth!()
    end

    test "no credentials: resource_metadata and no error" do
      conn = post_rpc(:admin, message("tools/list"))

      assert conn.status == 401
      assert challenge(conn) == "Bearer " <> metadata()
      assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
    end

    test "a bad token: error and resource_metadata" do
      for token <- ["not-a-token", "pk_00000000_" <> String.duplicate("A", 43)] do
        conn = post_rpc(:admin, message("tools/list"), token: token)
        assert conn.status == 401
        assert challenge(conn) == ~s(Bearer error="invalid_token", ) <> metadata()
      end
    end

    test "a malformed header is a bad token, not a missing one" do
      conn =
        :post
        |> api_conn("/", headers: [{"authorization", "Basic abc"}])
        |> Auth.call(Auth.init(audience: :admin, oauth: true))

      assert challenge(conn) == ~s(Bearer error="invalid_token", ) <> metadata()
    end

    test "an expired token: error and resource_metadata", %{seed: seed} do
      expire!(seed)
      conn = post_rpc(:admin, message("tools/list"), token: seed.access)

      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer error="invalid_token", ) <> metadata()
    end

    test "a revoked grant: error and resource_metadata", %{seed: seed} do
      {:ok, _} = Grants.revoke(seed.grant)
      conn = post_rpc(:admin, message("tools/list"), token: seed.access)

      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer error="invalid_token", ) <> metadata()
    end

    test "the metadata URL is the one of the resource, under the site origin" do
      assert Resource.metadata_url() =~ "/.well-known/oauth-protected-resource"
      assert String.ends_with?(Resource.metadata_url(), Resource.path())
    end

    test "a 403 for a missing scope has its own challenge", %{seed: seed} do
      conn =
        :post
        |> api_conn("/x", token: seed.access)
        |> rest_with_oauth()
        |> Problem.send(:forbidden, "Missing scope.", %{required_scope: "a.b:write"})

      assert conn.status == 403
      assert challenge(conn) == ~s(Bearer error="insufficient_scope", ) <> metadata()
    end

    test "a URL that could break out of the quotes is never put in the header" do
      conn =
        :post
        |> api_conn("/x")
        |> put_private(:phoenix_kit_api_oauth_challenge, %{
          resource_metadata: ~s(https://x.example/"; error="x),
          missing: true
        })
        |> Problem.send(:unauthorized, "No.", %{})

      assert challenge(conn) == ~s(Bearer error="invalid_token")
    end
  end

  describe "the failure bucket, OAuth on, on the admin MCP endpoint" do
    setup do
      enable_oauth!()
      wait_for_window_room()
    end

    test "is not used up by requests with no credentials, however many", %{} do
      fail_limit(2)
      ip = unique_ip()

      for _ <- 1..6 do
        conn = post_rpc(:admin, message("tools/list"), ip: ip)
        assert conn.status == 401
        assert challenge(conn) == "Bearer " <> metadata()
      end

      assert :ok = RateLimit.check_preauth(ip)
    end

    test "is not used up by a token that ran out", %{seed: seed} do
      expire!(seed)
      fail_limit(2)
      ip = unique_ip()

      for _ <- 1..6 do
        conn = post_rpc(:admin, message("tools/list"), token: seed.access, ip: ip)
        assert conn.status == 401
        assert challenge(conn) == ~s(Bearer error="invalid_token", ) <> metadata()
      end

      assert :ok = RateLimit.check_preauth(ip)
    end

    test "is not even peeked: a full bucket does not turn a missing token into a 429", %{} do
      fail_limit(1)
      ip = unique_ip()
      :ok = RateLimit.record_auth_failure(ip)
      assert {:error, _} = RateLimit.check_preauth(ip)

      conn = post_rpc(:admin, message("tools/list"), ip: ip)
      assert conn.status == 401
    end

    test "is charged by an unknown pkoa_ token, as before", %{} do
      fail_limit(2)
      ip = unique_ip()
      {unknown, _hash} = Tokens.generate(:access)

      assert post_rpc(:admin, message("tools/list"), token: unknown, ip: ip).status == 401
      assert post_rpc(:admin, message("tools/list"), token: unknown, ip: ip).status == 401
      assert post_rpc(:admin, message("tools/list"), token: unknown, ip: ip).status == 429
    end

    test "is charged by a bad pk_ key and a malformed header, as before" do
      fail_limit(2)
      ip = unique_ip()

      assert post_rpc(:admin, message("tools/list"), token: "pk_00000000_x", ip: ip).status == 401
      assert post_rpc(:admin, message("tools/list"), token: "garbage", ip: ip).status == 401
      assert post_rpc(:admin, message("tools/list"), token: "garbage", ip: ip).status == 429
    end

    test "a valid token is never refused for its address's failures", %{seed: seed} do
      fail_limit(1)
      ip = unique_ip()
      :ok = RateLimit.record_auth_failure(ip)

      assert post_rpc(:admin, message("tools/list"), token: seed.access, ip: ip).status == 200
    end
  end

  describe "the bucket on REST and with OAuth off is as it was" do
    test "no credentials on REST is charged, OAuth on or off", %{} do
      enable_oauth!()
      wait_for_window_room()
      fail_limit(2)
      ip = unique_ip()

      assert (:post |> api_conn("/x", ip: ip) |> rest()).status == 401
      assert (:post |> api_conn("/x", ip: ip) |> rest()).status == 401
      assert (:post |> api_conn("/x", ip: ip) |> rest()).status == 429
    end

    test "no credentials on the MCP endpoint with OAuth off is charged" do
      switch(:admin, true)
      wait_for_window_room()
      fail_limit(2)
      ip = unique_ip()

      assert post_rpc(:admin, message("tools/list"), ip: ip).status == 401
      assert post_rpc(:admin, message("tools/list"), ip: ip).status == 401
      assert post_rpc(:admin, message("tools/list"), ip: ip).status == 429
    end
  end

  defp expire!(seed) do
    past = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(t in Token, where: t.uuid == ^seed.access_row.uuid),
      set: [expires_at: past]
    )
  end

  defp rest_with_oauth(conn), do: Auth.call(conn, Auth.init(audience: :admin, oauth: true))

  # `issue_key/3` needs a holder of `api`: give this one the right on its role.
  defp holder_with_api(holder) do
    {user, _role} = user_with(["dashboard"])
    _ = holder
    user
  end
end
