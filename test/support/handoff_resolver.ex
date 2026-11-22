defmodule PhoenixKit.Test.HandoffResolver do
  @moduledoc """
  A `:canonical_host_resolver` for the handoff tests: one host per language, on different TLDs.
  A dialect (`"en-US"`) has no domain of its own, as the resolver's contract allows.
  """

  def host("en"), do: "shop.test"
  def host("de"), do: "shop-de.test"
  def host("fr"), do: "shop-fr.test"
  def host(_language), do: nil
end
