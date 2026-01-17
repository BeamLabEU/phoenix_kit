defmodule PhoenixKitWeb.Components.Dashboard.ContextSelector do
  @moduledoc """
  Context selector dropdown component for dashboard navigation.

  Allows users with multiple contexts (organizations, farms, teams, etc.)
  to switch between them. Only renders when the user has 2+ contexts.

  ## Components

  - `context_selector/1` - Header dropdown (for `position: :header` with `sub_position: :start` or `:end`)
  - `sidebar_context_selector/1` - Sidebar dropdown (for `position: :sidebar`)
  - `mobile_context_selector/1` - Mobile menu variant

  ## Usage

  Header position (default):

      <.context_selector
        contexts={@dashboard_contexts}
        current={@current_context}
        config={@context_selector_config}
      />

  Sidebar position:

      <.sidebar_context_selector
        contexts={@dashboard_contexts}
        current={@current_context}
        config={@context_selector_config}
      />

  Or use the convenience wrappers that check visibility:

      <.context_selector_if_enabled
        show={@show_context_selector}
        contexts={@dashboard_contexts}
        current={@current_context}
        config={@context_selector_config}
      />

      <.sidebar_context_selector_if_enabled
        show={@show_context_selector}
        contexts={@dashboard_contexts}
        current={@current_context}
        config={@context_selector_config}
      />

  """

  use Phoenix.Component

  alias PhoenixKit.Dashboard.ContextSelector

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders the context selector dropdown.

  Only renders if there are contexts to display.

  ## Attributes

  - `contexts` - List of context items
  - `current` - The currently selected context
  - `config` - The ContextSelector config struct
  - `class` - Additional CSS classes

  """
  attr :contexts, :list, required: true
  attr :current, :any, default: nil
  attr :config, :any, required: true
  attr :class, :string, default: ""

  def context_selector(assigns) do
    ~H"""
    <div class={["dropdown dropdown-end", @class]}>
      <label tabindex="0" class="btn btn-ghost gap-2 normal-case font-normal">
        <%= if @config.icon do %>
          <.icon name={@config.icon} class="w-4 h-4" />
        <% end %>
        <span class="max-w-[150px] truncate">
          {get_current_display_name(@current, @config)}
        </span>
        <.icon name="hero-chevron-down" class="w-4 h-4 opacity-50" />
      </label>
      <ul
        tabindex="0"
        class="dropdown-content z-50 menu p-2 shadow-lg bg-base-100 rounded-box w-56 border border-base-300"
      >
        <li class="menu-title">
          <span>Switch {@config.label}</span>
        </li>
        <%= for context <- @contexts do %>
          <li>
            <.link
              href={context_switch_path(context, @config)}
              method="post"
              class={context_item_classes(context, @current, @config)}
            >
              <%= if @config.icon do %>
                <.icon name={@config.icon} class="w-4 h-4" />
              <% end %>
              <span class="flex-1 truncate">
                {get_display_name(context, @config)}
              </span>
              <%= if current?(context, @current, @config) do %>
                <.icon name="hero-check" class="w-4 h-4 text-success" />
              <% end %>
            </.link>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  @doc """
  Conditionally renders the context selector based on visibility flag.

  Use this wrapper to avoid checking `@show_context_selector` manually.

  ## Attributes

  - `show` - Boolean flag from `@show_context_selector`
  - All other attributes are passed to `context_selector/1`

  """
  attr :show, :boolean, default: false
  attr :contexts, :list, required: true
  attr :current, :any, default: nil
  attr :config, :any, required: true
  attr :class, :string, default: ""

  def context_selector_if_enabled(assigns) do
    ~H"""
    <%= if @show and @config.enabled do %>
      <.context_selector
        contexts={@contexts}
        current={@current}
        config={@config}
        class={@class}
      />
    <% end %>
    """
  end

  @doc """
  Renders a mobile-friendly context selector for mobile menus.

  Shows as a list section at the top of mobile navigation.

  ## Attributes

  - `contexts` - List of context items
  - `current` - The currently selected context
  - `config` - The ContextSelector config struct

  """
  attr :contexts, :list, required: true
  attr :current, :any, default: nil
  attr :config, :any, required: true

  def mobile_context_selector(assigns) do
    ~H"""
    <div class="px-2 py-3 border-b border-base-300">
      <div class="text-xs font-semibold text-base-content/60 uppercase tracking-wider mb-2 px-2">
        Current {@config.label}
      </div>
      <ul class="menu menu-sm">
        <%= for context <- @contexts do %>
          <li>
            <.link
              href={context_switch_path(context, @config)}
              method="post"
              class={mobile_context_item_classes(context, @current, @config)}
            >
              <%= if @config.icon do %>
                <.icon name={@config.icon} class="w-4 h-4" />
              <% end %>
              <span class="flex-1 truncate">
                {get_display_name(context, @config)}
              </span>
              <%= if current?(context, @current, @config) do %>
                <.icon name="hero-check" class="w-4 h-4 text-success" />
              <% end %>
            </.link>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  @doc """
  Conditionally renders the mobile context selector.
  """
  attr :show, :boolean, default: false
  attr :contexts, :list, required: true
  attr :current, :any, default: nil
  attr :config, :any, required: true

  def mobile_context_selector_if_enabled(assigns) do
    ~H"""
    <%= if @show and @config.enabled do %>
      <.mobile_context_selector
        contexts={@contexts}
        current={@current}
        config={@config}
      />
    <% end %>
    """
  end

  @doc """
  Renders a context selector for the sidebar.

  Displays as a dropdown at the top of the sidebar navigation.

  ## Attributes

  - `contexts` - List of context items
  - `current` - The currently selected context
  - `config` - The ContextSelector config struct
  - `class` - Additional CSS classes

  """
  attr :contexts, :list, required: true
  attr :current, :any, default: nil
  attr :config, :any, required: true
  attr :class, :string, default: ""

  def sidebar_context_selector(assigns) do
    ~H"""
    <div class={["mb-4 px-2", @class]}>
      <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-2">
        {@config.label}
      </div>
      <div class="dropdown dropdown-bottom w-full">
        <label
          tabindex="0"
          class="btn btn-ghost btn-sm w-full justify-between gap-2 normal-case font-normal bg-base-200 hover:bg-base-300"
        >
          <span class="flex items-center gap-2 truncate">
            <%= if @config.icon do %>
              <.icon name={@config.icon} class="w-4 h-4 shrink-0" />
            <% end %>
            <span class="truncate">
              {get_current_display_name(@current, @config)}
            </span>
          </span>
          <.icon name="hero-chevron-up-down" class="w-4 h-4 opacity-50 shrink-0" />
        </label>
        <ul
          tabindex="0"
          class="dropdown-content z-50 menu p-2 shadow-lg bg-base-100 rounded-box w-full border border-base-300 mt-1"
        >
          <%= for context <- @contexts do %>
            <li>
              <.link
                href={context_switch_path(context, @config)}
                method="post"
                class={context_item_classes(context, @current, @config)}
              >
                <%= if @config.icon do %>
                  <.icon name={@config.icon} class="w-4 h-4" />
                <% end %>
                <span class="flex-1 truncate">
                  {get_display_name(context, @config)}
                </span>
                <%= if current?(context, @current, @config) do %>
                  <.icon name="hero-check" class="w-4 h-4 text-success" />
                <% end %>
              </.link>
            </li>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Conditionally renders the sidebar context selector.
  """
  attr :show, :boolean, default: false
  attr :contexts, :list, required: true
  attr :current, :any, default: nil
  attr :config, :any, required: true
  attr :class, :string, default: ""

  def sidebar_context_selector_if_enabled(assigns) do
    ~H"""
    <%= if @show and @config.enabled do %>
      <.sidebar_context_selector
        contexts={@contexts}
        current={@current}
        config={@config}
        class={@class}
      />
    <% end %>
    """
  end

  # Private helpers

  defp get_current_display_name(nil, config), do: "Select #{config.label}"

  defp get_current_display_name(current, config) do
    ContextSelector.get_display_name_for_config(config, current)
  end

  defp get_display_name(context, config) do
    ContextSelector.get_display_name_for_config(config, context)
  end

  defp context_switch_path(context, config) do
    id = ContextSelector.get_id_for_config(config, context)
    url_prefix = PhoenixKit.Config.get_url_prefix()

    # Use keyed path for multi-selector, legacy path for single selector
    if config.key && config.key != :default do
      "#{url_prefix}/context/#{config.key}/#{id}"
    else
      "#{url_prefix}/context/#{id}"
    end
  end

  defp current?(context, current, config) do
    context_id = ContextSelector.get_id_for_config(config, context)
    current_id = ContextSelector.get_id_for_config(config, current)
    context_id == current_id
  end

  defp context_item_classes(context, current, config) do
    base_classes = "flex items-center gap-2"

    if current?(context, current, config) do
      "#{base_classes} active"
    else
      base_classes
    end
  end

  defp mobile_context_item_classes(context, current, config) do
    base_classes = "flex items-center gap-2"

    if current?(context, current, config) do
      "#{base_classes} bg-primary/10 text-primary"
    else
      base_classes
    end
  end
end
