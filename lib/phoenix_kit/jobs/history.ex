defmodule PhoenixKit.Jobs.History do
  @moduledoc """
  The Activity log entries of a run's life (`job.started`, `job.paused`, …):
  who started, paused, resumed or cancelled it, and what became of it.

  An entry is built here and **inserted by the engine inside the transition's
  transaction**, then published after commit — the feed never hears of a change
  that rolled back (the pattern of `PhoenixKit.Settings.History`). The entry's
  module is the kind's module key, so a media run appears under media; its
  resource is the run (`resource_type: "job_run"`), which is how the Jobs page
  finds a run's own history.
  """

  alias PhoenixKit.Activity
  alias PhoenixKit.Jobs.Run

  @resource_type "job_run"

  @doc "The resource type of a run's entries."
  def resource_type, do: @resource_type

  @doc "The changeset of the entry for `action` on `run`."
  @spec entry_changeset(Run.t(), String.t(), map(), map()) :: Ecto.Changeset.t()
  def entry_changeset(%Run{} = run, action, extra, ctx) do
    %{
      action: action,
      module: run.module,
      mode: ctx.mode,
      actor_uuid: ctx.actor,
      resource_type: @resource_type,
      resource_uuid: run.uuid,
      metadata:
        Map.merge(
          %{
            "kind" => run.kind,
            "title" => run.title,
            "scope_type" => run.scope_type,
            "scope_uuid" => run.scope_uuid && to_string(run.scope_uuid),
            "done" => run.done,
            "total" => run.total,
            "error" => run.error
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new(),
          extra
        )
    }
    |> Activity.entry_changeset()
  end

  @doc "The entries of one run, oldest first."
  @spec for_run(Ecto.UUID.t() | String.t()) :: [PhoenixKit.Activity.Entry.t()]
  def for_run(run_uuid) do
    import Ecto.Query

    from(e in PhoenixKit.Activity.Entry,
      where: e.resource_type == ^@resource_type and e.resource_uuid == ^run_uuid,
      order_by: [asc: e.inserted_at, asc: e.uuid]
    )
    |> PhoenixKit.RepoHelper.repo().all()
  end
end
