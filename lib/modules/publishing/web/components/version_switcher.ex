defmodule PhoenixKit.Modules.Publishing.Web.Components.VersionSwitcher do
  @moduledoc """
  Version switcher component for publishing posts.

  Displays available versions as a compact inline list with status indicators.
  Used in the publishing editor to navigate between different versions of a post.

  ## Display Format

  Admin mode: v1 (●) | v2 (●) | v3 (○)
  - Green dot (●): Published (this IS the live version)
  - Yellow dot (●): Draft
  - Gray dot (●): Archived
  - Current version is highlighted

  ## Examples

      # Editor: switch between versions
      <.publishing_version_switcher
        versions={@available_versions}
        version_statuses={@version_statuses}
        current_version={@current_version}
        on_click="switch_version"
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc """
  Renders a compact inline version switcher.

  ## Attributes

  - `versions` - List of version numbers (integers)
  - `version_statuses` - Map of version number => status string ("published", "draft", "archived")
  - `version_dates` - Map of version number => ISO 8601 date string (shown in tooltip)
  - `current_version` - Currently active version number
  - `on_click` - Event name for click handler
  - `phx_target` - Target for the event
  - `class` - Additional CSS classes
  - `size` - Size variant: :xs, :sm, :md (default: :sm)

  Note: Only ONE version can have status "published" at a time. This is the live version.
  """
  attr :versions, :list, required: true
  attr :version_statuses, :map, default: %{}
  attr :version_dates, :map, default: %{}
  attr :current_version, :integer, default: nil
  attr :on_click, :string, default: nil
  attr :phx_target, :any, default: nil
  attr :class, :string, default: ""
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md]

  def publishing_version_switcher(assigns) do
    # Sort versions in ascending order
    sorted_versions = Enum.sort(assigns.versions)

    # Determine which version is actually "live" (highest published version)
    # Only ONE version should show as live - the one users will see publicly
    live_version =
      sorted_versions
      |> Enum.filter(fn v -> Map.get(assigns.version_statuses, v) == "published" end)
      |> Enum.max(fn -> nil end)

    assigns =
      assigns
      |> assign(:sorted_versions, sorted_versions)
      |> assign(:live_version, live_version)

    ~H"""
    <div class={["flex items-center flex-wrap", size_gap_class(@size), @class]}>
      <%= for {version, index} <- Enum.with_index(@sorted_versions) do %>
        <%= if index > 0 do %>
          <span class={["text-base-content/30", size_separator_class(@size)]}>|</span>
        <% end %>
        <.version_item
          version={version}
          status={Map.get(@version_statuses, version)}
          date={Map.get(@version_dates, version)}
          is_current={version == @current_version}
          is_live={version == @live_version}
          on_click={@on_click}
          phx_target={@phx_target}
          size={@size}
        />
      <% end %>
    </div>
    """
  end

  attr :version, :integer, required: true
  attr :status, :string, default: nil
  attr :date, :string, default: nil
  attr :is_current, :boolean, default: false
  attr :is_live, :boolean, default: false
  attr :on_click, :string, default: nil
  attr :phx_target, :any, default: nil
  attr :size, :atom, default: :sm

  defp version_item(assigns) do
    ~H"""
    <%= if @on_click do %>
      <button
        type="button"
        phx-click={@on_click}
        phx-value-version={@version}
        phx-target={@phx_target}
        class={item_classes(@is_current, @size)}
        title={version_title(@version, @status, @is_live, @date)}
      >
        <.version_content
          version={@version}
          status={@status}
          is_current={@is_current}
          is_live={@is_live}
          size={@size}
        />
      </button>
    <% else %>
      <span
        class={item_classes(@is_current, @size)}
        title={version_title(@version, @status, @is_live, @date)}
      >
        <.version_content
          version={@version}
          status={@status}
          is_current={@is_current}
          is_live={@is_live}
          size={@size}
        />
      </span>
    <% end %>
    """
  end

  attr :version, :integer, required: true
  attr :status, :string, default: nil
  attr :is_current, :boolean, default: false
  attr :is_live, :boolean, default: false
  attr :size, :atom, default: :sm

  defp version_content(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1">
      <span class={status_dot_classes(@status, @is_live, @size)}></span>
      <span class={code_classes(@is_current, @size)}>
        v{@version}
      </span>
      <%= if @is_live do %>
        <span class="text-xs text-success font-medium">(live)</span>
      <% end %>
    </span>
    """
  end

  # Status dot styling - live = green, published (not live) = blue, draft = yellow, archived = gray
  defp status_dot_classes(status, is_live, size) do
    base = ["rounded-full", "inline-block", dot_size_class(size)]

    color =
      cond do
        is_live -> "bg-success"
        status == "published" -> "bg-info"
        status == "draft" -> "bg-warning"
        status == "archived" -> "bg-base-content/40"
        true -> "bg-base-content/20"
      end

    base ++ [color]
  end

  # Item container classes
  defp item_classes(is_current, size) do
    base = [
      "inline-flex items-center rounded transition-colors",
      size_padding_class(size)
    ]

    state =
      if is_current do
        "bg-primary/10 text-primary font-semibold"
      else
        "hover:bg-base-200 cursor-pointer"
      end

    base ++ [state]
  end

  # Code text classes
  defp code_classes(is_current, size) do
    base = [size_text_class(size)]
    weight = if is_current, do: "font-semibold", else: "font-medium"
    base ++ [weight]
  end

  # Size-based classes
  defp dot_size_class(:xs), do: "w-1.5 h-1.5"
  defp dot_size_class(:sm), do: "w-2 h-2"
  defp dot_size_class(:md), do: "w-2.5 h-2.5"

  defp size_text_class(:xs), do: "text-xs"
  defp size_text_class(:sm), do: "text-sm"
  defp size_text_class(:md), do: "text-base"

  defp size_padding_class(:xs), do: "px-1 py-0.5"
  defp size_padding_class(:sm), do: "px-1.5 py-0.5"
  defp size_padding_class(:md), do: "px-2 py-1"

  defp size_gap_class(:xs), do: "gap-0.5"
  defp size_gap_class(:sm), do: "gap-1"
  defp size_gap_class(:md), do: "gap-1.5"

  defp size_separator_class(:xs), do: "text-xs"
  defp size_separator_class(:sm), do: "text-sm"
  defp size_separator_class(:md), do: "text-base"

  # Generate title/tooltip text
  defp version_title(version, status, is_live, date) do
    status_text =
      cond do
        is_live -> gettext("Published (Live)")
        status == "published" -> gettext("Published")
        status == "draft" -> gettext("Draft")
        status == "archived" -> gettext("Archived")
        true -> gettext("Unknown")
      end

    base = gettext("Version %{version} - %{status}", version: version, status: status_text)

    case format_version_date(date) do
      nil -> base
      formatted_date -> "#{base}\n#{gettext("Created:")} #{formatted_date}"
    end
  end

  # Format ISO 8601 date string for display
  defp format_version_date(nil), do: nil
  defp format_version_date(""), do: nil

  defp format_version_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

      _ ->
        # Try parsing as NaiveDateTime
        case NaiveDateTime.from_iso8601(date_string) do
          {:ok, naive_dt} -> Calendar.strftime(naive_dt, "%Y-%m-%d %H:%M")
          _ -> nil
        end
    end
  end

  defp format_version_date(_), do: nil
end
