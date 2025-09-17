defmodule PhoenixKit.Install.MigrationStrategy do
  @moduledoc """
  Handles migration strategy determination and execution for PhoenixKit installation.

  This module provides functionality to:
  - Determine whether installation is new, upgrade, or up-to-date
  - Create initial migration files
  - Handle interactive migration prompts
  - Generate appropriate migration notices
  """

  alias Igniter.Project.Application
  alias PhoenixKit.Install.Common
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Utils.Routes

  @doc """
  Creates PhoenixKit migration without interactive prompts (used by igniter).

  ## Parameters
  - `igniter` - The igniter context
  - `opts` - Installation options including prefix and create_schema

  ## Returns
  Updated igniter with migration files created or appropriate notices.
  """
  def create_phoenix_kit_migration_only(igniter, opts) do
    prefix = opts[:prefix] || "public"
    create_schema = opts[:create_schema] != false && prefix != "public"

    # Check if this is a new installation or existing installation
    case determine_migration_strategy(igniter, prefix) do
      {:new_install, igniter} ->
        create_initial_migration_silent(igniter, prefix, create_schema)

      {:upgrade_needed, igniter, current_version, target_version} ->
        handle_upgrade_needed(igniter, prefix, current_version, target_version)

      {:up_to_date, igniter} ->
        handle_up_to_date(igniter, prefix)

      {:error, igniter, reason} ->
        Igniter.add_warning(igniter, "Could not determine migration strategy: #{reason}")
        igniter
    end
  end

  @doc """
  Handles interactive migration after configuration changes are complete.

  This function is called outside of the Igniter context to prompt for
  migration execution and handle the results.
  """
  def handle_interactive_migration_after_config(opts \\ []) do
    # Check if this is a new installation that needs migration
    case determine_migration_strategy_simple(opts) do
      {:new_install, migration_file} ->
        # Check if we can run migrations safely
        case check_migration_conditions_simple() do
          :ok ->
            run_interactive_migration_prompt_simple(migration_file)

          {:error, reason} ->
            fallback_migration_notice_simple(reason)
        end

      {:upgrade_needed, current_version, target_version} ->
        show_upgrade_needed_notice(opts, current_version, target_version)

      {:up_to_date} ->
        show_up_to_date_notice(opts)

      {:no_migration_needed} ->
        # Migration already handled or not needed
        :ok
    end
  end

  # Determine whether this is a new install, upgrade, or already up to date
  defp determine_migration_strategy(igniter, _prefix) do
    case Application.app_name(igniter) do
      nil ->
        {:error, igniter, "Could not determine app name"}

      _app_name ->
        migrations_dir = Path.join(["priv", "repo", "migrations"])

        case find_phoenix_kit_migrations(migrations_dir) do
          [] ->
            # No existing PhoenixKit migrations
            {:new_install, igniter}

          _existing_migrations ->
            # Check current and target versions using proper DB method
            # Default prefix for install
            prefix = "public"

            try do
              current_version = Common.migrated_version(prefix)
              target_version = Postgres.current_version()

              cond do
                current_version < target_version ->
                  {:upgrade_needed, igniter, current_version, target_version}

                current_version >= target_version ->
                  {:up_to_date, igniter}
              end
            rescue
              _ ->
                # If DB not accessible but migration files exist, this is an update case
                # Migration files exist but haven't been run yet
                # No DB table = version 0
                current_version = 0
                target_version = Postgres.current_version()
                {:upgrade_needed, igniter, current_version, target_version}
            end
        end
    end
  end

  # Determine migration strategy outside of igniter context
  defp determine_migration_strategy_simple(opts) do
    prefix = opts[:prefix] || "public"
    migrations_dir = Path.join(["priv", "repo", "migrations"])

    case find_phoenix_kit_migrations(migrations_dir) do
      [] ->
        check_for_new_migration_file(migrations_dir)

      existing_migrations ->
        check_existing_migrations(existing_migrations, prefix)
    end
  rescue
    _ ->
      {:no_migration_needed}
  end

  # Check if a new migration file was created during igniter process
  defp check_for_new_migration_file(migrations_dir) do
    migrations_dir
    |> File.ls!()
    |> Enum.find(&new_install_migration?/1)
    |> case do
      nil -> {:no_migration_needed}
      migration_file -> {:new_install, migration_file}
    end
  end

  # Check existing migrations for new install or upgrade scenario
  defp check_existing_migrations(existing_migrations, prefix) do
    case find_new_install_migration(existing_migrations) do
      {:found, filename} ->
        {:new_install, filename}

      :not_found ->
        check_version_upgrade_needed(prefix)
    end
  end

  # Find newly created install migration among existing migrations
  defp find_new_install_migration(existing_migrations) do
    new_migration =
      Enum.find(existing_migrations, fn migration_path ->
        filename = Path.basename(migration_path)
        new_install_migration?(filename)
      end)

    case new_migration do
      nil -> :not_found
      migration -> {:found, Path.basename(migration)}
    end
  end

  # Check if filename matches new install migration pattern
  defp new_install_migration?(filename) do
    String.contains?(filename, "add_phoenix_kit_tables") &&
      String.ends_with?(filename, ".exs")
  end

  # Check if version upgrade is needed by comparing DB version with target
  defp check_version_upgrade_needed(prefix) do
    current_version = Common.migrated_version(prefix)
    target_version = Postgres.current_version()

    cond do
      current_version < target_version ->
        {:upgrade_needed, current_version, target_version}

      current_version >= target_version ->
        {:up_to_date}
    end
  rescue
    _ ->
      # If DB not accessible but migration files exist, this is probably upgrade case
      current_version = 0
      target_version = Postgres.current_version()
      {:upgrade_needed, current_version, target_version}
  end

  # Silent version for use during igniter process
  defp create_initial_migration_silent(igniter, prefix, create_schema) do
    case Application.app_name(igniter) do
      nil ->
        Igniter.add_warning(igniter, "Could not determine app name for migration")

      app_name ->
        timestamp = Common.generate_timestamp()
        migration_file = "#{timestamp}_add_phoenix_kit_tables.exs"
        migration_path = Path.join(["priv", "repo", "migrations", migration_file])

        module_name =
          "#{Macro.camelize(to_string(app_name))}.Repo.Migrations.AddPhoenixKitTables"

        migration_opts = migration_opts(prefix, create_schema)

        migration_content = """
        defmodule #{module_name} do
          use Ecto.Migration

          def up, do: PhoenixKit.Migrations.up(#{migration_opts})

          def down, do: PhoenixKit.Migrations.down(#{migration_opts})
        end
        """

        # Get PhoenixKit version info from mix.exs
        phoenix_kit_version =
          case :application.get_key(:phoenix_kit, :vsn) do
            {:ok, vsn} when is_list(vsn) -> List.to_string(vsn)
            {:ok, vsn} -> to_string(vsn)
            :undefined -> "unknown"
          end

        migration_version = Postgres.current_version()

        initial_notice = """

        📦 PhoenixKit V#{phoenix_kit_version} migration ready: #{migration_file}
        Target version: V#{Common.pad_version(migration_version)}
        """

        igniter
        |> Igniter.create_new_file(migration_path, migration_content)
        |> Igniter.add_notice(initial_notice)
    end
  end

  # Handle upgrade needed scenario
  defp handle_upgrade_needed(igniter, prefix, current_version, target_version) do
    notice = generate_upgrade_notice(prefix, current_version, target_version)
    Igniter.add_notice(igniter, notice)
    igniter
  end

  # Handle up to date scenario
  defp handle_up_to_date(igniter, prefix) do
    notice = generate_up_to_date_notice(prefix)
    Igniter.add_notice(igniter, notice)
    igniter
  end

  # Generate upgrade needed notice
  defp generate_upgrade_notice(prefix, current_version, target_version) do
    prefix_option = if prefix != "public", do: " --prefix=#{prefix}", else: ""

    """

    📦 PhoenixKit is already installed (V#{Common.pad_version(current_version)}).

    To update to the latest version (V#{Common.pad_version(target_version)}), please use:
      mix phoenix_kit.update#{prefix_option}

    To check current status:
      mix phoenix_kit.update --status#{prefix_option}
    """
  end

  # Generate up to date notice
  defp generate_up_to_date_notice(prefix) do
    prefix_option = if prefix != "public", do: " --prefix=#{prefix}", else: ""

    """

    ✅ PhoenixKit is already installed and up to date.

    To check current status:
      mix phoenix_kit.update --status#{prefix_option}

    To force reinstall:
      mix phoenix_kit.update --force#{prefix_option}
    """
  end

  # Interactive migration functions (called outside igniter)

  # Simplified migration conditions check (without igniter)
  defp check_migration_conditions_simple do
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

  # Simplified interactive prompt (without igniter)
  defp run_interactive_migration_prompt_simple(_migration_file) do
    prompt = """

    🚀 Would you like to run the database migration now?
    This will create the PhoenixKit tables.

    Options:
    - y/yes: Run 'mix ecto.migrate' now
    - n/no:  Skip migration (you can run it manually later)
    """

    IO.puts(prompt)

    case (try do
            Mix.shell().prompt("Run migration? [Y/n]")
          rescue
            _ -> "n"
          end)
         |> String.trim()
         |> String.downcase() do
      response when response in ["", "y", "yes"] ->
        run_migration_with_feedback_simple()

      _ ->
        manual_migration_notice_simple()
    end
  end

  # Simplified migration execution
  defp run_migration_with_feedback_simple do
    IO.puts("\n⏳ Running database migration...")

    try do
      case System.cmd("mix", ["ecto.migrate"], stderr_to_stdout: true) do
        {output, 0} ->
          IO.puts("\n✅ Migration completed successfully!\n")
          IO.puts(output)
          show_success_notice()

        {output, _} ->
          IO.puts("\n❌ Migration failed:")
          IO.puts(output)
          show_manual_migration_instructions()
      end
    rescue
      error ->
        IO.puts("\n⚠️  Migration execution failed: #{inspect(error)}")
        show_manual_migration_instructions()
    end
  end

  # Notice functions for interactive migration
  defp manual_migration_notice_simple do
    IO.puts("""

    ⚠️  Migration skipped. To run it manually later:
      mix ecto.migrate
    """)
  end

  defp fallback_migration_notice_simple(reason) do
    IO.puts("""

    💡 Migration not run automatically (#{reason}).
    To run migration manually:
      mix ecto.migrate
    """)
  end

  defp show_success_notice do
    IO.puts("""
    🎉 PhoenixKit ready! Visit: #{Routes.path("/users/register")}
    """)
  end

  defp show_manual_migration_instructions do
    IO.puts("""
    Please run the migration manually:
      mix ecto.migrate

    Then start your server:
      mix phx.server
    """)
  end

  # Show upgrade needed notice (simple version)
  defp show_upgrade_needed_notice(opts, current_version, target_version) do
    prefix = opts[:prefix] || "public"
    prefix_option = if prefix != "public", do: " --prefix=#{prefix}", else: ""

    IO.puts("""

    📦 PhoenixKit is already installed (V#{Common.pad_version(current_version)}).

    To update to the latest version (V#{Common.pad_version(target_version)}), please use:
      mix phoenix_kit.update#{prefix_option}

    To check current status:
      mix phoenix_kit.update --status#{prefix_option}
    """)
  end

  # Show up to date notice (simple version)
  defp show_up_to_date_notice(opts) do
    prefix = opts[:prefix] || "public"
    prefix_option = if prefix != "public", do: " --prefix=#{prefix}", else: ""

    IO.puts("""

    ✅ PhoenixKit is already installed and up to date.

    To check current status:
      mix phoenix_kit.update --status#{prefix_option}

    To force reinstall:
      mix phoenix_kit.update --force#{prefix_option}
    """)
  end

  # Utility functions

  # Find all existing PhoenixKit migrations
  defp find_phoenix_kit_migrations(migrations_dir) do
    if File.dir?(migrations_dir) do
      migrations_dir
      |> File.ls!()
      |> Enum.filter(fn filename ->
        (String.contains?(filename, "phoenix_kit") ||
           String.contains?(filename, "add_phoenix_kit") ||
           String.contains?(filename, "upgrade_phoenix_kit")) &&
          String.ends_with?(filename, ".exs")
      end)
      |> Enum.map(&Path.join([migrations_dir, &1]))
    else
      []
    end
  rescue
    _ -> []
  end

  # Generate migration options (same as phoenix_kit.install.ex)
  defp migration_opts("public", false), do: "[]"
  # public schema doesn't need create_schema
  defp migration_opts("public", true), do: "[]"

  defp migration_opts(prefix, create_schema) when is_binary(prefix) do
    opts = [prefix: prefix]
    opts = if create_schema, do: Keyword.put(opts, :create_schema, true), else: opts
    inspect(opts)
  end
end
