defmodule PhoenixKit.Modules.Storage.ManualDate do
  @moduledoc """
  A capture date set by a person.

  Files are dated automatically (`PhoenixKit.Modules.Storage.CaptureDate`: EXIF, a
  video's container, the file name, the upload time). A person can say otherwise:
  ten scans uploaded today are from 12 March 1985. `set/3` writes that date with the
  source `"manual"`, which no automatic writer ever replaces (`CaptureDate.replace?/2`),
  and `reset/2` is the way back to the file's own date.

  `set/3` takes several files and moves them **together**: the first gets the new
  date, every other moves by the same amount, so their order and the time between
  them stay. That is how a stack is dated (`PhoenixKit.Modules.Storage.Stacks`): its
  files, cover first. One file is the same call with one uuid.

  Who may: someone who may edit every file (`Libraries.can?/3` with `:edit`). Each
  change is announced on the file-changes topic (`Storage.subscribe_to_file_changes/0`).
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Workers.CaptureDateRereadJob
  alias PhoenixKit.Users.Auth.Scope

  require Logger

  # The span `CaptureDate` believes: nothing before photography, nothing more than a
  # day ahead (a time zone we cannot see).
  @earliest ~N[1826-01-01 00:00:00]

  @type reason :: :not_found | :forbidden | :implausible_date

  @doc """
  Dates `file_uuids` by hand: the first file's local date and time become `to`, and
  every other file moves by the same amount.

  `to` is a `NaiveDateTime` (the local wall-clock time, as a camera writes it) or a
  `Date`, which keeps the first file's time of day. Each file keeps its UTC offset when
  it has one. Returns `{:ok, file_uuids}`, or `{:error, reason}`: `:not_found`,
  `:forbidden`, or `:implausible_date` when a file would land before 1826 or in the
  future.
  """
  @spec set([String.t()], NaiveDateTime.t() | Date.t(), Scope.t() | nil) ::
          {:ok, [String.t()]} | {:error, reason()}
  def set(file_uuids, to, scope) do
    uuids = file_uuids |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

    repo().transaction(fn ->
      with {:ok, files} <- load(uuids),
           :ok <- check_edit(files, scope),
           {:ok, changes} <- shifted(files, to) do
        Enum.each(changes, fn {file, attrs} ->
          file |> Ecto.Changeset.change(attrs) |> repo().update!()
        end)

        Enum.map(files, & &1.uuid)
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  @doc """
  Gives back their own dates to files dated by hand: the date in the name or the upload
  time at once, then the date in their bytes (EXIF, a video's container) from a job
  that reads them (`CaptureDateRereadJob`), since reading an original from storage is
  too slow to wait for. Files not dated by hand are left alone. Returns
  `{:ok, file_uuids}` (the files that were reset), or `{:error, reason}`.
  """
  @spec reset([String.t()], Scope.t() | nil) :: {:ok, [String.t()]} | {:error, reason()}
  def reset(file_uuids, scope) do
    uuids = file_uuids |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

    repo().transaction(fn ->
      with {:ok, files} <- load(uuids),
           :ok <- check_edit(files, scope) do
        manual = Enum.filter(files, &(&1.taken_at_source == "manual"))

        Enum.each(manual, fn file ->
          file |> Ecto.Changeset.change(CaptureDate.resolve(nil, file)) |> repo().update!()
        end)

        Enum.map(manual, & &1.uuid)
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
    |> tap(fn
      {:ok, [_ | _] = reset} -> reread(reset)
      _ -> :ok
    end)
  end

  @doc """
  The local wall-clock time `file` was taken at: its capture date in its own time zone
  when the offset is known, else as stored (which is the local time, see
  `CaptureDate`). A file with no date yet counts from its upload time.
  """
  @spec local(StorageFile.t()) :: NaiveDateTime.t()
  def local(%StorageFile{taken_at: %DateTime{} = taken_at, taken_at_offset: offset}) do
    taken_at |> DateTime.to_naive() |> NaiveDateTime.add(offset || 0)
  end

  def local(%StorageFile{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_naive(inserted_at)

  def local(%StorageFile{inserted_at: %NaiveDateTime{} = inserted_at}), do: inserted_at

  # ---------------------------------------------------------------------------

  # The files in the order asked (the first is the anchor), locked for the change.
  defp load(uuids) do
    valid = for u <- uuids, {:ok, uuid} <- [Ecto.UUID.cast(u)], do: uuid

    found =
      from(f in StorageFile, where: f.uuid in ^valid, lock: "FOR UPDATE")
      |> repo().all()
      |> Map.new(&{&1.uuid, &1})

    files = for u <- valid, file = found[u], do: file

    if valid != [] and length(files) == length(uuids),
      do: {:ok, files},
      else: {:error, :not_found}
  end

  defp check_edit(files, scope) do
    if Enum.all?(files, &Libraries.can?(scope, &1, :edit)), do: :ok, else: {:error, :forbidden}
  end

  defp shifted([anchor | _] = files, to) do
    from = local(anchor) |> NaiveDateTime.truncate(:second)
    target = target(to, from)
    delta = NaiveDateTime.diff(target, from, :second)

    changes =
      for file <- files do
        new_local = file |> local() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.add(delta)
        {file, new_local, attrs(new_local, file.taken_at_offset)}
      end

    if Enum.all?(changes, fn {_file, new_local, _attrs} -> plausible?(new_local) end),
      do: {:ok, Enum.map(changes, fn {file, _new_local, attrs} -> {file, attrs} end)},
      else: {:error, :implausible_date}
  end

  defp target(%NaiveDateTime{} = to, _from), do: NaiveDateTime.truncate(to, :second)
  defp target(%Date{} = to, from), do: NaiveDateTime.new!(to, NaiveDateTime.to_time(from))

  defp attrs(local, offset) do
    %{
      taken_at: local |> NaiveDateTime.add(-(offset || 0)) |> DateTime.from_naive!("Etc/UTC"),
      taken_on: NaiveDateTime.to_date(local),
      taken_at_offset: offset,
      taken_at_source: "manual"
    }
  end

  defp plausible?(local) do
    NaiveDateTime.compare(local, @earliest) != :lt and
      NaiveDateTime.compare(local, NaiveDateTime.add(NaiveDateTime.utc_now(), 86_400)) != :gt
  end

  # The files already have a date (their name's or upload time's); the bytes' date is a
  # refinement, so a re-read that cannot be queued is logged, never an error.
  defp reread(file_uuids) do
    case %{"file_uuids" => file_uuids} |> CaptureDateRereadJob.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("ManualDate: could not queue a re-read: #{inspect(reason)}")
        :ok
    end
  rescue
    # No Oban running (update mode, a bare test).
    error ->
      Logger.warning("ManualDate: could not queue a re-read: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp announce({:ok, file_uuids}) do
    Storage.broadcast_files_changed(file_uuids)
    {:ok, file_uuids}
  end

  defp announce({:error, _reason} = error), do: error

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
