defmodule PhoenixKit.Integration.Dashboard.AccountMenuThemeTest do
  @moduledoc """
  The "Theme" row of the account menu on the host's pages
  (`UserDashboardNav.user_dropdown/1` with `show_theme_switcher`).

  A site that follows the system's light or dark theme had no way for a visitor
  to say otherwise short of the admin area's picker. The row is opt-in: only
  the host knows whether its own pages are styled for both themes.
  """
  use PhoenixKit.DataCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.UserDashboardNav

  defp scope! do
    {:ok, user} =
      Auth.register_user(%{
        email: "menu-theme-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    Scope.for_user(user)
  end

  defp menu(scope, show?) do
    assigns = %{scope: scope, show?: show?}

    rendered_to_string(~H"""
    <UserDashboardNav.user_dropdown
      scope={@scope}
      current_path="/"
      current_locale="en"
      show_theme_switcher={@show?}
    />
    """)
  end

  test "is not there unless the host asks for it" do
    html = menu(scope!(), false)

    refute html =~ "data-account-menu-theme"
    refute html =~ ~s(data-theme-role="inline-option")
  end

  test "is off by default: a host that says nothing gets the menu it had" do
    assigns = %{scope: scope!()}

    html =
      rendered_to_string(~H"""
      <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="en" />
      """)

    refute html =~ "data-account-menu-theme"
  end

  test "offers system and the configured light and dark theme, signed in" do
    html = menu(scope!(), true)
    {light, dark} = PhoenixKit.ThemeConfig.system_pair()

    assert html =~ "data-account-menu-theme"

    for theme <- ["system", light, dark] do
      assert html =~ ~s(data-theme-option="#{theme}")
    end

    # Three choices, whatever longer list the admin picker offers.
    assert length(String.split(html, ~s(data-theme-role="inline-option"))) == 4

    # The script the buttons need comes with the row: a host that only turns
    # the row on does not end up with three dead buttons.
    assert html =~ "__pkThemeController"
  end

  test "is offered to a visitor who is not signed in as well" do
    html = menu(nil, true)

    assert html =~ "data-account-menu-theme"
    assert html =~ ~s(data-theme-option="system")
    refute menu(nil, false) =~ "data-account-menu-theme"
  end
end
