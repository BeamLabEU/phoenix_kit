defmodule PhoenixKit.Modules.Shared.Components.Page do
  @moduledoc """
  Root page component wrapper.
  """
  use Phoenix.Component

  # Page delegates child rendering to the caller's PageBuilder.Renderer.
  # Default to Publishing's renderer for backward compatibility.
  @default_renderer PhoenixKit.Modules.Publishing.PageBuilder.Renderer

  attr :children, :list, default: []
  attr :attributes, :map, default: %{}
  attr :variant, :string, default: "default"

  def render(assigns) do
    ~H"""
    <div class="phk-page" data-slug={@attributes["slug"]}>
      <%= for child <- @children do %>
        {render_child(child, assigns)}
      <% end %>
    </div>
    """
  end

  defp render_child(child, assigns) do
    renderer = assigns[:__renderer__] || @default_renderer

    case renderer.render(child, assigns) do
      {:ok, html} -> html
      {:error, _} -> ""
    end
  end
end
