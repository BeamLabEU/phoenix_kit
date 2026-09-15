defmodule Mix.Tasks.PhoenixKit.Media.ReorganizeTest do
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.PhoenixKit.Media.Reorganize, as: ReorganizeTask
  alias PhoenixKit.ModuleRegistry

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
end
