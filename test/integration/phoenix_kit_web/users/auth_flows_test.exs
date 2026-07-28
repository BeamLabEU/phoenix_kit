defmodule PhoenixKitWeb.Users.AuthFlowsTest do
  @moduledoc """
  Login/registration flow behavior:

  - remember-me cookie persistence (registration + magic-link vs plain login)
  - configurable post-login / post-registration destinations
  - the `require_email_confirmation` toggle
  - the /users/confirm parked page moving confirmed users along
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.MagicLink
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  @remember_me_cookie "_phoenix_kit_web_user_remember_me"
  @password "ValidPassword123!"

  defp unique_email, do: "af_#{System.unique_integer([:positive])}@example.com"

  # Seed a throwaway Owner so users created inside tests get their intended
  # role rather than the first-user Owner promotion.
  setup do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, _} = Auth.admin_confirm_user(seed)
    :ok
  end

  defp register_user(attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(Map.merge(%{email: unique_email(), password: @password}, attrs))

    user
  end

  defp confirmed_user do
    user = register_user()
    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  # The deliver_* functions build the emailed URL through a callback, which is
  # the only place the plaintext token exists — capture it there.
  defp extract_token(deliver_fun) do
    test_pid = self()
    ref = make_ref()

    deliver_fun.(fn token ->
      send(test_pid, {ref, token})
      "http://localhost/#{token}"
    end)

    receive do
      {^ref, token} -> token
    after
      1000 -> flunk("no confirmation token was generated")
    end
  end

  defp login_conn(conn, user) do
    token = Auth.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
  end

  describe "remember-me cookie" do
    test "registration handoff POST sets the persistent cookie", %{conn: conn} do
      user = register_user()

      # The registration form now carries a hidden user[remember_me]=true and
      # trigger-action POSTs to /users/log-in?_action=registered.
      conn =
        post(conn, Routes.path("/users/log-in?_action=registered"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      assert %{value: value, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert is_binary(value) and value != ""
      assert max_age == 60 * 60 * 24 * 60
    end

    test "magic-link verify sets the persistent cookie", %{conn: conn} do
      user = confirmed_user()
      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)

      conn = get(conn, Routes.path("/users/magic-link/#{token}"))

      assert redirected_to(conn)
      assert %{value: value} = conn.resp_cookies[@remember_me_cookie]
      assert is_binary(value) and value != ""
    end

    test "plain login without the checkbox does NOT set the cookie", %{conn: conn} do
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      assert redirected_to(conn)
      refute Map.has_key?(conn.resp_cookies, @remember_me_cookie)
    end

    test "plain login with the checkbox still sets the cookie", %{conn: conn} do
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      assert Map.has_key?(conn.resp_cookies, @remember_me_cookie)
    end
  end

  describe "post-login destination" do
    test "defaults to /", %{conn: conn} do
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      assert redirected_to(conn) == "/"
    end

    test "honors the after_login_path setting", %{conn: conn} do
      Settings.update_setting("after_login_path", "/welcome")
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      assert redirected_to(conn) == "/welcome"
    end

    test "explicit return_to wins over the setting", %{conn: conn} do
      Settings.update_setting("after_login_path", "/welcome")
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "return_to" => "/somewhere-else"
          }
        })

      assert redirected_to(conn) == "/somewhere-else"
    end

    test "a non-local after_login_path value falls back to /", %{conn: conn} do
      # The settings form validates on save; this simulates a hand-edited DB row.
      Settings.update_setting("after_login_path", "https://evil.example")
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      assert redirected_to(conn) == "/"
    end
  end

  describe "post-registration destination" do
    test "honors the after_registration_path setting", %{conn: conn} do
      Settings.update_setting("after_registration_path", "/onboarding")
      user = register_user()

      conn =
        post(conn, Routes.path("/users/log-in?_action=registered"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      assert redirected_to(conn) == "/onboarding"
    end

    test "falls back to after_login_path when unset", %{conn: conn} do
      Settings.update_setting("after_login_path", "/welcome")
      user = register_user()

      conn =
        post(conn, Routes.path("/users/log-in?_action=registered"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      assert redirected_to(conn) == "/welcome"
    end

    test "form return_to wins over the setting", %{conn: conn} do
      Settings.update_setting("after_registration_path", "/onboarding")
      user = register_user()

      conn =
        post(conn, Routes.path("/users/log-in?_action=registered"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true",
            "return_to" => "/checkout"
          }
        })

      assert redirected_to(conn) == "/checkout"
    end

    test "a gate-stashed session return_to wins over the setting", %{conn: conn} do
      Settings.update_setting("after_registration_path", "/onboarding")
      user = register_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_return_to, "/protected-page")
        |> post(Routes.path("/users/log-in?_action=registered"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      assert redirected_to(conn) == "/protected-page"
    end
  end

  describe "auth page renders" do
    # Dead renders (get/2, not live/2): this markup is static, and the
    # connected mount of these LiveViews calls Presence.track_anonymous,
    # whose GenServer isn't running in the test env.
    #
    # A checked checkbox is `<input ... type="checkbox" ... checked>`; the
    # `<input type="hidden" ... value="false">` alongside it is the
    # component's unchecked-submit fallback, not the state.
    defp checkbox_checked?(html, name) do
      html
      |> String.split("<input")
      |> Enum.any?(fn frag ->
        String.contains?(frag, ~s(name="#{name}")) and
          String.contains?(frag, ~s(type="checkbox")) and
          String.contains?(frag, "checked")
      end)
    end

    defp has_field?(html, name), do: String.contains?(html, ~s(name="#{name}"))

    test "registration form shows remember_me, checked by default", %{conn: conn} do
      html = conn |> get(Routes.path("/users/register")) |> html_response(200)

      assert checkbox_checked?(html, "user[remember_me]")
    end

    test "magic-link completion form shows remember_me, checked by default", %{conn: conn} do
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(unique_email())

      html =
        conn
        |> get(Routes.path("/users/register/complete/#{token}"))
        |> html_response(200)

      assert checkbox_checked?(html, "user[remember_me]")
    end

    test "login form shows remember_me, checked by default", %{conn: conn} do
      html = conn |> get(Routes.path("/users/log-in")) |> html_response(200)

      assert checkbox_checked?(html, "user[remember_me]")
    end

    test "remember_me_default=false renders the box unchecked, not hidden", %{conn: conn} do
      Settings.update_setting("remember_me_default", "false")

      html = conn |> get(Routes.path("/users/log-in")) |> html_response(200)

      assert has_field?(html, "user[remember_me]")
      refute checkbox_checked?(html, "user[remember_me]")
    end

    test "remember_me_enabled=false hides the checkbox entirely", %{conn: conn} do
      Settings.update_setting("remember_me_enabled", "false")

      login = conn |> get(Routes.path("/users/log-in")) |> html_response(200)
      register = conn |> get(Routes.path("/users/register")) |> html_response(200)

      refute has_field?(login, "user[remember_me]")
      refute has_field?(register, "user[remember_me]")
    end

    test "registration page forwards ?return_to= into the form", %{conn: conn} do
      html =
        conn
        |> get(Routes.path("/users/register") <> "?return_to=/checkout")
        |> html_response(200)

      assert html =~ ~s(name="user[return_to]")
      assert html =~ ~s(value="/checkout")
    end
  end

  describe "remember-me site policy" do
    test "enabled=false blocks the cookie even when the param says true", %{conn: conn} do
      Settings.update_setting("remember_me_enabled", "false")
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      assert redirected_to(conn)
      refute Map.has_key?(conn.resp_cookies, @remember_me_cookie)
    end

    test "enabled=false makes magic-link login session-only", %{conn: conn} do
      Settings.update_setting("remember_me_enabled", "false")
      user = confirmed_user()
      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)

      conn = get(conn, Routes.path("/users/magic-link/#{token}"))

      assert redirected_to(conn)
      refute Map.has_key?(conn.resp_cookies, @remember_me_cookie)
    end

    test "default=false makes magic-link login session-only (no checkbox to tick)",
         %{conn: conn} do
      Settings.update_setting("remember_me_default", "false")
      user = confirmed_user()
      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)

      conn = get(conn, Routes.path("/users/magic-link/#{token}"))

      assert redirected_to(conn)
      refute Map.has_key?(conn.resp_cookies, @remember_me_cookie)
    end

    test "unticking the box keeps a login session-only", %{conn: conn} do
      user = confirmed_user()

      # An unticked daisyUI checkbox submits the hidden "false" fallback.
      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "false"
          }
        })

      assert redirected_to(conn)
      refute Map.has_key?(conn.resp_cookies, @remember_me_cookie)
    end

    test "helpers reflect the settings" do
      assert UserAuth.remember_me_enabled?()
      assert UserAuth.remember_me_default?()
      assert UserAuth.remember_me_params() == %{"remember_me" => "true"}

      Settings.update_setting("remember_me_default", "false")
      assert UserAuth.remember_me_enabled?()
      refute UserAuth.remember_me_default?()
      assert UserAuth.remember_me_params() == %{}

      # The master switch overrides the default in both directions.
      Settings.update_setting("remember_me_default", "true")
      Settings.update_setting("remember_me_enabled", "false")
      refute UserAuth.remember_me_enabled?()
      refute UserAuth.remember_me_default?()
      assert UserAuth.remember_me_params() == %{}
    end
  end

  describe "open-redirect hardening" do
    # Guard-level cases live in test/phoenix_kit/utils/routes_test.exs; this
    # pins the end-to-end behavior through a real redirect sink.
    test "a control-char return_to does not reach the parked page's redirect", %{conn: conn} do
      user = confirmed_user()
      conn = login_conn(conn, user)

      # Confirmed user mounts → redirected onward; must fall back to "/",
      # never to the smuggled destination.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(
                 conn,
                 Routes.path("/users/confirm") <>
                   "?return_to=" <>
                   URI.encode_www_form("/\t/evil.example")
               )
    end
  end

  describe "flash rendering on auth pages" do
    # Flash is owned by the layer inside the LiveView tree. A second copy in
    # the root layout rendered every message twice with duplicate
    # `flash-<kind>` element ids (which breaks LiveView DOM patching) and
    # froze at its dead-render value.
    test "a flash renders exactly once, with one element id", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> Phoenix.Controller.put_flash(:error, "UNIQUEFLASHMARKER")

      html = conn |> get(Routes.path("/users/log-in")) |> html_response(200)

      assert length(String.split(html, "UNIQUEFLASHMARKER")) - 1 == 1
      assert length(String.split(html, ~s(id="flash-error"))) - 1 == 1
    end

    test "auth pages render their content in standalone mode", %{conn: conn} do
      # Regression: the standalone fallback used to nest a second full
      # document and swallow the page body entirely.
      html = conn |> get(Routes.path("/users/log-in")) |> html_response(200)

      assert html =~ "login_form"
      assert length(String.split(html, "<!DOCTYPE html>")) - 1 == 1
    end
  end

  describe "settings validation" do
    test "accepts local paths and empty values" do
      changeset =
        Settings.validate_settings(%{
          "after_login_path" => "/welcome",
          "after_registration_path" => ""
        })

      refute changeset.errors[:after_login_path]
      refute changeset.errors[:after_registration_path]
    end

    test "rejects absolute URLs and protocol-relative paths" do
      changeset =
        Settings.validate_settings(%{
          "after_login_path" => "https://evil.example",
          "after_registration_path" => "//evil.example"
        })

      assert {msg, _} = changeset.errors[:after_login_path]
      assert msg =~ "local path"
      assert {msg2, _} = changeset.errors[:after_registration_path]
      assert msg2 =~ "local path"
    end

    test "require_email_confirmation only accepts boolean strings" do
      changeset = Settings.validate_settings(%{"require_email_confirmation" => "sometimes"})
      assert changeset.errors[:require_email_confirmation]

      changeset = Settings.validate_settings(%{"require_email_confirmation" => "false"})
      refute changeset.errors[:require_email_confirmation]
    end
  end

  describe "require_email_confirmation" do
    defp plug_conn(conn, user) do
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> Plug.Conn.assign(:phoenix_kit_current_user, user)
    end

    test "on (default): unconfirmed users are parked at /users/confirm", %{conn: conn} do
      user = register_user()

      conn = conn |> plug_conn(user) |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == Routes.path("/users/confirm")
      # The originally requested page is stashed so /users/confirm can move
      # the user along once confirmed.
      assert get_session(conn, :user_return_to)
    end

    test "off: unconfirmed users pass through", %{conn: conn} do
      Settings.update_setting("require_email_confirmation", "false")
      user = register_user()

      conn = conn |> plug_conn(user) |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end

    test "off: unconfirmed users pass the scope-based plug too", %{conn: conn} do
      Settings.update_setting("require_email_confirmation", "false")
      user = register_user()

      conn =
        conn
        |> plug_conn(user)
        |> Plug.Conn.assign(
          :phoenix_kit_current_scope,
          Scope.for_user(user)
        )
        |> UserAuth.require_authenticated_scope([])

      refute conn.halted
    end

    test "anonymous users still get sent to login either way", %{conn: conn} do
      Settings.update_setting("require_email_confirmation", "false")

      conn = conn |> plug_conn(nil) |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == Routes.path("/users/log-in")
    end

    # The owner/admin/module-access on_mount hooks gate on confirmation too;
    # they must honor the setting like the other three sites, or turning it
    # off leaves admin surfaces silently parked.
    test "off: elevated on_mount hooks no longer park unconfirmed users", %{conn: conn} do
      Settings.update_setting("require_email_confirmation", "false")

      {admin, _token} = create_admin_user()
      {:ok, admin} = Auth.admin_unconfirm_user(admin)
      conn = login_conn(conn, admin)

      # Reaching the LiveView at all means the confirmation branch didn't halt.
      assert {:ok, _lv, _html} = live(conn, Routes.path("/admin/settings/users"))
    end

    test "on (default): elevated on_mount hooks park unconfirmed users with return_to",
         %{conn: conn} do
      {admin, _token} = create_admin_user()
      {:ok, admin} = Auth.admin_unconfirm_user(admin)
      conn = login_conn(conn, admin)

      assert {:error, {:redirect, %{to: to}}} = live(conn, Routes.path("/admin/settings/users"))
      assert to =~ Routes.path("/users/confirm")
      # The originally requested admin page is preserved for the advance.
      assert to =~ "return_to="
    end
  end

  describe "/users/confirm parked page" do
    test "already-confirmed user is moved along on mount (DB flip + refresh case)", %{conn: conn} do
      user = confirmed_user()
      conn = login_conn(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, Routes.path("/users/confirm"))
    end

    test "confirmed user is moved to return_to when present", %{conn: conn} do
      user = confirmed_user()
      conn = login_conn(conn, user)

      assert {:error, {:redirect, %{to: "/after"}}} =
               live(conn, Routes.path("/users/confirm") <> "?return_to=/after")
    end

    test "non-local return_to is ignored", %{conn: conn} do
      user = confirmed_user()
      conn = login_conn(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} =
               live(
                 conn,
                 Routes.path("/users/confirm") <>
                   "?return_to=" <>
                   URI.encode_www_form("https://evil.example")
               )
    end

    test "confirmed user honors after_login_path", %{conn: conn} do
      Settings.update_setting("after_login_path", "/welcome")
      user = confirmed_user()
      conn = login_conn(conn, user)

      assert {:error, {:redirect, %{to: "/welcome"}}} = live(conn, Routes.path("/users/confirm"))
    end

    test "parked user is moved along live when an admin confirms them", %{conn: conn} do
      user = register_user()
      conn = login_conn(conn, user)

      {:ok, lv, html} = live(conn, Routes.path("/users/confirm"))
      assert html =~ user.email

      {:ok, _user} = Auth.admin_confirm_user(user)

      assert_redirect(lv, "/", 3000)
    end

    test "parked user keeps their original destination on live advance", %{conn: conn} do
      user = register_user()
      conn = login_conn(conn, user)

      {:ok, lv, _html} = live(conn, Routes.path("/users/confirm") <> "?return_to=/after")

      {:ok, _user} = Auth.admin_confirm_user(user)

      assert_redirect(lv, "/after", 3000)
    end

    test "another user's confirmation does not move the parked user", %{conn: conn} do
      user = register_user()
      other = register_user()
      conn = login_conn(conn, user)

      {:ok, lv, _html} = live(conn, Routes.path("/users/confirm"))

      {:ok, _} = Auth.admin_confirm_user(other)

      # Still parked: rendering succeeds (an assert_redirect here would flake
      # on timing, so assert the LV is alive and un-redirected instead).
      assert render(lv) =~ "confirmation"
    end

    test "anonymous visitor still gets the resend form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, Routes.path("/users/confirm"))

      assert html =~ "confirmation"
    end

    test "a confirmation landing between mount and subscribe is not missed", %{conn: conn} do
      user = register_user()
      conn = login_conn(conn, user)

      # Simulates the race: the row flips confirmed while the LV is mounting,
      # so no broadcast can reach it. The post-subscribe re-read must catch it.
      {:ok, _user} = Auth.admin_confirm_user(user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, Routes.path("/users/confirm"))
    end
  end

  describe "email-link confirmation destination" do
    test "confirming via the emailed link honors after_login_path", %{conn: conn} do
      Settings.update_setting("after_login_path", "/welcome")
      user = register_user()

      token =
        extract_token(fn url_fun ->
          Auth.deliver_user_confirmation_instructions(user, url_fun)
        end)

      {:ok, lv, _html} = live(conn, Routes.path("/users/confirm/#{token}"))

      lv |> element("#confirmation_form") |> render_submit()

      assert_redirect(lv, "/welcome")
    end

    test "confirming via the emailed link honors a session return_to", %{conn: conn} do
      user = register_user()

      token =
        extract_token(fn url_fun ->
          Auth.deliver_user_confirmation_instructions(user, url_fun)
        end)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_return_to, "/protected-page")

      {:ok, lv, _html} = live(conn, Routes.path("/users/confirm/#{token}"))

      lv |> element("#confirmation_form") |> render_submit()

      assert_redirect(lv, "/protected-page")
    end
  end
end
