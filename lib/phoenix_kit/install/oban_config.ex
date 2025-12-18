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

  # Mix functions only available at compile-time during installation
  @dialyzer {:nowarn_function, update_existing_oban_config: 3}
  @dialyzer {:nowarn_function, ensure_posts_queue: 2}
  @dialyzer {:nowarn_function, ensure_sitemap_queue: 2}
  @dialyzer {:nowarn_function, ensure_sqs_polling_queue: 2}
  @dialyzer {:nowarn_function, ensure_db_transfer_queue: 2}
  @dialyzer {:nowarn_function, ensure_cron_plugin: 2}
  @dialyzer {:nowarn_function, add_cron_plugin_to_plugins: 2}

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
    # Required for file processing (storage system), email handling, posts, sitemap, and DB transfer
    config :#{app_name}, Oban,
      repo: #{repo_module},
      queues: [
        default: 10,           # General purpose queue
        emails: 50,            # Email processing
        file_processing: 20,   # File variant generation (storage system)
        posts: 10,             # Posts scheduled publishing
        sitemap: 5,            # Sitemap generation
        sqs_polling: 1,        # SQS polling for email events (only one concurrent job)
        db_transfer: 5         # DB Transfer data import
      ],
      plugins: [
        Oban.Plugins.Pruner,   # Automatic cleanup of completed jobs
        {Oban.Plugins.Cron,
         crontab: [
           {"* * * * *", PhoenixKit.Posts.Workers.PublishScheduledPostsJob}
         ]}
      ]
    """

    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        # Check if Oban config already exists (with more robust detection)
        if oban_config_already_exists?(content, app_name) do
          # Update existing config to add posts queue and cron plugin
          update_existing_oban_config(source, content, app_name)
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

  # Update existing Oban configuration to add posts/sitemap/sqs_polling/db_transfer queues and cron plugin
  defp update_existing_oban_config(source, content, app_name) do
    Mix.shell().info("🔍 Updating existing Oban configuration for :#{app_name}...")

    updated_content =
      content
      |> ensure_posts_queue(app_name)
      |> ensure_sitemap_queue(app_name)
      |> ensure_sqs_polling_queue(app_name)
      |> ensure_db_transfer_queue(app_name)
      |> ensure_cron_plugin(app_name)

    if updated_content == content do
      Mix.shell().info(
        "✅ Oban configuration already up-to-date (posts/sitemap/sqs_polling/db_transfer queues and cron plugin present)"
      )
    else
      Mix.shell().info(
        "✅ Updated Oban configuration with posts, sitemap, sqs_polling, and db_transfer support"
      )
    end

    Rewrite.Source.update(source, :content, updated_content)
  end

  # Ensure posts queue exists in the queues list
  defp ensure_posts_queue(content, app_name) do
    # Check if posts queue already exists
    if Regex.match?(~r/posts:\s*\d+/, content) do
      Mix.shell().info("  ℹ️  Posts queue already configured")
      content
    else
      Mix.shell().info("  ➕ Adding posts queue to Oban configuration...")

      # Find the ACTIVE queues configuration (not commented out)
      # Pattern: line starts with 'config' (not #), then matches queues block
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban.*?queues:\s*\[)(.*?)(\n\s*\])/ms,
             content,
             capture: :all
           ) do
        [full_match, before_queues, queues_content, after_queues] ->
          Mix.shell().info("  ✓ Found queues block, adding posts queue")

          # Remove trailing whitespace and check for comma
          trimmed_content = String.trim_trailing(queues_content)
          has_trailing_comma = String.ends_with?(trimmed_content, ",")

          # Add posts queue with proper formatting
          new_queue_entry =
            if has_trailing_comma do
              "\n    posts: 10              # Posts scheduled publishing"
            else
              ",\n    posts: 10              # Posts scheduled publishing"
            end

          updated_queues = before_queues <> queues_content <> new_queue_entry <> after_queues

          String.replace(content, full_match, updated_queues, global: false)

        nil ->
          Mix.shell().error(
            "  ⚠️  Could not parse queues block for :#{app_name} - skipping posts queue update"
          )

          Mix.shell().error("     Please manually add: posts: 10")
          content
      end
    end
  end

  # Ensure sitemap queue exists in the queues list
  defp ensure_sitemap_queue(content, app_name) do
    # Check if sitemap queue already exists
    if Regex.match?(~r/sitemap:\s*\d+/, content) do
      Mix.shell().info("  ℹ️  Sitemap queue already configured")
      content
    else
      Mix.shell().info("  ➕ Adding sitemap queue to Oban configuration...")

      # Find the ACTIVE queues configuration (not commented out)
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban.*?queues:\s*\[)(.*?)(\n\s*\])/ms,
             content,
             capture: :all
           ) do
        [full_match, before_queues, queues_content, after_queues] ->
          Mix.shell().info("  ✓ Found queues block, adding sitemap queue")

          # Remove trailing whitespace and check for comma
          trimmed_content = String.trim_trailing(queues_content)
          has_trailing_comma = String.ends_with?(trimmed_content, ",")

          # Add sitemap queue with proper formatting
          new_queue_entry =
            if has_trailing_comma do
              "\n    sitemap: 5              # Sitemap generation"
            else
              ",\n    sitemap: 5              # Sitemap generation"
            end

          updated_queues = before_queues <> queues_content <> new_queue_entry <> after_queues

          String.replace(content, full_match, updated_queues, global: false)

        nil ->
          Mix.shell().error(
            "  ⚠️  Could not parse queues block for :#{app_name} - skipping sitemap queue update"
          )

          Mix.shell().error("     Please manually add: sitemap: 5")
          content
      end
    end
  end

  # Ensure sqs_polling queue exists in the queues list
  defp ensure_sqs_polling_queue(content, app_name) do
    # Check if sqs_polling queue already exists
    if Regex.match?(~r/sqs_polling:\s*\d+/, content) do
      Mix.shell().info("  ℹ️  SQS polling queue already configured")
      content
    else
      Mix.shell().info("  ➕ Adding sqs_polling queue to Oban configuration...")

      # Find the ACTIVE queues configuration (not commented out)
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban.*?queues:\s*\[)(.*?)(\n\s*\])/ms,
             content,
             capture: :all
           ) do
        [full_match, before_queues, queues_content, after_queues] ->
          Mix.shell().info("  ✓ Found queues block, adding sqs_polling queue")

          # Remove trailing whitespace and check for comma
          trimmed_content = String.trim_trailing(queues_content)
          has_trailing_comma = String.ends_with?(trimmed_content, ",")

          # Add sqs_polling queue with proper formatting
          new_queue_entry =
            if has_trailing_comma do
              "\n    sqs_polling: 1         # SQS polling for email events"
            else
              ",\n    sqs_polling: 1         # SQS polling for email events"
            end

          updated_queues = before_queues <> queues_content <> new_queue_entry <> after_queues

          String.replace(content, full_match, updated_queues, global: false)

        nil ->
          Mix.shell().error(
            "  ⚠️  Could not parse queues block for :#{app_name} - skipping sqs_polling queue update"
          )

          Mix.shell().error("     Please manually add: sqs_polling: 1")
          content
      end
    end
  end

  # Ensure db_transfer queue exists in the queues list
  defp ensure_db_transfer_queue(content, app_name) do
    # Check if db_transfer queue already exists
    if Regex.match?(~r/db_transfer:\s*\d+/, content) do
      Mix.shell().info("  ℹ️  db_transfer queue already configured")
      content
    else
      Mix.shell().info("  ➕ Adding db_transfer queue to Oban configuration...")

      # Find the queues configuration for this app's Oban config
      case Regex.run(
             ~r/(config\s+:#{app_name},\s+Oban.*?queues:\s*\[)(.*?)(\n\s*\])/s,
             content,
             capture: :all
           ) do
        [full_match, before_queues, queues_content, after_queues] ->
          Mix.shell().info("  ✓ Found queues block, adding db_transfer queue")

          # Remove trailing whitespace and check for comma
          trimmed_content = String.trim_trailing(queues_content)
          has_trailing_comma = String.ends_with?(trimmed_content, ",")

          # Add db_transfer queue with proper formatting
          new_queue_entry =
            if has_trailing_comma do
              "\n    db_transfer: 5         # DB Transfer data import"
            else
              ",\n    db_transfer: 5         # DB Transfer data import"
            end

          updated_queues = before_queues <> queues_content <> new_queue_entry <> after_queues

          String.replace(content, full_match, updated_queues, global: false)

        nil ->
          Mix.shell().error(
            "  ⚠️  Could not parse queues block for :#{app_name} - skipping db_transfer queue update"
          )

          Mix.shell().error("     Please manually add: db_transfer: 5")
          content
      end
    end
  end

  # Ensure cron plugin exists in the plugins list
  defp ensure_cron_plugin(content, app_name) do
    # Check if Oban.Plugins.Cron already exists
    if String.contains?(content, "Oban.Plugins.Cron") do
      # Cron plugin exists, check if PublishScheduledPostsJob is configured
      if String.contains?(content, "PublishScheduledPostsJob") do
        Mix.shell().info("  ℹ️  Cron plugin and PublishScheduledPostsJob already configured")
        content
      else
        Mix.shell().info("  ➕ Adding PublishScheduledPostsJob to existing cron configuration...")
        # Add PublishScheduledPostsJob to existing crontab
        add_scheduled_posts_job_to_crontab(content)
      end
    else
      Mix.shell().info("  ➕ Adding Oban.Plugins.Cron with PublishScheduledPostsJob...")
      # Add entire Cron plugin configuration
      add_cron_plugin_to_plugins(content, app_name)
    end
  end

  # Add PublishScheduledPostsJob to existing crontab
  defp add_scheduled_posts_job_to_crontab(content) do
    # Pattern: crontab: [...] within Cron plugin
    case Regex.run(~r/(crontab:\s*\[)(.*?)(\])/s, content, capture: :all) do
      [full_match, before_crontab, crontab_content, after_crontab] ->
        # Check if crontab is empty or has entries
        has_entries = String.trim(crontab_content) != ""

        new_job_entry =
          if has_entries do
            ",\n           {\"* * * * *\", PhoenixKit.Posts.Workers.PublishScheduledPostsJob}"
          else
            "\n           {\"* * * * *\", PhoenixKit.Posts.Workers.PublishScheduledPostsJob}\n         "
          end

        updated_crontab = before_crontab <> crontab_content <> new_job_entry <> after_crontab

        String.replace(content, full_match, updated_crontab, global: false)

      _ ->
        content
    end
  end

  # Add Cron plugin to plugins list
  defp add_cron_plugin_to_plugins(content, app_name) do
    # Find the ACTIVE plugins block - must not be commented out
    # Pattern: line starts with spaces (not #), then plugins: [
    case Regex.run(
           ~r/(^[ \t]+plugins:\s*\[\n)(.*?)(\n[ \t]+\])/ms,
           content,
           capture: :all
         ) do
      [full_match, plugins_open, plugins_content, plugins_close] ->
        Mix.shell().info("  ✓ Found plugins block, adding Cron plugin")

        # Check if content ends with comma
        trimmed_content = String.trim(plugins_content)
        has_trailing_comma = String.ends_with?(trimmed_content, ",")

        # Add cron plugin with proper formatting (matching existing indentation)
        cron_plugin =
          if has_trailing_comma do
            "\n    {Oban.Plugins.Cron,\n     crontab: [\n       {\"* * * * *\", PhoenixKit.Posts.Workers.PublishScheduledPostsJob}\n     ]}"
          else
            ",\n    {Oban.Plugins.Cron,\n     crontab: [\n       {\"* * * * *\", PhoenixKit.Posts.Workers.PublishScheduledPostsJob}\n     ]}"
          end

        updated_plugins = plugins_open <> plugins_content <> cron_plugin <> plugins_close

        String.replace(content, full_match, updated_plugins, global: false)

      nil ->
        Mix.shell().error(
          "  ⚠️  Could not parse plugins block for :#{app_name} - skipping cron plugin update"
        )

        Mix.shell().error("     Please manually add Oban.Plugins.Cron configuration")
        content
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
        """
        ⚙️  Oban configured for background jobs (file processing, emails, sitemap, sqs_polling)
           If queues were added/updated, restart your server to apply changes.
        """
        |> String.trim()
      )
    else
      Igniter.add_notice(
        igniter,
        """
        ⚠️  Oban configuration added to config.exs
           IMPORTANT: Restart your server to apply configuration changes.
        """
        |> String.trim()
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

    # Build AST for: Application.get_env(:app_name, Oban)
    # Using Sourceror to parse the code string into AST
    get_env_code = "Application.get_env(:#{app_name}, Oban)"
    get_env_ast = Sourceror.parse_string!(get_env_code)

    # Use Igniter API to add Oban with explicit positioning
    # Pass {Module, {:code, ast}} format so Igniter doesn't escape the AST
    # This ensures correct order: Repo → PhoenixKit → Oban → Endpoint
    igniter
    |> Application.add_new_child(
      {Oban, {:code, get_env_ast}},
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
          file_processing: 20,
          posts: 10,
          sitemap: 5,
          sqs_polling: 1,
          db_transfer: 5
        ],
        plugins: [
          Oban.Plugins.Pruner,
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.Posts.Workers.PublishScheduledPostsJob}
           ]}
        ]

    And add the following to lib/#{app_name}/application.ex in the children list:

      {Oban, Application.get_env(:#{app_name}, Oban)}

    IMPORTANT: Restart your server after making these changes.

    Without this configuration, the storage system cannot process uploaded files,
    scheduled posts will not be published automatically, sitemap generation
    will not work asynchronously, SQS polling for email events will not function,
    and DB Transfer imports will not work.
    """

    Igniter.add_notice(igniter, notice)
  end
end
