defmodule PhoenixKit.Integration.Users.LoginAlertsCountryTest do
  @moduledoc """
  The new-country sign-in alert (`new_country_login_alert_enabled`), with the
  geolocation lookup answered by `Req.Test` instead of the live services.

  `async: false`: the stub is wired through application config
  (`:geolocation_req_options`), which every process reads.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.KnownDevice
  alias PhoenixKit.Users.LoginAlerts

  # Documentation ranges (RFC 5737), each answered as a country below.
  @tallinn {203, 0, 113, 10}
  @tartu {203, 0, 113, 11}
  @helsinki {198, 51, 100, 20}
  @berlin {192, 0, 2, 30}
  # Answered as a failed lookup.
  @nowhere {192, 0, 2, 99}

  @places %{
    "203.0.113.10" => {"EE", "Estonia", "Tallinn"},
    "203.0.113.11" => {"EE", "Estonia", "Tartu"},
    "198.51.100.20" => {"FI", "Finland", "Helsinki"},
    "192.0.2.30" => {"DE", "Germany", "Berlin"}
  }

  @chrome_mac "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Chrome/120.0"

  setup do
    previous = Application.fetch_env(:phoenix_kit, :geolocation_req_options)
    Application.put_env(:phoenix_kit, :geolocation_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :geolocation_req_options, value)
        :error -> Application.delete_env(:phoenix_kit, :geolocation_req_options)
      end
    end)

    Req.Test.stub(__MODULE__, &answer/1)

    {:ok, _} = Settings.update_setting("new_country_login_alert_enabled", "true")
    {:ok, _} = Settings.update_setting("new_login_alert_enabled", "false")
    :ok
  end

  # ip-api.com answers /json/<ip>; the ipapi.co fallback /<ip>/json/.
  defp answer(%Plug.Conn{host: "ip-api.com", path_info: ["json", ip]} = conn) do
    case @places[ip] do
      {code, country, city} ->
        Req.Test.json(conn, %{
          "status" => "success",
          "countryCode" => code,
          "country" => country,
          "city" => city,
          "regionName" => ""
        })

      nil ->
        Req.Test.json(conn, %{"status" => "fail", "message" => "reserved range"})
    end
  end

  defp answer(conn),
    do: Req.Test.json(conn, %{"error" => true, "reason" => "Reserved IP Address"})

  defp create_user do
    email = "country_alert_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    # Confirmed: mail nobody asked for goes only to a proven address
    # (`Auth.unsolicited_mail_allowed?/1`).
    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  # One browser throughout: it carries the device cookie it was given, so
  # every alert below is about the country, never about the device.
  defp sign_in(user, ip, token \\ nil) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:remote_ip, ip)
      |> Plug.Conn.put_req_header("user-agent", @chrome_mac)

    conn =
      if token, do: Plug.Test.put_req_cookie(conn, LoginAlerts.device_cookie(), token), else: conn

    LoginAlerts.check(user, conn).resp_cookies[LoginAlerts.device_cookie()].value
  end

  test "stores the country code with the location" do
    user = create_user()
    sign_in(user, @tallinn)

    assert [%KnownDevice{country_code: "EE", location: "Tallinn, Estonia"}] =
             Repo.all(KnownDevice)
  end

  test "the account's first sign-in never alerts" do
    user = create_user()
    sign_in(user, @tallinn)

    refute_email_sent()
  end

  test "a known browser signing in from a new country alerts" do
    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @helsinki, token)

    assert_email_sent(fn email ->
      assert email.subject =~ "New login"
      assert email.text_body =~ "from a new device or location"
      assert email.text_body =~ "Helsinki, Finland"
    end)

    [entry] =
      PhoenixKit.Activity.list(action: "user.new_login_detected", actor_uuid: user.uuid).entries
      |> Enum.filter(&(&1.metadata["country_code"] == "FI"))

    assert entry.metadata["new_country"] == true
    assert entry.metadata["new_browser"] == false
  end

  test "a new address in a known country does not alert" do
    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @tartu, token)

    refute_email_sent()
  end

  test "a country alerts once: the next sign-in from it is known" do
    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @helsinki, token)
    assert_email_sent()

    sign_in(user, {198, 51, 100, 20}, token)
    refute_email_sent()
  end

  test "a failed lookup never alerts" do
    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @nowhere, token)

    refute_email_sent()
    assert [nil, "EE"] = KnownDevice |> Repo.all() |> Enum.map(& &1.country_code) |> Enum.sort()
  end

  # Rows from before V230, or whose lookup failed, have no country: the first
  # resolved one is the account's baseline, not an alarm.
  test "an account with no known country takes the next one as its baseline" do
    user = create_user()
    token = sign_in(user, @nowhere)
    sign_in(user, @helsinki, token)
    refute_email_sent()

    sign_in(user, @berlin, token)
    assert_email_sent(fn email -> assert email.text_body =~ "Berlin, Germany" end)
  end

  test "a returning device from before V230 establishes the baseline before travel" do
    user = create_user()
    sign_in(user, @tallinn)
    device = Repo.get_by!(KnownDevice, user_uuid: user.uuid)

    device
    |> KnownDevice.changeset(%{country_code: nil, device_token_hash: nil})
    |> Repo.update!()

    token = sign_in(user, @tallinn)

    assert %KnownDevice{country_code: "EE"} = Repo.get!(KnownDevice, device.uuid)
    refute_email_sent()

    sign_in(user, @helsinki, token)
    assert_email_sent(fn email -> assert email.text_body =~ "Helsinki, Finland" end)
  end

  test "a country resolved on a later visit alerts when the account never saw it" do
    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @helsinki, token)
    assert_email_sent()

    # As if the Helsinki lookup had failed at that sign-in.
    device = Repo.get_by!(KnownDevice, user_uuid: user.uuid, country_code: "FI")
    device |> KnownDevice.changeset(%{country_code: nil, location: nil}) |> Repo.update!()

    sign_in(user, @helsinki, token)

    assert %KnownDevice{country_code: "FI"} = Repo.get!(KnownDevice, device.uuid)
    assert_email_sent(fn email -> assert email.text_body =~ "Helsinki, Finland" end)

    sign_in(user, @helsinki, token)
    refute_email_sent()
  end

  test "a device from before V230 in a second country is recorded without an alert" do
    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @helsinki, token)
    assert_email_sent()

    device = Repo.get_by!(KnownDevice, user_uuid: user.uuid, country_code: "FI")

    device
    |> KnownDevice.changeset(%{country_code: nil, location: nil, device_token_hash: nil})
    |> Repo.update!()

    sign_in(user, @helsinki, token)

    assert %KnownDevice{country_code: "FI"} = Repo.get!(KnownDevice, device.uuid)
    refute_email_sent()
  end

  test "a row with no country is looked up again at most once a day" do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :login_country_lookups})

    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, :lookup)
      answer(conn)
    end)

    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @nowhere, token)
    flush_lookups()

    sign_in(user, @nowhere, token)
    assert_received :lookup
    flush_lookups()

    sign_in(user, @nowhere, token)
    refute_received :lookup
  end

  defp flush_lookups do
    receive do
      :lookup -> flush_lookups()
    after
      0 -> :ok
    end
  end

  test "does not alert while only the new-device alert is on" do
    {:ok, _} = Settings.update_setting("new_country_login_alert_enabled", "false")
    {:ok, _} = Settings.update_setting("new_login_alert_enabled", "true")
    user = create_user()
    token = sign_in(user, @tallinn)
    sign_in(user, @helsinki, token)

    refute_email_sent()
    # Still recorded, so turning the country alert on later has a history.
    assert ["EE", "FI"] = KnownDevice |> Repo.all() |> Enum.map(& &1.country_code) |> Enum.sort()
  end

  describe "the authorization settings page" do
    import Phoenix.LiveViewTest

    alias PhoenixKit.Utils.Routes

    setup %{conn: conn} do
      {:ok, _} = Settings.update_setting("new_country_login_alert_enabled", "false")
      {admin, _token} = create_admin_user()
      {:ok, conn: log_in_user(conn, admin)}
    end

    test "saves the new-country switch", %{conn: conn} do
      {:ok, view, html} = live(conn, Routes.path("/admin/settings/authorization"))
      assert html =~ "Email users when their account is signed in from a new country"

      view
      |> form("#authorization_settings_form", %{
        "settings" => %{"new_country_login_alert_enabled" => "true"}
      })
      |> render_submit()

      assert LoginAlerts.country_alerts_enabled?()
    end
  end
end
