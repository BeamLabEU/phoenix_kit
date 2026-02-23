defmodule PhoenixKit.Modules.Publishing.Components.Hero do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.Hero`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.Hero
end
