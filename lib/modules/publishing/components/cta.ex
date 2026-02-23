defmodule PhoenixKit.Modules.Publishing.Components.CTA do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.CTA`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.CTA
end
