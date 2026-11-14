defmodule PhoenixKit.Integration.Users.TurnstileTest do
  @moduledoc """
  Cloudflare Turnstile (`PhoenixKit.Users.Turnstile`): the verdicts, the
  settings (Settings → Authorization → Abuse protection) and the five public
  forms that ask for a token.

  Cloudflare is a plug here (`:turnstile_req_options`): the verdict follows the
  secret and the token it is sent, and every call is reported to the test.
  """

  # Swaps application env; the settings cache is shared.
  use PhoenixKitWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Turnstile
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"
  @secret "0x4AAAA-real-secret"
  @field "cf-turnstile-response"

  # What Cloudflare would answer.
  defp cloudflare(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      send(test_pid, {:siteverify, form})

      cond do
        form["response"] == "cloudflare-is-down" ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        form["secret"] != @secret ->
          Req.Test.json(conn, %{"success" => false, "error-codes" => ["invalid-input-secret"]})

        form["response"] == "good-token" ->
          Req.Test.json(conn, %{"success" => true})

        true ->
          Req.Test.json(conn, %{"success" => false, "error-codes" => ["invalid-input-response"]})
      end
    end
  end

  setup do
    previous = Application.fetch_env(:phoenix_kit, :turnstile_req_options)
    Application.put_env(:phoenix_kit, :turnstile_req_options, plug: cloudflare(self()))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :turnstile_req_options, value)
        :error -> Application.delete_env(:phoenix_kit, :turnstile_req_options)
      end
    end)

    :ok
  end

  defp switch_on do
    assert {:ok, :saved} =
             Turnstile.save_config(%{
               "enabled" => "true",
               "site_key" => "0x4AAAA-site",
               "secret_key" => @secret
             })

    # The probe `save_config/2` made.
    assert_received {:siteverify, %{"response" => "phoenix-kit-key-check"}}
  end

  defp unique_email, do: "ts_#{System.unique_integer([:positive])}@example.com"

  describe "verify/2" do
    test "off: every request passes and Cloudflare is not asked" do
      refute Turnstile.enabled?()
      assert :ok = Turnstile.verify(nil, "203.0.113.5")
      assert :ok = Turnstile.verify("anything")
      refute_received {:siteverify, _}
    end

    test "on: a good token passes, with the visitor's address" do
      switch_on()

      assert :ok = Turnstile.verify("good-token", "203.0.113.5")

      assert_received {:siteverify,
                       %{
                         "secret" => @secret,
                         "response" => "good-token",
                         "remoteip" => "203.0.113.5"
                       }}
    end

    test "on: no token is refused without asking Cloudflare" do
      switch_on()

      assert {:error, :missing} = Turnstile.verify(nil)
      assert {:error, :missing} = Turnstile.verify("  ")
      assert {:error, :missing} = Turnstile.verify(%{"forged" => "map"})
      refute_received {:siteverify, _}
    end

    test "on: a token Cloudflare refuses, and one too long to be a token" do
      switch_on()

      assert {:error, :rejected} = Turnstile.verify("spent-token")
      assert_received {:siteverify, %{"response" => "spent-token"}}

      assert {:error, :rejected} = Turnstile.verify(String.duplicate("a", 2049))
      refute_received {:siteverify, _}
    end

    test "on: no verdict from Cloudflare lets the request through" do
      switch_on()

      assert :ok = Turnstile.verify("cloudflare-is-down")
    end

    test "a switch left on without a key is off" do
      switch_on()
      {:ok, _} = Settings.update_setting("turnstile_site_key", "")

      refute Turnstile.enabled?()
      assert Turnstile.widget_site_key() == nil
      assert :ok = Turnstile.verify(nil)
    end
  end

  describe "save_config/2" do
    test "the secret is stored encrypted and never reported back" do
      switch_on()

      assert Turnstile.config() == %{enabled: true, site_key: "0x4AAAA-site", secret_set?: true}

      stored = PhoenixKit.RepoHelper.repo().get_by!(Setting, key: "turnstile_secret_key").value
      refute stored =~ @secret
      assert Settings.get_setting("turnstile_secret_key") == @secret
      assert "turnstile_secret_key" in Settings.restricted_setting_keys()
      assert Settings.security_setting_key?("turnstile_enabled")
    end

    test "a secret Cloudflare does not know is refused and nothing is written" do
      assert {:error, :invalid_secret} =
               Turnstile.save_config(%{
                 "enabled" => "true",
                 "site_key" => "0x4AAAA-site",
                 "secret_key" => "typo"
               })

      assert Turnstile.config() == %{enabled: false, site_key: "", secret_set?: false}
    end

    test "switching on needs both keys" do
      assert {:error, :site_key_required} =
               Turnstile.save_config(%{"enabled" => "true", "secret_key" => @secret})

      assert {:error, :secret_key_required} =
               Turnstile.save_config(%{"enabled" => "true", "site_key" => "0x4AAAA-site"})

      refute Turnstile.enabled?()
    end

    test "a blank secret keeps the saved one; the switch goes off and on" do
      switch_on()

      assert {:ok, :saved} =
               Turnstile.save_config(%{"enabled" => "false", "site_key" => "0x4AAAA-other"})

      assert Turnstile.config() == %{enabled: false, site_key: "0x4AAAA-other", secret_set?: true}

      assert {:ok, :saved} =
               Turnstile.save_config(%{
                 "enabled" => "true",
                 "site_key" => "0x4AAAA-other",
                 "secret_key" => ""
               })

      assert Turnstile.enabled?()
    end

    test "Cloudflare out of reach at save time: saved, reported as unverified" do
      Application.put_env(:phoenix_kit, :turnstile_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end
      )

      assert {:ok, :unverified} =
               Turnstile.save_config(%{
                 "enabled" => "true",
                 "site_key" => "0x4AAAA-site",
                 "secret_key" => @secret
               })

      assert Turnstile.enabled?()
    end
  end

  describe "Settings → Authorization → Abuse protection" do
    setup %{conn: conn} do
      {user, _token} = create_admin_user()
      %{conn: log_in_user(conn, user)}
    end

    defp protection(conn),
      do: live(conn, Routes.path("/admin/settings/authorization?tab=protection"))

    test "saves the switch and the keys; the secret is never rendered", %{conn: conn} do
      {:ok, view, html} = protection(conn)
      refute html =~ ~s(id="turnstile-enabled" checked)

      html =
        view
        |> form("#turnstile-settings-form", %{
          turnstile: %{enabled: "true", site_key: "0x4AAAA-site", secret_key: @secret}
        })
        |> render_submit()

      assert html =~ "Turnstile settings saved."
      assert html =~ "0x4AAAA-site"
      assert html =~ "Saved. Leave blank to keep it"
      refute html =~ @secret
      assert Turnstile.enabled?()

      # A fresh page still holds no secret.
      {:ok, _view, html} = protection(conn)
      refute html =~ @secret
    end

    test "a wrong secret is refused with a message", %{conn: conn} do
      {:ok, view, _html} = protection(conn)

      html =
        view
        |> form("#turnstile-settings-form", %{
          turnstile: %{enabled: "true", site_key: "0x4AAAA-site", secret_key: "typo"}
        })
        |> render_submit()

      assert html =~ "Cloudflare does not recognise this secret key"
      refute Turnstile.enabled?()
    end

    test "the main settings form cannot write the Turnstile keys", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization"))

      # A forged field in the settings form: not a key any settings form owns.
      render_submit(view, "save_settings", %{
        "settings" => %{"turnstile_enabled" => "true", "turnstile_secret_key" => "forged"}
      })

      assert Turnstile.config() == %{enabled: false, site_key: "", secret_set?: false}
    end
  end

  describe "the public forms" do
    test "off: no widget, and the forms work as before", %{conn: conn} do
      for path <- ~w(/users/register /users/reset-password /users/magic-link /users/confirm) do
        refute conn |> get(Routes.path(path)) |> html_response(200) =~ "phx-hook=\"Turnstile\""
      end
    end

    test "on: each form renders the widget inside its form", %{conn: conn} do
      switch_on()

      for {path, id} <- [
            {"/users/register", "registration-turnstile"},
            {"/users/register/magic-link", "registration-link-turnstile"},
            {"/users/reset-password", "reset-password-turnstile"},
            {"/users/magic-link", "magic-link-turnstile"},
            {"/users/confirm", "resend-confirmation-turnstile"}
          ] do
        {:ok, view, _html} = live(conn, Routes.path(path))

        assert has_element?(
                 view,
                 ~s(form ##{id}[phx-hook="Turnstile"][phx-update="ignore"][data-sitekey="0x4AAAA-site"])
               ),
               "no widget on #{path}"
      end
    end

    test "sign-up: refused without a passed check, before anything is counted", %{conn: conn} do
      switch_on()
      email = unique_email()
      params = %{"email" => email, "password" => @password}
      {:ok, view, _html} = live(conn, Routes.path("/users/register"))

      html = render_submit(view, "save", %{"user" => params})
      assert html =~ "Please wait for the verification to finish"
      refute Auth.get_user_by_email(email)

      html = render_submit(view, "save", %{"user" => params, @field => "spent-token"})
      assert html =~ "The verification did not succeed"
      assert_push_event(view, "phoenix_kit:turnstile_reset", %{})
      refute Auth.get_user_by_email(email)

      # Neither refusal took one of the address's three hourly attempts.
      assert RateLimiter.get_remaining_attempts(:registration, email) == 3

      render_submit(view, "save", %{"user" => params, @field => "good-token"})
      assert %User{} = Auth.get_user_by_email(email)
    end

    test "password reset: no mail and no limit spent without a passed check", %{conn: conn} do
      switch_on()

      {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
      {:ok, view, _html} = live(conn, Routes.path("/users/reset-password"))

      html = render_submit(view, "send_email", %{"user" => %{"email" => user.email}})
      assert html =~ "Please wait for the verification to finish"
      assert_no_email_sent()
      assert RateLimiter.get_remaining_attempts(:password_reset, user.email) == 3

      render_submit(view, "send_email", %{
        "user" => %{"email" => user.email},
        @field => "good-token"
      })

      assert_email_sent(to: user.email)
    end

    test "registration link, magic link and confirmation resend refuse too", %{conn: conn} do
      switch_on()
      email = unique_email()

      for {path, event, params} <- [
            {"/users/register/magic-link", "send_magic_link", %{"email" => email}},
            {"/users/magic-link", "send_magic_link", %{"magic_link" => %{"email" => email}}},
            {"/users/confirm", "send_instructions", %{"user" => %{"email" => email}}}
          ] do
        {:ok, view, _html} = live(conn, Routes.path(path))

        assert render_submit(view, event, params) =~ "Please wait for the verification to finish",
               "#{path} let a request through without a token"

        assert render_submit(view, event, Map.put(params, @field, "spent-token")) =~
                 "The verification did not succeed",
               "#{path} let a refused token through"
      end

      assert_no_email_sent()
    end

    test "Cloudflare down: the form still works", %{conn: conn} do
      switch_on()
      email = unique_email()
      {:ok, view, _html} = live(conn, Routes.path("/users/register"))

      render_submit(view, "save", %{
        "user" => %{"email" => email, "password" => @password},
        @field => "cloudflare-is-down"
      })

      assert %User{} = Auth.get_user_by_email(email)
    end
  end
end
