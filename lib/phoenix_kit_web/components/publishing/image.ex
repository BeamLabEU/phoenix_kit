# ============================================================================
# COMMENTED OUT: Component-based rendering system - Image Component
# ============================================================================
# This module was part of an experimental component-based page building system
# using XML-style markup (.phk files) with swappable design variants.
# Related to: lib/phoenix_kit/publishing/page_builder.ex
# ============================================================================

# defmodule PhoenixKitWeb.Components.Publishing.Image do
#   @moduledoc """
#   Image component for hero sections and content.
#   """
#   use Phoenix.Component
#
#   attr :attributes, :map, default: %{}
#   attr :variant, :string, default: "default"
#   attr :content, :string, default: nil
#
#   def render(assigns) do
#     src = Map.get(assigns.attributes, "src", "")
#     alt = Map.get(assigns.attributes, "alt", "")
#
#     assigns =
#       assigns
#       |> assign(:src, src)
#       |> assign(:alt, alt)
#
#     ~H"""
#     <img
#       src={@src}
#       alt={@alt}
#       class="w-full h-auto rounded-lg shadow-2xl"
#       loading="lazy"
#     />
#     """
#   end
# end
