defmodule PhoenixKit.Settings.Queries do
  @moduledoc """
  Ecto queries for Settings context.

  This module encapsulates all database queries for settings management,
  providing a centralized location for query logic.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings.Events
  alias PhoenixKit.Settings.History
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

  @doc """
  Gets a setting record by UUID.
  """
  def get_setting_by_uuid(uuid) when is_binary(uuid) do
    repo().get(Setting, uuid)
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

  @doc """
  Lists settings whose keys start with the given prefix.

  ## Examples

      iex> PhoenixKit.Settings.Queries.list_settings_by_key_prefix("integration:google:")
      [%Setting{key: "integration:google:default", ...}, %Setting{key: "integration:google:personal", ...}]
  """
  def list_settings_by_key_prefix(prefix) when is_binary(prefix) do
    like_pattern = prefix <> "%"

    Setting
    |> where([s], like(s.key, ^like_pattern))
    |> order_by([s], s.key)
    |> repo().all()
  end

  @doc """
  Lists settings whose keys match any of the given prefixes in a single query.

  More efficient than calling `list_settings_by_key_prefix/1` in a loop.

  ## Examples

      iex> PhoenixKit.Settings.Queries.list_settings_by_key_prefixes(["integration:google:", "integration:openrouter:"])
      [%Setting{key: "integration:google:default", ...}, %Setting{key: "integration:openrouter:default", ...}]
  """
  def list_settings_by_key_prefixes([]), do: []

  def list_settings_by_key_prefixes(prefixes) when is_list(prefixes) do
    conditions =
      Enum.reduce(prefixes, dynamic(false), fn prefix, acc ->
        like_pattern = prefix <> "%"
        dynamic([s], ^acc or like(s.key, ^like_pattern))
      end)

    Setting
    |> where(^conditions)
    |> order_by([s], s.key)
    |> repo().all()
  end

  @doc """
  Deletes a setting by key. Returns `{:ok, setting}` or `{:error, :not_found}`.
  """
  def delete_setting_by_key(key) when is_binary(key) do
    case get_setting_by_key(key) do
      nil -> {:error, :not_found}
      setting -> repo().delete(setting)
    end
  end

  # Write operations

  @doc """
  Inserts a new setting.

  ## Examples

      iex> %Setting{} |> Setting.changeset(%{key: "theme", value: "dark"})
      ...> |> PhoenixKit.Settings.Queries.insert_setting()
      {:ok, %Setting{}}
  """
  def insert_setting(changeset, opts \\ []) do
    # `log: false` — this table stores EVERY setting's value in the same two
    # generic columns, secrets included (`oauth_google_client_secret`,
    # `aws_secret_access_key`, ...). Ecto's own SQL debug logger inspects the
    # raw bound params with no notion of the schema (no `redact:` field
    # option reaches it — verified against `Ecto.Adapters.SQL`'s logger,
    # which only ever sees a flat positional param list), so a debug-level
    # logger would otherwise print the literal secret on every write
    # (`UPDATE ... SET value = $1 ... [<secret>, ...]`) regardless of key.
    # Found doing exactly that on a live install. Silencing the query log
    # for this one table is cheaper and safer than trying to enumerate
    # which keys are sensitive here too.
    with_history(changeset, opts, fn -> repo().insert(changeset, log: false) end)
  end

  @doc """
  Updates an existing setting.

  ## Examples

      iex> setting |> Setting.update_changeset(%{value: "light"})
      ...> |> PhoenixKit.Settings.Queries.update_setting()
      {:ok, %Setting{}}
  """
  def update_setting(changeset, opts \\ []) do
    # See `insert_setting/1` above for why.
    with_history(changeset, opts, fn -> repo().update(changeset, log: false) end)
  end

  # The write and its history row land together or not at all. `opts`
  # carries `:actor_uuid`, `:source` and `:history` for the history
  # (`PhoenixKit.Settings.History.record/3`); a write that changes no
  # value, or a machine stamp written with `history: false`, records
  # nothing. Options that may not skip the history are refused before the
  # transaction, so such a call takes no lock and writes nothing. The row
  # as it was is read under a lock INSIDE the transaction, so two concurrent writers cannot both record the same old
  # value. Nested inside a caller's transaction (the batch path) this joins
  # it. A history row that cannot be written rolls the setting back and
  # surfaces on the SETTING's changeset — callers hold that shape.
  defp with_history(changeset, opts, write) do
    :ok = History.check_options!(opts)

    result =
      repo().transaction(fn ->
        before = History.lock_current(Ecto.Changeset.get_field(changeset, :key))

        with {:ok, setting} <- write.(),
             {:ok, recorded} <- record_or_error(before, setting, changeset, opts) do
          {setting, recorded}
        else
          {:error, failed} -> repo().rollback(failed)
        end
      end)

    # Nobody hears of the change until it is committed.
    case result do
      {:ok, {setting, recorded}} ->
        announce_committed([{setting, recorded}])
        {:ok, setting}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # What every committed settings write does next, in this order: drop the
  # cached values (synchronously — a subscriber that reacts by reading the
  # setting must not get the old value back), then tell the activity feed and
  # the settings subscribers. `pairs` is `[{written_setting, history_result}]`;
  # a write that changed no value (`:unchanged`) is announced to nobody, and
  # one written without history (`:unrecorded`) only to the settings
  # subscribers — the feed has no entry to hear of.
  def announce_committed(pairs) do
    PhoenixKit.Cache.invalidate_now(:settings, Enum.map(pairs, fn {s, _} -> s.key end))

    for {setting, recorded} <- pairs, recorded != :unchanged do
      announce(fn -> History.publish(recorded) end)

      announce(fn ->
        Events.broadcast_setting_changed(setting.key, committed_value(setting), setting.module)
      end)
    end

    :ok
  end

  @doc false
  # One announcement of a committed change. The write already stands, so a
  # failed notification (PubSub not running in a Mix task, a feed subscriber
  # raising) is logged and the next one still goes out — it must never turn
  # the write into an error or skip the settings broadcast.
  def announce(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("Settings change not announced: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Settings change not announced: #{inspect({kind, reason})}")
      :ok
  end

  # The value a subscriber sees: the JSON document for a JSON setting, else
  # the string.
  defp committed_value(%Setting{value_json: json}) when not is_nil(json), do: json
  defp committed_value(%Setting{value: value}), do: value

  defp record_or_error(before, setting, changeset, opts) do
    case History.record(before, setting, opts) do
      {:ok, _} = ok ->
        ok

      {:error, history_changeset} ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :base,
           "the change could not be recorded: #{inspect(history_changeset.errors)}"
         )}
    end
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
