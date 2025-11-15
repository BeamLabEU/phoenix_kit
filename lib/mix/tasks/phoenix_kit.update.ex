# dialyzer: no_missing_calls
if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.PhoenixKit.Update do
    @moduledoc """
    Igniter-based updater for PhoenixKit.

    This task handles updating an existing PhoenixKit installation to the latest version
    by creating upgrade migrations that preserve existing data while adding new features.

    ## Two-Pass Update Strategy

    To prevent configuration timing issues, the update process uses a two-pass strategy:

    1. **First Pass** (if configuration is missing): Adds required configuration (e.g.,
       Ueberauth settings) via Igniter and prompts you to run the command again.

    2. **Second Pass** (configuration present): Safely starts the application and
       completes the update process.

    This ensures that the application always starts with all required configuration
    present, avoiding runtime errors from missing dependencies.

    ## Automatic Updates

    The update process also automatically:
    - Updates CSS configuration (enables daisyUI themes if disabled)
    - Rebuilds assets using the Phoenix asset pipeline
    - Applies database migrations (with optional interactive prompt)

    ## Usage

        $ mix phoenix_kit.update
        $ mix phoenix_kit.update --prefix=myapp
        $ mix phoenix_kit.update --status
        $ mix phoenix_kit.update --skip-assets
        $ mix phoenix_kit.update -y

    ## Options

      * `--prefix` - Database schema prefix (default: "public")
      * `--status` - Show current installation status and available updates
      * `--force` - Force update even if already up to date
      * `--skip-assets` - Skip automatic asset rebuild check
      * `--yes` / `-y` - Skip confirmation prompts and run migrations automatically

    ## Examples

        # Update PhoenixKit to latest version
        mix phoenix_kit.update

        # Check what version is installed and what updates are available
        mix phoenix_kit.update --status

        # Update with custom schema prefix
        mix phoenix_kit.update --prefix=auth

        # Update without prompts (useful for CI/CD)
        mix phoenix_kit.update -y

        # Force update with automatic migration
        mix phoenix_kit.update --force -y

    ## Version Management

    PhoenixKit uses a versioned migration system. Each version contains specific
    database schema changes that can be applied incrementally.

    Current version: V17 (latest version with comprehensive features)
    - V01: Basic authentication with role system
    - V02: Remove is_active column from role assignments (direct deletion)
    - V03-V17: Additional features and improvements (see migration files for details)

    ## Safe Updates

    All PhoenixKit updates are designed to be:
    - Non-destructive (existing data is preserved)
    - Backward compatible (existing code continues to work)
    - Idempotent (safe to run multiple times)
    - Rollback-capable (can be reverted if needed)
    """
    use Igniter.Mix.Task

    alias Igniter.Project.Config

    alias PhoenixKit.Install.{
      ApplicationSupervisor,
      AssetRebuild,
      BasicConfiguration,
      Common,
      CssIntegration,
      RateLimiterConfig
    }

    alias PhoenixKit.Utils.Routes

    @shortdoc "Updates PhoenixKit to the latest version"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :phoenix_kit,
        example: "mix phoenix_kit.update --prefix auth --force",
        positional: [],
        schema: [
          prefix: :string,
          status: :boolean,
          force: :boolean,
          skip_assets: :boolean,
          yes: :boolean
        ],
        aliases: [
          p: :prefix,
          s: :status,
          f: :force,
          y: :yes
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options

      # Handle --status flag
      if opts[:status] do
        show_status(opts)
        igniter
      else
        igniter
        |> BasicConfiguration.add_basic_config()
        |> ApplicationSupervisor.add_supervisor()
        |> perform_igniter_update(opts)
      end
    end

    # Override run/1 to handle post-igniter interactive migration and asset rebuild
    def run(argv) do
      # Handle --help flag
      if "--help" in argv or "-h" in argv do
        show_help()
        :ok
      else
        # Store options in process dictionary for later use
        opts =
          OptionParser.parse(argv,
            switches: [
              prefix: :string,
              status: :boolean,
              force: :boolean,
              skip_assets: :boolean,
              yes: :boolean
            ],
            aliases: [
              p: :prefix,
              s: :status,
              f: :force,
              y: :yes
            ]
          )

        # If --status flag, handle directly and exit
        if Keyword.get(elem(opts, 0), :status) do
          show_status(elem(opts, 0))
          :ok
        else
          # CRITICAL: Check if required configuration exists BEFORE starting app
          # This prevents configuration timing issues where config is added via Igniter
          # but the app has already started with cached (missing) configuration
          config_status = check_required_configuration()

          case config_status do
            :missing ->
              # First pass: Add configuration via Igniter without starting app
              show_missing_config_message(argv)
              result = super(argv)
              show_config_added_message(argv)
              result

            :ok ->
              # Second pass: Configuration exists, safe to start app and update
              Mix.Task.run("app.start")
              result = super(argv)
              post_igniter_tasks(elem(opts, 0))
              result
          end
        end
      end
    end

    # Display message about missing configuration
    defp show_missing_config_message(argv) do
      Mix.shell().info("""

      ⚠️  Required configuration is missing from config/config.exs

      PhoenixKit requires Ueberauth configuration for OAuth authentication.
      This configuration will be added now.

      After this completes, please run the update command again:
        mix phoenix_kit.update #{Enum.join(argv, " ")}
      """)
    end

    # Display message after configuration is added
    defp show_config_added_message(argv) do
      Mix.shell().info("""

      ✅ Configuration added successfully!

      Next step: Run the update command again to complete the upgrade:
        mix phoenix_kit.update #{Enum.join(argv, " ")}
      """)
    end

    # Check if all required configuration exists
    # Returns :ok if all config present, :missing if any config is missing
    defp check_required_configuration do
      config_file = "config/config.exs"

      if File.exists?(config_file) do
        content = File.read!(config_file)

        cond do
          # Missing Ueberauth configuration entirely
          !String.contains?(content, "config :ueberauth") ->
            :missing

          # Incorrect Ueberauth configuration (providers: [] instead of providers: %{})
          String.contains?(content, "config :ueberauth, Ueberauth") &&
              Regex.match?(~r/providers:\s*\[\s*\]/, content) ->
            :missing

          # All required configuration present
          true ->
            :ok
        end
      else
        # config.exs doesn't exist - let normal flow handle this error
        :ok
      end
    rescue
      # If we can't read config, proceed with normal flow
      _ -> :ok
    end

    # Perform the igniter-based update logic
    defp perform_igniter_update(igniter, opts) do
      prefix = opts[:prefix] || "public"
      force = opts[:force] || false

      # Validate and fix Ueberauth configuration before update
      igniter = validate_and_fix_ueberauth_config(igniter)

      # Ensure Hammer rate limiter configuration exists
      igniter = validate_and_add_hammer_config(igniter)

      case Common.check_installation_status(prefix) do
        {:not_installed} ->
          add_not_installed_notice(igniter)

        {:current_version, current_version} ->
          target_version = Common.current_version()

          cond do
            current_version >= target_version && !force ->
              add_already_up_to_date_notice(igniter, current_version)

            current_version < target_version || force ->
              create_update_migration_with_igniter(
                igniter,
                prefix,
                current_version,
                target_version,
                force,
                opts
              )

            true ->
              igniter
          end
      end
    end

    # Create update migration using igniter
    defp create_update_migration_with_igniter(
           igniter,
           prefix,
           current_version,
           target_version,
           force,
           opts
         ) do
      create_schema = prefix != "public"

      # Generate timestamp and migration file name using Ecto format
      timestamp = Common.generate_timestamp()
      action = if force, do: "force_update", else: "update"

      # Create padded version variables for shorter strings
      current_version_padded = Common.pad_version(current_version)
      target_version_padded = Common.pad_version(target_version)

      migration_name =
        "#{timestamp}_phoenix_kit_#{action}_v#{current_version_padded}_to_v#{target_version_padded}.exs"

      # Generate module name
      module_name =
        "PhoenixKit#{String.capitalize(action)}V#{current_version_padded}ToV#{target_version_padded}"

      # Create migration content
      migration_content = """
      defmodule Ecto.Migrations.#{module_name} do
        @moduledoc false
        use Ecto.Migration

        def up do
          # PhoenixKit Update Migration: V#{current_version_padded} -> V#{target_version_padded}
          PhoenixKit.Migrations.up([
            prefix: "#{prefix}",
            version: #{target_version},
            create_schema: #{create_schema}
          ])
        end

        def down do
          # Rollback PhoenixKit to V#{current_version_padded}
          PhoenixKit.Migrations.down([
            prefix: "#{prefix}",
            version: #{current_version}
          ])
        end
      end
      """

      # Use igniter to create the migration file
      migration_path = "priv/repo/migrations/#{migration_name}"

      igniter
      |> Igniter.create_new_file(migration_path, migration_content)
      |> add_migration_created_notice(migration_name, current_version, target_version)
      |> add_post_igniter_instructions(opts)
    end

    # Add notices for different scenarios
    defp add_not_installed_notice(igniter) do
      notice = """

      ❌ PhoenixKit is not installed.

      Please run: mix phoenix_kit.install
      """

      Igniter.add_notice(igniter, notice)
    end

    defp add_already_up_to_date_notice(igniter, current_version) do
      current_version_padded = Common.pad_version(current_version)

      notice = """

      ✅ PhoenixKit is already up to date (V#{current_version_padded}).

      Use --force to regenerate the migration anyway.
      """

      Igniter.add_notice(igniter, notice)
    end

    defp add_migration_created_notice(igniter, migration_name, current_version, target_version) do
      current_version_padded = Common.pad_version(current_version)
      target_version_padded = Common.pad_version(target_version)

      notice = """

      📦 PhoenixKit Update Migration Created: #{migration_name}
      - Updating from V#{current_version_padded} to V#{target_version_padded}
      """

      Igniter.add_notice(igniter, notice)
    end

    defp add_post_igniter_instructions(igniter, opts) do
      skip_assets = opts[:skip_assets] || false
      yes = opts[:yes] || false

      instructions = """

      📋 Next steps:
      """

      instructions =
        if skip_assets do
          instructions <> "    • CSS integration will be updated manually\n"
        else
          instructions <> "    • CSS integration and assets will be updated\n"
        end

      instructions =
        if yes do
          instructions <> "    • Migration will run automatically (--yes flag)\n"
        else
          instructions <> "    • You'll be prompted to run the migration\n"
        end

      final_instructions =
        instructions <>
          """

          After update completes:
            1. Run migrations if not done automatically: mix ecto.migrate
            2. Restart your Phoenix server: mix phx.server
            3. Visit your application: #{Routes.path("/users/register")}
          """

      Igniter.add_notice(igniter, final_instructions)
    end

    # Handle tasks that need to run after igniter completes
    defp post_igniter_tasks(opts) do
      # Update CSS integration (enables daisyUI themes if disabled)
      update_css_integration()

      # Always rebuild assets unless explicitly skipped
      unless Keyword.get(opts, :skip_assets, false) do
        AssetRebuild.check_and_rebuild(verbose: true)
      end

      # Handle interactive migration execution
      run_interactive_migration_update(opts)
    end

    # Run interactive migration for updates
    defp run_interactive_migration_update(opts) do
      yes = Keyword.get(opts, :yes, false)

      # Check if we can run migrations safely
      case check_migration_conditions() do
        :ok ->
          run_interactive_migration_prompt_update(yes)

        {:error, reason} ->
          if yes do
            # If -y flag is used but conditions aren't met, try to run migration anyway
            Mix.shell().info(
              "\n⚠️  Migration conditions not optimal (#{reason}), but running due to -y flag..."
            )

            run_migration_with_feedback()
          else
            Mix.shell().info("""

            💡 Migration not run automatically (#{reason}).
            To run migration manually:
              mix ecto.migrate
            """)
          end
      end
    end

    # Prompt user for migration execution (update-specific)
    defp run_interactive_migration_prompt_update(yes) do
      if yes do
        # Skip prompt and run migration directly
        Mix.shell().info("\n🚀 Running database migration automatically (--yes flag)...")
        run_migration_with_feedback()
      else
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
    end

    # Display comprehensive help information
    defp show_help do
      Mix.shell().info("""

      mix phoenix_kit.update - Update PhoenixKit to the latest version

      USAGE
        mix phoenix_kit.update [OPTIONS]

      DESCRIPTION
        Updates an existing PhoenixKit installation to the latest version by:
        • Creating upgrade migrations that preserve existing data
        • Adding new features and improvements
        • Updating CSS configuration (enables daisyUI themes if disabled)
        • Rebuilding assets using the Phoenix asset pipeline
        • Optionally running database migrations automatically

      OPTIONS
        --prefix SCHEMA         Database schema prefix for PhoenixKit tables
                                Default: "public" (standard PostgreSQL schema)
                                Must match prefix used during installation
                                Example: --prefix "auth"

        --status, -s            Show current installation status and available updates
                                Does not perform any changes

        --force, -f             Force update even if already up to date
                                Useful for regenerating migrations

        --skip-assets           Skip automatic asset rebuild check
                                Default: false

        --yes, -y               Skip confirmation prompts
                                Automatically runs migrations without asking
                                Useful for CI/CD environments

        -h, --help              Show this help message

      EXAMPLES
        # Update PhoenixKit to latest version (uses default "public" schema)
        mix phoenix_kit.update

        # Check current version and available updates
        mix phoenix_kit.update --status

        # Update with custom schema prefix (must match installation prefix)
        mix phoenix_kit.update --prefix "auth"

        # Update without prompts (useful for CI/CD)
        mix phoenix_kit.update -y

        # Force update and run migrations automatically
        mix phoenix_kit.update --force -y

        # Update without rebuilding assets
        mix phoenix_kit.update --skip-assets

      VERSION MANAGEMENT
        PhoenixKit uses a versioned migration system.
        Each version contains specific database schema changes that can
        be applied incrementally.

        Current latest version: V17
        • V01: Basic authentication with role system
        • V02: Remove is_active column from role assignments
        • V03-V06: Additional features and improvements
        • V07: Email system tables (logs, events, blocklist)
        • V08-V17: Settings, OAuth, magic links, and more

      SAFE UPDATES
        All PhoenixKit updates are designed to be:
        • Non-destructive (existing data is preserved)
        • Backward compatible (existing code continues to work)
        • Idempotent (safe to run multiple times)
        • Rollback-capable (can be reverted if needed)

      TWO-PASS UPDATE STRATEGY
        If required configuration is missing, the update process will:
        1. First run: Add missing configuration (e.g., Ueberauth settings)
        2. Prompt you to run the command again
        3. Second run: Complete the update with all configuration present

        This prevents configuration timing issues where the application
        starts before new configuration is available.

      AFTER UPDATE
        1. If migrations weren't run automatically:
           mix ecto.migrate

        2. Restart your Phoenix server:
           mix phx.server

        3. Visit your application:
           http://localhost:4000/phoenix_kit/users/register

      CI/CD USAGE
        For automated deployments, use the --yes flag to skip prompts:
        mix phoenix_kit.update -y

      TROUBLESHOOTING
        If the update fails or you need to check status:
        • Check version: mix phoenix_kit.update --status
        • Force regeneration: mix phoenix_kit.update --force
        • Manual migration: mix ecto.migrate
        • Rollback: mix ecto.rollback

      DOCUMENTATION
        For more information, visit:
        https://hexdocs.pm/phoenix_kit
      """)
    end

    # Show current installation status and available updates
    defp show_status(opts) do
      prefix = opts[:prefix] || "public"

      # Use the status command to show current status
      args = if prefix == "public", do: [], else: ["--prefix=#{prefix}"]
      Mix.Task.run("phoenix_kit.status", args)
    end

    # Update CSS integration during PhoenixKit updates
    defp update_css_integration do
      css_paths = [
        "assets/css/app.css",
        "priv/static/css/app.css",
        "lib/#{Mix.Phoenix.otp_app()}_web/assets/css/app.css"
      ]

      case Enum.find(css_paths, &File.exists?/1) do
        nil ->
          # No app.css found - skip CSS integration
          :ok

        css_path ->
          # Update CSS file to enable daisyUI themes if disabled
          content = File.read!(css_path)
          existing = CssIntegration.check_existing_integration(content)

          if existing.daisyui_themes_disabled do
            # Use regex to update themes: false -> themes: all
            pattern = ~r/@plugin\s+(["'][^"']*daisyui["'])\s*\{([^}]*themes:\s*)false([^}]*)\}/

            updated_content =
              String.replace(content, pattern, fn match ->
                String.replace(match, ~r/(themes:\s*)false/, "\\1all")
              end)

            File.write!(css_path, updated_content)

            Mix.shell().info("""

            ✅ Updated daisyUI configuration to enable all themes!
            File: #{css_path}
            Changed: themes: false → themes: all
            """)
          end
      end
    rescue
      error ->
        # Non-critical error - log and continue
        Mix.shell().info("ℹ️  Could not update CSS integration: #{inspect(error)}")
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

    # Validate and fix Ueberauth configuration
    defp validate_and_fix_ueberauth_config(igniter) do
      # Read current config.exs to check Ueberauth configuration
      config_file = "config/config.exs"

      if File.exists?(config_file) do
        content = File.read!(config_file)

        # Check Ueberauth configuration status
        cond do
          # Case 1: Incorrect configuration with providers: []
          String.contains?(content, "config :ueberauth, Ueberauth") &&
              Regex.match?(~r/providers:\s*\[\s*\]/, content) ->
            fix_ueberauth_providers_config(igniter, content)

          # Case 2: Configuration exists and is correct (providers: %{} or with values)
          String.contains?(content, "config :ueberauth, Ueberauth") ->
            igniter

          # Case 3: Configuration is missing - add it
          true ->
            add_missing_ueberauth_config(igniter)
        end
      else
        # config.exs doesn't exist, skip validation
        igniter
      end
    end

    # Fix Ueberauth providers configuration from [] to %{}
    defp fix_ueberauth_providers_config(igniter, _content) do
      igniter
      |> Igniter.update_file("config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        # Replace providers: [] with providers: %{}
        updated_content =
          Regex.replace(
            ~r/(config\s+:ueberauth,\s+Ueberauth,\s+providers:\s*)\[\s*\]/,
            content,
            "\\1%{}"
          )

        Rewrite.Source.update(source, :content, updated_content)
      end)
      |> add_ueberauth_fix_notice()
    end

    # Add notice about Ueberauth configuration fix
    defp add_ueberauth_fix_notice(igniter) do
      notice = """
      ✅ Fixed Ueberauth configuration: providers: [] → providers: %{}
         OAuth authentication will now work correctly.
      """

      Igniter.add_notice(igniter, String.trim(notice))
    end

    # Add missing Ueberauth configuration
    defp add_missing_ueberauth_config(igniter) do
      igniter
      |> Config.configure_new(
        "config.exs",
        :ueberauth,
        [Ueberauth],
        providers: %{}
      )
      |> add_ueberauth_added_notice()
    end

    # Add notice about Ueberauth configuration being added
    defp add_ueberauth_added_notice(igniter) do
      notice = """
      ✅ Added missing Ueberauth configuration: providers: %{}
         OAuth authentication configured for runtime loading.
      """

      Igniter.add_notice(igniter, String.trim(notice))
    end

    # Validate and add Hammer rate limiter configuration if missing
    defp validate_and_add_hammer_config(igniter) do
      if RateLimiterConfig.hammer_config_exists?(igniter) do
        # Configuration exists, no action needed
        igniter
      else
        # Configuration missing, add it
        igniter
        |> RateLimiterConfig.add_rate_limiter_configuration()
        |> add_hammer_config_added_notice()
      end
    end

    # Add notice about Hammer configuration being added
    defp add_hammer_config_added_notice(igniter) do
      notice = """
      ⚠️  Added missing Hammer rate limiter configuration to config.exs
         IMPORTANT: Restart your server if it's currently running.
         Without this configuration, the application will fail to start.
      """

      Igniter.add_notice(igniter, String.trim(notice))
    end

    # Ensure Hammer configuration exists BEFORE app.start
    # This is critical because app.start will fail without Hammer config
    defp ensure_hammer_config_before_start do
      config_path = "config/config.exs"

      if File.exists?(config_path) do
        content = File.read!(config_path)

        # Check if Hammer config exists
        unless String.contains?(content, "config :hammer") and
                 String.contains?(content, "expiry_ms") do
          # Add Hammer configuration
          Mix.shell().info("⚠️  Adding missing Hammer configuration to config.exs...")
          add_hammer_config_directly(config_path, content)
          Mix.shell().info("✅ Hammer configuration added successfully")
        end
      end
    rescue
      e ->
        Mix.shell().error("""
        ⚠️  Failed to check/add Hammer configuration: #{inspect(e)}
        Please add the configuration manually to config/config.exs:

          config :hammer,
            backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

          config :phoenix_kit, PhoenixKit.Users.RateLimiter,
            login_limit: 5, login_window_ms: 60_000,
            magic_link_limit: 3, magic_link_window_ms: 300_000,
            password_reset_limit: 3, password_reset_window_ms: 300_000,
            registration_limit: 3, registration_window_ms: 3_600_000,
            registration_ip_limit: 10, registration_ip_window_ms: 3_600_000
        """)
    end

    # Add Hammer configuration directly to config file (without Igniter)
    defp add_hammer_config_directly(config_path, content) do
      hammer_config = """

      # Configure rate limiting with Hammer
      config :hammer,
        backend:
          {Hammer.Backend.ETS,
           [
             # Cleanup expired rate limit buckets every 60 seconds
             expiry_ms: 60_000,
             # Cleanup interval (1 minute)
             cleanup_interval_ms: 60_000
           ]}

      # Configure rate limits for authentication endpoints
      config :phoenix_kit, PhoenixKit.Users.RateLimiter,
        # Login: 5 attempts per minute per email
        login_limit: 5,
        login_window_ms: 60_000,
        # Magic link: 3 requests per 5 minutes per email
        magic_link_limit: 3,
        magic_link_window_ms: 300_000,
        # Password reset: 3 requests per 5 minutes per email
        password_reset_limit: 3,
        password_reset_window_ms: 300_000,
        # Registration: 3 attempts per hour per email
        registration_limit: 3,
        registration_window_ms: 3_600_000,
        # Registration IP: 10 attempts per hour per IP
        registration_ip_limit: 10,
        registration_ip_window_ms: 3_600_000
      """

      # Find insertion point before import_config
      lines = String.split(content, "\n")

      import_index =
        Enum.find_index(lines, fn line ->
          trimmed = String.trim(line)
          String.starts_with?(trimmed, "import_config") or String.contains?(line, "import_config")
        end)

      updated_content =
        case import_index do
          nil ->
            # No import_config, append to end
            content <> hammer_config

          index ->
            # Insert before import_config
            {before_lines, after_lines} = Enum.split(lines, index)
            Enum.join(before_lines ++ [hammer_config] ++ after_lines, "\n")
        end

      File.write!(config_path, updated_content)
    end
  end

  # Fallback module for when Igniter is not available
else
  defmodule Mix.Tasks.PhoenixKit.Update do
    @moduledoc """
    PhoenixKit update task.

    This task requires the Igniter library to be available. Please add it to your mix.exs:

        {:igniter, "~> 0.6.27"}

    Then run: mix deps.get
    """

    @shortdoc "Update PhoenixKit (requires Igniter)"

    use Mix.Task

    def run(_args) do
      Mix.shell().error("""

      ❌ PhoenixKit update requires the Igniter library.

      Please add Igniter to your mix.exs dependencies:

          def deps do
            [
              {:igniter, "~> 0.6.27"}
              # ... your other dependencies
            ]
          end

      Then run:
        mix deps.get
        mix phoenix_kit.update

      For more information, visit: https://hex.pm/packages/igniter
      """)
    end
  end
end
