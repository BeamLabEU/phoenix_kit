defmodule PhoenixKitWeb.Live.Settings.EmailSendingSectionLinksTest do
  @moduledoc """
  The `:link` of a module-contributed section
  (`c:PhoenixKit.Module.email_settings_sections/0`) on the Emails
  Transactional settings page: a button beside "Preview emails" on the
  Branding tab, leading to the section's own tab or to the path it names,
  shown only to whoever may see the section.

  `async: false` — the fixture module is registered in the global
  `PhoenixKit.ModuleRegistry`, so other pages rendered meanwhile would see it.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Utils.Routes

  defmodule FixtureSection do
    @moduledoc false
    use Phoenix.LiveComponent

    def render(assigns) do
      ~H"""
      <div id={"fixture-section-#{@id}"}>Fixture section</div>
      """
    end
  end

  defmodule SectionsModule do
    @moduledoc false
    def enabled?, do: true

    def email_settings_sections do
      [
        %{
          id: :fixture_tab,
          title: "Fixture tab",
          permission: nil,
          component: FixtureSection,
          link: %{label: "Open fixture tab"}
        },
        %{
          id: :fixture_path,
          title: "Fixture path",
          permission: nil,
          component: FixtureSection,
          link: %{label: "Open fixture page", path: "/admin/settings/fixture-page"}
        },
        %{id: :fixture_plain, title: "Fixture plain", permission: nil, component: FixtureSection},
        %{
          id: :fixture_relative,
          title: "Fixture relative",
          permission: nil,
          component: FixtureSection,
          link: %{label: "Open relative fixture", path: "fixture-page"}
        },
        %{
          id: :fixture_other_host,
          title: "Fixture other host",
          permission: nil,
          component: FixtureSection,
          link: %{label: "Open other host fixture", path: "//other.example/admin"}
        },
        %{
          id: :fixture_nil_path,
          title: "Fixture nil path",
          permission: nil,
          component: FixtureSection,
          link: %{label: "Open nil path fixture", path: nil}
        },
        %{
          id: :fixture_no_label,
          title: "Fixture no label",
          permission: nil,
          component: FixtureSection,
          link: %{label: nil}
        },
        %{
          id: :fixture_backslash_host,
          title: "Fixture backslash host",
          permission: nil,
          component: FixtureSection,
          link: %{label: "Open backslash host fixture", path: "/\\other.example/admin"}
        },
        %{
          id: :fixture_gated,
          title: "Fixture gated",
          permission: "fixture_permission_nobody_holds",
          component: FixtureSection,
          link: %{label: "Open gated fixture"}
        }
      ]
    end
  end

  @path Routes.path("/admin/settings/email-sending")

  setup %{conn: conn} do
    ModuleRegistry.register(SectionsModule)
    on_exit(fn -> ModuleRegistry.unregister(SectionsModule) end)

    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user)}
  end

  test "a section's link sits beside Preview emails and opens the section's tab",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?tab=branding")

    tab_path = Routes.path("/admin/settings/email-sending?tab=module_fixture_tab")
    link = "#email-branding-panel #email-section-link-fixture_tab"

    assert has_element?(view, ~s(#{link}[href="#{tab_path}"]), "Open fixture tab")
    assert has_element?(view, "#email-branding-panel #email-preview-link")

    view |> element(link) |> render_click()

    assert_patch(view, tab_path)
    assert has_element?(view, "#fixture-section-fixture_tab")
    refute has_element?(view, ~s(div.hidden #fixture-section-fixture_tab))
  end

  test "a link with a path leads there", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(
             view,
             ~s(#email-section-link-fixture_path[href="#{Routes.path("/admin/settings/fixture-page")}"]),
             "Open fixture page"
           )
  end

  test "a section without a link adds no button", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#fixture-section-fixture_plain")
    refute has_element?(view, "#email-section-link-fixture_plain")
  end

  test "a link whose path is not an absolute path is left out", %{conn: conn} do
    {:ok, view, html} = live(conn, @path)

    assert has_element?(view, "#fixture-section-fixture_relative")
    refute has_element?(view, "#email-section-link-fixture_relative")
    refute html =~ "Open relative fixture"

    # Protocol-relative: another host, not a path of this app.
    assert has_element?(view, "#fixture-section-fixture_other_host")
    refute has_element?(view, "#email-section-link-fixture_other_host")
    refute html =~ "Open other host fixture"

    # A browser reads "/\\host" as "//host" too.
    assert has_element?(view, "#fixture-section-fixture_backslash_host")
    refute has_element?(view, "#email-section-link-fixture_backslash_host")
    refute html =~ "Open backslash host fixture"

    # A path that is not a string drops the button; it does not fall back to the tab.
    assert has_element?(view, "#fixture-section-fixture_nil_path")
    refute has_element?(view, "#email-section-link-fixture_nil_path")
    refute html =~ "Open nil path fixture"
  end

  test "a link whose label is not a string is left out", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#fixture-section-fixture_no_label")
    refute has_element?(view, "#email-section-link-fixture_no_label")
  end

  test "the link of a section the user may not see is not shown", %{conn: conn} do
    {:ok, view, html} = live(conn, @path)

    refute has_element?(view, "#fixture-section-fixture_gated")
    refute has_element?(view, "#email-section-link-fixture_gated")
    refute html =~ "Open gated fixture"
  end
end
