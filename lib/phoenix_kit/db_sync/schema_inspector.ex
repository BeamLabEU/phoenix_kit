defmodule PhoenixKit.DBSync.SchemaInspector do
  @moduledoc """
  Inspects database schema for DB Sync module.

  Discovers available tables, their columns, and metadata.
  Uses PostgreSQL information_schema for introspection.

  ## Security Considerations

  - Only returns tables in the public schema by default
  - System tables (pg_*, information_schema) are excluded
  - Admin can configure allowed/blocked tables (future feature)

  ## Example

      iex> SchemaInspector.list_tables()
      {:ok, [
        %{name: "users", estimated_count: 150},
        %{name: "posts", estimated_count: 1200},
        ...
      ]}

      iex> SchemaInspector.get_schema("users")
      {:ok, %{
        table: "users",
        columns: [
          %{name: "id", type: "bigint", nullable: false, primary_key: true},
          %{name: "email", type: "character varying", nullable: false},
          ...
        ],
        primary_key: ["id"]
      }}
  """

  alias PhoenixKit.RepoHelper

  # Tables to always exclude from sync
  @excluded_tables [
    # Ecto/Phoenix internal tables
    "schema_migrations",
    # Oban internal tables
    "oban_jobs",
    "oban_peers",
    "oban_producers",
    # Session/token tables (security sensitive)
    "phoenix_kit_user_tokens"
  ]

  # Prefixes for tables to exclude
  @excluded_prefixes [
    "pg_",
    "oban_"
  ]

  @doc """
  Lists all available tables with row counts.

  Returns tables from the public schema, excluding system tables
  and security-sensitive tables.

  ## Options

  - `:include_phoenix_kit` - Include phoenix_kit_* tables (default: true)
  - `:schema` - Database schema to inspect (default: "public")
  - `:exact_counts` - Use exact COUNT(*) instead of pg_stat estimates (default: true)
  """
  @spec list_tables(keyword()) :: {:ok, [map()]} | {:error, any()}
  def list_tables(opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")
    include_phoenix_kit = Keyword.get(opts, :include_phoenix_kit, true)
    exact_counts = Keyword.get(opts, :exact_counts, true)

    # First get the list of tables
    tables_query = """
    SELECT t.tablename as name
    FROM pg_catalog.pg_tables t
    WHERE t.schemaname = $1
    ORDER BY t.tablename
    """

    case RepoHelper.query(tables_query, [schema]) do
      {:ok, %{rows: rows}} ->
        tables =
          rows
          |> Enum.map(fn [name] -> name end)
          |> Enum.reject(fn name -> excluded_table?(name, include_phoenix_kit) end)
          |> Enum.map(fn name ->
            count =
              if exact_counts do
                get_exact_count(name, schema)
              else
                get_estimated_count(name, schema)
              end

            %{name: name, estimated_count: count}
          end)

        {:ok, tables}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_exact_count(table_name, schema) do
    if valid_identifier?(table_name) and valid_identifier?(schema) do
      query = "SELECT COUNT(*) FROM \"#{schema}\".\"#{table_name}\""

      case RepoHelper.query(query, []) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end
    else
      0
    end
  end

  defp get_estimated_count(table_name, schema) do
    query = """
    SELECT COALESCE(n_live_tup, 0)
    FROM pg_catalog.pg_stat_user_tables
    WHERE relname = $1 AND schemaname = $2
    """

    case RepoHelper.query(query, [table_name, schema]) do
      {:ok, %{rows: [[count]]}} -> count || 0
      _ -> 0
    end
  end

  @doc """
  Gets the schema (columns, types, constraints) for a specific table.

  ## Returns

  - `{:ok, schema}` - Map with table info and columns
  - `{:error, :not_found}` - Table doesn't exist
  - `{:error, reason}` - Database error
  """
  @spec get_schema(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def get_schema(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")

    # First check if table exists
    exists_query = """
    SELECT EXISTS (
      SELECT FROM pg_catalog.pg_tables
      WHERE schemaname = $1 AND tablename = $2
    )
    """

    case RepoHelper.query(exists_query, [schema, table_name]) do
      {:ok, %{rows: [[true]]}} ->
        fetch_table_schema(table_name, schema)

      {:ok, %{rows: [[false]]}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the primary key columns for a table.
  """
  @spec get_primary_key(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, any()}
  def get_primary_key(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")

    query = """
    SELECT a.attname
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE i.indisprimary
      AND c.relname = $1
      AND n.nspname = $2
    ORDER BY array_position(i.indkey, a.attnum)
    """

    case RepoHelper.query(query, [table_name, schema]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [col] -> col end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if a table exists.
  """
  @spec table_exists?(String.t(), keyword()) :: boolean()
  def table_exists?(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")

    query = """
    SELECT EXISTS (
      SELECT FROM pg_catalog.pg_tables
      WHERE schemaname = $1 AND tablename = $2
    )
    """

    case RepoHelper.query(query, [schema, table_name]) do
      {:ok, %{rows: [[exists]]}} -> exists
      _ -> false
    end
  end

  @doc """
  Creates a table based on a schema definition from another database.

  Used by DB Sync to create tables that exist on sender but not on receiver.

  ## Parameters

  - `table_name` - Name of the table to create
  - `schema_def` - Schema definition map with columns and primary_key

  ## Example

      schema_def = %{
        "columns" => [
          %{"name" => "id", "type" => "bigint", "nullable" => false, "primary_key" => true},
          %{"name" => "name", "type" => "character varying", "nullable" => true}
        ],
        "primary_key" => ["id"]
      }
      SchemaInspector.create_table("users", schema_def)
  """
  @spec create_table(String.t(), map(), keyword()) :: :ok | {:error, any()}
  def create_table(table_name, schema_def, opts \\ []) do
    db_schema = Keyword.get(opts, :schema, "public")

    if valid_identifier?(table_name) do
      columns = Map.get(schema_def, "columns") || Map.get(schema_def, :columns) || []
      primary_key = Map.get(schema_def, "primary_key") || Map.get(schema_def, :primary_key) || []

      column_defs = Enum.map_join(columns, ",\n  ", &column_to_sql/1)

      pk_constraint =
        if primary_key != [] do
          pk_cols = Enum.join(primary_key, ", ")
          ",\n  PRIMARY KEY (#{pk_cols})"
        else
          ""
        end

      query = """
      CREATE TABLE "#{db_schema}"."#{table_name}" (
        #{column_defs}#{pk_constraint}
      )
      """

      case RepoHelper.query(query, []) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_table_name}
    end
  end

  defp column_to_sql(column) do
    name = column["name"] || column[:name]
    type = map_column_type(column["type"] || column[:type])
    nullable = column["nullable"] || column[:nullable]

    null_constraint = if nullable, do: "", else: " NOT NULL"

    # Handle auto-increment for bigint primary keys
    type_with_serial =
      if (column["primary_key"] || column[:primary_key]) and type in ["bigint", "integer"] do
        if type == "bigint", do: "bigserial", else: "serial"
      else
        type
      end

    "\"#{name}\" #{type_with_serial}#{null_constraint}"
  end

  defp map_column_type("character varying"), do: "varchar(255)"

  defp map_column_type("character varying(" <> rest),
    do: "varchar(#{String.trim_trailing(rest, ")")}"

  defp map_column_type("timestamp without time zone"), do: "timestamp"
  defp map_column_type("timestamp with time zone"), do: "timestamptz"
  defp map_column_type(type), do: type

  @doc """
  Gets the exact count of records in a local table.

  This is used by the receiver to compare local vs sender record counts.
  """
  @spec get_local_count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def get_local_count(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")

    # Sanitize table name to prevent SQL injection
    if valid_identifier?(table_name) and valid_identifier?(schema) do
      query = "SELECT COUNT(*) FROM \"#{schema}\".\"#{table_name}\""

      case RepoHelper.query(query, []) do
        {:ok, %{rows: [[count]]}} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_identifier}
    end
  end

  defp valid_identifier?(name) when is_binary(name) do
    # Only allow alphanumeric and underscores, must start with letter or underscore
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name)
  end

  defp valid_identifier?(_), do: false

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp fetch_table_schema(table_name, schema) do
    columns_query = """
    SELECT
      c.column_name,
      c.data_type,
      c.is_nullable = 'YES' as nullable,
      c.column_default,
      c.character_maximum_length,
      c.numeric_precision,
      c.numeric_scale
    FROM information_schema.columns c
    WHERE c.table_schema = $1
      AND c.table_name = $2
    ORDER BY c.ordinal_position
    """

    with {:ok, %{rows: column_rows}} <- RepoHelper.query(columns_query, [schema, table_name]),
         {:ok, primary_key} <- get_primary_key(table_name, schema: schema) do
      columns =
        Enum.map(column_rows, fn [name, type, nullable, default, max_len, precision, scale] ->
          column = %{
            name: name,
            type: type,
            nullable: nullable,
            primary_key: name in primary_key
          }

          column
          |> maybe_add(:default, default)
          |> maybe_add(:max_length, max_len)
          |> maybe_add(:precision, precision)
          |> maybe_add(:scale, scale)
        end)

      {:ok,
       %{
         table: table_name,
         schema: schema,
         columns: columns,
         primary_key: primary_key
       }}
    end
  end

  defp excluded_table?(name, include_phoenix_kit) do
    cond do
      name in @excluded_tables ->
        true

      Enum.any?(@excluded_prefixes, &String.starts_with?(name, &1)) ->
        true

      not include_phoenix_kit and String.starts_with?(name, "phoenix_kit_") ->
        true

      true ->
        false
    end
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)
end
