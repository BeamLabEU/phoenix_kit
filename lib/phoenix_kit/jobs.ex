defmodule PhoenixKit.Jobs do
  @moduledoc """
  Background jobs module for PhoenixKit.

  This module provides functions for managing the Jobs admin interface.
  When enabled, it shows a view-only dashboard of background job status and history.

  ## Core Functions

  ### System Control

  - `enabled?/0` - Check if Jobs module is enabled
  - `enable_system/0` - Enable Jobs module
  - `disable_system/0` - Disable Jobs module

  ## Settings Keys

  All configuration is stored in the Settings system:

  - `jobs_enabled` - Enable/disable Jobs admin interface (boolean)

  ## Usage Examples

      # Check if Jobs module is enabled
      if PhoenixKit.Jobs.enabled?() do
        # Show jobs dashboard
      end

      # Enable/disable the module
      PhoenixKit.Jobs.enable_system()
      PhoenixKit.Jobs.disable_system()
  """

  @enabled_key "jobs_enabled"

  ## System Control Functions

  @doc """
  Returns true when the Jobs module is enabled.

  ## Examples

      iex> PhoenixKit.Jobs.enabled?()
      false

      iex> PhoenixKit.Jobs.enable_system()
      iex> PhoenixKit.Jobs.enabled?()
      true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    settings_call(:get_boolean_setting, [@enabled_key, false])
  end

  @doc """
  Enables the Jobs module.

  ## Examples

      iex> PhoenixKit.Jobs.enable_system()
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    settings_call(:update_boolean_setting, [@enabled_key, true])
  end

  @doc """
  Disables the Jobs module.

  ## Examples

      iex> PhoenixKit.Jobs.disable_system()
      {:ok, %PhoenixKit.Settings.Setting{}}
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    settings_call(:update_boolean_setting, [@enabled_key, false])
  end

  ## Configuration Functions

  @doc """
  Returns the current Jobs module configuration as a map.

  ## Examples

      iex> PhoenixKit.Jobs.get_config()
      %{
        enabled: true,
        stats: %{
          available: 0,
          scheduled: 0,
          executing: 0,
          completed: 0,
          retryable: 0,
          discarded: 0,
          cancelled: 0
        }
      }
  """
  @spec get_config() :: map()
  def get_config do
    %{
      enabled: enabled?(),
      stats: get_job_stats()
    }
  end

  @doc """
  Returns job statistics from the Oban jobs table.

  ## Examples

      iex> PhoenixKit.Jobs.get_job_stats()
      %{available: 5, scheduled: 2, executing: 1, completed: 100, ...}
  """
  @spec get_job_stats() :: map()
  def get_job_stats do
    repo = PhoenixKit.Config.get_repo()

    if repo do
      try do
        import Ecto.Query

        query =
          from(j in "oban_jobs",
            group_by: j.state,
            select: {j.state, count(j.id)}
          )

        stats =
          repo.all(query)
          |> Enum.into(%{})

        %{
          available: Map.get(stats, "available", 0),
          scheduled: Map.get(stats, "scheduled", 0),
          executing: Map.get(stats, "executing", 0),
          completed: Map.get(stats, "completed", 0),
          retryable: Map.get(stats, "retryable", 0),
          discarded: Map.get(stats, "discarded", 0),
          cancelled: Map.get(stats, "cancelled", 0)
        }
      rescue
        _ ->
          default_stats()
      end
    else
      default_stats()
    end
  end

  ## Private Helper Functions

  defp default_stats do
    %{
      available: 0,
      scheduled: 0,
      executing: 0,
      completed: 0,
      retryable: 0,
      discarded: 0,
      cancelled: 0
    }
  end

  # Get the configured Settings module (allows testing with mock)
  defp settings_module do
    PhoenixKit.Config.get(:jobs_settings_module, PhoenixKit.Settings)
  end

  # Call a function on the Settings module with arguments
  defp settings_call(fun, args) do
    apply(settings_module(), fun, args)
  end
end
