defmodule PhoenixKit.DB do
  @moduledoc """
  Database helpers for PhoenixKit.

  Provides metadata, stats, and paginated previews for Postgres tables so the
  admin UI can browse data without exposing full SQL access.

  ## Live Updates

  The DB module supports real-time updates via PostgreSQL LISTEN/NOTIFY.
  When a table is being viewed, changes to that table trigger automatic refreshes.

  This requires:
  1. The `DB.Listener` GenServer running (started via Application supervisor)
  2. A notification trigger on the table being viewed

  Use `ensure_trigger/2` to set up the trigger for a table.
  """

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings

  require Logger

  @module_name "db_explorer"
  @enabled_key "db_explorer_enabled"
  @default_table_page 1
  @default_table_page_size 20
  @default_row_page 1
  @default_row_page_size 50
  @notify_channel "phoenix_kit_db_changes"
  @notify_function_name "phoenix_kit_notify_table_change"
  @trigger_prefix "phoenix_kit_db_change_"

  @textual_types ~w(text character varying character citext json jsonb uuid inet)

  @doc """
  Whether the DB explorer module is enabled.
  """
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  end

  @doc """
  Enable the DB explorer module.
  """
  def enable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, true, @module_name)
  end

  @doc """
  Disable the DB explorer module.
  """
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, @module_name)
  end

  @doc """
  Returns configuration metadata for the admin dashboard card.
  """
  def get_config do
    stats = database_stats()

    %{
      enabled: enabled?(),
      table_count: stats.table_count,
      approx_rows: stats.approx_rows,
      total_size_bytes: stats.total_size_bytes,
      database_size_bytes: stats.database_size_bytes
    }
  end

  @doc """
  Aggregated Postgres stats for all user tables.
  """
  def database_stats do
    sql = """
    SELECT
      COUNT(*) AS table_count,
      COALESCE(SUM(n_live_tup), 0) AS approx_rows,
      COALESCE(SUM(pg_total_relation_size(relid)), 0) AS total_size_bytes,
      pg_database_size(current_database()) AS database_size_bytes
    FROM pg_stat_user_tables
    """

    case RepoHelper.query(sql) do
      {:ok, %{rows: [[table_count, approx_rows, total_size_bytes, db_size]]}} ->
        %{
          table_count: table_count,
          approx_rows: approx_rows,
          total_size_bytes: total_size_bytes,
          database_size_bytes: db_size
        }

      _ ->
        %{
          table_count: 0,
          approx_rows: 0,
          total_size_bytes: 0,
          database_size_bytes: 0
        }
    end
  end

  @doc """
  Lists tables + stats with pagination and search.
  """
  def list_tables(opts \\ %{}) do
    page = normalize_page(Map.get(opts, :page, @default_table_page))
    per_page = normalize_page_size(Map.get(opts, :per_page, @default_table_page_size))
    search = Map.get(opts, :search, "") |> to_string()
    offset = (page - 1) * per_page

    {where_sql, where_params} = table_search_clause(search)

    count_sql = "SELECT COUNT(*) FROM pg_stat_user_tables #{where_sql}"

    total_entries =
      case RepoHelper.query(count_sql, where_params) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end

    list_sql = """
    SELECT schemaname, relname, n_live_tup, pg_total_relation_size(relid)
    FROM pg_stat_user_tables
    #{where_sql}
    ORDER BY schemaname ASC, relname ASC
    LIMIT $#{length(where_params) + 1}
    OFFSET $#{length(where_params) + 2}
    """

    params = where_params ++ [per_page, offset]

    entries =
      case RepoHelper.query(list_sql, params) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [schema, name, approx_rows, size_bytes] ->
            %{
              schema: schema,
              name: name,
              approx_rows: approx_rows,
              size_bytes: size_bytes
            }
          end)

        _ ->
          []
      end

    total_pages = max(div_with_ceiling(total_entries, per_page), 1)

    %{
      entries: entries,
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: total_pages
    }
  end

  @doc """
  Fetches a single row by ID from a table.
  Returns {:ok, row_map} or {:error, :not_found}.
  """
  def fetch_row(schema, table, row_id) when is_binary(table) do
    schema = schema || "public"
    qualified = qualified_table(schema, table)

    # Convert row_id to integer if it's a string
    parsed_id = parse_row_id(row_id)

    if is_nil(parsed_id) do
      {:error, :invalid_id}
    else
      sql = "SELECT * FROM #{qualified} WHERE id = $1 LIMIT 1"

      case RepoHelper.query(sql, [parsed_id]) do
        {:ok, %{columns: columns, rows: [row]}} ->
          row_map =
            columns
            |> Enum.zip(row)
            |> Map.new()

          {:ok, row_map}

        {:ok, %{rows: []}} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_row_id(id) when is_integer(id), do: id

  defp parse_row_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_row_id(_), do: nil

  @doc """
  Returns table metadata and row preview.
  """
  def table_preview(schema, table, opts \\ %{}) when is_binary(table) do
    schema = schema || "public"
    page = normalize_page(Map.get(opts, :page, @default_row_page))
    per_page = normalize_page_size(Map.get(opts, :per_page, @default_row_page_size), 10, 200)
    search = Map.get(opts, :search, "") |> to_string()

    with true <- table_exists?(schema, table),
         columns when is_list(columns) <- fetch_columns(schema, table) do
      {where_clause, search_params} = row_search_clause(search, columns)
      offset = (page - 1) * per_page
      qualified = qualified_table(schema, table)

      count_sql = "SELECT COUNT(*) FROM #{qualified} #{where_clause}"

      total_rows =
        case RepoHelper.query(count_sql, search_params) do
          {:ok, %{rows: [[count]]}} -> count
          _ -> 0
        end

      order_column = if Enum.any?(columns, &(&1.name == "id")), do: "id", else: "ctid"

      select_sql = """
      SELECT * FROM #{qualified}
      #{where_clause}
      ORDER BY #{order_column}
      LIMIT $#{length(search_params) + 1}
      OFFSET $#{length(search_params) + 2}
      """

      params = search_params ++ [per_page, offset]

      rows =
        case RepoHelper.query(select_sql, params) do
          {:ok, %{columns: sql_columns, rows: sql_rows}} ->
            Enum.map(sql_rows, fn row ->
              sql_columns
              |> Enum.zip(row)
              |> Map.new()
            end)

          _ ->
            []
        end

      %{
        schema: schema,
        table: table,
        columns: columns,
        rows: rows,
        row_count: total_rows,
        page: page,
        per_page: per_page,
        total_pages: max(div_with_ceiling(total_rows, per_page), 1),
        approx_rows: get_table_stat(schema, table, :approx_rows),
        size_bytes: get_table_stat(schema, table, :size_bytes)
      }
    else
      _ ->
        %{
          schema: schema,
          table: table,
          columns: [],
          rows: [],
          row_count: 0,
          page: page,
          per_page: per_page,
          total_pages: 1,
          approx_rows: 0,
          size_bytes: 0
        }
    end
  end

  defp fetch_columns(schema, table) do
    sql = """
    SELECT column_name, data_type, is_nullable, ordinal_position
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2
    ORDER BY ordinal_position
    """

    case RepoHelper.query(sql, [schema, table]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, data_type, nullable, position] ->
          %{
            name: name,
            data_type: data_type,
            nullable: nullable == "YES",
            ordinal_position: position
          }
        end)

      _ ->
        []
    end
  end

  defp table_exists?(schema, table) do
    sql = """
    SELECT 1 FROM pg_stat_user_tables
    WHERE schemaname = $1 AND relname = $2
    LIMIT 1
    """

    case RepoHelper.query(sql, [schema, table]) do
      {:ok, %{num_rows: num_rows}} when num_rows > 0 -> true
      _ -> false
    end
  end

  defp get_table_stat(schema, table, field) do
    sql = """
    SELECT n_live_tup, pg_total_relation_size(relid)
    FROM pg_stat_user_tables
    WHERE schemaname = $1 AND relname = $2
    LIMIT 1
    """

    case RepoHelper.query(sql, [schema, table]) do
      {:ok, %{rows: [[approx_rows, size_bytes]]}} ->
        case field do
          :approx_rows -> approx_rows
          :size_bytes -> size_bytes
        end

      _ ->
        0
    end
  end

  defp qualified_table(schema, table) do
    Enum.map_join([schema, table], ".", &quote_ident/1)
  end

  defp quote_ident(name) when is_binary(name) do
    if Regex.match?(~r/^[a-zA-Z0-9_]+$/, name) do
      ~s("#{name}")
    else
      raise ArgumentError, "invalid identifier: #{inspect(name)}"
    end
  end

  defp table_search_clause(""), do: {"", []}

  defp table_search_clause(search) do
    {"WHERE (schemaname ILIKE $1 OR relname ILIKE $1)", ["%" <> search <> "%"]}
  end

  defp row_search_clause("", _columns), do: {"", []}

  defp row_search_clause(search, columns) do
    text_columns =
      Enum.filter(columns, fn column ->
        data_type = String.downcase(column.data_type || "")
        data_type in @textual_types
      end)

    if text_columns == [] do
      {"", []}
    else
      pattern = "%" <> search <> "%"

      clauses =
        text_columns
        |> Enum.with_index(1)
        |> Enum.map(fn {column, idx} ->
          "CAST(#{quote_ident(column.name)} AS TEXT) ILIKE $#{idx}"
        end)

      {
        "WHERE (" <> Enum.join(clauses, " OR ") <> ")",
        List.duplicate(pattern, length(clauses))
      }
    end
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page

  defp normalize_page(page) when is_binary(page) do
    page
    |> Integer.parse()
    |> case do
      {value, _} when value > 0 -> value
      _ -> @default_table_page
    end
  end

  defp normalize_page(_), do: @default_table_page

  defp normalize_page_size(size, min \\ 5, max \\ 100)

  defp normalize_page_size(size, min, max) when is_integer(size) do
    size
    |> max(min)
    |> min(max)
  end

  defp normalize_page_size(size, min, max) when is_binary(size) do
    size
    |> Integer.parse()
    |> case do
      {value, _} -> normalize_page_size(value, min, max)
      _ -> normalize_page_size(@default_table_page_size, min, max)
    end
  end

  defp normalize_page_size(_, min, max),
    do: normalize_page_size(@default_table_page_size, min, max)

  defp div_with_ceiling(0, _per_page), do: 0

  defp div_with_ceiling(total, per_page) when per_page > 0 do
    div(total + per_page - 1, per_page)
  end

  # ============================================================================
  # LIVE UPDATE TRIGGERS
  # ============================================================================

  @doc """
  Ensures the notification function exists and creates a trigger on the table.

  This sets up PostgreSQL LISTEN/NOTIFY for live updates. The trigger fires
  on INSERT, UPDATE, or DELETE and sends a notification to the
  `phoenix_kit_db_changes` channel.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  def ensure_trigger(schema, table) do
    with :ok <- ensure_notify_function() do
      create_table_trigger(schema, table)
    end
  end

  @doc """
  Removes the notification trigger from a table.
  """
  def remove_trigger(schema, table) do
    trigger_name = trigger_name(schema, table)
    qualified = qualified_table(schema, table)

    sql = "DROP TRIGGER IF EXISTS #{trigger_name} ON #{qualified}"

    case RepoHelper.query(sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a table has a notification trigger installed.
  """
  def has_trigger?(schema, table) do
    trigger_name = trigger_name(schema, table)

    sql = """
    SELECT EXISTS (
      SELECT 1 FROM information_schema.triggers
      WHERE trigger_schema = $1
      AND event_object_table = $2
      AND trigger_name = $3
    )
    """

    case RepoHelper.query(sql, [schema, table, trigger_name]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  Lists all tables that have notification triggers installed.
  """
  def list_triggered_tables do
    sql = """
    SELECT trigger_schema, event_object_table
    FROM information_schema.triggers
    WHERE trigger_name LIKE '#{@trigger_prefix}%'
    GROUP BY trigger_schema, event_object_table
    ORDER BY trigger_schema, event_object_table
    """

    case RepoHelper.query(sql) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [schema, table] -> {schema, table} end)

      _ ->
        []
    end
  end

  @doc """
  Removes all notification triggers from all tables.
  """
  def remove_all_triggers do
    list_triggered_tables()
    |> Enum.each(fn {schema, table} -> remove_trigger(schema, table) end)
  end

  # Creates the notification function if it doesn't exist
  defp ensure_notify_function do
    sql = """
    CREATE OR REPLACE FUNCTION #{@notify_function_name}()
    RETURNS trigger AS $$
    DECLARE
      row_id TEXT;
    BEGIN
      -- Try to get the row ID (works for tables with 'id' column)
      IF TG_OP = 'DELETE' THEN
        BEGIN
          row_id := OLD.id::TEXT;
        EXCEPTION WHEN undefined_column THEN
          row_id := '';
        END;
      ELSE
        BEGIN
          row_id := NEW.id::TEXT;
        EXCEPTION WHEN undefined_column THEN
          row_id := '';
        END;
      END IF;

      -- Payload format: schema.table:operation:row_id
      PERFORM pg_notify('#{@notify_channel}', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME || ':' || TG_OP || ':' || COALESCE(row_id, ''));

      -- AFTER triggers ignore return value, but we return appropriately for completeness
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      ELSE
        RETURN NEW;
      END IF;
    END;
    $$ LANGUAGE plpgsql;
    """

    case RepoHelper.query(sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Creates a trigger on a specific table
  defp create_table_trigger(schema, table) do
    trigger_name = trigger_name(schema, table)
    qualified = qualified_table(schema, table)

    # First check if trigger already exists
    if has_trigger?(schema, table) do
      :ok
    else
      sql = """
      CREATE TRIGGER #{trigger_name}
      AFTER INSERT OR UPDATE OR DELETE ON #{qualified}
      FOR EACH ROW
      EXECUTE FUNCTION #{@notify_function_name}();
      """

      case RepoHelper.query(sql) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp trigger_name(schema, table) do
    # Sanitize for use in trigger name
    safe_schema = String.replace(schema, ~r/[^a-zA-Z0-9_]/, "_")
    safe_table = String.replace(table, ~r/[^a-zA-Z0-9_]/, "_")
    "#{@trigger_prefix}#{safe_schema}_#{safe_table}"
  end
end
