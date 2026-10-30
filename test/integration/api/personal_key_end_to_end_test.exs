defmodule PhoenixKit.API.PersonalKeyEndToEndTest do
  @moduledoc """
  A personal API key through the real endpoint, router and database: every check is an
  HTTP request (REST and MCP) against `PhoenixKitWeb.Endpoint`.

  The person holds `api_personal_keys` and `media` and no `api`. What is shown here is
  that the key works while the permission is held, stops on the very next request when
  the role loses it (the key row is cached before), works again when it is given back,
  and that a key that is not personal keeps its old behaviour.

  Every request carries an `X-Forwarded-For` address of its own, so no test shares a
  rate-limit bucket with another.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes

  import PhoenixKit.Test.ApiHarness, only: [assert_row_cached: 1]

  import PhoenixKit.Test.McpHarness,
    only: [message: 1, tool_names: 1, version: 0]

  @identity_tool "system.get_identity"

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)

    {user, role} = KeyTestSupport.user_without_api(["api_personal_keys", "media"])
    scope = KeyTestSupport.scope_of(user)

    {:ok, key, token} =
      Keys.create_personal_key(
        scope,
        %{
          "name" => "Personal end to end",
          "scopes" => [KeyTestSupport.read_scope()],
          "expires_at" => PersonalKeysConfig.latest_expiry()
        },
        impersonated: false
      )

    %{conn: conn, user: user, role: role, key: key, token: token}
  end

  defp rest(conn, token) do
    conn
    |> put_req_header("x-forwarded-for", KeyTestSupport.unique_ip())
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(Routes.path("/api/admin/v1/" <> @identity_tool), "{}")
  end

  defp mcp_list(conn, token) do
    conn
    |> put_req_header("x-forwarded-for", KeyTestSupport.unique_ip())
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-protocol-version", version())
    |> post(Routes.path("/mcp/admin"), JSON.encode!(message("tools/list")))
  end

  test "REST reads the identity of the person and MCP lists only tools in their rights", %{
    conn: conn,
    token: token,
    user: user,
    key: key
  } do
    assert key.personal

    conn_rest = rest(conn, token)
    assert conn_rest.status == 200
    body = JSON.decode!(conn_rest.resp_body)
    assert body["owner"]["id"] == user.uuid
    assert body["key"]["prefix"] == key.prefix

    names = conn |> mcp_list(token) |> tool_names()
    assert "apikeytest_list_things" in names
    assert "system_get_identity" in names
    refute Enum.any?(names, &String.contains?(&1, "write"))
  end

  describe "the permission is checked on every request" do
    test "taking api_personal_keys from the role stops the key; giving it back revives it", %{
      conn: conn,
      token: token,
      role: role,
      key: key
    } do
      assert rest(conn, token).status == 200
      assert mcp_list(conn, token).status == 200
      assert_row_cached(key.prefix)

      :ok = Permissions.revoke_permission(role.uuid, "api_personal_keys")

      assert rest(conn, token).status == 401
      assert mcp_list(conn, token).status == 401

      {:ok, _} = Permissions.grant_permission(role.uuid, "api_personal_keys")

      assert rest(conn, token).status == 200
      assert mcp_list(conn, token).status == 200
    end

    test "a blocked owner is a 401", %{conn: conn, token: token, user: user} do
      assert rest(conn, token).status == 200

      {:ok, _} = Auth.update_user_status(user, %{"is_active" => false})

      assert rest(conn, token).status == 401
      assert mcp_list(conn, token).status == 401
    end
  end

  test "a key that is not personal keeps working after its owner loses api" do
    conn = build_conn()
    {user, role} = KeyTestSupport.user_with(["media"])

    {key, token} =
      KeyTestSupport.issue_key!(user, [KeyTestSupport.read_scope()])

    refute key.personal
    assert rest(conn, token).status == 200

    :ok = Permissions.revoke_permission(role.uuid, "api")

    assert rest(conn, token).status == 200
    assert mcp_list(conn, token).status == 200
  end
end
