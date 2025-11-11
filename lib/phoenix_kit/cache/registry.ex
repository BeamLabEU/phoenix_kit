defmodule PhoenixKit.Cache.Registry do
  @moduledoc """
  Lightweight Registry wrapper for PhoenixKit.Cache instances.

  This module provides simple process registration and discovery for cache
  processes.

  ## Features

  - Simple Registry wrapper using Elixir's Registry
  - Process registration and discovery
  - Basic cache listing and health checking

  ## Usage

      # Register a cache process (typically done automatically)
      {:ok, pid} = PhoenixKit.Cache.start_link(name: :my_cache)

      # List all registered caches
      PhoenixKit.Cache.Registry.list_caches()

      # Check if a cache is registered
      PhoenixKit.Cache.Registry.cache_exists?(:my_cache)

      # Get cache process PID
      PhoenixKit.Cache.Registry.get_cache_pid(:my_cache)

  """

  @doc """
  Starts the Registry for cache process registration.

  ## Examples

      {:ok, _pid} = PhoenixKit.Cache.Registry.start_link()

  """
  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  @doc """
  Creates a via tuple for process registration.

  ## Examples

      iex> PhoenixKit.Cache.Registry.via_tuple(:my_cache)
      {:via, Registry, {PhoenixKit.Cache.Registry, :my_cache}}

  """
  @spec via_tuple(atom()) :: {:via, Registry, {atom(), atom()}}
  def via_tuple(key) when is_atom(key) do
    {:via, Registry, {__MODULE__, key}}
  end

  @doc """
  Child specification for supervision trees.

  ## Examples

      children = [
        PhoenixKit.Cache.Registry
      ]

  """
  @spec child_spec(any()) :: Supervisor.child_spec()
  def child_spec(_) do
    Supervisor.child_spec(
      Registry,
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    )
  end

  @doc """
  Returns the count of registered cache processes.

  ## Examples

      iex> PhoenixKit.Cache.Registry.count()
      2

  """
  @spec count() :: non_neg_integer()
  def count do
    Registry.count(__MODULE__)
  end

  @doc """
  Looks up a cache process by name.

  ## Examples

      iex> PhoenixKit.Cache.Registry.lookup(:my_cache)
      [{#PID<0.123.0>, nil}]

  """
  @spec lookup(atom()) :: [{pid(), any()}]
  def lookup(key) when is_atom(key) do
    Registry.lookup(__MODULE__, key)
  end

  @doc """
  Lists all registered cache instances with their basic status.

  ## Examples

      PhoenixKit.Cache.Registry.list_caches()
      # => %{
      #   settings: %{pid: #PID<0.123.0>, status: :running},
      #   user_roles: %{pid: #PID<0.124.0>, status: :running}
      # }

  """
  @spec list_caches() :: map()
  def list_caches do
    __MODULE__
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.reduce(%{}, fn {name, pid}, acc ->
      status = if Process.alive?(pid), do: :running, else: :dead
      Map.put(acc, name, %{pid: pid, status: status})
    end)
  end

  @doc """
  Checks if a cache is registered and running.

  ## Examples

      iex> PhoenixKit.Cache.Registry.cache_exists?(:my_cache)
      true

  """
  @spec cache_exists?(atom()) :: boolean()
  def cache_exists?(name) when is_atom(name) do
    case lookup(name) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end

  @doc """
  Gets the PID of a registered cache process.

  ## Examples

      iex> PhoenixKit.Cache.Registry.get_cache_pid(:my_cache)
      #PID<0.123.0>

  """
  @spec get_cache_pid(atom()) :: pid() | nil
  def get_cache_pid(name) when is_atom(name) do
    case lookup(name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Gets basic statistics for registered caches.

  Note: This provides basic registry-level stats. For detailed cache
  statistics, use PhoenixKit.Cache.stats/1 directly.

  ## Examples

      PhoenixKit.Cache.Registry.stats()
      # => %{
      #   total_caches: 2,
      #   running_caches: 2,
      #   dead_caches: 0,
      #   cache_names: [:settings, :user_roles]
      # }

      PhoenixKit.Cache.Registry.stats(:my_cache)
      # => %{registered: true, running: true, pid: #PID<0.123.0>}

  """
  @spec stats(atom() | nil) :: map()
  def stats(cache_name \\ nil)

  def stats(nil) do
    caches = list_caches()
    running = Enum.count(caches, fn {_name, info} -> info.status == :running end)
    dead = Enum.count(caches, fn {_name, info} -> info.status == :dead end)
    cache_names = Map.keys(caches)

    %{
      total_caches: map_size(caches),
      running_caches: running,
      dead_caches: dead,
      cache_names: cache_names
    }
  end

  def stats(name) when is_atom(name) do
    case lookup(name) do
      [{pid, _}] ->
        %{
          registered: true,
          running: Process.alive?(pid),
          pid: pid
        }

      [] ->
        %{
          registered: false,
          running: false,
          pid: nil
        }
    end
  end

  @doc """
  Performs a basic health check on registered caches.

  ## Examples

      PhoenixKit.Cache.Registry.health_check()
      # => %{
      #   overall_status: :healthy,
      #   total_caches: 2,
      #   running_caches: 2,
      #   dead_caches: 0,
      #   registry_status: :running
      # }

  """
  @spec health_check() :: map()
  def health_check do
    caches = list_caches()
    running = Enum.count(caches, fn {_name, info} -> info.status == :running end)
    dead = Enum.count(caches, fn {_name, info} -> info.status == :dead end)
    total = map_size(caches)

    overall_status =
      cond do
        total == 0 -> :no_caches
        dead == 0 -> :healthy
        running > 0 -> :degraded
        true -> :unhealthy
      end

    %{
      overall_status: overall_status,
      total_caches: total,
      running_caches: running,
      dead_caches: dead,
      registry_status: :running,
      caches: caches
    }
  end
end
