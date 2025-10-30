# ============================================================================
# COMMENTED OUT: Component-based rendering system - Headline Component
# ============================================================================
# This module was part of an experimental component-based page building system
# using XML-style markup (.phk files) with swappable design variants.
# Related to: lib/phoenix_kit/publishing/page_builder.ex
# ============================================================================

# defmodule PhoenixKitWeb.Components.Publishing.Headline do
#   @moduledoc """
#   Headline component for hero sections.
#   """
#   use Phoenix.Component
#
#   attr :content, :string, required: true
#   attr :attributes, :map, default: %{}
#   attr :variant, :string, default: "default"
#
#   def render(assigns) do
#     ~H"""
#     <h1 class="text-4xl md:text-5xl lg:text-6xl font-bold text-base-content leading-tight">
#       {@content}
#     </h1>
#     """
#   end
# end
