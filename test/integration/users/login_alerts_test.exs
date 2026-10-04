defmodule PhoenixKit.Integration.Users.LoginAlertsTest do
  use PhoenixKitWeb.ConnCase, async: true

  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.KnownDevice
  alias PhoenixKit.Users.LoginAlerts

  defp unique_email, do: "login_alert_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})

    user
  end

  defp conn_with_ua(ua, remote_ip \\ {203, 0, 113, 42}) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, remote_ip)
    |> Plug.Conn.put_req_header("user-agent", ua)
  end

  @chrome_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Chrome/120.0"
  @firefox_linux "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"

  describe "check/2 when new_login_alert_enabled is off (default)" do
    test "does not persist a known device" do
      user = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user, conn)
      assert Repo.all(KnownDevice) == []
    end
  end

  describe "check/2 when new_login_alert_enabled is on" do
    setup do
      {:ok, _} = Settings.update_setting("new_login_alert_enabled", "true")
      :ok
    end

    test "a first-time login persists a new known device" do
      user = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user, conn)

      assert [%KnownDevice{user_uuid: user_uuid, browser: "Chrome", os: "macOS"}] =
               Repo.all(KnownDevice)

      assert user_uuid == user.uuid
    end

    # Registration ends by logging the new user in through this exact path —
    # with no skip, every signup on an install with alerts on would receive a
    # "we noticed a new login" security email about the login it just
    # performed to finish registering.
    test "a first-time login does not send an alert email" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))

      refute_email_sent()
    end

    test "a genuinely new device (the account's second) does send an alert email" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux))

      assert_email_sent(fn email -> assert email.subject =~ "New login" end)
    end

    test "the alert names the unrecognized device and qualifies the location" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux))

      assert_email_sent(fn email ->
        assert email.text_body =~ "from an unrecognized device"

        # Whether geolocation resolves here depends on a live lookup, so the
        # invariant is asserted instead of one of the two outcomes: a resolved
        # place is always marked approximate, and "Unknown" never is.
        assert email.text_body =~ ~r/^- Location: (Unknown|.+ \(approximate\))$/m
      end)
    end

    test "an unresolvable location degrades to Unknown without the qualifier" do
      user = create_user()
      local = {127, 0, 0, 1}

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, local))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux, local))

      assert_email_sent(fn email ->
        refute email.text_body =~ "(approximate)"
        assert email.text_body =~ "Location: Unknown"
      end)
    end

    # The line exists so the reader can answer "was that me?". Nobody can do
    # that against UTC, so it renders in the recipient's own timezone and names
    # it -- CEST in summer, CET in winter.
    test "the alert timestamps the login in the recipient's timezone" do
      user = create_user()
      {:ok, user} = Auth.update_user_profile(user, %{"user_timezone" => "Europe/Paris"})

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux))

      assert_email_sent(fn email ->
        assert [_, time_line] = Regex.run(~r/^- Time: (.+)$/m, email.text_body)
        refute time_line =~ "UTC"
        assert time_line =~ ~r/\bCES?T$/
      end)
    end

    test "a repeat login from the same device does not create a duplicate row" do
      user = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user, conn)
      assert :ok = LoginAlerts.check(user, conn)

      assert [%KnownDevice{}] = Repo.all(KnownDevice)
    end

    test "a different browser from the same user is tracked as a separate device" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux))

      assert [_, _] = Repo.all(KnownDevice)
    end

    test "the same browser from a new IP does not send an alert email" do
      # A dynamic IP (a new DHCP lease, switching wifi to mobile data, ...)
      # is not "a new device" — alerting on it alone trains people to
      # ignore the email. See the LoginAlerts moduledoc.
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, {203, 0, 113, 42}))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, {198, 51, 100, 7}))

      refute_email_sent()
    end

    test "the same browser from a new IP still records a device row for that IP" do
      # Preserves Active Sessions enrichment, which matches each live
      # session token's (network, ua) against a KnownDevice row.
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, {203, 0, 113, 42}))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, {198, 51, 100, 7}))

      assert [_, _] = Repo.all(KnownDevice)
    end

    test "the same browser from a rotated IPv6 address in the same /64 reuses its row" do
      # Operating systems rotate a temporary IPv6 address inside the /64
      # daily — that is the same connection, not a row per day.
      user = create_user()
      first = {0x2A0D, 0x3344, 0x6A, 0xC310, 0x88F8, 0x482C, 0xE41A, 0x9EF5}
      rotated = {0x2A0D, 0x3344, 0x6A, 0xC310, 0x1111, 0x2222, 0x3333, 0x4444}

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, first))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, rotated))

      assert [_] = Repo.all(KnownDevice)
    end

    test "the same browser from a different IPv6 /64 still records a second row" do
      user = create_user()
      first = {0x2A0D, 0x3344, 0x6A, 0xC310, 0, 0, 0, 1}
      other = {0x2A0D, 0x3344, 0x6A, 0xC311, 0, 0, 0, 1}

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, first))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, other))

      assert [_, _] = Repo.all(KnownDevice)
    end

    test "the same browser from a new IP still logs the activity for the audit trail" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, {203, 0, 113, 42}))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, {198, 51, 100, 7}))

      assert PhoenixKit.Activity.count(action: "user.new_login_detected", actor_uuid: user.uuid) ==
               2
    end

    test "a genuinely new browser on a brand-new IP still sends an alert email" do
      user = create_user()

      assert :ok = LoginAlerts.check(user, conn_with_ua(@chrome_mac, {203, 0, 113, 42}))
      assert :ok = LoginAlerts.check(user, conn_with_ua(@firefox_linux, {198, 51, 100, 7}))

      assert_email_sent(fn email -> assert email.subject =~ "New login" end)
    end

    test "devices are isolated per user" do
      user1 = create_user()
      user2 = create_user()
      conn = conn_with_ua(@chrome_mac)

      assert :ok = LoginAlerts.check(user1, conn)
      assert :ok = LoginAlerts.check(user2, conn)

      assert [_, _] = Repo.all(KnownDevice)
    end
  end
end
