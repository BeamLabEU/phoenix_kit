defmodule PhoenixKit.Migrations.Postgres.V106 do
  @moduledoc """
  V106: Split `phoenix_kit_projects.name` uniqueness across templates and
  real projects.

  V101 created a single global unique index
  (`phoenix_kit_projects_name_index`) on `lower(name)` over the
  `phoenix_kit_projects` table. Templates and real projects share that
  table — distinguished only by the `is_template` boolean — so they
  also shared one name namespace, which made
  `Projects.create_project_from_template/2` collide whenever a real
  project should reuse the source template's name (the common,
  expected case).

  This migration replaces that single index with two partial unique
  indexes — one per `is_template` value — so a template "Onboarding"
  and a real project "Onboarding" can coexist freely.

  ## Indexes

  - `phoenix_kit_projects_name_template_index`
    `UNIQUE (lower(name)) WHERE is_template = true`
  - `phoenix_kit_projects_name_project_index`
    `UNIQUE (lower(name)) WHERE is_template = false`

  Both are idempotent (`CREATE INDEX IF NOT EXISTS` / `DROP INDEX IF
  EXISTS`).

  Schema-side change only. The Ecto changeset's `unique_constraint(:name,
  name: :phoenix_kit_projects_name_index, ...)` reference is updated in
  the same release of `phoenix_kit_projects` to point at whichever
  partial index applies (the `is_template` value at validate time
  selects the correct constraint name).
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_name_index")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_template_index
    ON #{p}phoenix_kit_projects (lower(name))
    WHERE is_template = true
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_project_index
    ON #{p}phoenix_kit_projects (lower(name))
    WHERE is_template = false
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '105'")
  end

  @doc """
  Reverts to V101's single global unique index.

  **Lossy rollback:** if the post-V106 state has both a template and a
  real project with the same name, recreating the single
  `phoenix_kit_projects_name_index` will fail with a uniqueness
  violation. Resolve duplicates before rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_name_project_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_name_template_index")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_index
    ON #{p}phoenix_kit_projects (lower(name))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '104'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
