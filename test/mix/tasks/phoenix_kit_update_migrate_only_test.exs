defmodule Mix.Tasks.PhoenixKit.Update.MigrateOnlyTest do
  @moduledoc """
  `mix phoenix_kit.update --migrate-only`: every database step with only the
  repo started. The steps are injected, so these tests observe the order and
  that the application itself is never started.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.PhoenixKit.Update
  alias PhoenixKit.Migrations.Postgres, as: MigrationsPostgres

  defp steps(test_pid, status) do
    %{
      app_config: fn -> send(test_pid, {:step, :app_config}) end,
      with_repo: fn fun ->
        send(test_pid, {:step, :repo_started})
        result = fun.()
        send(test_pid, {:step, :repo_stopped})
        result
      end,
      installation_status: fn prefix ->
        send(test_pid, {:step, {:status, prefix}})
        status
      end,
      core_migration: fn status, _prefix -> send(test_pid, {:step, {:core, status}}) end,
      stage_oban: fn _prefix ->
        send(test_pid, {:step, :stage_oban})
        []
      end,
      migrate: fn -> send(test_pid, {:step, :migrate}) end,
      verify_oban: fn _ -> send(test_pid, {:step, :verify_oban}) end,
      modules: fn _ -> send(test_pid, {:step, :modules}) end
    }
  end

  defp steps_run(acc \\ []) do
    receive do
      {:step, name} -> steps_run([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "runs core, Oban and module migrations inside the repo, never app.start" do
    floor = MigrationsPostgres.minimum_version()
    status = {:current_version, floor}

    capture_io(fn ->
      Update.run_migrate_only_update([prefix: "public"], steps(self(), status))
    end)

    assert steps_run() == [
             :app_config,
             :repo_started,
             {:status, "public"},
             {:core, status},
             :stage_oban,
             :migrate,
             :verify_oban,
             :modules,
             :repo_stopped
           ]
  end

  test "below the floor it refuses before writing anything" do
    floor = MigrationsPostgres.minimum_version()

    assert_raise Mix.Error, ~r/below this release's floor/, fn ->
      capture_io(fn ->
        Update.run_migrate_only_update(
          [prefix: "public"],
          steps(self(), {:current_version, floor - 1})
        )
      end)
    end

    assert steps_run() == [:app_config, :repo_started, {:status, "public"}]
  end

  describe "the core step-up file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pk_migrate_only_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "is written from the database's version and calls up_to!", %{dir: dir} do
      target = MigrationsPostgres.current_version()

      capture_io(fn ->
        File.cd!(dir, fn ->
          Update.write_core_migration_file({:current_version, 230}, "public")
        end)
      end)

      [file] = File.ls!(Path.join(dir, "priv/repo/migrations"))
      assert file =~ "_phoenix_kit_update_v230_to_v#{target}.exs"

      content = File.read!(Path.join([dir, "priv/repo/migrations", file]))
      assert content =~ "PhoenixKit.Migrations.up_to!(#{target}"
      assert {:ok, _} = Code.string_to_quoted(content)

      # a second run reuses it
      capture_io(fn ->
        File.cd!(dir, fn ->
          Update.write_core_migration_file({:current_version, 230}, "public")
        end)
      end)

      assert length(File.ls!(Path.join(dir, "priv/repo/migrations"))) == 1
    end

    test "nothing to write when current", %{dir: dir} do
      current = MigrationsPostgres.current_version()

      out =
        capture_io(fn ->
          File.cd!(dir, fn ->
            Update.write_core_migration_file({:current_version, current}, "public")
          end)
        end)

      assert out =~ "already up to date"
      refute File.exists?(Path.join(dir, "priv/repo/migrations"))
    end

    test "not installed is refused" do
      assert_raise Mix.Error, ~r/No PhoenixKit installation/, fn ->
        Update.write_core_migration_file({:not_installed}, "public")
      end
    end
  end

  describe "the switch" do
    test "both option parsers declare it" do
      %Igniter.Mix.Task.Info{schema: schema} = Update.info([], nil)
      assert schema[:migrate_only] == :boolean

      [_, switches] =
        Regex.run(
          ~r/OptionParser\.parse\(argv,\s*switches:\s*\[(.*?)\]\s*,\s*aliases/s,
          File.read!("lib/mix/tasks/phoenix_kit.update.ex")
        )

      assert switches =~ "migrate_only: :boolean"
    end

    test "--help documents it" do
      assert capture_io(fn -> Update.run(["--help"]) end) =~ "--migrate-only"
    end

    test "--dry-run --migrate-only only describes" do
      out = capture_io(fn -> Update.run(["--migrate-only", "--dry-run"]) end)
      assert out =~ "nothing was written or migrated"
    end
  end

  test "the generated step-up (full update path) calls the floor-aware entry" do
    {name, content} = Update.update_migration("public", 230, 237, false)
    assert name =~ "_phoenix_kit_update_v230_to_v237.exs"
    assert content =~ "PhoenixKit.Migrations.up_to!(237"
    refute content =~ "Migrations.up("
    assert content =~ "@disable_ddl_transaction true"
    assert {:ok, _} = Code.string_to_quoted(content)
  end
end
