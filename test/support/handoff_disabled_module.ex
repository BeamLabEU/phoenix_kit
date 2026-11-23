defmodule PhoenixKit.Test.HandoffDisabledModule do
  @moduledoc """
  A registered feature module that is switched off (`enabled?/0` is `false`), for the handoff
  tests: neither hook may ever run for it. A call would report itself to the test process.
  """

  def module_key, do: "handoff_disabled"
  def module_name, do: "Handoff disabled"
  def enabled?, do: false

  def handoff_snapshot(_context) do
    send(caller(), :disabled_snapshot_called)
    %{secret: "disabled"}
  end

  def handoff_apply(_context, _payload) do
    send(caller(), :disabled_apply_called)
    {:ok, ["from a disabled module"]}
  end

  defp caller, do: List.first(Process.get(:"$callers", [])) || self()
end
