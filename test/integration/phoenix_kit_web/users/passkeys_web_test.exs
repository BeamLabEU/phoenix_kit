defmodule PhoenixKitWeb.Integration.Users.PasskeysWebTest do
  @moduledoc """
  Passkeys through the web: the sign-in page and its completion controller, the
  Passkeys section of the account settings, the admin's card on a user's page, and the
  switch on Settings -> Authorization. The browser is played by
  `PhoenixKit.Test.SoftAuthenticator` through the hooks' events.

  `async: false`: the tests switch `passkey_login_enabled`.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.SoftAuthenticator
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Passkeys
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {:ok, _} = Settings.update_setting("passkey_login_enabled", "true")
    on_exit(fn -> Settings.update_setting("passkey_login_enabled", "false") end)
    # A peer of its own, so the passkey rate limit of one test never reaches another.
    {:ok, conn: with_peer(conn, unique_ip())}
  end

  # A public documentation address: a loopback or private peer counts as a proxy
  # and is keyed by the forwarded header these requests do not carry.
  defp unique_ip do
    n = System.unique_integer([:positive])
    {203, 0, 113, rem(n, 250) + 1}
  end

  defp with_peer(conn, ip) do
    {adapter, payload} = conn.adapter
    peer = %{address: ip, port: 111_317, ssl_cert: nil}
    %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer)}, remote_ip: ip}
  end

  defp user do
    email = "passkey_web_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  defp add_passkey(user) do
    auth = SoftAuthenticator.new()
    {challenge, options} = Passkeys.registration_options(user)

    {:ok, passkey} =
      Passkeys.register(user, challenge, SoftAuthenticator.attest(auth, options),
        impersonated: false,
        session_token: Auth.generate_user_session_token(user)
      )

    {auth, passkey}
  end

  describe "the sign-in page" do
    test "offers the passkey button and the email-field suggestions", %{conn: conn} do
      {:ok, _view, html} = live(conn, Routes.path("/users/log-in"))

      assert html =~ "Sign in with passkey"
      assert html =~ ~s(phx-hook="PasskeySignIn")
      assert html =~ ~s(autocomplete="username webauthn")
    end

    test "offers neither while switched off", %{conn: conn} do
      {:ok, _} = Settings.update_setting("passkey_login_enabled", "false")
      {:ok, view, html} = live(conn, Routes.path("/users/log-in"))

      refute html =~ "Sign in with passkey"
      refute html =~ "webauthn"
      render_hook(view, "passkey_options", %{})
      assert_reply(view, reply)
      assert reply == %{}
    end

    test "a passkey signs the person in through a one-time link", %{conn: conn} do
      user = user()
      {auth, _} = add_passkey(user)
      {:ok, view, _html} = live(conn, Routes.path("/users/log-in"))

      render_hook(view, "passkey_options", %{})
      assert_reply(view, %{options: options})

      answer = SoftAuthenticator.assert(auth, options, user.uuid)
      render_hook(view, "passkey_sign_in", Map.put(answer, "remember_me", "true"))
      {path, _flash} = assert_redirect(view)

      assert path =~ "/users/passkey/finish/"
      assert path =~ "remember_me=true"

      conn = get(recycle(conn), path)
      assert get_session(conn, :user_token)
      assert conn.resp_cookies["_phoenix_kit_web_user_remember_me"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed in with a passkey."

      # The link works once.
      conn = get(build_conn(), path)
      assert redirected_to(conn) == Routes.path("/users/log-in")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "keeps return_to through the one-time link", %{conn: conn} do
      user = user()
      {auth, _} = add_passkey(user)

      {:ok, view, _html} =
        live(
          conn,
          Routes.path("/users/log-in") <> "?return_to=" <> URI.encode_www_form("/admin/users")
        )

      render_hook(view, "passkey_options", %{})
      assert_reply(view, %{options: options})
      render_hook(view, "passkey_sign_in", SoftAuthenticator.assert(auth, options, user.uuid))
      {path, _flash} = assert_redirect(view)

      assert path =~ "return_to=%2Fadmin%2Fusers"
      assert redirected_to(get(recycle(conn), path)) == "/admin/users"
    end

    test "an answer cannot be used twice: the challenge goes with the first", %{conn: conn} do
      user = user()
      {auth, _} = add_passkey(user)
      {:ok, view, _html} = live(conn, Routes.path("/users/log-in"))

      render_hook(view, "passkey_options", %{})
      assert_reply(view, %{options: options})
      answer = SoftAuthenticator.assert(auth, options, user.uuid, user_verified: false)

      assert render_hook(view, "passkey_sign_in", answer) =~ "That passkey did not work"

      # The same challenge again, now properly signed: there is no challenge left.
      good = SoftAuthenticator.assert(auth, options, user.uuid)
      assert render_hook(view, "passkey_sign_in", good) =~ "That passkey did not work"
    end

    test "an answer with no options asked first is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/users/log-in"))

      assert render_hook(view, "passkey_sign_in", %{"rawId" => "AA"}) =~
               "That passkey did not work"
    end

    # Limited before any lookup: the garbage below names no passkey at all.
    test "answers are rate limited before anything is looked up", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/users/log-in"))

      htmls =
        for _ <- 1..11, do: render_hook(view, "passkey_sign_in", %{"rawId" => "AA"})

      assert List.last(htmls) =~ "Too many attempts"
    end

    test "a browser that could not use a passkey gets the same message", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/users/log-in"))

      assert render_hook(view, "passkey_failed", %{"name" => "SecurityError"}) =~
               "That passkey did not work"
    end
  end

  describe "the completion link" do
    test "is refused while switched off", %{conn: conn} do
      token = Passkeys.mint_login_token(user())
      {:ok, _} = Settings.update_setting("passkey_login_enabled", "false")

      conn = get(conn, Routes.path("/users/passkey/finish/#{token}"))
      assert redirected_to(conn) == Routes.path("/users/log-in")
      refute get_session(conn, :user_token)
    end

    test "is refused for garbage", %{conn: conn} do
      conn = get(conn, Routes.path("/users/passkey/finish/nope"))
      assert redirected_to(conn) == Routes.path("/users/log-in")
      refute get_session(conn, :user_token)
    end

    test "a sign-in without the box ticked leaves no remember-me cookie", %{conn: conn} do
      token = Passkeys.mint_login_token(user())
      conn = get(conn, Routes.path("/users/passkey/finish/#{token}"))

      assert get_session(conn, :user_token)
      # Either no cookie at all, or the deletion of one (max_age 0).
      assert conn.resp_cookies["_phoenix_kit_web_user_remember_me"][:max_age] in [nil, 0]
    end
  end

  describe "the account settings section" do
    setup %{conn: conn} do
      user = user()
      {:ok, conn: log_in_user(conn, user), user: user}
    end

    defp security(conn), do: live(conn, Routes.path("/profile/settings/security"))

    test "a fresh sign-in can add a passkey, and the person is told", %{conn: conn, user: user} do
      {:ok, view, html} = security(conn)
      assert html =~ "Add a passkey"

      section = element(view, "#user-settings-passkeys")
      render_hook(section, "passkey_registration_options", %{})
      assert_reply(view, %{options: options})

      html =
        render_hook(
          section,
          "passkey_register",
          SoftAuthenticator.attest(SoftAuthenticator.new(), options)
        )

      assert html =~ "Passkey added: Chrome on macOS"
      assert [%{name: "Chrome on macOS"}] = Passkeys.list(user)

      assert_email_sent(fn email ->
        assert email.subject == "A passkey was added to your account"
      end)
    end

    test "a sign-in older than the window cannot, and is told why", %{conn: conn, user: user} do
      old = DateTime.utc_now() |> DateTime.add(-(Passkeys.fresh_session_minutes() + 5), :minute)

      Repo.update_all(
        from(t in UserToken, where: t.user_uuid == ^user.uuid and t.context == "session"),
        set: [inserted_at: old]
      )

      {:ok, view, html} = security(conn)
      refute html =~ "Add a passkey"
      assert html =~ "sign out and sign in again"

      # A forged event gets no challenge either.
      section = element(view, "#user-settings-passkeys")
      render_hook(section, "passkey_registration_options", %{})
      assert_reply(view, reply)
      assert reply == %{}
    end

    test "a forged answer without asked options is refused", %{conn: conn, user: user} do
      {:ok, view, _html} = security(conn)
      section = element(view, "#user-settings-passkeys")

      {_challenge, options} = Passkeys.registration_options(user)

      html =
        render_hook(
          section,
          "passkey_register",
          SoftAuthenticator.attest(SoftAuthenticator.new(), options)
        )

      assert html =~ "could not be added"
      assert Passkeys.list(user) == []
    end

    test "rename and remove", %{conn: conn, user: user} do
      {_auth, passkey} = add_passkey(user)
      {:ok, view, html} = security(conn)
      assert html =~ "Chrome on macOS"

      view |> element("#user-settings-passkeys button", "Rename") |> render_click()

      view
      |> form("#user-settings-passkeys-rename-#{passkey.uuid}", passkey: %{name: "Work laptop"})
      |> render_submit()

      assert [%{name: "Work laptop"}] = Passkeys.list(user)

      view |> element("#user-settings-passkeys li button", "Remove") |> render_click()

      html =
        view |> element("#user-settings-passkeys button.btn-error", "Remove") |> render_click()

      assert html =~ "Passkey removed: Work laptop"
      assert Passkeys.list(user) == []
    end

    test "the section is not there while switched off", %{conn: conn} do
      {:ok, _} = Settings.update_setting("passkey_login_enabled", "false")
      {:ok, _view, html} = security(conn)
      refute html =~ "Add a passkey"
      refute html =~ ~s(id="user-settings-passkeys")
    end
  end

  describe "the admin's user page" do
    test "an admin sees a user's passkeys and removes one, but cannot add", %{conn: conn} do
      {admin, _token} = create_admin_user()
      user = user()
      {_auth, _passkey} = add_passkey(user)

      {:ok, view, html} =
        live(log_in_user(conn, admin), Routes.path("/admin/users/view/#{user.uuid}?tab=account"))

      assert html =~ "Chrome on macOS"
      refute html =~ "Add a passkey"
      refute html =~ "Rename"

      view |> element("#user-details-passkeys li button", "Remove") |> render_click()

      html =
        view |> element("#user-details-passkeys button.btn-error", "Remove") |> render_click()

      assert html =~ "Passkey removed"
      assert Passkeys.list(user) == []
    end

    test "a forged add or rename from the admin page is refused", %{conn: conn} do
      {admin, _token} = create_admin_user()
      user = user()
      {_auth, passkey} = add_passkey(user)

      {:ok, view, _html} =
        live(log_in_user(conn, admin), Routes.path("/admin/users/view/#{user.uuid}?tab=account"))

      card = element(view, "#user-details-passkeys")
      render_hook(card, "passkey_registration_options", %{})
      assert_reply(view, reply)
      assert reply == %{}

      assert render_hook(card, "start_rename", %{"uuid" => passkey.uuid}) =~
               "You cannot change these passkeys"
    end
  end

  test "Settings -> Authorization saves the switch", %{conn: conn} do
    {:ok, _} = Settings.update_setting("passkey_login_enabled", "false")
    {admin, _token} = create_admin_user()

    {:ok, view, html} =
      live(log_in_user(conn, admin), Routes.path("/admin/settings/authorization"))

    assert html =~ "Enable sign-in with a passkey"
    assert html =~ Passkeys.relying_party().rp_id

    view
    |> form("#authorization_settings_form", %{"settings" => %{"passkey_login_enabled" => "true"}})
    |> render_submit()

    assert Passkeys.enabled?()
  end
end
