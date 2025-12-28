defmodule PhoenixKitWeb.Components.Core.HeroStatCard do
  @moduledoc """
  Provides a large hero statistics card UI component for prominent dashboard metrics.

  This component renders a large gradient card with icon with title side-by-side,
  and a prominent statistic value. Used for key metrics like System Owners,
  Administrators, and Total Users.
  """

  use Phoenix.Component

  @doc """
  Renders a large hero statistics card.

  ## Examples

      <.hero_stat_card
        value={@stats.owner_count}
        title="System Owners"
        subtitle="Complete system authority"
      >
        <:icon>
          <PhoenixKitWeb.Components.Core.Icons.icon_crown />
        </:icon>
      </.hero_stat_card>

      <.hero_stat_card
        value={@stats.admin_count}
        title="Administrators"
        subtitle="Management privileges"
      >
        <:icon>
          <PhoenixKitWeb.Components.Core.Icons.icon_star />
        </:icon>
      </.hero_stat_card>
  """
  attr :value, :any, required: true, doc: "The main statistic value to display"
  attr :title, :string, required: true, doc: "The card title text (displayed next to icon)"
  attr :subtitle, :string, required: true, doc: "The smaller descriptive text"

  slot :icon, required: true, doc: "Icon to display next to the title"

  def hero_stat_card(assigns) do
    ~H"""
    <div class="card bg-primary text-primary-content shadow-2xl hover:shadow-3xl transition-all duration-300 border-0 transform hover:scale-105">
      <div class="card-body relative overflow-hidden">
        <div class="flex items-center gap-3 mb-4">
          <div class="p-2 bg-white/20 rounded-lg">
            {render_slot(@icon)}
          </div>
          <h2 class="card-title text-xl">{@title}</h2>
        </div>
        <div class="text-7xl font-black mb-2 tracking-tight">{@value}</div>
        <p class="text-primary-content/80 text-sm">{@subtitle}</p>
      </div>
    </div>
    """
  end
end
