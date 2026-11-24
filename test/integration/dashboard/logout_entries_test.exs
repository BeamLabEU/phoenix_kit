defmodule PhoenixKit.Integration.Dashboard.LogoutEntriesTest do
  @moduledoc """
  The log-out entries of the avatar dropdowns are not GET links.

  `GET /users/log-out` signs out with no token, so a link that navigates there
  lets a third-party page sign a visitor out through a cross-site top-level
  navigation (a subresource such as an `<img>` carries no `SameSite=Lax`
  session) and lets a prefetcher do it too. Every entry must instead carry
  `data-method="delete"` and a CSRF token, which phoenix_html turns into a
  token-bearing DELETE form. `<.link navigate=…>` silently drops `method`, so
  the entry stays a plain GET navigation — that is what these tests catch.
  """
  use PhoenixKit.DataCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.{AdminNav, UserDashboardNav}

  defp scope! do
    {:ok, user} =
      Auth.register_user(%{
        email: "logout-entry-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    account = fn ref, active? ->
      %{ref: ref, email: user.email, role: "User", active?: active?, root?: ref == "a"}
    end

    %{
      Scope.for_user(user)
      | multi_session_allowed?: true,
        multi_session_accounts: [account.("a", true), account.("b", false)]
    }
  end

  # Every anchor that points at a log-out route, as its raw opening tag.
  defp logout_anchors(html) do
    ~r/<a\b[^>]*\/users\/log-out[^>]*>/
    |> Regex.scan(html)
    |> List.flatten()
  end

  defp assert_not_a_get_navigation(anchors) do
    assert anchors != []

    for tag <- anchors do
      assert tag =~ ~s(data-method="delete"), "log-out entry is a GET link: #{tag}"
      assert tag =~ ~r/data-csrf="[^"]+"/, "log-out entry carries no CSRF token: #{tag}"

      assert tag =~ ~r/data-to="[^"]*\/users\/log-out/,
             "log-out entry has no DELETE target: #{tag}"

      refute tag =~ "data-phx-link", "log-out entry is a LiveView navigation: #{tag}"
    end
  end

  test "the user dropdown's log-out and log-out-everywhere entries post a DELETE" do
    assigns = %{scope: scope!()}

    html =
      rendered_to_string(~H"""
      <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="en" />
      """)

    anchors = logout_anchors(html)
    assert length(anchors) == 2
    assert Enum.any?(anchors, &(&1 =~ ~r/data-to="[^"]*\/users\/log-out\?all=1"/))
    assert_not_a_get_navigation(anchors)
  end

  test "the admin dropdown's log-out and log-out-everywhere entries post a DELETE" do
    scope = scope!()
    assigns = %{scope: scope, accounts: scope.multi_session_accounts}

    html =
      rendered_to_string(~H"""
      <AdminNav.admin_user_dropdown
        scope={@scope}
        accounts={@accounts}
        multi_session_allowed?={true}
        current_path="/"
        current_locale="en"
      />
      """)

    anchors = logout_anchors(html)
    assert length(anchors) == 2
    assert Enum.any?(anchors, &(&1 =~ ~r/data-to="[^"]*\/users\/log-out\?all=1"/))
    assert_not_a_get_navigation(anchors)
  end

  test "the admin sidebar user info card's log-out entry posts a DELETE" do
    assigns = %{scope: scope!()}

    html =
      rendered_to_string(~H"""
      <AdminNav.admin_user_info scope={@scope} />
      """)

    anchors = logout_anchors(html)
    assert length(anchors) == 1
    assert_not_a_get_navigation(anchors)
  end

  test "both dropdowns carry the visitor's locale in their log-out targets" do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    scope = scope!()
    assigns = %{scope: scope, accounts: scope.multi_session_accounts}

    user_html =
      rendered_to_string(~H"""
      <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="de-DE" />
      """)

    admin_html =
      rendered_to_string(~H"""
      <AdminNav.admin_user_dropdown
        scope={@scope}
        accounts={@accounts}
        multi_session_allowed?={true}
        current_path="/"
        current_locale="de-DE"
      />
      """)

    expected = Routes.path("/users/log-out", locale: "de")
    assert expected =~ "/de/users/log-out"

    for html <- [user_html, admin_html] do
      anchors = logout_anchors(html)
      assert length(anchors) == 2
      assert Enum.any?(anchors, &(&1 =~ ~s(data-to="#{expected}")))
      assert Enum.any?(anchors, &(&1 =~ ~s(data-to="#{expected}?all=1")))
      assert_not_a_get_navigation(anchors)
    end
  end
end
