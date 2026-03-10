defmodule PhoenixKit.Settings.Queries do
  @moduledoc """
  Ecto queries for Settings context.

  This module encapsulates all database queries for settings management,
  providing a centralized location for query logic.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings.Setting

  # Single record queries

  @doc """
  Gets a setting record by key.

  ## Examples

      iex> PhoenixKit.Settings.Queries.get_setting_by_key("time_zone")
      %Setting{key: "time_zone", value: "0"}

      iex> PhoenixKit.Settings.Queries.get_setting_by_key("non_existent")
      nil
  """
  def get_setting_by_key(key) when is_binary(key) do
    repo().get_by(Setting, key: key)
  end

  # Multiple records queries

  @doc """
  Lists all settings ordered by key.

  ## Examples

      iex> PhoenixKit.Settings.Queries.list_settings()
      [%Setting{key: "date_format", value: "Y-m-d"}, %Setting{key: "time_zone", value: "0"}, ...]
  """
  def list_settings do
    Setting
    |> order_by([s], s.key)
    |> repo().all()
  end

  @doc """
  Gets all settings as a list of {key, value} tuples.

  ## Examples

      iex> PhoenixKit.Settings.Queries.list_settings_key_values()
      [{"time_zone", "0"}, {"date_format", "Y-m-d"}]
  """
  def list_settings_key_values do
    Setting
    |> select([s], {s.key, s.value})
    |> repo().all()
  end

  @doc """
  Lists settings for specific keys as a list of {key, value} tuples.

  ## Examples

      iex> PhoenixKit.Settings.Queries.list_settings_key_values_by_keys(["time_zone", "date_format"])
      [{"time_zone", "0"}, {"date_format", "Y-m-d"}]
  """
  def list_settings_key_values_by_keys(keys) when is_list(keys) do
    Setting
    |> where([s], s.key in ^keys)
    |> select([s], {s.key, s.value})
    |> repo().all()
  end

  @doc """
  Lists setting records for specific keys.

  ## Examples

      iex> PhoenixKit.Settings.Queries.list_settings_by_keys(["time_zone"])
      [%Setting{key: "time_zone", value: "0"}]
  """
  def list_settings_by_keys(keys) when is_list(keys) do
    Setting
    |> where([s], s.key in ^keys)
    |> repo().all()
  end

  @doc """
  Lists settings by keys with JSON priority as a list of {key, value} tuples.

  Returns a list where value_json is used if present, otherwise falls back to
  the string value.

  ## Examples

      iex> PhoenixKit.Settings.Queries.list_settings_with_json_priority_by_keys(["theme"])
      [{"theme", %{"primary" => "#3b82f6"}}]
  """
  def list_settings_with_json_priority_by_keys(keys) when is_list(keys) do
    Setting
    |> where([s], s.key in ^keys)
    |> repo().all()
    |> Enum.map(fn setting ->
      value = if setting.value_json, do: setting.value_json, else: setting.value
      {setting.key, value}
    end)
  end

  # Write operations

  @doc """
  Inserts a new setting.

  ## Examples

      iex> %Setting{} |> Setting.changeset(%{key: "theme", value: "dark"})
      ...> |> PhoenixKit.Settings.Queries.insert_setting()
      {:ok, %Setting{}}
  """
  def insert_setting(changeset) do
    repo().insert(changeset)
  end

  @doc """
  Updates an existing setting.

  ## Examples

      iex> setting |> Setting.update_changeset(%{value: "light"})
      ...> |> PhoenixKit.Settings.Queries.update_setting()
      {:ok, %Setting{}}
  """
  def update_setting(changeset) do
    repo().update(changeset)
  end

  # Transaction

  @doc """
  Executes a transaction with multiple operations.

  ## Examples

      iex> Ecto.Multi.new()
      ...> |> multi_operation()
      ...> |> PhoenixKit.Settings.Queries.transaction()
      {:ok, result}
  """
  def transaction(multi) do
    repo().transaction(multi)
  end

  # Private functions

  defp repo do
    RepoHelper.repo()
  end
end
