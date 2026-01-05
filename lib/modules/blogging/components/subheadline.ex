defmodule PhoenixKit.Modules.Blogging.Components.Subheadline do
  @moduledoc """
  Subheadline component for supporting text.
  """
  use Phoenix.Component

  attr :content, :string, required: true
  attr :attributes, :map, default: %{}
  attr :variant, :string, default: "default"

  def render(assigns) do
    ~H"""
    <p class="text-lg md:text-xl text-base-content/70 leading-relaxed">
      {@content}
    </p>
    """
  end
end
