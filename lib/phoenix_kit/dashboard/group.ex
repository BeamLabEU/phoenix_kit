defmodule PhoenixKit.Dashboard.Group do
  @moduledoc """
  Struct representing a dashboard tab group.

  Groups organize tabs in the dashboard sidebar. Each group has an ID,
  an optional label, and a priority for ordering.

  ## Fields

  - `id` - Unique group identifier atom (e.g., `:admin_main`, `:shop`)
  - `label` - Optional display label (nil for unlabeled groups)
  - `priority` - Sort priority (lower = first, default: 100)
  - `icon` - Optional heroicon name (e.g., `"hero-cube"`)
  - `collapsible` - Whether the group can be collapsed in the sidebar
  """

  @enforce_keys [:id]
  defstruct [:id, :label, :icon, priority: 100, collapsible: false]

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t() | nil,
          priority: integer(),
          icon: String.t() | nil,
          collapsible: boolean()
        }

  @doc """
  Creates a new group from a map or keyword list.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: attrs[:id] || attrs["id"],
      label: attrs[:label] || attrs["label"],
      priority: attrs[:priority] || attrs["priority"] || 100,
      icon: attrs[:icon] || attrs["icon"],
      collapsible: attrs[:collapsible] || attrs["collapsible"] || false
    }
  end

  def new(attrs) when is_list(attrs) do
    %__MODULE__{
      id: Keyword.fetch!(attrs, :id),
      label: Keyword.get(attrs, :label),
      priority: Keyword.get(attrs, :priority, 100),
      icon: Keyword.get(attrs, :icon),
      collapsible: Keyword.get(attrs, :collapsible, false)
    }
  end
end
