defmodule PhoenixKit.Modules.Storage.Workers.ChecksumBackfillJob do
  @moduledoc """
  Recomputes the MD5 checksums the upload API used to record (G12).

  `file_checksum` is the dedup key's input, and every upload path but
  `UploadController` hashed with SHA-256, so the same bytes uploaded through
  the API and through the media browser were never recognised as the same
  file. The controller hashes with SHA-256 now; this job finds the rows it
  stored before (a 32-hex-character checksum), reads each file's original,
  and records its SHA-256 and the matching `user_file_checksum`
  (`Storage.calculate_user_file_checksum/3`, library-aware).

  A row whose uploader already has the same bytes in the same library would
  collide on the dedup index: it is left as it is (it keeps not deduping,
  which is what it did before). A file whose original cannot be read is
  left too. Either is marked in its `metadata` (`"checksum_backfill"`), so a
  later pass does not download it again. The update is guarded on the old checksum, so a row changed
  meanwhile (an image edit) is not overwritten.

  Throttled and self-queuing like `LocationBackfillJob`: one batch per run,
  the next five seconds later, queued after boot and by the daily trash
  prune while any MD5 row is left.
  """

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue], states: [:available, :scheduled]]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Jobs.System, as: JobsSystem
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Jobs.ChecksumBackfill

  @batch_size 20

  @doc """
  Starts a pass as a job run (`Storage.Jobs.ChecksumBackfill`) when any file has an
  MD5 checksum, unless one is already active. Never raises.
  """
  @spec maybe_enqueue() :: :queued | :nothing_to_do | :unavailable
  def maybe_enqueue do
    if pending?() do
      case JobsSystem.start(ChecksumBackfill, :site, source: "backfill") do
        {:ok, _run, _how} -> :queued
        _ -> :unavailable
      end
    else
      :nothing_to_do
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc "Whether any file still has an MD5 checksum to recompute."
  @spec pending?() :: boolean()
  def pending?, do: repo().exists?(md5_query(nil))

  @doc "How many files still have an MD5 checksum to recompute."
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: repo().aggregate(md5_query(nil), :count)

  # The pass is a job run now. A job queued by an earlier release starts that run
  # and ends: its old cursor is dropped, which is safe — a file already recomputed
  # is not a candidate any more. This clause stays until `mix phoenix_kit.doctor`
  # finds no job left for it.
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case JobsSystem.start(ChecksumBackfill, :site, source: "backfill") do
      {:error, reason} -> {:error, reason}
      _started_or_existing -> :ok
    end
  end

  @doc """
  Runs a whole pass in the calling process; returns how many files were
  `:updated`, `:duplicate` (left, their uploader has the bytes already),
  `:unreadable` or `:changed` (edited meanwhile).
  """
  @spec run_pass() :: %{atom() => non_neg_integer()}
  def run_pass, do: run_pass(nil, %{})

  defp run_pass(cursor, totals) do
    case run_batch(cursor, totals) do
      {:more, last_uuid, totals} -> run_pass(last_uuid, totals)
      {:done, totals} -> totals
    end
  end

  # One batch after `cursor`; what `Storage.Jobs.ChecksumBackfill` calls for each.
  @doc false
  def run_batch(cursor, totals) do
    batch =
      cursor
      |> md5_query()
      |> then(&from(f in &1, order_by: f.uuid, limit: @batch_size))
      |> repo().all()

    totals =
      Enum.reduce(batch, totals, fn file, acc ->
        outcome = recompute(file)
        if outcome in [:duplicate, :unreadable], do: remember_skipped(file, outcome)
        Map.update(acc, outcome, 1, &(&1 + 1))
      end)

    if length(batch) < @batch_size,
      do: {:done, totals},
      else: {:more, batch |> List.last() |> Map.get(:uuid) |> to_string(), totals}
  end

  @doc false
  def recompute(%StorageFile{} = file) do
    case Storage.retrieve_original(file.uuid) do
      {:ok, path, _file, _instance} ->
        try do
          sha = :sha256 |> :crypto.hash(Elixir.File.read!(path)) |> Base.encode16(case: :lower)
          record(file, sha)
        after
          Elixir.File.rm(path)
        end

      _ ->
        :unreadable
    end
  end

  defp record(file, sha) do
    user_checksum = Storage.calculate_user_file_checksum(file.user_uuid, sha, file.library_uuid)

    {count, _} =
      repo().update_all(
        from(f in StorageFile,
          where: f.uuid == ^file.uuid and f.file_checksum == ^file.file_checksum
        ),
        set: [file_checksum: sha, user_file_checksum: user_checksum]
      )

    if count == 1, do: :updated, else: :changed
  rescue
    error in Postgrex.Error ->
      if error.postgres.code == :unique_violation,
        do: :duplicate,
        else: reraise(error, __STACKTRACE__)
  end

  # A row left as MD5 (a duplicate of the uploader's own copy, or an
  # original that could not be read) is marked in its metadata, so later
  # passes do not download it again only to reach the same answer.
  defp remember_skipped(file, outcome) do
    from(f in StorageFile,
      where: f.uuid == ^file.uuid,
      update: [
        set: [
          metadata:
            fragment(
              "coalesce(?, '{}'::jsonb) || jsonb_build_object('checksum_backfill', ?::text)",
              f.metadata,
              ^to_string(outcome)
            )
        ]
      ]
    )
    |> repo().update_all([])
  rescue
    _ -> :ok
  end

  # Files the upload API stored with an MD5 checksum: 32 hex characters.
  # System rows (tiles, edit backups) never had one; a row a pass already
  # had to leave is not visited again.
  defp md5_query(cursor) do
    base =
      from(f in StorageFile,
        where:
          f.system_managed == false and fragment("length(?)", f.file_checksum) == 32 and
            fragment("? ~ '^[0-9a-f]{32}$'", f.file_checksum) and
            fragment("(?->>'checksum_backfill') IS NULL", f.metadata)
      )

    case cursor do
      nil -> base
      after_uuid -> from(f in base, where: f.uuid > ^after_uuid)
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
