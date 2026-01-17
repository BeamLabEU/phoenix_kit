defmodule PhoenixKitWeb.Components.Dashboard.TabItem do
  @moduledoc """
  Tab item component for dashboard navigation.

  Renders individual tabs with support for:
  - Icons and labels
  - Badges and indicators
  - Active state highlighting
  - Attention animations
  - External links
  - Tooltips
  - Presence indicators
  """

  use Phoenix.Component

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Dashboard.Badge, as: BadgeComponent

  # Use the icon component from Core.Icon to avoid circular dependencies
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders a dashboard tab item.

  ## Attributes

  - `tab` - The Tab struct
  - `active` - Whether this tab is currently active
  - `viewer_count` - Number of users viewing this tab (optional)
  - `locale` - Current locale for path generation
  - `compact` - Render in compact mode (icon only)
  - `class` - Additional CSS classes

  ## Examples

      <.tab_item tab={@tab} active={@tab.active} />
      <.tab_item tab={@tab} active={true} viewer_count={3} />
  """
  attr :tab, :any, required: true
  attr :active, :boolean, default: false
  attr :viewer_count, :integer, default: 0
  attr :locale, :string, default: nil
  attr :compact, :boolean, default: false
  attr :class, :string, default: ""

  def tab_item(assigns) do
    cond do
      Tab.divider?(assigns.tab) ->
        render_divider(assigns)

      Tab.group_header?(assigns.tab) ->
        render_group_header(assigns)

      true ->
        render_tab(assigns)
    end
  end

  defp render_tab(assigns) do
    path = build_path(assigns.tab.path, assigns.locale)
    is_subtab = Tab.subtab?(assigns.tab)
    subtab_style = get_subtab_style(assigns.tab)

    assigns =
      assigns
      |> assign(:path, path)
      |> assign(:is_subtab, is_subtab)
      |> assign(:subtab_style, subtab_style)

    ~H"""
    <%= if @tab.external do %>
      <a
        href={@path}
        target={if @tab.new_tab, do: "_blank", else: nil}
        rel={if @tab.new_tab, do: "noopener noreferrer", else: nil}
        class={tab_classes(@active, @tab.attention, @is_subtab, @subtab_style, @class)}
        title={@tab.tooltip}
        data-tab-id={@tab.id}
        data-parent-id={@tab.parent}
      >
        <.tab_content
          tab={@tab}
          active={@active}
          viewer_count={@viewer_count}
          compact={@compact}
          is_subtab={@is_subtab}
          subtab_style={@subtab_style}
        />
        <%= if @tab.external do %>
          <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 ml-auto opacity-50" />
        <% end %>
      </a>
    <% else %>
      <.link
        navigate={@path}
        class={tab_classes(@active, @tab.attention, @is_subtab, @subtab_style, @class)}
        title={@tab.tooltip}
        data-tab-id={@tab.id}
        data-parent-id={@tab.parent}
      >
        <.tab_content
          tab={@tab}
          active={@active}
          viewer_count={@viewer_count}
          compact={@compact}
          is_subtab={@is_subtab}
          subtab_style={@subtab_style}
        />
      </.link>
    <% end %>
    """
  end

  defp render_divider(assigns) do
    ~H"""
    <%= if @tab.label do %>
      <div class={[
        "px-3 py-2 text-xs font-semibold text-base-content/50 uppercase tracking-wider",
        @class
      ]}>
        {@tab.label}
      </div>
    <% else %>
      <div class={["divider my-1", @class]}></div>
    <% end %>
    """
  end

  defp render_group_header(assigns) do
    collapsible = assigns.tab.metadata[:collapsible] || false
    collapsed = assigns.tab.metadata[:collapsed] || false

    assigns =
      assigns
      |> assign(:collapsible, collapsible)
      |> assign(:collapsed, collapsed)

    ~H"""
    <div
      class={[
        "px-3 py-2 text-xs font-semibold text-base-content/60 uppercase tracking-wider",
        @collapsible && "cursor-pointer hover:text-base-content/80 flex items-center justify-between",
        @class
      ]}
      data-group-id={@tab.id}
      data-collapsible={@collapsible}
      phx-click={@collapsible && "toggle_group"}
      phx-value-group={@tab.id}
    >
      <span class="flex items-center gap-2">
        <%= if @tab.icon do %>
          <.icon name={@tab.icon} class="w-3.5 h-3.5" />
        <% end %>
        {@tab.label}
      </span>
      <%= if @collapsible do %>
        <.icon
          name={if @collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
          class="w-3.5 h-3.5"
        />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the inner content of a tab (icon, label, badge, presence).
  """
  attr :tab, :any, required: true
  attr :active, :boolean, default: false
  attr :viewer_count, :integer, default: 0
  attr :compact, :boolean, default: false
  attr :is_subtab, :boolean, default: false
  attr :subtab_style, :map, default: %{}

  def tab_content(assigns) do
    ~H"""
    <div class="flex items-center gap-3 flex-1 min-w-0">
      <%= if @tab.icon do %>
        <.icon
          name={@tab.icon}
          class={icon_classes(@active, @tab.attention, @is_subtab, @subtab_style)}
        />
      <% end %>
      <%= unless @compact do %>
        <span class={["truncate", @is_subtab && (@subtab_style[:text_size] || "text-sm")]}>
          {@tab.label}
        </span>
      <% end %>
    </div>
    <div class="flex items-center gap-2 ml-auto">
      <%= if @tab.badge do %>
        <BadgeComponent.dashboard_badge badge={@tab.badge} />
      <% end %>
      <%= if @viewer_count > 0 do %>
        <BadgeComponent.presence_indicator count={@viewer_count} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a mobile-friendly tab item for bottom navigation.
  """
  attr :tab, :any, required: true
  attr :active, :boolean, default: false
  attr :locale, :string, default: nil
  attr :class, :string, default: ""

  def mobile_tab_item(assigns) do
    # Skip dividers and headers for mobile
    if Tab.navigable?(assigns.tab) do
      path = build_path(assigns.tab.path, assigns.locale)
      assigns = assign(assigns, :path, path)

      ~H"""
      <.link
        navigate={@path}
        class={mobile_tab_classes(@active, @tab.attention, @class)}
        data-tab-id={@tab.id}
      >
        <div class="relative">
          <%= if @tab.icon do %>
            <.icon name={@tab.icon} class={mobile_icon_classes(@active)} />
          <% end %>
          <%= if @tab.badge && PhoenixKit.Dashboard.Badge.visible?(@tab.badge) do %>
            <span class="absolute -top-1 -right-1">
              <BadgeComponent.dashboard_badge badge={@tab.badge} class="badge-xs" />
            </span>
          <% end %>
        </div>
        <span class="text-xs mt-1 truncate">{@tab.label}</span>
      </.link>
      """
    else
      ~H""
    end
  end

  # Helper functions

  # Always apply URL prefix via Routes.path
  # When locale is nil, use :none to skip locale prefix but still apply URL prefix
  defp build_path(path, nil), do: Routes.path(path, locale: :none)

  defp build_path(path, locale) do
    Routes.path(path, locale: locale)
  end

  defp tab_classes(active, attention, is_subtab, subtab_style, extra_class) do
    base =
      "flex items-center py-2 text-sm font-medium rounded-lg transition-all duration-200"

    # Subtabs use configurable indent, defaults to "pl-9 pr-3"
    padding_class =
      if is_subtab do
        indent = subtab_style[:indent] || "pl-9"
        "#{indent} pr-3"
      else
        "px-3"
      end

    active_class =
      if active do
        if is_subtab do
          "bg-primary/80 text-primary-content"
        else
          "bg-primary text-primary-content"
        end
      else
        if is_subtab do
          "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        else
          "text-base-content hover:bg-base-200"
        end
      end

    attention_class = attention_animation_class(attention)

    # Add subtab animation class if applicable
    animation_class =
      if is_subtab do
        subtab_animation_class(subtab_style[:animation])
      else
        nil
      end

    [base, padding_class, active_class, attention_class, animation_class, extra_class]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp icon_classes(_active, attention, is_subtab, subtab_style) do
    # Subtabs use configurable icon size, defaults to "w-4 h-4"
    base =
      if is_subtab do
        icon_size = subtab_style[:icon_size] || "w-4 h-4"
        "#{icon_size} shrink-0"
      else
        "w-5 h-5 shrink-0"
      end

    attention_class =
      case attention do
        :glow -> "drop-shadow-[0_0_8px_currentColor]"
        _ -> nil
      end

    [base, attention_class]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # Gets subtab style configuration, merging global defaults with per-tab overrides
  defp get_subtab_style(tab) do
    global_style = PhoenixKit.Config.get(:dashboard_subtab_style, [])

    %{
      indent: tab.subtab_indent || Keyword.get(global_style, :indent, "pl-9"),
      icon_size: tab.subtab_icon_size || Keyword.get(global_style, :icon_size, "w-4 h-4"),
      text_size: tab.subtab_text_size || Keyword.get(global_style, :text_size, "text-sm"),
      animation: tab.subtab_animation || Keyword.get(global_style, :animation, :none)
    }
  end

  defp subtab_animation_class(nil), do: nil
  defp subtab_animation_class(:none), do: nil
  defp subtab_animation_class(:slide), do: "animate-slide-in-left"
  defp subtab_animation_class(:fade), do: "animate-fade-in"
  defp subtab_animation_class(:collapse), do: "animate-collapse-open"
  defp subtab_animation_class(_), do: nil

  defp mobile_tab_classes(active, attention, extra_class) do
    base = "flex flex-col items-center justify-center py-2 px-3 min-w-[4rem] transition-all"

    active_class =
      if active do
        "text-primary"
      else
        "text-base-content/60 hover:text-base-content"
      end

    attention_class = attention_animation_class(attention)

    [base, active_class, attention_class, extra_class]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp mobile_icon_classes(active) do
    base = "w-6 h-6"
    active_class = if active, do: "text-primary", else: ""
    "#{base} #{active_class}"
  end

  defp attention_animation_class(nil), do: nil
  defp attention_animation_class(:pulse), do: "animate-pulse"
  defp attention_animation_class(:bounce), do: "animate-bounce"
  defp attention_animation_class(:shake), do: "animate-shake"
  defp attention_animation_class(:glow), do: "animate-glow"
  defp attention_animation_class(_), do: nil
end
