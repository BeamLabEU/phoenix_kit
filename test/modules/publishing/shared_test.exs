defmodule PhoenixKit.Modules.Publishing.SharedTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Shared

  # ============================================================================
  # uuid_format?/1
  # ============================================================================

  describe "uuid_format?/1" do
    test "returns true for valid UUIDv7" do
      assert Shared.uuid_format?("019cce93-ed2e-7e1b-9e62-af160709fd94")
    end

    test "returns false for non-UUID string" do
      refute Shared.uuid_format?("not-a-uuid")
      refute Shared.uuid_format?("hello")
      refute Shared.uuid_format?("")
    end

    test "returns false for nil" do
      refute Shared.uuid_format?(nil)
    end

    test "returns false for non-string types" do
      refute Shared.uuid_format?(123)
      refute Shared.uuid_format?(:atom)
    end
  end

  # ============================================================================
  # fetch_option/2
  # ============================================================================

  describe "fetch_option/2" do
    test "fetches atom key from map" do
      assert Shared.fetch_option(%{title: "Hello"}, :title) == "Hello"
    end

    test "fetches string key from map as fallback" do
      assert Shared.fetch_option(%{"title" => "Hello"}, :title) == "Hello"
    end

    test "fetches from keyword list" do
      assert Shared.fetch_option([title: "Hello"], :title) == "Hello"
    end

    test "returns nil for missing key in map" do
      assert Shared.fetch_option(%{other: "value"}, :title) == nil
    end

    test "returns nil for missing key in keyword list" do
      assert Shared.fetch_option([other: "value"], :title) == nil
    end

    test "returns nil for non-map non-list" do
      assert Shared.fetch_option("string", :title) == nil
      assert Shared.fetch_option(nil, :title) == nil
      assert Shared.fetch_option(123, :title) == nil
    end
  end

  # ============================================================================
  # parse_timestamp_path/1
  # ============================================================================

  describe "parse_timestamp_path/1" do
    test "parses date only" do
      assert {:ok, ~D[2025-12-09], nil, nil, nil} =
               Shared.parse_timestamp_path("2025-12-09")
    end

    test "parses date and time" do
      assert {:ok, ~D[2025-12-09], ~T[15:30:00], nil, nil} =
               Shared.parse_timestamp_path("2025-12-09/15:30")
    end

    test "parses date, time, and version" do
      assert {:ok, ~D[2025-12-09], ~T[15:30:00], 2, nil} =
               Shared.parse_timestamp_path("2025-12-09/15:30/v2")
    end

    test "parses date, time, and language" do
      assert {:ok, ~D[2025-12-09], ~T[15:30:00], nil, "en"} =
               Shared.parse_timestamp_path("2025-12-09/15:30/en")
    end

    test "parses date, time, version, and language" do
      assert {:ok, ~D[2025-12-09], ~T[15:30:00], 3, "fr"} =
               Shared.parse_timestamp_path("2025-12-09/15:30/v3/fr")
    end

    test "strips leading slash" do
      assert {:ok, ~D[2025-12-09], ~T[15:30:00], nil, nil} =
               Shared.parse_timestamp_path("/2025-12-09/15:30")
    end

    test "returns nil for non-date strings" do
      assert Shared.parse_timestamp_path("not-a-date") == nil
      assert Shared.parse_timestamp_path("hello/world") == nil
    end

    test "returns nil for invalid date" do
      assert Shared.parse_timestamp_path("2025-13-45") == nil
    end

    test "returns nil for invalid time" do
      assert Shared.parse_timestamp_path("2025-12-09/25:99") == nil
    end

    test "returns nil for empty string" do
      assert Shared.parse_timestamp_path("") == nil
    end
  end

  # ============================================================================
  # parse_time/1
  # ============================================================================

  describe "parse_time/1" do
    test "parses valid HH:MM time" do
      assert {:ok, ~T[15:30:00]} = Shared.parse_time("15:30")
      assert {:ok, ~T[00:00:00]} = Shared.parse_time("00:00")
      assert {:ok, ~T[23:59:00]} = Shared.parse_time("23:59")
    end

    test "returns error for invalid time" do
      assert match?({:error, _}, Shared.parse_time("25:00"))
      assert match?(:error, Shared.parse_time("abc"))
      assert match?(:error, Shared.parse_time(""))
    end

    test "returns error for non-string" do
      assert match?(:error, Shared.parse_time(nil))
      assert match?(:error, Shared.parse_time(123))
    end
  end

  # ============================================================================
  # extract_version_from_parts/1
  # ============================================================================

  describe "extract_version_from_parts/1" do
    test "extracts version from v-prefixed part" do
      assert {1, ["en"]} = Shared.extract_version_from_parts(["v1", "en"])
      assert {42, []} = Shared.extract_version_from_parts(["v42"])
    end

    test "returns nil version for non-version parts" do
      assert {nil, ["en"]} = Shared.extract_version_from_parts(["en"])
      assert {nil, ["slug"]} = Shared.extract_version_from_parts(["slug"])
    end

    test "handles empty list" do
      assert {nil, []} = Shared.extract_version_from_parts([])
    end
  end

  # ============================================================================
  # parse_version_segment/1
  # ============================================================================

  describe "parse_version_segment/1" do
    test "parses v-prefixed version numbers" do
      assert {:ok, 1} = Shared.parse_version_segment("v1")
      assert {:ok, 10} = Shared.parse_version_segment("v10")
      assert {:ok, 999} = Shared.parse_version_segment("v999")
    end

    test "returns error for non-version strings" do
      assert :error = Shared.parse_version_segment("en")
      assert :error = Shared.parse_version_segment("version1")
      assert :error = Shared.parse_version_segment("v")
      assert :error = Shared.parse_version_segment("")
    end

    test "returns error for non-string" do
      assert :error = Shared.parse_version_segment(nil)
      assert :error = Shared.parse_version_segment(123)
    end
  end

  # ============================================================================
  # should_regenerate_cache?/1
  # ============================================================================

  describe "should_regenerate_cache?/1" do
    test "returns true for timestamp mode" do
      assert Shared.should_regenerate_cache?(%{mode: :timestamp, metadata: %{status: "draft"}})
    end

    test "returns true for slug mode" do
      assert Shared.should_regenerate_cache?(%{
               mode: :slug,
               metadata: %{status: "draft"},
               version: 1
             })
    end

    test "returns true for published posts" do
      assert Shared.should_regenerate_cache?(%{
               mode: :slug,
               metadata: %{status: "published"},
               version: 1
             })
    end

    test "returns true when version is nil" do
      assert Shared.should_regenerate_cache?(%{mode: :slug, metadata: %{status: "draft"}})
    end

    test "returns false for unknown mode with non-published status" do
      refute Shared.should_regenerate_cache?(%{
               mode: :other,
               metadata: %{status: "archived"},
               version: 1
             })
    end

    test "handles missing metadata gracefully" do
      assert Shared.should_regenerate_cache?(%{mode: :timestamp})
    end

    test "handles empty map" do
      # No mode → nil version → true (always regenerate when unknown)
      assert Shared.should_regenerate_cache?(%{})
    end
  end

  # ============================================================================
  # audit_metadata/2
  # ============================================================================

  describe "audit_metadata/2" do
    test "returns empty map for nil scope" do
      assert Shared.audit_metadata(nil, :create) == %{}
      assert Shared.audit_metadata(nil, :update) == %{}
    end
  end

  # ============================================================================
  # resolve_db_version/2
  # ============================================================================

  describe "resolve_db_version/2" do
    test "function exists and is callable" do
      # Just verify the function is defined (actual DB calls tested in integration)
      assert function_exported?(Shared, :resolve_db_version, 2)
    end
  end
end
