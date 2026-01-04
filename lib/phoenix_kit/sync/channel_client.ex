defmodule PhoenixKit.Sync.ChannelClient do
  @moduledoc """
  Client for communicating with the Sync channel from the Receiver's LiveView.

  This module provides a simple interface for the Receiver to request data
  from the connected Sender through the channel.

  ## Usage

      # In Receiver LiveView, after sender connects:
      # You receive {:sync, {:sender_joined, channel_pid}}

      # Then request tables:
      ref = ChannelClient.request_tables(channel_pid, self())
      # Wait for {:sync_response, ref, {:ok, tables}} message

      # Or use synchronous API:
      {:ok, tables} = ChannelClient.fetch_tables(channel_pid)
  """

  @request_timeout 30_000

  @doc """
  Requests the list of available tables from the sender.

  Returns the request ref. Response will be sent as:
  `{:sync_response, ref, {:ok, tables} | {:error, reason}}`
  """
  @spec request_tables(pid(), pid()) :: String.t()
  def request_tables(channel_pid, reply_to) do
    ref = generate_ref()
    send(channel_pid, {:request_tables, ref, reply_to})
    ref
  end

  @doc """
  Requests the schema for a specific table from the sender.
  """
  @spec request_schema(pid(), String.t(), pid()) :: String.t()
  def request_schema(channel_pid, table, reply_to) do
    ref = generate_ref()
    send(channel_pid, {:request_schema, table, ref, reply_to})
    ref
  end

  @doc """
  Requests the record count for a specific table from the sender.
  """
  @spec request_count(pid(), String.t(), pid()) :: String.t()
  def request_count(channel_pid, table, reply_to) do
    ref = generate_ref()
    send(channel_pid, {:request_count, table, ref, reply_to})
    ref
  end

  @doc """
  Requests paginated records from a specific table from the sender.

  ## Options

  - `:offset` - Starting offset (default: 0)
  - `:limit` - Maximum records to fetch (default: 100)
  """
  @spec request_records(pid(), String.t(), keyword(), pid()) :: String.t()
  def request_records(channel_pid, table, opts \\ [], reply_to) do
    ref = generate_ref()
    send(channel_pid, {:request_records, table, opts, ref, reply_to})
    ref
  end

  @doc """
  Synchronously requests tables and waits for response.
  """
  @spec fetch_tables(pid()) :: {:ok, [map()]} | {:error, any()}
  def fetch_tables(channel_pid) do
    ref = request_tables(channel_pid, self())

    receive do
      {:sync_response, ^ref, result} -> result
    after
      @request_timeout -> {:error, :timeout}
    end
  end

  @doc """
  Synchronously requests schema and waits for response.
  """
  @spec fetch_schema(pid(), String.t()) :: {:ok, map()} | {:error, any()}
  def fetch_schema(channel_pid, table) do
    ref = request_schema(channel_pid, table, self())

    receive do
      {:sync_response, ^ref, result} -> result
    after
      @request_timeout -> {:error, :timeout}
    end
  end

  @doc """
  Synchronously requests count and waits for response.
  """
  @spec fetch_count(pid(), String.t()) :: {:ok, integer()} | {:error, any()}
  def fetch_count(channel_pid, table) do
    ref = request_count(channel_pid, table, self())

    receive do
      {:sync_response, ^ref, result} -> result
    after
      @request_timeout -> {:error, :timeout}
    end
  end

  @doc """
  Synchronously requests records and waits for response.
  """
  @spec fetch_records(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def fetch_records(channel_pid, table, opts \\ []) do
    ref = request_records(channel_pid, table, opts, self())

    receive do
      {:sync_response, ^ref, result} -> result
    after
      @request_timeout -> {:error, :timeout}
    end
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp generate_ref do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
