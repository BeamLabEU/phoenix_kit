defmodule PhoenixKit.Integration.Migrations.InstalledVersionTest do
  @moduledoc """
  `PhoenixKit.Migration.installed_version/1` is the public, runtime read of the
  installed schema version (until it existed a script had `mix phoenix_kit.status`
  or raw SQL on the table comment).

  The test database is brought to the latest version by `test_helper.exs`, but
  it is long-lived and may be shared with checkouts whose chain is longer: their
  suite migrates it further and stamps a higher version, which this checkout's
  `ensure_current/2` leaves alone. So the exact read is checked against a
  version stamped inside the sandbox, and the database as found only for being
  at least this release's.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migration
  alias PhoenixKit.Migrations.Postgres

  test "reads the version a fully migrated database records: the release's current version" do
    current = Migration.current_version()

    # Rolled back with the sandbox; other connections never see it.
    Repo.query!("COMMENT ON TABLE public.phoenix_kit IS '#{current}'")
    assert Migration.installed_version() == current
    assert Migration.installed_version(prefix: "public") == current

    Repo.query!("COMMENT ON TABLE public.phoenix_kit IS '#{current + 1}'")
    assert Migration.installed_version() == current + 1
  end

  test "the test database is at least at the release's version" do
    assert Migration.installed_version() >= Migration.current_version()
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
