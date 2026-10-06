defmodule PhoenixKit.Settings.History do
  @moduledoc """
  The history of site settings: what each setting was, and since when.

  ## Why

  A stored instant does not say which regime wrote it. When the `time_zone`
  setting moved from an integer offset to an IANA id and several modules
  turned out to have added that value to other instants, the rows they had
  written could not be repaired: nothing recorded when the setting changed
  or what it was before. `phoenix_kit_settings.date_updated` holds the last
  change only, and no settings writer logged anything.

  ## Where it lives

  In the activity feed, as `setting.changed` entries that are **permanent**
  (the pruner keeps them whatever their age), so there is one record of who
  did what, and the admin's Activity page shows settings changes beside
  everything else. The entry is inserted inside the settings write's
  transaction and published to the feed's subscribers only after the commit
  — nobody hears of a change that rolled back.

  Every write through `PhoenixKit.Settings` that changes a value records
  one entry — except a write passed `history: false` (see "Machine stamps"
  below): `metadata` carries the `key`, the value `from` and `to` (a
  JSON setting as its encoded document), the `source` (`"settings"` for the
  admin pages, `"system"` otherwise); `actor_uuid` is the person when one
  made the change; `resource_uuid` is the setting row. The value before is
  read under a row lock inside the write's transaction, so two racing
  writers cannot both record the same old value. A write that leaves the
  value as it was records nothing. A restricted (secret) setting records
  that a change happened — `restricted: true`, both values withheld. So does
  an integration connection row, whatever its key.

  ## Machine stamps

  A value a machine rewrites on a schedule — `job_runs_last_sweep_at`, which
  the jobs sweeper stamps on every five-minute pass — is not a change anybody
  made, and a permanent entry per pass would bury the feed under rows the
  pruner never takes. Such a writer passes `history: false`: the write, the
  cache invalidation and the settings change broadcast happen as for any
  other write; only the entry is left out. The option is for a machine's own
  stamp, never for something a person sets — a write that carries an
  `actor_uuid` or comes from the admin pages (`source: "settings"`) raises
  `ArgumentError` with it, so it cannot quietly drop a person's change.
  `list/2` and `value_at/2` know nothing about such a key's stamps.

  ## Reading it

    * `list/2` — the changes to one key, newest first.
    * `value_at/2` — the value a key had at an instant: the answer to "which
      timezone was this site on when that row was written?".
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings.Events
  alias PhoenixKit.Settings.Setting

  @action "setting.changed"
  @resource_type "setting"

  @doc "The activity action a settings change is logged under."
  @spec action() :: String.t()
  def action, do: @action

  @doc """
  Records the change a settings write made, or nothing when it changed no
  value.

  `before` is the row as it was — read under a row lock inside the write's
  transaction (`lock_current/1`) — or `nil` when the key did not exist;
  `written` the row as stored. Options: `:actor_uuid` (nil for a module or
  a migration), `:source` (`"settings"` for the admin pages; default
  `"system"`), `history: false` for a machine stamp (see "Machine stamps"
  in the moduledoc) — refused with `:actor_uuid` or `source: "settings"`.

  Returns `{:ok, %Activity.Entry{}}`, `{:ok, :unchanged}`,
  `{:ok, :unrecorded}` (a change written with `history: false`) or
  `{:error, changeset}`.
  """
  @spec record(Setting.t() | nil, Setting.t(), keyword()) ::
          {:ok, Entry.t() | :unchanged | :unrecorded} | {:error, Ecto.Changeset.t()}
  def record(before, %Setting{} = written, opts \\ []) do
    recorded? = recorded?(opts)
    old = if before, do: value_of(before), else: nil
    new = value_of(written)

    cond do
      old == new -> {:ok, :unchanged}
      not recorded? -> {:ok, :unrecorded}
      true -> insert(before, written, old, new, opts)
    end
  end

  # Checked before anything else, so a refused write fails the same way
  # whether or not it would have changed the value.
  defp recorded?(opts) do
    case Keyword.get(opts, :history, true) do
      false ->
        if Keyword.get(opts, :actor_uuid) != nil or Keyword.get(opts, :source) == "settings" do
          raise ArgumentError,
                "history: false is for a machine's own stamp; a write by a person " <>
                  "(actor_uuid:) or from the admin pages (source: \"settings\") is always recorded"
        end

        false

      _ ->
        true
    end
  end

  defp insert(before, written, old, new, opts) do
    # Either side restricted withholds both values — a key never changes
    # through these writers, but the history must not depend on that.
    restricted? =
      secret_row?(written) or (before != nil and secret_row?(before))

    actor_uuid = Keyword.get(opts, :actor_uuid)

    # Inserted directly, not through `Activity.log/1`: this runs inside
    # the settings write's transaction, and the feed's subscribers must
    # not hear of a change that then rolls back. The writer publishes the
    # entry (`Activity.broadcast/1`) once the transaction has committed.
    %{
      action: @action,
      actor_uuid: actor_uuid,
      mode: if(actor_uuid, do: "manual", else: "system"),
      resource_type: @resource_type,
      resource_uuid: written.uuid,
      permanent: true,
      metadata: %{
        "key" => written.key,
        "from" => if(restricted?, do: nil, else: old),
        "to" => if(restricted?, do: nil, else: new),
        "restricted" => restricted?,
        "source" => Keyword.get(opts, :source) || "system"
      }
    }
    |> Activity.entry_changeset()
    |> RepoHelper.repo().insert()
  end

  @doc """
  Publishes a recorded entry to the feed's subscribers — call after the
  transaction that wrote it has committed. `:unchanged` and `:unrecorded`
  publish nothing.
  """
  @spec publish(Entry.t() | :unchanged | :unrecorded) :: :ok
  def publish(%Entry{} = entry), do: Activity.broadcast(entry)
  def publish(nothing) when nothing in [:unchanged, :unrecorded], do: :ok

  @doc """
  The current row for `key`, locked for the rest of the transaction — the
  "before" a writer hands to `record/3`. `nil` when the key does not exist.
  Call inside a transaction.
  """
  @spec lock_current(String.t()) :: Setting.t() | nil
  def lock_current(key) when is_binary(key) do
    Setting
    |> where([s], s.key == ^key)
    |> lock("FOR UPDATE")
    |> RepoHelper.repo().one(log: false)
  end

  @doc """
  The changes to `key`, newest first. `:limit` (default 100).
  """
  @spec list(String.t(), keyword()) :: [Entry.t()]
  def list(key, opts \\ []) when is_binary(key) do
    limit = Keyword.get(opts, :limit, 100)

    key
    |> changes()
    |> order_by([e], desc: e.inserted_at, desc: e.uuid)
    |> limit(^limit)
    |> RepoHelper.repo().all()
  end

  @doc """
  The value `key` had at `instant`.

  The newest change at or before the instant says what the value became;
  with none, the oldest change after it says what the value was before
  anything was recorded; with no history at all, the current value — a
  setting that was never changed since recording began is ASSUMED to have
  always been what it is now. A JSON setting is its encoded document, the
  same shape the history holds. A `DateTime` in any zone is the instant it
  names, not its wall clock. A restricted key answers `nil` for every
  instant (so does an integration connection row): its values are withheld
  from the history and this must not become the way around that — and a key that WAS restricted when a change
  was recorded answers `nil` for that period even after it stops being
  restricted, because the value was never written down.
  """
  @spec value_at(String.t(), DateTime.t() | NaiveDateTime.t()) :: String.t() | nil
  def value_at(key, %NaiveDateTime{} = instant) when is_binary(key) do
    value_at(key, DateTime.from_naive!(instant, "Etc/UTC"))
  end

  def value_at(key, %DateTime{} = instant) when is_binary(key) do
    {:ok, utc} = DateTime.shift_zone(instant, "Etc/UTC")

    if secret_key_now?(key) do
      nil
    else
      at_or_before =
        key
        |> changes()
        |> where([e], e.inserted_at <= ^utc)
        |> order_by([e], desc: e.inserted_at, desc: e.uuid)
        |> limit(1)
        |> RepoHelper.repo().one()

      case at_or_before do
        %Entry{metadata: %{"to" => value}} ->
          value

        nil ->
          after_it =
            key
            |> changes()
            |> where([e], e.inserted_at > ^utc)
            |> order_by([e], asc: e.inserted_at, asc: e.uuid)
            |> limit(1)
            |> RepoHelper.repo().one()

          case after_it do
            %Entry{metadata: %{"from" => value}} -> value
            nil -> current_value(key)
          end
      end
    end
  end

  # The `setting.changed` entries for one key. Settings change rarely, so
  # the action index carries the walk; the key is matched in the metadata.
  defp changes(key) do
    from(e in Entry,
      where: e.action == @action and fragment("? ->> 'key' = ?", e.metadata, ^key)
    )
  end

  defp current_value(key) do
    case Setting |> where([s], s.key == ^key) |> RepoHelper.repo().one(log: false) do
      %Setting{} = setting -> value_of(setting)
      nil -> nil
    end
  end

  # `value_at/2` has only the key. The row's module decides for integration
  # rows, whose uuid keys no name rule can recognise.
  defp secret_key_now?(key) do
    module =
      Setting
      |> where([s], s.key == ^key)
      |> select([s], s.module)
      |> RepoHelper.repo().one()

    Events.secret_key?(key, module)
  rescue
    # Fail closed: an integration row's uuid key is only recognisable by its
    # module, so a lookup that could not answer must not reveal its body.
    _ -> true
  catch
    :exit, _ -> true
  end

  # The restricted keys, every integration connection row — whose key is a
  # uuid and whose body holds tokens (see `Settings.secret_setting?/2`) — AND
  # any key whose name marks it as a secret. The same wide test the change
  # broadcast uses (`Events.secret_key?/2`), on purpose: the restricted list
  # only knows the keys core knows, so a module's `…_api_key` written through
  # the ordinary writers was withheld from the broadcast and then stored here
  # in plaintext — in a row that is never pruned, and that `publish/1` sends
  # out over the activity feed. Withholding a value costs a reader nothing it
  # cannot get from the setting itself.
  defp secret_row?(%Setting{key: key, module: module}), do: Events.secret_key?(key, module)

  # A setting's value as history sees it: the JSON encoded when the setting
  # is a JSON one (an empty document is a value too — "{}" — not "nothing"),
  # else the string. `nil` when there is neither.
  defp value_of(%Setting{value_json: json}) when not is_nil(json), do: Jason.encode!(json)
  defp value_of(%Setting{value: value}), do: value
end
