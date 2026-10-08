defmodule PhoenixKitWeb.Components.Core.LibraryLoadNoticeTest do
  @moduledoc """
  The viewer-library failure notice is a deployment diagnostic: it renders
  for the active scope's Owner, Admin or superadmin — the people who can act
  on a Content-Security-Policy or a broken build — and for nobody else. Not
  `can_access_admin_area?/1`, which is also true for any single-permission
  holder (a restricted media viewer). Both shells render it beside their
  flash group.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.Core.LibraryLoadNotice

  defp scope(roles, perms \\ []),
    do: %Scope{
      authenticated?: true,
      cached_roles: roles,
      held_roles: roles,
      cached_permissions: MapSet.new(perms)
    }

  defp render(scope),
    do: rendered_to_string(LibraryLoadNotice.library_load_notice(%{scope: scope, id: "n"}))

  test "renders for an Owner, an Admin and a superadmin" do
    for s <- [scope(["Owner"]), scope(["Admin"]), scope(["User"], ["*"])] do
      html = render(s)
      assert html =~ ~s(phx-hook="LibraryLoadNotice")
      assert html =~ "hidden", "starts hidden — the hook shows it only when something failed"
      assert html =~ "Some features on this page could not load"
    end
  end

  test "renders nothing for an anonymous visitor, a user, or a single-permission holder" do
    for s <- [nil, scope(["User"]), scope(["Editor"], ["media"])] do
      assert render(s) == ""
    end
  end

  test "an Owner acting as a lesser role sees what that role sees" do
    # Active role narrows cached_roles to the role being acted as.
    acting = %{scope(["User"]) | held_roles: ["Owner", "User"]}
    assert render(acting) == ""
  end

  test "every layout shell renders it beside its flash group" do
    wrapper = File.read!("lib/phoenix_kit_web/components/layout_wrapper.ex")
    flashes = length(Regex.scan(~r/<\.flash_group flash=\{@flash\} \/>/, wrapper))

    notices =
      length(
        Regex.scan(
          ~r/<\.flash_group flash=\{@flash\} \/>\n\s*<\.library_load_notice scope=\{assigns\[:phoenix_kit_current_scope\]\} \/>/,
          wrapper
        )
      )

    assert flashes > 0 and notices == flashes, "#{notices} of #{flashes} LayoutWrapper branches"

    dashboard = File.read!("lib/phoenix_kit_web/components/layouts/dashboard.html.heex")

    assert dashboard =~ ~s(id="pk-library-notice-dashboard"),
           "the dashboard has its own shell, and its own id"
  end
end
