defmodule PhoenixKit.Integration.ObanSchemaUpgradeTest do
  @moduledoc """
  The behaviour `PhoenixKit.ObanSchema` exists for, on a real database.

  A scratch schema is migrated to Oban's schema version 13 — what a host keeps
  when it moves to an Oban whose library expects 14 without migrating. A
  unique insert through an Oban instance on that schema fails exactly as on
  such a host; the migration the updater generates is then applied the way
  `mix ecto.migrate` applies it (`Ecto.Migrator`, inside its DDL transaction),
  and the same insert goes through.

  ## Why sandbox `:auto` mode

  Same reason as `PhoenixKit.Integration.PrefixMigrationTest`: the migrator
  runs in its own process with its own connections, so a sandbox checkout
  cannot cover it — and inside a sandbox transaction Postgres refuses to use
  an enum value added by `ALTER TYPE ... ADD VALUE` in that same transaction,
  which is exactly the value this test needs. `async: false`, so the flip runs
  after every async test has finished.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.ObanSchema
  alias PhoenixKit.Test.Repo

  @moduletag :integration
  @moduletag :tmp_dir

  # Scratch schemas: one left at Oban v13, one at the library's version, one
  # with no Oban tables at all. Plain names, so the generated file is too.
  @behind "pk_oban_v13_probe"
  @current "pk_oban_cur_probe"
  @empty "pk_oban_none_probe"

  @migrated_at 13

  defmodule ObanToV13 do
    @moduledoc false
    use Ecto.Migration

    def change do
      Oban.Migration.up(prefix: prefix(), version: 13, create_schema: false)
    end
  end

  defmodule ObanToCurrent do
    @moduledoc false
    use Ecto.Migration

    def change, do: Oban.Migration.up(prefix: prefix(), create_schema: false)
  end

  defmodule UniqueWorker do
    @moduledoc false
    use Oban.Worker, queue: :default, unique: [period: 60]

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule PlainWorker do
    @moduledoc false
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      try do
        for schema <- [@behind, @current, @empty] do
          Repo.query!("DROP SCHEMA IF EXISTS #{schema} CASCADE")
        end
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    for schema <- [@behind, @current, @empty] do
      Repo.query!("DROP SCHEMA IF EXISTS #{schema} CASCADE")
      Repo.query!("CREATE SCHEMA #{schema}")
    end

    # A host's v13 schema was built by an Oban older than 2.24, whose V01
    # created the enum without 'suspended' (V09 adds 'cancelled'). Oban 2.24's
    # own V01 creates it WITH 'suspended', so migrating a fresh schema "to 13"
    # with today's library would not reproduce anything. V01 skips creating
    # the type when one exists, so give it the old shape first.
    Repo.query!("""
    CREATE TYPE #{@behind}.oban_job_state AS ENUM
      ('available', 'scheduled', 'executing', 'retryable', 'completed', 'discarded')
    """)

    run_change(ObanToV13, @behind)
    run_change(ObanToCurrent, @current)

    expected = Oban.Migration.current_version(repo: Repo)

    # The scenario only exists while the library is past 13; on an Oban where
    # it is not, this suite has nothing to reproduce and says so loudly.
    assert expected > @migrated_at,
           "Oban #{Application.spec(:oban, :vsn)} expects schema v#{expected}; " <>
             "this test needs a library past v#{@migrated_at}"

    %{expected: expected}
  end

  describe "detection — per prefix, read from the comment on oban_jobs" do
    test "each prefix reports its own version", %{expected: expected} do
      assert ObanSchema.check(Repo, @behind) == {:behind, @migrated_at, expected}
      assert ObanSchema.check(Repo, @current) == {:current, expected}
      assert ObanSchema.check(Repo, @empty) == :no_table
      assert ObanSchema.check(Repo, "pk_oban_no_such_schema") == :no_table
    end

    test "the version is the table comment, nothing else", %{expected: expected} do
      Repo.query!("COMMENT ON TABLE #{@current}.oban_jobs IS NULL")
      assert ObanSchema.check(Repo, @current) == {:unversioned, nil}

      Repo.query!("COMMENT ON TABLE #{@current}.oban_jobs IS '#{expected + 1}'")
      assert ObanSchema.check(Repo, @current) == {:ahead, expected + 1, expected}

      Repo.query!("COMMENT ON TABLE #{@current}.oban_jobs IS '#{@migrated_at}'")
      assert ObanSchema.check(Repo, @current) == {:behind, @migrated_at, expected}
    end
  end

  describe "a schema behind the library" do
    test "fails every unique insert, and rolls back a cron-style batch with it" do
      oban = start_oban(@behind)

      # The plain insert works — the schema is not broken, only behind.
      assert {:ok, %Oban.Job{}} = Oban.insert(oban, PlainWorker.new(%{}))

      error =
        assert_raise Postgrex.Error, fn -> Oban.insert(oban, UniqueWorker.new(%{})) end

      assert Exception.message(error) =~
               ~s(invalid input value for enum #{@behind}.oban_job_state: "suspended")

      # Only uniqueness that looks in `suspended` fails: Oban's default states,
      # the `:incomplete` group and `Oban.Job.states()` all include it; an
      # explicit list without it does not.
      assert {:ok, %Oban.Job{}} =
               Oban.insert(oban, PlainWorker.new(%{}, unique: [states: [:available, :scheduled]]))

      for states <- [:incomplete, Oban.Job.states() -- [:completed, :cancelled, :discarded]] do
        assert_raise Postgrex.Error, fn ->
          Oban.insert(oban, PlainWorker.new(%{states: inspect(states)}, unique: [states: states]))
        end
      end

      # Oban.Cron inserts one minute's jobs in a single transaction with
      # `Oban.insert!`: the unique one takes every other job down with it.
      before = count_jobs(@behind)

      # The connection logs "disconnected: transaction rolling back" — the
      # line a host sees every five minutes.
      {batch, _log} =
        with_log(fn ->
          try do
            Repo.transaction(fn ->
              Oban.insert!(oban, PlainWorker.new(%{batch: true}))
              Oban.insert!(oban, UniqueWorker.new(%{batch: true}))
            end)
          rescue
            exception -> {:raised, exception}
          end
        end)

      assert {:raised, _} = batch
      assert count_jobs(@behind) == before
    end

    test "is named at boot by the running instance's own repo and prefix" do
      oban = start_oban(@behind)
      log = capture_log(fn -> assert ObanSchema.warn_if_behind(oban: oban) == :ok end)

      assert log =~ "Oban schema v13, Oban expects v"
      assert log =~ ~s(prefix "#{@behind}")
      assert log =~ "mix phoenix_kit.update"

      on_current = start_oban(@current)
      assert capture_log(fn -> ObanSchema.warn_if_behind(oban: on_current) end) == ""
    end
  end

  describe "the generated migration, as mix phoenix_kit.update writes it" do
    test "core current and Oban behind: written once, applied, and unique inserts work",
         %{tmp_dir: dir, expected: expected} do
      # The host case: PhoenixKit's own chain has nothing to do, so no core
      # update migration is generated — the Oban step must not depend on one.
      assert Postgres.migrated_version_runtime(%{prefix: "public", escaped_prefix: "public"}) ==
               Postgres.current_version()

      prefixes = [@current, @behind, @empty]
      timestamp = fn index -> "2026100412000#{index}" end

      staged = ObanSchema.stage(Repo, prefixes, dir, "PhoenixKitTest", timestamp)

      assert [
               %{prefix: @current, status: {:current, ^expected}, file: nil},
               %{prefix: @behind, status: {:behind, 13, ^expected}, file: {:created, path}},
               %{prefix: @empty, status: :no_table, file: nil}
             ] = staged

      assert Path.basename(path) ==
               "20261004120001_phoenix_kit_update_oban_#{@behind}_v13_to_v#{expected}.exs"

      source = File.read!(path)

      assert source =~
               ~s|Oban.Migration.up(version: #{expected}, prefix: "#{@behind}", create_schema: false)|

      assert source =~ ~s|Oban.Migration.down(version: #{@migrated_at + 1}, prefix: "#{@behind}")|

      # A second run before the migration is applied finds the same file.
      assert [_, %{file: {:exists, ^path}}, _] =
               ObanSchema.stage(Repo, prefixes, dir, "PhoenixKitTest", timestamp)

      assert File.ls!(dir) == [Path.basename(path)]

      [{migration, _}] = Code.compile_file(path)
      version = path |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()

      # Ecto.Migrator wraps the migration in its DDL transaction, exactly as
      # `mix ecto.migrate` does; `prefix:` keeps its bookkeeping table inside
      # the scratch schema.
      assert :ok = Ecto.Migrator.up(Repo, version, migration, prefix: @behind, log: false)
      assert ObanSchema.check(Repo, @behind) == {:current, expected}

      oban = start_oban(@behind)
      assert {:ok, %Oban.Job{id: id}} = Oban.insert(oban, UniqueWorker.new(%{}))
      assert {:ok, %Oban.Job{id: ^id, conflict?: true}} = Oban.insert(oban, UniqueWorker.new(%{}))

      # Applied: nothing more to write, and the file is left as it was.
      assert [_, %{status: {:current, ^expected}, file: nil}, _] =
               ObanSchema.stage(Repo, prefixes, dir, "PhoenixKitTest", timestamp)

      assert File.ls!(dir) == [Path.basename(path)]

      # And down returns the schema to where it was.
      assert :ok = Ecto.Migrator.down(Repo, version, migration, prefix: @behind, log: false)
      assert ObanSchema.check(Repo, @behind) == {:behind, 13, expected}
    end

    test "nothing is written when every prefix matches or has no Oban tables",
         %{tmp_dir: dir} do
      staged =
        ObanSchema.stage(Repo, [@current, @empty], dir, "PhoenixKitTest", fn _ -> "1" end)

      assert Enum.all?(staged, &is_nil(&1.file))
      assert File.ls!(dir) == []
    end
  end

  defp run_change(module, prefix) do
    Runner.run(Repo, Repo.config(), 0, module, :forward, :change, :up, prefix: prefix, log: false)
  end

  # Inserts run in the calling process: no queues, plugins, stager or peer —
  # nothing else touches the database — and `testing: :disabled`, so Oban does
  # not refuse to start on an outdated schema the way a test mode would.
  defp start_oban(prefix) do
    name = Module.concat(__MODULE__, "Oban#{System.unique_integer([:positive])}")

    start_supervised!(
      {Oban,
       name: name,
       repo: Repo,
       prefix: prefix,
       testing: :disabled,
       queues: false,
       plugins: false,
       peer: false,
       stager: false,
       notifier: Oban.Notifiers.Isolated},
      id: name
    )

    name
  end

  defp count_jobs(prefix) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{prefix}.oban_jobs")
    count
  end
end
