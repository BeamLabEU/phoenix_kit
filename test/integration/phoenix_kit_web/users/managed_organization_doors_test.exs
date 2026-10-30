defmodule PhoenixKitWeb.Users.ManagedOrganizationDoorsTest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.MagicLink
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthProvider
  alias PhoenixKit.Users.QrLogin
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: WebAuth
  alias PhoenixKitWeb.Users.MultiSession

  @password "ValidPassword123!"

  test "password login and the common web login funnel refuse a managed organization", %{
    conn: conn
  } do
    org = Fixtures.organization()
    refute User.valid_password?(org, @password)

    assert {:error, :invalid_credentials} =
             Auth.get_user_by_email_and_password(org.email, @password)

    assert {:error, :invalid_credentials} =
             Auth.get_user_by_email_or_username_and_password(org.email, @password)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> WebAuth.log_in_user(org)

    assert redirected_to(conn) == Routes.path("/users/log-in")
    assert Plug.Conn.get_session(conn, :user_token) == nil
  end

  test "ordinary add-account and impersonation cannot mint a managed organization's session" do
    org = Fixtures.organization()
    owner = Fixtures.person()
    {:ok, _} = Roles.promote_to_admin(owner)
    {token, _} = Fixtures.session(owner)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{user_token: token, pk_session_accounts: [token]})

    assert {:error, :invalid_credentials} = MultiSession.add_account(conn, org.email, @password)
    assert {:error, :inactive} = MultiSession.add_authenticated_user(conn, org)
    assert {:error, :inactive} = MultiSession.impersonate(conn, org)
    refute MultiSession.impersonable?(owner, org)
    refute MapSet.member?(MultiSession.impersonable_uuids(owner, [org]), org.uuid)
  end

  test "magic-link requests and preexisting links both refuse a managed organization" do
    org = Fixtures.organization()
    assert {:error, :user_not_found} = MagicLink.generate_magic_link(org.email)

    assert {:error, :invalid_token} =
             MagicLink.verify_magic_link(Fixtures.email_token(org, "magic_link"))

    person = Fixtures.person()
    assert {:ok, _, token} = MagicLink.generate_magic_link(person.email)
    assert {:ok, %{uuid: uuid}} = MagicLink.verify_magic_link(token)
    assert uuid == person.uuid
  end

  test "contact email never resolves to the organization for login" do
    person = Fixtures.person()
    org = Fixtures.organization(%{contact_email: person.email})
    assert Auth.get_user_by_email(org.contact_email).uuid == person.uuid
    assert {:ok, %{uuid: uuid}, _} = MagicLink.generate_magic_link(org.contact_email)
    assert uuid == person.uuid
  end

  test "password reset refuses delivery, old tokens, and a stale pre-conversion struct" do
    person = Fixtures.person()

    org =
      person
      |> Ecto.Changeset.change(
        account_type: "organization",
        organization_name: "Acme",
        managed_by_members: true
      )
      |> Repo.update!()

    old_hash = org.hashed_password

    assert {:error, :managed_organization} =
             Auth.deliver_user_reset_password_instructions(org, &"http://localhost/#{&1}")

    assert Auth.get_user_by_reset_password_token(Fixtures.email_token(org, "reset_password")) ==
             nil

    assert {:error, changeset} =
             Auth.reset_user_password(person, %{password: "DifferentPassword123!"})

    assert changeset.errors[:password]
    assert Repo.get!(User, org.uuid).hashed_password == old_hash
  end

  test "confirmation and email-change tokens cannot confirm or rename a managed organization" do
    org = Fixtures.organization(%{confirmed_at: nil})

    assert {:error, :already_confirmed} =
             Auth.deliver_user_confirmation_instructions(org, &"http://localhost/#{&1}")

    assert Auth.confirm_user(Fixtures.email_token(org, "confirm")) == :error
    assert Auth.update_user_email(org, Fixtures.email_token(org, "change:#{org.email}")) == :error
    assert Repo.get!(User, org.uuid).confirmed_at == nil
  end

  test "OAuth refuses both matching login email and a previously attached identity" do
    org = Fixtures.organization()
    data = oauth_data(org.email)
    assert {:error, :managed_organization} = OAuth.find_or_create_user(data)

    %OAuthProvider{}
    |> OAuthProvider.changeset(%{
      user_uuid: org.uuid,
      provider: "google",
      provider_uid: data.provider_uid,
      provider_email: org.email
    })
    |> Repo.insert!()

    assert {:error, :managed_organization} =
             OAuth.find_or_create_user(%{data | email: "other@example.com"})
  end

  test "QR approval and completion both refuse managed organizations", %{conn: conn} do
    start_supervised!(Keyfob.Store.ETS)
    Settings.update_boolean_setting("qr_login_enabled", true)
    org = Fixtures.organization()
    {:ok, %{token: request}} = QrLogin.create_request()
    assert {:error, :not_allowed} = QrLogin.approve(request, org.uuid)
    # A one-time approval minted before conversion still cannot finish.
    QrLogin.subscribe(request)
    assert :ok = Keyfob.approve(request, org.uuid, QrLogin.keyfob_opts())
    assert_receive {:keyfob, ^request, {:approved, login_token}}
    conn = get(conn, Routes.path("/users/qr-login/finish/#{login_token}"))
    assert redirected_to(conn) == Routes.path("/users/log-in")
    assert Plug.Conn.get_session(conn, :user_token) == nil
  end

  test "API keys and service-user creation refuse a managed owner even with a forged full scope" do
    org = Fixtures.organization()

    scope = %Scope{
      user: org,
      authenticated?: true,
      cached_roles: ["Owner"],
      cached_permissions: MapSet.new(["*", "api"])
    }

    assert {:error, :forbidden} = Keys.create_key(org, scope, %{name: "Denied"})
    assert {:error, :owner_inactive} = Keys.active_owner(%Key{user_uuid: org.uuid})
    assert {:error, :forbidden} = ServiceUsers.create(scope, %{roles: []})
  end

  defp oauth_data(email) do
    %{
      provider: "google",
      provider_uid: "managed-#{System.unique_integer([:positive])}",
      email: email,
      first_name: "Test",
      last_name: "User",
      image: nil,
      access_token: "at",
      refresh_token: nil,
      token_expires_at: nil,
      raw_info: %{user: %{"email" => email, "email_verified" => true}}
    }
  end
end
