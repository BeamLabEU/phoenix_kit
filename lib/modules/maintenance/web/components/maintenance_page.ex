defmodule PhoenixKitWeb.Components.Core.MaintenancePage do
  @moduledoc """
  Maintenance page card component.

  Renders the maintenance mode card with header, subtext, and optional countdown.
  Used by the `/maintenance` LiveView. Can also be embedded in other views.

  ## Examples

      <PhoenixKitWeb.Components.Core.MaintenancePage.maintenance_card />
      <PhoenixKitWeb.Components.Core.MaintenancePage.maintenance_card
        header="Coming Soon"
        subtext="Check back later!"
      />
  """

  use Phoenix.Component

  alias PhoenixKit.Modules.Maintenance

  @doc """
  Renders the maintenance card (header + subtext + emoji).

  ## Attributes
  - `header` - Main heading text (default: loaded from settings)
  - `subtext` - Descriptive text (default: loaded from settings)
  """
  attr :header, :string, default: nil
  attr :subtext, :string, default: nil

  def maintenance_card(assigns) do
    assigns =
      assigns
      |> assign_new(:header, fn -> Maintenance.get_header() end)
      |> assign_new(:subtext, fn -> Maintenance.get_subtext() end)

    ~H"""
    <div class="card bg-base-100 shadow-2xl border-2 border-dashed border-base-300 max-w-2xl w-full">
      <div class="card-body text-center py-12 px-6">
        <div class="text-8xl mb-6 opacity-70">
          🚧
        </div>
        <h1 class="text-5xl font-bold text-base-content mb-6">
          {@header}
        </h1>
        <p class="text-xl text-base-content/70 mb-8 leading-relaxed">
          {@subtext}
        </p>
      </div>
    </div>
    """
  end

  # Keep the old function name as an alias for backwards compatibility
  @doc false
  def maintenance_page(assigns), do: maintenance_card(assigns)
end
