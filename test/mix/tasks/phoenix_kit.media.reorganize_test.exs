defmodule Mix.Tasks.PhoenixKit.Media.ReorganizeTest do
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Mix.Tasks.PhoenixKit.Media.Reorganize, as: ReorganizeTask
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Storage.Reorganizer

  defmodule StubSourceModule do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

    @impl true
    def plan(_actor, _opts) do
      [
        %{
          source: "stub_task_module",
          kind: :legacy_folder,
          label: "Stub legacy folder",
          op: :report,
          reason: "smoke test row"
        }
      ]
    end
  end

  defmodule StubHostModule do
    @moduledoc false
    def module_key, do: "stub_task_module"
    def module_name, do: "Stub Task Module"
    def enabled?, do: true
    def enable_system, do: :ok
    def disable_system, do: :ok
    def media_reorganizer, do: StubSourceModule
  end

  setup do
    ModuleRegistry.register(StubHostModule)
    on_exit(fn -> ModuleRegistry.unregister(StubHostModule) end)
    :ok
  end

  test "dry-run output contains the stub source's row" do
    output =
      capture_io(fn ->
        ReorganizeTask.run(["--source", "stub_task_module"])
      end)

    assert output =~ "stub_task_module legacy_folder"
    assert output =~ "Stub legacy folder"
    assert output =~ "dry run"
  end

  describe "exit_code/2" do
    test "is 0 on a dry-run regardless of outcomes" do
      assert ReorganizeTask.exit_code(%{actions: [%{outcome: :failed}]}, false) == 0
    end

    test "is 0 after --apply when nothing failed or conflicted" do
      assert ReorganizeTask.exit_code(
               %{actions: [%{outcome: :moved}, %{outcome: :trashed}]},
               true
             ) ==
               0
    end

    test "is 1 after --apply when an action outcome is :failed" do
      assert ReorganizeTask.exit_code(%{actions: [%{outcome: :moved}, %{outcome: :failed}]}, true) ==
               1
    end

    test "is 1 after --apply when an action outcome is :conflict" do
      assert ReorganizeTask.exit_code(%{actions: [%{outcome: :conflict}]}, true) == 1
    end
  end

  describe "invalid options" do
    test "an unknown switch is ignored with a warning instead of silently accepted" do
      output =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            ReorganizeTask.run(["--source", "stub_task_module", "--no-such-switch"])
          end)
        end)

      assert output =~ "dry run"
    end

    test "--pending-days must be a positive integer" do
      {exit_reason, output} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          catch_exit(ReorganizeTask.run(["--pending-days", "abc"]))
        end)

      assert exit_reason == {:shutdown, 1}
      assert output =~ "--pending-days"
    end

    test "--pending-days 0 is rejected" do
      {exit_reason, output} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          catch_exit(ReorganizeTask.run(["--pending-days", "0"]))
        end)

      assert exit_reason == {:shutdown, 1}
      assert output =~ "--pending-days"
    end

    test "an unresolved --source key is warned about instead of silently vanishing" do
      log =
        capture_log(fn ->
          capture_io(fn ->
            Reorganizer.sources(["no_such_module_key"])
          end)
        end)

      assert log =~ "no_such_module_key"
      assert log =~ "unresolved source key"
    end
  end
end
