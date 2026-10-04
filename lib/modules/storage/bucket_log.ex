defmodule PhoenixKit.Modules.Storage.BucketLog do
  @moduledoc """
  What went wrong with a site storage bucket, and what its probes said (V208).

  `Manager` reports a write, read or delete that failed (`record_failure/3`),
  and `Storage.probe_bucket/1` reports every probe of a saved bucket
  (`record/4`). The bucket's own page reads it back (`recent/2`, `summary/1`).

    * **Failures only.** A successful write or read is not recorded — on a busy
      site that would be a row per request. Latency over time therefore comes
      from the probes.
    * **A miss is not a failure.** A bucket that does not hold an object is the
      normal case during failover; a "not found" reply is not logged.
    * **A repeat is one row.** The same failure of the same kind on the same
      bucket within a minute bumps `count` and `last_at` instead of adding a row,
      so a bucket that is down does not write a row per request.
    * **Site buckets only.** A user's own bucket (V206) is private to them and is
      never logged here; neither is a bucket that has no uuid yet (a form's
      unsaved test).
    * **Never in the way.** Writing is best effort: `record_failure/3` runs in
      the background (`PhoenixKit.TaskSupervisor`), swallows every error, and
      cannot fail or slow the read or write that reported it.

  Rows are pruned daily to `bucket_log_retention_days` (default 30)
  by `Workers.BucketLogPruneWorker`.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage.BucketLogEntry
  alias PhoenixKit.Settings

  @kinds ~w(probe write read delete)
  @merge_window_seconds 60
  @message_limit 500
  @default_retention_days 30
  @latency_points 20

  @doc "The kinds of entry."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Reports that `kind` (`"write"`, `"read"` or `"delete"`) failed on `bucket`,
  with the provider's `reason`. Returns `:ok` at once; the row is written in the
  background. A "not found" reason is ignored.
  """
  @spec record_failure(struct() | nil, String.t(), term()) :: :ok
  def record_failure(bucket, kind, reason) when kind in @kinds do
    message = reason_text(reason)

    if loggable?(bucket) and not not_found?(message) do
      run(fn -> record(bucket, kind, false, message: message) end)
    end

    :ok
  rescue
    _ -> :ok
  end

  def record_failure(_bucket, _kind, _reason), do: :ok

  @doc """
  Writes an entry now: `:ok`, or `:skipped` for a bucket that is not logged or a
  write that did not happen (the table is unreachable). Options: `:message`,
  `:latency_ms`. A repeat of a failure that is not a probe, within a minute,
  bumps the earlier row instead.
  """
  @spec record(struct() | nil, String.t(), boolean(), keyword()) :: :ok | :skipped
  def record(bucket, kind, ok?, opts \\ []) when kind in @kinds and is_boolean(ok?) do
    if loggable?(bucket), do: write(bucket.uuid, kind, ok?, opts), else: :skipped
  rescue
    error ->
      Logger.debug("BucketLog: not written: #{Exception.message(error)}")
      :skipped
  catch
    :exit, _ -> :skipped
  end

  defp write(bucket_uuid, kind, ok?, opts) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    message = opts |> Keyword.get(:message) |> truncate()

    merged? = not ok? and kind != "probe" and merge(bucket_uuid, kind, message, now) > 0

    unless merged? do
      repo().insert!(%BucketLogEntry{
        bucket_uuid: bucket_uuid,
        kind: kind,
        ok: ok?,
        latency_ms: opts[:latency_ms],
        message: message,
        count: 1,
        inserted_at: now,
        last_at: now
      })
    end

    :ok
  end

  # Bumps the newest row of the same failure seen within the window.
  defp merge(bucket_uuid, kind, message, now) do
    since = NaiveDateTime.add(now, -@merge_window_seconds, :second)
    text = message || ""

    newest =
      from(e in BucketLogEntry,
        where:
          e.bucket_uuid == ^bucket_uuid and e.kind == ^kind and e.ok == false and
            coalesce(e.message, "") == ^text and e.last_at >= ^since,
        order_by: [desc: e.last_at],
        limit: 1,
        select: e.uuid
      )

    {count, _} =
      repo().update_all(
        from(e in BucketLogEntry, where: e.uuid in subquery(newest)),
        inc: [count: 1],
        set: [last_at: now]
      )

    count
  end

  @doc """
  The bucket's entries, newest first: `%{entries, page, total_pages, total}`.
  Options: `:page` (1), `:per_page` (10), `:filter` (`:all`, or `:failures`).
  """
  @spec recent(term(), keyword()) :: map()
  def recent(bucket_uuid, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, 10)

    base = from(e in BucketLogEntry, where: e.bucket_uuid == ^bucket_uuid)
    base = if opts[:filter] == :failures, do: where(base, [e], e.ok == false), else: base

    total = repo().aggregate(base, :count)
    total_pages = max(ceil(total / per_page), 1)
    page = min(page, total_pages)

    entries =
      base
      |> order_by([e], desc: e.last_at, desc: e.uuid)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> repo().all()

    %{entries: entries, page: page, total_pages: total_pages, total: total}
  end

  @doc """
  The bucket's log at a glance: `%{failures_24h, last_failure, last_probe,
  probes}`. `failures_24h` counts every failure seen in the last day (a row
  that merged repeats counts them all); `probes` are the latest probes, oldest
  first, for the latency chart.
  """
  @spec summary(term()) :: map()
  def summary(bucket_uuid) do
    since = NaiveDateTime.add(NaiveDateTime.utc_now(), -86_400, :second)
    mine = from(e in BucketLogEntry, where: e.bucket_uuid == ^bucket_uuid)

    failures =
      repo().one(
        from(e in mine, where: e.ok == false and e.last_at >= ^since, select: sum(e.count))
      )

    last_failure =
      repo().one(from(e in mine, where: e.ok == false, order_by: [desc: e.last_at], limit: 1))

    probes =
      from(e in mine,
        where: e.kind == "probe",
        order_by: [desc: e.last_at],
        limit: @latency_points
      )
      |> repo().all()

    %{
      failures_24h: to_int(failures),
      last_failure: last_failure,
      last_probe: List.first(probes),
      probes: Enum.reverse(probes)
    }
  end

  @doc "Removes every entry of a bucket (it was deleted). Returns how many."
  @spec delete_for_bucket(term()) :: non_neg_integer()
  def delete_for_bucket(bucket_uuid) do
    {count, _} =
      repo().delete_all(from(e in BucketLogEntry, where: e.bucket_uuid == ^bucket_uuid))

    count
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "How long entries are kept, in days (`bucket_log_retention_days`, default 30)."
  @spec retention_days() :: pos_integer()
  def retention_days do
    case Integer.parse(
           Settings.get_setting("bucket_log_retention_days", "#{@default_retention_days}")
         ) do
      {days, _} when days > 0 -> days
      _ -> @default_retention_days
    end
  end

  @doc "Deletes the entries last seen before the retention. Returns how many."
  @spec prune() :: non_neg_integer()
  def prune do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -retention_days() * 86_400, :second)
    {count, _} = repo().delete_all(from(e in BucketLogEntry, where: e.last_at < ^cutoff))
    count
  end

  # ---- internals ----

  # A site bucket that is saved. A user's own bucket (owner_uuid) is theirs.
  defp loggable?(%{uuid: uuid, owner_uuid: nil}) when not is_nil(uuid), do: true
  defp loggable?(_bucket), do: false

  defp run(fun) do
    case Process.whereis(PhoenixKit.TaskSupervisor) do
      nil ->
        fun.()

      supervisor ->
        Task.Supervisor.start_child(supervisor, fun)
    end

    :ok
  end

  # The provider's own words for a miss: an object that is simply not on the
  # bucket is how a failover starts, not a fault.
  defp not_found?(message),
    do: message =~ ~r/404|enoent|no such file|not found|nosuchkey/i

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(%{__exception__: true} = error), do: Exception.message(error)
  defp reason_text(reason), do: inspect(reason, limit: 10)

  defp truncate(nil), do: nil
  defp truncate(text), do: text |> String.replace("\x00", "") |> String.slice(0, @message_limit)

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_int(value) when is_integer(value), do: value

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
