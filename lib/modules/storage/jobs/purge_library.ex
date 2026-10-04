defmodule PhoenixKit.Modules.Storage.Jobs.PurgeLibrary do
  @moduledoc """
  Purges one trashed storage library (`storage.purge_library`): its files (bytes
  included, through the normal delete path), its folders, then the library
  (`PhoenixKit.Modules.Storage.Libraries.purge_library/1`) — as a job run, so an
  admin can see that it is happening and what became of it.

  **Visible, not controllable** (`controls/0` is `[]`; plan
  `2026-10-03-job-runs.md`, R6). `Libraries.purge_library/1` walks the whole
  library in one go, deletion cannot be undone, and the `purging` marker deliberately
  refuses a restore — so Pause and Cancel would promise what the work cannot do.
  Batching the purge, and what cancelling one means, is its own piece of work.

  A library on a user's own bucket whose objects could not all be deleted is retried
  (`{:error, :objects_remain}`, five attempts), then fails visibly; the daily trash
  prune starts it again. A library that is gone, or no longer trashed, ends the run
  with nothing done. Started by `Storage.Workers.PurgeLibraryJob`, the Oban job the
  user-deletion and the prune have always queued (it commits with their transaction).
  """

  use PhoenixKit.Jobs.Kind

  alias PhoenixKit.Modules.Storage.Libraries

  @impl true
  def kind, do: "storage.purge_library"

  @impl true
  def module_key, do: "storage"

  @impl true
  def title(_args, {"library", uuid}) do
    case Libraries.get_library(uuid) do
      %{kind: "system", name: name} -> "Delete library \"#{name}\" and its files"
      # A user's library is theirs and private: its name stays out of the title.
      %{kind: "user"} -> "Delete a user's library and its files"
      nil -> "Delete a library and its files"
    end
  end

  def title(_args, _scope), do: "Delete a library and its files"

  # Purging a half-purged library carries on where it was.
  @impl true
  def idempotent?, do: true

  @impl true
  def controls, do: []

  @impl true
  def permission, do: "media.manage"

  @impl true
  def queue, do: :file_processing

  @impl true
  def max_attempts, do: 5

  @impl true
  def timeout, do: :timer.minutes(30)

  @impl true
  def batch(%{scope_type: "library", scope_uuid: uuid}) do
    case Libraries.purge_library(to_string(uuid)) do
      :ok -> {:done, %{"purged" => true}}
      {:error, :not_found} -> {:done, %{"skipped" => "the library is gone"}}
      {:error, :not_trashed} -> {:done, %{"skipped" => "the library is not in the trash"}}
      # Objects on a user's own bucket could not be deleted yet: nothing was
      # forgotten, so try again later.
      {:error, :objects_remain} -> {:error, "objects remain on the library's own bucket"}
    end
  end
end
