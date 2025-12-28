defmodule PhoenixKit.Migrations.Postgres.V41 do
  @moduledoc """
  PhoenixKit V41 Migration: Universal Scheduled Jobs System

  This migration introduces a centralized scheduled jobs system that can handle
  any type of scheduled task (posts, emails, notifications, etc.) using a
  polymorphic design with behaviour-based handlers.

  ## Changes

  ### Scheduled Jobs Table (phoenix_kit_scheduled_jobs)
  - Universal job scheduling with polymorphic resource references
  - Handler module storage for dynamic dispatch
  - Status tracking (pending, executed, failed, cancelled)
  - Retry support with attempt tracking
  - Priority-based execution ordering
  - Flexible metadata via JSONB args field

  ## Design

  The system uses a behaviour pattern where handler modules implement:
  - `job_type/0` - Returns the job type string
  - `resource_type/0` - Returns the resource type string
  - `execute/2` - Executes the job with resource_id and args

  ## PostgreSQL Support
  - Uses binary_id primary key
  - Optimized indexes for status + scheduled_at queries
  - Supports prefix for schema isolation
  """
  use Ecto.Migration

  @doc """
  Run the V41 migration to add the scheduled jobs system.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===========================================
    # 1. SCHEDULED JOBS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_scheduled_jobs, primary_key: false, prefix: prefix) do
      add :id, :binary_id, primary_key: true

      # Job type & handler
      add :job_type, :string, null: false
      add :handler_module, :string, null: false

      # Polymorphic resource reference
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false

      # Scheduling
      add :scheduled_at, :utc_datetime_usec, null: false
      add :executed_at, :utc_datetime_usec

      # Status tracking
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :last_error, :text

      # Metadata
      add :args, :map, null: false, default: %{}
      add :priority, :integer, null: false, default: 0

      # Audit - optional user reference (bigint to match phoenix_kit_users.id)
      add :created_by_id, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    # Primary query index: find pending jobs due for execution
    create_if_not_exists index(:phoenix_kit_scheduled_jobs, [:status, :scheduled_at],
                           name: :phoenix_kit_scheduled_jobs_status_scheduled_idx,
                           prefix: prefix
                         )

    # Find jobs for a specific resource
    create_if_not_exists index(:phoenix_kit_scheduled_jobs, [:resource_type, :resource_id],
                           name: :phoenix_kit_scheduled_jobs_resource_idx,
                           prefix: prefix
                         )

    # Filter by job type
    create_if_not_exists index(:phoenix_kit_scheduled_jobs, [:job_type],
                           name: :phoenix_kit_scheduled_jobs_job_type_idx,
                           prefix: prefix
                         )

    # Priority ordering within status
    create_if_not_exists index(:phoenix_kit_scheduled_jobs, [:status, :priority, :scheduled_at],
                           name: :phoenix_kit_scheduled_jobs_priority_idx,
                           prefix: prefix
                         )

    # Add foreign key to users (optional - created_by_id can be null)
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_scheduled_jobs_created_by_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}
        ADD CONSTRAINT phoenix_kit_scheduled_jobs_created_by_id_fkey
        FOREIGN KEY (created_by_id)
        REFERENCES #{prefix_table_name("phoenix_kit_users", prefix)}(id)
        ON DELETE SET NULL;
      END IF;
    EXCEPTION
      WHEN undefined_table THEN
        -- phoenix_kit_users doesn't exist yet, skip FK
        NULL;
    END $$;
    """

    # ===========================================
    # 2. TABLE COMMENTS
    # ===========================================
    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)} IS
    'Universal scheduled jobs system for posts, emails, notifications, etc.'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}.job_type IS
    'Type of job: publish_post, send_email, send_notification, etc.'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}.handler_module IS
    'Elixir module that implements PhoenixKit.ScheduledJobs.Handler behaviour'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}.resource_type IS
    'Type of resource: post, email, notification, etc.'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}.resource_id IS
    'UUID of the target resource in its respective table'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}.status IS
    'Job status: pending, executed, failed, cancelled'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}.args IS
    'JSONB map of additional arguments passed to the handler'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}.priority IS
    'Higher values = higher priority. Jobs with same scheduled_at are ordered by priority DESC'
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '41'"
  end

  @doc """
  Rollback the V41 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop foreign key
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_scheduled_jobs_created_by_id_fkey'
        AND conrelid = '#{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}'::regclass
      ) THEN
        ALTER TABLE #{prefix_table_name("phoenix_kit_scheduled_jobs", prefix)}
        DROP CONSTRAINT phoenix_kit_scheduled_jobs_created_by_id_fkey;
      END IF;
    EXCEPTION
      WHEN undefined_table THEN
        NULL;
    END $$;
    """

    # Drop indexes
    drop_if_exists index(:phoenix_kit_scheduled_jobs, [:status, :priority, :scheduled_at],
                     name: :phoenix_kit_scheduled_jobs_priority_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_scheduled_jobs, [:job_type],
                     name: :phoenix_kit_scheduled_jobs_job_type_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_scheduled_jobs, [:resource_type, :resource_id],
                     name: :phoenix_kit_scheduled_jobs_resource_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_scheduled_jobs, [:status, :scheduled_at],
                     name: :phoenix_kit_scheduled_jobs_status_scheduled_idx,
                     prefix: prefix
                   )

    # Drop table
    drop_if_exists table(:phoenix_kit_scheduled_jobs, prefix: prefix)

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '40'"
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
