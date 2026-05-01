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

  ## Schema-side change only — changeset half lives downstream

  Core owns the SQL. The matching `unique_constraint(...)` swap on
  the `Project` schema lives in the **downstream `phoenix_kit_projects`
  package**, not in this repo (no `phoenix_kit_projects` schema
  exists under `lib/` here — `rg phoenix_kit_projects_name_template_index
  lib/` will only return this migration).

  The downstream changeset picks
  `:phoenix_kit_projects_name_template_index` vs
  `:phoenix_kit_projects_name_project_index` based on the
  `is_template` field at validate time, so unique-name violations
  surface as a clean `name has already been taken` form error
  instead of a generic FK error path. Without the changeset half
  shipped alongside this migration, the V106 split would be
  invisible to end users — they'd still see the legacy single
  constraint name in error tuples.
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

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '106'")
  end

  @doc """
  Reverts to V101's single global unique index.

  **Lossy rollback:** if the post-V106 state has both a template and a
  real project with the same name, recreating the single
  `phoenix_kit_projects_name_index` will fail with a uniqueness
  violation. Resolve duplicates before rolling back in production.

  The down step pre-checks for cross-mode duplicates and raises an
  actionable message (naming one offending row) BEFORE dropping the
  partial indexes. Without the pre-check, operators would hit a
  generic Postgres `duplicate key value violates unique constraint`
  during the `CREATE UNIQUE INDEX` step — same end result but the
  error message wouldn't tell them which name to resolve, and by then
  the partial indexes have already been dropped, leaving the table
  with no name uniqueness at all.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Pre-check: find a `lower(name)` that exists across both
    # template and project rows. The partial indexes V106 added each
    # cover one bucket, so they don't collide today; the global
    # index we're about to recreate would.
    case repo().query!(
           "SELECT lower(name) FROM #{p}phoenix_kit_projects " <>
             "GROUP BY lower(name) HAVING count(*) > 1 LIMIT 1",
           [],
           log: false
         ) do
      %{rows: []} ->
        :ok

      %{rows: [[duplicate_name]]} ->
        raise """
        Cannot roll back V106: name #{inspect(duplicate_name)} exists \
        in both `phoenix_kit_projects` rows that V106's split allowed \
        to coexist (template + real project, or two of either kind \
        sharing a name). Resolve the duplicate before rolling back \
        — either delete one of the rows or rename it. The down step \
        recreates a single global UNIQUE index on (lower(name)) which \
        these duplicates would violate.\
        """
    end

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_name_project_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_projects_name_template_index")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_projects_name_index
    ON #{p}phoenix_kit_projects (lower(name))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '105'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
