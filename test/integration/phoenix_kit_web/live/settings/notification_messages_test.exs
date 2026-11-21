defmodule PhoenixKitWeb.Live.Settings.NotificationMessagesTest do
  @moduledoc """
  Settings → Notification messages (item 20): who may open it, the editor
  starting from the default, a live preview, Save, the stale-copy guard and
  Reset.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Notifications.Messages
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Users.{Auth, Permissions}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
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

    assert %{"subject" => "News: {{subject}}", "version" => version} =
             Messages.entry("*", "email", "en")

    assert is_integer(version)

    # An older copy (version 0 again) is refused, nothing overwritten.
    html =
      render_submit(view, "save", %{
        "version" => "0",
        "message" => %{"subject" => "Other", "markdown" => "{{text}}"}
      })

    assert html =~ "Someone else saved this message meanwhile."
    assert Messages.entry("*", "email", "en")["subject"] == "News: {{subject}}"

    # Clearing every part is also a write from this submitted version.
    html =
      render_submit(view, "save", %{
        "version" => "0",
        "message" => %{"subject" => "", "markdown" => ""}
      })

    assert html =~ "Someone else saved this message meanwhile."
    assert Messages.entry("*", "email", "en")["version"] == version

    view |> element("#notification-messages-reset") |> render_click()
    assert Messages.entry("*", "email", "en") == nil
  end

  @tag :tmp_dir
  test "preview retains host files until the operator overrides that part", %{
    conn: conn,
    tmp_dir: root
  } do
    dir = Path.join(root, "notification")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "subject.txt"), "Host subject")
    File.write!(Path.join(dir, "text.txt"), "Host body")
    previous = Application.fetch_env(:phoenix_kit, :template_paths)
    Application.put_env(:phoenix_kit, :template_paths, [root])

    on_exit(fn ->
      case previous do
        {:ok, paths} -> Application.put_env(:phoenix_kit, :template_paths, paths)
        :error -> Application.delete_env(:phoenix_kit, :template_paths)
      end
    end)

    {:ok, view, _} = live(editor(conn), @path)
    assert has_element?(view, "#notification-messages-preview-subject", "Host subject")
    assert has_element?(view, "#notification-messages-preview-text", "Host body")
    render_change(view, "change", %{"message" => %{"subject" => "New subject"}})
    assert has_element?(view, "#notification-messages-preview-subject", "New subject")
    assert has_element?(view, "#notification-messages-preview-text", "Host body")
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

  test "a type shows what it inherits, and a save keeps only what was changed", %{conn: conn} do
    owner = %Scope{
      user: %User{uuid: Ecto.UUID.generate()},
      authenticated?: true,
      cached_roles: ["Owner"],
      cached_permissions: MapSet.new()
    }

    {:ok, _} =
      Messages.save(owner, "*", "email", "en", %{
        "subject" => "Operations notice",
        "markdown" => "{{text}}"
      })

    [type | _] = Types.all_pref_keys()
    {:ok, view, _html} = live(editor(conn), @path <> "?type=#{type}&channel=email&lang=en")

    assert has_element?(view, "#notification-messages-subject[value='Operations notice']")
    assert has_element?(view, "#notification-messages-inherited")

    # Only the body changed: the subject goes on inheriting.
    render_submit(view, "save", %{
      "version" => "0",
      "message" => %{"subject" => "Operations notice", "markdown" => "{{text}} (own)"}
    })

    entry = Messages.entry(type, "email", "en")
    assert entry["markdown"] == "{{text}} (own)"
    assert entry["subject"] == ""
  end

  test "clearing a type's last own part is the same as a reset", %{conn: conn} do
    owner = %Scope{
      user: %User{uuid: Ecto.UUID.generate()},
      authenticated?: true,
      cached_roles: ["Owner"],
      cached_permissions: MapSet.new()
    }

    [type | _] = Types.all_pref_keys()
    {:ok, _} = Messages.save(owner, type, "email", "en", %{"subject" => "Own", "markdown" => ""})

    {:ok, view, _html} = live(editor(conn), @path <> "?type=#{type}&channel=email&lang=en")
    version = Messages.entry(type, "email", "en")["version"]

    # The body is the default, untouched (sent with Windows line endings).
    default_body = Messages.default_parts("email", "en")["markdown"]

    render_submit(view, "save", %{
      "version" => to_string(version),
      "message" => %{"subject" => "", "markdown" => String.replace(default_body, "\n", "\r\n")}
    })

    assert Messages.entry(type, "email", "en") == nil
  end
end
