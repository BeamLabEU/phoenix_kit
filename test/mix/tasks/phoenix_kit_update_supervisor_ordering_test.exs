defmodule Mix.Tasks.PhoenixKit.Update.SupervisorOrderingTest do
  @moduledoc """
  P013: `fix_supervisor_ordering/1` used to decide whether `application.ex`
  needed reordering by reading the file straight off REAL disk
  (`content = File.read!(app_file)`), then making its correct/needs-fix
  decision from that snapshot. Igniter never flushes a step's writes to
  disk before the next step runs — on a real `mix phoenix_kit.update` run,
  TWO earlier steps in the SAME pipeline stage edits to this exact file
  before `fix_supervisor_ordering/1` runs: `ApplicationSupervisor.add_supervisor/1`
  (unconditionally, at the very top of `igniter/1`) and, when missing,
  `ObanConfig.add_oban_supervisor/1` (inside `perform_igniter_update/2`,
  immediately before `fix_supervisor_ordering/1` itself). Both write via
  `Igniter.Project.Application.add_new_child/3`, which only ever touches
  the Igniter buffer.

  Same defect class as I103 (`PhoenixKit.Install.BootHook.add_boot_hook/1`,
  `Mix.Tasks.PhoenixKit.Update.fix_ueberauth_providers_config/1`) — except
  here the consequence isn't a discarded edit, it's a SKIPPED fix: the
  disk-based check saw no `PhoenixKit.Supervisor` line at all (it wasn't on
  disk yet), matched the `(repo, nil, nil, _) -> :correct` clause in
  `validate_supervisor_positions/4`, and returned the igniter untouched —
  leaving whatever position the earlier step landed the supervisor in,
  correct or not, uncorrected.

  Reproduced/verified with a REAL (non-test-mode) `Igniter.new/0` rooted at
  a throwaway temp directory — `Igniter.Test.test_project/1` cannot be
  used here because it never touches real disk (see
  `PhoenixKit.Install.BootHookTest`'s moduledoc), so `File.exists?/1` /
  `File.read!/1` would simply see nothing and the whole function would
  short-circuit before reaching the code under test.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.PhoenixKit.Update

  @app_file "lib/probe_app/application.ex"

  @mix_exs """
  defmodule ProbeApp.MixProject do
    use Mix.Project

    def project do
      [app: :probe_app, version: "0.1.0"]
    end
  end
  """

  @initial_content """
  defmodule ProbeApp.Application do
    use Application

    @impl true
    def start(_type, _args) do
      children = [
        ProbeApp.Repo,
        ProbeAppWeb.Endpoint
      ]

      opts = [strategy: :one_for_one, name: ProbeApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  """

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "pk_p013_probe_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, "lib/probe_app"))
    File.write!(Path.join(tmp_dir, "mix.exs"), @mix_exs)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  # Stands in for `ApplicationSupervisor.add_supervisor/1` landing
  # `PhoenixKit.Supervisor` in the WRONG spot — the shape it takes when
  # `Igniter.Libs.Ecto.list_repos/1` finds no repo to anchor `after:` on,
  # so only `before: [endpoint]` applies and the child lands at the very
  # top of the list, ahead of the Repo.
  defp stage_misordered_phoenix_kit_supervisor(igniter) do
    Igniter.update_file(igniter, @app_file, fn source ->
      content = Rewrite.Source.get(source, :content)

      updated =
        String.replace(content, "children = [", "children = [\n        PhoenixKit.Supervisor,")

      Rewrite.Source.update(source, :content, updated)
    end)
  end

  defp final_content(igniter) do
    assert Rewrite.has_source?(igniter.rewrite, @app_file),
           "#{@app_file} was never loaded into the Igniter buffer — " <>
             "fix_supervisor_ordering/1 decided from a bare File.read!/1 " <>
             "instead of the Igniter-tracked source"

    igniter.rewrite |> Rewrite.source!(@app_file) |> Rewrite.Source.get(:content)
  end

  defp index_of!(content, needle) do
    {index, _} = :binary.match(content, needle)
    index
  end

  test "detects and corrects a misordering staged by an earlier step in the same run",
       %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, @app_file), @initial_content)

    File.cd!(tmp_dir, fn ->
      igniter =
        Igniter.new()
        |> stage_misordered_phoenix_kit_supervisor()
        |> Update.fix_supervisor_ordering()

      content = final_content(igniter)

      repo_index = index_of!(content, "ProbeApp.Repo")
      pk_index = index_of!(content, "PhoenixKit.Supervisor")
      endpoint_index = index_of!(content, "ProbeAppWeb.Endpoint")

      assert repo_index < pk_index and pk_index < endpoint_index, """
      expected Repo -> PhoenixKit.Supervisor -> Endpoint, got:
      #{content}
      """
    end)
  end

  test "still fixes a misordering that is already on disk (no earlier staged step)",
       %{tmp_dir: tmp_dir} do
    already_broken =
      String.replace(
        @initial_content,
        "children = [",
        "children = [\n        PhoenixKit.Supervisor,"
      )

    File.write!(Path.join(tmp_dir, @app_file), already_broken)

    File.cd!(tmp_dir, fn ->
      igniter = Igniter.new() |> Update.fix_supervisor_ordering()
      content = final_content(igniter)

      repo_index = index_of!(content, "ProbeApp.Repo")
      pk_index = index_of!(content, "PhoenixKit.Supervisor")
      endpoint_index = index_of!(content, "ProbeAppWeb.Endpoint")

      assert repo_index < pk_index and pk_index < endpoint_index, """
      expected Repo -> PhoenixKit.Supervisor -> Endpoint, got:
      #{content}
      """
    end)
  end

  test "is idempotent and leaves a foreign/unrelated child untouched when order is already correct",
       %{tmp_dir: tmp_dir} do
    already_correct = """
    defmodule ProbeApp.Application do
      use Application

      @impl true
      def start(_type, _args) do
        children = [
          ProbeApp.Repo,
          SomeOtherLib.Supervisor,
          PhoenixKit.Supervisor,
          ProbeAppWeb.Endpoint,
          {Oban, Application.get_env(:probe_app, Oban)}
        ]

        opts = [strategy: :one_for_one, name: ProbeApp.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """

    File.write!(Path.join(tmp_dir, @app_file), already_correct)

    File.cd!(tmp_dir, fn ->
      igniter = Igniter.new() |> Update.fix_supervisor_ordering()
      content = final_content(igniter)

      assert content == already_correct,
             "an already-correct order with a foreign child must be left untouched:\n#{content}"
    end)
  end

  describe "a children list the line-based rewrite does not understand" do
    # NordAPI builds its list with `++`; the old rewrite crashed on it
    # (ArithmeticError) or, with the lines to move in different parts, could
    # duplicate a child. Such a file is now left exactly as it is.
    @concatenated """
    defmodule ProbeApp.Application do
      use Application

      @impl true
      def start(_type, _args) do
        children = [
          PhoenixKit.Supervisor,
          ProbeApp.Repo,
        ] ++ [ProbeAppWeb.Endpoint] ++ [{Oban, Application.get_env(:probe_app, Oban)}]

        Supervisor.start_link(children, strategy: :one_for_one)
      end
    end
    """

    @opened_on_next_line """
    defmodule ProbeApp.Application do
      use Application

      @impl true
      def start(_type, _args) do
        children =
          [
            PhoenixKit.Supervisor,
            ProbeApp.Repo,
            ProbeAppWeb.Endpoint
          ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end
    end
    """

    test "reorder_supervisors/2 answers :unsafe instead of rewriting" do
      assert Update.reorder_supervisors(@concatenated, :probe_app) == :unsafe
      assert Update.reorder_supervisors(@opened_on_next_line, :probe_app) == :unsafe
    end

    test "fix_supervisor_ordering/1 leaves the file untouched and says what to move",
         %{tmp_dir: tmp_dir} do
      for content <- [@concatenated, @opened_on_next_line] do
        File.write!(Path.join(tmp_dir, @app_file), content)

        File.cd!(tmp_dir, fn ->
          igniter = Igniter.new() |> Update.fix_supervisor_ordering()

          assert final_content(igniter) == content
          assert Enum.any?(igniter.warnings, &(&1 =~ "NOT changed"))
          refute Enum.any?(igniter.notices, &(&1 =~ "CRITICAL FIX APPLIED"))
        end)
      end
    end

    test "a plain list is still reordered" do
      plain = """
      defmodule ProbeApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            PhoenixKit.Supervisor,
            ProbeApp.Repo,
            ProbeAppWeb.Endpoint
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end
      """

      assert {:ok, fixed} = Update.reorder_supervisors(plain, :probe_app)
      assert index_of!(fixed, "ProbeApp.Repo") < index_of!(fixed, "PhoenixKit.Supervisor")
      assert index_of!(fixed, "PhoenixKit.Supervisor") < index_of!(fixed, "ProbeAppWeb.Endpoint")
    end
  end
end
