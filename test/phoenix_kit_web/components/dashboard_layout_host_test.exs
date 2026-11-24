defmodule PhoenixKitWeb.Components.DashboardLayoutHostTest do
  @moduledoc """
  The user dashboard layout hands the page's host (`:url_host`, set by the navigation hook) to
  the avatar menu, so the menu's language list can hand a visitor over to another domain
  (`PhoenixKit.Handoff`). `dashboard_assigns/1` is what a page passes to the layout: the host
  has to survive it.
  """
  use PhoenixKit.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.HandoffResolver
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.LayoutHelpers

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    Application.put_env(:phoenix_kit, :canonical_host_resolver, {HandoffResolver, :host})
    on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)

    {:ok, user} =
      Auth.register_user(%{
        email: "dash-host-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    %{scope: Scope.for_user(user)}
  end

  defp render_layout(page_assigns) do
    assigns = %{page: LayoutHelpers.dashboard_assigns(page_assigns)}

    rendered_to_string(~H"""
    <PhoenixKitWeb.Layouts.dashboard {@page}>body</PhoenixKitWeb.Layouts.dashboard>
    """)
  end

  defp handoff_links(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a[rel=nofollow]")
    |> LazyHTML.attribute("href")
  end

  test "a page's :url_host reaches the avatar menu", %{scope: scope} do
    html =
      render_layout(%{
        flash: %{},
        phoenix_kit_current_scope: scope,
        url_path: "/phoenix_kit/dashboard",
        url_host: "shop.test",
        current_locale: "en-US"
      })

    assert handoff_links(html) == [
             "/phoenix_kit/handoff/start?lang=de-DE&to=%2Fphoenix_kit%2Fdashboard"
           ]
  end

  test "without a host the menu keeps its plain switch", %{scope: scope} do
    html =
      render_layout(%{
        flash: %{},
        phoenix_kit_current_scope: scope,
        url_path: "/phoenix_kit/dashboard",
        current_locale: "en-US"
      })

    assert handoff_links(html) == []
  end
end
