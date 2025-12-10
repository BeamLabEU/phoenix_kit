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
      IgniterHelpers,
      JsIntegration,
      ObanConfig,
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

          # Check if this is a retry pass (automatic restart after adding config)
          is_retry = Process.get(:phoenix_kit_retry_pass, false)
          config_status = check_required_configuration()

          case {config_status, is_retry} do
            {:missing, false} ->
              # First pass: Add configuration via Igniter without starting app
              # Store config status in Process dictionary for igniter/1 to read
              Process.put(:phoenix_kit_config_status, :missing)
              show_missing_config_message(argv)
              super(argv)

              # Automatic restart instead of manual prompt
              Mix.shell().info("""

              ✅ Configuration added successfully!
              🔄 Automatically restarting to complete the update...
              """)

              # Clean Process dictionary for fresh state
              Process.delete(:phoenix_kit_config_status)
              Process.put(:phoenix_kit_retry_pass, true)

              # Recursive call with same arguments
              run(argv)

            {:ok, _} ->
              # Second pass (automatic or manual): Configuration exists, safe to start app
              # Store config status in Process dictionary for igniter/1 to read
              Process.put(:phoenix_kit_config_status, :ok)
              Mix.Task.run("app.start")
              result = super(argv)
              post_igniter_tasks(elem(opts, 0))

              # Clean retry flag
              Process.delete(:phoenix_kit_retry_pass)
              result

            {:missing, true} ->
              # Safety: Configuration still missing after retry
              Mix.shell().error("""

              ❌ Configuration was not added successfully after automatic retry.

              This may indicate a problem with your config/config.exs file.
              Please check the file manually and ensure it's writable.

              Then run manually:
                mix phoenix_kit.update #{Enum.join(argv, " ")}
              """)

              Process.delete(:phoenix_kit_retry_pass)
              :error
          end
        end
      end
    end

    # Display message about missing configuration
    defp show_missing_config_message(argv) do
      Mix.shell().info("""

      ⚠️  Required configuration is missing from config/config.exs

      PhoenixKit requires configuration for:
      - Ueberauth (OAuth authentication)
      - Hammer (rate limiting)
      - Oban (background jobs for file processing)

      This configuration will be added now.

      After this completes, please run the update command again:
        mix phoenix_kit.update #{Enum.join(argv, " ")}
      """)
    end

    # Check if all required configuration exists
    # Returns :ok if all config present, :missing if any config is missing
    defp check_required_configuration do
      config_file = "config/config.exs"

      if File.exists?(config_file) do
        content = File.read!(config_file)
        lines = String.split(content, "\n")

        cond do
          # Missing Ueberauth configuration entirely
          !String.contains?(content, "config :ueberauth") ->
            :missing

          # Incorrect Ueberauth configuration (providers: [] instead of providers: %{})
          String.contains?(content, "config :ueberauth, Ueberauth") &&
              Regex.match?(~r/providers:\s*\[\s*\]/, content) ->
            :missing

          # Missing Hammer configuration (check for active, non-commented config)
          !has_active_hammer_config?(lines) ->
            :missing

          # Missing Oban configuration (check for active, non-commented config)
          !has_active_oban_config?(lines) ->
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

    # Check if active (non-commented) Hammer configuration exists
    defp has_active_hammer_config?(lines) do
      has_hammer_config =
        Enum.any?(lines, fn line ->
          trimmed = String.trim(line)
          # Not a comment and contains config :hammer
          !String.starts_with?(trimmed, "#") and String.starts_with?(trimmed, "config :hammer")
        end)

      has_expiry_ms =
        Enum.any?(lines, fn line ->
          trimmed = String.trim(line)
          # Not a comment and contains expiry_ms
          !String.starts_with?(trimmed, "#") and String.contains?(line, "expiry_ms")
        end)

      has_hammer_config and has_expiry_ms
    end

    # Check if active (non-commented) Oban configuration exists
    defp has_active_oban_config?(lines) do
      has_oban_config =
        Enum.any?(lines, fn line ->
          trimmed = String.trim(line)
          # Not a comment and contains config for any app with Oban
          # Matches: "config :any_app, Oban" or "config :any_app, Oban,"
          !String.starts_with?(trimmed, "#") and
            String.contains?(line, ", Oban")
        end)

      has_queues =
        Enum.any?(lines, fn line ->
          trimmed = String.trim(line)
          # Not a comment and contains queues:
          !String.starts_with?(trimmed, "#") and String.contains?(line, "queues:")
        end)

      has_oban_config and has_queues
    end

    # Perform the igniter-based update logic
    defp perform_igniter_update(igniter, opts) do
      prefix = opts[:prefix] || "public"
      force = opts[:force] || false

      # Validate and fix Ueberauth configuration before update
      igniter = validate_and_fix_ueberauth_config(igniter)

      # Ensure Hammer rate limiter configuration exists
      igniter = validate_and_add_hammer_config(igniter)

      # Ensure Oban configuration exists
      igniter = validate_and_add_oban_config(igniter)

      # CRITICAL FIX: Ensure correct supervisor ordering in application.ex
      # This must run AFTER add_oban_supervisor to fix installations with wrong order
      igniter = fix_supervisor_ordering(igniter)

      # Check if this is the first pass (config missing) or second pass (config exists)
      config_status = Process.get(:phoenix_kit_config_status, :ok)

      case config_status do
        :missing ->
          # First pass: Only add configuration, skip migration creation
          # Migration will be created in second pass after app is started
          igniter

        :ok ->
          # Second pass: Configuration exists, app is started, proceed with migration
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

      # Update JS integration (adds PhoenixKit hooks if missing)
      update_js_integration()

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

    # Update JS integration during PhoenixKit updates
    defp update_js_integration do
      js_paths = [
        "assets/js/app.js",
        "priv/static/assets/app.js"
      ]

      case Enum.find(js_paths, &File.exists?/1) do
        nil ->
          # No app.js found - skip JS integration
          :ok

        js_path ->
          # First, ensure vendor files are up to date
          copy_vendor_files(js_path)

          # Update JS file - fix old paths and add hooks if missing
          content = File.read!(js_path)

          # Use Rewrite.Source pattern for consistency
          source = Rewrite.Source.from_string(content, path: js_path)
          updated_source = JsIntegration.add_smart_js_integration(source)
          updated_content = Rewrite.Source.get(updated_source, :content)

          # Only write if content changed
          if updated_content != content do
            File.write!(js_path, updated_content)

            Mix.shell().info("""

            ✅ Updated JavaScript configuration with PhoenixKit hooks!
            File: #{js_path}
            """)
          end
      end
    rescue
      error ->
        # Non-critical error - log and continue
        Mix.shell().info("ℹ️  Could not update JS integration: #{inspect(error)}")
    end

    # Copy PhoenixKit JS files to vendor directory
    defp copy_vendor_files(js_path) do
      vendor_dir = js_path |> Path.dirname() |> Path.join("vendor")
      File.mkdir_p!(vendor_dir)

      source_dir = get_phoenix_kit_assets_dir()
      source_files = ["phoenix_kit.js", "phoenix_kit_sortable.js"]

      Enum.each(source_files, fn file ->
        source_path = Path.join(source_dir, file)
        dest_path = Path.join(vendor_dir, file)

        if File.exists?(source_path) do
          content = File.read!(source_path)

          # Only write if different or doesn't exist
          should_write =
            !File.exists?(dest_path) or File.read!(dest_path) != content

          if should_write do
            File.write!(dest_path, content)
            Mix.shell().info("  📦 Updated #{dest_path}")
          end
        end
      end)
    end

    # Get the path to PhoenixKit's static assets directory
    defp get_phoenix_kit_assets_dir do
      # Use :code.priv_dir to get the actual priv directory of the phoenix_kit application
      # This works for both Hex packages and local path dependencies
      case :code.priv_dir(:phoenix_kit) do
        {:error, _} ->
          # Fallback: try common locations
          possible_paths = [
            "deps/phoenix_kit/priv/static/assets",
            Path.join([Mix.Project.deps_path(), "phoenix_kit", "priv", "static", "assets"])
          ]

          Enum.find(possible_paths, &File.dir?/1) || List.first(possible_paths)

        priv_dir ->
          assets_path = Path.join([to_string(priv_dir), "static", "assets"])

          if File.dir?(assets_path) do
            assets_path
          else
            "deps/phoenix_kit/priv/static/assets"
          end
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

    # Validate and add Oban configuration if missing
    # Fix supervisor ordering in application.ex to prevent startup crashes
    # Ensures correct order: Repo → PhoenixKit.Supervisor → Oban → Endpoint
    defp fix_supervisor_ordering(igniter) do
      app_name = IgniterHelpers.get_parent_app_name(igniter)
      app_file = "lib/#{app_name}/application.ex"

      if File.exists?(app_file) do
        content = File.read!(app_file)

        # Check current supervisor ordering
        case check_supervisor_order(content, app_name) do
          :correct ->
            # Order is already correct, no changes needed
            igniter

          {:needs_fix, reason} ->
            # Order is incorrect, attempt to fix using Igniter API
            igniter
            |> fix_application_supervisor_order(app_name, reason)
            |> add_supervisor_ordering_fixed_notice(reason)

          :cannot_determine ->
            # Cannot determine order (unusual setup), skip silently
            igniter
        end
      else
        # No application.ex found (unusual), skip
        igniter
      end
    rescue
      e ->
        # If any error occurs, log warning but continue
        Mix.shell().info("⚠️  Could not check supervisor ordering: #{inspect(e)}")
        igniter
    end

    # Check the ordering of supervisors in application.ex
    # Returns :correct, {:needs_fix, reason}, or :cannot_determine
    defp check_supervisor_order(content, app_name) do
      lines = String.split(content, "\n")

      # Find line numbers for each supervisor
      repo_line = find_supervisor_line(lines, ~r/#{app_name}\.Repo[,\s]/)
      phoenix_kit_line = find_supervisor_line(lines, ~r/PhoenixKit\.Supervisor[,\s]/)

      oban_line =
        find_supervisor_line(lines, ~r/\{Oban,|Application\.get_env\(:#{app_name}, Oban\)/)

      validate_supervisor_positions(repo_line, phoenix_kit_line, oban_line)
    end

    # Validate supervisor positions and return check result
    defp validate_supervisor_positions(nil, nil, nil), do: :cannot_determine
    defp validate_supervisor_positions(nil, _, _), do: :cannot_determine
    defp validate_supervisor_positions(repo, nil, nil) when is_integer(repo), do: :correct

    defp validate_supervisor_positions(repo, pk, nil) when is_integer(repo) and is_integer(pk) do
      if repo < pk, do: :correct, else: {:needs_fix, "PhoenixKit.Supervisor before Repo"}
    end

    defp validate_supervisor_positions(repo, pk, oban)
         when is_integer(repo) and is_integer(pk) and is_integer(oban) do
      check_three_supervisor_order(repo, pk, oban)
    end

    defp validate_supervisor_positions(_, _, _), do: :cannot_determine

    # Check ordering when all three supervisors exist
    defp check_three_supervisor_order(repo, pk, oban) do
      cond do
        pk < repo and oban < repo -> {:needs_fix, "both PhoenixKit and Oban before Repo"}
        pk < repo -> {:needs_fix, "PhoenixKit.Supervisor before Repo"}
        oban < repo -> {:needs_fix, "Oban before Repo"}
        oban < pk -> {:needs_fix, "Oban before PhoenixKit.Supervisor"}
        true -> :correct
      end
    end

    # Find the line number where a supervisor is defined
    defp find_supervisor_line(lines, pattern) do
      lines
      |> Enum.with_index(1)
      |> Enum.find(fn {line, _index} ->
        trimmed = String.trim(line)
        # Not a comment and matches pattern
        !String.starts_with?(trimmed, "#") and Regex.match?(pattern, line)
      end)
      |> case do
        {_line, index} -> index
        nil -> nil
      end
    end

    # Fix the supervisor ordering using manual reordering
    # Note: We can't use Igniter.Project.Application.add_new_child to reorder existing children,
    # so we need to manually reorder the children list
    defp fix_application_supervisor_order(igniter, app_name, _reason) do
      app_file = "lib/#{app_name}/application.ex"

      Igniter.update_file(igniter, app_file, fn source ->
        content = Rewrite.Source.get(source, :content)
        fixed_content = reorder_supervisors(content, app_name)
        Rewrite.Source.update(source, :content, fixed_content)
      end)
    end

    # Reorder supervisors in application.ex to correct order
    defp reorder_supervisors(content, app_name) do
      lines = String.split(content, "\n")

      # Extract supervisor lines
      {repo_line, repo_index} = extract_supervisor(lines, ~r/#{app_name}\.Repo[,\s]/)
      {pk_line, pk_index} = extract_supervisor(lines, ~r/PhoenixKit\.Supervisor[,\s]/)

      {oban_line, oban_index} =
        extract_supervisor(lines, ~r/\{Oban,|Application\.get_env\(:#{app_name}, Oban\)/)

      # Determine children list boundaries
      children_start = find_children_list_start(lines)
      children_end = find_children_list_end(lines, children_start)

      if is_integer(children_start) and is_integer(children_end) do
        # Build new children list with correct order
        supervisors = %{
          repo: {repo_line, repo_index},
          phoenix_kit: {pk_line, pk_index},
          oban: {oban_line, oban_index}
        }

        new_lines =
          rebuild_children_list(lines, children_start, children_end, supervisors)

        Enum.join(new_lines, "\n")
      else
        # Cannot find children list boundaries, return unchanged
        content
      end
    end

    # Extract supervisor line and its index
    defp extract_supervisor(lines, pattern) do
      case Enum.with_index(lines, 1) do
        indexed_lines ->
          case Enum.find(indexed_lines, fn {line, _index} ->
                 trimmed = String.trim(line)
                 !String.starts_with?(trimmed, "#") and Regex.match?(pattern, line)
               end) do
            {line, index} -> {line, index}
            nil -> {nil, nil}
          end
      end
    end

    # Find the start of children list
    defp find_children_list_start(lines) do
      Enum.find_index(lines, fn line ->
        String.contains?(line, "children = [")
      end)
    end

    # Find the end of children list (closing bracket)
    defp find_children_list_end(lines, start_index) do
      lines
      |> Enum.drop(start_index + 1)
      |> Enum.with_index(start_index + 1)
      |> Enum.find(fn {line, _index} ->
        trimmed = String.trim(line)
        trimmed == "]"
      end)
      |> case do
        {_line, index} -> index
        nil -> nil
      end
    end

    # Rebuild children list with correct supervisor ordering
    defp rebuild_children_list(lines, children_start, children_end, supervisors) do
      %{
        repo: {repo_line, repo_index},
        phoenix_kit: {pk_line, pk_index},
        oban: {oban_line, oban_index}
      } = supervisors

      # Lines before children list
      before_children = Enum.take(lines, children_start + 1)

      # Lines after children list
      after_children = Enum.drop(lines, children_end)

      # Get all children between start and end
      children_lines =
        lines
        |> Enum.drop(children_start + 1)
        |> Enum.take(children_end - children_start - 1)

      # Remove repo, phoenix_kit, and oban lines from children
      filtered_children =
        children_lines
        |> Enum.with_index(children_start + 2)
        |> Enum.reject(fn {_line, index} ->
          index in [repo_index, pk_index, oban_index]
        end)
        |> Enum.map(fn {line, _index} -> line end)

      # Build new ordered children list
      ordered_children =
        build_ordered_supervisor_list(repo_line, pk_line, oban_line, filtered_children)

      # Reconstruct file
      before_children ++ ordered_children ++ after_children
    end

    # Build ordered list of supervisors with correct positioning
    defp build_ordered_supervisor_list(repo_line, pk_line, oban_line, filtered_children) do
      # Add Repo first (if exists)
      ordered = if repo_line, do: [repo_line], else: []

      # Split remaining children at Endpoint
      {before_endpoint, from_endpoint} = split_at_endpoint(filtered_children)

      # Add PhoenixKit after Repo, before Endpoint
      ordered = ordered ++ before_endpoint
      ordered = if pk_line, do: ordered ++ [pk_line], else: ordered

      # Add Oban after PhoenixKit
      ordered = if oban_line, do: ordered ++ [oban_line], else: ordered

      # Add remaining children (Endpoint and after)
      ordered ++ from_endpoint
    end

    # Split children at Endpoint line
    defp split_at_endpoint(children) do
      endpoint_index =
        Enum.find_index(children, fn line ->
          String.contains?(line, "Endpoint") and !String.contains?(line, "#")
        end)

      case endpoint_index do
        nil -> {children, []}
        index -> Enum.split(children, index)
      end
    end

    # Add notice about supervisor ordering being fixed
    defp add_supervisor_ordering_fixed_notice(igniter, reason) do
      notice = """
      ⚠️  CRITICAL FIX APPLIED: Corrected supervisor ordering in application.ex

         Issue detected: #{reason}

         Fixed to correct order:
           1. YourApp.Repo            (database connection - must be first)
           2. PhoenixKit.Supervisor   (uses Repo for Settings cache)
           3. {Oban, ...}            (uses Repo for job persistence)
           4. Other supervisors...

         This fixes startup crashes where PhoenixKit or Oban tried to access
         the database before Repo was ready.

         IMPORTANT: Restart your server for changes to take effect.
      """

      Igniter.add_notice(igniter, String.trim(notice))
    end

    defp validate_and_add_oban_config(igniter) do
      config_exists = ObanConfig.oban_config_exists?(igniter)
      supervisor_exists = ObanConfig.oban_supervisor_exists?(igniter)

      igniter =
        if config_exists do
          igniter
        else
          # Configuration missing, add it
          igniter
          |> ObanConfig.add_oban_configuration()
          |> add_oban_config_added_notice()
        end

      # Check and add supervisor separately
      if supervisor_exists do
        igniter
      else
        igniter
        |> ObanConfig.add_oban_supervisor()
        |> add_oban_supervisor_added_notice()
      end
    end

    # Add notice about Oban configuration being added
    defp add_oban_config_added_notice(igniter) do
      notice = """
      ⚠️  Added missing Oban configuration to config.exs
         IMPORTANT: Restart your server if it's currently running.
         Without Oban, the storage system cannot process uploaded files.
      """

      Igniter.add_notice(igniter, String.trim(notice))
    end

    # Add notice about Oban supervisor being added
    defp add_oban_supervisor_added_notice(igniter) do
      notice = """
      ⚠️  Added Oban to application supervisor tree in application.ex
         IMPORTANT: Restart your server if it's currently running.
         Oban will now start automatically with your application.
      """

      Igniter.add_notice(igniter, String.trim(notice))
    end
  end

  # Fallback module for when Igniter is not available
else
  defmodule Mix.Tasks.PhoenixKit.Update do
    @moduledoc """
    PhoenixKit update task.

    This task requires the Igniter library to be available. Please add it to your mix.exs:

        {:igniter, "~> 0.7"}

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
              {:igniter, "~> 0.7"}
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
