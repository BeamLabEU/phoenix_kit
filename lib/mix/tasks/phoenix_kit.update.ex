defmodule Mix.Tasks.PhoenixKit.Update do
  use Mix.Task

  @moduledoc """
  Updates PhoenixKit to the latest version.

  This task handles updating an existing PhoenixKit installation to the latest version
  by creating upgrade migrations that preserve existing data while adding new features.

  ## Usage

      $ mix phoenix_kit.update
      $ mix phoenix_kit.update --prefix=myapp
      $ mix phoenix_kit.update --status
      $ mix phoenix_kit.update --skip-assets

  ## Options

    * `--prefix` - Database schema prefix (default: "public")
    * `--status` - Show current installation status and available updates
    * `--force` - Force update even if already up to date
    * `--skip-assets` - Skip automatic asset rebuild check

  ## Examples

      # Update PhoenixKit to latest version
      mix phoenix_kit.update

      # Check what version is installed and what updates are available
      mix phoenix_kit.update --status

      # Update with custom schema prefix
      mix phoenix_kit.update --prefix=auth

  ## Version Management

  PhoenixKit uses a versioned migration system similar to Oban. Each version
  contains specific database schema changes that can be applied incrementally.

  Current version: V07 (latest version with comprehensive features)
  - V01: Basic authentication with role system
  - V02: Remove is_active column from role assignments (direct deletion)
  - V03-V07: Additional features and improvements (see migration files for details)

  ## Safe Updates

  All PhoenixKit updates are designed to be:
  - Non-destructive (existing data is preserved)
  - Backward compatible (existing code continues to work)
  - Idempotent (safe to run multiple times)
  - Rollback-capable (can be reverted if needed)
  """

  alias PhoenixKit.Install.{AssetRebuild, Common}
  alias PhoenixKit.Utils.Routes

  @shortdoc "Updates PhoenixKit to the latest version"

  @switches [
    prefix: :string,
    status: :boolean,
    force: :boolean,
    skip_assets: :boolean
  ]

  @aliases [
    p: :prefix,
    s: :status,
    f: :force
  ]

  @impl Mix.Task
  def run(argv) do
    # Ensure application is started for proper version detection
    Mix.Task.run("app.start")

    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    if opts[:status] do
      show_status(opts)
    else
      perform_update(opts)
    end
  end

  # Show current installation status and available updates
  defp show_status(opts) do
    prefix = opts[:prefix] || "public"

    # Use the status command to show current status
    args = if prefix == "public", do: [], else: ["--prefix=#{prefix}"]
    Mix.Task.run("phoenix_kit.status", args)
  end

  # Handle not installed scenario
  defp handle_not_installed do
    Mix.shell().error("""

    ❌ PhoenixKit is not installed.

    Please run: mix phoenix_kit.install
    """)
  end

  # Handle update check logic
  defp handle_update_check(prefix, current_version, force, skip_assets) do
    target_version = Common.current_version()

    cond do
      current_version >= target_version && !force ->
        handle_already_up_to_date(current_version)

      current_version < target_version || force ->
        handle_update_needed(prefix, current_version, target_version, force, skip_assets)

      true ->
        Mix.shell().info("No update needed.")
    end
  end

  # Handle already up to date scenario
  defp handle_already_up_to_date(current_version) do
    Mix.shell().info("""

    ✅ PhoenixKit is already up to date (V#{pad_version(current_version)}).

    Use --force to regenerate the migration anyway.
    """)
  end

  # Handle update needed scenario
  defp handle_update_needed(prefix, current_version, target_version, force, skip_assets) do
    migration_file = create_update_migration(prefix, current_version, target_version, force)

    # Always rebuild assets unless explicitly skipped
    unless skip_assets do
      AssetRebuild.check_and_rebuild(verbose: true)
    end

    # Run interactive migration execution
    run_update_migration_interactive(migration_file)
  end

  # Perform the actual update
  defp perform_update(opts) do
    prefix = opts[:prefix] || "public"
    force = opts[:force] || false
    skip_assets = opts[:skip_assets] || false

    case Common.check_installation_status(prefix) do
      {:not_installed} ->
        handle_not_installed()

      {:current_version, current_version} ->
        handle_update_check(prefix, current_version, force, skip_assets)
    end
  end

  # Create update migration from current to target version
  defp create_update_migration(prefix, current_version, target_version, force) do
    create_schema = prefix != "public"

    # Ensure migrations directory exists
    migrations_dir = "priv/repo/migrations"
    File.mkdir_p!(migrations_dir)

    # Generate timestamp and migration file name using Ecto format
    timestamp = generate_timestamp()
    action = if force, do: "force_update", else: "update"

    migration_name =
      "#{timestamp}_phoenix_kit_#{action}_v#{pad_version(current_version)}_to_v#{pad_version(target_version)}.exs"

    migration_file = Path.join(migrations_dir, migration_name)

    # Generate module name
    module_name =
      "PhoenixKit#{String.capitalize(action)}V#{pad_version(current_version)}ToV#{pad_version(target_version)}"

    # Create migration content
    migration_content = """
    defmodule Ecto.Migrations.#{module_name} do
      @moduledoc false
      use Ecto.Migration

      def up do
        # PhoenixKit Update Migration: V#{pad_version(current_version)} -> V#{pad_version(target_version)}
        PhoenixKit.Migrations.up([
          prefix: "#{prefix}",
          version: #{target_version},
          create_schema: #{create_schema}
        ])
      end

      def down do
        # Rollback PhoenixKit to V#{pad_version(current_version)}
        PhoenixKit.Migrations.down([
          prefix: "#{prefix}",
          version: #{current_version}
        ])
      end
    end
    """

    # Write migration file
    File.write!(migration_file, migration_content)

    # Show brief success notice
    Mix.shell().info("""

    📦 PhoenixKit Update Migration Created: #{migration_name}
    - Updating from V#{pad_version(current_version)} to V#{pad_version(target_version)}
    """)

    # Return migration file for interactive execution
    migration_name
  end

  # Run interactive migration execution (similar to install command)
  defp run_update_migration_interactive(migration_file) do
    # Check if we can run migrations safely
    case check_migration_conditions() do
      :ok ->
        run_interactive_migration_prompt(migration_file)

      {:error, reason} ->
        Mix.shell().info("""

        💡 Migration not run automatically (#{reason}).
        To run migration manually:
          mix ecto.migrate
        """)
    end
  end

  # Check if migration can be run interactively
  defp check_migration_conditions do
    # Check if we have an app name
    case Mix.Project.config()[:app] do
      nil ->
        {:error, "No app name found"}

      _app ->
        # Check if we're in interactive environment
        if System.get_env("CI") || !System.get_env("TERM") do
          {:error, "Non-interactive environment"}
        else
          :ok
        end
    end
  rescue
    _ -> {:error, "Error checking conditions"}
  end

  # Prompt user for migration execution
  defp run_interactive_migration_prompt(_migration_file) do
    Mix.shell().info("""

    🚀 Would you like to run the database migration now?
    This will update your PhoenixKit installation.

    Options:
    - y/yes: Run 'mix ecto.migrate' now
    - n/no:  Skip migration (you can run it manually later)
    """)

    case Mix.shell().prompt("Run migration? [Y/n]")
         |> String.trim()
         |> String.downcase() do
      response when response in ["", "y", "yes"] ->
        run_migration_with_feedback()

      _ ->
        Mix.shell().info("""

        ⚠️  Migration skipped. To run it manually later:
          mix ecto.migrate
        """)
    end
  end

  # Execute migration with feedback
  defp run_migration_with_feedback do
    Mix.shell().info("\n⏳ Running database migration...")

    try do
      case System.cmd("mix", ["ecto.migrate"], stderr_to_stdout: true) do
        {output, 0} ->
          Mix.shell().info("\n✅ Migration completed successfully!")
          Mix.shell().info(output)
          show_update_success_notice()

        {output, _} ->
          Mix.shell().info("\n❌ Migration failed:")
          Mix.shell().info(output)
          show_manual_migration_instructions()
      end
    rescue
      error ->
        Mix.shell().info("\n⚠️  Migration execution failed: #{inspect(error)}")
        show_manual_migration_instructions()
    end
  end

  # Show success notice after update
  defp show_update_success_notice do
    Mix.shell().info("""
    🎉 PhoenixKit updated successfully! Visit: #{Routes.path("/users/register")}
    """)
  end

  # Show manual migration instructions
  defp show_manual_migration_instructions do
    Mix.shell().info("""
    Please run the migration manually:
      mix ecto.migrate

    Then start your server:
      mix phx.server
    """)
  end

  # Generate timestamp in Ecto migration format (same as phoenix_kit.install.ex)
  defp generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)

  # Pad version number for consistent naming
  defp pad_version(version) when version < 10, do: "0#{version}"
  defp pad_version(version), do: to_string(version)
end
