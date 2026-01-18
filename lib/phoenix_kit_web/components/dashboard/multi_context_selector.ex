defmodule PhoenixKitWeb.Components.Dashboard.MultiContextSelector do
  @moduledoc """
  Wrapper component for rendering multiple context selectors.

  This component filters selectors by position and sub_position, sorts them
  by priority, and renders them in a flex container.

  ## Usage

  Header position (start):

      <.multi_context_selector
        position={:header}
        sub_position={:start}
        configs={@context_selector_configs}
        contexts_map={@dashboard_contexts_map}
        current_map={@current_contexts_map}
        show_map={@show_context_selectors_map}
      />

  Sidebar position (end):

      <.multi_context_selector_sidebar
        position={:sidebar}
        sub_position={:end}
        configs={@context_selector_configs}
        contexts_map={@dashboard_contexts_map}
        current_map={@current_contexts_map}
        show_map={@show_context_selectors_map}
      />

  """

  use Phoenix.Component

  alias PhoenixKitWeb.Components.Dashboard.ContextSelector, as: SelectorComponent

  @doc """
  Renders multiple context selectors for header position.

  Filters selectors by position and sub_position, sorts by priority.

  ## Attributes

  - `position` - The position to filter by (:header or :sidebar)
  - `sub_position` - The sub_position to filter by (:start, :end, or {:priority, N})
  - `configs` - List of all ContextSelector configs
  - `contexts_map` - Map of key => list of contexts
  - `current_map` - Map of key => current context
  - `show_map` - Map of key => boolean (whether to show selector)
  - `class` - Additional CSS classes
  - `separator` - Optional separator between selectors

  """
  attr :position, :atom, default: :header
  attr :sub_position, :atom, default: :start
  attr :configs, :list, required: true
  attr :contexts_map, :map, required: true
  attr :current_map, :map, required: true
  attr :show_map, :map, required: true
  attr :class, :string, default: ""
  attr :separator, :string, default: nil

  def multi_context_selector(assigns) do
    # Filter and sort configs for this position
    filtered_configs =
      assigns.configs
      |> Enum.filter(fn config ->
        config.enabled &&
          config.position == assigns.position &&
          sub_position_matches?(config.sub_position, assigns.sub_position)
      end)
      |> Enum.sort_by(& &1.priority)

    assigns = assign(assigns, :filtered_configs, filtered_configs)

    ~H"""
    <%= if @filtered_configs != [] do %>
      <div class={["flex items-center gap-2", @class]}>
        <%= for {config, index} <- Enum.with_index(@filtered_configs) do %>
          <% show = Map.get(@show_map, config.key, false) %>
          <% contexts = Map.get(@contexts_map, config.key, []) %>
          <% current = Map.get(@current_map, config.key) %>

          <%= if index > 0 and @separator do %>
            <span class="text-base-content/30">{@separator}</span>
          <% end %>

          <%= if show do %>
            <SelectorComponent.context_selector
              contexts={contexts}
              current={current}
              config={config}
            />
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders multiple context selectors for sidebar position.

  Uses sidebar-specific styling for vertical layout.
  """
  attr :position, :atom, default: :sidebar
  attr :sub_position, :atom, default: :start
  attr :configs, :list, required: true
  attr :contexts_map, :map, required: true
  attr :current_map, :map, required: true
  attr :show_map, :map, required: true
  attr :class, :string, default: ""

  def multi_context_selector_sidebar(assigns) do
    # Filter and sort configs for this position
    filtered_configs =
      assigns.configs
      |> Enum.filter(fn config ->
        config.enabled &&
          config.position == assigns.position &&
          sub_position_matches?(config.sub_position, assigns.sub_position)
      end)
      |> Enum.sort_by(& &1.priority)

    assigns = assign(assigns, :filtered_configs, filtered_configs)

    ~H"""
    <%= if @filtered_configs != [] do %>
      <div class={["flex flex-col gap-2", @class]}>
        <%= for config <- @filtered_configs do %>
          <% show = Map.get(@show_map, config.key, false) %>
          <% contexts = Map.get(@contexts_map, config.key, []) %>
          <% current = Map.get(@current_map, config.key) %>

          <%= if show do %>
            <SelectorComponent.sidebar_context_selector
              contexts={contexts}
              current={current}
              config={config}
            />
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders mobile context selectors for all keys.
  """
  attr :configs, :list, required: true
  attr :contexts_map, :map, required: true
  attr :current_map, :map, required: true
  attr :show_map, :map, required: true

  def multi_context_selector_mobile(assigns) do
    # Sort all configs by priority
    sorted_configs =
      assigns.configs
      |> Enum.filter(& &1.enabled)
      |> Enum.sort_by(& &1.priority)

    assigns = assign(assigns, :sorted_configs, sorted_configs)

    ~H"""
    <%= for config <- @sorted_configs do %>
      <% show = Map.get(@show_map, config.key, false) %>
      <% contexts = Map.get(@contexts_map, config.key, []) %>
      <% current = Map.get(@current_map, config.key) %>

      <%= if show do %>
        <SelectorComponent.mobile_context_selector
          contexts={contexts}
          current={current}
          config={config}
        />
      <% end %>
    <% end %>
    """
  end

  @doc """
  Checks if multi-selector is enabled and there are any selectors to show.

  Use this to conditionally render the multi-selector container.
  """
  attr :configs, :list, required: true
  attr :show_map, :map, required: true
  attr :position, :atom, default: :header
  attr :sub_position, :atom, default: :start

  def has_visible_selectors?(assigns) do
    assigns.configs
    |> Enum.any?(fn config ->
      config.enabled &&
        config.position == assigns.position &&
        sub_position_matches?(config.sub_position, assigns.sub_position) &&
        Map.get(assigns.show_map, config.key, false)
    end)
  end

  # Private helpers

  defp sub_position_matches?(config_sub, target_sub) when config_sub == target_sub, do: true
  defp sub_position_matches?({:priority, _}, :start), do: true
  defp sub_position_matches?({:priority, _}, :end), do: true
  defp sub_position_matches?(_, _), do: false
end
