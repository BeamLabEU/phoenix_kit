defmodule PhoenixKitWeb.Live.Users.MediaUrlTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # URL building helpers (mirrors handle_info logic in media.ex)
  # ---------------------------------------------------------------------------

  defp build_url(params) do
    base = "/phoenix_kit/admin/media"
    folder = params[:folder]
    q = params[:q] || ""
    page = params[:page] || 1
    filter_orphaned = params[:filter_orphaned] || false

    qs =
      %{}
      |> then(&if folder, do: Map.put(&1, "folder", folder), else: &1)
      |> then(&if q != "", do: Map.put(&1, "q", q), else: &1)
      |> then(&if page > 1, do: Map.put(&1, "page", page), else: &1)
      |> then(&if filter_orphaned, do: Map.put(&1, "orphaned", "1"), else: &1)

    if qs == %{}, do: base, else: base <> "?" <> URI.encode_query(qs)
  end

  defp parse_page(str) do
    case Integer.parse(str || "1") do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  # ---------------------------------------------------------------------------
  # URL building — handle_info navigate params → URL
  # ---------------------------------------------------------------------------

  describe "URL building for navigate params" do
    test "no params produces bare base path" do
      url = build_url(%{})
      assert url == "/phoenix_kit/admin/media"
    end

    test "folder param appended as query string" do
      url = build_url(%{folder: "abc-123"})
      assert url =~ "folder=abc-123"
    end

    test "search query appended" do
      url = build_url(%{q: "logo"})
      assert url =~ "q=logo"
    end

    test "empty search query omitted" do
      url = build_url(%{q: ""})
      refute url =~ "q="
    end

    test "page 1 omitted from query string" do
      url = build_url(%{page: 1})
      refute url =~ "page="
    end

    test "page > 1 appended" do
      url = build_url(%{page: 3})
      assert url =~ "page=3"
    end

    test "orphaned filter appended as 1 when true" do
      url = build_url(%{filter_orphaned: true})
      assert url =~ "orphaned=1"
    end

    test "orphaned filter omitted when false" do
      url = build_url(%{filter_orphaned: false})
      refute url =~ "orphaned"
    end

    test "all params combined produces correct query string" do
      url =
        build_url(%{
          folder: "f-uuid",
          q: "img",
          page: 2,
          filter_orphaned: true
        })

      assert url =~ "folder=f-uuid"
      assert url =~ "q=img"
      assert url =~ "page=2"
      assert url =~ "orphaned=1"
    end

    test "nil folder omitted" do
      url = build_url(%{folder: nil})
      refute url =~ "folder"
    end
  end

  # ---------------------------------------------------------------------------
  # Page param parsing — Integer.parse safe fallback
  # ---------------------------------------------------------------------------

  describe "page param parsing" do
    test "valid integer string returns that integer" do
      assert parse_page("5") == 5
    end

    test "nil defaults to 1" do
      assert parse_page(nil) == 1
    end

    test "empty string defaults to 1" do
      assert parse_page("") == 1
    end

    test "non-numeric string defaults to 1" do
      assert parse_page("abc") == 1
    end

    test "zero defaults to 1" do
      assert parse_page("0") == 1
    end

    test "negative number defaults to 1" do
      assert parse_page("-3") == 1
    end

    test "string with trailing garbage still parses leading digits" do
      # Integer.parse("2abc") => {2, "abc"} — valid page
      assert parse_page("2abc") == 2
    end

    test "page 1 string returns 1" do
      assert parse_page("1") == 1
    end
  end
end
