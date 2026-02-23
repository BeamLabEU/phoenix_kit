defmodule PhoenixKitWeb.Components.Core.AdminPageHeader do
  @moduledoc """
  Provides a unified admin page header component with optional back button,
  title, subtitle, and action slots.

  Replaces the 7+ different header patterns previously used across admin templates,
  providing a consistent inline flex layout with responsive behavior.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders an admin page header with back navigation, title, and optional actions.

  For simple headers, use `title` and `subtitle` attributes. For complex headers
  with rich content (badges, metadata), use `inner_block` to provide custom title
  markup that replaces the default title/subtitle rendering.

  ## Attributes

  - `back` - Navigate path for the back button (renders a `<.link>`)
  - `back_click` - Phoenix event name for the back button (renders a `<button>`)
  - `title` - Page title as a string attribute
  - `subtitle` - Page subtitle as a string attribute

  ## Slots

  - `:inner_block` - Custom title/subtitle markup (overrides `title`/`subtitle` attrs)
  - `:actions` - Action buttons rendered on the right side

  ## Examples

      <%!-- Basic --%>
      <.admin_page_header back={Routes.path("/admin")} title="User Management" />

      <%!-- With subtitle --%>
      <.admin_page_header back={Routes.path("/admin")} title="Settings" subtitle="Configure system" />

      <%!-- With actions --%>
      <.admin_page_header back={Routes.path("/admin/posts")} title="Posts">
        <:actions>
          <button class="btn btn-primary btn-sm">New Post</button>
        </:actions>
      </.admin_page_header>

      <%!-- Rich title content --%>
      <.admin_page_header back={Routes.path("/admin/billing")}>
        <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">Invoice #123</h1>
        <p class="text-sm text-base-content/60 mt-0.5">Created 2 days ago</p>
      </.admin_page_header>

      <%!-- phx-click back (for unsaved changes check) --%>
      <.admin_page_header back_click="attempt_cancel" title="Page Editor" />
  """
  attr :back, :string, default: nil
  attr :back_click, :string, default: nil
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  slot :inner_block
  slot :actions

  def admin_page_header(assigns) do
    if assigns[:back] && assigns[:back_click] do
      raise ArgumentError, "admin_page_header: cannot set both `back` and `back_click`"
    end

    ~H"""
    <header class="mb-6">
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div class="flex items-center gap-3">
          <.link :if={@back} navigate={@back} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <button
            :if={@back_click}
            type="button"
            phx-click={@back_click}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </button>
          <div>
            <%= if @inner_block != [] do %>
              {render_slot(@inner_block)}
            <% else %>
              <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">
                {@title}
              </h1>
              <p :if={@subtitle} class="text-sm sm:text-base text-base-content/60 mt-0.5">
                {@subtitle}
              </p>
            <% end %>
          </div>
        </div>
        <div :if={@actions != []} class="flex items-center gap-2 sm:flex-shrink-0">
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end
end
