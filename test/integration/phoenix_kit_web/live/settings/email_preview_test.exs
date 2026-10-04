defmodule PhoenixKitWeb.Live.Settings.EmailPreviewTest do
  @moduledoc """
  The admin email preview (`/admin/settings/email-sending/preview`): the list
  of known emails, the rendered subject/HTML/text, and where each part comes
  from.

  `async: false` — the file-override case points `:template_paths` at a
  fixture directory, which is application env.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Settings.EmailPreview
  alias PhoenixKitWeb.Users.Auth

  defmodule EmailModule do
    @moduledoc false
    def enabled?, do: true
    def module_name, do: "Fixture Module"

    def email_templates do
      [
        %{
          name: "fixture_text_only",
          label: "Text only",
          description: %{not: "a string"},
          defaults: fn -> %{subject: "Only text", text: "Hello"} end,
          layout: false
        },
        %{name: "fixture_broken", label: "Broken", variables: fn -> raise "boom" end},
        %{
          name: "fixture_html_only",
          label: "HTML only",
          defaults: fn -> %{subject: "Only HTML", html: "<p>Only HTML</p>"} end
        },
        %{
          name: "fixture_billing",
          label: "Billing",
          defaults: fn -> %{subject: "Invoice", text: "Pay"} end,
          layout: "billing"
        }
      ]
    end
  end

  defmodule ThrowingModule do
    @moduledoc false
    def enabled?, do: true
    def email_templates, do: throw(:no_list)
  end

  defmodule DbProvider do
    @moduledoc false
    def get_active_template_by_name("register"), do: %{name: "register", id: 1}
    def get_active_template_by_name(_name), do: nil

    def render_template(_template, _variables, _locale) do
      %{subject: "From the database", html_body: "<p>DB BODY</p>", text_body: "DB BODY"}
    end
  end

  @path Routes.path("/admin/settings/email-sending/preview")

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user)}
  end

  defp at(email, locale \\ "en"),
    do: @path <> "?" <> URI.encode_query(%{"email" => email, "lang" => locale})

  defp with_module(module) do
    ModuleRegistry.register(module)
    on_exit(fn -> ModuleRegistry.unregister(module) end)
  end

  defp revoke(role_uuid), do: Permissions.revoke_permission(role_uuid, "settings")

  defp with_template_root(files) do
    root = Path.join(System.tmp_dir!(), "pk_preview_#{System.unique_integer([:positive])}")

    for {rel, content} <- files do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    previous = Application.get_env(:phoenix_kit, :template_paths)
    Application.put_env(:phoenix_kit, :template_paths, [root])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :template_paths, previous),
        else: Application.delete_env(:phoenix_kit, :template_paths)

      File.rm_rf!(root)
    end)

    root
  end

  test "lists every core email and previews the first by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    for name <- ~w(register reset_password update_email magic_link magic_link_registration
                   organization_invitation new_login_alert failed_login_alert) do
      assert has_element?(view, "#email-preview-item-#{name}")
    end

    assert has_element?(view, "#email-preview-item-register.menu-active")
    assert has_element?(view, "#email-preview-subject", "Confirm your account")
  end

  test "renders the HTML in a script-less sandboxed iframe, and the text", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("reset_password"))

    assert has_element?(view, ~s(iframe#email-preview-html[sandbox=""]))

    assert has_element?(
             view,
             ~s(iframe#email-preview-html[srcdoc*="reset-password/preview-token"])
           )

    assert has_element?(view, "#email-preview-text", "reset-password/preview-token")
    refute has_element?(view, "#email-preview-missing")
  end

  test "says each part of a default email is the built-in default", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("new_login_alert"))

    assert has_element?(view, "#email-source-subject", "Built-in default")
    assert has_element?(view, "#email-source-markdown", "Built-in default")
    assert has_element?(view, "#email-source-markdown [data-builds=html]")
    assert has_element?(view, "#email-source-markdown [data-builds=text]")
    assert has_element?(view, "#email-source-text", "Not used")
    assert has_element?(view, "#email-preview-order", "markdown.md")
    assert has_element?(view, "#email-source-layout", "Built-in default")
    assert has_element?(view, "#email-source-header", "Built-in default")
    assert has_element?(view, "#email-source-subject", "new_login_alert/subject.en.txt")
  end

  test "shows a host file with its path, and the group's header file", %{conn: conn} do
    root =
      with_template_root(%{
        "register/subject.txt" => "From a file\n",
        "register/markdown.md" => "[Confirm]({{confirmation_url}})",
        "register/layout.txt" => "auth",
        "_header-auth/html.html" => "<p>GROUP HEADER</p>",
        "_footer/html.html" => "  \n"
      })

    {:ok, view, _html} = live(conn, at("register"))

    assert has_element?(view, "#email-preview-subject", "From a file")
    assert has_element?(view, "#email-source-subject", "Host file")

    assert has_element?(
             view,
             "#email-source-subject [data-source-path]",
             Path.join(root, "register/subject.txt")
           )

    assert has_element?(view, "#email-source-markdown [data-builds=html]")
    assert has_element?(view, "#email-source-markdown [data-builds=text]")
    refute has_element?(view, "#email-source-text [data-builds]")
    assert has_element?(view, "#email-source-layout-group", "auth")

    assert has_element?(
             view,
             "#email-source-header [data-source-path]",
             Path.join(root, "_header-auth/html.html")
           )

    refute has_element?(view, "#email-source-footer [data-source-path]")
    assert has_element?(view, "#email-source-footer", "Built-in default")
    assert has_element?(view, "#email-preview-ignored", Path.join(root, "_footer/html.html"))
    assert has_element?(view, ~s(iframe#email-preview-html[srcdoc*="GROUP HEADER"]))
    # the hint names the file under the configured root
    assert has_element?(view, "#email-source-html", Path.join(root, "register/html.en.html"))
  end

  test "lists a placeholder no sample binds", %{conn: conn} do
    with_template_root(%{"register/text.txt" => "Code: {{one_time_code}}"})

    {:ok, view, _html} = live(conn, at("register"))

    assert has_element?(view, "#email-preview-missing", "one_time_code")
  end

  test "choosing another email patches the URL and re-renders", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element("#email-preview-item-failed_login_alert") |> render_click()

    assert_patch(view, at("failed_login_alert"))
    assert has_element?(view, "#email-preview-subject", "Failed sign-in attempts")
  end

  test "offers the enabled site languages and renders a dialect in its language",
       %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("es-ES")
    _ = Languages.enable_language("es-ES")

    {:ok, view, _html} = live(conn, at("register"))

    assert has_element?(view, ~s(#email-preview-locale option[value="es-ES"]))

    view
    |> element("#email-preview-locale-form")
    |> render_change(%{"locale" => "es-ES"})

    assert_patch(view, at("register", "es-ES"))

    spanish =
      RecipientLocale.in_locale("es", fn ->
        CoreTemplates.register_defaults().subject
      end)

    refute spanish == "Confirm your account"
    assert has_element?(view, "#email-preview-subject", spanish)
  end

  test "a module's emails are listed under the module's name", %{conn: conn} do
    with_module(EmailModule)

    {:ok, view, _html} = live(conn, at("fixture_text_only"))

    assert has_element?(view, "#email-preview-list .menu-title", "Fixture Module")
    assert has_element?(view, "#email-preview-subject", "Only text")
    # sent with `layout: false` and no html: there is no HTML version
    assert has_element?(view, "#email-preview-no-html")
    refute has_element?(view, "#email-preview-html")
    assert has_element?(view, "#email-source-layout", "Not used")
  end

  test "a module entry that raises, or carries junk, does not take the page down",
       %{conn: conn} do
    with_module(EmailModule)

    {:ok, view, _html} = live(conn, at("fixture_broken"))

    assert has_element?(view, "#email-preview-error", "boom")
    refute has_element?(view, "#email-preview-subject")
    assert has_element?(view, "#email-preview-item-fixture_broken.menu-active")
  end

  test "warns when an active database template answers the email", %{conn: conn} do
    previous = Application.get_env(:phoenix_kit, :email_provider)
    Application.put_env(:phoenix_kit, :email_provider, DbProvider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :email_provider, previous),
        else: Application.delete_env(:phoenix_kit, :email_provider)
    end)

    # a placeholder the file leaves unbound is not reported: the database
    # template answered, the file was never used
    with_template_root(%{"register/text.txt" => "Code: {{one_time_code}}"})

    {:ok, view, _html} = live(conn, at("register"))

    refute has_element?(view, "#email-preview-missing")
    assert has_element?(view, "#email-preview-db-notice")
    assert has_element?(view, "#email-preview-subject", "From the database")
    assert has_element?(view, "#email-source-subject", "Database template")
    assert has_element?(view, ~s(iframe#email-preview-html[srcdoc*="DB BODY"]))
  end

  test "host HTML reaches the page only inside the iframe's srcdoc", %{conn: conn} do
    with_template_root(%{
      "register/html.html" => ~s|<p>x</p><script>alert(1)</script><img src=x onerror="alert(2)">|
    })

    {:ok, view, html} = live(conn, at("register"))

    refute html =~ "<script>alert(1)</script>"
    refute render(view) =~ "<script>alert(1)</script>"
    assert has_element?(view, ~s|iframe#email-preview-html[srcdoc*="<script>alert(1)</script>"]|)
  end

  describe "access" do
    test "is gated by the settings permission, like the Emails Transactional page" do
      assert Auth.permission_key_for_admin_view(EmailPreview, :index) == "settings"

      assert Auth.permission_key_for_admin_view(EmailPreview, :index) ==
               Auth.permission_key_for_admin_view(
                 PhoenixKitWeb.Live.Settings.EmailSending,
                 :index
               )
    end

    test "an Admin without the settings permission is refused", %{conn: conn} do
      admin_role = Roles.get_role_by_name("Admin")
      :ok = revoke(admin_role.uuid)

      assert {:error, _redirect} = live(conn, @path)
    end
  end

  test "a language that is not an enabled site language is not used", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("register", "xx"))

    # the hint and the selection use the default language, never "xx" — an
    # arbitrary value would otherwise also mint a lookup-cache key per value
    refute render(view) =~ "subject.xx.txt"
    refute has_element?(view, ~s(#email-preview-locale option[selected][value="xx"]))
    assert has_element?(view, "#email-preview-locale option[selected]")
  end

  test "file paths are shown as they sit in the host's source tree", %{conn: conn} do
    base = Path.join(System.tmp_dir!(), "pk_app_#{System.unique_integer([:positive])}")
    root = Path.join(base, "priv/phoenix_kit_templates")
    File.mkdir_p!(Path.join(root, "register"))
    File.write!(Path.join(root, "register/subject.txt"), "Mine\n")

    previous = Application.get_env(:phoenix_kit, :template_paths)
    Application.put_env(:phoenix_kit, :template_paths, [root])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :template_paths, previous),
        else: Application.delete_env(:phoenix_kit, :template_paths)

      File.rm_rf!(base)
    end)

    {:ok, view, _html} = live(conn, at("register"))

    assert has_element?(
             view,
             "#email-source-subject [data-source-path]",
             "priv/phoenix_kit_templates/register/subject.txt"
           )

    refute has_element?(view, "#email-source-subject [data-source-path]", base)

    assert has_element?(
             view,
             "#email-source-html [data-override-file]",
             "priv/phoenix_kit_templates/register/html.en.html"
           )

    refute has_element?(view, "#email-source-html [data-override-file]", base)
  end

  test "a group the sending code names offers no layout.txt to create", %{conn: conn} do
    with_module(EmailModule)

    {:ok, view, _html} = live(conn, at("fixture_billing"))

    assert has_element?(view, "#email-source-layout-group", "billing")

    assert has_element?(
             view,
             "#email-source-layout-group [data-no-file]",
             "Set by the sending code"
           )

    refute has_element?(view, "#email-source-layout-group [data-override-file]")

    assert has_element?(
             view,
             "#email-source-header [data-override-file]",
             "_header-billing/html.html"
           )
  end

  test "without the layout, the layout, header and footer offer no file", %{conn: conn} do
    with_module(EmailModule)

    {:ok, view, _html} = live(conn, at("fixture_text_only"))

    for row <- ~w(layout-group layout header footer) do
      assert has_element?(view, "#email-source-#{row} [data-no-file]", "Not used")
      refute has_element?(view, "#email-source-#{row} [data-override-file]")
    end
  end

  test "an email with no text version says so", %{conn: conn} do
    with_module(EmailModule)

    {:ok, view, _html} = live(conn, at("fixture_html_only"))

    assert has_element?(view, "#email-preview-no-text")
    assert has_element?(view, ~s(iframe#email-preview-html[srcdoc*="Only HTML"]))
  end

  test "a module whose email_templates/0 throws does not take the page down", %{conn: conn} do
    with_module(ThrowingModule)

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#email-preview-item-register")
  end

  test "a select_locale event without a language is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("register"))

    render_hook(view, "select_locale", %{"something" => "else"})
    render_hook(view, "select_locale", %{"locale" => %{"not" => "a string"}})

    assert has_element?(view, "#email-preview-subject", "Confirm your account")
  end

  test "an unknown email or language falls back to the defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("no_such_email", "xx"))

    assert has_element?(view, "#email-preview-item-register.menu-active")
    assert has_element?(view, "#email-preview-subject", "Confirm your account")
  end
end
