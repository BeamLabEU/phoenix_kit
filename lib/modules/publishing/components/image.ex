defmodule PhoenixKit.Modules.Publishing.Components.Image do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.Image`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.Image
end
