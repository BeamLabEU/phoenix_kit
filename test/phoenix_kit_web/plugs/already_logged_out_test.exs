defmodule PhoenixKitWeb.Plugs.AlreadyLoggedOutTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PhoenixKitWeb.Plugs.AlreadyLoggedOut
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  defp request(method, path, session \\ %{}) do
    method
    |> conn(path)
    |> init_test_session(session)
    |> AlreadyLoggedOut.call(AlreadyLoggedOut.init([]))
  end

  test "a log-out with no session is redirected before anything else runs" do
    conn = request(:delete, "/phoenix_kit/users/log-out")

    assert conn.halted
    assert conn.status == 302
    assert [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, "/")
  end

  test "the locale-prefixed route is covered too" do
    assert request(:delete, "/phoenix_kit/et/users/log-out").halted
  end

  test "a signed-in session passes through to the CSRF check and the controller" do
    conn = request(:delete, "/phoenix_kit/users/log-out", %{"user_token" => "tok"})

    refute conn.halted
    assert is_nil(conn.status)
  end

  test "an account stack with no active token still passes through" do
    conn = request(:delete, "/users/log-out", %{"pk_session_accounts" => ["root"]})

    refute conn.halted
  end

  test "a remember-me cookie could still sign the visitor in, so it passes through" do
    conn =
      :delete
      |> conn("/users/log-out")
      |> put_req_header("cookie", "#{UserAuth.remember_me_cookie()}=anything")
      |> init_test_session(%{})
      |> AlreadyLoggedOut.call([])

    refute conn.halted
  end

  test "other routes and other methods are left alone" do
    refute request(:delete, "/users/session/accounts/abc").halted
    refute request(:get, "/users/log-out").halted
    refute request(:post, "/users/log-in").halted
  end
end
