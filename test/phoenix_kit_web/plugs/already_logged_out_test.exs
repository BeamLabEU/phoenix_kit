defmodule PhoenixKitWeb.Plugs.AlreadyLoggedOutTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PhoenixKitWeb.Plugs.AlreadyLoggedOut
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  # The plug, then the CSRF check a host's :browser pipeline runs — with no
  # token in the request, as from a page rendered in a session that is gone.
  defp request(method, path, session \\ %{}, cookie \\ nil) do
    conn = conn(method, path)
    conn = if cookie, do: put_req_header(conn, "cookie", cookie), else: conn

    conn
    |> init_test_session(session)
    |> AlreadyLoggedOut.call(AlreadyLoggedOut.init([]))
  end

  defp csrf(conn), do: Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([]))

  describe "a log-out with nothing left to log out" do
    test "passes the CSRF check it would otherwise fail" do
      # The control: the same request without the plug is the 403.
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        :delete |> conn("/phoenix_kit/users/log-out") |> init_test_session(%{}) |> csrf()
      end

      conn = :delete |> request("/phoenix_kit/users/log-out") |> csrf()

      # Not answered here: it goes on to the controller like any log-out.
      refute conn.halted
      assert is_nil(conn.status)
    end

    test "on the locale-prefixed route too" do
      conn = :delete |> request("/phoenix_kit/et/users/log-out") |> csrf()
      refute conn.halted
    end
  end

  describe "a request that could still be signed in keeps its CSRF check" do
    test "with a session token" do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        :delete |> request("/phoenix_kit/users/log-out", %{"user_token" => "tok"}) |> csrf()
      end
    end

    test "with an account stack and no active token" do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        :delete |> request("/users/log-out", %{"pk_session_accounts" => ["root"]}) |> csrf()
      end
    end

    test "with a remember-me cookie" do
      cookie = "#{UserAuth.remember_me_cookie()}=anything"

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        :delete |> request("/users/log-out", %{}, cookie) |> csrf()
      end
    end
  end

  test "other routes and methods are never exempted" do
    for {method, path} <- [
          {:delete, "/users/session/accounts/abc"},
          {:post, "/users/log-in"},
          {:post, "/users/log-out"},
          {:put, "/users/session/active"}
        ] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        method |> request(path) |> csrf()
      end
    end
  end

  describe "wiring" do
    # The exemption only works ahead of the CSRF check, which lives in the
    # host's :browser pipeline. After it, the 403 has already been raised.
    for path <- ["/phoenix_kit/users/log-out", "/phoenix_kit/en/users/log-out"] do
      test "DELETE #{path} runs the plug's pipeline before :browser" do
        info =
          Phoenix.Router.route_info(PhoenixKitWeb.Router, "DELETE", unquote(path), "localhost")

        assert %{pipe_through: pipes} = info
        guard = Enum.find_index(pipes, &(&1 == :phoenix_kit_already_logged_out))
        browser = Enum.find_index(pipes, &(&1 == :browser))

        assert guard, "the log-out route lost the pipeline: #{inspect(pipes)}"
        assert browser, "expected :browser in #{inspect(pipes)}"
        assert guard < browser
      end
    end
  end
end
