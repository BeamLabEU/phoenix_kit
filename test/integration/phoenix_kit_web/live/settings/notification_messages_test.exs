defmodule PhoenixKitWeb.Live.Settings.NotificationMessagesTest do
  @moduledoc """
  Settings → Notification messages (item 20): who may open it, the editor
  starting from the default, a live preview, Save, the stale-copy guard and
  Reset.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Notifications.Messages
  alias PhoenixKit.Users.{Auth, Permissions}
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/notification-messages")

  defp role!(keys) do
    {:ok, role} = Roles.create_role(%{name: "Msg perms #{System.unique_integer([:positive])}"})
    for key <- keys, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    role
  end

  defp user_with(keys) do
    role = role!(keys)

    {:ok, user} =
      Auth.register_user(%{
        email: "msg-perms-#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp editor(conn), do: log_in_user(conn, user_with(["settings", "settings.messages"]))

  test "without settings.messages the page is refused", %{conn: conn} do
    conn = log_in_user(conn, user_with(["settings"]))

    assert {:error, {_kind, %{to: to}}} = live(conn, @path)
    refute to =~ "notification-messages"
  end

  test "opens on every notification's email, starting from the default", %{conn: conn} do
    {:ok, view, html} = live(editor(conn), @path)

    assert html =~ "Every notification"
    assert has_element?(view, "#notification-messages-subject[value='{{subject}}']")
    assert has_element?(view, "#notification-messages-markdown", "{{text}}")
    assert has_element?(view, "#notification-messages-variables", "{{quote}}")
    assert has_element?(view, "#notification-messages-preview-html")
    assert html =~ "Every language uses the default."
  end

  test "typing previews; Save keeps the wording; a stale copy is refused; Reset removes it",
       %{conn: conn} do
    {:ok, view, _html} = live(editor(conn), @path <> "?type=*&channel=email&lang=en")

    view
    |> form("#notification-messages-form",
      message: %{"subject" => "News: {{subject}}", "markdown" => "{{text}}\n\n{{quote}}"}
    )
    |> render_change()

    assert has_element?(
             view,
             "#notification-messages-preview-subject",
             "News: ACME-12 can be started"
           )

    view
    |> form("#notification-messages-form",
      message: %{"subject" => "News: {{subject}}", "markdown" => "{{text}}\n\n{{quote}}"}
    )
    |> render_submit(%{"version" => "0"})

    assert %{"subject" => "News: {{subject}}", "version" => 1} =
             Messages.entry("*", "email", "en")

    # An older copy (version 0 again) is refused, nothing overwritten.
    html =
      render_submit(view, "save", %{
        "version" => "0",
        "message" => %{"subject" => "Other", "markdown" => "{{text}}"}
      })

    assert html =~ "Someone else saved this message meanwhile."
    assert Messages.entry("*", "email", "en")["subject"] == "News: {{subject}}"

    view |> element("#notification-messages-reset") |> render_click()
    assert Messages.entry("*", "email", "en") == nil
  end

  test "an unknown variable is refused and named", %{conn: conn} do
    {:ok, view, _html} = live(editor(conn), @path)

    html =
      render_submit(view, "save", %{
        "version" => "0",
        "message" => %{"subject" => "{{password}}", "markdown" => "{{text}}"}
      })

    assert html =~ "Unknown variables: {{password}}"
    assert Messages.entry("*", "email", "en") == nil
  end

  test "Telegram is one plain text with the button kept", %{conn: conn} do
    {:ok, view, _html} = live(editor(conn), @path <> "?type=*&channel=telegram&lang=en")

    assert has_element?(view, "#notification-messages-text")
    refute has_element?(view, "#notification-messages-subject")
    assert has_element?(view, "#notification-messages-preview-text", "Fit the doors (ACME-12)")
  end
end
