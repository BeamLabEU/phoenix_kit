defmodule PhoenixKitWeb.Components.Core.AdminPageHeader do
  @moduledoc """
  Provides a unified admin page header component with optional back button,
  title, subtitle, and action slots.

  Replaces the 7+ different header patterns previously used across admin templates,
  providing a consistent inline flex layout with responsive behavior.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders an admin page header with title, subtitle, and optional actions.

  For simple headers, use `title` and `subtitle` attributes. For complex headers
  with rich content (badges, metadata), use `inner_block` to provide custom title
  markup that replaces the default title/subtitle rendering.

  ## Attributes

  - `title` - Page title as a string attribute
  - `subtitle` - Page subtitle as a string attribute
  - `back` - Path to navigate to when the back arrow is clicked. Must already be
    resolved (e.g. via `Routes.path/1` / `PhoenixKit.Utils.Routes.path/1`) — this
    renders a plain `<.link navigate>`, it does NOT re-apply the PhoenixKit URL
    prefix the way `<.pk_link>` would. When set, renders a compact ghost
    back-affordance inline beside the title, aligned to its first line (never
    on its own row — an icon-only circle by default).
  - `back_label` - Optional text shown next to the back arrow (from the `sm`
    breakpoint up; phones stay icon-only). When omitted the button is a
    circular icon-only chip (still gets an accessible label + title tooltip).
  - `back_click` - Deprecated, no-op. Retained so existing callers compile.

  ## Slots

  - `:inner_block` - Custom title/subtitle markup (overrides `title`/`subtitle` attrs)
  - `:actions` - Action buttons rendered on the right side

  ## Examples

      <%!-- Basic --%>
      <.admin_page_header title="User Management" />

      <%!-- With subtitle --%>
      <.admin_page_header title="Settings" subtitle="Configure system" />

      <%!-- With a back affordance --%>
      <.admin_page_header
        back={Routes.path("/admin/settings/email-sending")}
        back_label="Email Sending"
        title="Send Profiles"
      />

      <%!-- With actions --%>
      <.admin_page_header title="Posts">
        <:actions>
          <button class="btn btn-primary btn-sm">New Post</button>
        </:actions>
      </.admin_page_header>

      <%!-- Rich title content --%>
      <.admin_page_header>
        <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">Invoice #123</h1>
        <p class="text-sm text-base-content/60 mt-0.5">Created 2 days ago</p>
      </.admin_page_header>
  """
  attr :back, :string, default: nil
  attr :back_label, :string, default: nil
  attr :back_click, :string, default: nil
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  attr :class, :string,
    default: nil,
    doc: """
    Replaces the header's default bottom margin (`"mb-3 sm:mb-6"`) when set —
    pass e.g. `"mb-0"` when the page layout controls spacing itself (a flex
    gap), so margins don't compound.
    """

  slot :inner_block
  slot :actions

  def admin_page_header(assigns) do
    ~H"""
    <header class={@class || "mb-3 sm:mb-6"}>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div class="flex items-start gap-2 min-w-0">
          <.link
            :if={@back}
            navigate={@back}
            class={[
              "btn btn-ghost btn-sm shrink-0 -ml-2 mt-0.5 lg:mt-1",
              (@back_label && "gap-1") || "btn-circle"
            ]}
            aria-label={@back_label || gettext("Back")}
            title={@back_label || gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            <span :if={@back_label} class="hidden sm:inline">{@back_label}</span>
          </.link>
          <div class="min-w-0">
            <%= if @title do %>
              <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content break-words">
                {@title}
              </h1>
              <p :if={@subtitle} class="text-sm sm:text-base text-base-content/60 mt-0.5">
                {@subtitle}
              </p>
            <% else %>
              {render_slot(@inner_block)}
            <% end %>
          </div>
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
