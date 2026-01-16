defmodule PhoenixKitWeb.Components.Core.ModuleCard do
  @moduledoc """
  Provides a module card UI component for the Modules Overview page.

  This component renders a card displaying a system module with a toggle switch,
  status badges, action buttons, and optional configuration stats. Each module
  can have custom badges, buttons, and stats displayed through slots.
  """

  use Phoenix.Component

  @doc """
  Renders a module card with header, toggle, status, actions, and optional stats.

  ## Examples

      <.module_card
        title="Referral Codes"
        description="Manage referral codes for user registration and monitoring"
        icon="🎫"
        enabled={assigns.module_enabled}
        toggle_event="toggle_module"
      >
        <:status_badges>
          <span class="badge badge-success">
            Enabled
          </span>
          <span class="badge badge-outline ml-2">
            Optional
          </span>
        </:status_badges>

        <:action_buttons>
          <.link navigate="/admin/settings/module" class="btn btn-primary btn-sm">
            Configure
          </.link>
        </:action_buttons>

        <:stats>
          <div class="grid grid-cols-2 gap-2 text-xs">
            <div>
              <span class="text-base-content/70">Max per user:</span>
              <span class="font-medium">5</span>
            </div>
          </div>
        </:stats>
      </.module_card>
  """
  attr(:title, :string, required: true, doc: "Module title")
  attr(:description, :string, required: true, doc: "Module description text")
  attr(:icon, :string, required: true, doc: "Emoji icon for the module")
  attr(:enabled, :boolean, required: true, doc: "Whether the module is enabled")
  attr(:toggle_event, :string, required: true, doc: "Phoenix event name for the toggle switch")
  attr :show_toggle, :boolean, default: true, doc: "Whether to show the toggle switch"
  attr :toggle_disabled, :boolean, default: false, doc: "Whether the toggle is disabled"
  attr :toggle_hint, :string, default: nil, doc: "Hint text shown under the toggle when disabled"
  attr :stats_title, :string, default: "Current Configuration", doc: "Title for the stats section"

  slot(:status_badges, required: true, doc: "Status badges to display (left side of actions row)")

  slot(:action_buttons,
    required: true,
    doc: "Action buttons to display (right side of actions row)"
  )

  slot(:stats, doc: "Optional stats/configuration section (shown when enabled)")
  slot(:info, doc: "Optional informational content rendered between header and actions")

  def module_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <%!-- Header: Icon, Title, Description, Toggle --%>
        <div class="flex items-center">
          <div class="text-3xl px-3 mr-4">{@icon}</div>
          <div class="flex-1">
            <h3 class="card-title text-xl">{@title}</h3>
            <p class="text-base-content/70">
              {@description}
            </p>
          </div>
          <%= if @show_toggle do %>
            <div class="flex flex-col items-end gap-1">
              <input
                type="checkbox"
                class="toggle toggle-primary"
                checked={@enabled}
                disabled={@toggle_disabled}
                phx-click={@toggle_event}
              />
              <%= if @toggle_hint do %>
                <span class="badge badge-warning badge-xs">{@toggle_hint}</span>
              <% end %>
            </div>
          <% end %>
        </div>

        <%= if @info != [] do %>
          <div class="mt-4 bg-base-200/60 rounded-lg p-3 text-xs text-base-content/80 space-y-2">
            {render_slot(@info)}
          </div>
        <% end %>

        <div class="divider my-2"></div>

        <%!-- Status and Configuration --%>
        <div class="flex items-center justify-between">
          <div>
            {render_slot(@status_badges)}
          </div>

          <div class="card-actions">
            {render_slot(@action_buttons)}
          </div>
        </div>

        <%!-- Optional Stats Section --%>
        <%= if @enabled && @stats != [] do %>
          <div class="bg-base-200 rounded-lg p-3 mt-4">
            <h4 class="text-sm font-medium text-base-content mb-2">{@stats_title}</h4>
            {render_slot(@stats)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
