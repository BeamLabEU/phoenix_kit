defmodule PhoenixKit.Jobs.Run do
  @moduledoc """
  A job run: one logical piece of long background work (V207).

  Oban executes it batch by batch; this row is what an admin watches and
  controls. See `PhoenixKit.Jobs` for the API and
  `dev_docs/plans/2026-10-03-job-runs.md` for the design. Go through
  `PhoenixKit.Jobs` rather than writing rows: every transition is one
  transaction that also dispatches the next batch and writes the history.

  ## States

    * `queued` — started (or resumed, or restarted), waiting for a batch;
    * `running` — a batch is executing, or the next one is waiting for its turn;
    * `pausing` / `cancelling` — a pause or cancel was asked while a batch holds
      the run; the batch finishes, then the run becomes `paused` / `cancelled`;
    * `paused`, `completed`, `failed`, `cancelled`.

  The first five are *active*: at most one run per kind and scope may be in one
  of them (a partial unique index), so a retry cannot start while the old run is
  still draining.

  ## The execution protocol

  `generation` counts dispatches: every Oban job carries the generation it was
  made for, and one of an older generation is inert. `claim_token` /
  `claimed_at` say a batch holds the run now. `restart_seq` counts triggers that
  asked for a fresh pass and `restart_ack` the last one a batch has taken in.
  `rescues` / `last_rescued_at` are the sweeper's durable budget, and
  `oban_job_id` the current dispatch.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @states ~w(queued running pausing paused cancelling completed failed cancelled)
  @active_states ~w(queued running pausing paused cancelling)
  @terminal_states ~w(completed failed cancelled)
  @modes ~w(manual auto cron script)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_job_runs" do
    field :kind, :string
    field :module, :string
    field :scope_type, :string
    field :scope_uuid, UUIDv7
    field :title, :string
    field :state, :string, default: "queued"
    field :done, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :total, :integer
    field :cursor, :map, default: %{}
    field :args, :map, default: %{}
    field :result, :map
    field :error, :string
    field :mode, :string, default: "manual"
    field :started_by_uuid, UUIDv7
    field :paused_by_uuid, UUIDv7
    field :cancelled_by_uuid, UUIDv7
    field :generation, :integer, default: 0
    field :claim_token, Ecto.UUID
    field :claimed_at, :utc_datetime
    field :claim_owner, :string
    field :wake_at, :utc_datetime
    field :interruptions, :integer, default: 0
    field :owner_token, Ecto.UUID
    field :oban_job_id, :integer
    field :restart_seq, :integer, default: 0
    field :restart_ack, :integer, default: 0
    field :rescues, :integer, default: 0
    field :last_rescued_at, :utc_datetime
    field :heartbeat_at, :utc_datetime
    field :started_at, :utc_datetime
    field :paused_at, :utc_datetime
    field :cancelled_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Every state a run can be in."
  def states, do: @states

  @doc "The states of an unfinished run: at most one per kind and scope."
  def active_states, do: @active_states

  @doc "The states a run never leaves."
  def terminal_states, do: @terminal_states

  @doc "The ways a run can have been started."
  def modes, do: @modes

  @doc "Whether the run has not finished."
  @spec active?(t() | String.t()) :: boolean()
  def active?(%__MODULE__{state: state}), do: active?(state)
  def active?(state) when is_binary(state), do: state in @active_states

  @doc "Whether the run has finished, one way or another."
  @spec terminal?(t() | String.t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: terminal?(state)
  def terminal?(state) when is_binary(state), do: state in @terminal_states

  # How long a script's claim stands without a sign of life before the sweeper
  # may take it for dead. An inline batch has no Oban job to ask about, so its
  # lease is the only evidence; a kind with longer batches calls
  # `PhoenixKit.Jobs.heartbeat/1`.
  @inline_lease_seconds 3600

  @doc "Seconds a script's claim stands without a heartbeat."
  def inline_lease_seconds, do: @inline_lease_seconds

  @doc "Whether a script (`run_inline/3`) holds the run, not an Oban batch."
  @spec inline_claim?(t()) :: boolean()
  def inline_claim?(%__MODULE__{claim_token: token, claim_owner: "inline"}), do: not is_nil(token)
  def inline_claim?(%__MODULE__{}), do: false

  @doc """
  Whether the lease of a script's claim has run out at `now`. The lease runs from
  the latest sign of life — the claim, a heartbeat, or the time the script asked
  its next batch to wait for (`wake_at`) — so a script waiting out a long delay
  between batches holds its run for the delay *and* a lease after it.
  """
  @spec lease_expired?(t(), DateTime.t()) :: boolean()
  def lease_expired?(%__MODULE__{claimed_at: claimed, heartbeat_at: beat, wake_at: wake}, now) do
    case Enum.reject([claimed, beat, wake], &is_nil/1) do
      [] ->
        true

      times ->
        last = Enum.max(times, DateTime)
        DateTime.compare(now, DateTime.add(last, @inline_lease_seconds, :second)) == :gt
    end
  end

  @doc """
  Whether a script owns the run between its batches: it holds no batch claim but
  has not given the run up either (it is waiting out a delay).
  """
  @spec inline_waiting?(t()) :: boolean()
  def inline_waiting?(%__MODULE__{claim_token: nil, claim_owner: "inline"}), do: true
  def inline_waiting?(%__MODULE__{}), do: false

  @doc "Seconds until `wake_at`, never negative; 0 when the run has no delay pending."
  @spec seconds_until_wake(t(), DateTime.t()) :: non_neg_integer()
  def seconds_until_wake(%__MODULE__{wake_at: nil}, _now), do: 0
  def seconds_until_wake(%__MODULE__{wake_at: at}, now), do: max(0, DateTime.diff(at, now))

  @doc "Whether a batch holds the run right now."
  @spec claimed?(t()) :: boolean()
  def claimed?(%__MODULE__{claim_token: token}), do: not is_nil(token)

  @doc """
  The run's scope as `{type, uuid}`, or `:site` when it is about nothing in
  particular.
  """
  @spec scope(t()) :: :site | {String.t(), String.t()}
  def scope(%__MODULE__{scope_type: nil}), do: :site
  def scope(%__MODULE__{scope_type: type, scope_uuid: uuid}), do: {type, to_string(uuid)}

  @doc "A whole number between 0 and 100, or nil when the total is not known."
  @spec percent(t()) :: non_neg_integer() | nil
  def percent(%__MODULE__{total: total}) when not is_integer(total) or total <= 0, do: nil

  def percent(%__MODULE__{done: done, failed_count: failed, total: total}) do
    min(100, div((done + failed) * 100, total))
  end

  @doc "The changeset a new run is inserted with."
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :kind,
      :module,
      :scope_type,
      :scope_uuid,
      :title,
      :mode,
      :started_by_uuid,
      :args,
      :generation,
      :started_at
    ])
    |> validate_required([:kind, :module, :title, :mode])
    |> validate_inclusion(:mode, @modes)
    |> validate_length(:kind, max: 100)
    |> validate_length(:title, max: 255)
    |> unique_constraint(:kind, name: :phoenix_kit_job_runs_active_index)
  end
end
