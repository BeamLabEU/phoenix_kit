defmodule Mix.Tasks.PhoenixKit.UpdateNoTerminalTest do
  @moduledoc """
  The migration question with nobody to answer it (issue #1066).

  `mix phoenix_kit.update < /dev/null` crashed with a `FunctionClauseError`:
  `Mix.shell().prompt/1` returns `:eof` there, and the answer went straight
  into `String.trim/1`. The crash also skipped the "not migrated" error, so no
  module migration file was written and nothing named `--yes`.
  """
  # Mix.shell/1, the working directory and the environment are process-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.PhoenixKit.Update
  alias PhoenixKit.Install.MigrationStrategy

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "MigrationStrategy.confirm/1" do
    test "y, yes and a bare Enter are a yes" do
      for answer <- ["y\n", "YES\n", " Yes \n", "\n", ""] do
        send(self(), {:mix_shell_input, :prompt, answer})
        assert MigrationStrategy.confirm("Run migration? [Y/n]") == :yes
      end
    end

    test "anything else typed is a no" do
      for answer <- ["n\n", "no\n", "later\n"] do
        send(self(), {:mix_shell_input, :prompt, answer})
        assert MigrationStrategy.confirm("Run migration? [Y/n]") == :no
      end
    end

    test "a closed or failing standard input is no input, never a yes" do
      for answer <- [:eof, {:error, :terminated}] do
        send(self(), {:mix_shell_input, :prompt, answer})
        assert MigrationStrategy.confirm("Run migration? [Y/n]") == :no_input
      end
    end

    test "a shell that cannot ask is no input" do
      # Mix.Shell.Process raises on prompt/1 with nothing queued.
      assert MigrationStrategy.confirm("Run migration? [Y/n]") == :no_input
    end
  end

  describe "the update's migrate step with no terminal on standard input" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pk_update_no_tty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "priv/repo/migrations"))

      previous_cwd = File.cwd!()
      previous = Map.new(["CI", "TERM"], &{&1, System.get_env(&1)})
      System.delete_env("CI")
      # TERM is what the task used to trust; ExUnit's stdin is no terminal.
      System.put_env("TERM", "xterm")
      File.cd!(dir)

      on_exit(fn ->
        File.cd!(previous_cwd)

        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)

        File.rm_rf!(dir)
      end)
    end

    test "fails as a pending migration that names --yes, without asking" do
      steps = %{
        stage_oban: fn _prefix -> [] end,
        verify_oban: fn _staged -> :ok end,
        modules: fn _opts -> send(self(), :modules_ran) end
      }

      error =
        assert_raise Mix.Error, fn -> Update.run_schema_steps([prefix: "public"], steps) end

      assert error.message =~ "no interactive terminal"
      assert error.message =~ "mix phoenix_kit.update --yes"
      assert error.message =~ "mix ecto.migrate"

      refute_received {:mix_shell, :prompt, _}
      refute_received :modules_ran
    end
  end
end
