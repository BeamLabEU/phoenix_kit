defmodule PhoenixKitWeb.Components.Blogging.Page do
  @moduledoc """
  Root page component wrapper.
  """
  use Phoenix.Component

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
    case PhoenixKitWeb.Live.Modules.Blogging.PageBuilder.Renderer.render(child, assigns) do
      {:ok, html} -> html
      {:error, _} -> ""
    end
  end
end
