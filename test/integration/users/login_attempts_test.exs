defmodule PhoenixKit.Integration.Users.LoginAttemptsTest do
  @moduledoc """
  Failed sign-ins are recorded, aggregated, and never allowed to break a login.

  The properties that actually matter here are the aggregation key and the
  things it must NOT do: grow one row per attempt, disclose whether an account
  exists, or take the login form down when the table is unreachable.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.LoginAlerts
  alias PhoenixKit.Users.LoginAttempt
  alias PhoenixKit.Users.LoginAttempts
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"

  defp unique_email, do: "la_#{System.unique_integer([:positive])}@example.com"

  defp unique_ip do
    n = System.unique_integer([:positive])
    {127, 2, n |> div(256) |> rem(256), rem(n, 256)}
  end

  defp create_user(attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(Map.merge(%{email: unique_email(), password: @password}, attrs))

    # Confirmed: mail nobody asked for goes only to a proven address
    # (`Auth.unsolicited_mail_allowed?/1`).
    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  defp conn_at(ip, ua \\ "Mozilla/5.0 (Macintosh) Chrome/120.0") do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, ip)
    |> Plug.Conn.put_req_header("user-agent", ua)
  end

  defp attempts, do: Repo.all(LoginAttempt)

  describe "record/4" do
    test "attributes an attempt to the account whose address was tried" do
      user = create_user()

      assert :ok = LoginAttempts.record(conn_at(unique_ip()), user.email, "invalid_credentials")

      assert [%LoginAttempt{user_uuid: user_uuid, outcome: "invalid_credentials"} = row] =
               attempts()

      assert user_uuid == user.uuid
      assert row.identifier == user.email
      assert row.attempt_count == 1
    end

    test "records an unknown identifier with no account attached" do
      assert :ok =
               LoginAttempts.record(
                 conn_at(unique_ip()),
                 "nobody@example.com",
                 "invalid_credentials"
               )

      assert [%LoginAttempt{user_uuid: nil, identifier: "nobody@example.com"}] = attempts()
    end

    test "many attempts from one network collapse into one rising row" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..25 do
        LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")
      end

      assert [%LoginAttempt{attempt_count: 25}] = attempts()
    end

    test "first_at pins when the bucket opened; last_at tracks the newest hit" do
      ip = unique_ip()
      LoginAttempts.record(conn_at(ip), "someone@example.com", "invalid_credentials")
      [first] = attempts()

      LoginAttempts.record(conn_at(ip), "someone@example.com", "invalid_credentials")
      [second] = attempts()

      assert second.first_at == first.first_at
      assert DateTime.compare(second.last_at, first.last_at) in [:eq, :gt]
    end

    test "each outcome and each identifier is its own bucket" do
      ip = unique_ip()

      LoginAttempts.record(conn_at(ip), "a@example.com", "invalid_credentials")
      LoginAttempts.record(conn_at(ip), "a@example.com", "rate_limited")
      LoginAttempts.record(conn_at(ip), "b@example.com", "invalid_credentials")

      assert length(attempts()) == 3
    end

    # A refused request is past the limiter's bound, so its identifier cannot
    # be a free key component: a blocked client naming a fresh address per
    # request would otherwise write a row per request.
    test "refused requests naming no account collapse into one row per network" do
      ip = unique_ip()

      for n <- 1..20 do
        LoginAttempts.record(conn_at(ip), "spray_#{n}@example.com", "rate_limited")
      end

      assert [%{identifier: "*", attempt_count: 20, outcome: "rate_limited"}] = attempts()
    end

    test "a refused request naming a real account keeps its identifier" do
      user = create_user()

      LoginAttempts.record(conn_at(unique_ip()), user.email, "rate_limited")

      assert [%{identifier: identifier, user_uuid: uuid}] = attempts()
      assert identifier == user.email
      assert uuid == user.uuid
    end

    test "the identifier is normalized and truncated" do
      long = String.duplicate("x", 300) <> "@example.com"

      LoginAttempts.record(conn_at(unique_ip()), "  MiXeD@Example.COM  ", "invalid_credentials")
      LoginAttempts.record(conn_at(unique_ip()), long, "invalid_credentials")

      identifiers = Enum.map(attempts(), & &1.identifier)

      assert "mixed@example.com" in identifiers
      # The column is varchar(160) and the value is attacker-controlled; an
      # untruncated insert would raise rather than record.
      assert Enum.any?(identifiers, &(String.length(&1) == 160))
    end

    test "null bytes are stripped from the identifier" do
      # Postgres rejects \\x00 even though it is valid UTF-8; leaving it in
      # would make the insert raise and the attempt go unrecorded.
      LoginAttempts.record(conn_at(unique_ip()), "bad\0@example.com", "invalid_credentials")

      assert [%LoginAttempt{identifier: "bad@example.com"}] = attempts()
    end

    test "a bucket that opened against no account attaches once the account exists" do
      email = unique_email()
      ip = unique_ip()

      LoginAttempts.record(conn_at(ip), email, "invalid_credentials")
      assert [%LoginAttempt{user_uuid: nil, attempt_count: 1}] = attempts()

      user = create_user(%{email: email})

      LoginAttempts.record(conn_at(ip), email, "invalid_credentials")

      assert [%LoginAttempt{user_uuid: user_uuid, attempt_count: 2}] = attempts()
      assert user_uuid == user.uuid
    end

    test "the browser and OS are captured from the user agent" do
      LoginAttempts.record(
        conn_at(unique_ip(), "Mozilla/5.0 (X11; Linux x86_64) Firefox/120.0"),
        "someone@example.com",
        "invalid_credentials"
      )

      assert [%LoginAttempt{browser: "Firefox", os: "Linux"}] = attempts()
    end

    test "records nothing when logging is disabled" do
      {:ok, _} = Settings.update_setting("login_attempt_logging_enabled", "false")
      on_exit(fn -> Settings.update_setting("login_attempt_logging_enabled", "true") end)

      assert :ok =
               LoginAttempts.record(conn_at(unique_ip()), "a@example.com", "invalid_credentials")

      assert attempts() == []
    end

    test "an unusable outcome is swallowed rather than raised at the caller" do
      # The changeset rejects it, `record/4` reports :ok anyway. A security log
      # must never be the reason a sign-in fails.
      assert :ok = LoginAttempts.record(conn_at(unique_ip()), "a@example.com", "nonsense")
      assert attempts() == []
    end
  end

  describe "reading" do
    test "count_for_user_since/2 sums attempt_count, not rows" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..7, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")
      LoginAttempts.record(conn_at(unique_ip()), user.email, "invalid_credentials")

      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      # Two buckets (two networks), eight attempts.
      assert length(attempts()) == 2
      assert LoginAttempts.count_for_user_since(user, since) == 8
    end

    test "count_for_user_since/2 ignores anything older than the window" do
      user = create_user()
      LoginAttempts.record(conn_at(unique_ip()), user.email, "invalid_credentials")

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert LoginAttempts.count_for_user_since(user, future) == 0
    end

    test "count_for_user_since/2 does not count another account's attempts" do
      user = create_user()
      other = create_user()

      LoginAttempts.record(conn_at(unique_ip()), other.email, "invalid_credentials")

      since = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert LoginAttempts.count_for_user_since(user, since) == 0
    end

    test "stats/1 separates attempts from buckets" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..5, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")
      LoginAttempts.record(conn_at(unique_ip()), "nobody@example.com", "invalid_credentials")

      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert %{attempts: 6, buckets: 2, accounts: 1, networks: 2} = LoginAttempts.stats(since)
    end

    test "top_since/2 orders by weight" do
      user = create_user()
      heavy = unique_ip()

      for _ <- 1..9, do: LoginAttempts.record(conn_at(heavy), user.email, "invalid_credentials")
      LoginAttempts.record(conn_at(unique_ip()), "quiet@example.com", "invalid_credentials")

      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert [%LoginAttempt{attempt_count: 9}, %LoginAttempt{attempt_count: 1}] =
               LoginAttempts.top_since(since)
    end
  end

  describe "retention" do
    test "prune/1 deletes by last_at, keeping a bucket that is still being hit" do
      LoginAttempts.record(conn_at(unique_ip()), "old@example.com", "invalid_credentials")
      [row] = attempts()

      long_ago = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)

      # An old bucket that stopped being hit.
      Repo.update_all(
        from(a in LoginAttempt, where: a.uuid == ^row.uuid),
        set: [first_at: long_ago, last_at: long_ago]
      )

      # One that opened just as long ago but is still live.
      LoginAttempts.record(conn_at(unique_ip()), "live@example.com", "invalid_credentials")
      [_, live] = Enum.sort_by(attempts(), & &1.identifier)

      Repo.update_all(from(a in LoginAttempt, where: a.uuid == ^live.uuid),
        set: [first_at: long_ago]
      )

      assert {:ok, 1} = LoginAttempts.prune(90)
      assert [%LoginAttempt{identifier: "live@example.com"}] = attempts()
    end

    test "retention_days/0 falls back to 90 for an unusable setting" do
      {:ok, _} = Settings.update_setting("login_attempt_retention_days", "not-a-number")
      on_exit(fn -> Settings.update_setting("login_attempt_retention_days", "90") end)

      assert LoginAttempts.retention_days() == 90
    end
  end

  describe "warning the account holder" do
    setup do
      {:ok, _} = Settings.update_setting("failed_login_alert_enabled", "true")
      {:ok, _} = Settings.update_setting("failed_login_alert_threshold", "5")

      on_exit(fn ->
        Settings.update_setting("failed_login_alert_enabled", "false")
        Settings.update_setting("failed_login_alert_threshold", "10")
      end)

      :ok
    end

    test "stays quiet below the threshold" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..4, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      refute_email_sent()
    end

    test "warns once the threshold is crossed" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..5, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      assert_email_sent(fn email ->
        assert email.subject =~ "Failed sign-in"
        assert email.to == [{"", user.email}]
        assert email.text_body =~ "Failed attempts: 5"
      end)
    end

    test "a sustained attack cannot turn the warning into a mail flood" do
      user = create_user()
      ip = unique_ip()

      # Twenty more failures past the threshold. The 24h cooldown means the
      # attacker gets to send the victim exactly one email, not twenty.
      for _ <- 1..25, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      assert_email_sent(fn email -> assert email.subject =~ "Failed sign-in" end)
      refute_email_sent()
    end

    # Every caller reads "due" from a user struct loaded before anyone stamped,
    # which is what a parallel burst looks like. The stamp is the gate, so the
    # same stale struct cannot win it twice.
    test "a stale user struct cannot send a second warning" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..5, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")
      assert_email_sent(fn email -> assert email.subject =~ "Failed sign-in" end)

      # `user` still carries no stamp — exactly what a concurrent request holds.
      for _ <- 1..3 do
        LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials", user: user)
      end

      refute_email_sent()
    end

    test "the warning does not count as an edit of the account" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..5, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      assert Repo.get!(PhoenixKit.Users.Auth.User, user.uuid).updated_at == user.updated_at
    end

    test "the cooldown stamp does not clobber other custom_fields" do
      user = create_user()
      {:ok, _} = Auth.merge_user_custom_fields(user, %{"keep_me" => "yes"})

      ip = unique_ip()
      for _ <- 1..5, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      reloaded = Repo.get(PhoenixKit.Users.Auth.User, user.uuid)
      assert reloaded.custom_fields["keep_me"] == "yes"
      assert is_binary(reloaded.custom_fields["phoenix_kit_failed_login_alert_at"])
    end

    test "an unknown address warns nobody" do
      ip = unique_ip()

      for _ <- 1..10 do
        LoginAttempts.record(conn_at(ip), "nobody@example.com", "invalid_credentials")
      end

      refute_email_sent()
    end

    test "stays quiet when the alert is switched off" do
      {:ok, _} = Settings.update_setting("failed_login_alert_enabled", "false")

      user = create_user()
      ip = unique_ip()
      for _ <- 1..10, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      refute_email_sent()
    end
  end

  describe "the new-device email carries the failure count" do
    setup do
      {:ok, _} = Settings.update_setting("new_login_alert_enabled", "true")
      on_exit(fn -> Settings.update_setting("new_login_alert_enabled", "false") end)
      :ok
    end

    test "reports recent failures alongside the successful sign-in" do
      user = create_user()
      ip = unique_ip()

      for _ <- 1..3, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      # First device is the account's own registration login and stays silent;
      # the second is the one that alerts.
      LoginAlerts.check(user, conn_at(ip, "Mozilla/5.0 (Macintosh) Chrome/120.0"))
      LoginAlerts.check(user, conn_at(ip, "Mozilla/5.0 (X11; Linux) Firefox/120.0"))

      assert_email_sent(fn email ->
        assert email.text_body =~ "3 failed sign-in attempts"
        assert email.text_body =~ "If this was you, no action is needed."
      end)
    end

    test "the failure count survives translation" do
      # A fuzzy carryover silently dropped {{failed_attempts}} from all seven
      # catalogues once already. Without the placeholder the count renders in
      # English and vanishes everywhere else.
      user = create_user()
      # Written directly: `update_user_locale_preference/2` validates against
      # the install's enabled languages, and this test cares about the
      # catalogue, not the language picker.
      {:ok, user} =
        Auth.merge_user_custom_fields(user, %{"preferred_locale" => "de"},
          ensure_definitions: false
        )

      ip = unique_ip()

      for _ <- 1..3, do: LoginAttempts.record(conn_at(ip), user.email, "invalid_credentials")

      LoginAlerts.check(user, conn_at(ip, "Mozilla/5.0 (Macintosh) Chrome/120.0"))
      LoginAlerts.check(user, conn_at(ip, "Mozilla/5.0 (X11; Linux) Firefox/120.0"))

      assert_email_sent(fn email ->
        refute email.text_body =~ "{{failed_attempts}}"
        assert email.text_body =~ "3"
        # The substitution has to survive in a translated catalogue, not just
        # leave a number somewhere in an otherwise-English body.
        assert email.text_body =~ "fehlgeschlagene Anmeldeversuche"
      end)
    end

    test "says nothing about failures when there were none" do
      user = create_user()
      ip = unique_ip()

      LoginAlerts.check(user, conn_at(ip, "Mozilla/5.0 (Macintosh) Chrome/120.0"))
      LoginAlerts.check(user, conn_at(ip, "Mozilla/5.0 (X11; Linux) Firefox/120.0"))

      assert_email_sent(fn email ->
        refute email.text_body =~ "failed sign-in attempt"
        # The optional paragraph collapses rather than leaving a gap.
        assert email.text_body =~ "\n\nIf this was you, no action is needed."
      end)
    end
  end

  describe "the account holder's own settings page" do
    test "lists recent failed attempts", %{conn: conn} do
      user = create_user()
      {:ok, _} = Auth.admin_confirm_user(user)
      ip = unique_ip()

      for _ <- 1..4 do
        LoginAttempts.record(
          conn_at(ip, "Mozilla/5.0 (X11; Linux x86_64) Firefox/120.0"),
          user.email,
          "invalid_credentials"
        )
      end

      {:ok, _view, html} =
        live(log_in_user(conn, user), Routes.path("/profile/settings/sessions"))

      assert html =~ "Failed sign-in attempts"
      assert html =~ "4 attempts"
      assert html =~ "Firefox on Linux"
      # The reader is told nobody got in — the whole point of showing it.
      assert html =~ "Nobody got in."
    end

    test "shows nothing when the account has never been targeted", %{conn: conn} do
      user = create_user()
      {:ok, _} = Auth.admin_confirm_user(user)

      {:ok, _view, html} =
        live(log_in_user(conn, user), Routes.path("/profile/settings/sessions"))

      refute html =~ "Failed sign-in attempts"
    end

    test "describes the source by device, never by the identifier", %{conn: conn} do
      user = create_user()
      {:ok, _} = Auth.admin_confirm_user(user)

      # No user-agent header, so there is no browser or OS to name. The row
      # falls back to a generic description rather than reaching for the
      # stored identifier, which is attacker-controlled text.
      bare =
        Phoenix.ConnTest.build_conn() |> Map.put(:remote_ip, unique_ip())

      LoginAttempts.record(bare, user.email, "invalid_credentials")

      {:ok, _view, html} =
        live(log_in_user(conn, user), Routes.path("/profile/settings/sessions"))

      assert html =~ "Failed sign-in attempts"
      assert html =~ "from an unrecognized device"
    end
  end

  describe "the admin sessions page" do
    setup %{conn: conn} do
      {admin, _token} = create_admin_user()
      {:ok, conn: log_in_user(conn, admin)}
    end

    test "surfaces recent failed sign-ins", %{conn: conn} do
      victim = create_user()
      ip = unique_ip()

      for _ <- 1..12 do
        LoginAttempts.record(
          conn_at(ip, "Mozilla/5.0 (X11; Linux x86_64) Firefox/120.0"),
          victim.email,
          "invalid_credentials"
        )
      end

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions"))

      assert html =~ "Failed sign-ins"
      assert html =~ "12"
      assert html =~ victim.email
      assert html =~ "Firefox on Linux"
      assert html =~ "Wrong password"
    end

    test "names attempts that matched no account as such", %{conn: conn} do
      LoginAttempts.record(conn_at(unique_ip()), "nobody@example.com", "invalid_credentials")

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions"))

      assert html =~ "no such account"
      assert html =~ "nobody@example.com"
    end

    test "escapes the attacker-controlled identifier", %{conn: conn} do
      LoginAttempts.record(
        conn_at(unique_ip()),
        "<script>alert(1)</script>@evil.test",
        "invalid_credentials"
      )

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions"))

      # The identifier is the one field a login form lets a stranger write
      # into an admin page. It renders escaped, never as markup.
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "hides the panel entirely on a quiet install", %{conn: conn} do
      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions"))

      refute html =~ "Failed sign-ins"
    end
  end

  describe "the login form records through to the table" do
    test "a wrong password is recorded against the real account" do
      user = create_user()

      conn =
        post(Map.put(build_conn(), :remote_ip, unique_ip()), Routes.path("/users/log-in"), %{
          "user" => %{"email_or_username" => user.email, "password" => "wrong-#{@password}"}
        })

      assert redirected_to(conn) =~ "/users/log-in"

      assert [%LoginAttempt{outcome: "invalid_credentials", user_uuid: user_uuid}] = attempts()
      assert user_uuid == user.uuid
    end

    test "an unknown address is recorded, and the response is the same one" do
      real = create_user()

      responses =
        for identifier <- [real.email, "definitely-not-registered@example.com"] do
          conn =
            post(Map.put(build_conn(), :remote_ip, unique_ip()), Routes.path("/users/log-in"), %{
              "user" => %{"email_or_username" => identifier, "password" => "wrong-#{@password}"}
            })

          {redirected_to(conn), Phoenix.Flash.get(conn.assigns.flash, :error)}
        end

      # Both branches record, and neither the destination nor the message
      # distinguishes a real account from a fictitious one.
      assert [_identical] = Enum.uniq(responses)
      assert length(attempts()) == 2
    end

    test "a successful login records nothing" do
      user = create_user()
      {:ok, _} = Auth.admin_confirm_user(user)

      post(Map.put(build_conn(), :remote_ip, unique_ip()), Routes.path("/users/log-in"), %{
        "user" => %{"email_or_username" => user.email, "password" => @password}
      })

      assert attempts() == []
    end

    test "a deactivated account with the CORRECT password is recorded as :inactive" do
      user = create_user()
      {:ok, user} = Auth.update_user_status(user, %{is_active: false})

      post(Map.put(build_conn(), :remote_ip, unique_ip()), Routes.path("/users/log-in"), %{
        "user" => %{"email_or_username" => user.email, "password" => @password}
      })

      # The most interesting outcome of the three: somebody has the password.
      assert [%LoginAttempt{outcome: "inactive", user_uuid: user_uuid}] = attempts()
      assert user_uuid == user.uuid
    end

    test "a wrong password on add-account is recorded against the real account", %{conn: conn} do
      {:ok, _} = Settings.update_setting("multi_session_enabled", "true")
      on_exit(fn -> Settings.update_setting("multi_session_enabled", "false") end)

      holder = create_user()
      {:ok, _} = Auth.admin_confirm_user(holder)
      target = create_user()

      conn =
        conn
        |> Map.put(:remote_ip, unique_ip())
        |> log_in_user(holder)

      post(conn, Routes.path("/users/session/accounts"), %{
        "user" => %{"email_or_username" => target.email, "password" => "wrong-#{@password}"}
      })

      assert [%LoginAttempt{outcome: "invalid_credentials", user_uuid: user_uuid}] = attempts()
      assert user_uuid == target.uuid
    end
  end

  describe "the authorization settings page" do
    setup %{conn: conn} do
      {admin, _token} = create_admin_user()
      {:ok, conn: log_in_user(conn, admin)}
    end

    test "exposes the failed-sign-in toggles", %{conn: conn} do
      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/authorization"))

      assert html =~ "Record failed sign-ins"
      assert html =~ "Email users when failed sign-ins on their account cross a threshold"
      assert html =~ "name=\"settings[failed_login_alert_enabled]\""
      assert html =~ "name=\"settings[login_attempt_logging_enabled]\""
    end

    test "saving the form persists the new settings", %{conn: conn} do
      on_exit(fn ->
        Settings.update_setting("failed_login_alert_enabled", "false")
        Settings.update_setting("failed_login_alert_threshold", "10")
        Settings.update_setting("login_attempt_logging_enabled", "true")
        Settings.update_setting("login_attempt_retention_days", "90")
      end)

      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization"))

      view
      |> form("#authorization_settings_form", %{
        "settings" => %{
          "failed_login_alert_enabled" => "true",
          "failed_login_alert_threshold" => "7",
          "login_attempt_logging_enabled" => "true",
          "login_attempt_retention_days" => "30"
        }
      })
      |> render_submit()

      assert Settings.get_setting("failed_login_alert_enabled") == "true"
      assert Settings.get_setting("failed_login_alert_threshold") == "7"
      assert Settings.get_setting("login_attempt_retention_days") == "30"
    end
  end
end
