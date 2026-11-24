defmodule PhoenixKitWeb.Live.AdminMenuHandoffTest do
  @moduledoc """
  The page's host reaches the admin account menu on its own for a LiveView rendered through the
  admin layout: the navigation hook assigns `:url_host`, `layouts/admin.html.heex` hands it to
  `app_layout/1`, and the menu's language list hands the visitor over to the other language's
  domain through the cross-domain handoff.

  The test endpoint serves `www.example.com`, so that is the site's English host here.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Languages

  @path "/phoenix_kit/admin/__test/admin-edit-probe"

  defmodule Resolver do
    def host("en"), do: "www.example.com"
    def host("de"), do: "shop-de.test"
    def host(_), do: nil
  end

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)
    :ok
  end

  defp menu_links(html) do
    [menu] = Regex.run(~r/<ul[^>]*id="pk-admin-account-menu".*?<\/ul>/s, html)
    LazyHTML.from_fragment(menu)
  end

  test "the other language's domain is a handoff link, not a language switch", %{conn: conn} do
    Application.put_env(:phoenix_kit, :canonical_host_resolver, {Resolver, :host})
    {admin, _} = create_admin_user()
    {:ok, _lv, html} = live(log_in_user(conn, admin), @path)

    menu = menu_links(html)
    links = LazyHTML.query(menu, "a[rel=nofollow]")

    assert LazyHTML.attribute(links, "href") ==
             [
               "/phoenix_kit/handoff/start?lang=de-DE&to=%2Fphoenix_kit%2Fadmin%2F__test%2Fadmin-edit-probe"
             ]

    assert LazyHTML.query(menu, "[phx-value-locale]") |> LazyHTML.attribute("phx-value-locale") ==
             []
  end

  test "without a domain map the menu is the plain language switch", %{conn: conn} do
    {admin, _} = create_admin_user()
    {:ok, _lv, html} = live(log_in_user(conn, admin), @path)

    menu = menu_links(html)

    assert LazyHTML.query(menu, "a[rel=nofollow]") |> LazyHTML.attribute("href") == []

    assert LazyHTML.query(menu, "button[phx-value-locale]")
           |> LazyHTML.attribute("phx-value-locale") == ["de-DE"]
  end
end
