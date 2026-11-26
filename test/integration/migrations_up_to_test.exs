defmodule PhoenixKit.Integration.MigrationsUpToTest do
  @moduledoc """
  `PhoenixKit.Migrations.up_to!/2`, the call the step migrations
  `mix phoenix_kit.update` writes. Each case stamps a scratch schema's
  `phoenix_kit` table comment with a version and runs a one-off migration
  through `Ecto.Migrator` (which runs outside the sandbox, so the sandbox is
  switched to `:auto` for the test, as `PrefixMigrationTest` does).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Test.Repo

  @moduletag :integration

  @schema "pk_up_to_test"

  defmodule UpToCurrent do
    use Ecto.Migration
    def up, do: PhoenixKit.Migrations.up_to!(Postgres.current_version(), prefix: "pk_up_to_test")
    def down, do: :ok
  end

  defmodule UpToAhead do
    use Ecto.Migration

    def up,
      do: PhoenixKit.Migrations.up_to!(Postgres.current_version() + 3, prefix: "pk_up_to_test")

    def down, do: :ok
  end

  defmodule UpToOlder do
    use Ecto.Migration

    def up,
      do: PhoenixKit.Migrations.up_to!(Postgres.minimum_version(), prefix: "pk_up_to_test")

    def down, do: :ok
  end

  defmodule OldStyleAhead do
    use Ecto.Migration

    def up,
      do:
        PhoenixKit.Migrations.up(
          prefix: "pk_up_to_test",
          version: Postgres.current_version() + 3
        )

    def down, do: :ok
  end

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      try do
        Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
    Repo.query!("CREATE SCHEMA #{@schema}")
    Repo.query!("CREATE TABLE #{@schema}.phoenix_kit (id integer)")
    :ok
  end

  defp stamp(version),
    do: Repo.query!("COMMENT ON TABLE #{@schema}.phoenix_kit IS '#{version}'")

  defp migrate(module) do
    Ecto.Migrator.run(Repo, [{System.unique_integer([:positive]), module}], :up,
      all: true,
      log: false,
      prefix: @schema
    )
  end

  test "a database already at the target is a no-op" do
    stamp(Postgres.current_version())
    assert [_] = migrate(UpToCurrent)
  end

  test "a database newer than the target is a no-op too (a replayed old step file)" do
    stamp(Postgres.current_version())

    assert [_] = migrate(UpToOlder)
  end

  test "below the floor it raises naming the bridge release — never success" do
    stamp(Postgres.initial_version() - 10)

    error =
      assert_raise PhoenixKit.Migrations.BelowFloorError, fn -> migrate(UpToCurrent) end

    assert Exception.message(error) =~ Postgres.bridge_version()
  end

  test "a target past this release's chain names the problem" do
    stamp(Postgres.current_version())

    error = assert_raise PhoenixKit.Migrations.TargetAheadError, fn -> migrate(UpToAhead) end
    assert Exception.message(error) =~ "chain ends at V#{Postgres.current_version()}"
  end

  test "up(version:) of an older step file gets the same diagnostic" do
    stamp(Postgres.current_version())
    assert_raise PhoenixKit.Migrations.TargetAheadError, fn -> migrate(OldStyleAhead) end
  end
end
