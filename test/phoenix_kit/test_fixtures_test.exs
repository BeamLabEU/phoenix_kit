defmodule PhoenixKit.TestFixturesTest do
  @moduledoc """
  `PhoenixKit.Test.Fixtures` exists because every host was writing the same four
  helpers, and the hand-rolled login was subtly wrong: it set `:user_token` and
  not `:live_socket_id`, so LiveView disconnect-on-logout never fired. Only a
  session-invalidation test would ever have caught that, which is exactly why it
  should not be everyone's job to get right.

  These pin the properties a host depends on.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.Fixtures

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  describe "user_fixture/1" do
    test "produces an UNCONFIRMED user" do
      # The honest mirror of `register_user/1`. A fixture that silently
      # confirmed would leave a reader unable to tell why a redirect gate in
      # their test did or did not fire.
      assert %{confirmed_at: nil} = user_fixture()
    end

    test "accepts overrides with either atom or string keys" do
      assert user_fixture(%{email: "atom@example.com"}).email == "atom@example.com"
      assert user_fixture(%{"email" => "string@example.com"}).email == "string@example.com"
    end

    test "many fixtures in a row do not trip the registration rate limiter" do
      # `register_user/2` limits per email AND per IP, and the test adapter
      # reports one peer for every conn — so a fixture passing a real IP would
      # put every test in the same bucket and fail the eleventh.
      users = Enum.map(1..12, fn _ -> user_fixture() end)

      assert length(users) == 12
      assert Enum.all?(users, &match?(%{uuid: uuid} when is_binary(uuid), &1))
    end
  end

  describe "confirmed_user_fixture/1" do
    test "produces a confirmed user" do
      assert %{confirmed_at: %DateTime{}} = confirmed_user_fixture()
    end
  end

  describe "log_in_user/2" do
    test "sets BOTH :user_token and :live_socket_id" do
      # The second key is the whole point. Without it
      # `PhoenixKitWeb.Endpoint.broadcast` has no topic to reach the socket on,
      # so logging out never disconnects the LiveView.
      user = confirmed_user_fixture()
      conn = Phoenix.ConnTest.build_conn() |> init_session() |> log_in_user(user)

      token = Plug.Conn.get_session(conn, :user_token)

      assert is_binary(token)

      assert Plug.Conn.get_session(conn, :live_socket_id) ==
               "phoenix_kit_sessions:#{Base.url_encode64(token)}"
    end

    test "the token it puts in the session actually resolves to the user" do
      user = confirmed_user_fixture()
      conn = Phoenix.ConnTest.build_conn() |> init_session() |> log_in_user(user)

      token = Plug.Conn.get_session(conn, :user_token)

      assert Auth.get_user_by_session_token(token).uuid == user.uuid
    end
  end

  describe "log_in_user/2 on a conn without a session" do
    test "a plain build_conn() conn works: the session is started for it" do
      user = confirmed_user_fixture()
      conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

      token = Plug.Conn.get_session(conn, :user_token)
      assert Auth.get_user_by_session_token(token).uuid == user.uuid

      assert Plug.Conn.get_session(conn, :live_socket_id) ==
               "phoenix_kit_sessions:#{Base.url_encode64(token)}"
    end

    test "an existing session is kept, not replaced" do
      user = confirmed_user_fixture()

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"return_to" => "/somewhere"})
        |> log_in_user(user)

      assert Plug.Conn.get_session(conn, "return_to") == "/somewhere"
      assert is_binary(Plug.Conn.get_session(conn, :user_token))
    end

    test "register_and_log_in_user/1 composes with a plain conn too" do
      context = register_and_log_in_user(%{conn: Phoenix.ConnTest.build_conn()})
      assert is_binary(Plug.Conn.get_session(context.conn, :user_token))
    end
  end

  describe "register_and_log_in_user/1" do
    test "returns a confirmed, logged-in user and composes as a setup" do
      conn = Phoenix.ConnTest.build_conn() |> init_session()

      context = register_and_log_in_user(%{conn: conn})

      assert %DateTime{} = context.user.confirmed_at
      assert Plug.Conn.get_session(context.conn, :user_token)
    end
  end

  describe "scope_for/1" do
    test "builds a real scope, not a stub" do
      user = confirmed_user_fixture()
      scope = scope_for(user)

      assert Scope.authenticated?(scope)
      assert Scope.user_uuid(scope) == user.uuid
    end

    test "nil yields an anonymous scope" do
      refute Scope.authenticated?(scope_for(nil))
    end
  end

  describe "admin_fixture/1" do
    test "holds the Admin role and can reach the admin area" do
      admin = admin_fixture()

      assert Scope.can_access_admin_area?(scope_for(admin))
    end
  end

  defp init_session(conn) do
    Plug.Test.init_test_session(conn, %{})
  end
end
