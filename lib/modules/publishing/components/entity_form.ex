defmodule PhoenixKit.Modules.Publishing.Components.EntityForm do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.EntityForm`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.EntityForm
end
