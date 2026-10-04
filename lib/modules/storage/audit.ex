defmodule PhoenixKit.Modules.Storage.Audit do
  @moduledoc """
  The "who changed what" half of Media's history
  (`dev_docs/plans/2026-10-03-job-runs.md`, §7): every change to the site's storage
  *configuration* is written to the Activity log, and the action names live here, in
  one place. Settings → Media → **History** reads them back, together with the
  entries of the storage job runs.

  | action | resource |
  |---|---|
  | `storage.profile.created` / `updated` / `deleted` | `storage_profile` |
  | `storage.profile.bucket_added` / `bucket_changed` / `bucket_removed` | `storage_profile` |
  | `storage.library.created` / `renamed` / `deleted` | `storage_library` |
  | `storage.library.profile_changed` / `variant_set_changed` / `setting_changed` | `storage_library` |
  | `storage.variant_set.created` / `updated` / `deleted` / `remade` | `storage_variant_set` |
  | `storage.variant_set.size_created` / `size_updated` / `size_deleted` / `sizes_reset` | `storage_variant_set` |
  | `storage.bucket.created` / `updated` / `deleted` | `storage_bucket` |

  An entry carries the acting user (`actor_uuid:` in the context's options; the
  LiveViews pass `PhoenixKitWeb.Actor.opts(socket)`), a mode (`manual` when a person
  acted, `auto` when nothing did) and, for a change, the Activity log's own
  `"changes"` shape — `%{"copies_originals" => %{"from" => 1, "to" => 2}}` — which the
  feed already renders as "from → to". Entries are **permanent**: they are not pruned
  by `activity_retention_days`, because "who changed this bucket last year" is exactly
  what an audit is asked.

  Only the **site's** configuration is recorded. A user's own library, profile and
  bucket (V203–V206) are theirs and private; their changes are not written here. And
  nothing secret is ever put in an entry: bucket changes name only the fields in
  `bucket_fields/0`, never a key or a secret.
  """

  import Ecto.Query
  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.Modules.Storage.Endpoint

  @module_key "storage"

  @bucket_fields ~w(name provider region endpoint bucket_name enabled priority integration_uuid cdn_url access_type max_size_mb)a
  @entries_key {__MODULE__, :entries}
  @callbacks_key {__MODULE__, :callbacks}
  @external_key {__MODULE__, :external_transaction}

  @doc "The Activity module key every storage entry (configuration and runs) is filed under."
  @spec module_key() :: String.t()
  def module_key, do: @module_key

  @doc "The bucket fields whose changes are recorded: never a key or a secret."
  @spec bucket_fields() :: [atom()]
  def bucket_fields, do: @bucket_fields

  @doc """
  Runs a configuration mutation and its audit inserts in one transaction, then
  announces the entries after commit. Nested audited mutations share the entries.
  A failed mutation or audit insert rolls everything back.

  Inside a caller's own repo transaction, entries commit with that transaction
  but are not announced: this module cannot know when the caller commits. The
  History tab's periodic refresh picks them up. Call this wrapper at the outer
  boundary when immediate announcements are wanted.
  """
  @spec transaction((-> result)) :: result | {:error, term()} when result: var
  def transaction(fun) do
    if Process.get(@entries_key), do: fun.(), else: transact(fun)
  end

  defp transact(fun) do
    nested? = repo().in_transaction?()

    result =
      repo().transaction(fn ->
        Process.put(@entries_key, [])
        Process.put(@callbacks_key, [])
        Process.put(@external_key, nested?)

        try do
          case fun.() do
            {:error, reason} ->
              repo().rollback(reason)

            value ->
              {value, Enum.reverse(Process.get(@entries_key)),
               Enum.reverse(Process.get(@callbacks_key))}
          end
        after
          Process.delete(@entries_key)
          Process.delete(@callbacks_key)
          Process.delete(@external_key)
        end
      end)

    case result do
      {:ok, {value, entries, callbacks}} ->
        Enum.each(callbacks, &run_callback/1)
        unless nested?, do: Enum.each(entries, &Activity.broadcast/1)
        value

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Defers a cache invalidation or compatibility-settings sync until this module's
  outer transaction commits. Callbacks are best effort. Inside a caller-owned
  repo transaction it retains the callback's existing immediate behavior; callers
  needing commit ordering must use `transaction/1` as their outer boundary.
  """
  @spec after_commit((-> term())) :: :ok
  def after_commit(fun) do
    if Process.get(@callbacks_key) && not Process.get(@external_key) do
      Process.put(@callbacks_key, [fun | Process.get(@callbacks_key)])
    else
      run_callback(fun)
    end

    :ok
  end

  defp run_callback(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("Storage audit post-commit callback failed: #{Exception.message(error)}")
  catch
    :exit, reason ->
      Logger.warning("Storage audit post-commit callback exited: #{inspect(reason)}")
  end

  @doc "Locks and reloads an audited resource so diffs describe its actual preceding state."
  @spec change(struct(), (struct() -> result)) :: result | {:error, term()} when result: var
  def change(%{__struct__: schema, uuid: uuid}, fun) do
    transaction(fn ->
      case repo().one(from(r in schema, where: r.uuid == ^uuid, lock: "FOR NO KEY UPDATE")) do
        nil -> {:error, :not_found}
        current -> fun.(current)
      end
    end)
  end

  @doc """
  Writes one configuration entry. Insert failures roll back an enclosing audited
  mutation; a standalone call returns the error. Entries are announced only after
  the transaction owned by this module commits.

  `opts` are the context call's: `:actor_uuid`, and `:mode` (default `"manual"` with an
  actor, `"auto"` without). `audit: false` writes nothing (`:skipped`) — for a change
  one context makes to another's rows as a consequence of the one that is recorded.
  `metadata` is a map of string keys.
  """
  @spec log(String.t(), String.t(), String.t() | nil, keyword(), map()) ::
          {:ok, PhoenixKit.Activity.Entry.t()} | {:error, term()} | :skipped
  def log(action, resource_type, resource_uuid, opts, metadata \\ %{}) do
    if Keyword.get(opts, :audit, true),
      do: transaction(fn -> write(action, resource_type, resource_uuid, opts, metadata) end),
      else: :skipped
  rescue
    error -> failed(error)
  catch
    :exit, reason -> failed(reason)
  end

  defp write(action, resource_type, resource_uuid, opts, metadata) do
    actor = Keyword.get(opts, :actor_uuid)

    %{
      module: @module_key,
      action: action,
      actor_uuid: actor,
      mode: Keyword.get(opts, :mode, if(actor, do: "manual", else: "auto")),
      resource_type: resource_type,
      resource_uuid: resource_uuid && to_string(resource_uuid),
      metadata: metadata,
      permanent: true
    }
    |> Activity.entry_changeset()
    |> repo().insert(mode: :savepoint)
    |> case do
      {:ok, entry} ->
        Process.put(@entries_key, [entry | Process.get(@entries_key)])
        {:ok, entry}

      {:error, reason} ->
        repo().rollback(reason)
    end
  end

  defp failed(reason) do
    if Process.get(@entries_key), do: repo().rollback(reason), else: {:error, reason}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  The `"changes"` map of an update: for each of `fields` that the changeset changes,
  `%{"field" => %{"from" => old, "to" => new}}` (values made loggable). Empty when
  nothing in `fields` changed.
  """
  @spec changes(Ecto.Changeset.t(), [atom()]) :: %{String.t() => map()}
  def changes(%Ecto.Changeset{} = changeset, fields) do
    for field <- fields, Map.has_key?(changeset.changes, field), into: %{} do
      {Atom.to_string(field),
       %{
         "from" => loggable(field, Map.get(changeset.data, field)),
         "to" => loggable(field, Map.fetch!(changeset.changes, field))
       }}
    end
  end

  @doc """
  The `"changes"` map between two values of the same struct (`before`, `after`) for
  `fields`. Empty when none differs.
  """
  @spec diff(map(), map(), [atom()]) :: %{String.t() => map()}
  def diff(before, later, fields) do
    for field <- fields, Map.get(before, field) != Map.get(later, field), into: %{} do
      {Atom.to_string(field),
       %{
         "from" => loggable(field, Map.get(before, field)),
         "to" => loggable(field, Map.get(later, field))
       }}
    end
  end

  @doc "Logs an update, when `changes` is not empty; `extra` is merged into the metadata."
  @spec log_update(String.t(), String.t(), String.t() | nil, keyword(), map(), map()) :: :ok
  def log_update(action, resource_type, uuid, opts, changes, extra \\ %{})

  def log_update(_action, _type, _uuid, _opts, changes, _extra) when map_size(changes) == 0,
    do: :ok

  def log_update(action, resource_type, uuid, opts, changes, extra) do
    log(action, resource_type, uuid, opts, Map.put(extra, Activity.changes_key(), changes))
    :ok
  end

  defp loggable(:endpoint, value), do: Endpoint.audit_value(value)
  defp loggable(:cdn_url, value), do: Endpoint.audit_value(value, local_path: false)

  defp loggable(_field, value), do: loggable(value)

  # Keep lists as JSON arrays rather than inspected Elixir source.
  defp loggable(value) when is_list(value), do: Enum.map(value, &loggable/1)
  defp loggable(nil), do: nil
  defp loggable(value) when is_boolean(value) or is_number(value) or is_binary(value), do: value
  defp loggable(value) when is_atom(value), do: Atom.to_string(value)
  defp loggable(value), do: inspect(value)
end
