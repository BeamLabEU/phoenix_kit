defmodule PhoenixKit.Modules.Shop.ShopConfig do
  @moduledoc """
  Shop configuration storage schema (key-value JSONB).

  Used for storing global Shop module settings like:
  - `global_attribute_schema` - Global product attribute definitions

  ## Attribute Schema Format

      %{
        "key" => "material",
        "label" => "Material",
        "type" => "select",
        "options" => ["PLA", "ABS", "PETG"],
        "default" => "PLA",
        "required" => false,
        "unit" => nil,
        "position" => 0
      }

  Supported types: `text`, `number`, `boolean`, `select`, `multiselect`
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "phoenix_kit_shop_config" do
    field :value, :map

    timestamps()
  end

  @doc """
  Changeset for shop configuration.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> validate_length(:key, max: 100)
  end
end
