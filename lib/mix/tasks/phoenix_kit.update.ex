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

      * `--prefix` - Database schema prefix. When omitted, resolves from
        `config :phoenix_kit, :prefix`, then defaults to "public". Passing it
        explicitly also persists the config entry. On prefixed installs the
        task warns when your existing Oban config lacks the `prefix:` key.
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

    Run `mix phoenix_kit.status` to see the currently installed and latest
    available migration versions.

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
      BootHook,
      Common,
      CssIntegration,
      DaisyUI,
      DbConnectionCheck,
      Deprecations,
      EndpointIntegration,
      IgniterHelpers,
      JsIntegration,
      ObanConfig,
      PrefixConfig,
      RateLimiterConfig
    }

    alias PhoenixKit.Migrations.Modules, as: MigrationModules
    alias PhoenixKit.Migrations.Postgres, as: MigrationsPostgres
    # NOTE: Do NOT alias PhoenixKit.Utils.Routes here — it depends on
    # application config that isn't available during mix task execution.

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
        |> BootHook.add_boot_hook()
        |> EndpointIntegration.add_pdfjs_static_mount()
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

              # Cap the Ecto pool to 2 connections so we don't saturate PgBouncer
              # when the production app is already running.
              #
              # The sequencing is critical:
              # 1. Run app.config first — this evaluates config/runtime.exs (which
              #    reads POOL_SIZE env and sets pool_size: N in Application env).
              # 2. THEN override pool_size to 2 via Application.put_env, after
              #    runtime.exs has already run and can no longer overwrite us.
              # 3. THEN start app — app.config won't run again (Mix tracks ran tasks),
              #    so Ecto initialises the pool with our capped pool_size: 2.
              Mix.Task.run("app.config")
              cap_repo_pool_size_for_update(2)

              # Tell PhoenixKit.Supervisor to skip Dashboard.Registry,
              # OAuthConfigLoader, and module workers so they don't compete
              # for the 2 available DB connections during startup.
              Application.put_env(:phoenix_kit, :update_mode, true)

              Mix.Task.run("app.start")

              # Verify database is reachable before running update
              DbConnectionCheck.ensure_connected!()

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
      # --prefix option → config :phoenix_kit, :prefix → "public".
      # Checking the wrong prefix here is dangerous: a prefixed install
      # looks "not installed" at public.
      prefix = PrefixConfig.resolve_prefix(opts)
      force = opts[:force] || false

      # When --prefix is passed explicitly, persist it into config (covers
      # installs made before the installer started writing it; no-op when
      # already configured). Without the flag there is nothing to backfill
      # from — config either already has it or the install is public.
      igniter = PrefixConfig.add_prefix_configuration(igniter, opts[:prefix])

      # Validate and fix Ueberauth configuration before update
      igniter = validate_and_fix_ueberauth_config(igniter)

      # Ensure Hammer rate limiter configuration exists
      igniter = validate_and_add_hammer_config(igniter)

      # Ensure Oban configuration exists
      igniter = validate_and_add_oban_config(igniter, prefix)

      # CRITICAL FIX: Ensure correct supervisor ordering in application.ex
      # This must run AFTER add_oban_supervisor to fix installations with wrong order
      igniter = fix_supervisor_ordering(igniter)

      # Register both compilers in a SINGLE mix.exs edit — touching :compilers
      # from two separate Igniter.Project.MixProject.update/4 calls corrupts
      # the second registration (see Common.ensure_compilers_registered/2).
      igniter =
        Common.ensure_compilers_registered(igniter, [
          :phoenix_kit_css_sources,
          :phoenix_kit_js_sources
        ])

      # Ensure the rest of the external-module JS integration is wired
      # (aggregate file, script tag). Picks up the feature on hosts installed
      # before it existed.
      igniter = JsIntegration.ensure_module_js_integration(igniter)

      # Check if this is the first pass (config missing) or second pass (config exists)
      config_status = Process.get(:phoenix_kit_config_status, :ok)

      case config_status do
        :missing ->
          # First pass: Only add configuration, skip migration creation
          # Migration will be created in second pass after app is started
          igniter

        :ok ->
          # Second pass: Configuration exists, app is started, proceed with migration
          handle_installation_status(
            Common.check_installation_status(prefix),
            igniter,
            prefix,
            force,
            opts
          )
      end
    end

    # Split out of `perform_igniter_update/2` to keep its cyclomatic
    # complexity down (credo's Refactor.CyclomaticComplexity) — this branch
    # was the below-floor addition's cost.
    defp handle_installation_status({:not_installed}, igniter, prefix, _force, _opts) do
      add_not_installed_notice(igniter, prefix)
    end

    defp handle_installation_status({:unreachable, reason}, igniter, _prefix, _force, _opts) do
      Igniter.add_warning(igniter, """
      ❌ Cannot reach the database to determine the installed PhoenixKit
      version (#{inspect(reason)}).

      Not generating an update migration — fix the database connection
      and re-run mix phoenix_kit.update.
      """)
    end

    defp handle_installation_status(
           {:current_version, current_version},
           igniter,
           prefix,
           force,
           opts
         ) do
      target_version = Common.current_version()
      floor_version = MigrationsPostgres.initial_version()

      cond do
        # Spec §5.2/§5.3: generating an update migration here would just
        # defer the SAME hard `BelowFloorError` to migrate-time
        # (`PhoenixKit.Migrations.Postgres.up/1`, once the generated
        # wrapper actually runs) — refuse up front instead, with the
        # bridge instructions, rather than hand the operator a migration
        # file that is guaranteed to raise. LIVE since the squash raised the
        # floor to 135: any install still at V1..V134 lands here
        # (current_version is always >= 1 in this clause — `{:not_installed}`
        # is handled separately above).
        current_version > 0 and current_version < floor_version ->
          add_below_floor_notice(igniter, current_version, floor_version)

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

    # Create update migration using igniter
    defp create_update_migration_with_igniter(
           igniter,
           prefix,
           current_version,
           target_version,
           force,
           opts
         ) do
      # An update implies an existing installation, so the schema exists —
      # never ask the chain to create it (CREATE SCHEMA fails for
      # low-privilege roles even with IF NOT EXISTS).
      create_schema = false

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
      # @disable_ddl_transaction is critical: without it, Ecto wraps the entire
      # migration in a single transaction.  ALTER TABLE requires AccessExclusiveLock,
      # which blocks (and is blocked by) every other connection on the table.
      # A long-running transaction holding such locks on dozens of tables will deadlock
      # with the production app's normal queries — even on an empty database.
      # With DDL transaction disabled each statement auto-commits, so locks are held
      # only for milliseconds per ALTER TABLE.  PhoenixKit migrations are already
      # fully idempotent (IF NOT EXISTS / IF EXISTS guards), so partial runs are safe.
      migration_content = """
      defmodule Ecto.Migrations.#{module_name} do
        @moduledoc false
        use Ecto.Migration

        @disable_ddl_transaction true

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

      # Check for existing migration with same version range to prevent duplicates
      existing_pattern =
        "phoenix_kit_#{action}_v#{current_version_padded}_to_v#{target_version_padded}.exs"

      existing_migration =
        Path.wildcard("priv/repo/migrations/*#{existing_pattern}")
        |> List.first()

      if existing_migration do
        notice = """

        ⚠️  Migration already exists: #{existing_migration}
           Skipping duplicate creation. To regenerate, delete the existing file first.
        """

        Igniter.add_notice(igniter, notice)
      else
        migration_path = "priv/repo/migrations/#{migration_name}"

        igniter
        |> Igniter.create_new_file(migration_path, migration_content)
        |> add_migration_created_notice(migration_name, current_version, target_version)
        |> add_post_igniter_instructions(opts)
      end
    end

    # Add notices for different scenarios
    defp add_not_installed_notice(igniter, prefix) do
      notice = """

      ❌ No PhoenixKit installation found at schema prefix #{inspect(prefix)}.

      If PhoenixKit IS installed but under a different schema prefix, pass it
      explicitly (and persist it in config so future runs resolve it):

        mix phoenix_kit.update --prefix your_schema
        config :phoenix_kit, prefix: "your_schema"

      If PhoenixKit is not installed yet, run: mix igniter.install phoenix_kit
      (or `mix phoenix_kit.install` if the dep is already in mix.exs)
      """

      Igniter.add_notice(igniter, notice)
    end

    # Spec §5.2/§5.3 generation-time below-floor refusal. Was dormant while
    # `MigrationsPostgres.initial_version/0` is 1 — every installed DB is
    # already at or above that floor, so `current_version` can never land
    # here today. Mirrors `PhoenixKit.Migrations.BelowFloorError`'s message
    # (this path never touches the DB again, so it can't raise that
    # exception directly — it names the same bridge instructions instead).
    defp add_below_floor_notice(igniter, current_version, floor_version) do
      current_padded = Common.pad_version(current_version)
      floor_padded = Common.pad_version(floor_version)

      notice = """

      ❌ PhoenixKit database is at V#{current_padded}, below this release's floor
      (V#{floor_padded}) — this release's chain no longer carries the migration
      modules below the floor, so it cannot generate a migration that would
      bring this database current.

      Install the last PhoenixKit 1.7.x release (the migration bridge) first,
      run its migrations until the reported version is at least V#{floor_padded},
      THEN move the dependency pin to this release and run
      mix phoenix_kit.update again.
      """

      Igniter.add_warning(igniter, notice)
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
            3. Visit your application: #{build_app_path(opts, "/users/register")}
          """

      Igniter.add_notice(igniter, final_instructions)
    end

    # Handle tasks that need to run after igniter completes
    defp post_igniter_tasks(opts) do
      prefix = PrefixConfig.resolve_prefix(opts)

      # Update CSS integration (enables daisyUI themes if disabled)
      update_css_integration()

      # Warn when the host's vendored daisyUI is older than what PhoenixKit's
      # UI is designed against (the host owns the file; we never touch it)
      warn_if_daisyui_outdated()

      # Advance heads-up that the user dashboard (/dashboard) is deprecated
      # (still works unchanged; see PhoenixKit.Install.Deprecations)
      warn_user_dashboard_deprecated()

      # Update JS hooks file
      JsIntegration.update_js_file()

      # Always rebuild assets unless explicitly skipped
      unless Keyword.get(opts, :skip_assets, false) do
        AssetRebuild.check_and_rebuild(verbose: true)
      end

      # Handle interactive migration execution
      run_interactive_migration_update(opts)

      # Run migrations for registered PhoenixKit modules (e.g. Document Creator)
      run_module_migrations(opts)

      # Show migration status summary
      show_migration_status(prefix)
    end

    # Run interactive migration for updates
    defp run_interactive_migration_update(opts) do
      yes = Keyword.get(opts, :yes, false)

      # Check if we can run migrations safely
      case check_migration_conditions() do
        :ok ->
          run_interactive_migration_prompt_update(yes, opts)

        {:error, reason} ->
          if yes do
            # If -y flag is used but conditions aren't met, try to run migration anyway
            Mix.shell().info(
              "\n⚠️  Migration conditions not optimal (#{reason}), but running due to -y flag..."
            )

            run_migration_with_feedback(opts)
          else
            raise_pending_migration("""
            Migration not run automatically (#{reason}).
            """)
          end
      end
    end

    # Prompt user for migration execution (update-specific)
    defp run_interactive_migration_prompt_update(yes, opts) do
      if yes do
        # Skip prompt and run migration directly
        Mix.shell().info("\n🚀 Running database migration automatically (--yes flag)...")
        run_migration_with_feedback(opts)
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
            run_migration_with_feedback(opts)

          _ ->
            raise_pending_migration("Migration skipped at your request.")
        end
      end
    end

    # A pending migration means new code is running against an old schema, so the
    # task must NOT exit 0. It used to: `ssh host "mix phoenix_kit.update"`
    # succeeded, the deploy went green, and the drift was silent — in exactly the
    # environment where you least want to find out later.
    #
    # `Mix.raise/1` gives a non-zero exit with a clean message and no stacktrace.
    # It fires for the interactive "no" too: the exit code answers "is this
    # install up to date?", and the answer does not depend on why it is not.
    defp raise_pending_migration(reason) do
      Mix.raise("""
      #{String.trim(reason)}

      PhoenixKit's code is updated but the database is not. Do one of:

        mix ecto.migrate                 # run it now
        mix phoenix_kit.update --yes     # re-run this task and migrate without prompting
                                         # (this is the one for CI/CD and deploy scripts)
      """)
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
                                Omitted: resolves from config :phoenix_kit,
                                :prefix, then defaults to "public" — so a
                                configured prefixed install needs no flag.
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

        Run mix phoenix_kit.status for the installed and latest versions.

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
        https://phoenix-kit.hexdocs.pm
      """)
    end

    # Run versioned migrations for all registered PhoenixKit modules that
    # implement `migration_module/0`. Generates an incremental migration file
    # in the parent app for each module that needs updating, then runs migrations.
    defp run_module_migrations(opts) do
      prefix = PrefixConfig.resolve_prefix(opts)
      modules = MigrationModules.list(prefix: prefix)

      report_unreadable_modules(modules)

      case MigrationModules.pending(modules) do
        [] ->
          report_modules_up_to_date(modules)

        pending ->
          # Write every module's migration file FIRST, then migrate once.
          # The old code ran a full `ecto.migrate` inside the loop, so N
          # modules meant N migrator runs over the same (growing) directory.
          written =
            pending
            |> Enum.with_index()
            |> Enum.flat_map(fn {entry, index} ->
              Mix.shell().info(
                "\n⏳ #{entry.name}: V#{pad_version(entry.installed)} → V#{pad_version(entry.target)}"
              )

              write_module_migration(entry, prefix, index)
            end)

          if written != [] do
            migrate_host_repo()
          end

          verify_module_migrations(written, prefix)
      end
    end

    # One module must not be able to abort the run. Writing a migration file
    # can raise for reasons entirely outside our control (unwritable
    # `priv/`, a disk full), and on the pre-1.7.230 code a per-module
    # `try/rescue` kept the loop going. Losing that meant a single bad module
    # killed `mix phoenix_kit.update` *after* core had already migrated,
    # skipping every remaining module and the UUID repair pass.
    defp write_module_migration(entry, prefix, index) do
      generate_module_migration(entry, prefix, index)
      [entry]
    rescue
      error ->
        report_module_write_failure(entry, Exception.message(error))
        []
    catch
      :exit, reason ->
        report_module_write_failure(entry, "exited: #{inspect(reason)}")
        []
    end

    defp report_module_write_failure(entry, message) do
      Mix.shell().info(
        "⚠️  #{entry.name}: could not write its migration — #{message}\n" <>
          "    Its tables were NOT migrated; the remaining modules continue."
      )
    end

    # Re-read each module's version from the database instead of assuming the
    # migrator applied what we wrote. `ecto.migrate` runs against the resolved
    # repo's own migration path, which is not necessarily the directory we
    # wrote to, and it exits 0 when it finds nothing to do — so an
    # unconditional "✅ migrated" could report success while no SQL ran at all.
    defp verify_module_migrations([], _prefix), do: :ok

    defp verify_module_migrations(written, prefix) do
      after_versions =
        MigrationModules.list(prefix: prefix)
        |> Map.new(&{&1.module, &1})

      Enum.each(written, fn entry ->
        case Map.get(after_versions, entry.module) do
          %{status: :up_to_date, installed: installed} ->
            Mix.shell().info("✅ #{entry.name} migrated to V#{pad_version(installed)}")

          %{status: :error, error: error} ->
            Mix.shell().error(
              "❌ #{entry.name} could not be re-read after migrating — #{error}. " <>
                "Run mix phoenix_kit.status to confirm its schema version."
            )

          %{installed: installed} ->
            Mix.shell().error(
              "❌ #{entry.name} is still at V#{pad_version(installed)}, expected " <>
                "V#{pad_version(entry.target)}. The generated migration did not run — check " <>
                "that #{inspect(module_migrations_dir())} is the migration path of the repo " <>
                "`mix ecto.migrate` used."
            )

          nil ->
            Mix.shell().error(
              "❌ #{entry.name} could not be re-read after migrating; its version is unknown."
            )
        end
      end)
    end

    # A module whose coordinator raises used to be silently dropped from the
    # run — the host saw nothing at all and assumed its tables were current.
    defp report_unreadable_modules(modules) do
      case MigrationModules.failed(modules) do
        [] ->
          :ok

        failed ->
          Enum.each(failed, fn entry ->
            Mix.shell().info(
              "⚠️  #{entry.name}: could not read schema version — #{entry.error}\n" <>
                "    Its tables were NOT migrated. Check #{inspect(entry.migration_module)}."
            )
          end)
      end
    end

    defp report_modules_up_to_date([]), do: :ok

    defp report_modules_up_to_date(modules) do
      Enum.each(modules, fn
        %{status: :error} ->
          :ok

        entry ->
          Mix.shell().info("✅ #{entry.name}: V#{pad_version(entry.installed)} (up to date)")
      end)
    end

    defp migrate_host_repo do
      Mix.Task.reenable("ecto.migrate")

      case resolve_host_repo() do
        nil -> Mix.Task.run("ecto.migrate")
        repo -> Mix.Task.run("ecto.migrate", ["-r", repo])
      end
    end

    # `index` offsets the timestamp so two modules migrated in the same second
    # can't collide. Ecto derives a migration's version from the filename
    # prefix and rejects duplicates outright, so without this a host running
    # two module upgrades at once got a hard failure.
    defp generate_module_migration(entry, prefix, index) do
      migrations_dir = module_migrations_dir()
      File.mkdir_p!(migrations_dir)

      slug =
        entry.name
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")
        |> String.trim("_")

      mod_name = inspect(entry.migration_module)
      current = entry.installed
      target = entry.target

      suffix = "#{slug}_update_v#{pad_version(current)}_to_v#{pad_version(target)}.exs"

      # Same guard the core migration path has had all along. Without it an
      # interrupted run (file written, `ecto.migrate` failed) leaves the module
      # still pending, and the next run writes a SECOND file with the same
      # migration name — which Ecto rejects outright with "migration name ... is
      # duplicated", blocking every future migration until a human deletes one.
      case Path.wildcard(Path.join(migrations_dir, "*_#{suffix}")) do
        [existing | _] ->
          Mix.shell().info(
            "  Migration already exists: #{existing}\n" <>
              "     Reusing it. To regenerate, delete the file first."
          )

          :ok

        [] ->
          write_migration_file(entry, prefix, index, migrations_dir, suffix, slug, mod_name)
      end
    end

    defp write_migration_file(entry, prefix, index, migrations_dir, suffix, slug, mod_name) do
      current = entry.installed
      target = entry.target
      filename = "#{unique_timestamp(migrations_dir, index)}_#{suffix}"

      app_module =
        Mix.Project.config()[:app]
        |> to_string()
        |> Macro.camelize()

      class_name =
        "#{slug |> Macro.camelize()}UpdateV#{pad_version(current)}ToV#{pad_version(target)}"

      content = """
      defmodule #{app_module}.Repo.Migrations.#{class_name} do
        @moduledoc false
        use Ecto.Migration

        def up do
          #{mod_name}.up(prefix: "#{prefix}", version: #{target})
        end

        def down do
          #{mod_name}.down(prefix: "#{prefix}", version: #{current})
        end
      end
      """

      path = Path.join(migrations_dir, filename)
      File.write!(path, content)
      Mix.shell().info("  Created migration: #{path}")
    end

    # Where the repo `mix ecto.migrate` will run against actually reads its
    # migrations from. Hardcoding `priv/repo/migrations` silently no-ops on a
    # host whose first `:ecto_repos` entry is not `MyApp.Repo` — the file lands
    # somewhere the migrator never scans, so it exits 0 having done nothing.
    defp module_migrations_dir do
      case resolve_host_repo_module() do
        nil -> Path.join(["priv", "repo", "migrations"])
        repo -> Path.join(repo_priv_dir(repo), "migrations")
      end
    end

    # `repo.config()` needs the repo's app env, which may not be loaded under
    # `--no-start`; fall back to the convention Ecto itself defaults to,
    # `priv/<repo module underscored>`.
    defp repo_priv_dir(repo) do
      repo.config()[:priv] || default_repo_priv_dir(repo)
    rescue
      _ -> default_repo_priv_dir(repo)
    catch
      :exit, _ -> default_repo_priv_dir(repo)
    end

    defp default_repo_priv_dir(repo) do
      Path.join("priv", repo |> Module.split() |> List.last() |> Macro.underscore())
    end

    # Base timestamp + index, bumped past anything already on disk. Migration
    # versions only have to be unique and increasing — they are not required to
    # decode back to a real wall-clock time.
    defp unique_timestamp(migrations_dir, index) do
      base = String.to_integer(Common.generate_timestamp()) + index

      highest =
        migrations_dir
        |> File.ls()
        |> case do
          {:ok, files} -> files
          {:error, _} -> []
        end
        |> Enum.map(&(&1 |> String.split("_") |> hd() |> Integer.parse()))
        |> Enum.flat_map(fn
          {version, ""} -> [version]
          _ -> []
        end)
        |> Enum.max(fn -> 0 end)

      to_string(max(base, highest + 1 + index))
    end

    # Show current installation status and available updates
    defp show_status(opts) do
      prefix = PrefixConfig.resolve_prefix(opts)

      # Use the status command to show current status
      args = if prefix == "public", do: [], else: ["--prefix=#{prefix}"]
      Mix.Task.run("phoenix_kit.status", args)

      show_upgrade_value(prefix)
    end

    # What a behind host would GAIN by upgrading.
    #
    # `--status` reported version numbers and "Various improvements and new
    # features", which does not help anyone decide between upgrading now and
    # next sprint. That gap is why several already-shipped features reached us
    # as bug reports: hosts had no way to learn a capability existed short of
    # reading release notes they had no reason to open.
    defp show_upgrade_value(prefix) do
      current = Common.migrated_version(prefix)
      target = Common.current_version()

      if current > 0 and current < target do
        Mix.shell().info("""

        #{IO.ANSI.bright()}What you'd gain by updating (V#{current} → V#{target}):#{IO.ANSI.reset()}
        #{Common.describe_version_changes(current, target)}

        Run `mix phoenix_kit.update` to apply.
        """)
      end
    rescue
      # A diagnostic must never be the reason a status check fails.
      _ -> :ok
    end

    # Advisory only — the host owns assets/vendor/daisyui.js; PhoenixKit's
    # modals rely on daisyUI >= DaisyUI.minimum_version() for correct modal
    # scrollbar-gutter handling (see PhoenixKit.Install.DaisyUI).
    defp warn_if_daisyui_outdated do
      case DaisyUI.check() do
        {:outdated, version} -> Mix.shell().info(DaisyUI.outdated_warning(version))
        _ -> :ok
      end
    end

    # Advance heads-up that the user dashboard (/dashboard) is deprecated. It
    # still works unchanged — advisory only (see PhoenixKit.Install.Deprecations).
    defp warn_user_dashboard_deprecated do
      Mix.shell().info(Deprecations.user_dashboard_warning())
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

          content =
            if existing.daisyui_themes_disabled do
              pattern = ~r/@plugin\s+(["'][^"']*daisyui["'])\s*\{([^}]*themes:\s*)false([^}]*)\}/

              updated =
                String.replace(content, pattern, fn match ->
                  String.replace(match, ~r/(themes:\s*)false/, "\\1all")
                end)

              Mix.shell().info("""

              ✅ Updated daisyUI configuration to enable all themes!
              File: #{css_path}
              Changed: themes: false → themes: all
              """)

              updated
            else
              content
            end

          # Ensure auto-generated CSS sources import is present
          content =
            if String.contains?(content, "_phoenix_kit_sources.css") do
              content
            else
              updated =
                String.replace(
                  content,
                  ~r/(@source\s+["'][^"']*phoenix_kit["'];)/,
                  "\\1\n@import \"./_phoenix_kit_sources.css\";",
                  global: false
                )

              Mix.shell().info("""

              ✅ Added auto-generated CSS sources import!
              File: #{css_path}
              Added: @import "./_phoenix_kit_sources.css";
              """)

              updated
            end

          File.write!(css_path, content)

          # Ensure the generated CSS sources file exists so @import doesn't fail
          generated_path = Path.join(Path.dirname(css_path), "_phoenix_kit_sources.css")

          unless File.exists?(generated_path) do
            File.write!(generated_path, """
            /* Auto-generated by PhoenixKit — do not edit manually.
               Regenerated on each compilation from css_sources/0 callbacks. */
            """)

            Mix.shell().info("✅ Created #{generated_path} (will be updated on next compilation)")
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
    defp run_migration_with_feedback(opts) do
      Mix.shell().info("\n⏳ Running database migration...")

      try do
        # Run ecto.migrate in-process so it shares the current Repo pool
        # (capped to 2 connections with Oban disabled and update_mode set).
        # Using System.cmd("mix", ["ecto.migrate"]) would spawn a separate
        # BEAM that starts its own full app with pool_size=20, bypassing
        # all update_mode optimisations and saturating PgBouncer.
        #
        # Re-enable the task first since Mix tracks which tasks have run
        # and ecto.migrate may have been invoked earlier in the session.
        #
        # Pass -r flag with the host app's repo explicitly, because
        # Mix.Task.run("ecto.migrate") without -r may pick up phoenix_kit
        # (which has ecto_repos: []) and skip the migration entirely.
        Mix.Task.reenable("ecto.migrate")

        case resolve_host_repo() do
          nil ->
            Mix.Task.run("ecto.migrate")

          repo ->
            Mix.Task.run("ecto.migrate", ["-r", repo])
        end

        Mix.shell().info("\n✅ Migration completed successfully!")
        show_update_success_notice(opts)
      rescue
        error ->
          Mix.shell().info("\n⚠️  Migration failed: #{Exception.message(error)}")
          show_manual_migration_instructions()
      end
    end

    # Show success notice after update
    defp show_update_success_notice(opts) do
      Mix.shell().info("""
      🎉 PhoenixKit updated successfully! Visit: #{build_app_path(opts, "/users/register")}
      """)
    end

    defp build_app_path(opts, path) do
      prefix = if is_list(opts), do: opts[:prefix] || "public", else: "public"
      base = if prefix == "public", do: "", else: "/#{prefix}"
      "#{base}#{path}"
    end

    # Resolve the host application's Ecto repo module name as a string.
    # Returns nil if no repo is found (falls back to default ecto.migrate behaviour).
    defp resolve_host_repo do
      case resolve_host_repo_module() do
        nil -> nil
        repo -> inspect(repo)
      end
    end

    # The same repo as an atom — `module_migrations_dir/0` needs the module
    # itself to ask it where its migrations live.
    defp resolve_host_repo_module do
      app_name = Mix.Project.config()[:app]

      case Application.get_env(app_name, :ecto_repos, []) do
        [repo | _] -> repo
        _ -> nil
      end
    rescue
      ArgumentError -> nil
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

    # Show migration status summary (current vs target version)
    defp show_migration_status(prefix) do
      opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}
      target = MigrationsPostgres.current_version()

      db_version =
        try do
          MigrationsPostgres.migrated_version_runtime(opts)
        rescue
          _ -> 0
        end

      phoenix_kit_version =
        case :application.get_key(:phoenix_kit, :vsn) do
          {:ok, vsn} when is_list(vsn) -> List.to_string(vsn)
          {:ok, vsn} -> to_string(vsn)
          :undefined -> "unknown"
        end

      a = IO.ANSI

      # Modules that own their schema report alongside core, so the closing
      # summary answers "what version is everything at?" in one place rather
      # than only covering core and leaving module versions to scrollback.
      module_lines = module_summary_lines(prefix)
      core_branch = if module_lines == "", do: "└──", else: "├──"

      Mix.shell().info("""

      #{a.bright()}PhoenixKit v#{phoenix_kit_version}#{a.reset()}
      #{a.bright()}├── Migration#{a.reset()}: #{format_version(db_version, target)}
      #{a.bright()}#{core_branch} Target#{a.reset()}:    V#{pad_version(target)}#{module_lines}
      """)
    end

    defp module_summary_lines(prefix) do
      modules = MigrationModules.list(prefix: prefix)
      a = IO.ANSI
      last_index = length(modules) - 1

      modules
      |> Enum.with_index()
      |> Enum.map_join("", fn {entry, index} ->
        branch = if index == last_index, do: "└──", else: "├──"
        "\n#{a.bright()}#{branch} #{entry.name}#{a.reset()}: #{format_module_version(entry)}"
      end)
    rescue
      _ -> ""
    catch
      # A dead connection pool exits rather than raising, and losing the
      # closing summary of an otherwise-successful update run over a cosmetic
      # lookup would be a poor trade.
      :exit, _ -> ""
    end

    defp format_module_version(%{status: :error} = entry) do
      "#{IO.ANSI.red()}unreadable ❌#{IO.ANSI.reset()} (#{entry.error})"
    end

    defp format_module_version(%{status: :up_to_date} = entry) do
      "#{IO.ANSI.green()}V#{pad_version(entry.installed)} ✅#{IO.ANSI.reset()}"
    end

    defp format_module_version(entry) do
      "#{IO.ANSI.yellow()}V#{pad_version(entry.installed)} (needs V#{pad_version(entry.target)})#{IO.ANSI.reset()}"
    end

    defp format_version(db, target) when db >= target,
      do: "#{IO.ANSI.green()}V#{pad_version(db)} ✅#{IO.ANSI.reset()}"

    defp format_version(0, _target),
      do: "#{IO.ANSI.red()}Not installed#{IO.ANSI.reset()}"

    defp format_version(db, target),
      do:
        "#{IO.ANSI.yellow()}V#{pad_version(db)} → V#{pad_version(target)} (needs migration)#{IO.ANSI.reset()}"

    defp pad_version(v) when v < 10, do: "0#{v}"
    defp pad_version(v), do: to_string(v)

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

      # Convert snake_case app_name to PascalCase module name
      app_module = Macro.camelize(to_string(app_name))

      # Find line numbers for each supervisor
      repo_line = find_supervisor_line(lines, ~r/#{app_module}\.Repo[,\s]/)
      phoenix_kit_line = find_supervisor_line(lines, ~r/PhoenixKit\.Supervisor[,\s]/)
      endpoint_line = find_supervisor_line(lines, ~r/#{app_module}Web\.Endpoint[,\s]/)

      oban_line =
        find_supervisor_line(lines, ~r/\{Oban,|Application\.get_env\(:#{app_name}, Oban\)/)

      validate_supervisor_positions(repo_line, phoenix_kit_line, oban_line, endpoint_line)
    end

    # Validate supervisor positions and return check result
    # Correct order: Repo → PhoenixKit.Supervisor → Endpoint → Oban
    # PhoenixKit MUST be before Endpoint so Presence is ready for LiveViews
    defp validate_supervisor_positions(nil, nil, nil, _), do: :cannot_determine
    defp validate_supervisor_positions(nil, _, _, _), do: :cannot_determine
    defp validate_supervisor_positions(repo, nil, nil, _) when is_integer(repo), do: :correct

    defp validate_supervisor_positions(repo, pk, nil, nil)
         when is_integer(repo) and is_integer(pk) do
      if repo < pk, do: :correct, else: {:needs_fix, "PhoenixKit.Supervisor before Repo"}
    end

    defp validate_supervisor_positions(repo, pk, nil, endpoint)
         when is_integer(repo) and is_integer(pk) and is_integer(endpoint) do
      cond do
        pk < repo -> {:needs_fix, "PhoenixKit.Supervisor before Repo"}
        pk > endpoint -> {:needs_fix, "PhoenixKit.Supervisor after Endpoint"}
        true -> :correct
      end
    end

    defp validate_supervisor_positions(repo, pk, oban, nil)
         when is_integer(repo) and is_integer(pk) and is_integer(oban) do
      check_supervisor_order_without_endpoint(repo, pk, oban)
    end

    defp validate_supervisor_positions(repo, pk, oban, endpoint)
         when is_integer(repo) and is_integer(pk) and is_integer(oban) and is_integer(endpoint) do
      check_full_supervisor_order(repo, pk, oban, endpoint)
    end

    defp validate_supervisor_positions(_, _, _, _), do: :cannot_determine

    # Check ordering without endpoint
    defp check_supervisor_order_without_endpoint(repo, pk, oban) do
      cond do
        pk < repo and oban < repo -> {:needs_fix, "both PhoenixKit and Oban before Repo"}
        pk < repo -> {:needs_fix, "PhoenixKit.Supervisor before Repo"}
        oban < repo -> {:needs_fix, "Oban before Repo"}
        oban < pk -> {:needs_fix, "Oban before PhoenixKit.Supervisor"}
        true -> :correct
      end
    end

    # Check full ordering with endpoint
    # Correct order: Repo → PhoenixKit.Supervisor → Endpoint → Oban
    defp check_full_supervisor_order(repo, pk, oban, endpoint) do
      cond do
        pk < repo -> {:needs_fix, "PhoenixKit.Supervisor before Repo"}
        oban < repo -> {:needs_fix, "Oban before Repo"}
        pk > endpoint -> {:needs_fix, "PhoenixKit.Supervisor after Endpoint"}
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

      # Convert snake_case app_name to PascalCase module name
      app_module = Macro.camelize(to_string(app_name))

      # Extract supervisor lines
      {repo_line, repo_index} = extract_supervisor(lines, ~r/#{app_module}\.Repo[,\s]/)
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
    # Correct order: Repo → PhoenixKit → Endpoint → Oban
    defp build_ordered_supervisor_list(repo_line, pk_line, oban_line, filtered_children) do
      # Add Repo first (if exists)
      ordered = if repo_line, do: [repo_line], else: []

      # Split remaining children at Endpoint
      {before_endpoint, from_endpoint} = split_at_endpoint(filtered_children)

      # Add children before Endpoint
      ordered = ordered ++ before_endpoint

      # Add PhoenixKit BEFORE Endpoint (so Presence is ready for LiveViews)
      ordered = if pk_line, do: ordered ++ [pk_line], else: ordered

      # Add Endpoint
      ordered = ordered ++ from_endpoint

      # Add Oban AFTER Endpoint (typically last in the list)
      if oban_line, do: ordered ++ [oban_line], else: ordered
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
           2. PhoenixKit.Supervisor   (Presence must be ready before Endpoint)
           3. YourAppWeb.Endpoint     (starts accepting connections)
           4. {Oban, ...}            (uses Repo for job persistence)

         PhoenixKit.Supervisor must start BEFORE Endpoint so that Presence
         ETS tables are ready when LiveViews mount for collaborative editing.

         IMPORTANT: Restart your server for changes to take effect.
      """

      Igniter.add_notice(igniter, String.trim(notice))
    end

    defp validate_and_add_oban_config(igniter, prefix) do
      config_exists = ObanConfig.oban_config_exists?(igniter)
      supervisor_exists = ObanConfig.oban_supervisor_exists?(igniter)

      # Always call add_oban_configuration - it handles both:
      # - Adding new configuration if missing
      # - Updating existing configuration with new queues (posts, sitemap, sqs_polling)
      igniter =
        igniter
        |> ObanConfig.add_oban_configuration(prefix)
        |> maybe_add_oban_config_notice(config_exists)

      # Check and add supervisor separately
      if supervisor_exists do
        igniter
      else
        igniter
        |> ObanConfig.add_oban_supervisor()
        |> add_oban_supervisor_added_notice()
      end
    end

    # Add appropriate notice based on whether config existed
    defp maybe_add_oban_config_notice(igniter, config_existed) do
      if config_existed do
        # Config existed, might have been updated with new queues
        add_oban_config_updated_notice(igniter)
      else
        # Config was newly added
        add_oban_config_added_notice(igniter)
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

    # Add notice about Oban configuration being updated with new queues
    defp add_oban_config_updated_notice(igniter) do
      notice = """
      ⚙️  Oban configuration verified/updated in config.exs
         New queues may have been added: posts, sitemap, sqs_polling
         IMPORTANT: If your server is running, restart it to apply changes.
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

    # Reduce Ecto repo pool sizes and disable Oban queue workers before app.start
    # so the update task uses minimal DB connections and doesn't starve the
    # production app via PgBouncer. Must be called AFTER app.config so that
    # runtime.exs has already applied its settings — then we override here.
    defp cap_repo_pool_size_for_update(pool_size) do
      app_name = Mix.Project.config()[:app]

      repos =
        Application.get_env(app_name, :ecto_repos, []) ++
          Application.get_env(:phoenix_kit, :ecto_repos, [])

      Enum.each(repos, fn repo ->
        current = Application.get_env(app_name, repo, [])
        updated = Keyword.put(current, :pool_size, pool_size)
        Application.put_env(app_name, repo, updated)
        Mix.shell().info("PhoenixKit: capped #{inspect(repo)} pool_size to #{pool_size}")
      end)

      # Disable Oban queue workers so they don't consume all pool connections
      # before the settings cache warms and Dashboard.Registry initialises.
      # With pool_size=2, 7+ Oban producers would otherwise starve everything else.
      disable_oban_queues_for_update(app_name)
    rescue
      e ->
        Mix.shell().info("PhoenixKit: could not cap repo pool_size: #{inspect(e)}")
    end

    defp disable_oban_queues_for_update(app_name) do
      case Application.get_env(app_name, Oban) do
        nil ->
          :ok

        oban_config ->
          updated = oban_config |> Keyword.put(:queues, []) |> Keyword.put(:plugins, [])
          Application.put_env(app_name, Oban, updated)
          Mix.shell().info("PhoenixKit: disabled Oban queues/plugins for update task")
      end
    rescue
      _ -> :ok
    end
  end
else
  # Igniter is optional (see mix.exs), so this task cannot be defined here.
  # A guard with no `else` would make it vanish and Mix would report only
  # "could not be found" — naming neither PhoenixKit nor the missing dep.
  defmodule Mix.Tasks.PhoenixKit.Update do
    @moduledoc """
    Placeholder for `mix phoenix_kit.update`, which needs the optional :igniter
    dependency. Running it explains how to add igniter; see
    `PhoenixKit.Install.MissingIgniter` for why the dep is optional.
    """

    use PhoenixKit.Install.MissingIgniter, task: "phoenix_kit.update"
  end
end
