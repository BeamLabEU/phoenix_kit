defmodule PhoenixKitWeb.Components.Core.UserDashboardHeader do
  @moduledoc """
  Provides a unified user dashboard header component with title, subtitle, and action slots.

  Use this component in custom user dashboard pages for consistent page-level
  headers with titles and action buttons.

  ## Examples

      <%!-- Basic --%>
      <.user_dashboard_header title="My Profile" />

      <%!-- With subtitle --%>
      <.user_dashboard_header title="Security" subtitle="Manage your account security" />

      <%!-- With actions --%>
      <.user_dashboard_header title="My Posts">
        <:actions>
          <.pk_link_button navigate={~p"/dashboard/posts/new"} variant="primary">
            New Post
          </.pk_link_button>
        </:actions>
      </.user_dashboard_header>

      <%!-- Rich title content --%>
      <.user_dashboard_header>
        <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">Order #123</h1>
        <p class="text-sm text-base-content/60 mt-0.5">Placed 2 days ago</p>
      </.user_dashboard_header>

  ## Attributes

  - `title` - Page title as a string attribute
  - `subtitle` - Page subtitle as a string attribute

  ## Slots

  - `:inner_block` - Custom title/subtitle markup (overrides `title`/`subtitle` attrs)
  - `:actions` - Action buttons rendered on the right side

  """

  use Phoenix.Component

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  slot :inner_block
  slot :actions

  def user_dashboard_header(assigns) do
    ~H"""
    <header class="mb-3 sm:mb-6">
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <%= if @title do %>
            <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">
              {@title}
            </h1>
            <p :if={@subtitle} class="text-sm sm:text-base text-base-content/60 mt-0.5">
              {@subtitle}
            </p>
          <% else %>
            {render_slot(@inner_block)}
          <% end %>
        </div>
        <div
          :if={@actions != []}
          class="flex flex-wrap items-center gap-2 sm:flex-shrink-0 [&>*]:w-full [&>*]:sm:w-auto"
        >
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end
end
