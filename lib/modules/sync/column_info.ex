defmodule PhoenixKit.Modules.Sync.ColumnInfo do
  @moduledoc """
  Struct representing a single database column's metadata.

  ## Fields

  - `name` - Column name
  - `type` - PostgreSQL data type (e.g., `"bigint"`, `"text"`)
  - `nullable` - Whether the column allows NULL values
  - `primary_key` - Whether the column is part of the primary key
  - `default` - Default value expression or nil
  - `max_length` - Maximum character length or nil
  - `precision` - Numeric precision or nil
  - `scale` - Numeric scale or nil
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :default,
    :max_length,
    :precision,
    :scale,
    nullable: false,
    primary_key: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          nullable: boolean(),
          primary_key: boolean(),
          default: String.t() | nil,
          max_length: integer() | nil,
          precision: integer() | nil,
          scale: integer() | nil
        }
end
