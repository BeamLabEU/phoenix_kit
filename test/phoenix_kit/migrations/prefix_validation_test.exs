defmodule PhoenixKit.Migrations.PrefixValidationTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.Common
  alias PhoenixKit.Install.MigrationStrategy
  alias PhoenixKit.Install.PrefixConfig
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.Helpers

  @moduledoc """
  Pins the prefix-validation chokepoints added after the 2026-07 quorum
  review: an invalid prefix must raise at every entry point — never be
  swallowed into "not installed" or reach interpolated SQL. All of these
  raise BEFORE any repo/migration-context use, so no DB is needed.
  """

  @bad "Bad-Prefix; DROP TABLE x;--"

  test "Postgres.up/down reject an invalid prefix before touching the DB" do
    assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
      Postgres.up(prefix: @bad)
    end

    assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
      Postgres.down(prefix: @bad)
    end
  end

  test "migrated_version_runtime reraises the validation error instead of returning 0" do
    assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
      Postgres.migrated_version_runtime(prefix: @bad)
    end
  end

  test "Install.Common.check_installation_status rejects an invalid prefix" do
    assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
      Common.check_installation_status(@bad)
    end
  end

  test "ensure_extension! rejects extension names outside the allowlist" do
    # The name is interpolated into DDL; the guard runs before any repo use.
    assert_raise ArgumentError, ~r/unknown Postgres extension/, fn ->
      Helpers.ensure_extension!(:no_repo_needed, "bogus; DROP TABLE x;--")
    end
  end

  test "migration_opts always emits create_schema explicitly for non-public prefixes" do
    # Omitting the key would let the chain re-default it to true, silently
    # discarding --create-schema=false.
    assert MigrationStrategy.migration_opts("auth", true) ==
             ~s([prefix: "auth", create_schema: true])

    assert MigrationStrategy.migration_opts("auth", false) ==
             ~s([prefix: "auth", create_schema: false])

    assert MigrationStrategy.migration_opts("public", true) == "[]"
    assert MigrationStrategy.migration_opts("public", false) == "[]"
  end

  test "add_prefix_configuration rejects an invalid prefix instead of persisting it" do
    assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
      PrefixConfig.add_prefix_configuration(:igniter_unused, @bad)
    end
  end
end
