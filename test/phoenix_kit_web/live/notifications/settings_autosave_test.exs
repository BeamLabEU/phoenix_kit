defmodule PhoenixKitWeb.Live.Notifications.SettingsAutosaveTest do
  @moduledoc """
  My Settings' notification matrix saves every switch the moment it is
  flipped and is drawn from what is stored. It used to keep a draft until a
  Save button and drew the channel columns from what was stored, so a
  channel switch flipped back as soon as the page redrew (the boss,
  2026-11-18: "when you initially flip a toggle, it just untoggles"). Every
  line names what it covers, with an example where the type declares one,
  and has an anchor a notification's "why you got this" line links to.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Prefs
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @path "/admin/notifications/settings"

  setup do
    {user, _token} = create_admin_user()
    %{user: user, conn: log_in_user(build_conn(), user)}
  end

  defp open(conn), do: live(conn, Routes.path(@path))

  defp email_toggle(key),
    do: ~s(input[type="checkbox"][name="notification_channel[email][types][#{key}]"])

  defp inapp_toggle(key), do: ~s(input[type="checkbox"][name="notification_prefs[#{key}]"])

  test "a channel switch flipped for the first time is saved at once and stays on", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = open(conn)
    refute view |> element(email_toggle("account")) |> render() =~ "checked"

    view
    |> element("#notification-settings-form")
    |> render_change(%{
      "notification_channel" => %{"email" => %{"types" => %{"account" => "true"}}}
    })

    stored = user.uuid |> Auth.get_user() |> ChannelConfig.for_channel("email")
    assert ChannelConfig.type_enabled?(stored, "account")
    assert has_element?(view, "#notification-settings-saved")
    assert view |> element(email_toggle("account")) |> render() =~ "checked"

    # A second switch, flipped after the first, leaves the first on.
    view
    |> element("#notification-settings-form")
    |> render_change(%{
      "notification_channel" => %{
        "email" => %{"types" => %{"account" => "true", "security" => "true"}}
      }
    })

    assert view |> element(email_toggle("account")) |> render() =~ "checked"

    {:ok, again, _html} = open(conn)
    assert again |> element(email_toggle("account")) |> render() =~ "checked"
    assert again |> element(email_toggle("security")) |> render() =~ "checked"
  end

  test "an in-app switch is saved at once and survives a reload", %{conn: conn, user: user} do
    {:ok, view, _html} = open(conn)
    assert view |> element(inapp_toggle("account")) |> render() =~ "checked"

    view
    |> element("#notification-settings-form")
    |> render_change(%{"notification_prefs" => %{"account" => "false"}})

    assert Prefs.get(user.uuid)["account"] == false

    {:ok, again, _html} = open(conn)
    refute again |> element(inapp_toggle("account")) |> render() =~ "checked"
  end

  test "a second tab showing an older state writes back only the switch it flips", %{
    conn: conn,
    user: user
  } do
    {:ok, tab_a, _} = open(conn)
    {:ok, tab_b, _} = open(conn)

    tab_a
    |> element("#notification-settings-form")
    |> render_change(%{
      "_target" => ["notification_prefs", "account"],
      "notification_prefs" => %{"account" => "false", "security" => "true"}
    })

    assert Prefs.get(user.uuid)["account"] == false

    # Tab B still shows "account" on, and flips "security" off.
    tab_b
    |> element("#notification-settings-form")
    |> render_change(%{
      "_target" => ["notification_prefs", "security"],
      "notification_prefs" => %{"account" => "true", "security" => "false"}
    })

    prefs = Prefs.get(user.uuid)
    assert prefs["security"] == false
    assert prefs["account"] == false
  end

  test "every line has its anchor, and declared examples are shown", %{conn: conn} do
    {:ok, view, html} = open(conn)

    assert has_element?(view, "#notif-security")
    assert has_element?(view, "#notif-account")
    assert has_element?(view, "#notif-posts\\.comments")
    assert html =~ "For example: You signed in from a new phone in Tallinn."
  end

  test "there is no Save button any more", %{conn: conn} do
    {:ok, _view, html} = open(conn)
    refute html =~ "Save preferences"
  end
end
