defmodule PhoenixKit.Modules.Publishing.Components.Subheadline do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.Subheadline`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.Subheadline
end
