defmodule PhoenixKit.Widgets.Widget do
  @moduledoc """
  Defines the structure of a dashboard widget.
  """

  defstruct id: nil,
            title: nil,
            description: nil,
            icon: nil,
            component: nil,
            component_props: %{},
            order: 100,
            enabled: true,
            module: nil

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          icon: String.t() | nil,
          component: atom(),
          component_props: map(),
          order: integer(),
          enabled: boolean(),
          module: atom() | nil
        }

  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  def new(list) when is_list(list) do
    new(Map.new(list))
  end
end
