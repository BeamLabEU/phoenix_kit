# ============================================================================
# COMMENTED OUT: Component-based rendering system - Subheadline Component
# ============================================================================
# This module was part of an experimental component-based page building system
# using XML-style markup (.phk files) with swappable design variants.
# Related to: lib/phoenix_kit/publishing/page_builder.ex
# ============================================================================

# defmodule PhoenixKitWeb.Components.Publishing.Subheadline do
#   @moduledoc """
#   Subheadline component for hero sections.
#   """
#   use Phoenix.Component
#
#   attr :content, :string, required: true
#   attr :attributes, :map, default: %{}
#   attr :variant, :string, default: "default"
#
#   def render(assigns) do
#     ~H"""
#     <p class="text-lg md:text-xl text-base-content/70 leading-relaxed">
#       {@content}
#     </p>
#     """
#   end
# end
