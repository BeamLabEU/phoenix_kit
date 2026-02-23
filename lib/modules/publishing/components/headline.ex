defmodule PhoenixKit.Modules.Publishing.Components.Headline do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.Headline`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.Headline
end
