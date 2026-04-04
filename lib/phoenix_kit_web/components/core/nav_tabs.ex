defmodule PhoenixKitWeb.Components.Core.NavTabs do
  @moduledoc """
  Universal tab component for PhoenixKit.

  Supports two modes with identical visual appearance:

  **Navigation tabs** — each tab has a `path`, renders as `<.link navigate={...}>`:

      <.nav_tabs active_tab="general" tabs={[
        %{id: "general", label: "General", icon: "hero-cog-6-tooth", path: "/admin/settings"},
        %{id: "advanced", label: "Advanced", path: "/admin/settings/advanced"}
      ]} />

  **Event tabs** — no paths, uses `on_change` event via `phx-click`:

      <.nav_tabs active_tab={@active_tab} on_change="switch_tab" tabs={[
        %{id: "oban", label: "Oban Jobs"},
        %{id: "scheduler", label: "Scheduler"}
      ]} />

  **With badges** (works in both modes):

      <.nav_tabs active_tab={@tab} tabs={[
        %{id: "followers", label: "Followers", path: "/connections?tab=followers", badge: @followers_count},
        %{id: "following", label: "Following", path: "/connections?tab=following", badge: @following_count}
      ]} />

  ## Tab map keys

  Required: `:id`, `:label`
  Optional: `:icon` (Heroicon name), `:path` (navigation URL), `:badge` (count/text)
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Utils.Routes

  attr :active_tab, :string, required: true

  attr :tabs, :list,
    required: true,
    doc: "List of tab maps with :id, :label, and optional :icon, :path, :badge"

  attr :on_change, :string,
    default: nil,
    doc: "phx-click event name for event-based tabs (when tabs have no :path)"

  attr :class, :string, default: nil

  def nav_tabs(assigns) do
    ~H"""
    <div role="tablist" class={["tabs tabs-boxed bg-base-200 p-1", @class]}>
      <%= for tab <- @tabs do %>
        <%= if Map.has_key?(tab, :path) do %>
          <.link
            navigate={Routes.path(tab.path)}
            role="tab"
            class={["tab gap-2", tab.id == @active_tab && "tab-active"]}
          >
            <.icon :if={Map.has_key?(tab, :icon)} name={tab.icon} class="w-4 h-4" />
            {tab.label}
            <span
              :if={Map.has_key?(tab, :badge)}
              class={["badge badge-sm", tab.id == @active_tab && "badge-primary"]}
            >
              {tab.badge}
            </span>
          </.link>
        <% else %>
          <button
            type="button"
            role="tab"
            phx-click={@on_change}
            phx-value-tab={tab.id}
            class={["tab gap-2", tab.id == @active_tab && "tab-active"]}
          >
            <.icon :if={Map.has_key?(tab, :icon)} name={tab.icon} class="w-4 h-4" />
            {tab.label}
            <span
              :if={Map.has_key?(tab, :badge)}
              class={["badge badge-sm", tab.id == @active_tab && "badge-primary"]}
            >
              {tab.badge}
            </span>
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end
end
