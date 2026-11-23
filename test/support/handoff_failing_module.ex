defmodule PhoenixKit.Test.HandoffFailingModule do
  @moduledoc """
  A feature module whose handoff hooks fail, for the handoff tests: one failing module must not
  break the handoff of the others.
  """

  def module_key, do: "handoff_failing"
  def module_name, do: "Handoff failing"
  def enabled?, do: true

  def handoff_snapshot(_context), do: raise("snapshot boom: secret-session-value")
  def handoff_apply(_context, _payload), do: raise("apply boom: secret-session-value")
end
