defmodule PhoenixKit.Sync.Workers.ImportWorker do
  @moduledoc """
  Oban worker for background data import from DB Sync.

  This worker handles the actual import of records received from a sender,
  processing them in the background so the user doesn't have to wait.

  ## Job Arguments

  - `table` - The table name to import into
  - `records` - List of records to import (JSON-serialized)
  - `strategy` - Conflict resolution strategy ("skip", "overwrite", "merge")
  - `session_code` - The sync session code (for tracking)
  - `batch_index` - Optional batch index for large transfers

  ## Usage

  The Receiver LiveView enqueues jobs after receiving data:

      ImportWorker.new(%{
        table: "users",
        records: records,
        strategy: "skip",
        session_code: "ABC12345"
      })
      |> Oban.insert()

  ## Queue Configuration

  Add the sync queue to your Oban config:

      config :my_app, Oban,
        queues: [default: 10, sync: 5]
  """

  use Oban.Worker, queue: :sync, max_attempts: 3

  alias PhoenixKit.Sync.DataImporter
  alias PhoenixKit.Sync.SchemaInspector

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    table = Map.fetch!(args, "table")
    records = Map.fetch!(args, "records")
    strategy = args |> Map.get("strategy", "skip") |> String.to_existing_atom()
    session_code = Map.get(args, "session_code", "unknown")
    batch_index = Map.get(args, "batch_index", 0)
    schema = Map.get(args, "schema")

    Logger.info(
      "Sync.ImportWorker: Starting import for #{table} " <>
        "(batch #{batch_index}, #{length(records)} records, strategy: #{strategy})"
    )

    # Create table if it doesn't exist and we have a schema
    with :ok <- ensure_table_exists(table, schema) do
      case DataImporter.import_records(table, records, strategy) do
        {:ok, result} ->
          Logger.info(
            "Sync.ImportWorker: Completed import for #{table} (session: #{session_code}) - " <>
              "created: #{result.created}, updated: #{result.updated}, " <>
              "skipped: #{result.skipped}, errors: #{length(result.errors)}"
          )

          # Log any errors for debugging
          for {record, error} <- result.errors do
            Logger.warning(
              "Sync.ImportWorker: Error importing record in #{table}: #{inspect(error)}"
            )

            # Log the record primary key if available
            pk_info =
              case Map.get(record, "id") || Map.get(record, :id) do
                nil -> ""
                id -> " (id: #{id})"
              end

            Logger.debug("Sync.ImportWorker: Failed record#{pk_info}: #{inspect(record)}")
          end

          # Return success even if some records had errors
          # (we've logged them and don't want to retry the whole batch)
          :ok

        {:error, reason} ->
          Logger.error(
            "Sync.ImportWorker: Failed import for #{table} (session: #{session_code}) - " <>
              "#{inspect(reason)}"
          )

          # Return error to trigger Oban retry
          {:error, reason}
      end
    end
  end

  defp ensure_table_exists(table, schema) when is_map(schema) do
    if SchemaInspector.table_exists?(table) do
      :ok
    else
      Logger.info("Sync.ImportWorker: Creating missing table #{table}")

      case SchemaInspector.create_table(table, schema) do
        :ok ->
          Logger.info("Sync.ImportWorker: Created table #{table}")
          :ok

        {:error, reason} ->
          Logger.error("Sync.ImportWorker: Failed to create table #{table}: #{inspect(reason)}")

          {:error, {:table_creation_failed, reason}}
      end
    end
  end

  defp ensure_table_exists(_table, nil), do: :ok
  defp ensure_table_exists(_table, _), do: :ok

  @doc """
  Creates a new import job for the specified table and records.

  ## Parameters

  - `table` - Table name to import into
  - `records` - List of record maps
  - `strategy` - Conflict strategy (atom or string)
  - `session_code` - Transfer session code for tracking
  - `opts` - Additional options:
    - `:batch_index` - Index of the batch for multi-batch imports
    - `:schema` - Table schema definition (for auto-creating missing tables)

  ## Returns

  An Oban.Job changeset ready for insertion.
  """
  @spec create_job(String.t(), list(map()), atom() | String.t(), String.t(), keyword()) ::
          Oban.Job.changeset()
  def create_job(table, records, strategy, session_code, opts \\ []) do
    strategy_str = if is_atom(strategy), do: Atom.to_string(strategy), else: strategy

    args =
      %{
        "table" => table,
        "records" => records,
        "strategy" => strategy_str,
        "session_code" => session_code,
        "batch_index" => Keyword.get(opts, :batch_index, 0)
      }
      |> maybe_add_schema(Keyword.get(opts, :schema))

    new(args)
  end

  defp maybe_add_schema(args, nil), do: args
  defp maybe_add_schema(args, schema), do: Map.put(args, "schema", schema)

  @doc """
  Enqueues import jobs for multiple tables.

  Splits large record sets into batches to avoid memory issues.

  ## Parameters

  - `table_data` - Map of table name to one of:
    - `{records, strategy}` - Records and strategy without schema
    - `{records, strategy, schema}` - Records, strategy, and schema for auto-creating tables
  - `session_code` - Transfer session code
  - `batch_size` - Maximum records per job (default: 500)

  ## Returns

  - `{:ok, job_count}` - Number of jobs enqueued
  - `{:error, reason}` - If any job failed to enqueue
  """
  @spec enqueue_imports(map(), String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def enqueue_imports(table_data, session_code, batch_size \\ 500) do
    jobs =
      table_data
      |> Enum.flat_map(fn {table, table_info} ->
        {records, strategy, schema} = normalize_table_info(table_info)

        records
        |> Enum.chunk_every(batch_size)
        |> Enum.with_index()
        |> Enum.map(fn {batch, index} ->
          opts = [batch_index: index]
          opts = if schema, do: Keyword.put(opts, :schema, schema), else: opts
          create_job(table, batch, strategy, session_code, opts)
        end)
      end)

    # Insert all jobs
    results =
      Enum.map(jobs, fn job ->
        Oban.insert(job)
      end)

    # Check for failures
    errors =
      results
      |> Enum.filter(fn
        {:error, _} -> true
        _ -> false
      end)

    if Enum.empty?(errors) do
      {:ok, length(results)}
    else
      {:error, {:some_jobs_failed, length(errors)}}
    end
  end

  defp normalize_table_info({records, strategy}), do: {records, strategy, nil}
  defp normalize_table_info({records, strategy, schema}), do: {records, strategy, schema}
end
