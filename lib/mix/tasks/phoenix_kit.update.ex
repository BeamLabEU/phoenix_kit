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
    - Steps up Oban's schema when the installed Oban library expects a newer
      one (see "Oban schema" below)

    ## Oban schema

    Oban's tables are versioned by the Oban library, not by PhoenixKit's chain:
    core installs them once, at whatever version the Oban of that day shipped,
    and a later Oban may need a newer schema (Oban 2.24's version 14 — without
    it every unique insert fails, cron included). The update compares the
    version on `oban_jobs` with `Oban.Migration.current_version/1` — at
    PhoenixKit's prefix, and at your Oban config's prefix (on the repo that
    config names) when that differs — and when the schema is behind writes
    `<timestamp>_phoenix_kit_update_oban_vNN_to_vMM.exs`, applied with the
    rest of the update's migrations. This happens whether or not core itself
    had anything to migrate. No `oban_jobs` table (a fresh install), a schema
    matching the library, or a non-Postgres repo writes nothing; a schema
    newer than the library is only reported. When your Oban config runs on a
    different repo than the one this task migrates (its `repo:` is not the
    first of `:ecto_repos`), no file is written for it — the task prints the
    migration to add to that repo instead.

    ## Usage

        $ mix phoenix_kit.update
        $ mix phoenix_kit.update --prefix=myapp
        $ mix phoenix_kit.update --status
        $ mix phoenix_kit.update --skip-assets
        $ mix phoenix_kit.update -y
        $ mix phoenix_kit.update --no-start
        $ mix phoenix_kit.update --migrate-only
        $ mix phoenix_kit.update --dry-run

    ## When the application will not start (`--no-start`)

    The full update runs `Mix.Task.run("app.start")`, and a column-adding
    release is exactly when that fails. The newly compiled schema module
    selects a column the database has not got, so any host child that queries
    at init — a registry warming a cache, a GenServer loading settings — takes
    the whole boot down with `ERROR 42703 (undefined_column)`, and the updater
    that would add the column cannot run. `update_mode: true` stands
    PhoenixKit's own supervisor down; it has no say over the host's children.

    `--no-start` runs the two steps that need no application: it generates the
    chain step-up migration (`mix phoenix_kit.gen.migration` reads the current
    version off the migration FILENAMES, never the database) and applies it
    with `mix ecto.migrate`, which starts the repo alone. Before generating, it
    starts the repo the same way to read the installed version, and refuses a
    database below this release's floor like the full update does. Configuration repair,
    asset rebuild and module migrations are skipped and reported — every one of
    them needs the app. Run the full `mix phoenix_kit.update` once the host
    boots again.

    ## Database only (`--migrate-only`)

    The default update boots the whole host application, which starts the
    host's own children too: pollers, bots, a Telegram `getUpdates` loop that
    then conflicts with the copy already running in production.
    `--migrate-only` starts only the repo (`Ecto.Migrator.with_repo/3`): it
    refuses a database below the floor, writes the PhoenixKit step-up
    migration from the version the database reports, writes an Oban schema
    step-up when one is due, runs `mix ecto.migrate`, then writes and runs the
    installed modules' migrations and checks their versions. No project file
    other than those migrations is touched, and nothing is prompted. The
    default (no flag) is unchanged, and `--no-start` keeps its meaning. A repo
    configured with `start_apps_before_migration:` gets those applications
    started first, as `mix ecto.migrate` does: leave the host app out of that
    list for `--migrate-only` to keep it stopped.

    ## Options

      * `--prefix` - Database schema prefix. When omitted, resolves from
        `config :phoenix_kit, :prefix`, then defaults to "public". Passing it
        explicitly also persists the config entry. On prefixed installs the
        task warns when your existing Oban config lacks the `prefix:` key.
      * `--status` - Show current installation status and available updates
      * `--force` - Force update even if already up to date
      * `--skip-assets` - Skip automatic asset rebuild check
      * `--yes` / `-y` - Skip confirmation prompts and run migrations automatically
      * `--no-start` - Migrate the database without starting the host
        application. See "When the application will not start" above.
      * `--migrate-only` - Run every database step — PhoenixKit's step-up,
        Oban's schema, the installed modules' migrations (their files are
        written too) — with only the repo started. See "Database only" below.
      * `--install-root-theme` - Add the theme bootstrap to the host's ROOT
        layout (opt-in; see "Theme bootstrap" below).
      * `--remove-root-theme` - Remove a kit-marked theme bootstrap from the
        root layout and record `theme_bootstrap` as declined.
      * `--skip-patch ID` - Decline an optional project edit and record it
        in `.phoenix_kit.exs` (repeatable). See "The patch ledger" below.
      * `--repair-patch ID` - Apply an optional edit again although the
        ledger says it was removed or declined (repeatable).
      * `--dry-run` - Show what would change and write nothing: Igniter
        prints the diff of every project file it would edit, and the steps
        that write outside Igniter (app.css, the vendored JS, the asset
        rebuild, migrations and module migration files) are listed and
        skipped. The application still starts, to read the database.

    A database below this release's migration floor is refused before
    anything is written (no project edit, no migration file); the message
    names the bridge release to install first. The one exception is a run
    whose config.exs lacks the Ueberauth, Hammer or Oban configuration: that
    configuration is added first, and nothing else, because the version can
    only be read once the app starts with it.

    ## Theme bootstrap

    The update no longer puts `PhoenixKitWeb.Components.ThemeBootstrap` in
    your root layout: the kit's admin pages and auth pages stamp the saved
    theme themselves (`PhoenixKitWeb.Components.LayoutWrapper`), and a root
    copy stamped `data-theme` on your public site as well. A snippet an
    earlier update injected stays where it is (nothing is removed
    automatically); `--remove-root-theme` removes it when it carries the
    kit's marker comment. `--install-root-theme` adds it, for a site that
    wants its public pages to follow the kit's saved theme.

    ## The patch ledger (`.phoenix_kit.exs`)

    The optional edits this task makes to your project have stable IDs
    (`module_js_seed`, `oban_queues` / `oban_queues:<queue>`,
    `daisyui_themes`, `css_sources_import`, `theme_bootstrap`), and the
    task records in `.phoenix_kit.exs` which it applied and which you
    declined. Commit the file. An edit recorded as applied that you later
    remove is treated as declined — not re-added — and listed at the end of
    the run with the `--repair-patch ID` hint. `--skip-patch ID` and an
    inline marker (`# phoenix_kit:skip ID`, `<%!-- phoenix_kit:skip ID --%>`)
    decline one up front. The first run without a ledger behaves exactly as
    before and records what is present. Required configuration and
    security-relevant edits (`body_guard`) are never declinable. Oban
    queues are added only for packages that are installed, and an existing
    queue is never removed. Details: `PhoenixKit.Install.PatchLedger`.

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

    ## Upgrading across releases

    Stop the application first (or run this on a separate checkout): the task
    compiles and boots the app, and recompiling a `_build/prod` that a running
    server loads from restarts it onto half-upgraded code.

    The `..._phoenix_kit_update_vNN_to_vMM.exs` file this writes calls
    `PhoenixKit.Migrations.up_to!(MM, ...)`: a no-op on a database already at
    MM or later, a `BelowFloorError` naming the bridge release on one below
    this release's floor, and a `TargetAheadError` under a pin whose chain
    stops before MM. It still needs a release that accepts NN: apply it on
    every environment before moving the pin on. (Files written by earlier
    releases call `PhoenixKit.Migrations.up(version: MM)` and are left as they
    are; they raise the same two errors.) From 1.7.x the route is `1.7.236`
    (until V135), then
    `2.65.0` (until V225), then 3.x — see the "Upgrading to PhoenixKit 3.0"
    guide (`guides/upgrading-to-3.0.md`), which also lists the settings keys
    and functions renamed on the way.

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
      AdminLabelConfig,
      ApplicationSupervisor,
      AssetRebuild,
      BasicConfiguration,
      BootHook,
      ChildOrder,
      Common,
      ConfigVerify,
      CssIntegration,
      DaisyUI,
      DbConnectionCheck,
      Deprecations,
      EndpointIntegration,
      IgniterHelpers,
      JsIntegration,
      MailerConfig,
      MigrationStrategy,
      MissingIgniter,
      ObanConfig,
      PatchLedger,
      PrefixConfig,
      RateLimiterConfig,
      TestFixturesIntegration
    }

    alias PhoenixKit.Migrations.Modules, as: MigrationModules
    alias PhoenixKit.Migrations.Postgres, as: MigrationsPostgres
    alias PhoenixKit.ObanSchema
    alias PhoenixKit.Users.Roles
    # NOTE: PhoenixKit.Utils.Routes depends on application config that isn't
    # always available during mix task execution: use only `path/2` with
    # `locale: :none` (reads the `url_prefix` config, nothing else), and
    # only through `app_path/1`, which falls back when that fails.
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
          yes: :boolean,
          no_start: :boolean,
          migrate_only: :boolean,
          dry_run: :boolean,
          skip_patch: :keep,
          repair_patch: :keep,
          install_root_theme: :boolean,
          remove_root_theme: :boolean
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

      cond do
        opts[:status] ->
          show_status(opts)
          igniter

        # The first pass (config.exs lacks Ueberauth/Hammer/Oban) runs before
        # the app can start, so nothing can know yet whether the database is
        # below this release's floor. It adds that configuration and nothing
        # else: the layout, app.js, mix.exs, application.ex and endpoint edits
        # wait for the second pass, which refuses a below-floor database
        # before making them.
        Process.get(:phoenix_kit_config_status, :ok) == :missing ->
          igniter
          |> add_missing_configuration(opts)
          |> IgniterHelpers.tidy_messages()

        true ->
          igniter
          |> BasicConfiguration.add_basic_config()
          |> AdminLabelConfig.add_admin_label_options()
          |> ApplicationSupervisor.add_supervisor()
          |> BootHook.add_boot_hook()
          |> MailerConfig.repair_runtime_import_order()
          |> EndpointIntegration.add_pdfjs_static_mount()
          |> EndpointIntegration.add_body_guard()
          |> perform_igniter_update(opts)
          |> IgniterHelpers.tidy_messages()
      end
    end

    # The first pass: only the config.exs entries `check_required_configuration/0`
    # found missing.
    defp add_missing_configuration(igniter, opts) do
      prefix = PrefixConfig.resolve_prefix(opts)

      igniter
      |> PrefixConfig.add_prefix_configuration(opts[:prefix])
      |> validate_and_fix_ueberauth_config()
      |> validate_and_add_hammer_config()
      |> ObanConfig.add_oban_configuration(prefix)
    end

    # Override run/1 to handle post-igniter interactive migration and asset rebuild
    def run(argv) do
      # The compile-time `Code.ensure_loaded?(Igniter.Mix.Task)` guard around
      # this module can outlive the dependency it tested (see
      # `PhoenixKit.Install.MissingIgniter`), so ask again before any generated
      # Igniter code runs.
      MissingIgniter.ensure_available!("phoenix_kit.update", argv)

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
              yes: :boolean,
              no_start: :boolean,
              migrate_only: :boolean,
              # Igniter's own global switch (it shows the diff and writes
              # nothing); declared here too so the post-Igniter steps, which
              # write outside Igniter, can honour it.
              dry_run: :boolean,
              skip_patch: :keep,
              repair_patch: :keep,
              install_root_theme: :boolean,
              remove_root_theme: :boolean
            ],
            aliases: [
              p: :prefix,
              s: :status,
              f: :force,
              y: :yes
            ]
          )

        # A bad patch ID stops the run before anything starts.
        Enum.each([:skip_patch, :repair_patch], fn key ->
          opts |> elem(0) |> Keyword.get_values(key) |> PatchLedger.validate_ids!()
        end)

        # The Igniter pass: the first pass runs it inside the ledger window, the
        # second hands it to `full_update/2` (which decides whether it runs at all).
        igniter_pass = fn -> super(argv) end

        # If --status flag, handle directly and exit
        cond do
          Keyword.get(elem(opts, 0), :status) ->
            show_status(elem(opts, 0))
            :ok

          Keyword.get(elem(opts, 0), :migrate_only) ->
            migrate_only_update(elem(opts, 0))

          Keyword.get(elem(opts, 0), :no_start) ->
            schema_only_update(elem(opts, 0))

          true ->
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
                result = first_pass_with_ledger(elem(opts, 0), igniter_pass)

                Process.delete(:phoenix_kit_config_status)

                after_first_pass(elem(opts, 0), result, argv)

              {:ok, _} ->
                # Second pass (automatic or manual): Configuration exists, safe to start app
                # Store config status in Process dictionary for igniter/1 to read
                Process.put(:phoenix_kit_config_status, :ok)

                run_second_pass(elem(opts, 0), igniter_pass)

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

    @doc false
    # The second pass, in the order that keeps a refused or previewed run from
    # touching the host:
    #
    #   1. start the app (capped pool, `update_mode`) and check the database
    #   2. refuse a database below this release's floor — BEFORE the Igniter
    #      pass, which edits config.exs/application.ex/the root layout, and
    #      before the post-Igniter steps, which write CSS, vendored JS and
    #      migration files. A refused run used to leave all of that behind,
    #      and a second run after the bridge wrote a duplicate set.
    #   3. the Igniter pass (`run/1`'s `super/1`; with `--dry-run` Igniter
    #      shows its diff and writes nothing)
    #   4. the post-Igniter steps — skipped under `--dry-run`, which lists them
    #
    # `steps` replaces any of the four (tests observe what runs).
    def full_update(opts, steps \\ %{}) do
      steps = Map.merge(default_full_update_steps(), steps)

      steps.start_app.()
      refuse_below_floor!(opts, steps.installation_status)
      # The patch ledger (`.phoenix_kit.exs`): read after the refusal, so a
      # refused run neither reads nor writes it.
      PatchLedger.begin(opts, steps.root)

      try do
        result = steps.igniter.()

        if Keyword.get(opts, :dry_run, false) do
          report_dry_run(opts)
        else
          finish_with_ledger(opts, steps.finish)
        end

        result
      after
        PatchLedger.abandon()
      end
    end

    # The ledger is written even when the migration step raises (a declined
    # migration ends in Mix.raise/1): the project edits it records were made.
    defp finish_with_ledger(opts, finish) do
      finish.(opts)
    after
      PatchLedger.flush()

      case PatchLedger.summary() do
        "" -> :ok
        summary -> Mix.shell().info(summary)
      end
    end

    defp default_full_update_steps do
      %{
        start_app: &start_app_for_update/0,
        installation_status: &Common.check_installation_status/1,
        igniter: fn -> raise ArgumentError, "the Igniter pass is run/1's super/1" end,
        finish: &finish_update/1,
        root: File.cwd!()
      }
    end

    defp start_app_for_update do
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
    end

    # Only a readable version below the floor refuses here. Every other status
    # (not installed, unknown, unreachable) keeps its own message from the
    # Igniter pass's `handle_installation_status/5`, which writes no migration
    # for any of them.
    defp refuse_below_floor!(opts, installation_status) do
      prefix = PrefixConfig.resolve_prefix(opts)
      floor_version = MigrationsPostgres.minimum_version()

      case installation_status.(prefix) do
        {:current_version, current} when current > 0 and current < floor_version ->
          # The first pass (missing Ueberauth/Hammer/Oban config) runs before
          # the app can start, so it cannot know the version yet.
          changed =
            if Process.get(:phoenix_kit_retry_pass, false),
              do: unfinished_after_first_pass(),
              else: "Nothing was changed."

          Mix.raise(below_floor_message(current, floor_version) <> "\n" <> changed)

        _ ->
          :ok
      end
    end

    # What `--dry-run` skipped after Igniter's preview: everything below writes
    # outside Igniter, so its diff cannot show it.
    defp report_dry_run(opts) do
      assets =
        if Keyword.get(opts, :skip_assets, false),
          do: "",
          else: "\n  • the asset rebuild (mix assets.build or its fallbacks)"

      Mix.shell().info("""

      🔍 Dry run (--dry-run): nothing was written. The diff above is every
      change to your project files; these steps were skipped too:
        • the daisyUI theme switch in app.css and the vendored
          phoenix_kit.js bundle in priv/static/assets/vendor/#{assets}
        • the Oban schema check, the migration run and the module
          migration files#{dry_run_module_lines(opts)}

      Run the same command without --dry-run to apply.
      """)
    end

    # Read-only: which module migration files the real run would write.
    defp dry_run_module_lines(opts) do
      prefix = PrefixConfig.resolve_prefix(opts)

      case [prefix: prefix] |> MigrationModules.list() |> MigrationModules.pending() do
        [] ->
          ""

        pending ->
          Enum.map_join(pending, "", fn entry ->
            "\n      #{entry.name}: V#{pad_version(entry.installed)} → V#{pad_version(entry.target)}"
          end)
      end
    rescue
      _ -> ""
    catch
      :exit, _ -> ""
    end

    defp run_second_pass(opts, igniter_pass) do
      full_update(opts, %{igniter: igniter_pass})
    after
      # Clean retry flag
      Process.delete(:phoenix_kit_retry_pass)
    end

    @doc false
    # The first pass backfills an existing Oban block's queues too, so it reads the
    # patch ledger (`.phoenix_kit.exs`) and `--skip-patch` / `--repair-patch` like the
    # full update: a queue the host declined or removed is not written back. It records
    # nothing; the second pass reads the file again and records what is present then.
    def first_pass_with_ledger(opts, pass, root \\ File.cwd!()) do
      PatchLedger.begin(opts, root)

      try do
        pass.()
      after
        PatchLedger.abandon()
      end
    end

    # After the first pass added the missing configuration: restart into the
    # second pass, or — under --dry-run, where nothing was written and the
    # second pass would find the same configuration missing — stop here.
    defp after_first_pass(opts, result, argv) do
      if Keyword.get(opts, :dry_run, false) do
        Mix.shell().info("""

        🔍 Dry run (--dry-run): the configuration above would be added
        first; nothing was written. The rest of the update runs only
        once that configuration exists — run without --dry-run to add
        it, then preview the remaining steps with --dry-run again.
        """)

        result
      else
        # Automatic restart instead of manual prompt
        Mix.shell().info("""

        ✅ Configuration added (step 1 of 2).
        🔄 Automatically restarting for step 2 — the update is not finished
           until it completes.
        """)

        Process.put(:phoenix_kit_retry_pass, true)

        # Recursive call with same arguments
        run(argv)
      end
    end

    # Display message about missing configuration. The second pass follows in
    # the same invocation (`after_first_pass/3` re-enters `run/1`), but it can
    # still stop (a below-floor database, a declined prompt, an interrupt):
    # the first pass alone leaves e.g. Oban configured with no Oban child in
    # the supervisor, so the message says the update is in two parts.
    defp show_missing_config_message(argv) do
      Mix.shell().info("""

      ⚠️  Required configuration is missing from config/config.exs

      PhoenixKit requires configuration for:
      - Ueberauth (OAuth authentication)
      - Hammer (rate limiting)
      - Oban (background jobs for file processing)

      Step 1 of 2: this configuration will be added now. Step 2 (the
      supervisor, layout, endpoint and migration changes) then runs
      automatically. If the update stops before step 2 finishes, it is NOT
      complete: run it again with
        mix phoenix_kit.update #{Enum.join(argv, " ")}
      """)
    end

    # What a refusal in the second pass says when the first pass wrote the
    # missing configuration: the host is half-updated (Oban configured, but no
    # Oban child in its supervisor yet) until a later run completes.
    defp unfinished_after_first_pass do
      """
      Only the missing configuration added above was written. The update is
      NOT finished: the supervisor (Oban child), layout, endpoint and migration
      changes were not applied, so Oban jobs will not run on this host yet.
      Run `mix phoenix_kit.update` again once the database is at the floor.\
      """
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
      igniter = root_theme(igniter, opts)
      igniter = TestFixturesIntegration.ensure_conn_case_import(igniter)

      # Second pass only (the first stops at `add_missing_configuration/2`):
      # configuration exists and the app is started, so the version is readable.
      handle_installation_status(
        Common.check_installation_status(prefix),
        igniter,
        prefix,
        force,
        opts
      )
    end

    @doc false
    # The theme bootstrap in the host's ROOT layout is opt-in: the kit's admin
    # and auth pages stamp the theme themselves, and a root copy re-themes the
    # host's public site. A snippet an earlier update injected is left in
    # place; `--remove-root-theme` takes a kit-marked one out.
    def root_theme(igniter, opts) do
      cond do
        opts[:remove_root_theme] ->
          JsIntegration.remove_theme_bootstrap(igniter)

        opts[:install_root_theme] == true or PatchLedger.repair?("theme_bootstrap") ->
          JsIntegration.ensure_theme_bootstrap(igniter)

        true ->
          igniter
      end
    end

    # Split out of `perform_igniter_update/2` to keep its cyclomatic
    # complexity down (credo's Refactor.CyclomaticComplexity) — this branch
    # was the below-floor addition's cost.
    defp handle_installation_status({:not_installed}, igniter, prefix, _force, _opts) do
      add_not_installed_notice(igniter, prefix)
    end

    # Installed, but the version comment is gone or unparseable. Deliberately
    # NOT routed to the below-floor branch: that reports "V1" and tells the
    # operator to install the 1.7.x bridge, and the migrator refuses this exact
    # state because replaying the pre-squash chain over a possibly CURRENT
    # database backfills still-NULL tracked columns with invented uuids and then
    # deletes the rows for matching no user. Two halves of one release must not
    # give opposite instructions; this one matches the migrator's.
    defp handle_installation_status({:unknown_version}, igniter, prefix, _force, _opts) do
      Igniter.add_warning(igniter, """

      ❌ #{prefix}.phoenix_kit exists but carries no readable version comment.

      The comment is the only record of which migrations this database has, so
      neither an update nor a fresh install can be generated safely — a guess
      here can replay migrations over live data.

      Establish the real state and restamp it by hand:

          mix phoenix_kit.doctor       # reports schema-vs-comment discrepancies
          COMMENT ON TABLE #{prefix}.phoenix_kit IS '<version>';

      Then run mix phoenix_kit.update again.
      """)
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
      floor_version = MigrationsPostgres.minimum_version()

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
      {migration_name, migration_content} =
        update_migration(prefix, current_version, target_version, force)

      # Check for existing migration with same version range to prevent duplicates
      existing_pattern = update_migration_suffix(current_version, target_version, force)

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

    @doc false
    # The core step-up migration: `{file name, content}`. Pure.
    #
    # `@disable_ddl_transaction` is critical: without it, Ecto wraps the entire
    # migration in a single transaction. ALTER TABLE requires AccessExclusiveLock,
    # which blocks (and is blocked by) every other connection on the table. A
    # long-running transaction holding such locks on dozens of tables deadlocks
    # with the production app's normal queries — even on an empty database. With
    # DDL transaction disabled each statement auto-commits. PhoenixKit migrations
    # are idempotent (IF NOT EXISTS / IF EXISTS guards), so partial runs are safe.
    #
    # An update implies an existing installation, so the schema exists — never
    # ask the chain to create it (CREATE SCHEMA fails for low-privilege roles
    # even with IF NOT EXISTS).
    #
    # The file calls the floor-aware `up_to!/2`: a no-op on a database already
    # at the target, a BelowFloorError naming the bridge below the floor.
    def update_migration(prefix, current_version, target_version, force) do
      action = if force, do: "force_update", else: "update"
      current_padded = Common.pad_version(current_version)
      target_padded = Common.pad_version(target_version)

      name =
        "#{Common.generate_timestamp()}_" <>
          update_migration_suffix(current_version, target_version, force)

      module_name = "PhoenixKit#{String.capitalize(action)}V#{current_padded}ToV#{target_padded}"

      content = """
      defmodule Ecto.Migrations.#{module_name} do
        @moduledoc false
        use Ecto.Migration

        @disable_ddl_transaction true

        def up do
          # PhoenixKit Update Migration: V#{current_padded} -> V#{target_padded}
          # A no-op on a database already at V#{target_padded} or later; below the
          # release floor it raises naming the bridge release (up_to!/2).
          PhoenixKit.Migrations.up_to!(#{target_version},
            prefix: "#{prefix}",
            create_schema: false
          )
        end

        def down do
          # Rollback PhoenixKit to V#{current_padded}
          PhoenixKit.Migrations.down([
            prefix: "#{prefix}",
            version: #{current_version}
          ])
        end
      end
      """

      {name, content}
    end

    @doc false
    def update_migration_suffix(current_version, target_version, force) do
      action = if force, do: "force_update", else: "update"

      "phoenix_kit_#{action}_v#{Common.pad_version(current_version)}" <>
        "_to_v#{Common.pad_version(target_version)}.exs"
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

    # Spec §5.2/§5.3 generation-time below-floor refusal. LIVE since the
    # squash raised `MigrationsPostgres.initial_version/0` to 135 — any
    # install still at V01..V134 lands here. (Dormant while that floor was 1:
    # every installed DB was already at or above it.) Mirrors
    # `PhoenixKit.Migrations.BelowFloorError`'s message
    # (this path never touches the DB again, so it can't raise that
    # exception directly — it names the same bridge instructions instead).
    #
    # Normally unreachable now: `full_update/2` refuses a below-floor database
    # before the Igniter pass starts. Kept for a caller that runs `igniter/1`
    # on its own, as an issue so Igniter writes none of the pass's changes.
    defp add_below_floor_notice(igniter, current_version, floor_version) do
      Igniter.add_issue(igniter, below_floor_message(current_version, floor_version))
    end

    @doc false
    def below_floor_message(current_version, floor_version) do
      current_padded = Common.pad_version(current_version)
      floor_padded = Common.pad_version(floor_version)

      """
      ❌ PhoenixKit database is at V#{current_padded}, below this release's floor
      (V#{floor_padded}) — this release's chain no longer carries the migration
      modules below the floor, so it cannot generate a migration that would
      bring this database current.

      Install #{bridge_name(MigrationsPostgres.bridge_version())} (the migration bridge) first,
      run its migrations until the reported version is at least V#{floor_padded},
      THEN move the dependency pin to this release and run
      mix phoenix_kit.update again.
      """
    end

    defp bridge_name(version), do: "PhoenixKit #{version}"

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
            3. #{next_step_line()}
          """

      Igniter.add_notice(igniter, final_instructions)
    end

    defp finish_update(opts),
      do: with_manual_steps_summary(fn -> post_igniter_tasks(opts) end)

    @doc false
    # Runs `fun` (the migration, asset and schema steps) and prints the closing
    # manual-steps block AFTER it — also when it raises. A declined or failed
    # migration ends in `Mix.raise/1`, and the summary is exactly what such a
    # run must not lose: the raise would otherwise cut it off.
    def with_manual_steps_summary(fun) do
      fun.()
    after
      print_manual_steps()
    end

    # Everything the Oban config pass could not edit by itself, repeated as one
    # block at the very end — after the migration and asset output that buried
    # the one-line warnings in the run that left a host without a cron entry.
    defp print_manual_steps do
      case ObanConfig.manual_steps_summary(
             ObanConfig.take_manual_steps(),
             ObanConfig.take_declined()
           ) do
        "" -> :ok
        summary -> Mix.shell().error(summary)
      end
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

      # Oban's schema step-up, the migrate step, and module migrations
      run_schema_steps(opts)

      # Show migration status summary
      show_migration_status(prefix)
    end

    @doc false
    # The database half of the post-Igniter work, in order:
    #
    #   1. Oban's schema step-up (PhoenixKit.ObanSchema) — written BEFORE the
    #      migrate step so a single `ecto.migrate` applies core and Oban
    #      together, and a declined prompt leaves the file on disk for a later
    #      `mix ecto.migrate`, exactly like the core file Igniter just wrote.
    #   2. the migrate step (prompt, or automatic with --yes)
    #   3. re-reading the Oban schema version after it
    #   4. migrations for registered PhoenixKit modules
    #
    # Deliberately takes no core installation status: the Oban step runs
    # whether or not core had anything to migrate — a host already on the
    # latest core is precisely the one an Oban upgrade leaves behind. `steps`
    # replaces any of the four (tests observe what runs, and in what order).
    def run_schema_steps(opts, steps \\ %{}) do
      steps = Map.merge(default_schema_steps(), steps)
      prefix = PrefixConfig.resolve_prefix(opts)

      oban_staged = steps.stage_oban.(prefix)
      migrate_opts = Keyword.put(opts, :oban_staged, oban_staged)
      steps.migrate.(migrate_opts)
      steps.verify_oban.(oban_staged)
      steps.modules.(opts)
    end

    defp default_schema_steps do
      %{
        stage_oban: &stage_oban_schema_migrations/1,
        migrate: &run_interactive_migration_update/1,
        verify_oban: &verify_oban_schema_migrations/1,
        modules: &run_module_migrations/1
      }
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
            raise_pending_migration(
              """
              Migration not run automatically (#{reason}).
              """,
              opts
            )
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

        case MigrationStrategy.confirm("Run migration? [Y/n]") do
          :yes ->
            run_migration_with_feedback(opts)

          :no ->
            raise_pending_migration("Migration skipped at your request.", opts)

          # Never a yes: the Enter default is for a person who pressed Enter.
          :no_input ->
            raise_pending_migration(
              "Migration not run: no answer on standard input (not a terminal).",
              opts
            )
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
    defp raise_pending_migration(reason, opts) do
      # Hoisted out of the message below rather than called from inside the
      # interpolation: this WRITES migration files to the host repo, and a side
      # effect that big should be a visible statement on the failure path, not
      # something a reader has to follow a formatting helper to discover. It
      # runs even when the operator answered "no" — declining to *migrate* is
      # not declining to have the file written, and the note says so.
      staged = stage_module_migrations(opts)

      Mix.raise("""
      #{String.trim(reason)}

      PhoenixKit's code is updated but the database is not. Do one of:

        mix phoenix_kit.update --yes     # re-run this task and migrate without prompting
                                         # (this is the one for CI/CD and deploy scripts)
        mix ecto.migrate                 # apply the migrations written so far
      #{staged_oban_note(Keyword.get(opts, :oban_staged, []))}#{staged_module_note(staged)}
      """)
    end

    @doc false
    # The line the "not migrated" error adds for an Oban step written to disk.
    def staged_oban_note([]), do: ""

    def staged_oban_note(staged) do
      steps = Enum.map_join(staged, ", ", &"#{&1.prefix} v#{&1.from} → v#{&1.to}")

      "\n  An Oban schema migration is written too (#{steps}); until it runs, " <>
        "unique Oban inserts fail."
    end

    # Raising here aborts the task BEFORE `run_module_migrations/1` runs, so a
    # module carrying its own schema never gets a migration file written. That
    # made the advice above actively wrong: `mix ecto.migrate` applied the core
    # chain, exited 0, and left the module's tables at their old version. The
    # gap then surfaced as an undefined-column crash on a page with no visible
    # connection to this run — core said V166 ✅ while a module sat four
    # versions behind.
    #
    # Writing those files is what makes `mix ecto.migrate` sufficient again.
    # Re-running the task later reuses them rather than writing a duplicate
    # (see `generate_module_migration/3`). Pure formatting — the write happens
    # in `raise_pending_migration/2`, where it is visible.
    defp staged_module_note([]), do: ""

    defp staged_module_note(staged) do
      names = Enum.map_join(staged, ", ", & &1.name)

      "\n  Module schema migrations were written for: #{names}.\n" <>
        "  Either command above applies them; `mix phoenix_kit.status` reports what is left."
    end

    # The database is read here to decide what is pending, and this runs on a
    # path that is already failing — an unreachable repo must not replace the
    # migration advice with a connection error.
    defp stage_module_migrations(opts) do
      prefix = PrefixConfig.resolve_prefix(opts)

      [prefix: prefix]
      |> MigrationModules.list()
      |> MigrationModules.pending()
      |> write_pending_module_migrations(prefix)
    rescue
      _ -> []
    catch
      :exit, _ -> []
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

        --no-start              Migrate the database WITHOUT starting the app
                                For when the app cannot boot because its
                                schema modules are ahead of the database
                                (a column-adding release: "column
                                p0.<new_column> does not exist" at startup).
                                Generates the chain step-up migration and
                                runs it; skips configuration repair, assets
                                and module migrations, which all need the
                                application. Re-run the full update after.

        --migrate-only          Run only the database steps, with only the
                                repo started (the host app does not boot):
                                core step-up, Oban schema, module migrations
                                (files written, then migrated). No prompt;
                                config, layout and assets are left alone.

        --dry-run               Show what would change, write nothing
                                Igniter prints the diff of the project
                                files it would edit; the asset rebuild,
                                vendored JS, migrations and module
                                migration files are listed and skipped

        --install-root-theme    Put the theme bootstrap (pre-paint theme
                                stamp) in your ROOT layout, so your public
                                pages follow the saved theme too. Not done
                                otherwise: the admin and auth pages carry
                                their own.

        --remove-root-theme     Remove a theme bootstrap an earlier update
                                put in the root layout (only the kit-marked
                                one) and record it as declined

        --skip-patch ID         Decline an optional project edit (repeatable)
                                and record it in .phoenix_kit.exs, so later
                                runs leave it out too. IDs: module_js_seed,
                                oban_queues (or oban_queues:<queue>),
                                daisyui_themes, css_sources_import,
                                theme_bootstrap. Required and security
                                edits (body_guard, …) cannot be declined.
                                An inline marker does the same:
                                # phoenix_kit:skip ID  /  <%!-- phoenix_kit:skip ID --%>

        --repair-patch ID       Apply an optional edit again although the
                                ledger says it was removed or declined

        -h, --help              Show this help message

      PATCH LEDGER (.phoenix_kit.exs — commit it)
        The update records which optional edits it made (applied) and which
        you declined. One you remove after an update is not added back; the
        run lists it with the --repair-patch hint. The first run without the
        file behaves as before and records what is present.

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

        # App will not boot ("column ... does not exist")? Migrate first,
        # then run the full update once it starts again
        mix phoenix_kit.update --no-start

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

        3. Create the first Owner (a fresh install has none, and public sign-up
           does not make one):
           mix phoenix_kit.create_owner you@example.com

      CI/CD USAGE
        For automated deployments, use the --yes flag to skip prompts:
        mix phoenix_kit.update -y

      TROUBLESHOOTING
        If the update fails or you need to check status:
        • Check version: mix phoenix_kit.update --status
        • Force regeneration: mix phoenix_kit.update --force
        • Manual migration: mix ecto.migrate
        • Rollback: mix ecto.rollback
        • App will not boot after upgrading the dep, because a host child
          queries a table whose new column is not there yet:
          mix phoenix_kit.update --no-start

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
      report_ahead_modules(modules)

      case MigrationModules.pending(modules) do
        [] ->
          report_modules_up_to_date(modules)

        pending ->
          written = write_pending_module_migrations(pending, prefix)

          if written != [] do
            migrate_host_repo()
          end

          verify_module_migrations(written, prefix)
      end
    end

    # Write every module's migration file FIRST, then migrate once. The old
    # code ran a full `ecto.migrate` inside the loop, so N modules meant N
    # migrator runs over the same (growing) directory.
    defp write_pending_module_migrations(pending, prefix) do
      pending
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        Mix.shell().info(
          "\n⏳ #{entry.name}: V#{pad_version(entry.installed)} → V#{pad_version(entry.target)}"
        )

        write_module_migration(entry, prefix, index)
      end)
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

          %{status: :ahead_of_code, installed: installed} ->
            Mix.shell().error(
              "❌ #{entry.name} is now at V#{pad_version(installed)}, ahead of what " <>
                "#{inspect(entry.migration_module)} expects (V#{pad_version(entry.target)}). " <>
                "Something else migrated it further than this run asked for."
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

    # An ahead-of-code module is not pending — nothing here would migrate
    # it — but it must not be silently reported as up to date either. Called
    # unconditionally, same as `report_unreadable_modules/1`, so it still
    # surfaces on a run where some other module IS pending and
    # `report_modules_up_to_date/1` never runs.
    defp report_ahead_modules(modules) do
      case MigrationModules.ahead_of_code(modules) do
        [] ->
          :ok

        ahead ->
          Enum.each(ahead, fn entry ->
            Mix.shell().info(
              "⚠️  #{entry.name}: V#{pad_version(entry.installed)} is ahead of code " <>
                "(code expects V#{pad_version(entry.target)}) — rollback or a backwards-pinned dependency?"
            )
          end)
      end
    end

    defp report_modules_up_to_date([]), do: :ok

    defp report_modules_up_to_date(modules) do
      Enum.each(modules, fn
        %{status: :error} ->
          :ok

        # Already reported by `report_ahead_modules/1` (called unconditionally
        # before this runs) — skipped here to avoid printing it twice.
        %{status: :ahead_of_code} ->
          :ok

        entry ->
          Mix.shell().info("✅ #{entry.name}: V#{pad_version(entry.installed)} (up to date)")
      end)
    end

    # ── Oban schema ─────────────────────────────────────────────────────────
    #
    # Files go to the host repo's migrations — the repo `ecto.migrate -r` runs
    # and the one core's baseline created Oban's tables on. Checked there at
    # core's prefix, and at the host Oban config's prefix on the repo that
    # config names (see PhoenixKit.ObanSchema.targets/3). Returns the steps
    # that have a migration file waiting to run.
    defp stage_oban_schema_migrations(prefix) do
      case resolve_host_repo_module() do
        nil ->
          []

        repo ->
          dir = module_migrations_dir()
          oban_config = Application.get_env(Mix.Project.config()[:app], Oban)

          repo
          |> ObanSchema.stage(
            ObanSchema.targets(repo, prefix, oban_config),
            dir,
            &unique_timestamp(dir, &1)
          )
          |> Enum.flat_map(&report_oban_schema(&1, repo))
      end
    end

    defp report_oban_schema(
           %{status: {:behind, from, to} = status, file: file} = entry,
           host_repo
         ) do
      where = oban_schema_where(entry, host_repo)
      Mix.shell().info("\n⏳ Oban schema at #{where}: #{ObanSchema.describe(status)}")
      staged = [%{repo: entry.repo, prefix: entry.prefix, from: from, to: to}]

      case file do
        {:created, path} ->
          Mix.shell().info("  Created migration: #{path}")
          staged

        {:exists, path} ->
          Mix.shell().info(
            "  Migration already exists: #{path}\n     Reusing it (it may already have run — if so, the schema would no longer be behind). To regenerate, delete the file first."
          )

          staged

        :other_repo ->
          Mix.shell().info(other_repo_hint(entry, host_repo, from, to))
          []

        :not_generatable ->
          Mix.shell().info(
            "⚠️  Not generating a migration for this schema name; add one by hand:\n" <>
              "    #{oban_up_call(entry.prefix, to)}"
          )

          []

        {:error, message} ->
          Mix.shell().info("⚠️  Could not write the Oban schema migration — #{message}")
          []
      end
    end

    defp report_oban_schema(%{status: {:current, _} = status} = entry, host_repo) do
      Mix.shell().info(
        "✅ Oban schema at #{oban_schema_where(entry, host_repo)}: #{ObanSchema.describe(status)}"
      )

      []
    end

    # Fresh or Oban-less schema: core's baseline installs the library's
    # version itself, so there is nothing to step up.
    defp report_oban_schema(%{status: :no_table}, _host_repo), do: []

    defp report_oban_schema(%{status: {:ahead, _, _} = status} = entry, host_repo) do
      Mix.shell().info(
        "⚠️  Oban #{ObanSchema.describe(status)} at #{oban_schema_where(entry, host_repo)} — " <>
          "a newer Oban migrated it; nothing to do, but check the Oban version you pin."
      )

      []
    end

    defp report_oban_schema(%{status: {:unversioned, _} = status} = entry, host_repo) do
      Mix.shell().info(
        "⚠️  Oban schema at #{oban_schema_where(entry, host_repo)}: #{ObanSchema.describe(status)}.\n" <>
          "    Not generating a migration from an unknown version. Establish it and restamp:\n" <>
          "    COMMENT ON TABLE #{inspect(entry.prefix)}.oban_jobs IS '<version>';"
      )

      []
    end

    defp report_oban_schema(%{status: status} = entry, host_repo) do
      Mix.shell().info(
        "⚠️  Oban schema at #{oban_schema_where(entry, host_repo)}: #{ObanSchema.describe(status)}"
      )

      []
    end

    defp oban_schema_where(%{repo: repo, prefix: prefix}, host_repo),
      do: inspect(ObanSchema.label({repo, prefix}, host_repo))

    # A migration written here would run against the host repo's database,
    # not the one Oban uses — so hand over the migration for that repo instead.
    defp other_repo_hint(%{repo: repo, prefix: prefix}, host_repo, from, to) do
      source =
        if ObanSchema.generatable_prefix?(prefix) do
          ObanSchema.migration_source(ObanSchema.migrations_namespace(repo), prefix, from, to)
        else
          oban_up_call(prefix, to)
        end

      "⚠️  Your Oban config runs on #{inspect(repo)}, not #{inspect(host_repo)} (where this " <>
        "task writes migrations), so no file was written. Add this to #{inspect(repo)}'s " <>
        "migrations and run them:\n\n" <> indent(source)
    end

    defp oban_up_call(prefix, to),
      do: "Oban.Migration.up(version: #{to}, prefix: #{inspect(prefix)}, create_schema: false)"

    defp indent(text) do
      text
      |> String.trim_trailing()
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))
    end

    # Re-read rather than trust the migrator: `ecto.migrate` exits 0 when the
    # file sat somewhere it does not scan (see `verify_module_migrations/2`).
    defp verify_oban_schema_migrations([]), do: :ok

    defp verify_oban_schema_migrations(staged) do
      Enum.each(staged, fn %{repo: repo, prefix: prefix, to: to} ->
        case ObanSchema.check(repo, prefix) do
          {:current, _} = status ->
            Mix.shell().info(
              "✅ Oban schema at #{inspect(prefix)} migrated: #{ObanSchema.describe(status)}"
            )

          status ->
            Mix.raise(
              "Oban schema migration was not verified at #{inspect(prefix)}: " <>
                "#{ObanSchema.describe(status)} " <>
                "(expected v#{to} after migrating). Check that #{inspect(module_migrations_dir())} " <>
                "is the migration path of the repo `mix ecto.migrate` used."
            )
        end
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

      app_module = host_namespace()

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

    defp host_namespace do
      Mix.Project.config()[:app]
      |> to_string()
      |> Macro.camelize()
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
    # `--no-start`: bring the DATABASE up to this release's chain version
    # without booting the host application.
    #
    # The full update needs `Mix.Task.run("app.start")`, and that is exactly
    # what a column-adding release breaks: the newly compiled schema module
    # selects a column the database has not got yet, so any host child that
    # queries at init — a registry warming its cache, a GenServer loading
    # settings — brings the whole boot down, and the updater that would add
    # the column cannot run. `update_mode: true` stands PhoenixKit's own
    # supervisor down, but it has no say over the host's children.
    #
    # This path runs the two steps that need no application: generate the
    # chain step-up migration (`phoenix_kit.gen.migration` reads the version
    # off the migration FILENAMES, never the database) and apply it with
    # `ecto.migrate`, which starts the repo alone. Everything else the full
    # update does — configuration repair, asset rebuild, module migrations —
    # is deliberately skipped and reported, because all of it needs the app.
    defp schema_only_update(opts) do
      if Keyword.get(opts, :dry_run, false) do
        Mix.shell().info("""

        🔍 Dry run (--dry-run --no-start): nothing was written or migrated.
        Without --dry-run this would run, in order:

            mix phoenix_kit.gen.migration#{if opts[:prefix], do: " --prefix #{opts[:prefix]}", else: ""}
            mix ecto.migrate

        and skip configuration repair, assets and module migrations.
        """)
      else
        run_schema_only_update(opts)
      end

      :ok
    end

    @doc false
    # `steps` replaces any of the four (tests observe what runs). The floor is
    # checked before the migration file is generated: below it,
    # `phoenix_kit.gen.migration` (which reads only filenames) wrote a step-up
    # that `ecto.migrate` then failed with a raw BelowFloorError.
    def run_schema_only_update(opts, steps \\ %{}) do
      steps = Map.merge(default_schema_only_steps(), steps)

      Mix.shell().info("""

      🔧 PhoenixKit update — schema only (--no-start)

      Bringing the database up to this release's migration version without
      starting #{Mix.Project.config()[:app]}. Use this when the app cannot
      boot because its schema modules are ahead of the database.
      """)

      # Loads config/*.exs (including runtime.exs) and compiles, without
      # starting any application — `--prefix` still resolves through
      # `config :phoenix_kit, :prefix` below.
      steps.app_config.()
      refuse_below_floor!(opts, steps.installation_status)

      gen_args = if opts[:prefix], do: ["--prefix", opts[:prefix]], else: []
      steps.gen_migration.(gen_args)
      steps.migrate.()

      Mix.shell().info("""

      ✅ Database schema is up to date.

      Skipped (every one of these needs the application running):
        • configuration repair (Ueberauth, Hammer, Oban, supervisor order)
        • asset rebuild and JS/CSS integration
        • migrations for registered PhoenixKit modules

      Not checked either: the Oban schema. It needs only the repo, but this
      path starts nothing before ecto.migrate — mix phoenix_kit.doctor reports
      it, and the full update writes its migration.

      Run the full update once #{Mix.Project.config()[:app]} boots again:

          mix phoenix_kit.update
      """)
    end

    defp default_schema_only_steps do
      %{
        app_config: fn -> Mix.Task.run("app.config") end,
        installation_status: &schema_only_installation_status/1,
        gen_migration: &Mix.Task.run("phoenix_kit.gen.migration", &1),
        migrate: fn -> Mix.Task.run("ecto.migrate") end
      }
    end

    # `--migrate-only`: every database step of the full update — core's
    # step-up, Oban's schema, the module migrations (files written, then
    # migrated) — with only the repo started. Nothing of the host app boots:
    # no pollers, bots or Telegram getUpdates competing with the running app,
    # and no Igniter pass (configuration, layout, assets are left alone).
    defp migrate_only_update(opts) do
      if Keyword.get(opts, :dry_run, false) do
        Mix.shell().info("""

        🔍 Dry run (--dry-run --migrate-only): nothing was written or migrated.
        Without --dry-run this would start only the repo and, in order:
          • refuse a database below this release's floor
          • write the PhoenixKit step-up migration (if behind)
          • write an Oban schema step-up (if behind)
          • run mix ecto.migrate
          • write and run the migrations of installed PhoenixKit modules
        """)
      else
        run_migrate_only_update(opts)
      end

      :ok
    end

    @doc false
    # `steps` replaces any of the steps (tests observe what runs, and that
    # the app is never started).
    def run_migrate_only_update(opts, steps \\ %{}) do
      steps = Map.merge(default_migrate_only_steps(), steps)
      prefix = PrefixConfig.resolve_prefix(opts)

      Mix.shell().info("""

      🔧 PhoenixKit update — database only (--migrate-only)

      Starting only the repo (not #{Mix.Project.config()[:app]}) to run PhoenixKit's,
      Oban's and the installed modules' migrations.
      """)

      steps.app_config.()

      steps.with_repo.(fn ->
        status = steps.installation_status.(prefix)
        refuse_below_floor!(opts, fn _prefix -> status end)
        steps.core_migration.(status, prefix)

        run_schema_steps(opts, %{
          stage_oban: steps.stage_oban,
          migrate: fn _opts -> steps.migrate.() end,
          verify_oban: steps.verify_oban,
          modules: steps.modules
        })
      end)

      Mix.shell().info("""

      ✅ Database migrations done. Not run (they need the application or edit
      project files): configuration repair, layout/JS/CSS integration, the
      asset rebuild. Run the full `mix phoenix_kit.update` for those when the
      app can start.
      """)
    end

    defp default_migrate_only_steps do
      %{
        app_config: fn -> Mix.Task.run("app.config") end,
        with_repo: &with_host_repo/1,
        installation_status: &Common.check_installation_status/1,
        core_migration: &write_core_migration_file/2,
        stage_oban: &stage_oban_schema_migrations/1,
        migrate: fn -> migrate_host_repo() end,
        verify_oban: &verify_oban_schema_migrations/1,
        modules: &run_module_migrations/1
      }
    end

    # The repo PhoenixKit uses, started on its own (`Ecto.Migrator.with_repo/3`
    # starts the adapter's applications and the repo, nothing else, and stops
    # the repo afterwards). `ecto.migrate` inside reuses it.
    defp with_host_repo(fun) do
      repo = resolve_host_repo_module() || PhoenixKit.RepoHelper.repo()

      case Ecto.Migrator.with_repo(repo, fn _repo -> fun.() end, pool_size: 2) do
        {:ok, result, _apps} -> result
        {:error, reason} -> Mix.raise("Could not start #{inspect(repo)}: #{inspect(reason)}")
      end
    end

    @doc false
    # The core step-up file for `--migrate-only`, from the version the
    # DATABASE reports (the full update writes the same file through Igniter;
    # `--no-start` reads filenames instead). Same name, same content, same
    # duplicate guard as `create_update_migration_with_igniter/6`.
    def write_core_migration_file({:current_version, current}, prefix) do
      target = Common.current_version()

      if current < target do
        {name, content} = update_migration(prefix, current, target, false)
        dir = Path.join(["priv", "repo", "migrations"])

        existing =
          Path.wildcard(Path.join(dir, "*" <> update_migration_suffix(current, target, false)))

        case existing do
          [file | _] ->
            Mix.shell().info("  Migration already exists: #{file} (reused)")

          [] ->
            File.mkdir_p!(dir)
            File.write!(Path.join(dir, name), content)
            Mix.shell().info("📦 PhoenixKit Update Migration Created: #{name}")
        end
      else
        Mix.shell().info("✅ PhoenixKit is already up to date (V#{Common.pad_version(current)}).")
      end
    end

    def write_core_migration_file({:not_installed}, prefix) do
      Mix.raise(
        "No PhoenixKit installation found at schema prefix #{inspect(prefix)} — " <>
          "--migrate-only updates an existing install (pass --prefix if it lives elsewhere)."
      )
    end

    def write_core_migration_file(other, _prefix) do
      Mix.raise(
        "Cannot read the installed PhoenixKit version (#{inspect(other)}); " <>
          "run mix phoenix_kit.doctor."
      )
    end

    # Starts the repo alone, as `ecto.migrate` is about to, to read the
    # installed version. A repo that will not start is left to `ecto.migrate`
    # to report.
    defp schema_only_installation_status(prefix) do
      case Ecto.Migrator.with_repo(PhoenixKit.RepoHelper.repo(), fn _repo ->
             Common.check_installation_status(prefix)
           end) do
        {:ok, status, _apps} -> status
        {:error, reason} -> {:unreachable, reason}
      end
    end

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

    # Advisory only — the host owns its daisyUI; PhoenixKit's
    # modals rely on daisyUI >= DaisyUI.minimum_version() for correct modal
    # scrollbar-gutter handling (see PhoenixKit.Install.DaisyUI).
    #
    # The heads-up band prints once per {kit, daisyUI} version pair (kept in
    # the patch ledger, written with the rest of it); below the gutter fix it
    # prints every run.
    defp warn_if_daisyui_outdated do
      case DaisyUI.notice_once() do
        nil -> :ok
        warning -> Mix.shell().info(warning)
      end
    end

    # The user dashboard has two things worth saying, and which one applies
    # depends on what the host has actually configured:
    #
    #   * switched ON explicitly — the deprecation heads-up, as before.
    #   * key never written — the host is upgrading across the default flip to
    #     `false`, so /dashboard stops routing on the next compile. Say so, and
    #     say how to keep it. This is the only notice an unsuspecting host gets.
    #   * switched OFF explicitly — they decided; nothing to say.
    defp warn_user_dashboard_deprecated do
      cond do
        PhoenixKit.Config.user_dashboard_enabled?() ->
          Mix.shell().info(Deprecations.user_dashboard_warning())

        not PhoenixKit.Config.user_dashboard_configured?() ->
          Mix.shell().info(Deprecations.user_dashboard_default_changed())

        true ->
          :ok
      end
    end

    # Update CSS integration during PhoenixKit updates. Two optional patches
    # (`PhoenixKit.Install.PatchLedger`): `daisyui_themes` (themes: false →
    # all) and `css_sources_import` (the generated sources @import). A host
    # that undid either after an earlier update keeps it undone.
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
          original = File.read!(css_path)

          content =
            original
            |> enable_daisyui_themes(css_path)
            |> add_css_sources_import(css_path)

          if content != original, do: File.write!(css_path, content)

          # Ensure the generated CSS sources file exists so @import doesn't fail
          if String.contains?(content, "_phoenix_kit_sources.css"),
            do: ensure_css_sources_file(css_path)
      end
    rescue
      error ->
        # Non-critical error - log and continue
        Mix.shell().info("ℹ️  Could not update CSS integration: #{inspect(error)}")
    end

    @doc false
    def enable_daisyui_themes(content, css_path) do
      disabled? = CssIntegration.check_existing_integration(content).daisyui_themes_disabled

      case PatchLedger.decide("daisyui_themes", not disabled?, content) do
        :apply ->
          pattern = ~r/@plugin\s+(["'][^"']*daisyui["'])\s*\{([^}]*themes:\s*)false([^}]*)\}/

          updated =
            String.replace(content, pattern, fn match ->
              String.replace(match, ~r/(themes:\s*)false/, "\\1all")
            end)

          if updated != content do
            # Recorded only if app.css on disk shows it when the ledger is written: a write
            # that fails leaves `themes: false`, which the next run would read as removed.
            PatchLedger.record("daisyui_themes", :applied, fn ->
              not CssIntegration.check_existing_integration(File.read!(css_path)).daisyui_themes_disabled
            end)

            Mix.shell().info("""

            ✅ Updated daisyUI configuration to enable all themes!
            File: #{css_path}
            Changed: themes: false → themes: all
            """)
          end

          updated

        {:declined, reason} ->
          Mix.shell().info(JsIntegration.declined_notice("daisyui_themes", reason))
          content

        :present ->
          content
      end
    end

    @doc false
    def add_css_sources_import(content, css_path) do
      present? = String.contains?(content, "_phoenix_kit_sources.css")

      case PatchLedger.decide("css_sources_import", present?, content) do
        :apply ->
          updated =
            String.replace(
              content,
              ~r/(@source\s+["'][^"']*phoenix_kit["'];)/,
              "\\1\n@import \"./_phoenix_kit_sources.css\";",
              global: false
            )

          if updated != content do
            PatchLedger.record("css_sources_import", :applied, fn ->
              css_path |> File.read!() |> String.contains?("_phoenix_kit_sources.css")
            end)

            Mix.shell().info("""

            ✅ Added auto-generated CSS sources import!
            File: #{css_path}
            Added: @import "./_phoenix_kit_sources.css";
            """)
          end

          updated

        {:declined, reason} ->
          Mix.shell().info(JsIntegration.declined_notice("css_sources_import", reason))
          content

        :present ->
          content
      end
    end

    defp ensure_css_sources_file(css_path) do
      generated_path = Path.join(Path.dirname(css_path), "_phoenix_kit_sources.css")

      unless File.exists?(generated_path) do
        File.write!(generated_path, """
        /* Auto-generated by PhoenixKit — do not edit manually.
           Regenerated on each compilation from css_sources/0 callbacks. */
        """)

        Mix.shell().info("✅ Created #{generated_path} (will be updated on next compilation)")
      end
    end

    # Check if migration can be run interactively
    defp check_migration_conditions do
      # Check if we have an app name
      case Mix.Project.config()[:app] do
        nil ->
          {:error, "No app name found"}

        _app ->
          # TERM alone cannot tell (`mix phoenix_kit.update < /dev/null`, a
          # tool runner's pipe): ask whether standard input is a terminal.
          if System.get_env("CI") || !System.get_env("TERM") ||
               !MigrationStrategy.interactive_terminal?() do
            {:error, "no interactive terminal"}
          else
            :ok
          end
      end
    rescue
      _ -> {:error, "Error checking conditions"}
    end

    # Execute migration with feedback
    defp run_migration_with_feedback(_opts) do
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
        show_update_success_notice()
      rescue
        error ->
          Mix.shell().info("\n⚠️  Migration failed: #{Exception.message(error)}")
          show_manual_migration_instructions()

          # Swallowing this returned exit 0 from `phoenix_kit.update -y` with the
          # schema still behind — the same "deploy went green with silent
          # drift" failure the declined-migration path already refuses.
          Mix.raise("PhoenixKit: database migration failed — see the output above.")
      end
    end

    # Show success notice after update
    #
    # Not a plain "success" while config edits are still waiting on the host:
    # the closing "Manual steps needed" block follows, and this line must not
    # read as the last word before it.
    defp show_update_success_notice do
      case ObanConfig.manual_step_count() do
        0 ->
          Mix.shell().info("""
          🎉 PhoenixKit updated successfully! #{next_step_line()}
          """)

        n ->
          Mix.shell().info("""
          PhoenixKit updated — #{n} manual step(s) below. #{next_step_line()}
          """)
      end
    end

    @doc false
    # The closing pointer: the admin area when an Owner exists, the console
    # task when none does (public sign-up no longer makes the first registrant
    # the Owner, see `PhoenixKit.Users.Setup`), both when the count cannot be
    # read. Paths carry the configured `url_prefix` (`Routes.path/2`) — the
    # earlier `--prefix` (a database schema) was never a URL.
    @spec next_step_line(:none | :exists | :unknown) :: String.t()
    def next_step_line(owner_state \\ owner_state()) do
      case owner_state do
        :exists ->
          "Visit: #{app_path("/admin")}"

        :none ->
          "This site has no Owner yet — create it with: " <>
            "mix phoenix_kit.create_owner you@example.com"

        :unknown ->
          "Visit: #{app_path("/admin")} " <>
            "(no Owner yet? mix phoenix_kit.create_owner you@example.com)"
      end
    end

    defp owner_state do
      if Roles.count_active_owners() > 0, do: :exists, else: :none
    rescue
      _ -> :unknown
    catch
      :exit, _ -> :unknown
    end

    # See the note at the aliases. A config that cannot be read falls back to
    # the default prefix.
    defp app_path(path) do
      Routes.path(path, locale: :none)
    rescue
      _ -> "/phoenix_kit" <> path
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

    defp format_module_version(%{status: :ahead_of_code} = entry) do
      "#{IO.ANSI.red()}V#{pad_version(entry.installed)} ⚠ ahead of code (code expects V#{pad_version(entry.target)})#{IO.ANSI.reset()}"
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
            fix_ueberauth_providers_config(igniter)

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
    #
    # I103: wrapped with the same parse-then-verify safety net as the Oban
    # config splices — a single-line `Regex.replace/3` is lower risk than a
    # multi-line block splice, but it is still blind to comments/strings.
    # The verify+rollback decision happens INSIDE the `Igniter.update_file/3`
    # callback, against the BUFFERED content (`Rewrite.Source.get(source,
    # :content)`) — NOT a fresh disk read taken before this runs. Igniter
    # buffers writes and never flushes them to disk mid-pipeline: building
    # the candidate from a stale disk read and then unconditionally
    # overwriting the buffer with it discarded whatever earlier steps in the
    # SAME run had already staged for config/config.exs — concretely,
    # `BasicConfiguration.add_basic_config/1` and
    # `PrefixConfig.add_prefix_configuration/2`, both of which write to this
    # exact file earlier in `mix phoenix_kit.update`'s pipeline. A lost
    # `prefix:` backfill sends the next `update`/`status` looking for the
    # installation in `public` (see `PhoenixKit.Install.PrefixConfig`'s
    # moduledoc).
    #
    # Public (not `defp`), `@doc false`: a real unit-test seam, the same
    # reasoning as `PhoenixKit.Install.ObanConfig`'s exposed splice helpers —
    # the defect this guards against lives in what actually lands in the
    # buffer, which only an Igniter-level test (`Igniter.Test.test_project/1`)
    # can reach.
    @doc false
    @spec fix_ueberauth_providers_config(Igniter.t()) :: Igniter.t()
    def fix_ueberauth_providers_config(igniter) do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        content = Rewrite.Source.get(source, :content)

        candidate =
          Regex.replace(
            ~r/(config\s+:ueberauth,\s+Ueberauth,\s+providers:\s*)\[\s*\]/,
            content,
            "\\1%{}"
          )

        case ConfigVerify.verify_or_rollback(content, candidate, &ueberauth_providers_map?/1) do
          {:ok, updated_content} ->
            Mix.shell().info("""

            ✅ Fixed Ueberauth configuration: providers: [] → providers: %{}
               OAuth authentication will now work correctly.
            """)

            Rewrite.Source.update(source, :content, updated_content)

          {:rolled_back, _original, _reason} ->
            {:warning,
             "Could not safely fix Ueberauth's providers: [] -> %{} (the replacement would " <>
               "have produced invalid or misplaced config) - please change it manually in " <>
               "config/config.exs."}
        end
      end)
    end

    # True if `ast` has `config :ueberauth, Ueberauth, providers: %{}` (or
    # any non-empty `providers:` map/keyword) — used to confirm the
    # `[] -> %{}` replacement actually landed on the real Ueberauth config
    # call, not on a comment or string that happened to match the same text.
    defp ueberauth_providers_map?(ast) do
      ConfigVerify.ast_contains?(ast, fn
        {:config, _, [:ueberauth, {:__aliases__, _, [:Ueberauth]}, opts]} when is_list(opts) ->
          match?({:ok, {:%{}, _, _}}, ConfigVerify.keyword_get(opts, :providers))

        _ ->
          false
      end)
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
    #
    # P013: this used to decide `:correct` / `:needs_fix` from a fresh
    # `File.read!/1` of application.ex — the same class of bug fixed under
    # I103 for `BootHook.add_boot_hook/1` and
    # `fix_ueberauth_providers_config/1`. Igniter never flushes a step's
    # writes to disk before the next step runs; on a real `mix
    # phoenix_kit.update`, TWO earlier steps in the SAME pipeline stage
    # `application.ex` edits before this one runs —
    # `ApplicationSupervisor.add_supervisor/1` (unconditionally, at the top
    # of `igniter/1`) and `ObanConfig.add_oban_supervisor/1` (right before
    # this call, inside `perform_igniter_update/2`) — both via
    # `Igniter.Project.Application.add_new_child/3`, which only ever
    # touches the Igniter buffer. A disk read here is blind to both: it can
    # see no `PhoenixKit.Supervisor`/`Oban` line at all, match
    # `validate_supervisor_positions/4`'s trivial "nothing to check yet"
    # clauses, and report `:correct` while the buffer — the content that
    # actually reaches disk when this run finishes — sits misordered.
    # `Igniter.exists?/2` + loading the file into the Igniter buffer before
    # reading its content (`Rewrite.Source.get/2`) makes this check see the
    # SAME up-to-date state the subsequent fix in
    # `fix_application_supervisor_order/3` already reads from.
    #
    # Test seam: made public (`@doc false`) the same way I103 exposed
    # `fix_ueberauth_providers_config/1` — this defect can only be
    # exercised end-to-end (a real, non-test-mode Igniter + real temp
    # disk), not via a pure-content unit test.
    @doc false
    @spec fix_supervisor_ordering(Igniter.t()) :: Igniter.t()
    def fix_supervisor_ordering(igniter) do
      app_name = IgniterHelpers.get_parent_app_name(igniter)
      app_file = "lib/#{app_name}/application.ex"

      if Igniter.exists?(igniter, app_file) do
        igniter = Igniter.include_existing_file(igniter, app_file)
        content = igniter.rewrite |> Rewrite.source!(app_file) |> Rewrite.Source.get(:content)

        # Check current supervisor ordering
        case check_supervisor_order(content, app_name) do
          :correct ->
            # Order is already correct, no changes needed
            igniter

          {:needs_fix, reason} ->
            # Order is incorrect: rewrite the list only when its shape is
            # one the line-based rewrite understands, otherwise say what to
            # move and leave the file alone.
            case reorder_supervisors(content, app_name) do
              {:ok, fixed_content} ->
                igniter
                |> fix_application_supervisor_order(app_file, fixed_content)
                |> add_supervisor_ordering_fixed_notice(reason)

              :unsafe ->
                add_supervisor_ordering_manual_notice(igniter, app_file, reason)
            end

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
    defp fix_application_supervisor_order(igniter, app_file, fixed_content) do
      Igniter.update_file(igniter, app_file, fn source ->
        Rewrite.Source.update(source, :content, fixed_content)
      end)
    end

    @doc false
    # Reorders the supervisors of `application.ex` — `{:ok, content}`, or
    # `:unsafe` when the children list is not one plain `children = [ ... ]`
    # holding every line it would move (a list built with `++`, a child
    # spread over several lines, a list it cannot find). The rewrite is
    # line-based, so on any other shape it could duplicate or drop a child:
    # the host's file is then left exactly as it is. The result must also
    # parse and keep the same children, or it is `:unsafe` too.
    def reorder_supervisors(content, app_name) do
      with :literal <- ChildOrder.list_shape(content),
           {:ok, fixed} <- reorder_supervisor_lines(content, app_name),
           true <- fixed != content,
           true <- same_children?(content, fixed) do
        {:ok, fixed}
      else
        _ -> :unsafe
      end
    end

    defp same_children?(before, after_reorder) do
      with {:ok, old_children} <- ChildOrder.ordered_children(before),
           {:ok, new_children} <- ChildOrder.ordered_children(after_reorder) do
        Enum.sort(old_children) == Enum.sort(new_children)
      else
        _ -> false
      end
    end

    defp reorder_supervisor_lines(content, app_name) do
      lines = String.split(content, "\n")

      # Convert snake_case app_name to PascalCase module name
      app_module = Macro.camelize(to_string(app_name))

      # Extract supervisor lines
      {repo_line, repo_index} = extract_supervisor(lines, ~r/#{app_module}\.Repo[,\s]/)
      {pk_line, pk_index} = extract_supervisor(lines, ~r/PhoenixKit\.Supervisor[,\s]/)

      {oban_line, oban_index} =
        extract_supervisor(lines, ~r/\{Oban,|Application\.get_env\(:#{app_name}, Oban\)/)

      # Determine children list boundaries. No `children = [` line (the list
      # opens on the next line, or is built some other way) used to reach
      # `find_children_list_end/2` as `nil + 1` — an ArithmeticError.
      children_start = find_children_list_start(lines)

      children_end =
        if is_integer(children_start), do: find_children_list_end(lines, children_start)

      supervisor_indexes = Enum.reject([repo_index, pk_index, oban_index], &is_nil/1)

      if is_integer(children_start) and is_integer(children_end) and
           Enum.all?(supervisor_indexes, &(&1 in (children_start + 2)..children_end//1)) do
        # Build new children list with correct order
        supervisors = %{
          repo: {repo_line, repo_index},
          phoenix_kit: {pk_line, pk_index},
          oban: {oban_line, oban_index}
        }

        new_lines =
          rebuild_children_list(lines, children_start, children_end, supervisors)

        {:ok, Enum.join(new_lines, "\n")}
      else
        # A line to move sits outside the list this found (or no list was
        # found): rewriting would duplicate or lose a child.
        :unsafe
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

    defp add_supervisor_ordering_manual_notice(igniter, app_file, reason) do
      Igniter.add_warning(igniter, """
      ⚠️  The children list in #{app_file} looks misordered (#{reason}), but it is
         not a single plain `children = [ ... ]` list (it is built with `++`, a
         child spans several lines, or the list could not be found), so it was
         NOT changed. Reorder it by hand to:

           1. YourApp.Repo
           2. PhoenixKit.Supervisor   (before the Endpoint)
           3. YourAppWeb.Endpoint
           4. {Oban, ...}

         `mix phoenix_kit.doctor` checks the order afterwards.
      """)
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
      supervisor_exists = ObanConfig.oban_supervisor_exists?(igniter)

      # Always call add_oban_configuration - it handles both:
      # - Adding new configuration if missing
      # - Adding any declared queue (PhoenixKit.ObanQueues) the existing
      #   configuration is missing, without changing limits already set
      # and reports the result in one line (ObanConfig.report_patch/2): an
      # edit that would not parse is skipped and listed in the closing summary.
      igniter = ObanConfig.add_oban_configuration(igniter, prefix)

      # Check and add supervisor separately
      if supervisor_exists do
        igniter
      else
        igniter
        |> ObanConfig.add_oban_supervisor()
        |> add_oban_supervisor_added_notice()
      end
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
