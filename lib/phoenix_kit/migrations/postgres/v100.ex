defmodule PhoenixKit.Migrations.Postgres.V100 do
  @moduledoc """
  V100: Staff module tables.

  Creates four tables used by `phoenix_kit_staff`:

  - `phoenix_kit_staff_departments` — top-level org units
  - `phoenix_kit_staff_teams` — teams inside a department
  - `phoenix_kit_staff_people` — staff profiles, each linked 1:1 to a
    `phoenix_kit_users` row (required FK)
  - `phoenix_kit_staff_team_memberships` — join table for team membership

  UUIDv7 primary keys, `timestamptz` timestamps, cascading deletes
  department → team → team_memberships; person deletion cascades to
  team_memberships; user deletion cascades to the staff person profile.

  Departments and teams are identified by UUID only — no slug columns.
  A team's name must be unique within its department.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_departments (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_departments_name_index
    ON #{p}phoenix_kit_staff_departments (lower(name))
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_teams (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      department_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE CASCADE,
      name VARCHAR(255) NOT NULL,
      description TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_name_index
    ON #{p}phoenix_kit_staff_teams (department_uuid, lower(name))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_index
    ON #{p}phoenix_kit_staff_teams (department_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_people (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      user_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
      primary_department_uuid UUID REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      job_title VARCHAR(255),
      employment_type VARCHAR(20),
      employment_start_date DATE,
      employment_end_date DATE,
      work_location VARCHAR(255),
      work_phone VARCHAR(50),
      personal_phone VARCHAR(50),
      bio TEXT,
      skills TEXT,
      notes TEXT,
      date_of_birth DATE,
      personal_email VARCHAR(255),
      emergency_contact_name VARCHAR(255),
      emergency_contact_phone VARCHAR(50),
      emergency_contact_relationship VARCHAR(100),
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_people_user_index
    ON #{p}phoenix_kit_staff_people (user_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_primary_department_index
    ON #{p}phoenix_kit_staff_people (primary_department_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_status_index
    ON #{p}phoenix_kit_staff_people (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_team_memberships (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      team_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE CASCADE,
      staff_person_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_team_person_index
    ON #{p}phoenix_kit_staff_team_memberships (team_uuid, staff_person_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_person_index
    ON #{p}phoenix_kit_staff_team_memberships (staff_person_uuid)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '100'")
  end

  @doc """
  Drops all four staff tables.

  **Lossy rollback:** all staff data (departments, teams, people, and
  their team memberships) is permanently destroyed. Back up before
  rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_staff_team_memberships")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_staff_people")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_staff_teams")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_staff_departments")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '99'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
