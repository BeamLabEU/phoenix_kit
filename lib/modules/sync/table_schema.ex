defmodule PhoenixKit.Modules.Sync.TableSchema do
  @moduledoc """
  Struct representing a database table's schema information.

  Returned by `SchemaInspector.fetch_table_schema/2` and consumed by
  `DataImporter`, `DataExporter`, sync LiveViews, and the wire protocol.

  ## Fields

  - `table` - Table name
  - `schema` - PostgreSQL schema (e.g., `"public"`)
  - `columns` - List of `ColumnInfo` structs
  - `primary_key` - List of primary key column names
  """

  alias PhoenixKit.Modules.Sync.ColumnInfo

  @enforce_keys [:table, :schema]
  defstruct [:table, :schema, columns: [], primary_key: []]

  @type t :: %__MODULE__{
          table: String.t(),
          schema: String.t(),
          columns: [ColumnInfo.t()],
          primary_key: [String.t()]
        }
end
