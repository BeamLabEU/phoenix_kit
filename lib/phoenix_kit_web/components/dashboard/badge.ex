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
        <% :compound -> %>
          <.compound_badge badge={@badge} class={@class} />
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
  Renders a compound badge with multiple colored segments.

  Supports three styles:
  - `:text` - Colored text values with separator (default)
  - `:blocks` - Colored background pills side by side
  - `:dots` - Colored dots with numbers
  """
  attr :badge, :any, required: true
  attr :class, :string, default: ""

  def compound_badge(assigns) do
    segments = BadgeStruct.visible_segments(assigns.badge)
    style = assigns.badge.compound_style || :text
    separator = assigns.badge.separator || "/"

    assigns =
      assigns
      |> assign(:segments, segments)
      |> assign(:style, style)
      |> assign(:separator, separator)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1",
        @badge.pulse && "animate-pulse",
        @class
      ]}
      data-badge-type="compound"
      data-badge-style={@style}
    >
      <%= case @style do %>
        <% :text -> %>
          <.compound_text_style segments={@segments} separator={@separator} />
        <% :blocks -> %>
          <.compound_blocks_style segments={@segments} />
        <% :dots -> %>
          <.compound_dots_style segments={@segments} />
        <% _ -> %>
          <.compound_text_style segments={@segments} separator={@separator} />
      <% end %>
    </span>
    """
  end

  # Text style: "10 / 5 / 2" with colored text
  defp compound_text_style(assigns) do
    ~H"""
    <%= for {segment, index} <- Enum.with_index(@segments) do %>
      <%= if index > 0 do %>
        <span class="text-base-content/40 text-xs">{@separator}</span>
      <% end %>
      <span class={["text-xs font-medium", text_color_class(segment[:color] || segment["color"])]}>
        {segment[:value] || segment["value"]}
        <%= if segment[:label] || segment["label"] do %>
          <span class="opacity-70 ml-0.5">{segment[:label] || segment["label"]}</span>
        <% end %>
      </span>
    <% end %>
    """
  end

  # Blocks style: colored background pills
  defp compound_blocks_style(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-lg overflow-hidden">
      <%= for segment <- @segments do %>
        <span class={[
          "px-1.5 py-0.5 text-xs font-medium",
          block_color_class(segment[:color] || segment["color"])
        ]}>
          {segment[:value] || segment["value"]}
        </span>
      <% end %>
    </span>
    """
  end

  # Dots style: colored dots with numbers
  defp compound_dots_style(assigns) do
    ~H"""
    <%= for segment <- @segments do %>
      <span class="inline-flex items-center gap-0.5">
        <span class={[
          "w-2 h-2 rounded-full",
          dot_color_class_for_segment(segment[:color] || segment["color"])
        ]}>
        </span>
        <span class="text-xs text-base-content/70">
          {segment[:value] || segment["value"]}
        </span>
      </span>
    <% end %>
    """
  end

  # Text color classes for compound badge text style
  defp text_color_class(:primary), do: "text-primary"
  defp text_color_class(:secondary), do: "text-secondary"
  defp text_color_class(:accent), do: "text-accent"
  defp text_color_class(:info), do: "text-info"
  defp text_color_class(:success), do: "text-success"
  defp text_color_class(:warning), do: "text-warning"
  defp text_color_class(:error), do: "text-error"
  defp text_color_class(:neutral), do: "text-neutral"
  defp text_color_class(:base), do: "text-base-content"
  defp text_color_class("primary"), do: "text-primary"
  defp text_color_class("secondary"), do: "text-secondary"
  defp text_color_class("accent"), do: "text-accent"
  defp text_color_class("info"), do: "text-info"
  defp text_color_class("success"), do: "text-success"
  defp text_color_class("warning"), do: "text-warning"
  defp text_color_class("error"), do: "text-error"
  defp text_color_class("neutral"), do: "text-neutral"
  defp text_color_class("base"), do: "text-base-content"
  defp text_color_class(_), do: "text-base-content"

  # Block color classes (background + text) for compound badge blocks style
  defp block_color_class(:primary), do: "bg-primary text-primary-content"
  defp block_color_class(:secondary), do: "bg-secondary text-secondary-content"
  defp block_color_class(:accent), do: "bg-accent text-accent-content"
  defp block_color_class(:info), do: "bg-info text-info-content"
  defp block_color_class(:success), do: "bg-success text-success-content"
  defp block_color_class(:warning), do: "bg-warning text-warning-content"
  defp block_color_class(:error), do: "bg-error text-error-content"
  defp block_color_class(:neutral), do: "bg-neutral text-neutral-content"
  defp block_color_class(:base), do: "bg-base-300 text-base-content"
  defp block_color_class("primary"), do: "bg-primary text-primary-content"
  defp block_color_class("secondary"), do: "bg-secondary text-secondary-content"
  defp block_color_class("accent"), do: "bg-accent text-accent-content"
  defp block_color_class("info"), do: "bg-info text-info-content"
  defp block_color_class("success"), do: "bg-success text-success-content"
  defp block_color_class("warning"), do: "bg-warning text-warning-content"
  defp block_color_class("error"), do: "bg-error text-error-content"
  defp block_color_class("neutral"), do: "bg-neutral text-neutral-content"
  defp block_color_class("base"), do: "bg-base-300 text-base-content"
  defp block_color_class(_), do: "bg-base-300 text-base-content"

  # Dot color classes for compound badge dots style
  defp dot_color_class_for_segment(:primary), do: "bg-primary"
  defp dot_color_class_for_segment(:secondary), do: "bg-secondary"
  defp dot_color_class_for_segment(:accent), do: "bg-accent"
  defp dot_color_class_for_segment(:info), do: "bg-info"
  defp dot_color_class_for_segment(:success), do: "bg-success"
  defp dot_color_class_for_segment(:warning), do: "bg-warning"
  defp dot_color_class_for_segment(:error), do: "bg-error"
  defp dot_color_class_for_segment(:neutral), do: "bg-neutral"
  defp dot_color_class_for_segment(:base), do: "bg-base-300"
  defp dot_color_class_for_segment("primary"), do: "bg-primary"
  defp dot_color_class_for_segment("secondary"), do: "bg-secondary"
  defp dot_color_class_for_segment("accent"), do: "bg-accent"
  defp dot_color_class_for_segment("info"), do: "bg-info"
  defp dot_color_class_for_segment("success"), do: "bg-success"
  defp dot_color_class_for_segment("warning"), do: "bg-warning"
  defp dot_color_class_for_segment("error"), do: "bg-error"
  defp dot_color_class_for_segment("neutral"), do: "bg-neutral"
  defp dot_color_class_for_segment("base"), do: "bg-base-300"
  defp dot_color_class_for_segment(_), do: "bg-base-300"

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
