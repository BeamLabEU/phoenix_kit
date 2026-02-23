defmodule PhoenixKit.Modules.Publishing.Components.Video do
  @moduledoc """
  Delegates to `PhoenixKit.Modules.Shared.Components.Video`.

  Kept for backward compatibility with external consumers.
  """

  defdelegate render(assigns), to: PhoenixKit.Modules.Shared.Components.Video
end
