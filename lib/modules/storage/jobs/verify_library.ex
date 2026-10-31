defmodule PhoenixKit.Modules.Storage.Jobs.VerifyLibrary do
  @moduledoc """
  Read-only, resumable library verification. Files present when started are
  walked in UUID order, five per batch. Originals are the default; previews and
  full checksum reads are opt-ins. A completed run can have findings: its failed
  counter counts files needing attention, not a failed worker execution.
  """
  use PhoenixKit.Jobs.Kind
  import Ecto.Query

  alias PhoenixKit.Jobs
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Libraries, LibraryVerification, VerificationPolicy}

  @batch_size 5
  @impl true
  def kind, do: "storage.verify_library"
  @impl true
  def module_key, do: "storage"
  @impl true
  def title(_args, _scope), do: "Verify a library"
  @impl true
  def permission, do: "media.manage"
  @impl true
  def idempotent?, do: true
  @impl true
  def queue, do: :file_processing
  @impl true
  def timeout, do: :timer.minutes(30)

  @impl true
  def on_start(args) do
    if args["mode"] in ["presence", "checksum"] and is_boolean(args["include_previews"]) and
         Map.has_key?(args, "through") and
         (is_nil(args["through"]) or match?({:ok, _}, Ecto.UUID.cast(args["through"]))),
       do: :ok,
       else: {:error, :invalid_options}
  end

  @impl true
  def admit_start(_args, scope), do: VerificationPolicy.admit(scope)

  @impl true
  def batch(%{scope_type: "library", scope_uuid: uuid} = run) do
    case Libraries.get_library(uuid) do
      %{trashed_at: nil} -> check_batch(run)
      _ -> {:error, "Library is no longer available"}
    end
  rescue
    _ -> {:error, "Verification could not finish this batch; check storage access and retry"}
  catch
    _, _ -> {:error, "Verification could not finish this batch; check storage access and retry"}
  end

  def batch(_run), do: {:error, "A library scope is required"}

  defp check_batch(run) do
    query =
      from(f in StorageFile,
        where:
          f.library_uuid == ^run.scope_uuid and f.status != "trashed" and not f.system_managed
      )

    query =
      if through = run.args["through"],
        do: where(query, [f], f.uuid <= ^through),
        else: where(query, [f], false)

    total = if run.cursor["after"], do: run.total, else: repo().aggregate(query, :count)

    query =
      if after_uuid = run.cursor["after"],
        do: where(query, [f], f.uuid > ^after_uuid),
        else: query

    files = repo().all(from(f in query, order_by: [asc: f.uuid], limit: ^@batch_size))

    findings = Enum.map(files, &check_file(run, &1))

    problems = List.flatten(findings)
    failed = Enum.count(findings, &(&1 != []))
    checked = length(files)

    progress = %{
      total: total,
      done: checked - failed,
      failed: failed,
      log: %{
        "checked" => checked,
        "healthy" => checked - failed,
        "needs_attention" => failed,
        "problems" => problems,
        "verification_mode" => run.args["mode"]
      }
    }

    if checked < @batch_size do
      {:done,
       %{
         "checked" => run.done + run.failed_count + checked,
         "needs_attention" => run.failed_count + failed,
         "mode" => run.args["mode"],
         "include_previews" => run.args["include_previews"]
       }, progress}
    else
      {:more, Map.put(progress, :cursor, %{"after" => List.last(files).uuid}), schedule_in: 1}
    end
  end

  defp check_file(run, file) do
    heartbeat = fn ->
      case Jobs.heartbeat(run) do
        :ok -> :ok
        _ -> raise "Verification claim was lost"
      end
    end

    heartbeat.()

    problems =
      LibraryVerification.check(file, run.args["mode"], run.args["include_previews"],
        heartbeat: heartbeat
      )

    # A concurrent edit/move is inconclusive, rather than a false clean result.
    current = repo().get(StorageFile, file.uuid)

    if current && current.updated_at == file.updated_at &&
         current.library_uuid == file.library_uuid && current.file_checksum == file.file_checksum,
       do: problems,
       else: [%{"file_uuid" => file.uuid, "problem" => "changed_during_check"}]
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
