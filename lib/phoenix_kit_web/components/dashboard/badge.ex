defmodule PhoenixKitWeb.Components.Dashboard.Badge do
  @moduledoc """
  Badge component for dashboard tab indicators.

  Renders various badge types with support for:
  - Count badges (numeric)
  - Dot indicators
  - Status badges
  - "New" indicators
  - Custom text badges
  - Pulse and other animations
  """

  use Phoenix.Component

  alias PhoenixKit.Dashboard.Badge, as: BadgeStruct

  @doc """
  Renders a dashboard badge.

  ## Attributes

  - `badge` - The Badge struct or nil
  - `class` - Additional CSS classes

  ## Examples

      <.dashboard_badge badge={@tab.badge} />
      <.dashboard_badge badge={Badge.count(5)} />
  """
  attr :badge, :any, default: nil
  attr :class, :string, default: ""

  def dashboard_badge(assigns) do
    ~H"""
    <%= if @badge && BadgeStruct.visible?(@badge) do %>
      <%= case @badge.type do %>
        <% :dot -> %>
          <.dot_badge badge={@badge} class={@class} />
        <% :count -> %>
          <.count_badge badge={@badge} class={@class} />
        <% :status -> %>
          <.status_badge badge={@badge} class={@class} />
        <% :new -> %>
          <.new_badge badge={@badge} class={@class} />
        <% :text -> %>
          <.text_badge badge={@badge} class={@class} />
        <% _ -> %>
          <.count_badge badge={@badge} class={@class} />
      <% end %>
    <% end %>
    """
  end

  @doc """
  Renders a count badge with optional max value display.
  """
  attr :badge, :any, required: true
  attr :class, :string, default: ""

  def count_badge(assigns) do
    value = BadgeStruct.display_value(assigns.badge)
    color_class = BadgeStruct.color_class(assigns.badge)

    assigns =
      assigns
      |> assign(:value, value)
      |> assign(:color_class, color_class)

    ~H"""
    <span
      class={[
        "badge badge-sm",
        @color_class,
        @badge.pulse && "animate-pulse",
        @badge.animate && "transition-all duration-300",
        @class
      ]}
      data-badge-id={@badge.metadata[:tab_id]}
      data-badge-type="count"
    >
      {@value}
    </span>
    """
  end

  @doc """
  Renders a dot indicator badge.
  """
  attr :badge, :any, required: true
  attr :class, :string, default: ""

  def dot_badge(assigns) do
    color_class = BadgeStruct.dot_color_class(assigns.badge)
    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <span
      class={[
        "w-2.5 h-2.5 rounded-full",
        @color_class,
        @badge.pulse && "animate-pulse",
        @class
      ]}
      data-badge-type="dot"
    >
    </span>
    """
  end

  @doc """
  Renders a status badge with value and color.
  """
  attr :badge, :any, required: true
  attr :class, :string, default: ""

  def status_badge(assigns) do
    value = BadgeStruct.display_value(assigns.badge)
    color_class = BadgeStruct.color_class(assigns.badge)

    assigns =
      assigns
      |> assign(:value, value)
      |> assign(:color_class, color_class)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 text-xs font-medium",
        @badge.pulse && "animate-pulse",
        @class
      ]}
      data-badge-type="status"
    >
      <span class={["w-2 h-2 rounded-full", BadgeStruct.dot_color_class(@badge)]}></span>
      <span class={@color_class |> String.replace("badge-", "text-")}>
        {String.capitalize(to_string(@value))}
      </span>
    </span>
    """
  end

  @doc """
  Renders a "New" indicator badge.
  """
  attr :badge, :any, required: true
  attr :class, :string, default: ""

  def new_badge(assigns) do
    color_class = BadgeStruct.color_class(assigns.badge)
    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <span
      class={[
        "badge badge-sm",
        @color_class,
        @badge.pulse && "animate-pulse",
        @class
      ]}
      data-badge-type="new"
    >
      New
    </span>
    """
  end

  @doc """
  Renders a custom text badge.
  """
  attr :badge, :any, required: true
  attr :class, :string, default: ""

  def text_badge(assigns) do
    value = BadgeStruct.display_value(assigns.badge)
    color_class = BadgeStruct.color_class(assigns.badge)

    assigns =
      assigns
      |> assign(:value, value)
      |> assign(:color_class, color_class)

    ~H"""
    <span
      class={[
        "badge badge-sm",
        @color_class,
        @badge.pulse && "animate-pulse",
        @class
      ]}
      data-badge-type="text"
    >
      {@value}
    </span>
    """
  end

  @doc """
  Renders a presence indicator showing user count.
  """
  attr :count, :integer, default: 0
  attr :show_text, :boolean, default: false
  attr :class, :string, default: ""

  def presence_indicator(assigns) do
    ~H"""
    <%= if @count > 0 do %>
      <span
        class={[
          "inline-flex items-center gap-1 text-xs text-base-content/60",
          @class
        ]}
        title={"#{@count} #{if @count == 1, do: "user", else: "users"} viewing"}
      >
        <span class="w-1.5 h-1.5 rounded-full bg-success animate-pulse"></span>
        <%= if @show_text do %>
          <span>{@count}</span>
        <% end %>
      </span>
    <% end %>
    """
  end
end
