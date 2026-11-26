defmodule PhoenixKit.Integration.Users.FirstOwnerTest do
  @moduledoc """
  Who becomes the first Owner (`PhoenixKit.Users.Setup`): the policy matrix
  of the public doors, the one-time setup token, and the console path
  (`Setup.create_owner/2`, `mix phoenix_kit.create_owner`).

  Every test starts from a world with no active Owner (the suite's committed
  seed Owner is demoted inside the sandbox, see `DataCase`) unless it says
  otherwise.
  """

  # Swaps application env (`:first_owner`) and drives LiveViews.
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureIO
  import PhoenixKit.DataCase, only: [errors_on: 1, demote_seed_owner: 0]
  import ExUnit.CaptureLog

  alias Mix.Tasks.PhoenixKit.CreateOwner
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Test.Fixtures
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.{MagicLinkRegistration, OAuth, RoleAssignment, Roles, Setup}
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"

  setup do
    previous = Application.fetch_env(:phoenix_kit, :first_owner)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :first_owner, value)
        :error -> Application.delete_env(:phoenix_kit, :first_owner)
      end
    end)

    :ok
  end

  defp no_owner(_context) do
    demote_seed_owner()
    assert Roles.count_active_owners() == 0
    :ok
  end

  defp put_policy(policy), do: Application.put_env(:phoenix_kit, :first_owner, policy)

  defp email, do: "first-owner-#{System.unique_integer([:positive])}@example.com"
  defp attrs(email), do: %{"email" => email, "password" => @password}

  defp owner?(email) do
    case Auth.get_user_by_email(email) do
      nil -> false
      user -> Roles.user_has_role?(user, "Owner")
    end
  end

  defp token_row_count,
    do: Repo.aggregate(from(s in Setting, where: s.key == "first_owner_setup_token_hash"), :count)

  defp register_page(conn, query \\ "") do
    {:ok, view, html} = live(conn, Routes.path("/users/register") <> query)
    {view, html}
  end

  defp submit(view, email) do
    render_submit(view, "save", %{"user" => %{"email" => email, "password" => @password}})
  end

  describe "the registration page, with no Owner" do
    setup :no_owner

    test "without a setup token on a public host: refused, nothing created", %{conn: conn} do
      {view, _html} = register_page(conn)
      address = email()

      assert submit(view, address) =~ "no owner yet"
      refute Auth.get_user_by_email(address)
      assert Roles.count_active_owners() == 0
    end

    test "with the setup token: the registrant becomes the Owner and the token is spent",
         %{conn: conn} do
      {:ok, token} = Setup.generate_setup_token()
      {view, html} = register_page(conn, "?setup=" <> token)
      assert html =~ "Setup link accepted"

      address = email()
      submit(view, address)

      assert owner?(address)
      assert Auth.get_user_by_email(address).confirmed_at
      refute Setup.setup_token_valid?(token)
      assert token_row_count() == 0
    end

    test "with a wrong token: refused, and the page says the link is not valid", %{conn: conn} do
      {:ok, _token} = Setup.generate_setup_token()
      {view, html} = register_page(conn, "?setup=not-the-token")
      assert html =~ "setup link is not valid"

      address = email()
      assert submit(view, address) =~ "no owner yet"
      refute Auth.get_user_by_email(address)
    end

    test "a newer token replaces the older one", %{conn: _conn} do
      {:ok, old} = Setup.generate_setup_token()
      {:ok, new} = Setup.generate_setup_token()

      refute Setup.setup_token_valid?(old)
      assert Setup.setup_token_valid?(new)
      assert token_row_count() == 1
    end

    test "under the :open policy the first registrant is the Owner, as before", %{conn: conn} do
      put_policy(:open)
      {view, _html} = register_page(conn)
      address = email()
      submit(view, address)

      assert owner?(address)
    end
  end

  describe "the registration page, with an Owner" do
    test "a registrant is a plain user, and a setup token changes nothing", %{conn: conn} do
      assert Roles.count_active_owners() > 0
      {view, html} = register_page(conn, "?setup=whatever")
      assert html =~ "already has an owner"

      address = email()
      submit(view, address)

      assert Auth.get_user_by_email(address)
      refute owner?(address)
    end
  end

  describe "Auth.register_user/3 with no Owner" do
    setup :no_owner

    test "a local dev claim makes the Owner" do
      address = email()

      assert {:ok, _} =
               Auth.register_user(attrs(address), nil,
                 site_wide: true,
                 first_owner: %{setup_token: nil, local: true}
               )

      assert owner?(address)
    end

    test "site_wide: true without a claim is held to the public claim and refused" do
      address = email()
      assert {:error, changeset} = Auth.register_user(attrs(address), nil, site_wide: true)
      assert Enum.any?(errors_on(changeset).email, &(&1 =~ "no owner yet"))
      refute Auth.get_user_by_email(address)
    end

    test "code-level callers (seeds, fixtures) still make the first user the Owner" do
      address = email()
      assert {:ok, _} = Auth.register_user(attrs(address))
      assert owner?(address)
    end

    test "PhoenixKit.Test.Fixtures still makes the first user the Owner" do
      user = Fixtures.user_fixture()
      assert Roles.user_has_role?(user, "Owner")
    end

    test "a user an admin adds is never the first Owner" do
      admin = Fixtures.user_fixture()
      # The fixture above took the Owner role; take it away to get back to 0.
      Repo.delete_all(from(a in RoleAssignment, where: a.user_uuid == ^admin.uuid))

      address = email()

      log =
        capture_log(fn -> assert {:ok, _} = Auth.admin_create_user(attrs(address), admin) end)

      refute owner?(address)
      assert log =~ "did not prove the right"
    end

    test "the token is single use: a second grant with it is refused" do
      {:ok, token} = Setup.generate_setup_token()
      claim = %{setup_token: token, local: false}

      assert Setup.grant_first_owner?(claim, Repo)
      refute Setup.grant_first_owner?(claim, Repo)
      refute Setup.setup_token_valid?(token)
    end

    test "with a valid token, the first registration is Owner and a second with it is refused" do
      {:ok, token} = Setup.generate_setup_token()
      claim = %{setup_token: token, local: false}
      first = email()

      assert {:ok, user} =
               Auth.register_user(attrs(first), nil, site_wide: true, first_owner: claim)

      assert owner?(first)

      # Back to no Owner: the spent token proves nothing any more.
      Repo.delete_all(from(a in RoleAssignment, where: a.user_uuid == ^user.uuid))

      second = email()

      assert {:error, _} =
               Auth.register_user(attrs(second), nil, site_wide: true, first_owner: claim)

      refute Auth.get_user_by_email(second)
    end

    test ":token policy ignores the local case built by claim/4" do
      put_policy(:token)
      claim = Setup.claim(nil, "localhost", "127.0.0.1", dev: true)
      refute claim.local
      assert {:error, _} = Auth.register_user(attrs(email()), nil, first_owner: claim)
    end
  end

  describe "the other sign-up doors, with no Owner" do
    setup :no_owner

    test "magic-link completion without a claim is refused" do
      address = email()
      {:ok, ^address, token} = MagicLinkRegistration.send_registration_link(address)

      assert {:error, %Ecto.Changeset{}} =
               MagicLinkRegistration.complete_registration(token, %{"password" => @password})

      refute Auth.get_user_by_email(address)
    end

    test "the magic-link request page says sign-up is closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/users/register/magic-link"))
      assert render_submit(view, "send_magic_link", %{"email" => email()}) =~ "no owner yet"
    end

    test "OAuth sign-up without a claim is refused" do
      address = email()

      data = %{
        provider: "google",
        provider_uid: "uid-#{System.unique_integer([:positive])}",
        email: address,
        first_name: "T",
        last_name: "P",
        image: nil,
        access_token: "token",
        refresh_token: nil,
        token_expires_at: nil,
        raw_info: %{user: %{"email_verified" => true}}
      }

      assert {:error, %Ecto.Changeset{}} = OAuth.find_or_create_user(data)
      refute Auth.get_user_by_email(address)

      assert {:ok, _user, :created} =
               OAuth.find_or_create_user(data, false, nil, %{setup_token: nil, local: true})

      assert owner?(address)
    end
  end

  describe "claim/4" do
    test "local only on a dev server, a loopback host and a loopback or unknown peer" do
      assert Setup.claim(nil, "localhost", "127.0.0.1", dev: true).local
      assert Setup.claim(nil, "127.0.0.1", nil, dev: true).local
      assert Setup.claim(nil, "[::1]", "::1", dev: true).local
      assert Setup.claim(nil, "app.localhost", "unknown", dev: true).local

      refute Setup.claim(nil, "localhost", "127.0.0.1", dev: false).local
      refute Setup.claim(nil, "example.com", "127.0.0.1", dev: true).local
      refute Setup.claim(nil, "localhost", "203.0.113.7", dev: true).local
      refute Setup.claim(nil, "localhost.example.com", "127.0.0.1", dev: true).local
    end

    test "blank tokens are no token" do
      assert Setup.claim("  ", "example.com", nil).setup_token == nil
      assert Setup.claim(123, "example.com", nil).setup_token == nil
      assert Setup.claim("abc", "example.com", nil).setup_token == "abc"
    end

    test "an unknown policy is read as :token" do
      put_policy(:wide_open)
      assert capture_log(fn -> assert Setup.policy() == :token end) =~ "not one of"
    end
  end

  describe "the setup link and boot message" do
    test "carry the url_prefix and the token" do
      url = Setup.setup_url("TOKEN")
      assert url =~ Routes.path("/users/register", locale: :none) <> "?setup=TOKEN"

      message = Setup.boot_message("TOKEN")
      assert message =~ url
      assert message =~ "mix phoenix_kit.create_owner"
    end

    test "announce_at_boot/1 stays silent in tests" do
      assert :ok = Setup.announce_at_boot(delay: 0)
      assert token_row_count() == 0
    end
  end

  describe "Setup.create_owner/2" do
    setup :no_owner

    test "creates a confirmed, active Owner with a generated password, and spends the token" do
      {:ok, _token} = Setup.generate_setup_token()
      address = email()

      assert {:ok, %{user: user, created: true, password: password}} = Setup.create_owner(address)
      assert is_binary(password) and byte_size(password) >= 12
      assert user.confirmed_at
      assert user.is_active
      assert owner?(address)
      assert {:ok, _} = Auth.get_user_by_email_and_password(address, password)
      assert token_row_count() == 0
    end

    test "uses a given password" do
      address = email()
      assert {:ok, %{password: @password}} = Setup.create_owner(address, password: @password)
      assert {:ok, _} = Auth.get_user_by_email_and_password(address, @password)
    end

    test "refuses a password the registration rules refuse, and creates nothing" do
      address = email()
      assert {:error, %Ecto.Changeset{}} = Setup.create_owner(address, password: "short")
      refute Auth.get_user_by_email(address)
    end

    test "promotes an existing account, leaving its password alone" do
      address = email()

      capture_log(fn ->
        send(self(), Auth.register_user(attrs(address), nil, first_owner: :deny))
      end)

      assert_received {:ok, user}
      refute owner?(address)

      assert {:ok, %{user: promoted, created: false, password: nil}} = Setup.create_owner(address)
      assert promoted.uuid == user.uuid
      assert promoted.confirmed_at
      assert owner?(address)
      assert {:ok, _} = Auth.get_user_by_email_and_password(address, @password)
    end

    test "refuses when an active Owner exists, unless forced" do
      {:ok, _} = Setup.create_owner(email())
      second = email()

      assert {:error, :owner_exists} = Setup.create_owner(second)
      refute Auth.get_user_by_email(second)

      assert {:ok, %{created: true}} = Setup.create_owner(second, force: true)
      assert owner?(second)
    end
  end

  describe "mix phoenix_kit.create_owner" do
    setup :no_owner

    test "creates the Owner and prints the password once with the prefixed sign-in URL" do
      address = email()
      output = capture_io(fn -> CreateOwner.create(address, []) end)

      assert output =~ "Created Owner account: #{address}"
      assert output =~ "Password: "
      assert output =~ Routes.path("/users/log-in", locale: :none)
      assert owner?(address)
    end

    test "refuses with exit 1 when an Owner exists" do
      {:ok, _} = Setup.create_owner(email())
      second = email()

      stderr =
        capture_io(:stderr, fn ->
          assert catch_exit(CreateOwner.create(second, [])) == {:shutdown, 1}
        end)

      assert stderr =~ "already exists"
      refute Auth.get_user_by_email(second)
    end

    test "rejects missing and unknown arguments before touching the app" do
      capture_io(:stderr, fn ->
        assert catch_exit(CreateOwner.run([])) == {:shutdown, 1}
        assert catch_exit(CreateOwner.run(["a@b.c", "--bogus"])) == {:shutdown, 1}

        assert catch_exit(CreateOwner.run(["a@b.c", "--password", "x", "--password-stdin"])) ==
                 {:shutdown, 1}
      end)
    end
  end
end
