defmodule PhoenixKit.Test.HandoffResolver do
  @moduledoc """
  A `:canonical_host_resolver` for the handoff tests: one host per language, on different TLDs.
  A dialect (`"en-US"`) has no domain of its own, as the resolver's contract allows.

  Every question is reported to the asking process (`{:resolver_asked, language}`), so a test can
  count them.
  """

  def host(language) do
    send(self(), {:resolver_asked, language})
    answer(language)
  end

  defp answer("en"), do: "shop.test"
  defp answer("de"), do: "shop-de.test"
  defp answer("fr"), do: "shop-fr.test"
  defp answer(_language), do: nil
end
