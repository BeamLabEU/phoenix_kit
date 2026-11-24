defmodule PhoenixKitWeb.Users.LogoutMethodsTest do
  @moduledoc """
  Both log-out routes sign out. The menus use DELETE (with a CSRF token); the
  GET route stays for hosts that link to it directly and is pinned here as it
  is, so a change to it is a deliberate one.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.MultiSession

  setup %{conn: conn} do
    # The first registered user becomes Owner; seed one so the next is plain.
    {:ok, _} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    token = Auth.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(
        :live_socket_id,
        "phoenix_kit_sessions:#{Base.url_encode64(token)}"
      )
      |> Plug.Conn.put_session(:pk_session_accounts, [token])

    %{conn: conn, token: token}
  end

  defp unique_email, do: "lm_#{System.unique_integer([:positive])}@example.com"

  test "DELETE signs the session out", %{conn: conn, token: token} do
    conn = delete(conn, Routes.path("/users/log-out"))

    assert redirected_to(conn)
    refute get_session(conn)["user_token"]
    assert is_nil(Auth.get_user_by_session_token(token))
  end

  test "GET still signs the session out, unchanged", %{conn: conn, token: token} do
    conn = get(conn, Routes.path("/users/log-out"))

    assert redirected_to(conn)
    refute get_session(conn)["user_token"]
    assert is_nil(Auth.get_user_by_session_token(token))
  end

  describe "with two accounts signed in" do
    setup %{conn: conn} do
      PhoenixKit.Settings.update_boolean_setting("multi_session_enabled", true)
      {:ok, other} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
      {:ok, other} = Auth.admin_confirm_user(other)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      [root_token, other_token] = get_session(conn)["pk_session_accounts"]

      %{
        conn: Phoenix.Controller.fetch_flash(conn),
        root_token: root_token,
        other_token: other_token
      }
    end

    test "the plain entry signs out the active account only",
         %{conn: conn, root_token: root, other_token: other} do
      conn = delete(conn, Routes.path("/users/log-out"))

      assert redirected_to(conn)
      assert is_nil(Auth.get_user_by_session_token(other))
      assert Auth.get_user_by_session_token(root)
      assert Auth.get_user_by_session_token(get_session(conn)["user_token"])
    end

    test "the log-out-from-all entry signs out both",
         %{conn: conn, root_token: root, other_token: other} do
      conn = delete(conn, Routes.path("/users/log-out") <> "?all=1")

      assert redirected_to(conn)
      assert is_nil(Auth.get_user_by_session_token(root))
      assert is_nil(Auth.get_user_by_session_token(other))
      refute get_session(conn)["user_token"]
    end
  end
end
