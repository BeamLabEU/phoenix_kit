defmodule Mix.Tasks.PhoenixKit.Gen.MigrationTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Gen.Migration

  # Regression (2026-07 quorum review): with no prior PhoenixKit migration
  # in the project (from_version == 0), the generated migration IS the
  # fresh install — a non-public schema may genuinely need creating, so
  # create_schema must not be hardcoded to false.
  test "fresh prefixed install (from_version 0) keeps schema creation" do
    content =
      Migration.migration_content("MyApp", "phoenix_kit_update_v0_to_v142", 0, 142, "auth")

    assert content =~ ~s(prefix: "auth")
    assert content =~ "create_schema: true"
  end

  test "prefixed upgrade never asks the chain to create the schema" do
    content =
      Migration.migration_content("MyApp", "phoenix_kit_update_v140_to_v142", 140, 142, "auth")

    assert content =~ ~s(prefix: "auth")
    assert content =~ "create_schema: false"
  end

  test "public installs never request schema creation" do
    for from <- [0, 140] do
      content =
        Migration.migration_content(
          "MyApp",
          "phoenix_kit_update_v#{from}_to_v142",
          from,
          142,
          "public"
        )

      assert content =~ "create_schema: false"
    end
  end

  # Regression: the installer emits `add_phoenix_kit_tables` (verified against
  # `PhoenixKit.Install.MigrationStrategy.create_initial_migration_silent/3`
  # and `PhoenixKit.Install.Common.phoenix_kit_migration?/1`'s own doctest),
  # but the scan used to look only for `create_phoenix_kit_tables` — a
  # pattern that never appears anywhere the installer writes. A project with
  # only the real installer's file therefore silently scanned as "no prior
  # PhoenixKit migration" (from_version 0) instead of "already installed"
  # (from_version 1), which both risks a stray `create_schema: true` on a
  # prefixed re-generation and rolls a `down` all the way to version 0
  # instead of stopping at the initial install's version 1.
  describe "extract_phoenix_kit_version/1 (scan bug fix)" do
    test "matches the real installer filename: add_phoenix_kit_tables" do
      assert Migration.extract_phoenix_kit_version("20250908_add_phoenix_kit_tables.exs") == [1]
    end

    test "still matches the legacy name: create_phoenix_kit_tables" do
      assert Migration.extract_phoenix_kit_version("20260316_create_phoenix_kit_tables.exs") ==
               [1]
    end

    test "matches phoenix_kit_update_vXX_to_vYY regardless of the install-marker patterns" do
      assert Migration.extract_phoenix_kit_version("20260310_phoenix_kit_update_v78_to_v80.exs") ==
               [80]
    end

    test "the update-range pattern takes precedence when a filename could match both" do
      # Contrived, but pins the `cond` ordering: an update-style filename is
      # never miscategorized as a fresh-install marker just because it also
      # contains the substring "add_phoenix_kit_tables".
      filename = "20260310_phoenix_kit_update_v78_to_v80_add_phoenix_kit_tables.exs"
      assert Migration.extract_phoenix_kit_version(filename) == [80]
    end

    test "ignores unrelated filenames" do
      assert Migration.extract_phoenix_kit_version("20250908_create_users.exs") == []
    end

    test "detect_current_version-equivalent max/0 fallback still yields 0 for an unrelated file" do
      # `detect_current_version/0` itself touches the filesystem
      # (`priv/repo/migrations`, cwd-relative) and is not unit-tested here;
      # this pins the piece it delegates to for the actual regex/substring
      # matching, which is what the scan bug lived in.
      versions =
        ["20250908_create_users.exs", "20250908_add_phoenix_kit_tables.exs"]
        |> Enum.flat_map(&Migration.extract_phoenix_kit_version/1)

      assert Enum.max(versions, fn -> 0 end) == 1
    end
  end
end
