defmodule PhoenixKit.Migrations.Postgres.V101 do
  @moduledoc """
  V101: Projects module tables.

  Creates five tables used by `phoenix_kit_projects`:

  - `phoenix_kit_project_tasks` — reusable task library with default
    assignees and estimated duration
  - `phoenix_kit_project_task_dependencies` — "task A must finish before
    task B" links at the template (library) level
  - `phoenix_kit_projects` — project containers with start mode
    (immediate / scheduled)
  - `phoenix_kit_project_assignments` — task instance in a project;
    copies duration + description from template (editable independently)
  - `phoenix_kit_project_dependencies` — per-project assignment-level
    "A must finish before B" links

  Each assignment and task template may have **at most one** assignee
  (team, department, or person) — enforced by `CHECK (num_nonnulls(...) <= 1)`
  on both tables.

  Depends on V100 (staff tables) for the polymorphic assignee foreign keys.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_tasks (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      title VARCHAR(255) NOT NULL,
      description TEXT,
      estimated_duration INTEGER,
      estimated_duration_unit VARCHAR(20) DEFAULT 'hours',
      default_assigned_team_uuid UUID REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      default_assigned_department_uuid UUID REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      default_assigned_person_uuid UUID REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE SET NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_tasks_single_default_assignee
        CHECK (num_nonnulls(default_assigned_team_uuid, default_assigned_department_uuid, default_assigned_person_uuid) <= 1)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_tasks_title_index
    ON #{p}phoenix_kit_project_tasks (lower(title))
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_projects (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      is_template BOOLEAN NOT NULL DEFAULT false,
      counts_weekends BOOLEAN NOT NULL DEFAULT false,
      start_mode VARCHAR(20) NOT NULL DEFAULT 'immediate',
      scheduled_start_date DATE,
      started_at TIMESTAMPTZ,
      completed_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_index
    ON #{p}phoenix_kit_projects (lower(name))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_projects_status_index
    ON #{p}phoenix_kit_projects (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_assignments (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      project_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_projects(uuid) ON DELETE CASCADE,
      task_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      status VARCHAR(20) NOT NULL DEFAULT 'todo',
      position INTEGER NOT NULL DEFAULT 0,
      description TEXT,
      estimated_duration INTEGER,
      estimated_duration_unit VARCHAR(20),
      assigned_team_uuid UUID REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE SET NULL,
      assigned_department_uuid UUID REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      assigned_person_uuid UUID REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE SET NULL,
      counts_weekends BOOLEAN,
      progress_pct INTEGER NOT NULL DEFAULT 0,
      track_progress BOOLEAN NOT NULL DEFAULT false,
      completed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      completed_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_project_assignments_single_assignee
        CHECK (num_nonnulls(assigned_team_uuid, assigned_department_uuid, assigned_person_uuid) <= 1)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_project_index
    ON #{p}phoenix_kit_project_assignments (project_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_status_index
    ON #{p}phoenix_kit_project_assignments (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_task_index
    ON #{p}phoenix_kit_project_assignments (task_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_team_index
    ON #{p}phoenix_kit_project_assignments (assigned_team_uuid)
    WHERE assigned_team_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_department_index
    ON #{p}phoenix_kit_project_assignments (assigned_department_uuid)
    WHERE assigned_department_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_person_index
    ON #{p}phoenix_kit_project_assignments (assigned_person_uuid)
    WHERE assigned_person_uuid IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_assignments_completed_by_index
    ON #{p}phoenix_kit_project_assignments (completed_by_uuid)
    WHERE completed_by_uuid IS NOT NULL
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_dependencies (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      assignment_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      depends_on_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_assignments(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_dependencies_pair_index
    ON #{p}phoenix_kit_project_dependencies (assignment_uuid, depends_on_uuid)
    """)

    # Reverse lookup: "which assignments depend on X?" (impact analysis when
    # marking X done). The pair index above only helps forward lookups.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_project_dependencies_depends_on_index
    ON #{p}phoenix_kit_project_dependencies (depends_on_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_project_task_dependencies (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      task_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      depends_on_task_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_project_tasks(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_project_task_deps_pair_index
    ON #{p}phoenix_kit_project_task_dependencies (task_uuid, depends_on_task_uuid)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '101'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_task_dependencies")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_dependencies")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_assignments")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_projects")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_tasks")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '100'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
