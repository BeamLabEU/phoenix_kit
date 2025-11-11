defmodule PhoenixKitWeb.Components.Core.StatCard do
  @moduledoc """
  Provides a statistics card UI component for dashboard metrics.

  This component renders a gradient card with an icon, main statistic value,
  title, and subtitle. Commonly used in admin dashboards to display KPIs
  and real-time statistics.
  """

  use Phoenix.Component

  @doc """
  Renders a statistics card with semantic background color.

  ## Examples

      <.stat_card
        value={@session_stats.total_active}
        title="Active Sessions"
        subtitle="Currently logged in"
      >
        <:icon>
          <PhoenixKitWeb.Components.Core.Icons.icon_activity />
        </:icon>
      </.stat_card>

      <.stat_card
        rounded="2xl"
        value={@stats.active_users}
        title="Active Users"
        subtitle="Currently online"
      >
        <:icon>
          <PhoenixKitWeb.Components.Core.Icons.icon_check_circle_filled />
        </:icon>
      </.stat_card>

      <.stat_card
        compact={true}
        value={@stats.total_users}
        title="Total Users"
        subtitle="Registered accounts"
      >
        <:icon>
          <.icon name="hero-users" class="w-5 h-5" />
        </:icon>
      </.stat_card>
  """
  attr :rounded, :string, default: "xl", doc: "Border radius size (xl, 2xl, etc.)"
  attr :compact, :boolean, default: false, doc: "Use compact layout with reduced height"
  attr :value, :any, required: true, doc: "The main statistic value to display"
  attr :title, :string, required: true, doc: "The card title text"
  attr :subtitle, :string, required: true, doc: "The smaller descriptive text"

  slot :icon, required: true, doc: "Icon to display in the card header"

  def stat_card(assigns) do
    ~H"""
    <div class={[
      "bg-info text-info-content rounded-box shadow-xl hover:shadow-2xl transition-all duration-300 transform hover:scale-105",
      if(@compact, do: "p-4", else: "p-6")
    ]}>
      <%= if @compact do %>
        <%!-- Compact horizontal layout --%>
        <div class="flex items-center gap-3">
          <div class="p-2 bg-white/20 rounded-box flex-shrink-0">
            {render_slot(@icon)}
          </div>
          <div class="flex-1">
            <div class="text-2xl font-bold mb-1">{@value}</div>
            <div class="text-info-content/90 font-medium text-sm">{@title}</div>
            <div class="text-info-content/70 text-xs">{@subtitle}</div>
          </div>
        </div>
      <% else %>
        <%!-- Original vertical layout --%>
        <div class="flex items-center justify-between mb-4">
          <div class="p-2 bg-white/20 rounded-box">
            {render_slot(@icon)}
          </div>
        </div>
        <div class="text-3xl font-bold mb-2">{@value}</div>
        <div class="text-info-content/90 font-medium">{@title}</div>
        <div class="text-info-content/70 text-xs mt-1">
          {@subtitle}
        </div>
      <% end %>
    </div>
    """
  end
end
