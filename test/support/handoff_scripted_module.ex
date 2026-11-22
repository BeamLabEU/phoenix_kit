defmodule PhoenixKit.Test.HandoffScriptedModule do
  @moduledoc """
  A feature module whose answers a handoff test scripts, for what a module may do wrong. The
  hooks run in a task of their own, so the script travels through the application environment
  (`:handoff_scripted`, a map with `:snapshot` and `:apply`).

  `:apply` is the answer of `handoff_apply/2`, or `{:raise, message}`, `{:sleep, ms}`. The
  snapshot is `%{"x" => 1}` unless scripted.
  """

  def module_key, do: "handoff_scripted"
  def module_name, do: "Handoff scripted"
  def enabled?, do: true

  def script(map), do: Application.put_env(:phoenix_kit, :handoff_scripted, map)
  def clear, do: Application.delete_env(:phoenix_kit, :handoff_scripted)

  def handoff_snapshot(_context), do: run(:snapshot, %{x: 1})
  def handoff_apply(_context, _payload), do: run(:apply, {:ok, []})

  defp run(hook, default) do
    case Application.get_env(:phoenix_kit, :handoff_scripted, %{}) |> Map.get(hook, default) do
      {:raise, message} -> raise message
      {:sleep, ms} -> Process.sleep(ms) && default
      answer -> answer
    end
  end
end
