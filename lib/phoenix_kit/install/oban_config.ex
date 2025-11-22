defmodule PhoenixKit.Install.ObanConfig do
  @moduledoc """
  Handles Oban configuration for PhoenixKit installation.

  This module provides functionality to:
  - Configure Oban for background job processing
  - Set up required queues (default, emails, file_processing)
  - Add Oban.Plugins.Pruner for job cleanup
  - Add Oban to application supervisor tree
  - Ensure configuration exists during updates
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Libs.Phoenix
  alias Igniter.Project.Application
  alias PhoenixKit.Install.IgniterHelpers

  @doc """
  Adds or verifies Oban configuration.

  This function ensures that Oban is properly configured for PhoenixKit's
  background job processing, including:
  1. Repo configuration (auto-detected from PhoenixKit config)
  2. Required queues for file processing and email handling
  3. Pruner plugin for automatic job cleanup

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with Oban configuration and notices.
  """
  def add_oban_configuration(igniter) do
    igniter
    |> add_oban_config()
    |> add_oban_configuration_notice()
  end

  @doc """
  Checks if Oban configuration exists in config.exs.

  ## Parameters
  - `igniter` - The igniter context for detecting parent app name

  ## Returns
  Boolean indicating if configuration exists.
  """
  def oban_config_exists?(igniter) do
    config_path = "config/config.exs"
    app_name = IgniterHelpers.get_parent_app_name(igniter)

    if File.exists?(config_path) do
      content = File.read!(config_path)
      lines = String.split(content, "\n")

      # Check for active (non-commented) Oban configuration with parent app namespace
      has_oban_config =
        Enum.any?(lines, fn line ->
          trimmed = String.trim(line)
          # Not a comment and contains config :app_name, Oban
          !String.starts_with?(trimmed, "#") and
            String.contains?(line, "config :#{app_name}, Oban")
        end)

      has_queues =
        Enum.any?(lines, fn line ->
          trimmed = String.trim(line)
          # Not a comment and contains queues:
          !String.starts_with?(trimmed, "#") and String.contains?(line, "queues:")
        end)

      has_oban_config and has_queues
    else
      false
    end
  rescue
    _ -> false
  end

  # Add Oban configuration to config.exs
  defp add_oban_config(igniter) do
    # Get parent app name and repo
    app_name = IgniterHelpers.get_parent_app_name(igniter)
    repo_module = get_repo_module(igniter)

    oban_config = """

    # Configure Oban for PhoenixKit background jobs
    # Required for file processing (storage system) and email handling
    config :#{app_name}, Oban,
      repo: #{repo_module},
      queues: [
        default: 10,           # General purpose queue
        emails: 50,            # Email processing
        file_processing: 20    # File variant generation (storage system)
      ],
      plugins: [
        Oban.Plugins.Pruner    # Automatic cleanup of completed jobs
      ]
    """

    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        # Check if Oban config already exists (with more robust detection)
        if oban_config_already_exists?(content, app_name) do
          source
        else
          # Find insertion point before import_config statements
          insertion_point = find_import_config_location(content)

          updated_content =
            case insertion_point do
              {:before_import, before_content, after_content} ->
                # Insert before import_config
                before_content <> oban_config <> "\n" <> after_content

              :append_to_end ->
                # No import_config found, append to end
                content <> oban_config
            end

          Rewrite.Source.update(source, :content, updated_content)
        end
      end)
    rescue
      e ->
        IO.warn("Failed to add Oban configuration: #{inspect(e)}")
        add_manual_config_notice(igniter, repo_module)
    end
  end

  # Get repo module from PhoenixKit config or detect from app
  defp get_repo_module(igniter) do
    config_path = "config/config.exs"
    app_name = IgniterHelpers.get_parent_app_name(igniter)

    if File.exists?(config_path) do
      content = File.read!(config_path)

      # First try: Look for existing PhoenixKit repo config
      case Regex.run(~r/config :phoenix_kit,\s+repo:\s+([A-Za-z0-9_.]+)/, content) do
        [_, repo] ->
          repo

        _ ->
          # Second try: Look for ecto_repos in app config
          app_module = Macro.camelize(to_string(app_name))

          case Regex.run(~r/config :#{app_name}.*?ecto_repos:\s*\[([A-Za-z0-9_.]+)\]/s, content) do
            [_, repo] -> repo
            _ -> "#{app_module}.Repo"
          end
      end
    else
      app_module = Macro.camelize(to_string(app_name))
      "#{app_module}.Repo"
    end
  rescue
    _ ->
      app_name = IgniterHelpers.get_parent_app_name(igniter)
      app_module = Macro.camelize(to_string(app_name))
      "#{app_module}.Repo"
  end

  # Check if Oban config already exists in the file
  defp oban_config_already_exists?(content, app_name) do
    lines = String.split(content, "\n")

    Enum.any?(lines, fn line ->
      trimmed = String.trim(line)

      # Not a comment and contains config for Oban
      # Also check for variations with spaces
      !String.starts_with?(trimmed, "#") and
        (String.contains?(line, "config :#{app_name}, Oban") or
           Regex.match?(~r/config\s+:#{app_name},\s+Oban/, line))
    end)
  end

  # Find the location to insert config before import_config statements
  defp find_import_config_location(content) do
    lines = String.split(content, "\n")

    # Look for import_config pattern
    import_index =
      Enum.find_index(lines, fn line ->
        trimmed = String.trim(line)
        String.starts_with?(trimmed, "import_config") or String.contains?(line, "import_config")
      end)

    case import_index do
      nil ->
        # No import_config found, append to end
        :append_to_end

      index ->
        # Find the start of the import_config block
        start_index = find_import_block_start(lines, index)

        # Split content at the start of import block
        before_lines = Enum.take(lines, start_index)
        after_lines = Enum.drop(lines, start_index)

        before_content = Enum.join(before_lines, "\n")
        after_content = Enum.join(after_lines, "\n")

        {:before_import, before_content, after_content}
    end
  end

  # Find the start of the import_config block (including preceding comments)
  defp find_import_block_start(lines, import_index) do
    lines
    |> Enum.take(import_index)
    |> Enum.reverse()
    |> Enum.reduce_while(import_index, fn line, current_index ->
      trimmed = String.trim(line)

      cond do
        # Comment line related to import
        String.starts_with?(trimmed, "#") and
            (String.contains?(line, "import") or String.contains?(line, "Import") or
               String.contains?(line, "bottom") or String.contains?(line, "BOTTOM") or
               String.contains?(line, "environment")) ->
          {:cont, current_index - 1}

        # Blank line
        trimmed == "" ->
          {:cont, current_index - 1}

        # config_env or similar
        String.contains?(line, "config_env()") or String.contains?(line, "env_config") ->
          {:cont, current_index - 1}

        # Stop at any other code
        true ->
          {:halt, current_index}
      end
    end)
  end

  # Add notice about Oban configuration
  defp add_oban_configuration_notice(igniter) do
    if oban_config_exists?(igniter) do
      Igniter.add_notice(
        igniter,
        "⚙️  Oban configured for background jobs (file processing, emails)"
      )
    else
      Igniter.add_notice(
        igniter,
        "⚠️  Oban configuration added - restart your server if running"
      )
    end
  end

  @doc """
  Adds Oban to the parent application's supervision tree.

  This function ensures that Oban starts automatically when the application starts,
  with correct positioning in the supervisor tree:
  - AFTER PhoenixKit.Supervisor (PhoenixKit services available)
  - BEFORE Endpoint (Oban ready before HTTP requests)

  ## Important

  Oban MUST start AFTER PhoenixKit.Supervisor because PhoenixKit.Supervisor
  depends on Repo, and Oban also depends on Repo. The correct order is:
  1. Repo (database connection)
  2. PhoenixKit.Supervisor (uses Repo for Settings)
  3. Oban (uses Repo for job persistence)

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with Oban added to application supervisor.
  """
  def add_oban_supervisor(igniter) do
    app_name = IgniterHelpers.get_parent_app_name(igniter)
    {igniter, endpoint} = Phoenix.select_endpoint(igniter)

    # Use Igniter API to add Oban with explicit positioning
    # This ensures correct order: Repo → PhoenixKit → Oban → Endpoint
    igniter
    |> Application.add_new_child(
      {Oban, {:application, app_name, Oban}},
      after: [PhoenixKit.Supervisor],
      before: [endpoint]
    )
  end

  @doc """
  Checks if Oban supervisor is configured in application.ex.

  ## Parameters
  - `igniter` - The igniter context for detecting parent app name

  ## Returns
  Boolean indicating if Oban supervisor exists in application.ex.
  """
  def oban_supervisor_exists?(igniter) do
    app_name = IgniterHelpers.get_parent_app_name(igniter)
    app_file = "lib/#{app_name}/application.ex"

    if File.exists?(app_file) do
      content = File.read!(app_file)

      # Check for Oban in children list
      String.contains?(content, "{Oban,") or
        String.contains?(content, "Application.get_env(:#{app_name}, Oban)")
    else
      false
    end
  rescue
    _ -> false
  end

  # Add notice when manual configuration is required
  defp add_manual_config_notice(igniter, repo_module) do
    app_name = IgniterHelpers.get_parent_app_name(igniter)

    notice = """
    ⚠️  Manual Configuration Required: Oban

    PhoenixKit couldn't automatically configure Oban for background jobs.

    Please add the following to config/config.exs:

      config :#{app_name}, Oban,
        repo: #{repo_module},
        queues: [
          default: 10,
          emails: 50,
          file_processing: 20
        ],
        plugins: [
          Oban.Plugins.Pruner
        ]

    And add the following to lib/#{app_name}/application.ex in the children list:

      {Oban, Application.get_env(:#{app_name}, Oban)}

    Without this configuration, the storage system cannot process uploaded files.
    Files will remain stuck in "processing" status.
    """

    Igniter.add_notice(igniter, notice)
  end
end
