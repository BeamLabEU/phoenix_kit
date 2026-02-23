defmodule PhoenixKit.Modules.Publishing.Components.Page do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.Page`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.Page
end
