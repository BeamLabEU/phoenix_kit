defmodule PhoenixKit.DBSync.DataImporter do
  @moduledoc """
  Handles import of records from remote sender with conflict resolution.

  This module is responsible for importing records received from a sender
  into the local database, handling primary key conflicts according to
  the configured strategy.

  ## Conflict Strategies

  - `:skip` - Skip import if record with same primary key exists (default)
  - `:overwrite` - Replace existing record with imported data
  - `:merge` - Merge imported data with existing record (keeps existing values where new is nil)
  - `:append` - Always insert as new record with auto-generated ID (ignores source primary key)

  ## Usage

      # Import a batch of records with a strategy
      {:ok, result} = DataImporter.import_records("users", records, :skip)

      # Result structure:
      %{
        created: 5,
        updated: 2,
        skipped: 3,
        errors: []
      }
  """

  alias PhoenixKit.DBSync.SchemaInspector
  alias PhoenixKit.RepoHelper

  require Logger

  @type conflict_strategy :: :skip | :overwrite | :merge | :append
  @type import_result :: %{
          created: non_neg_integer(),
          updated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: list()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Imports a batch of records into the specified table.

  ## Parameters

  - `table` - The table name to import into
  - `records` - List of record maps from the sender
  - `strategy` - Conflict resolution strategy (`:skip`, `:overwrite`, `:merge`, `:append`)

  ## Returns

  - `{:ok, result}` with counts and any errors
  - `{:error, reason}` if import fails completely
  """
  @spec import_records(String.t(), list(map()), conflict_strategy()) ::
          {:ok, import_result()} | {:error, term()}
  def import_records(table, records, strategy \\ :skip) when is_list(records) do
    repo = RepoHelper.repo()

    with {:ok, schema} <- SchemaInspector.get_schema(table),
         primary_keys <- get_primary_keys(schema) do
      result =
        records
        |> Enum.reduce(%{created: 0, updated: 0, skipped: 0, errors: []}, fn record, acc ->
          case import_single_record(repo, table, record, primary_keys, strategy) do
            {:ok, :created} -> %{acc | created: acc.created + 1}
            {:ok, :updated} -> %{acc | updated: acc.updated + 1}
            {:ok, :skipped} -> %{acc | skipped: acc.skipped + 1}
            {:error, reason} -> %{acc | errors: [{record, reason} | acc.errors]}
          end
        end)

      {:ok, %{result | errors: Enum.reverse(result.errors)}}
    end
  end

  @doc """
  Imports records for multiple tables in a single operation.

  ## Parameters

  - `table_records` - Map of table name to records list
  - `strategies` - Map of table name to conflict strategy

  ## Returns

  - `{:ok, %{table_name => result}}`
  """
  @spec import_multiple(map(), map()) :: {:ok, map()} | {:error, term()}
  def import_multiple(table_records, strategies \\ %{}) when is_map(table_records) do
    results =
      table_records
      |> Enum.map(fn {table, records} ->
        strategy = Map.get(strategies, table, :skip)

        case import_records(table, records, strategy) do
          {:ok, result} -> {table, result}
          {:error, reason} -> {table, %{created: 0, updated: 0, skipped: 0, errors: [reason]}}
        end
      end)
      |> Map.new()

    {:ok, results}
  end

  # ============================================================================
  # Single Record Import
  # ============================================================================

  defp import_single_record(repo, table, record, primary_keys, :append) do
    # For append strategy: strip primary keys and insert as new record
    record = prepare_record(record)
    record_without_pk = Map.drop(record, primary_keys)
    insert_record(repo, table, record_without_pk)
  rescue
    e ->
      Logger.warning("DataImporter: Error importing record - #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  defp import_single_record(repo, table, record, primary_keys, strategy) do
    # Prepare the record with proper types
    record = prepare_record(record)

    case find_existing(repo, table, record, primary_keys) do
      nil ->
        insert_record(repo, table, record)

      existing ->
        handle_conflict(repo, table, existing, record, primary_keys, strategy)
    end
  rescue
    e ->
      Logger.warning("DataImporter: Error importing record - #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  defp find_existing(_repo, _table, _record, []) do
    # No primary keys, can't find existing record
    nil
  end

  defp find_existing(repo, table, record, primary_keys) do
    # Build WHERE clause for primary key match
    conditions =
      primary_keys
      |> Enum.map(fn pk ->
        value = Map.get(record, pk) || Map.get(record, String.to_atom(pk))

        if is_nil(value) do
          nil
        else
          "#{pk} = #{escape_value(value)}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(conditions) do
      nil
    else
      where_clause = Enum.join(conditions, " AND ")
      query = "SELECT * FROM #{table} WHERE #{where_clause} LIMIT 1"

      case repo.query(query) do
        {:ok, %{rows: [row], columns: columns}} ->
          Enum.zip(columns, row) |> Map.new()

        _ ->
          nil
      end
    end
  end

  defp insert_record(repo, table, record) do
    columns = Map.keys(record) |> Enum.map(&to_string/1)
    values = Map.values(record) |> Enum.map(&escape_value/1)

    query = """
    INSERT INTO #{table} (#{Enum.join(columns, ", ")})
    VALUES (#{Enum.join(values, ", ")})
    """

    case repo.query(query) do
      {:ok, _} -> {:ok, :created}
      {:error, error} -> {:error, format_error(error)}
    end
  end

  defp handle_conflict(_repo, _table, _existing, _record, _primary_keys, :skip) do
    {:ok, :skipped}
  end

  defp handle_conflict(repo, table, existing, record, primary_keys, :overwrite) do
    update_record(repo, table, record, primary_keys, existing)
  end

  defp handle_conflict(repo, table, existing, record, primary_keys, :merge) do
    # Merge: keep existing values where new is nil
    merged =
      record
      |> Enum.reduce(existing, fn {key, value}, acc ->
        key_str = to_string(key)

        if is_nil(value) do
          acc
        else
          Map.put(acc, key_str, value)
        end
      end)

    update_record(repo, table, merged, primary_keys, existing)
  end

  defp update_record(repo, table, record, primary_keys, existing) do
    # Build SET clause (exclude primary keys)
    set_parts =
      record
      |> Enum.reject(fn {key, _} -> to_string(key) in primary_keys end)
      |> Enum.map(fn {key, value} -> "#{key} = #{escape_value(value)}" end)

    if Enum.empty?(set_parts) do
      # Nothing to update
      {:ok, :skipped}
    else
      # Build WHERE clause using primary keys from existing record
      where_parts =
        primary_keys
        |> Enum.map(fn pk ->
          value = Map.get(existing, pk)
          "#{pk} = #{escape_value(value)}"
        end)

      query = """
      UPDATE #{table}
      SET #{Enum.join(set_parts, ", ")}
      WHERE #{Enum.join(where_parts, " AND ")}
      """

      case repo.query(query) do
        {:ok, _} -> {:ok, :updated}
        {:error, error} -> {:error, format_error(error)}
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_primary_keys(schema) do
    schema
    |> Map.get("columns", [])
    |> Enum.filter(& &1["is_primary_key"])
    |> Enum.map(& &1["name"])
  end

  defp prepare_record(record) when is_map(record) do
    # Convert string keys to string (normalize) and handle special values
    record
    |> Enum.map(fn {key, value} ->
      {to_string(key), prepare_value(value)}
    end)
    |> Map.new()
  end

  defp prepare_value(%{"__type__" => "datetime", "value" => value}) do
    # Handle serialized datetime
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> value
    end
  end

  defp prepare_value(%{"__type__" => "date", "value" => value}) do
    # Handle serialized date
    case Date.from_iso8601(value) do
      {:ok, d} -> d
      _ -> value
    end
  end

  defp prepare_value(%{"__type__" => "time", "value" => value}) do
    # Handle serialized time
    case Time.from_iso8601(value) do
      {:ok, t} -> t
      _ -> value
    end
  end

  defp prepare_value(%{"__type__" => "decimal", "value" => value}) do
    # Handle serialized decimal
    Decimal.new(value)
  end

  defp prepare_value(value), do: value

  defp escape_value(nil), do: "NULL"

  defp escape_value(value) when is_binary(value) do
    # Escape single quotes and wrap in quotes
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  defp escape_value(value) when is_boolean(value) do
    if value, do: "TRUE", else: "FALSE"
  end

  defp escape_value(value) when is_integer(value) or is_float(value) do
    to_string(value)
  end

  defp escape_value(%DateTime{} = dt) do
    "'#{DateTime.to_iso8601(dt)}'"
  end

  defp escape_value(%NaiveDateTime{} = dt) do
    "'#{NaiveDateTime.to_iso8601(dt)}'"
  end

  defp escape_value(%Date{} = d) do
    "'#{Date.to_iso8601(d)}'"
  end

  defp escape_value(%Time{} = t) do
    "'#{Time.to_iso8601(t)}'"
  end

  defp escape_value(%Decimal{} = d) do
    Decimal.to_string(d)
  end

  defp escape_value(value) when is_map(value) or is_list(value) do
    # JSON encode for jsonb columns
    case Jason.encode(value) do
      {:ok, json} -> "'#{String.replace(json, "'", "''")}'"
      _ -> "NULL"
    end
  end

  defp escape_value(value) do
    # Fallback - try to convert to string
    "'#{String.replace(to_string(value), "'", "''")}'"
  end

  defp format_error(%{postgres: %{message: message}}) do
    message
  end

  defp format_error(%{message: message}) do
    message
  end

  defp format_error(error) when is_binary(error) do
    error
  end

  defp format_error(error) do
    inspect(error)
  end
end
