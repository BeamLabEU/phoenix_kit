defmodule PhoenixKitWeb.Users.ApiOnlyDoorsTest do
  @moduledoc """
  A service user (`api_only`) owns API keys and never signs in on the web. Whatever else is
  true of the account - confirmed, active, even holding a known password because somebody
  set one - every web authentication door must refuse it:

    * password login, and adding an account to a browser session
    * impersonation by an administrator
    * magic link (asking for one, and following one)
    * password reset (the mail, and the token) and registration confirmation
    * OAuth (an address that matches, and an identity already linked)
    * QR login
    * reading a session at all, including one minted before the flag was set

  Each test pairs the refusal with the same step done for an ordinary user, so a door
  that is broken for everyone cannot pass as "refused".
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.MagicLink
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthProvider
  alias PhoenixKit.Users.QrLogin
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth
  alias PhoenixKitWeb.Users.MultiSession

  @password "ValidPassword123!"

  defp unique_email, do: "svc_#{System.unique_integer([:positive])}@example.com"

  # A throwaway Owner up front, so the users built in a test keep their intended roles
  # instead of the first-user promotion. Each test also gets its own peer address: the
  # login rate limit keys on it (15 a minute) and the test adapter reports one peer for all.
  setup %{conn: conn} do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, _} = Auth.admin_confirm_user(seed)
    {:ok, conn: with_peer(conn, unique_ip())}
  end

  defp unique_ip do
    n = System.unique_integer([:positive])
    {127, 1, n |> div(256) |> rem(256), rem(n, 256)}
  end

  defp with_peer(conn, ip) do
    {adapter, payload} = conn.adapter
    peer = %{address: ip, port: 111_317, ssl_cert: nil}
    %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer)}, remote_ip: ip}
  end

  # An ordinary, confirmed, active user.
  defp plain_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(User, user.uuid)
  end

  # The worst case: confirmed, active, and with a password that works - as if an admin had
  # typed one into a form. Only the flag stands between this account and the web.
  defp service_user do
    user = plain_user()
    {:ok, user} = user |> Ecto.Changeset.change(api_only: true) |> Repo.update()
    user
  end

  defp owner_user do
    user = plain_user()
    owner_role = Roles.get_role_by_name("Owner")

    {:ok, _} =
      %RoleAssignment{}
      |> RoleAssignment.changeset(%{user_uuid: user.uuid, role_uuid: owner_role.uuid})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_uuid, :role_uuid])

    Repo.get!(User, user.uuid)
  end

  defp session_conn(user) do
    token = Auth.generate_user_session_token(user)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
    |> Plug.Conn.put_session(:pk_session_accounts, [token])
  end

  defp email_token(user, context) do
    {token, user_token} = UserToken.build_email_token(user, context)
    Repo.insert!(user_token)
    token
  end

  defp tokens_of(user, context) do
    Repo.aggregate(
      from(t in UserToken, where: t.user_uuid == ^user.uuid and t.context == ^context),
      :count
    )
  end

  defp signed_in?(conn), do: Plug.Conn.get_session(conn, :user_token) != nil

  describe "password login" do
    test "a service user is refused, with the answer a wrong password gets", %{conn: conn} do
      service = service_user()

      assert {:error, :invalid_credentials} =
               Auth.get_user_by_email_or_username_and_password(service.email, @password)

      assert {:error, :invalid_credentials} =
               Auth.get_user_by_email_and_password(service.email, @password)

      refute User.valid_password?(service, @password)

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => service.email, "password" => @password}
        })

      assert redirected_to(conn) == Routes.path("/users/log-in")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid email/username or password"
      refute signed_in?(conn)
    end

    test "an ordinary user with the same password signs in", %{conn: conn} do
      user = plain_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      assert redirected_to(conn) == Routes.path("/admin")
      assert signed_in?(conn)
    end
  end

  describe "adding an account to a browser session (multi-account)" do
    test "a service user is refused, the stack is unchanged" do
      owner = owner_user()
      service = service_user()
      conn = session_conn(owner)

      assert {:error, :invalid_credentials} =
               MultiSession.add_account(conn, service.email, @password)

      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "an ordinary user is added" do
      conn = session_conn(owner_user())

      assert {:ok, conn} = MultiSession.add_account(conn, plain_user().email, @password)
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 2
    end

    test "add_authenticated_user/3 (the OAuth add-account step) refuses a service user too" do
      conn = session_conn(owner_user())

      assert {:error, :inactive} = MultiSession.add_authenticated_user(conn, service_user())
      assert {:ok, _conn} = MultiSession.add_authenticated_user(conn, plain_user())
    end
  end

  describe "impersonation" do
    test "an owner cannot sign in as a service user" do
      owner = owner_user()
      service = service_user()
      conn = session_conn(owner)

      assert {:error, :inactive} = MultiSession.impersonate(conn, service)
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "the menus do not offer it, and an owner can still sign in as an ordinary user" do
      owner = owner_user()
      service = service_user()
      plain = plain_user()
      conn = session_conn(owner)

      refute MultiSession.impersonable?(owner, service)
      assert MultiSession.impersonable?(owner, plain)

      assert MapSet.new([plain.uuid]) ==
               MultiSession.impersonable_uuids(owner, [service, plain])

      assert {:ok, _conn} = MultiSession.impersonate(conn, plain)
    end
  end

  describe "magic link" do
    test "asking for a link for a service user answers like an unknown address, and makes no token" do
      service = service_user()

      assert {:error, :user_not_found} = MagicLink.generate_magic_link(service.email)
      assert tokens_of(service, "magic_link") == 0

      assert {:error, :user_not_found} = MagicLink.generate_magic_link("nobody-#{unique_email()}")
      assert {:ok, _user, _token} = MagicLink.generate_magic_link(plain_user().email)
    end

    test "a link that exists for a service user is dead, as a function and as a page", %{
      conn: conn
    } do
      service = service_user()
      token = email_token(service, "magic_link")

      assert {:error, :invalid_token} = MagicLink.verify_magic_link(token)

      conn = get(conn, Routes.path("/users/magic-link/#{token}"))

      assert redirected_to(conn) == Routes.path("/users/log-in")
      refute signed_in?(conn)
    end

    test "the same link for an ordinary user signs them in", %{conn: conn} do
      token = email_token(plain_user(), "magic_link")

      conn = get(conn, Routes.path("/users/magic-link/#{token}"))

      assert signed_in?(conn)
    end
  end

  describe "password reset" do
    test "no reset mail is sent to a service user and no token is made" do
      service = service_user()

      assert {:error, :api_only} =
               Auth.deliver_user_reset_password_instructions(service, &"http://localhost/#{&1}")

      assert tokens_of(service, "reset_password") == 0

      assert {:ok, _} =
               Auth.deliver_user_reset_password_instructions(
                 plain_user(),
                 &"http://localhost/#{&1}"
               )
    end

    test "a reset token that exists for a service user finds nobody" do
      service = service_user()
      plain = plain_user()

      assert Auth.get_user_by_reset_password_token(email_token(service, "reset_password")) == nil

      assert %User{uuid: uuid} =
               Auth.get_user_by_reset_password_token(email_token(plain, "reset_password"))

      assert uuid == plain.uuid
    end
  end

  describe "registration confirmation" do
    defp unconfirmed_service_user do
      {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
      {:ok, user} = user |> Ecto.Changeset.change(api_only: true) |> Repo.update()
      user
    end

    test "no confirmation mail is sent to a service user and no token is made" do
      service = unconfirmed_service_user()

      assert {:error, :already_confirmed} =
               Auth.deliver_user_confirmation_instructions(service, &"http://localhost/#{&1}")

      assert tokens_of(service, "confirm") == 0
    end

    test "a confirmation token that exists for a service user confirms nobody" do
      service = unconfirmed_service_user()
      token = email_token(service, "confirm")

      assert Auth.confirm_user(token) == :error
      assert Repo.get!(User, service.uuid).confirmed_at == nil
    end

    test "an ordinary unconfirmed user is confirmed by the same step" do
      {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})

      assert {:ok, %User{confirmed_at: %DateTime{}}} =
               Auth.confirm_user(email_token(user, "confirm"))
    end
  end

  describe "OAuth" do
    defp oauth_data(email, overrides \\ %{}) do
      Map.merge(
        %{
          provider: "google",
          provider_uid: "uid_#{System.unique_integer([:positive])}",
          email: email,
          first_name: "Test",
          last_name: "User",
          image: nil,
          access_token: "at",
          refresh_token: nil,
          token_expires_at: nil,
          # The provider vouches for the address: the only thing missing is the flag.
          raw_info: %{user: %{"email" => email, "email_verified" => true}}
        },
        overrides
      )
    end

    test "an address that matches a service user is not attached to it" do
      service = service_user()

      assert {:error, :api_only_account} = OAuth.find_or_create_user(oauth_data(service.email))

      assert Repo.aggregate(from(p in OAuthProvider, where: p.user_uuid == ^service.uuid), :count) ==
               0
    end

    test "an identity already linked to a service user does not sign it in" do
      service = service_user()
      uid = "uid_#{System.unique_integer([:positive])}"

      {:ok, _} =
        %OAuthProvider{}
        |> OAuthProvider.changeset(%{
          user_uuid: service.uuid,
          provider: "google",
          provider_uid: uid,
          provider_email: service.email
        })
        |> Repo.insert()

      assert {:error, :api_only_account} =
               OAuth.find_or_create_user(
                 oauth_data("other-#{service.email}", %{provider_uid: uid})
               )
    end

    test "an ordinary user with the same verified address is found" do
      plain = plain_user()

      assert {:ok, %User{uuid: uuid}, :found} = OAuth.find_or_create_user(oauth_data(plain.email))
      assert uuid == plain.uuid
    end
  end

  describe "QR login" do
    setup do
      start_supervised!(Keyfob.Store.ETS)
      {:ok, _} = Settings.update_boolean_setting("qr_login_enabled", true)
      :ok
    end

    # What the phone does: approve a request for `user`. Returns the one-time login token
    # the desktop would follow.
    defp approved_login_token(user) do
      {:ok, %{token: request}} = QrLogin.create_request()
      :ok = QrLogin.subscribe(request)
      # Simulate an approval minted before the account became API-only.
      :ok = Keyfob.approve(request, user.uuid, QrLogin.keyfob_opts())
      assert_receive {:keyfob, ^request, {:approved, login_token}}
      login_token
    end

    test "completing a login approved for a service user signs nobody in", %{conn: conn} do
      conn =
        get(conn, Routes.path("/users/qr-login/finish/#{approved_login_token(service_user())}"))

      assert redirected_to(conn) == Routes.path("/users/log-in")
      refute signed_in?(conn)
    end

    test "the same for an ordinary user signs them in", %{conn: conn} do
      conn =
        get(conn, Routes.path("/users/qr-login/finish/#{approved_login_token(plain_user())}"))

      assert signed_in?(conn)
    end
  end

  describe "reading a session" do
    test "a token whose user is a service user resolves to nobody" do
      service = service_user()
      token = Auth.generate_user_session_token(service)

      assert Auth.get_user_by_session_token(token) == nil

      {:ok, query} = UserToken.verify_session_token_query(token)
      assert Repo.one(query) == nil

      plain = plain_user()

      assert %User{uuid: uuid} =
               Auth.get_user_by_session_token(Auth.generate_user_session_token(plain))

      assert uuid == plain.uuid
    end

    test "a session that was valid before the flag was set stops at once" do
      user = plain_user()
      token = Auth.generate_user_session_token(user)
      assert %User{} = Auth.get_user_by_session_token(token)

      {:ok, _} = user |> Ecto.Changeset.change(api_only: true) |> Repo.update()

      assert Auth.get_user_by_session_token(token) == nil
    end

    test "the request plug treats the session of a service user as signed out" do
      conn = service_user() |> session_conn() |> UserAuth.fetch_phoenix_kit_current_scope([])

      assert conn.assigns.phoenix_kit_current_user == nil
      refute Scope.authenticated?(conn.assigns.phoenix_kit_current_scope)

      conn = plain_user() |> session_conn() |> UserAuth.fetch_phoenix_kit_current_scope([])

      assert %User{} = conn.assigns.phoenix_kit_current_user
      assert Scope.authenticated?(conn.assigns.phoenix_kit_current_scope)
    end
  end

  describe "the funnel itself" do
    test "log_in_user/3 mints no session for a service user whichever door called it", %{
      conn: conn
    } do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> UserAuth.log_in_user(service_user(), %{})

      assert conn.halted
      assert redirected_to(conn) == Routes.path("/users/log-in")
      refute signed_in?(conn)
    end
  end
end
