defmodule PhoenixKit.Migrations.UUIDRepair do
  @moduledoc """
  Repairs missing UUID columns for databases upgrading from PhoenixKit < 1.7.0.

  ## Problem

  PhoenixKit 1.7.x added UUID columns to all legacy tables in migration V40.
  However, some migrations before V40 (e.g., V31) use Ecto schemas that expect
  the `uuid` column to exist. This creates a chicken-and-egg problem for users
  upgrading from older versions.

  ## Solution

  This module detects the condition and adds UUID columns BEFORE running
  migrations, ensuring V31+ can use Ecto schemas without errors.

  ## When It Runs

  Called automatically by `mix phoenix_kit.update` when:
  1. Current database version is < 40
  2. Tables exist but are missing uuid columns

  ## Tables Affected

  Only repairs tables that:
  1. Exist in the database
  2. Are missing the uuid column
  3. Are used by Ecto schemas in migrations before V40

  Primary tables:
  - phoenix_kit_settings (used by V35, V36)
  - phoenix_kit_email_templates (used by V31)
  """

  require Logger

  @tables_needing_repair [
    :phoenix_kit_settings,
    :phoenix_kit_email_templates
  ]

  @doc """
  Checks if UUID repair is needed and performs it if necessary.

  Returns:
  - `{:ok, :not_needed}` - No repair needed (fresh install or already has uuid)
  - `{:ok, :repaired}` - Repair was performed successfully
  - `{:error, reason}` - Repair failed
  """
  def maybe_repair(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    with {:ok, repo} <- get_repo(),
         {:ok, version} <- get_current_version(repo, prefix),
         {:ok, needs_repair} <- check_needs_repair(repo, prefix, version) do
      if needs_repair do
        perform_repair(repo, prefix)
      else
        {:ok, :not_needed}
      end
    end
  end

  @doc """
  Checks if repair is needed without performing it.

  Useful for dry-run or status checks.
  """
  def needs_repair?(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    with {:ok, repo} <- get_repo(),
         {:ok, version} <- get_current_version(repo, prefix) do
      check_needs_repair(repo, prefix, version)
    end
  end

  ## Private Functions

  defp get_repo do
    case PhoenixKit.RepoHelper.repo() do
      nil -> {:error, :no_repo_configured}
      repo -> {:ok, repo}
    end
  end

  defp get_current_version(repo, prefix) do
    query = """
    SELECT obj_description('#{prefix}.phoenix_kit'::regclass, 'pg_class')::integer
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_integer(version) ->
        {:ok, version}

      {:ok, %{rows: [[nil]]}} ->
        # No version comment - treat as very old
        {:ok, 0}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        # Table doesn't exist - fresh install, no repair needed
        {:ok, :fresh_install}

      {:error, reason} ->
        {:error, {:version_check_failed, reason}}
    end
  end

  defp check_needs_repair(_repo, _prefix, :fresh_install) do
    # Fresh install - V15+ will create tables with uuid
    {:ok, false}
  end

  defp check_needs_repair(_repo, _prefix, version) when version >= 40 do
    # Already at V40+ - uuid columns should exist
    {:ok, false}
  end

  defp check_needs_repair(repo, prefix, version) when version < 40 do
    # Version < 40, need to check if tables are missing uuid
    missing_uuid =
      Enum.any?(@tables_needing_repair, fn table ->
        table_exists?(repo, table, prefix) and not column_exists?(repo, table, :uuid, prefix)
      end)

    {:ok, missing_uuid}
  end

  defp perform_repair(repo, prefix) do
    Logger.info("[PhoenixKit] Starting UUID column repair for upgrade compatibility...")

    # First ensure pgcrypto extension exists
    ensure_pgcrypto(repo)

    # Repair each table that needs it
    results =
      Enum.map(@tables_needing_repair, fn table ->
        repair_table(repo, table, prefix)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      repaired_count = Enum.count(results, &match?({:ok, :repaired}, &1))
      Logger.info("[PhoenixKit] UUID repair complete. #{repaired_count} table(s) repaired.")
      {:ok, :repaired}
    else
      {:error, {:repair_failed, errors}}
    end
  end

  defp ensure_pgcrypto(repo) do
    repo.query("CREATE EXTENSION IF NOT EXISTS pgcrypto", [], log: false)
  end

  defp repair_table(repo, table, prefix) do
    table_name = prefix_table_name(Atom.to_string(table), prefix)

    cond do
      not table_exists?(repo, table, prefix) ->
        # Table doesn't exist - skip (will be created properly by migrations)
        {:ok, :skipped}

      column_exists?(repo, table, :uuid, prefix) ->
        # UUID column already exists - nothing to do
        {:ok, :skipped}

      true ->
        # Need to add uuid column
        Logger.info("[PhoenixKit] Adding uuid column to #{table_name}...")

        add_uuid_query = """
        ALTER TABLE #{table_name}
        ADD COLUMN uuid UUID DEFAULT gen_random_uuid()
        """

        backfill_query = """
        UPDATE #{table_name}
        SET uuid = gen_random_uuid()
        WHERE uuid IS NULL
        """

        with {:ok, _} <- repo.query(add_uuid_query, [], log: false),
             {:ok, _} <- repo.query(backfill_query, [], log: false) do
          Logger.info("[PhoenixKit] Successfully added uuid to #{table_name}")
          {:ok, :repaired}
        else
          {:error, reason} ->
            Logger.error("[PhoenixKit] Failed to add uuid to #{table_name}: #{inspect(reason)}")
            {:error, {table, reason}}
        end
    end
  end

  defp table_exists?(repo, table, prefix) do
    table_name = Atom.to_string(table)

    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = $1
      AND table_name = $2
    )
    """

    case repo.query(query, [prefix, table_name], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(repo, table, column, prefix) do
    table_name = Atom.to_string(table)
    column_name = Atom.to_string(column)

    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_schema = $1
      AND table_name = $2
      AND column_name = $3
    )
    """

    case repo.query(query, [prefix, table_name, column_name], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
