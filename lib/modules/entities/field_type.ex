defmodule PhoenixKit.Modules.Entities.FieldType do
  @moduledoc """
  Struct representing an entity field type definition.

  ## Fields

  - `name` - Field type identifier (e.g., `"text"`, `"select"`)
  - `label` - Human-readable label (e.g., `"Text"`, `"Select Dropdown"`)
  - `description` - Short description of the field type
  - `category` - Category atom (`:basic`, `:numeric`, `:boolean`, `:datetime`, `:choice`, `:advanced`)
  - `icon` - Heroicon name for rendering
  - `requires_options` - Whether the field type requires options to be defined
  - `default_props` - Default properties for new fields of this type
  """

  @enforce_keys [:name, :label, :category]
  defstruct [
    :name,
    :label,
    :description,
    :category,
    :icon,
    requires_options: false,
    default_props: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          description: String.t() | nil,
          category: :basic | :numeric | :boolean | :datetime | :choice | :advanced,
          icon: String.t() | nil,
          requires_options: boolean(),
          default_props: map()
        }

  @doc """
  Converts a plain map to a `%FieldType{}` struct.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map[:name] || map["name"],
      label: map[:label] || map["label"],
      description: map[:description] || map["description"],
      category: map[:category] || map["category"],
      icon: map[:icon] || map["icon"],
      requires_options: map[:requires_options] || map["requires_options"] || false,
      default_props: map[:default_props] || map["default_props"] || %{}
    }
  end
end
