defmodule PhoenixKit.Integration.Migrations.InstalledVersionTest do
  @moduledoc """
  `PhoenixKit.Migration.installed_version/1` is the public, runtime read of the
  installed schema version (until it existed a script had `mix phoenix_kit.status`
  or raw SQL on the table comment). The test database is brought to the latest
  version by `test_helper.exs`, so the two public numbers must agree.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migration
  alias PhoenixKit.Migrations.Postgres

  test "reads the version of a fully migrated database: the release's current version" do
    assert Migration.installed_version() == Migration.current_version()
    assert Migration.installed_version(prefix: "public") == Migration.current_version()
  end

  test "a schema PhoenixKit is not installed in reads 0" do
    assert Migration.installed_version(prefix: "no_phoenix_kit_here") == 0
  end

  test "an invalid prefix raises instead of reading as not installed" do
    assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
      Migration.installed_version(prefix: "Bad-Prefix; DROP TABLE x;--")
    end
  end

  test "current_version/0 is the last version in the chain" do
    assert Migration.current_version() == Postgres.current_version()
    assert is_integer(Migration.current_version()) and Migration.current_version() > 0
  end
end
