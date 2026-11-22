defmodule Mix.Tasks.PhoenixKit.PostInstallTest do
  # File.cd!/1 and Mix.shell/1 are process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.PhoenixKit.Install, as: InstallTask
  alias Mix.Tasks.PhoenixKit.PostInstall
  alias PhoenixKit.Install.MigrationStrategy

  # Igniter runs `phoenix_kit.post_install` through Mix.shell().cmd/1: the
  # child inherits TERM but its stdin is a pipe nobody writes to, so a prompt
  # there hung the install. The question now lives in the installer, and the
  # task prompts only on a real terminal. ExUnit has no terminal either, so
  # these run in the same position as the queued child.

  describe "MigrationStrategy.interactive_terminal?/0" do
    test "is false with no terminal on stdin, whatever TERM says" do
      previous = System.get_env("TERM")
      System.put_env("TERM", "xterm")

      try do
        refute MigrationStrategy.interactive_terminal?()
      after
        if previous, do: System.put_env("TERM", previous), else: System.delete_env("TERM")
      end
    end
  end

  describe "post_install on a new install" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "pk_post_install_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "priv/repo/migrations"))

      File.write!(
        Path.join(dir, "priv/repo/migrations/20260101000000_add_phoenix_kit_tables.exs"),
        ""
      )

      previous_cwd = File.cwd!()
      previous_ci = System.get_env("CI")
      System.delete_env("CI")
      File.cd!(dir)

      # Mix.Shell.Process raises on prompt/1 with no queued input: a prompt
      # here is the hang, so it fails the test instead.
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        File.cd!(previous_cwd)
        if previous_ci, do: System.put_env("CI", previous_ci)
        File.rm_rf!(dir)
      end)
    end

    test "with no answer and no terminal, says why and does not ask" do
      output = capture_io(fn -> PostInstall.run(["--skip-assets"]) end)

      assert output =~ "Migration not run automatically (no interactive terminal)"
      assert output =~ "mix ecto.migrate"
    end

    test "--no-migrate skips the migration without asking" do
      output = capture_io(fn -> PostInstall.run(["--skip-assets", "--no-migrate"]) end)

      assert output =~ "Migration skipped"
    end
  end

  describe "the installer's decision" do
    test "an explicit --yes runs the migration" do
      assert InstallTask.decide_migrate_argv(igniter(["--yes"])) == ["--migrate"]
    end

    test "no terminal and no --yes: no question, post_install prints the note" do
      # Igniter sets options[:yes] by itself when stdin is not a TTY; that is
      # consent to the file changes, not to migrating.
      assert InstallTask.decide_migrate_argv(igniter([], yes: true)) == []
    end

    test "--dry-run decides nothing (queued tasks do not run)" do
      assert InstallTask.decide_migrate_argv(igniter(["--dry-run", "--yes"])) == []
      assert InstallTask.decide_migrate_argv(igniter([], dry_run: true)) == []
    end

    test "not a new install: post_install reports the state itself" do
      igniter = igniter(["--yes"]) |> Igniter.assign(:phoenix_kit_new_install?, false)
      assert InstallTask.decide_migrate_argv(igniter) == []
    end
  end

  defp igniter(argv, options \\ []) do
    Igniter.new()
    |> Map.put(:args, %Igniter.Mix.Task.Args{argv: argv, options: options})
    |> Igniter.assign(:phoenix_kit_new_install?, true)
  end
end
