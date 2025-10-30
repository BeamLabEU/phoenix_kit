# ============================================================================
# COMMENTED OUT: Component-based rendering system - Page Component
# ============================================================================
# This module was part of an experimental component-based page building system
# using XML-style markup (.phk files) with swappable design variants.
# Related to: lib/phoenix_kit/publishing/page_builder.ex
# ============================================================================

# defmodule PhoenixKitWeb.Components.Publishing.Page do
#   @moduledoc """
#   Root page component wrapper.
#   """
#   use Phoenix.Component
#
#   attr :children, :list, default: []
#   attr :attributes, :map, default: %{}
#   attr :variant, :string, default: "default"
#
#   def render(assigns) do
#     ~H"""
#     <div class="phk-page" data-slug={@attributes["slug"]}>
#       <%= for child <- @children do %>
#         {render_child(child, assigns)}
#       <% end %>
#     </div>
#     """
#   end
#
#   defp render_child(child, assigns) do
#     case PhoenixKitWeb.Live.Modules.Publishing.PageBuilder.Renderer.render(child, assigns) do
#       {:ok, html} -> html
#       {:error, _} -> ""
#     end
#   end
# end
