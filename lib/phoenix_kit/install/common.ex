defmodule PhoenixKit.Install.Common do
  @moduledoc """
  Common utilities shared between PhoenixKit installation and update tasks.

  This module provides shared functionality for:
  - Timestamp generation
  - Version formatting
  - Status checking
  - Migration detection
  """

  alias PhoenixKit.Config
  alias PhoenixKit.Migrations.Postgres

  @doc """
  Generates timestamp in Ecto migration format.

  ## Examples

      iex> PhoenixKit.Install.Common.generate_timestamp()
      "20250908123045"
  """
  def generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  @doc """
  Pads a number with leading zero if less than 10.

  ## Examples

      iex> PhoenixKit.Install.Common.pad(5)
      "05"

      iex> PhoenixKit.Install.Common.pad(12)
      "12"
  """
  def pad(i) when i < 10, do: <<?0, ?0 + i>>
  def pad(i), do: to_string(i)

  @doc """
  Pads version number for consistent naming.

  ## Examples

      iex> PhoenixKit.Install.Common.pad_version(1)
      "01"

      iex> PhoenixKit.Install.Common.pad_version(15)
      "15"
  """
  def pad_version(version) when version < 10, do: "0#{version}"
  def pad_version(version), do: to_string(version)

  @doc """
  Checks the current installation status for a given prefix.

  Returns one of:
  - `{:not_installed}` - PhoenixKit is not installed
  - `{:current_version, version}` - PhoenixKit is installed with given version

  ## Parameters
  - `prefix` - Database schema prefix (default: "public")

  ## Examples

      iex> PhoenixKit.Install.Common.check_installation_status("public")
      {:current_version, 3}

      iex> PhoenixKit.Install.Common.check_installation_status("auth")
      {:not_installed}
  """
  def check_installation_status(prefix \\ "public") do
    # Use the same version detection logic as the migration system
    opts = %{
      prefix: prefix,
      escaped_prefix: String.replace(prefix, "'", "\\'")
    }

    try do
      # Use PhoenixKit's centralized runtime version detection function
      current_version = Postgres.migrated_version_runtime(opts)

      if current_version > 0 do
        # Valid version found in database
        {:current_version, current_version}
      else
        # Primary detection failed, try alternative detection methods
        check_alternative_version_detection(prefix, opts)
      end
    rescue
      error ->
        # Database error - genuine connection/query failure
        IO.puts("Warning: Database connection failed during version detection: #{inspect(error)}")
        # Try alternative methods before giving up
        check_alternative_version_detection(prefix, opts)
    end
  end

  # Alternative version detection when primary method fails
  defp check_alternative_version_detection(prefix, opts) do
    # Strategy 1: Try direct database query (like status command does)
    case try_direct_database_version_check(opts) do
      version when version > 0 ->
        {:current_version, version}

      _ ->
        # Strategy 2: Check if tables exist and try to infer version
        case check_installation_from_tables(prefix) do
          {:current_version, version} ->
            {:current_version, version}

          {:not_installed} ->
            {:not_installed}
        end
    end
  end

  # Try direct database connection (similar to what status command does)
  defp try_direct_database_version_check(opts) do
    # Try to get the repo from application config first (same as status command)
    repo = Config.get(:repo, nil)

    if repo do
      escaped_prefix = Map.fetch!(opts, :escaped_prefix)
      query_version_directly(repo, escaped_prefix)
    else
      0
    end
  rescue
    _ -> 0
  end

  # Direct version query (simplified version of the runtime check)
  defp query_version_directly(repo, escaped_prefix) do
    # Check if phoenix_kit table exists first
    table_check =
      "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'phoenix_kit' AND table_schema = '#{escaped_prefix}')"

    case repo.query(table_check, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        # Table exists, get version comment
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo.query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) ->
            String.to_integer(version)

          _ ->
            # Table exists but no version comment - assume version 1
            1
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  # Check installation based on table presence and schema analysis
  defp check_installation_from_tables(_prefix) do
    case find_existing_phoenix_kit_migrations() do
      [] ->
        {:not_installed}

      _migrations ->
        # Migration files exist - try to determine actual version from database
        # This is a last resort, assume recent version if tables are expected to exist
        {:current_version, 1}
    end
  end

  @doc """
  Finds existing PhoenixKit migrations in the project.

  Returns a list of migration file paths.
  """
  def find_existing_phoenix_kit_migrations do
    if File.exists?("priv/repo/migrations") do
      "priv/repo/migrations"
      |> File.ls!()
      |> Enum.filter(&phoenix_kit_migration?/1)
      |> Enum.map(&Path.join("priv/repo/migrations", &1))
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Checks if a filename matches PhoenixKit migration pattern.

  ## Examples

      iex> PhoenixKit.Install.Common.phoenix_kit_migration?("20250908_add_phoenix_kit_tables.exs")
      true

      iex> PhoenixKit.Install.Common.phoenix_kit_migration?("20250908_create_users.exs")
      false
  """
  def phoenix_kit_migration?(filename) do
    (String.contains?(filename, "phoenix_kit") ||
       String.contains?(filename, "add_phoenix_kit") ||
       String.contains?(filename, "upgrade_phoenix_kit") ||
       String.contains?(filename, "update_phoenix_kit")) &&
      String.ends_with?(filename, ".exs")
  end

  @doc """
  Describes what changed between versions.

  ## Parameters
  - `from_version` - Starting version number
  - `to_version` - Target version number

  ## Returns
  String describing the changes between versions.
  """
  def describe_version_changes(from_version, to_version) do
    case {from_version, to_version} do
      {1, 3} ->
        "- Remove is_active column from role assignments (simplified role system)\n" <>
          "- Add settings table with user preferences support"

      {2, 3} ->
        "- Add settings table with user preferences support"

      {_, _} when from_version < to_version ->
        "- Various improvements and new features"

      {_, _} ->
        "- No changes (already up to date)"
    end
  end

  @doc """
  Gets current PhoenixKit version from migrations system.
  """
  def current_version, do: Postgres.current_version()

  @doc """
  Gets migrated version for given prefix.

  ## Parameters
  - `prefix` - Database schema prefix
  """
  def migrated_version(prefix \\ "public") do
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}
    Postgres.migrated_version_runtime(opts)
  rescue
    _ -> 0
  end

  @doc """
  Checks if an update is needed from current to target version.

  ## Parameters
  - `prefix` - Database schema prefix
  - `force` - Force update even if already up to date

  ## Returns
  - `{:up_to_date, current_version}` - Already up to date
  - `{:update_needed, current_version, target_version}` - Update available
  - `{:not_installed}` - PhoenixKit not installed
  """
  def check_update_needed(prefix \\ "public", force \\ false) do
    case check_installation_status(prefix) do
      {:not_installed} ->
        {:not_installed}

      {:current_version, current_version} ->
        target_version = current_version()

        cond do
          current_version >= target_version && !force ->
            {:up_to_date, current_version}

          current_version < target_version || force ->
            {:update_needed, current_version, target_version}

          true ->
            {:up_to_date, current_version}
        end
    end
  end
end
