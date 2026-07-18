defmodule PhoenixKit.Modules.Storage.AnnotationThumbnailJob do
  @moduledoc """
  Background (re)generation of a file's baked annotated thumbnail.

  Debounced: jobs are unique per `file_uuid` *while still pending or running*
  (scheduled / available / executing / retryable) and enqueued with a short
  delay, so a burst of annotation edits collapses into a single render. The job
  reads the *current* annotations at run time, so it always reflects the latest
  state.

  Crucially, `:completed` is **not** a unique state: once a regen finishes, the
  next edit enqueues a fresh one. (Oban's default unique states include
  `:completed`, which would throttle regens to one per `period` per file and
  silently drop edits made inside that window — the symptom being "my new shape
  didn't show up until I drew another one.")
  """
  # The "incomplete" (not-yet-finished) states, computed from the *installed*
  # Oban so the list stays valid across versions — `:suspended` exists in some
  # Oban releases (2.23) but not others (2.20), and naming the wrong set is a
  # hard compile error in the host app. Excluding the terminal states (above
  # all `:completed`) is the whole point: a finished regen must never dedup the
  # next edit's enqueue.
  @unique_states Oban.Job.states() -- [:completed, :cancelled, :discarded]

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: 120, keys: [:file_uuid], states: @unique_states]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.AnnotationThumbnail

  # Seconds to wait before rendering, letting a flurry of edits settle.
  @debounce_seconds 8

  @doc """
  Enqueue a debounced annotated-thumbnail refresh for `file_uuid`.

  Best-effort: never raises (so it can't break the annotation-save path even if
  Oban isn't running). Returns `:ok` regardless.
  """
  def enqueue(file_uuid) when is_binary(file_uuid) do
    if AnnotationThumbnail.enabled?() do
      %{file_uuid: file_uuid}
      |> new(schedule_in: @debounce_seconds)
      |> Oban.insert()
    end

    :ok
  rescue
    _ -> :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuid" => file_uuid}}) do
    case AnnotationThumbnail.refresh(file_uuid) do
      {:ok, _} ->
        # Both outcomes (fresh bake, variant removed) change what grids
        # should show — let open UIs swap the thumbnail without a reload.
        Storage.broadcast_file_thumbnail_updated(file_uuid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
