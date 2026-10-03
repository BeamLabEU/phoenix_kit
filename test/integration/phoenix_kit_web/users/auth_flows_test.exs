defmodule PhoenixKitWeb.Users.AuthFlowsTest do
  @moduledoc """
  Login/registration flow behavior:

  - remember-me cookie persistence (registration + magic-link vs plain login)
  - configurable post-login / post-registration destinations
  - the `require_email_confirmation` toggle
  - the /users/confirm parked page moving confirmed users along
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.MagicLink
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  @remember_me_cookie "_phoenix_kit_web_user_remember_me"
  @password "ValidPassword123!"

  defp unique_email, do: "af_#{System.unique_integer([:positive])}@example.com"

  # Seed a throwaway Owner so users created inside tests get their intended
  # role rather than the first-user Owner promotion.
  #
  # Each test also gets its own source IP. Login rate limiting keys on the IP
  # (15/min) as well as the address, and this file performs several logins per
  # test; sharing 127.0.0.1 let a busy run exhaust the bucket and bounce later
  # tests back to the login page. Hammer 7 dropped bucket deletion, so a unique
  # IP is the way to isolate rather than reset.
  setup %{conn: conn} do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, _} = Auth.admin_confirm_user(seed)
    {:ok, conn: with_peer(conn, unique_ip())}
  end

  defp unique_ip do
    n = System.unique_integer([:positive])
    {127, 1, n |> div(256) |> rem(256), rem(n, 256)}
  end

  # Rate limiting reads the peer via `Plug.Conn.get_peer_data/1`, NOT
  # `conn.remote_ip` — and the test adapter reports the same peer for every
  # conn, so all 56 tests shared one login bucket (15/min) and a busy ordering
  # bounced later tests back to the login page. Giving each test its own peer
  # models distinct clients; Hammer 7 removed bucket deletion, so isolating
  # beats resetting.
  defp with_peer(conn, ip) do
    {adapter, payload} = conn.adapter
    peer = %{address: ip, port: 111_317, ssl_cert: nil}
    %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer)}, remote_ip: ip}
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

  # A non-persistent login must leave no USABLE cookie. It may still appear in
  # resp_cookies as an explicit expiry (value "", max_age 0) — that is the
  # stronger outcome: it actively clears a stale cookie whose token a password
  # change may have deleted, rather than leaving it to keep failing for 60 days.
  defp persistent_cookie?(conn) do
    case conn.resp_cookies[@remember_me_cookie] do
      %{value: v} when is_binary(v) and v != "" ->
        Map.get(conn.resp_cookies[@remember_me_cookie], :max_age) != 0

      _ ->
        false
    end
  end

  # A genuinely-signed remember-me cookie, minted the way a real login does —
  # hand-signing it needs a secret_key_base the bare test conn doesn't carry.
  defp remember_me_cookie_for(user) do
    conn =
      post(with_peer(build_conn(), unique_ip()), Routes.path("/users/log-in"), %{
        "user" => %{
          "email_or_username" => user.email,
          "password" => @password,
          "remember_me" => "true"
        }
      })

    conn.resp_cookies[@remember_me_cookie].value
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

      # The registration form carries a "Keep me logged in" checkbox
      # (user[remember_me], checked by default per remember_me_default?/0) and
      # trigger-action POSTs to /users/log-in?_action=registered — the params
      # below are what the browser sends with that box left ticked.
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
      refute persistent_cookie?(conn)
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

      assert persistent_cookie?(conn)
    end
  end

  describe "post-login destination" do
    # The default is the host's `/`. This router is `PhoenixKitWeb.Router`,
    # which declares no root route — so the probe rejects it and the visitor
    # gets core's own landing instead of a 404. On a host that serves a home
    # page (nearly all of them) the answer is still `/`; see
    # `test/phoenix_kit/utils/safe_destination_settings_test.exs`, which pins
    # both halves against a router that declares one.
    test "defaults to a core landing when the host declares no /", %{conn: conn} do
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      assert redirected_to(conn) == Routes.path("/admin")
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

    test "a non-local after_login_path value falls back to the default", %{conn: conn} do
      # The settings form validates on save; this simulates a hand-edited DB row.
      Settings.update_setting("after_login_path", "https://evil.example")
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      refute redirected_to(conn) =~ "evil.example"
      assert redirected_to(conn) == Routes.path("/admin")
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
      refute persistent_cookie?(conn)
    end

    test "enabled=false makes magic-link login session-only", %{conn: conn} do
      Settings.update_setting("remember_me_enabled", "false")
      user = confirmed_user()
      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)

      conn = get(conn, Routes.path("/users/magic-link/#{token}"))

      assert redirected_to(conn)
      refute persistent_cookie?(conn)
    end

    test "default=false makes magic-link login session-only (no checkbox to tick)",
         %{conn: conn} do
      Settings.update_setting("remember_me_default", "false")
      user = confirmed_user()
      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)

      conn = get(conn, Routes.path("/users/magic-link/#{token}"))

      assert redirected_to(conn)
      refute persistent_cookie?(conn)
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
      refute persistent_cookie?(conn)
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

      # Confirmed user mounts → redirected onward; must fall back to a
      # core-owned landing, never to the smuggled destination.
      assert {:error, {:redirect, %{to: to}}} =
               live(
                 conn,
                 Routes.path("/users/confirm") <>
                   "?return_to=" <>
                   URI.encode_www_form("/\t/evil.example")
               )

      refute to =~ "evil.example"
      assert Routes.local_path?(to)
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

      # The guard against a second flash copy is the element id, not the
      # message text: since flash auto-dismiss, the message ALSO lives in the
      # hook's `data-flash-message` attribute, so the marker legitimately
      # appears twice in the markup of a single, correctly rendered flash.
      assert html =~ "UNIQUEFLASHMARKER"
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

    # The account is fine; the user is asked to do one routine thing. Error
    # styling made a first visit look like a failure (reported from topp.ee).
    test "the confirmation halt is a warning flash, not an error", %{conn: conn} do
      user = register_user()

      conn = conn |> plug_conn(user) |> UserAuth.require_authenticated_user([])

      assert Phoenix.Flash.get(conn.assigns.flash, :warning) =~ "confirm your email"
      refute Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "the scope-based plug halts with the same warning flash", %{conn: conn} do
      user = register_user()

      conn =
        conn
        |> plug_conn(user)
        |> Plug.Conn.assign(:phoenix_kit_current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_scope([])

      assert conn.halted
      assert redirected_to(conn) == Routes.path("/users/confirm")
      assert Phoenix.Flash.get(conn.assigns.flash, :warning) =~ "confirm your email"
      refute Phoenix.Flash.get(conn.assigns.flash, :error)
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

      # Redirects to a core-owned landing (e.g. /dashboard), never to the bare
      # "/" which core does not declare and which 404s on hosts without a root route.
      assert {:error, {:redirect, %{to: to}}} = live(conn, Routes.path("/users/confirm"))
      assert Routes.local_path?(to)
      refute to == "/"
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

      # Hostile return_to is dropped; lands on a core-owned path, not bare "/".
      assert {:error, {:redirect, %{to: to}}} =
               live(
                 conn,
                 Routes.path("/users/confirm") <>
                   "?return_to=" <>
                   URI.encode_www_form("https://evil.example")
               )

      refute to =~ "evil.example"
      assert Routes.local_path?(to)
    end

    test "confirmed user honors after_login_path", %{conn: conn} do
      Settings.update_setting("after_login_path", "/welcome")
      user = confirmed_user()
      conn = login_conn(conn, user)

      assert {:error, {:redirect, %{to: "/welcome"}}} = live(conn, Routes.path("/users/confirm"))
    end

    test "waiting screen is short: one line with the address, no long hint", %{conn: conn} do
      user = register_user()
      conn = login_conn(conn, user)

      {:ok, _lv, html} = live(conn, Routes.path("/users/confirm"))

      assert html =~ "We sent a confirmation link to #{user.email}."
      refute html =~ "no need to come back to this page"
      refute html =~ "No confirmation email on record"
    end

    test "waiting screen shows the sent time only when a confirmation was sent", %{conn: conn} do
      user = register_user()
      conn = login_conn(conn, user)

      {:ok, lv, _html} = live(conn, Routes.path("/users/confirm"))
      refute has_element?(lv, "#confirmation-sent-at")

      extract_token(fn url_fun -> Auth.deliver_user_confirmation_instructions(user, url_fun) end)

      {:ok, lv, html} = live(conn, Routes.path("/users/confirm"))
      assert has_element?(lv, "#confirmation-sent-at")
      assert html =~ "Sent"
    end

    test "parked user is moved along live when an admin confirms them", %{conn: conn} do
      user = register_user()
      conn = login_conn(conn, user)

      {:ok, lv, html} = live(conn, Routes.path("/users/confirm"))
      assert html =~ user.email

      {:ok, _user} = Auth.admin_confirm_user(user)

      # Redirects to a core-owned landing, not bare "/" which 404s on hosts
      # without a root route.
      {to, _flash} = assert_redirect(lv, 3000)
      assert Routes.local_path?(to)
      refute to == "/"
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

    # A parked visitor is already authenticated, so the enumeration-safe
    # "if your email is in our system" hedge (correct for the anonymous form)
    # reads as a wrong answer here — they know perfectly well they're signed
    # in. There is nothing left to avoid revealing, so the response names
    # their own address directly.
    test "parked user gets a direct message naming their own email", %{conn: conn} do
      user = register_user()
      {:ok, lv, _html} = live(login_conn(conn, user), Routes.path("/users/confirm"))

      html =
        lv
        |> form("#resend_confirmation_form", %{"user" => %{"email" => user.email}})
        |> render_submit()

      assert html =~ "sent a new confirmation link to #{user.email}"
      refute html =~ "If your email is in our system"
    end

    # A parked user is authenticated, so a rate-limit block is safe to name
    # directly (see the comment above) — and it must be named: the resend
    # handler used to flash "sent" unconditionally regardless of what the
    # rate limiter or the mailer actually did, which is indistinguishable
    # from working right up until the user notices no mail ever arrives.
    test "parked user hitting the resend rate limit sees a real error, not a false 'sent'", %{
      conn: conn
    } do
      user = register_user()
      {:ok, lv, _html} = live(login_conn(conn, user), Routes.path("/users/confirm"))

      for _ <- 1..3 do
        lv
        |> form("#resend_confirmation_form", %{"user" => %{"email" => user.email}})
        |> render_submit()
      end

      html =
        lv
        |> form("#resend_confirmation_form", %{"user" => %{"email" => user.email}})
        |> render_submit()

      # The prior successful sends' :info flash is still on screen too — Phoenix
      # flash is keyed by kind and only the auto-dismiss JS (which never runs in
      # a headless render) clears it. The error flash existing at all, next to
      # it, is the assertion: it used to never appear no matter what happened.
      assert html =~ "wait a few minutes"
    end

    # The email field renders as a hidden input (not editable in the DOM), but
    # the server must not trust the submitted value either — a client that
    # crafts its own phx-submit payload could still send an arbitrary email.
    # Without server-side enforcement, a logged-in unconfirmed user could
    # probe whether an arbitrary address is registered and get the (now
    # honest) answer back. `render_submit/3` bypasses the DOM entirely, the
    # same way a hand-crafted client payload would.
    test "a forged email in the resend payload still resends to the parked user's own account",
         %{conn: conn} do
      user = register_user()
      other = register_user()
      {:ok, lv, _html} = live(login_conn(conn, user), Routes.path("/users/confirm"))

      html = render_submit(lv, "send_instructions", %{"user" => %{"email" => other.email}})

      assert html =~ user.email
      refute html =~ other.email
    end

    # With confirmation NOT enforced the account is already usable, so the
    # password-less path would let a hijacked session re-address a live
    # account and take it over through a password reset. The form then asks
    # for the password, exactly as Profile Settings does.
    test "with confirmation not enforced, the parked email change needs the password", %{
      conn: conn
    } do
      Settings.update_boolean_setting("require_email_confirmation", false)
      user = register_user()
      new_email = unique_email()

      {:ok, lv, _html} = live(login_conn(conn, user), Routes.path("/users/confirm"))

      html = lv |> element("button", "Wrong email? Change it") |> render_click()
      assert html =~ "current_password"

      html =
        render_submit(lv, "update_email", %{
          "current_password" => "not-the-password",
          "email_change" => %{"email" => new_email}
        })

      refute html =~ "sent a confirmation link to #{new_email}"
      refute_email_sent()

      html =
        lv
        |> form("#change_email_form", %{
          "current_password" => @password,
          "email_change" => %{"email" => new_email}
        })
        |> render_submit()

      assert html =~ "sent a confirmation link to #{new_email}"
    end

    test "parked user can fix a typo'd email; the resulting link changes AND confirms it", %{
      conn: conn
    } do
      user = register_user()
      other_conn = login_conn(build_conn(), user)
      new_email = unique_email()

      {:ok, lv, _html} = live(login_conn(conn, user), Routes.path("/users/confirm"))

      html = lv |> element("button", "Wrong email? Change it") |> render_click()
      assert html =~ "change_email_form"
      # Unlike the confirmed Profile Settings flow, this parked/unconfirmed
      # path never asks for the password — there is no live account yet for
      # a hijacked session to protect (see `apply_unconfirmed_user_email/2`).
      refute html =~ "current_password"

      html =
        lv
        |> form("#change_email_form", %{"email_change" => %{"email" => new_email}})
        |> render_submit()

      assert html =~ "sent a confirmation link to #{new_email}"

      assert_email_sent(fn email ->
        assert [_, token] =
                 Regex.run(~r{change-email/([^\s"<]+)}, email.html_body || email.text_body)

        # A second tab still parked on the same account live-advances once the
        # new address is confirmed, exactly like the direct confirm-link flow.
        {:ok, other_lv, _html} = live(other_conn, Routes.path("/users/confirm"))

        {:ok, confirm_lv, _html} =
          live(
            login_conn(build_conn(), user),
            Routes.path("/users/confirm/change-email/#{token}")
          )

        confirm_lv
        |> form("#confirm_email_change_form", %{"user" => %{"token" => token}})
        |> render_submit()

        assert_redirect(other_lv, 3000)

        updated = Auth.get_user(user.uuid)
        assert updated.email == new_email
        assert updated.confirmed_at
      end)
    end

    test "changing to another account's email surfaces a real error, not a silent no-op", %{
      conn: conn
    } do
      user = register_user()
      taken = register_user()
      {:ok, lv, _html} = live(login_conn(conn, user), Routes.path("/users/confirm"))

      lv |> element("button", "Wrong email? Change it") |> render_click()

      html =
        lv
        |> form("#change_email_form", %{"email_change" => %{"email" => taken.email}})
        |> render_submit()

      assert html =~ "has already been taken"
      refute_email_sent()
    end

    test "a confirmation landing between mount and subscribe is not missed", %{conn: conn} do
      user = register_user()
      conn = login_conn(conn, user)

      # Simulates the race: the row flips confirmed while the LV is mounting,
      # so no broadcast can reach it. The post-subscribe re-read must catch it.
      {:ok, _user} = Auth.admin_confirm_user(user)

      # Redirects to a core-owned landing, not bare "/".
      assert {:error, {:redirect, %{to: to}}} = live(conn, Routes.path("/users/confirm"))
      assert Routes.local_path?(to)
      refute to == "/"
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

  describe "review round 2 regressions" do
    test "changing a password keeps the persistent session alive", %{conn: conn} do
      user = confirmed_user()

      # Password change deletes EVERY token, the one inside the live cookie
      # included. The re-login handoff carries no checkbox, so without
      # carry_remember_me/2 the user kept a cookie pointing at a dead token.
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Test.put_req_cookie(@remember_me_cookie, remember_me_cookie_for(user))
        |> post(Routes.path("/users/log-in?_action=password_updated"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      assert redirected_to(conn)
      assert persistent_cookie?(conn)
    end

    test "a login without remember-me clears a stale cookie", %{conn: conn} do
      user = confirmed_user()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Test.put_req_cookie(@remember_me_cookie, remember_me_cookie_for(user))
        |> post(Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => @password}
        })

      # Explicitly expired, not merely "not set" — a stale cookie whose token
      # is gone must not survive to keep failing for 60 days.
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      refute persistent_cookie?(conn)
    end

    test "remember_me_enabled=false stops an already-issued cookie working", %{conn: conn} do
      user = confirmed_user()

      # Obtain a genuinely-signed cookie the way a real login does.
      logged_in =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "remember_me" => "true"
          }
        })

      %{value: cookie} = logged_in.resp_cookies[@remember_me_cookie]

      Settings.update_setting("remember_me_enabled", "false")

      restored =
        build_conn()
        |> Plug.Test.put_req_cookie(@remember_me_cookie, cookie)
        |> Map.put(:secret_key_base, PhoenixKitWeb.Endpoint.config(:secret_key_base))
        |> Phoenix.ConnTest.init_test_session(%{})
        |> UserAuth.fetch_phoenix_kit_current_user([])

      # Blocking new cookies while still honoring old ones would let every
      # cookie issued before the switch keep working for its full 60 days.
      refute restored.assigns.phoenix_kit_current_user
    end

    test "magic-link registration confirms the account", %{conn: _conn} do
      email = unique_email()
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(email)

      {:ok, user} =
        MagicLinkRegistration.complete_registration(token, %{"password" => @password})

      # Clicking the emailed link proves inbox control. Unconfirmed, the user
      # would be parked at /users/confirm with no email ever sent to escape it.
      assert user.confirmed_at
    end

    test "magic-link registration ignores client-supplied custom_fields" do
      email = unique_email()
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(email)

      {:ok, user} =
        MagicLinkRegistration.complete_registration(token, %{
          "password" => @password,
          "custom_fields" => %{"oauth_avatar_url" => "http://evil.example/x.png"}
        })

      # complete_registration/3 is a context call, so it legitimately accepts
      # custom_fields; the LiveView strips them before they ever get here.
      # This pins that the changeset itself never took confirmed_at.
      assert user.confirmed_at
    end

    test "an expired registration token does not crash the completion flow" do
      email = unique_email()
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(email)
      :ok = MagicLinkRegistration.delete_registration_token(token)

      assert {:error, :invalid_token} =
               MagicLinkRegistration.complete_registration(token, %{"password" => @password})
    end

    test "the after-login path cannot be set to a sign-in page" do
      # /users/log-out is the nastiest of these: a real GET route, so it would
      # sign the user straight back out on every login, locking out the admin
      # who set it too.
      for loop <- [
            "/users/log-in",
            "/users/log-out",
            "/users/register",
            "/users/confirm",
            "/users/magic-link",
            "/users/qr-login",
            "/users/reset-password",
            "/users/log-in/"
          ] do
        cs = Settings.validate_settings(%{"after_login_path" => loop})
        assert cs.errors[:after_login_path], "expected #{loop} to be rejected"
      end

      refute Settings.validate_settings(%{"after_login_path" => "/dashboard"}).errors[
               :after_login_path
             ]
    end

    test "a hand-edited loop path is still refused at read time" do
      # update_setting/2 bypasses the changeset, so the guard has to hold on
      # the read side too.
      Settings.update_setting("after_login_path", "/users/log-out")

      # The refused setting falls through to the context-less tail of
      # `post_auth_path/2`. That tail used to be a bare `"/"`; it is now
      # `/admin`, the landing core declares unconditionally and admits every
      # authenticated visitor to. What the test is really pinning is unchanged:
      # the stored `/users/log-out` never comes back, so a login cannot sign the
      # user straight out again.
      assert Routes.post_auth_path([]) == Routes.path("/admin")
      refute Routes.auth_page?(Routes.post_auth_path([]))
    end

    test "magic-link login honors a return_to carried by the emailed link", %{conn: conn} do
      user = confirmed_user()
      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)

      conn =
        get(conn, Routes.path("/users/magic-link/#{token}") <> "?return_to=/checkout")

      assert redirected_to(conn) == "/checkout"
    end

    test "magic-link login ignores a non-local return_to", %{conn: conn} do
      user = confirmed_user()
      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)

      conn =
        get(
          conn,
          Routes.path("/users/magic-link/#{token}") <>
            "?return_to=" <> URI.encode_www_form("https://evil.example")
        )

      refute redirected_to(conn) =~ "evil.example"
      # The default destination, resolved: no host `/` in this router.
      assert redirected_to(conn) == Routes.path("/admin")
    end

    test "auth pages hand return_to to each other", %{conn: conn} do
      html =
        conn
        |> get(Routes.path("/users/log-in") <> "?return_to=/checkout")
        |> html_response(200)

      # Switching sign-in method or heading to registration must not silently
      # drop the destination the user was sent here to reach.
      assert html =~ "return_to=%2Fcheckout"
    end

    test "redirect paths are trimmed on save" do
      cs = Settings.validate_settings(%{"after_login_path" => "  /dashboard  "})
      refute cs.errors[:after_login_path]
      assert Ecto.Changeset.get_change(cs, :after_login_path) == "/dashboard"
    end

    test "a failed registration handoff does not stash the destination", %{conn: conn} do
      Settings.update_setting("after_registration_path", "/onboarding")
      user = register_user()

      conn =
        post(conn, Routes.path("/users/log-in?_action=registered"), %{
          "user" => %{"email_or_username" => user.email, "password" => "WrongPassword123!"}
        })

      assert redirected_to(conn) == Routes.path("/users/log-in")
      refute get_session(conn, :user_return_to)
    end

    test "confirmation resend is rate limited", %{conn: conn} do
      user = register_user()
      # A parked (logged-in, unconfirmed) user stays on the page after
      # submitting, so the response can be inspected repeatedly.
      {:ok, lv, _html} = live(login_conn(conn, user), Routes.path("/users/confirm"))

      # Well past the 3-per-5-minutes budget. Every response stays identical so
      # the throttle can't be used to tell registered addresses apart.
      for _ <- 1..6 do
        html =
          lv
          |> form("#resend_confirmation_form", %{"user" => %{"email" => user.email}})
          |> render_submit()

        refute html =~ "Too many"
      end
    end

    # The forgot-password LiveView throttles BEFORE the user lookup (so the
    # response can't reveal whether the address exists), and deliver_* also
    # throttles for callers with no limiter of their own. Both hit the same
    # per-email bucket, so the public path has to opt the inner one out —
    # otherwise each submission spends two of the three allowed hits and the
    # user's SECOND reset request in a window silently sends nothing while the
    # page still shows the success notice.
    test "the public reset path charges the per-email bucket exactly once" do
      user = confirmed_user()

      for n <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(user.email),
               "request #{n} should be within the 3-per-5-minutes budget"

        assert {:ok, %Swoosh.Email{}} =
                 Auth.deliver_user_reset_password_instructions(
                   user,
                   &"http://localhost/#{&1}",
                   rate_limit: false
                 )
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(user.email)
    end

    # The per-address bucket cannot see a spray — ten thousand addresses take
    # one hit each and it never fires — so the IP bucket is the one that stops
    # it. That only works if the page actually hands the visitor's address over,
    # and connect info is readable during mount and nowhere else: capture it in
    # the wrong place and the bucket silently keys on nothing forever. Assert on
    # the bucket itself rather than on an email, so nothing else in the flow can
    # make this pass.
    test "the forgot-password page charges the IP bucket with the visitor's address" do
      user = confirmed_user()
      ip = {198, 51, 100, 77}
      key = "auth:password_reset:ip:198.51.100.77"
      window = 300_000

      before = Backend.get(key, window)

      {:ok, lv, _html} =
        build_conn()
        |> with_peer(ip)
        |> live(Routes.path("/users/reset-password"))

      lv
      |> form("#reset_password_form", %{"user" => %{"email" => user.email}})
      |> render_submit()

      assert Backend.get(key, window) == before + 1
    end

    # Same requirement, different capture point in each file — the reason to
    # pin all three rather than trust one.
    test "the confirmation-resend page charges the IP bucket with the visitor's address" do
      user = register_user()
      ip = {198, 51, 100, 78}
      key = "auth:confirmation_resend:ip:198.51.100.78"
      window = 300_000

      before = Backend.get(key, window)

      {:ok, lv, _html} =
        build_conn() |> with_peer(ip) |> live(Routes.path("/users/confirm"))

      lv
      |> form("#resend_confirmation_form", %{"user" => %{"email" => user.email}})
      |> render_submit()

      assert Backend.get(key, window) == before + 1
    end

    # Covered one level down from its page: mounting the magic-link LiveView
    # connected calls `Presence.track_anonymous/2`, and `SimplePresence` is not
    # among the processes `test_helper.exs` starts, so `live/2` exits there for
    # reasons that have nothing to do with rate limiting. This pins the half
    # that is ours — the address reaching the bucket — and the page hands it
    # over the same way the two above do.
    test "generate_magic_link/2 charges the IP bucket with the address it is given" do
      user = confirmed_user()
      key = "auth:magic_link:ip:198.51.100.79"
      window = 300_000

      before = Backend.get(key, window)

      assert {:ok, _user, _token} =
               MagicLink.generate_magic_link(user.email, "198.51.100.79")

      assert Backend.get(key, window) == before + 1
    end

    test "deliver_user_reset_password_instructions/3 still limits by default" do
      # The admin "send reset link" action has no limiter of its own, so the
      # inner one must stay for callers that don't opt out.
      user = confirmed_user()

      for _ <- 1..3 do
        assert {:ok, %Swoosh.Email{}} =
                 Auth.deliver_user_reset_password_instructions(user, &"http://localhost/#{&1}")
      end

      assert {:error, :rate_limit_exceeded} =
               Auth.deliver_user_reset_password_instructions(user, &"http://localhost/#{&1}")
    end

    # `?return_to=` is the least trusted of the three destination inputs, and
    # /users/log-out is a real GET route — planted in an auth link it signs the
    # user back out the instant they sign in.
    test "a return_to pointing at log-out is ignored", %{conn: conn} do
      user = confirmed_user()

      conn =
        post(conn, Routes.path("/users/log-in"), %{
          "user" => %{
            "email_or_username" => user.email,
            "password" => @password,
            "return_to" => Routes.path("/users/log-out")
          }
        })

      refute redirected_to(conn) =~ "log-out"
      # The default destination, resolved: no host `/` in this router.
      assert redirected_to(conn) == Routes.path("/admin")
    end
  end

  describe "allow_registration closes the magic-link completion route" do
    setup do
      on_exit(fn -> Settings.update_setting("allow_registration", "true") end)
      :ok
    end

    test "an in-flight completion link stops working once registration closes",
         %{conn: conn} do
      # The completion page gained a `magic_link_registration_enabled` gate for
      # exactly this reason — "a link already sitting in an inbox still creates
      # an account after an admin switched it off" — but read only that
      # setting. `allow_registration` is the BROADER switch (no new accounts at
      # all), so honouring the narrow one and not the wide one left the wide one
      # as the button-hiding-without-route-closing this page was fixed for.
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(unique_email())

      # Still open: the link works.
      assert conn |> get(Routes.path("/users/register/complete/#{token}")) |> html_response(200)

      Settings.update_setting("allow_registration", "false")

      conn = get(conn, Routes.path("/users/register/complete/#{token}"))

      # Not /users/register — that page is closed too, so sending them there
      # would just bounce them again.
      assert redirected_to(conn) == Routes.path("/users/log-in")
    end

    test "closing registration does not break the completion route while it is open",
         %{conn: conn} do
      Settings.update_setting("allow_registration", "true")

      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(unique_email())

      assert conn |> get(Routes.path("/users/register/complete/#{token}")) |> html_response(200)
    end
  end

  describe "registration account-type policy" do
    alias PhoenixKit.Users.Invitations

    defp orgs_on(mode) do
      Settings.update_setting("enable_organization_accounts", "true")
      Settings.update_setting("registration_account_type", mode)
    end

    defp register_page(conn),
      do: conn |> get(Routes.path("/users/register")) |> html_response(200)

    # Submits the signup LiveView's "save" event directly, which is the shape a
    # forged payload has: fields the rendered form never contained. Going
    # through `form/3` would only prove the picker is hidden, and the picker is
    # not the control.
    defp submit_registration(conn, user_params) do
      {:ok, lv, _html} = live(conn, Routes.path("/users/register"))
      render_submit(lv, "save", %{"user" => user_params})
    end

    defp organization_with_invitation(email) do
      owner = confirmed_user()

      {:ok, org} =
        Auth.register_user(%{
          email: unique_email(),
          password: @password,
          account_type: "organization",
          organization_name: "Acme GmbH"
        })

      {:ok, _invitation, token} = Invitations.create_invitation(org, email, owner)
      {org, token}
    end

    test "no picker while organization accounts are off", %{conn: conn} do
      Settings.update_setting("enable_organization_accounts", "false")

      refute register_page(conn) =~ ~s(name="user[account_type]")
    end

    test "\"choice\" renders the picker — the shipped default", %{conn: conn} do
      orgs_on("choice")

      html = register_page(conn)

      assert html =~ ~s(name="user[account_type]")
      assert html =~ ~s(value="organization")
    end

    test "\"person\" hides the picker even with the feature on", %{conn: conn} do
      orgs_on("person")

      html = register_page(conn)

      refute html =~ ~s(name="user[account_type]")
      refute html =~ ~s(name="user[organization_name]")
    end

    test "\"organization\" swaps the picker for a required Organization Name", %{conn: conn} do
      orgs_on("organization")

      html = register_page(conn)

      refute html =~ ~s(name="user[account_type]")
      assert html =~ ~s(name="user[organization_name]")
    end

    test "a forged account_type cannot beat \"person\" mode", %{conn: conn} do
      orgs_on("person")
      email = unique_email()

      submit_registration(conn, %{
        "email" => email,
        "password" => @password,
        "account_type" => "organization",
        "organization_name" => "Forged Ltd"
      })

      user = Auth.get_user_by_email(email)

      assert user.account_type == "person"
      assert is_nil(user.organization_name)
    end

    test "a forged account_type cannot beat the feature being off", %{conn: conn} do
      Settings.update_setting("enable_organization_accounts", "false")
      email = unique_email()

      submit_registration(conn, %{
        "email" => email,
        "password" => @password,
        "account_type" => "organization",
        "organization_name" => "Forged Ltd"
      })

      assert Auth.get_user_by_email(email).account_type == "person"
    end

    test "\"organization\" mode registers an organization", %{conn: conn} do
      orgs_on("organization")
      email = unique_email()

      submit_registration(conn, %{
        "email" => email,
        "password" => @password,
        "organization_name" => "Woodmatrix OÜ"
      })

      user = Auth.get_user_by_email(email)

      assert user.account_type == "organization"
      assert user.organization_name == "Woodmatrix OÜ"
    end

    test "an unnamed organization is refused rather than silently registered", %{conn: conn} do
      orgs_on("organization")
      email = unique_email()

      html = submit_registration(conn, %{"email" => email, "password" => @password})

      assert html =~ "can&#39;t be blank"
      refute Auth.get_user_by_email(email)
    end

    test "an organization invitation pins the visitor to a person", %{conn: conn} do
      orgs_on("choice")
      email = unique_email()
      {_org, token} = organization_with_invitation(email)

      html =
        conn
        |> get(Routes.path("/users/register") <> "?invitation=#{token}")
        |> html_response(200)

      # Choosing "Organization" here would create a SECOND organization, and an
      # organization account cannot hold an organization_uuid — the invitation
      # could never be redeemed afterwards.
      refute html =~ ~s(name="user[account_type]")
    end

    test "and a forged payload on that page is pinned too", %{conn: conn} do
      orgs_on("choice")
      email = unique_email()
      {_org, token} = organization_with_invitation(email)

      {:ok, lv, _html} = live(conn, Routes.path("/users/register") <> "?invitation=#{token}")

      render_submit(lv, "save", %{
        "user" => %{
          "email" => email,
          "password" => @password,
          "account_type" => "organization",
          "organization_name" => "Forged Ltd"
        }
      })

      assert Auth.get_user_by_email(email).account_type == "person"
    end
  end
end
