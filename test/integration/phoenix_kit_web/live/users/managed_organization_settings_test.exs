defmodule PhoenixKitWeb.Live.Users.ManagedOrganizationSettingsTest do
  use PhoenixKit.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.TimeZoneAlert
  alias PhoenixKitWeb.Components.LayoutWrapper
  alias PhoenixKitWeb.Components.ProfileSettingsTabs
  alias PhoenixKitWeb.Live.Components.UserSettings

  test "embedded settings omit credentials even when explicitly requested" do
    user = Fixtures.organization()

    html =
      render_component(UserSettings,
        id: "managed",
        user: user,
        sections: [:identity, :email, :password, :oauth, :sessions, :api_keys],
        show_google_email: true
      )

    refute html =~ "Email Address"
    refute html =~ "Change Password"
    refute html =~ "Connected Accounts"
    refute html =~ "Active Sessions"
    refute html =~ "managed-api-keys"
    refute html =~ "Google Email"
    refute html =~ ~s(phx-hook="TimezoneDetector")
    refute html =~ user.email
    assert html =~ "Personal Timezone"
  end

  test "forged credential and browser-timezone events are refused before reading params" do
    user = Fixtures.organization()
    socket = socket(user)

    events = ~w(validate_email update_email validate_password update_password
      connect_oauth_provider disconnect_oauth_provider toggle_email_form
      toggle_password_form revoke_session revoke_other_sessions
      browser_timezone_detected use_browser_timezone)

    for event <- events do
      assert {:noreply, ^socket} = UserSettings.handle_event(event, %{}, socket)
    end

    assert Auth.get_user(user.uuid).hashed_password == user.hashed_password
  end

  test "a crafted profile save cannot change the login or Google email" do
    user = Fixtures.organization()
    params = %{"user" => %{"email" => "new@example.com", "google_email" => "new@example.com"}}

    assert {:noreply, _} = UserSettings.handle_event("update_profile", params, socket(user))
    fresh = Auth.get_user(user.uuid)
    assert fresh.email == user.email
    assert fresh.google_email == user.google_email
  end

  test "the manager's browser does not change the organization's timezone bookkeeping" do
    user = Fixtures.organization(%{user_timezone: "Europe/Warsaw"})
    assert :ok = TimeZoneAlert.observe(user, "Asia/Tokyo")
    assert Auth.get_user(user.uuid).custom_fields == user.custom_fields

    scope = Scope.for_user(user)

    html =
      render_component(&LayoutWrapper.timezone_detector/1, scope: scope, handler_attached: true)

    refute html =~ "TimezoneDetector"

    tabs = ProfileSettingsTabs.tab_ids(scope)
    refute "security" in tabs
    refute "sessions" in tabs
    assert "account" in tabs
  end

  defp socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, user: user, myself: nil},
      private: %{live_temp: %{}}
    }
  end
end
