defmodule PhoenixKitWeb.Live.AdminMenuHandoffTest do
  @moduledoc """
  The page's host reaches the admin account menu on every admin page of the kit, and the menu's
  language list hands the visitor over to the other language's domain through the cross-domain
  handoff.

  Two routes carry the host: the page's own socket (`LayoutWrapper.app_layout/1` called
  directly, which the plugin pages' `layouts/admin.html.heex` also does) and an explicit
  `current_host` (the few kit pages that pass no socket; `AppLayoutHostGuardTest` pins that every
  call passes one of the two).

  The test endpoint serves `www.example.com`, so that is the site's English host here.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitWeb.Components.AccountMenu

  @probe "/phoenix_kit/admin/__test/admin-edit-probe"
  @start "/phoenix_kit/handoff/start?lang=de-DE&to="

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

  defp resolver!,
    do: Application.put_env(:phoenix_kit, :canonical_host_resolver, {Resolver, :host})

  defp menu(html) do
    [menu] = Regex.run(~r/<ul[^>]*id="pk-admin-account-menu".*?<\/ul>/s, html)
    LazyHTML.from_fragment(menu)
  end

  defp language_buttons(html), do: LazyHTML.query(menu(html), "button[phx-value-locale]")

  defp urls(html),
    do: html |> language_buttons() |> LazyHTML.attribute("phx-value-url")

  # Every page of the kit that wears the admin chrome, by the way it learns the host.
  @pages [
    {"a plugin page (admin layout, with its socket)",
     "/phoenix_kit/admin/__test/admin-edit-probe"},
    {"a page that passes its socket", "/phoenix_kit/admin/users"},
    {"the admin dashboard", "/phoenix_kit/admin"},
    {"a page that passes no socket", "/phoenix_kit/admin/settings/media"},
    {"another page that passes no socket", "/phoenix_kit/admin/settings/emails-bulk"}
  ]

  for {name, path} <- @pages do
    test "the other language's domain is a handoff url on #{name}", %{conn: conn} do
      resolver!()
      {admin, _} = create_admin_user()
      {:ok, _lv, html} = live(log_in_user(conn, admin), unquote(path))

      assert [url] = urls(html)
      assert String.starts_with?(url, @start)
      assert URI.decode_www_form(String.replace_prefix(url, @start, "")) =~ "/phoenix_kit/admin"
    end

    test "without a domain map #{name} keeps the plain language switch", %{conn: conn} do
      {admin, _} = create_admin_user()
      {:ok, _lv, html} = live(log_in_user(conn, admin), unquote(path))

      assert [url] = urls(html)
      refute url =~ "/handoff/"
    end
  end

  test "picking the language through the handoff still saves the preference", %{conn: conn} do
    resolver!()
    {admin, _} = create_admin_user()
    {:ok, lv, _html} = live(log_in_user(conn, admin), @probe)

    result =
      lv
      |> element("#pk-admin-account-menu button[phx-value-locale=de-DE]")
      |> render_click()

    # `start` is a controller, not a LiveView: the handler sends the browser there with a full
    # page load, not a navigation that stays on the socket.
    assert {:error, {:redirect, %{to: to}}} = result
    assert String.starts_with?(to, @start)

    assert Repo.get!(User, admin.uuid).custom_fields["preferred_locale"] == "de-DE"
  end

  describe "the language event handler" do
    setup %{conn: conn} do
      {admin, _} = create_admin_user()
      %{conn: log_in_user(conn, admin)}
    end

    # A page that has redirected is gone: every pick mounts its own.
    defp pick(conn, url) do
      {:ok, lv, _html} = live(conn, @probe)
      render_hook(lv, "phoenix_kit_set_locale", %{"locale" => "de-DE", "url" => url})
    end

    test "an ordinary language switch stays on the socket", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/phoenix_kit/de/admin/anything"}}} =
               pick(conn, "/phoenix_kit/de/admin/anything")
    end

    test "the handoff start is left with a full page load", %{conn: conn} do
      start = "/phoenix_kit/handoff/start"

      assert {:error, {:redirect, %{to: to}}} = pick(conn, start <> "?lang=de-DE&to=%2F")
      assert to == start <> "?lang=de-DE&to=%2F"
    end

    test "a path that merely begins like the start is not it", %{conn: conn} do
      assert {:error, {:live_redirect, _}} = pick(conn, "/phoenix_kit/handoff/startx?lang=de-DE")
      assert {:error, {:live_redirect, _}} = pick(conn, "/phoenix_kit/handoff/starting")
    end
  end

  describe "what the start endpoint does with the menu's url" do
    defp start(url, host) do
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, host)
      |> Plug.Conn.put_req_header("sec-fetch-site", "same-origin")
      |> Plug.Conn.put_req_header("sec-fetch-dest", "document")
      |> get(url)
    end

    test "the url the menu renders is the one start follows, dialect segment included" do
      resolver!()
      {:ok, _} = Languages.add_language("en-GB")
      assigns = %{languages: AccountMenu.languages("de-DE", "shop-de.test")}

      html =
        rendered_to_string(~H"""
        <AccountMenu.language_section
          languages={@languages}
          current_path="/phoenix_kit/de/users/log-in"
          current_locale="de-DE"
          switch={:link}
        />
        """)

      gb =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a[rel=nofollow]")
        |> LazyHTML.attribute("href")
        |> Enum.find(&(&1 =~ "lang=en-GB"))

      conn = start(gb, "shop-de.test")
      assert redirected_to(conn, 302) == "https://www.example.com/phoenix_kit/en-gb/users/log-in"
    end
  end
end
