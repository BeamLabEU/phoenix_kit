defmodule PhoenixKit.Modules.Sync.DataExporter do
  @moduledoc """
  Exports data from database tables for DB Sync module.

  Provides functions to fetch records from tables with pagination,
  handle data serialization, and stream large datasets.

  ## Security Considerations

  - Uses parameterized queries to prevent SQL injection
  - Validates table names against actual database tables
  - Respects configured table whitelist/blacklist (future feature)

  ## Example

      iex> DataExporter.get_count("users")
      {:ok, 150}

      iex> DataExporter.fetch_records("users", offset: 0, limit: 100)
      {:ok, [
        %{"id" => 1, "email" => "user@example.com", ...},
        ...
      ]}
  """

  alias PhoenixKit.Modules.Sync.SchemaInspector
  alias PhoenixKit.RepoHelper

  @default_limit 100
  @max_limit 1000

  @doc """
  Gets the exact count of records in a table.

  ## Options

  - `:schema` - Database schema (default: "public")
  """
  @spec get_count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def get_count(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")

    # Validate table exists first
    if SchemaInspector.table_exists?(table_name, schema: schema) do
      # Use exact count for accuracy
      # For very large tables, consider using estimated count from pg_stat
      query = "SELECT COUNT(*) FROM #{quote_identifier(schema)}.#{quote_identifier(table_name)}"

      case RepoHelper.query(query, []) do
        {:ok, %{rows: [[count]]}} ->
          {:ok, count}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :table_not_found}
    end
  end

  @doc """
  Fetches records from a table with pagination.

  Records are returned as maps with string keys matching column names.
  All values are JSON-serializable.

  ## Options

  - `:offset` - Number of records to skip (default: 0)
  - `:limit` - Maximum records to return (default: 100, max: 1000)
  - `:schema` - Database schema (default: "public")
  - `:order_by` - Column(s) to order by (default: primary key)
  """
  @spec fetch_records(String.t(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def fetch_records(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)

    # Validate table exists and get schema info
    case SchemaInspector.get_schema(table_name, schema: schema) do
      {:ok, table_schema} ->
        do_fetch_records(table_name, schema, table_schema, offset, limit, opts)

      {:error, :not_found} ->
        {:error, :table_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports all records from a table as a stream.

  Useful for large tables where loading all records into memory
  is not practical. Returns a stream that yields batches of records.

  ## Options

  - `:batch_size` - Records per batch (default: 500)
  - `:schema` - Database schema (default: "public")
  """
  @spec stream_records(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, any()}
  def stream_records(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")
    batch_size = Keyword.get(opts, :batch_size, 500)

    case SchemaInspector.get_schema(table_name, schema: schema) do
      {:ok, table_schema} ->
        stream =
          Stream.resource(
            fn -> 0 end,
            fn offset ->
              case do_fetch_records(table_name, schema, table_schema, offset, batch_size, opts) do
                {:ok, []} ->
                  {:halt, offset}

                {:ok, records} ->
                  {[records], offset + length(records)}

                {:error, _reason} ->
                  {:halt, offset}
              end
            end,
            fn _offset -> :ok end
          )

        {:ok, stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp do_fetch_records(table_name, schema, table_schema, offset, limit, opts) do
    columns = Enum.map(table_schema.columns, & &1.name)
    order_by = Keyword.get(opts, :order_by) || table_schema.primary_key

    # Build column list for SELECT
    column_list = Enum.map_join(columns, ", ", &quote_identifier/1)

    # Build ORDER BY clause
    order_clause = build_order_clause(order_by)

    query = """
    SELECT #{column_list}
    FROM #{quote_identifier(schema)}.#{quote_identifier(table_name)}
    #{order_clause}
    LIMIT $1 OFFSET $2
    """

    case RepoHelper.query(query, [limit, offset]) do
      {:ok, %{rows: rows}} ->
        records =
          Enum.map(rows, fn row ->
            columns
            |> Enum.zip(row)
            |> Enum.map(fn {col, val} -> {col, serialize_value(val)} end)
            |> Map.new()
          end)

        {:ok, records}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_order_clause([]), do: ""

  defp build_order_clause(columns) when is_list(columns) do
    order_cols = Enum.map_join(columns, ", ", &quote_identifier/1)
    "ORDER BY #{order_cols}"
  end

  defp build_order_clause(column) when is_binary(column) do
    "ORDER BY #{quote_identifier(column)}"
  end

  # Quote identifier to prevent SQL injection
  # PostgreSQL uses double quotes for identifiers
  defp quote_identifier(name) when is_binary(name) do
    # Escape any double quotes in the identifier
    escaped = String.replace(name, "\"", "\"\"")
    "\"#{escaped}\""
  end

  # Serialize values to JSON-compatible format
  defp serialize_value(nil), do: nil
  defp serialize_value(value) when is_binary(value), do: value
  defp serialize_value(value) when is_number(value), do: value
  defp serialize_value(value) when is_boolean(value), do: value
  defp serialize_value(value) when is_list(value), do: Enum.map(value, &serialize_value/1)
  defp serialize_value(value) when is_map(value), do: serialize_map(value)

  defp serialize_value(%Date{} = date), do: Date.to_iso8601(date)
  defp serialize_value(%Time{} = time), do: Time.to_iso8601(time)
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp serialize_value(%Decimal{} = decimal), do: Decimal.to_string(decimal)

  # Handle Ecto types
  defp serialize_value(%{__struct__: _} = struct) do
    if function_exported?(struct.__struct__, :to_string, 1) do
      to_string(struct)
    else
      inspect(struct)
    end
  end

  # Fallback for other types
  defp serialize_value(value), do: inspect(value)

  defp serialize_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end
end
