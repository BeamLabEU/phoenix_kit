defmodule PhoenixKit.Migrations.Postgres.V207 do
  @moduledoc """
  V207: job runs, the table (`dev_docs/plans/2026-10-03-job-runs.md`, §3.1 and §14).

  A **run** is a durable record of one logical piece of long work — a backfill,
  a reconcile of one library, later a broadcast or an import — that Oban executes
  batch by batch and an admin can watch, pause, resume, cancel and retry. One
  table, `phoenix_kit_job_runs`:

    * identity — `kind`, `module`, `scope_type` / `scope_uuid` (a library, or
      neither for the site) and a `title` fixed at start;
    * `state` — `queued`, `running`, `pausing`, `paused`, `cancelling`,
      `completed`, `failed`, `cancelled`;
    * progress — `done`, `failed_count`, `total` (NULL when unknown) and the
      `cursor` the next batch resumes from;
    * attribution — `mode` (`manual`, `auto`, `cron`, `script`) and who started,
      paused and cancelled it;
    * the execution protocol (§14 R1, R2, R5) — `generation` (every dispatch
      bumps it; an Oban job of an older generation is inert), `claim_token` and
      `claimed_at` (a batch holds the run while it works), `claim_owner` (`queue` for an Oban
      batch, `inline` for a script — the sweeper judges the two differently; a script keeps it
      between its batches too), `wake_at` (when the next batch should start, after a delay),
      `interruptions` (batches that were interrupted and run again: the counts of such a run
      are approximate), `owner_token` (which script invocation owns the run between its
      batches — another invocation is refused while that owner's lease stands), `oban_job_id` (the
      current dispatch), `restart_seq` / `restart_ack` (a trigger that arrived,
      and the last one a batch has seen), `rescues` and `last_rescued_at` (the
      sweeper's durable budget) and `heartbeat_at`.

  **One active run per kind and scope**, by a partial unique index over the five
  active states. `pausing` and `cancelling` are active on purpose: a retry or a
  new run cannot start while the old one is still draining its batch.

  There are **no foreign keys**: a run must outlive what it was about (a purged
  library) and who started it (a deleted user), the same choice V206 made for
  `owner_uuid`.

  Nothing is copied, moved or rewritten; the table starts empty.

  ## Locks

  `CREATE TABLE` and `CREATE INDEX` on a table nothing references. Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Postgres.V203

  @states ~w(queued running pausing paused cancelling completed failed cancelled)
  @active_states ~w(queued running pausing paused cancelling)
  @modes ~w(manual auto cron script)

  @doc "The states a run can be in."
  def states, do: @states

  @doc "The states of a run that has not finished: at most one per kind and scope."
  def active_states, do: @active_states

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V207 back: the runs are only history, so the table simply goes."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)
    states = Enum.map_join(@states, ", ", &"'#{&1}'")
    active = Enum.map_join(@active_states, ", ", &"'#{&1}'")
    modes = Enum.map_join(@modes, ", ", &"'#{&1}'")

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_job_runs (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        kind character varying(100) NOT NULL,
        module character varying(100) NOT NULL,
        scope_type character varying(50),
        scope_uuid uuid,
        title character varying(255) NOT NULL,
        state character varying(20) DEFAULT 'queued' NOT NULL,
        done bigint DEFAULT 0 NOT NULL,
        failed_count bigint DEFAULT 0 NOT NULL,
        total bigint,
        cursor jsonb DEFAULT '{}'::jsonb NOT NULL,
        args jsonb DEFAULT '{}'::jsonb NOT NULL,
        result jsonb,
        error text,
        mode character varying(20) DEFAULT 'manual' NOT NULL,
        started_by_uuid uuid,
        paused_by_uuid uuid,
        cancelled_by_uuid uuid,
        generation integer DEFAULT 0 NOT NULL,
        claim_token uuid,
        claimed_at timestamp(0) without time zone,
        oban_job_id bigint,
        restart_seq integer DEFAULT 0 NOT NULL,
        restart_ack integer DEFAULT 0 NOT NULL,
        rescues integer DEFAULT 0 NOT NULL,
        last_rescued_at timestamp(0) without time zone,
        heartbeat_at timestamp(0) without time zone,
        started_at timestamp(0) without time zone,
        paused_at timestamp(0) without time zone,
        cancelled_at timestamp(0) without time zone,
        finished_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        claim_owner character varying(10),
        wake_at timestamp(0) without time zone,
        interruptions integer DEFAULT 0 NOT NULL,
        owner_token uuid,
        CONSTRAINT phoenix_kit_job_runs_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_job_runs_state_check CHECK (state IN (#{states})),
        CONSTRAINT phoenix_kit_job_runs_mode_check CHECK (mode IN (#{modes})),
        CONSTRAINT phoenix_kit_job_runs_scope_check CHECK (
          (scope_type IS NULL AND scope_uuid IS NULL)
          OR (scope_type IS NOT NULL AND scope_uuid IS NOT NULL)
        )
      )
      """,
      # At most one active run per kind and scope: what makes a start
      # idempotent. The site's scope (both NULL) is one scope like another.
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_job_runs_active_index
      ON #{p}phoenix_kit_job_runs (
        kind,
        (COALESCE(scope_type, '')),
        (COALESCE(scope_uuid, '00000000-0000-0000-0000-000000000000'::uuid))
      )
      WHERE state IN (#{active})
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_job_runs_state_index
      ON #{p}phoenix_kit_job_runs (state, inserted_at DESC)
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_job_runs_module_kind_index
      ON #{p}phoenix_kit_job_runs (module, kind)
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_job_runs_scope_uuid_index
      ON #{p}phoenix_kit_job_runs (scope_uuid)
      WHERE scope_uuid IS NOT NULL
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_job_runs_finished_at_index
      ON #{p}phoenix_kit_job_runs (finished_at)
      WHERE finished_at IS NOT NULL
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '207'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "DROP TABLE IF EXISTS #{p}phoenix_kit_job_runs",
      "COMMENT ON TABLE #{p}phoenix_kit IS '206'"
    ]
  end
end
