defmodule PhoenixKitWeb.Plugs.IntegrationRememberMeTest do
  @moduledoc """
  `PhoenixKitWeb.Plugs.Integration` rebuilds the session from the remember-me
  cookie, so a host's public pages, which never run the kit's fetch plugs, see
  a remembered visitor as signed in after the session cookie is gone.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Plugs.Integration
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  @password "ValidPassword123!"

  defp unique_email, do: "irm_#{System.unique_integer([:positive])}@example.com"

  setup do
    # The first user in a fresh sandbox becomes Owner; seed one so the user
    # under test is an ordinary account.
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, _} = Auth.admin_confirm_user(seed)

    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, user} = Auth.admin_confirm_user(user)
    %{user: user}
  end

  defp remember_me_cookie(user) do
    ip = {10, 77, :rand.uniform(250), :rand.uniform(250)}

    conn =
      %{build_conn() | remote_ip: ip}
      |> post(Routes.path("/users/log-in"), %{
        "user" => %{
          "email_or_username" => user.email,
          "password" => @password,
          "remember_me" => "true"
        }
      })

    %{value: value} = conn.resp_cookies[UserAuth.remember_me_cookie()]
    value
  end

  # A request to a host page after a browser restart: the remember-me cookie
  # is sent, the session cookie is not, and only the integration plug runs.
  defp host_request(cookies) do
    cookies
    |> Enum.reduce(build_conn(:get, "/about"), fn {name, value}, conn ->
      put_req_cookie(conn, name, value)
    end)
    |> Map.put(:secret_key_base, @endpoint.config(:secret_key_base))
    |> init_test_session(%{})
    |> Integration.call(Integration.init([]))
  end

  test "rebuilds the session from the remember-me cookie", %{user: user} do
    conn = host_request(%{UserAuth.remember_me_cookie() => remember_me_cookie(user)})

    token = get_session(conn, :user_token)
    assert token
    assert Auth.get_user_by_session_token(token).uuid == user.uuid
    assert get_session(conn, :live_socket_id)
  end

  test "does nothing without the cookie" do
    conn = host_request(%{})
    refute get_session(conn, :user_token)
  end

  test "leaves a session that already has a user alone", %{user: user} do
    cookie = remember_me_cookie(user)

    conn =
      build_conn(:get, "/about")
      |> put_req_cookie(UserAuth.remember_me_cookie(), cookie)
      |> Map.put(:secret_key_base, @endpoint.config(:secret_key_base))
      |> init_test_session(%{user_token: "already-here"})
      |> Integration.call(Integration.init([]))

    assert get_session(conn, :user_token) == "already-here"
  end

  test "honours the remember-me switch", %{user: user} do
    cookie = remember_me_cookie(user)
    Settings.update_boolean_setting("remember_me_enabled", false)
    on_exit(fn -> Settings.update_boolean_setting("remember_me_enabled", true) end)

    conn = host_request(%{UserAuth.remember_me_cookie() => cookie})
    refute get_session(conn, :user_token)
  end

  test "passes a conn whose session was never fetched straight through" do
    conn =
      build_conn(:get, "/about")
      |> put_req_cookie(UserAuth.remember_me_cookie(), "anything")
      |> UserAuth.restore_remembered_session()

    refute Map.has_key?(conn.private, :plug_session)
  end
end
