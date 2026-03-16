defmodule PhoenixKit.Modules.Publishing.Web.Controller.RoutingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Controller.Routing

  # ============================================================================
  # build_segments/1
  # ============================================================================

  describe "build_segments/1" do
    test "returns group only when no path" do
      assert Routing.build_segments(%{"group" => "blog"}) == ["blog"]
    end

    test "appends path list to group" do
      params = %{"group" => "blog", "path" => ["2026-03-16", "14:30"]}
      assert Routing.build_segments(params) == ["blog", "2026-03-16", "14:30"]
    end

    test "wraps binary path as single segment" do
      params = %{"group" => "docs", "path" => "getting-started"}
      assert Routing.build_segments(params) == ["docs", "getting-started"]
    end

    test "ignores non-list non-binary path" do
      params = %{"group" => "blog", "path" => 42}
      assert Routing.build_segments(params) == ["blog"]
    end

    test "returns empty list when group missing" do
      assert Routing.build_segments(%{"path" => ["foo"]}) == []
      assert Routing.build_segments(%{}) == []
    end

    test "returns empty list for non-map input" do
      assert Routing.build_segments(nil) == []
      assert Routing.build_segments("string") == []
    end
  end

  # ============================================================================
  # parse_path/1
  # ============================================================================

  describe "parse_path/1" do
    test "empty list returns error" do
      assert Routing.parse_path([]) == {:error, :invalid_path}
    end

    test "single segment returns listing" do
      assert Routing.parse_path(["blog"]) == {:listing, "blog"}
    end

    test "slug post" do
      assert Routing.parse_path(["docs", "getting-started"]) ==
               {:slug_post, "docs", "getting-started"}
    end

    test "timestamp post with date and time" do
      assert Routing.parse_path(["blog", "2026-03-16", "14:30"]) ==
               {:timestamp_post, "blog", "2026-03-16", "14:30"}
    end

    test "date-only post" do
      assert Routing.parse_path(["blog", "2026-03-16"]) ==
               {:date_only_post, "blog", "2026-03-16"}
    end

    test "versioned post" do
      assert Routing.parse_path(["docs", "my-post", "v", "3"]) ==
               {:versioned_post, "docs", "my-post", 3}
    end

    test "versioned post with invalid version" do
      assert Routing.parse_path(["docs", "my-post", "v", "abc"]) ==
               {:error, :invalid_version}
    end

    test "versioned post with zero version" do
      assert Routing.parse_path(["docs", "my-post", "v", "0"]) ==
               {:error, :invalid_version}
    end

    test "versioned post with negative version" do
      assert Routing.parse_path(["docs", "my-post", "v", "-1"]) ==
               {:error, :invalid_version}
    end

    test "two segments where first is date and second is not time" do
      assert Routing.parse_path(["blog", "2026-03-16", "not-a-time"]) ==
               {:error, :invalid_path}
    end

    test "too many segments" do
      assert Routing.parse_path(["a", "b", "c", "d", "e"]) == {:error, :invalid_path}
    end
  end

  # ============================================================================
  # date?/1
  # ============================================================================

  describe "date?/1" do
    test "valid dates" do
      assert Routing.date?("2026-01-01")
      assert Routing.date?("2026-12-31")
      assert Routing.date?("2000-06-15")
    end

    test "invalid dates" do
      refute Routing.date?("2026-13-01")
      refute Routing.date?("2026-00-01")
      refute Routing.date?("2026-01-32")
      refute Routing.date?("2026-01-00")
      refute Routing.date?("not-a-date")
      refute Routing.date?("20260101")
      refute Routing.date?("2026-1-1")
    end

    test "non-string input" do
      refute Routing.date?(nil)
      refute Routing.date?(42)
      refute Routing.date?(~D[2026-01-01])
    end
  end

  # ============================================================================
  # time?/1
  # ============================================================================

  describe "time?/1" do
    test "valid times" do
      assert Routing.time?("00:00")
      assert Routing.time?("23:59")
      assert Routing.time?("12:30")
      assert Routing.time?("09:05")
    end

    test "invalid times" do
      refute Routing.time?("24:00")
      refute Routing.time?("12:60")
      refute Routing.time?("1:30")
      refute Routing.time?("12:5")
      refute Routing.time?("12:30:00")
      refute Routing.time?("not-a-time")
    end

    test "non-string input" do
      refute Routing.time?(nil)
      refute Routing.time?(42)
      refute Routing.time?(~T[12:30:00])
    end
  end
end
