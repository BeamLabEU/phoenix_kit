defmodule PhoenixKit.Jobs.Events do
  @moduledoc """
  PubSub for job runs, so the Jobs page follows a run as it moves instead of
  polling. Two topics: `topic/0` hears every run, `run_topic/1` one run. A
  message is `{:job_run, action, run}`, where `action` is what happened
  (`:started`, `:progress`, `:paused`, `:completed`, …).

  Always published **after** the transaction that made the change has
  committed, so a subscriber never hears of a change that rolled back
  (`PhoenixKit.Jobs.Engine`).
  """

  alias PhoenixKit.PubSub.Manager

  @topic "phoenix_kit:job_runs"

  @doc "The topic that hears every run."
  def topic, do: @topic

  @doc "The topic of one run."
  def run_topic(run_uuid), do: "#{@topic}:#{run_uuid}"

  @doc "Subscribes the caller to every run."
  def subscribe, do: Manager.subscribe(@topic)

  @doc "Subscribes the caller to one run."
  def subscribe(run_uuid), do: Manager.subscribe(run_topic(run_uuid))

  @doc "Tells the subscribers what happened to `run`. Never raises."
  @spec broadcast(PhoenixKit.Jobs.Run.t(), atom()) :: :ok
  def broadcast(run, action) do
    message = {:job_run, action, run}
    Manager.broadcast(@topic, message)
    Manager.broadcast(run_topic(run.uuid), message)
    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end
end
