defmodule PhoenixKit.Integration.Users.ListPaginationTest do
  @moduledoc """
  Rows-per-page on the Sessions and Roles tabs and the media selector.

  Each tab reads `per_page` from the query string through `UrlState`, so the
  contract is the same everywhere and is pinned once per tab: the value is
  honoured, an unlisted value falls back to the default (25, or the person's
  saved size: `admin_page_size_test.exs`), and choosing a size from
  `<.page_size_selector>` lands on page 1. The Users tab is in
  `users_tab_pagination_test.exs` and Live Sessions in
  `live_sessions_pagination_test.exs` — both need `async: false`.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.Routes

  defp unique_email, do: "pag_#{System.unique_integer([:positive])}@example.com"

  # Filler rows only: a direct insert skips the bcrypt round per user that
  # `register_user/1` pays, which at 30 users was pushing a test past the
  # suite's timeout under load.
  defp create_users!(n) do
    for _ <- 1..n do
      %User{}
      |> Ecto.Changeset.change(%{email: unique_email(), hashed_password: "not-a-hash"})
      |> Repo.insert!()
    end
  end

  # The selector renders the current size as the selected option; `Auto`
  # (when offered) wins over the number it resolved to.
  defp selected_size(html) do
    case Regex.run(~r/<option value="([^"]+)"\s+selected/, html) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp query_of(path), do: path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp page_links(html) do
    ~r/page=(\d+)(?:"|&amp;)/
    |> Regex.scan(html)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
    |> Enum.uniq()
  end

  setup %{conn: conn} do
    {admin, _token} = create_admin_user()
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "/admin/users/sessions" do
    defp create_sessions!(n) do
      [user] = create_users!(1)
      for _ <- 1..n, do: Auth.generate_user_session_token(user)
      user
    end

    test "per_page from the URL is honoured, unlisted values fall back to 25", %{conn: conn} do
      # With the admin's own two sessions, 27: two pages of 25, one of 50.
      create_sessions!(25)

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions"))
      assert selected_size(html) == "25"
      assert 2 in page_links(html)

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions?per_page=50"))
      assert selected_size(html) == "50"
      assert page_links(html) == []

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions?per_page=7"))
      assert selected_size(html) == "25"
    end

    test "choosing a size resets to page 1", %{conn: conn} do
      create_sessions!(25)
      {:ok, view, _html} = live(conn, Routes.path("/admin/users/sessions?page=2"))

      view
      |> element("form[phx-change=change_per_page]")
      |> render_change(%{"per_page" => "50"})

      # Saved as the admin's size, so the address no longer needs it.
      assert_patch(view, Routes.path("/admin/users/sessions"))
      assert selected_size(render(view)) == "50"
    end

    test "a page past the end shows the last page, not an empty one", %{conn: conn} do
      user = create_sessions!(25)

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/sessions?page=99"))
      assert html =~ user.email
      assert html =~ "Showing 26 to"
    end
  end

  describe "Sessions.list_sessions_paginated/1" do
    test "filters in SQL and pages with limit/offset" do
      user = create_sessions!(3)
      [other] = create_users!(1)
      Auth.generate_user_session_token(other)

      assert %{total_count: 3, total_pages: 2, page: 2, sessions: [_]} =
               Sessions.list_sessions_paginated(search: user.email, page: 2, per_page: 2)

      # A LIKE wildcard typed into the search box is a literal character.
      assert %{total_count: 0} = Sessions.list_sessions_paginated(search: "%")

      # Both freshly registered users are unconfirmed; the admin from setup
      # (confirmed, logged in) must not leak into the pending bucket.
      assert %{total_count: 4, sessions: pending} =
               Sessions.list_sessions_paginated(user_status: "pending")

      assert Enum.all?(pending, &is_nil(&1.user_confirmed_at))

      assert %{sessions: confirmed} = Sessions.list_sessions_paginated(user_status: "confirmed")
      refute Enum.any?(confirmed, &(&1.user_email in [user.email, other.email]))
    end
  end

  describe "/admin/users/roles" do
    defp create_roles!(n) do
      for i <- 1..n do
        {:ok, role} =
          Roles.create_role(%{name: "Pag Role #{System.unique_integer([:positive])} #{i}"})

        role
      end
    end

    test "the list is paginated at 25 by default and per_page is honoured", %{conn: conn} do
      # Whatever the seeded system roles number, 25 custom on top spills
      # onto a second page of 25 and fits one page of 50.
      create_roles!(25)
      total = Roles.count_roles().total
      assert total in 26..50

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/roles"))
      assert selected_size(html) == "25"
      assert 2 in page_links(html)
      # The toolbar counts every role, not just the page.
      assert html =~ ~r/\b#{total} roles\b/

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/roles?per_page=50"))
      assert selected_size(html) == "50"
      assert page_links(html) == []

      {:ok, _view, html} = live(conn, Routes.path("/admin/users/roles?per_page=7"))
      assert selected_size(html) == "25"
    end

    test "choosing a size resets to page 1", %{conn: conn} do
      create_roles!(25)
      {:ok, view, _html} = live(conn, Routes.path("/admin/users/roles?page=2"))

      view
      |> element("form[phx-change=change_per_page]")
      |> render_change(%{"per_page" => "50"})

      # Saved as the admin's size, so the address no longer needs it.
      assert_patch(view, Routes.path("/admin/users/roles"))
      assert selected_size(render(view)) == "50"
    end
  end

  describe "/admin/media/selector" do
    defp create_files!(n, user_uuid) do
      for _ <- 1..n do
        i = System.unique_integer([:positive])

        {:ok, file} =
          Repo.insert(%StorageFile{
            original_file_name: "pag_#{i}.jpg",
            file_name: "pag_#{i}.jpg",
            mime_type: "image/jpeg",
            file_type: "image",
            ext: "jpg",
            file_checksum: "sha256:pag-#{i}",
            user_file_checksum: "user-sha256:pag-#{i}",
            size: 1024,
            status: "active",
            user_uuid: user_uuid
          })

        file
      end
    end

    test "per_page from the URL is honoured, unlisted values fall back to 30",
         %{conn: conn, admin: admin} do
      create_files!(31, admin.uuid)
      base = Routes.path("/admin/media/selector")

      {:ok, _view, html} = live(conn, base <> "?return_to=/admin&mode=single")
      assert selected_size(html) == "30"
      assert 2 in page_links(html)

      {:ok, _view, html} = live(conn, base <> "?return_to=/admin&mode=single&per_page=50")
      assert selected_size(html) == "50"
      assert page_links(html) == []

      {:ok, _view, html} = live(conn, base <> "?per_page=7")
      assert selected_size(html) == "30"
    end

    test "choosing a size resets to page 1 and keeps the picker's own params",
         %{conn: conn, admin: admin} do
      create_files!(31, admin.uuid)
      base = Routes.path("/admin/media/selector")

      {:ok, view, _html} = live(conn, base <> "?return_to=/admin&mode=single&page=2")

      view
      |> element("form[phx-change=change_per_page]")
      |> render_change(%{"per_page" => "50"})

      assert query_of(assert_patch(view)) ==
               %{"return_to" => "/admin", "mode" => "single", "per_page" => "50"}
    end
  end
end
