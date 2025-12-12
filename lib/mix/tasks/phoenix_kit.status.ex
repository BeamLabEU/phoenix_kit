defmodule Mix.Tasks.PhoenixKit.Status do
  @moduledoc """
  Shows comprehensive status of PhoenixKit installation.

  This task provides a detailed overview of your PhoenixKit installation status,
  including version information, database connectivity, assets status, and
  suggested next actions.

  ## Usage

      $ mix phoenix_kit.status
      $ mix phoenix_kit.status --prefix=myapp

  ## Options

    * `--prefix` - Database schema prefix (default: "public")
    * `--verbose` - Show detailed diagnostic information

  ## Examples

      # Show status for default installation
      mix phoenix_kit.status

      # Show status for custom schema prefix
      mix phoenix_kit.status --prefix=auth

      # Show detailed diagnostic information
      mix phoenix_kit.status --verbose

  ## Sample Output

      PhoenixKit v1.2.1
      ├── Installed: V03 ✅
      ├── Database: Connected ✅
      ├── Assets: Built ✅
      └── Status: Ready

  """

  use Mix.Task
  alias Ecto.Adapters.SQL

  alias PhoenixKit.Config
  alias PhoenixKit.Install.Common
  alias PhoenixKit.Migrations.Postgres

  @impl Mix.Task
  @spec run([String.t()]) :: :ok

  @shortdoc "Shows comprehensive PhoenixKit installation status"

  @switches [
    prefix: :string,
    verbose: :boolean
  ]

  @aliases [
    p: :prefix,
    v: :verbose
  ]

  def run(argv) do
    # Start the application to ensure repo is available
    Mix.Task.run("app.start")

    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    prefix = opts[:prefix] || "public"
    verbose = opts[:verbose] || false

    show_comprehensive_status(prefix, verbose)
  end

  # Main status display function
  defp show_comprehensive_status(prefix, verbose) do
    # Get all status information
    phoenix_kit_version = get_phoenix_kit_version()
    installation_status = get_installation_status(prefix)
    database_status = get_database_status(prefix)
    next_action = determine_next_action(installation_status, prefix)

    # Display header
    IO.puts("\n#{IO.ANSI.bright()}PhoenixKit v#{phoenix_kit_version}#{IO.ANSI.reset()}")

    # Display status tree
    display_status_tree([
      {"Installed", format_installation_status(installation_status)},
      {"Database", format_database_status(database_status)},
      {"Next", format_next_action(next_action)}
    ])

    # Show verbose information if requested
    if verbose do
      show_verbose_diagnostics(prefix, installation_status, database_status)
    end

    IO.puts("")
  end

  # Get PhoenixKit module version
  defp get_phoenix_kit_version do
    case :application.get_key(:phoenix_kit, :vsn) do
      {:ok, vsn} when is_list(vsn) -> List.to_string(vsn)
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "unknown"
    end
  end

  # Get installation status
  defp get_installation_status(prefix) do
    case Common.check_installation_status(prefix) do
      {:not_installed} ->
        {:not_installed}

      {:current_version, version} ->
        target_version = Postgres.current_version()

        if version >= target_version do
          {:up_to_date, version}
        else
          {:needs_update, version, target_version}
        end
    end
  end

  # Get database connectivity status with hybrid repo detection
  defp get_database_status(prefix) do
    case get_repo_with_fallback() do
      nil ->
        {:no_repo_configured}

      repo ->
        test_repo_and_tables(repo, prefix)
    end
  rescue
    error -> {:error, error}
  end

  # Test repository connection and check for PhoenixKit tables
  defp test_repo_and_tables(repo, prefix) do
    case ensure_repo_started(repo) do
      :ok ->
        test_database_connection(repo, prefix)

      {:error, reason} ->
        {:connection_error, reason}
    end
  end

  # Test database connection and check tables
  defp test_database_connection(repo, prefix) do
    case SQL.query(repo, "SELECT 1", []) do
      {:ok, _result} ->
        check_phoenix_kit_tables(prefix)

      {:error, reason} ->
        {:connection_error, reason}
    end
  end

  # Helper function to check if PhoenixKit tables exist
  defp check_phoenix_kit_tables(prefix) do
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}
    version = Postgres.migrated_version_runtime(opts)

    if version > 0 do
      {:connected_with_tables, version}
    else
      {:connected_no_tables}
    end
  end

  # Determine next recommended action
  defp determine_next_action({:not_installed}, _prefix) do
    {:install, "mix phoenix_kit.install"}
  end

  defp determine_next_action({:needs_update, _current, _target}, prefix) do
    cmd =
      if prefix != "public",
        do: "mix phoenix_kit.update --prefix=#{prefix}",
        else: "mix phoenix_kit.update"

    {:update, cmd}
  end

  defp determine_next_action({:up_to_date, _version}, _prefix) do
    {:ready, "Ready"}
  end

  # Format installation status for display
  defp format_installation_status({:not_installed}) do
    "#{IO.ANSI.red()}Not installed#{IO.ANSI.reset()}"
  end

  defp format_installation_status({:up_to_date, version}) do
    "#{IO.ANSI.green()}V#{pad_version(version)} ✅#{IO.ANSI.reset()}"
  end

  defp format_installation_status({:needs_update, current, target}) do
    "#{IO.ANSI.yellow()}V#{pad_version(current)} (needs update to V#{pad_version(target)})#{IO.ANSI.reset()}"
  end

  # Format database status for display
  defp format_database_status({:connected_with_tables, _version}) do
    "#{IO.ANSI.green()}Connected ✅#{IO.ANSI.reset()}"
  end

  defp format_database_status({:connected_no_tables}) do
    "#{IO.ANSI.yellow()}Connected (no tables)#{IO.ANSI.reset()}"
  end

  defp format_database_status({:connection_error, _reason}) do
    "#{IO.ANSI.red()}Connection failed ❌#{IO.ANSI.reset()}"
  end

  defp format_database_status({:no_repo_configured}) do
    "#{IO.ANSI.red()}No repo configured ❌#{IO.ANSI.reset()}"
  end

  defp format_database_status({:error, _error}) do
    "#{IO.ANSI.red()}Error ❌#{IO.ANSI.reset()}"
  end

  # Format next action for display
  defp format_next_action({:install, command}) do
    "#{IO.ANSI.cyan()}#{command}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:update, command}) do
    "#{IO.ANSI.cyan()}#{command}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:ready, message}) do
    "#{IO.ANSI.green()}#{message}#{IO.ANSI.reset()}"
  end

  # Display status information in tree format
  defp display_status_tree(items) do
    items
    |> Enum.with_index()
    |> Enum.each(fn {{label, value}, index} ->
      is_last = index == length(items) - 1
      prefix = if is_last, do: "└── ", else: "├── "

      IO.puts("#{prefix}#{IO.ANSI.bright()}#{label}#{IO.ANSI.reset()}: #{value}")
    end)
  end

  # Show detailed diagnostic information
  defp show_verbose_diagnostics(prefix, installation_status, database_status) do
    IO.puts("\n#{IO.ANSI.bright()}═══ Detailed Diagnostics ═══#{IO.ANSI.reset()}")

    show_installation_diagnostics(installation_status, prefix)
    show_database_diagnostics(database_status, prefix)
    show_configuration_diagnostics()
  end

  # Show installation diagnostics
  defp show_installation_diagnostics(status, prefix) do
    IO.puts("\n#{IO.ANSI.bright()}Installation:#{IO.ANSI.reset()}")
    IO.puts("  Schema prefix: #{prefix}")

    case status do
      {:not_installed} ->
        IO.puts("  Migration files: #{inspect(Common.find_existing_phoenix_kit_migrations())}")

      {:up_to_date, version} ->
        IO.puts("  Current version: V#{pad_version(version)}")
        IO.puts("  Target version: V#{pad_version(Postgres.current_version())}")

      {:needs_update, current, target} ->
        IO.puts("  Current version: V#{pad_version(current)}")
        IO.puts("  Target version: V#{pad_version(target)}")
        changes = Common.describe_version_changes(current, target)
        IO.puts("  Available changes:")
        String.split(changes, "\n") |> Enum.each(&IO.puts("    #{&1}"))
    end
  end

  # Show database diagnostics
  defp show_database_diagnostics(status, _prefix) do
    IO.puts("\n#{IO.ANSI.bright()}Database:#{IO.ANSI.reset()}")

    # Show how repo was detected
    show_repo_detection_info()

    case status do
      {:connected_with_tables, version} ->
        IO.puts("  Connection: OK")
        IO.puts("  PhoenixKit tables: Present (V#{pad_version(version)})")

      {:connected_no_tables} ->
        IO.puts("  Connection: OK")
        IO.puts("  PhoenixKit tables: Missing")

      {:connection_error, reason} ->
        IO.puts("  Connection: Failed")
        IO.puts("  Error: #{inspect(reason)}")

      {:no_repo_configured} ->
        IO.puts("  Connection: No repo configured")
        show_repo_fallback_attempts()

      {:error, error} ->
        IO.puts("  Connection: Error")
        IO.puts("  Details: #{inspect(error)}")
    end
  end

  # Show detailed repo detection information
  defp show_repo_detection_info do
    phoenix_kit_repo = Config.get(:repo, nil)

    IO.puts("  PhoenixKit repo config: #{inspect(phoenix_kit_repo)}")

    if phoenix_kit_repo do
      show_configured_repo_info(phoenix_kit_repo)
    else
      show_fallback_repo_info()
    end
  end

  # Show information about configured repo
  defp show_configured_repo_info(repo) do
    IO.puts("  Detection method: PhoenixKit application config")
    IO.puts("  Testing repo connection...")

    test_and_report_repo_connection(repo)
  end

  # Show information about fallback repo detection
  defp show_fallback_repo_info do
    started_repo = ensure_phoenix_kit_started()
    IO.puts("  After starting PhoenixKit app: #{inspect(started_repo)}")

    detected_repo = detect_repo_from_project()

    if detected_repo do
      show_detected_repo_info(detected_repo)
    else
      IO.puts("  No repo detected via fallback methods")
    end
  end

  # Show information about detected repo
  defp show_detected_repo_info(repo) do
    parent_app_name = Mix.Project.config()[:app]

    IO.puts("  Fallback repo detected: #{inspect(repo)}")

    # Show which method worked
    if try_ecto_repos_config(parent_app_name) do
      IO.puts("  Detection method: :ecto_repos config")
    else
      IO.puts("  Detection method: Naming pattern")
    end

    IO.puts("  Testing repo connection...")
    test_and_report_repo_connection(repo)
  end

  # Test repo connection and report results
  defp test_and_report_repo_connection(repo) do
    case test_repo_connection(repo) do
      :ok -> IO.puts("  Repo connection test: PASSED")
      {:error, reason} -> IO.puts("  Repo connection test: FAILED - #{inspect(reason)}")
    end
  end

  # Test repo connection
  defp test_repo_connection(repo) do
    # Ensure repo is started first
    case ensure_repo_started(repo) do
      :ok ->
        case SQL.query(repo, "SELECT 1", []) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  # Show fallback attempts when repo is not configured
  defp show_repo_fallback_attempts do
    parent_app_name = Mix.Project.config()[:app]

    IO.puts("  Fallback attempts:")
    IO.puts("    - PhoenixKit config: #{inspect(Config.get(:repo, nil))}")

    IO.puts(
      "    - App :ecto_repos: #{inspect(Application.get_env(parent_app_name, :ecto_repos, []))}"
    )

    if parent_app_name do
      expected_repo = Module.concat([Macro.camelize(to_string(parent_app_name)), "Repo"])
      IO.puts("    - Naming pattern (#{expected_repo}): #{ensure_repo_loaded?(expected_repo)}")
    end
  end

  # Show configuration diagnostics
  defp show_configuration_diagnostics do
    IO.puts("\n#{IO.ANSI.bright()}Configuration:#{IO.ANSI.reset()}")

    # Check layout configuration
    layout_config = PhoenixKit.Config.get(:layout)

    IO.puts(
      "  Layout integration: #{if layout_config != :not_found, do: "Configured", else: "Using defaults"}"
    )

    # Check mailer configuration
    mailer_config = PhoenixKit.Config.get(PhoenixKit.Mailer)

    IO.puts(
      "  Mailer: #{if mailer_config != :not_found, do: "Configured", else: "Not configured"}"
    )
  end

  # Hybrid repo detection with fallback strategies
  defp get_repo_with_fallback do
    # Strategy 1: Try to get from PhoenixKit application config
    case Config.get(:repo, nil) do
      nil ->
        # Strategy 2: Try to ensure PhoenixKit application is started
        case ensure_phoenix_kit_started() do
          repo when not is_nil(repo) ->
            repo

          nil ->
            # Strategy 3: Auto-detect from project configuration
            detect_repo_from_project()
        end

      repo ->
        repo
    end
  end

  # Try to start PhoenixKit application and get repo config
  defp ensure_phoenix_kit_started do
    Application.ensure_all_started(:phoenix_kit)
    Config.get(:repo, nil)
  rescue
    _ -> nil
  end

  # Auto-detect repository from project configuration (similar to RepoDetection)
  defp detect_repo_from_project do
    parent_app_name = Mix.Project.config()[:app]

    # Try :ecto_repos config first
    case try_ecto_repos_config(parent_app_name) do
      nil -> try_naming_patterns(parent_app_name)
      repo -> repo
    end
  end

  # Try to get repo from :ecto_repos application config
  defp try_ecto_repos_config(nil), do: nil

  defp try_ecto_repos_config(app_name) do
    case Application.get_env(app_name, :ecto_repos, []) do
      [repo | _] when is_atom(repo) ->
        if ensure_repo_loaded?(repo), do: repo, else: nil

      [] ->
        nil
    end
  rescue
    _ -> nil
  end

  # Try common naming patterns
  defp try_naming_patterns(nil), do: nil

  defp try_naming_patterns(app_name) do
    # Try most common pattern: AppName.Repo
    repo_module = Module.concat([Macro.camelize(to_string(app_name)), "Repo"])

    if ensure_repo_loaded?(repo_module) do
      repo_module
    else
      nil
    end
  end

  # Check if repo module exists and is loaded
  defp ensure_repo_loaded?(repo) when is_atom(repo) and not is_nil(repo) do
    Code.ensure_loaded?(repo) && function_exported?(repo, :__adapter__, 0)
  rescue
    _ -> false
  end

  defp ensure_repo_loaded?(_), do: false

  # Ensure repo is properly started for database operations
  # Since app.start is called in run/1, this is now much simpler
  defp ensure_repo_started(repo) do
    if repo_available?(repo) do
      :ok
    else
      {:error, "Repository #{inspect(repo)} is not available"}
    end
  end

  # Check if repo module is available and started
  defp repo_available?(repo) do
    Code.ensure_loaded?(repo) &&
      function_exported?(repo, :__adapter__, 0) &&
      Process.whereis(repo) != nil
  rescue
    _ -> false
  end

  # Pad version number for consistent display
  defp pad_version(version) when version < 10, do: "0#{version}"
  defp pad_version(version), do: to_string(version)
end
