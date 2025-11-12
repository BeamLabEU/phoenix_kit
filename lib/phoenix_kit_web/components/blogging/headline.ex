defmodule PhoenixKitWeb.Components.Blogging.Headline do
  @moduledoc """
  Headline component for hero sections.
  """
  use Phoenix.Component

  attr :content, :string, required: true
  attr :attributes, :map, default: %{}
  attr :variant, :string, default: "default"

  def render(assigns) do
    ~H"""
    <h1 class="text-4xl md:text-5xl lg:text-6xl font-bold text-base-content leading-tight">
      {@content}
    </h1>
    """
  end
end
