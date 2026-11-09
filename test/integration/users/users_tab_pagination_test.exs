defmodule PhoenixKit.Integration.Users.UsersTabPaginationTest do
  @moduledoc """
  Rows-per-page on the Users tab, plus the Auto (fit-to-viewport) pilot.

  Same contract as `list_pagination_test.exs`, but `async: false`: the Users
  LiveView subscribes to the global users/stats PubSub topics and reloads the
  page on every event, so while other files register and delete users in
  parallel a mounted view queues hundreds of reloads and a `render_change`
  behind them trips the test timeout.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes

  defp unique_email, do: "pag_#{System.unique_integer([:positive])}@example.com"

  # Filler rows only: a direct insert skips the bcrypt round per user that
  # `register_user/1` pays.
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
    {:ok, conn: log_in_user(conn, admin)}
  end

  describe "/admin/users" do
    test "per_page from the URL is honoured and drives the page count", %{conn: conn} do
      # The admin from setup makes it 31 users: 2 pages of 25, 1 page of 50.
      create_users!(30)

      {:ok, _view, html} = live(conn, Routes.path("/admin/users"))
      assert selected_size(html) == "25"
      assert 2 in page_links(html)

      {:ok, _view, html} = live(conn, Routes.path("/admin/users?per_page=50"))
      assert selected_size(html) == "50"
      assert page_links(html) == []
    end

    test "a per_page outside the allowlist falls back to the default", %{conn: conn} do
      {:ok, _view, html} = live(conn, Routes.path("/admin/users?per_page=7"))
      assert selected_size(html) == "25"

      {:ok, _view, html} = live(conn, Routes.path("/admin/users?per_page=1000000"))
      assert selected_size(html) == "25"
    end

    test "choosing a size from the selector resets to page 1", %{conn: conn} do
      create_users!(30)

      {:ok, view, _html} = live(conn, Routes.path("/admin/users?page=2"))

      view
      |> element("form[phx-change=change_per_page]")
      |> render_change(%{"per_page" => "50"})

      # Saved as the admin's size, so the address no longer needs it.
      assert_patch(view, Routes.path("/admin/users"))
      assert selected_size(render(view)) == "50"
    end

    test "page links preserve a size the link named", %{conn: conn} do
      create_users!(30)

      {:ok, _view, html} = live(conn, Routes.path("/admin/users?per_page=10"))
      assert html =~ "page=2"
      assert html =~ ~r/per_page=10[^"]*page=2|page=2[^"]*per_page=10/
    end

    test "Auto raises the fit flag, the hook's push keeps it, a hand-picked size drops it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/users"))

      view
      |> element("form[phx-change=change_per_page]")
      |> render_change(%{"per_page" => "auto"})

      # Auto is the admin's saved choice now, so it needs no `fit` in the URL.
      assert_patch(view, Routes.path("/admin/users"))
      assert selected_size(render(view)) == "auto"

      # What the PageSizeAutoFit hook pushes once it has measured the table.
      render_hook(view, "change_per_page", %{"per_page" => "50", "auto" => "1"})
      assert query_of(assert_patch(view)) == %{"per_page" => "50"}
      assert selected_size(render(view)) == "auto"

      view
      |> element("form[phx-change=change_per_page]")
      |> render_change(%{"per_page" => "10"})

      assert_patch(view, Routes.path("/admin/users"))
      assert selected_size(render(view)) == "10"
    end
  end
end
