if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.PhoenixKit.Install do
    @moduledoc """
    Igniter installer for PhoenixKit.

    This task automatically installs PhoenixKit into a Phoenix application by:
    1. Auto-detecting and configuring Ecto repo
    2. Setting up mailer configuration for development and production
    3. Modifying the router to include PhoenixKit routes

    ## Usage

    The recommended one-command install (adds the dep, fetches, and runs this task):

    ```bash
    mix igniter.install phoenix_kit
    ```

    Requires the `igniter_new` archive (one-time setup, same as `phx_new`):

    ```bash
    mix archive.install hex igniter_new
    ```

    If `:phoenix_kit` is already in your project's deps, run the task directly:

    ```bash
    mix phoenix_kit.install
    ```

    With custom options:

    ```bash
    mix igniter.install phoenix_kit --repo MyApp.Repo --router-path lib/my_app_web/router.ex
    ```

    ## Options

    * `--repo` - Specify Ecto repo module (auto-detected if not provided)
    * `--router-path` - Specify custom path to router.ex file
    * `--prefix` - Specify PostgreSQL schema prefix (defaults to "public").
      Must match `[a-z_][a-z0-9_]*` (validated; the install aborts otherwise).
      A non-public prefix is persisted as `config :phoenix_kit, prefix:` (in
      config.exs and test.exs), baked into the generated migration, and
      written into the generated Oban config as `prefix:`.
    * `--create-schema` - Create schema if using custom prefix (default: true for non-public prefixes)
    * `--install-root-theme` - Also put `PhoenixKitWeb.Components.ThemeBootstrap`
      in the root layout, so the host's public pages follow the kit's saved
      theme. Off by default: the kit's admin and auth pages stamp the theme
      themselves.
    * `--trusted-proxy CIDR` - A reverse proxy whose `X-Forwarded-For` /
      `X-Real-IP` headers may be believed (repeatable). Written as
      `config :phoenix_kit, trusted_proxies: [...]`. Without the flag the
      installer asks in a terminal (default: no proxy, which writes `[]`);
      with no terminal it writes nothing. See `PhoenixKit.Install.InstallDefaults`.

    ## Auto-detection

    The installer will automatically:
    - Detect Ecto repo from `:ecto_repos` config or common naming patterns (MyApp.Repo).
      With MULTIPLE repos detected, the install halts and requires `--repo`
      (guessing between e.g. a runtime repo and a migration-only repo is unsafe)
    - Find main router using Phoenix conventions (MyAppWeb.Router)
    - Configure Swoosh.Adapters.Local for development in config/dev.exs
    - Provide production mailer setup instructions
    - Name the site after the app: `config :phoenix_kit, project_title: "My App"`
      (humanized OTP app name; an existing entry is kept)
    - On a new installation, give stored credentials a dedicated encryption key:
      generated in config/dev.exs and config/test.exs, read from
      `PHOENIX_KIT_INTEGRATIONS_ENCRYPTION_KEY` in the `:prod` block of
      config/runtime.exs (see `PhoenixKit.Install.EncryptionKeyConfig`)

    ## Note about warnings

    You may see a compiler warning about "unused import PhoenixKitWeb.Integration".
    This is normal behavior for Elixir macros and can be safely ignored.
    The `phoenix_kit_routes()` macro is properly used and will expand correctly.
    """

    @shortdoc "Install PhoenixKit into a Phoenix application"

    use Igniter.Mix.Task

    alias PhoenixKit.Install.{
      AdminLabelConfig,
      ApplicationSupervisor,
      BasicConfiguration,
      BootHook,
      BrowserPipelineIntegration,
      Common,
      CssIntegration,
      DaisyUI,
      Deprecations,
      EncryptionKeyConfig,
      EndpointIntegration,
      IgniterHelpers,
      InstallDefaults,
      JsIntegration,
      LayoutConfig,
      MailerConfig,
      MigrationStrategy,
      MissingIgniter,
      OAuthConfig,
      ObanConfig,
      PatchLedger,
      PrefixConfig,
      RateLimiterConfig,
      RepoDetection,
      RouterIntegration,
      TestFixturesIntegration
    }

    # NOTE: Do NOT alias PhoenixKit.Utils.Routes here — it depends on
    # application config that isn't available during mix task execution.

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :phoenix_kit,
        example: "mix igniter.install phoenix_kit --repo MyApp.Repo --prefix auth",
        positional: [],
        schema: [
          router_path: :string,
          repo: :string,
          prefix: :string,
          create_schema: :boolean,
          skip_assets: :boolean,
          trusted_proxy: :keep,
          install_root_theme: :boolean
        ],
        aliases: [
          r: :router_path,
          repo: :repo,
          p: :prefix
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      # A project that already has `.phoenix_kit.exs` keeps what it declined
      # (`PatchLedger.with_existing/2`); a fresh one installs as always.
      PatchLedger.with_existing(fn -> install_pipeline(igniter) end)
    end

    defp install_pipeline(igniter) do
      opts = igniter.args.options

      igniter
      |> BasicConfiguration.add_basic_config()
      |> BasicConfiguration.add_new_app_defaults()
      |> AdminLabelConfig.add_admin_label_options()
      |> RepoDetection.add_phoenix_kit_configuration(opts[:repo])
      |> PrefixConfig.add_prefix_configuration(opts[:prefix])
      |> MailerConfig.add_mailer_configuration()
      |> RateLimiterConfig.add_rate_limiter_configuration()
      |> InstallDefaults.add_trusted_proxies(opts[:trusted_proxy] || [])
      |> InstallDefaults.add_project_title()
      |> OAuthConfig.add_oauth_configuration()
      |> EncryptionKeyConfig.add_encryption_key()
      |> ObanConfig.add_oban_configuration(PrefixConfig.resolve_prefix(opts))
      |> ApplicationSupervisor.add_supervisor()
      |> BootHook.add_boot_hook()
      |> ObanConfig.add_oban_supervisor()
      |> LayoutConfig.add_layout_integration_configuration()
      |> Common.ensure_compilers_registered([
        :phoenix_kit_css_sources,
        :phoenix_kit_js_sources
      ])
      |> CssIntegration.add_automatic_css_integration()
      |> JsIntegration.add_js_integration()
      |> maybe_install_root_theme(opts)
      |> warn_if_daisyui_outdated()
      |> warn_user_dashboard_deprecated()
      |> RouterIntegration.add_router_integration(opts[:router_path])
      |> BrowserPipelineIntegration.add_integration_to_browser_pipeline()
      |> TestFixturesIntegration.ensure_conn_case_import()
      |> EndpointIntegration.add_endpoint_integration()
      |> EndpointIntegration.add_body_guard()
      |> MigrationStrategy.create_phoenix_kit_migration_only(opts)
      |> add_completion_notice(opts)
      |> queue_post_install(opts)
      |> IgniterHelpers.tidy_messages()
    end

    # The theme bootstrap in the host's root layout is opt-in: the kit's own
    # admin and auth pages stamp the theme themselves, and a root copy would
    # re-theme the host's public site too.
    defp maybe_install_root_theme(igniter, opts) do
      if opts[:install_root_theme],
        do: JsIntegration.ensure_theme_bootstrap(igniter),
        else: igniter
    end

    # The migration prompt and asset rebuild have to happen AFTER the file
    # changes land, so they cannot live in this pipeline directly - but they
    # cannot live in run/1 either: `mix igniter.install phoenix_kit` (the entry
    # point this task's own help recommends) composes installers via
    # Igniter.Mix.Task.configure_and_run/3, which calls igniter/1 and never
    # run/1. Queue them instead; Igniter runs queued tasks once changes are
    # committed, on both entry points, and skips them on --dry-run.
    defp queue_post_install(igniter, opts) do
      prefix_argv = if prefix = opts[:prefix], do: ["--prefix", prefix], else: []
      skip_assets_argv = if opts[:skip_assets], do: ["--skip-assets"], else: []

      Igniter.add_task(
        igniter,
        "phoenix_kit.post_install",
        prefix_argv ++ skip_assets_argv ++ migrate_argv(igniter)
      )
    end

    # "Run the migration?" is asked HERE, while igniter/1 runs in the process
    # the person typed into. The queued task cannot ask: Igniter starts it with
    # Mix.shell().cmd/1, whose child inherits TERM but gets a stdin pipe nobody
    # writes to, so a prompt there waited forever.
    #
    # An explicit --yes means migrate. No flag on a non-terminal means no
    # question and no flag: Igniter turns `yes` on by itself when stdin is not
    # a TTY, which is consent to the file changes, not to touching a database,
    # so post_install prints the "run mix ecto.migrate" note as before.
    #
    # The direct `mix phoenix_kit.install` path can run igniter/1 twice (the
    # config pre-flight restarts it); the first answer is kept for the second.
    @migrate_answer_key :phoenix_kit_install_migrate_argv

    defp migrate_argv(igniter) do
      case Process.get(@migrate_answer_key) do
        nil ->
          argv = decide_migrate_argv(igniter)
          if argv != [], do: Process.put(@migrate_answer_key, argv)
          argv

        argv ->
          argv
      end
    end

    @doc false
    def decide_migrate_argv(igniter) do
      cond do
        # The migration file exists already: post_install reports the
        # upgrade / up-to-date state on its own.
        !igniter.assigns[:phoenix_kit_new_install?] -> []
        # Queued tasks do not run on --dry-run.
        flag?(igniter, :dry_run, "--dry-run") -> []
        "--yes" in igniter.args.argv -> ["--migrate"]
        !MigrationStrategy.interactive_terminal?() -> []
        ask_migrate?() -> ["--migrate"]
        true -> ["--no-migrate"]
      end
    end

    # Global Igniter switches are not always parsed into a task's own options
    # on the composed `igniter.install` path; Igniter reads them off argv too.
    defp flag?(igniter, key, flag),
      do: igniter.args.options[key] == true or flag in igniter.args.argv

    defp ask_migrate? do
      Mix.shell().info("""

      🚀 PhoenixKit adds a migration that creates its tables.
      It can run `mix ecto.migrate` right after the changes below are applied
      (answer n to run it yourself later).
      """)

      Igniter.Util.IO.yes?("Run the migration after installing?")
    end

    # Override run/1 to handle post-igniter interactive migration
    def run(argv) do
      # The compile-time `Code.ensure_loaded?(Igniter.Mix.Task)` guard around
      # this module can outlive the dependency it tested (see
      # `PhoenixKit.Install.MissingIgniter`), so ask again before any generated
      # Igniter code runs.
      MissingIgniter.ensure_available!("phoenix_kit.install", argv)

      # Handle --help flag
      if "--help" in argv or "-h" in argv do
        show_help()
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
            # Store status in Process dictionary for tracking
            Process.put(:phoenix_kit_config_status, :missing)

            show_missing_config_message(argv)
            super(argv)

            # AUTOMATIC RESTART instead of asking user to run again manually
            Mix.shell().info("""

            ✅ Configuration added successfully!
            🔄 Automatically restarting to complete the installation...
            """)

            # Clean Process dictionary to ensure fresh state for retry
            Process.delete(:phoenix_kit_config_status)

            # Mark this as a retry pass to prevent infinite loops
            Process.put(:phoenix_kit_retry_pass, true)

            # Recursive call with same arguments - automatic restart
            run(argv)

          {:ok, _} ->
            # Second pass: Configuration exists, safe to start app and complete installation
            Process.put(:phoenix_kit_config_status, :ok)

            # Run standard igniter process. The migration prompt and asset
            # rebuild ride along as a queued task (see queue_post_install/2),
            # so they happen here too - and on the igniter.install path, which
            # never reaches this function.
            result = super(argv)

            # Clean up retry flag on successful completion
            Process.delete(:phoenix_kit_retry_pass)
            Process.delete(@migrate_answer_key)
            InstallDefaults.forget_answers()
            result

          {:missing, true} ->
            # Safety check: Configuration still missing after automatic retry
            # This prevents infinite loops if configuration addition fails
            Mix.shell().error("""

            ❌ Configuration was not added successfully after automatic retry.

            Please check config/config.exs manually and ensure it contains:
            - config :ueberauth, Ueberauth (with providers: [])
            - config :hammer (with backend and expiry_ms)
            - config :your_app, Oban (with queues configuration)

            Then run: mix phoenix_kit.install #{Enum.join(argv, " ")}
            """)

            Process.delete(:phoenix_kit_retry_pass)
            Process.delete(@migrate_answer_key)
            InstallDefaults.forget_answers()
            :error
        end
      end
    end

    # Display comprehensive help information
    defp show_help do
      Mix.shell().info("""

      mix phoenix_kit.install - Install PhoenixKit into a Phoenix application

      USAGE
        # Recommended (single command — adds dep, fetches, and runs this task):
        mix igniter.install phoenix_kit [OPTIONS]

        # Direct invocation (when :phoenix_kit is already in your deps):
        mix phoenix_kit.install [OPTIONS]

        Tip: `mix igniter.install` requires the `igniter_new` archive
        (`mix archive.install hex igniter_new` — one-time setup).

      DESCRIPTION
        Automatically installs PhoenixKit into a Phoenix application by:
        • Auto-detecting and configuring Ecto repository
        • Setting up mailer configuration for development and production
        • Modifying the router to include PhoenixKit routes
        • Creating database migrations for authentication system
        • Integrating CSS assets (daisyUI 5 + Tailwind CSS)

      OPTIONS
        --repo MODULE           Specify Ecto repo module (e.g., MyApp.Repo)
                                Auto-detected if not provided

        --router-path PATH      Specify custom path to router.ex file
                                Default: auto-detected (MyAppWeb.Router)

        --prefix SCHEMA         PostgreSQL schema prefix for PhoenixKit tables
                                Default: "public" (standard PostgreSQL schema)
                                Use custom prefix for table isolation
                                Example: --prefix "auth"
                                Validated ([a-z_][a-z0-9_]*); persisted into
                                config :phoenix_kit, prefix: and the generated
                                Oban config. Runtime schemas compile it in —
                                any later mix compile/phx.server picks it up.

        --create-schema         Create schema if using custom prefix
                                Default: true for non-public prefixes

        --skip-assets           Skip automatic asset rebuild check
                                Default: false

        --install-root-theme    Also put the theme bootstrap (pre-paint
                                theme stamp) in your root layout, so your
                                public pages follow the saved theme. The
                                admin and auth pages carry their own.

        --trusted-proxy CIDR    A reverse proxy whose X-Forwarded-For header
                                is believed (repeatable), e.g.
                                --trusted-proxy 127.0.0.1/8 --trusted-proxy 10.0.0.0/8
                                Written as config :phoenix_kit, trusted_proxies:.
                                Without it the installer asks (default: no
                                proxy, which writes trusted_proxies: []);
                                with no terminal it writes nothing.

        -h, --help              Show this help message

      EXAMPLES
        # Basic installation with auto-detection (uses default "public" schema)
        mix igniter.install phoenix_kit

        # Install with specific repository
        mix igniter.install phoenix_kit --repo MyApp.Repo

        # Install with custom PostgreSQL schema prefix for table isolation
        mix igniter.install phoenix_kit --prefix "auth" --create-schema

        # Install with custom router path
        mix igniter.install phoenix_kit --router-path lib/my_app_web/router.ex

        # Install with all options
        mix igniter.install phoenix_kit --repo MyApp.Repo --prefix "auth"

        # All flags also work with direct invocation: mix phoenix_kit.install ...

      AUTO-DETECTION
        The installer automatically:
        • Detects Ecto repo from :ecto_repos config or naming patterns
        • Finds main router using Phoenix conventions
        • Configures Swoosh.Adapters.Local for development
        • Provides production mailer setup instructions

      URL PREFIX CONFIGURATION
        PhoenixKit routes are served under a URL prefix (default: /phoenix_kit).
        To customize or remove the prefix, configure in config/config.exs:

        # Default behavior (prefix: /phoenix_kit)
        phoenix_kit_routes()
        # Routes: /phoenix_kit/users/register, /phoenix_kit/admin

        # Custom prefix
        config :phoenix_kit, url_prefix: "/auth"
        # Routes: /auth/users/register, /auth/admin

        # No prefix (root-level routes)
        config :phoenix_kit, url_prefix: ""
        # Routes: /users/register, /admin

      AFTER INSTALLATION
        1. Run database migrations:
           mix ecto.migrate

        2. Start your Phoenix server:
           mix phx.server

        3. Create the first Owner:
           mix phoenix_kit.create_owner you@example.com
           (in dev on localhost, the first account registered at
           http://localhost:4000/phoenix_kit/users/register becomes it too)

        4. Check the install:
           mix phoenix_kit.doctor

      NOTES
        • You may see "unused import PhoenixKitWeb.Integration" warning
          This is normal for Elixir macros and can be safely ignored
        • The phoenix_kit_routes() macro expands correctly at compile time

      DOCUMENTATION
        For more information, visit:
        https://phoenix-kit.hexdocs.pm
      """)
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

      After this completes, please run the install command again:
        mix phoenix_kit.install #{Enum.join(argv, " ")}
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
          # Not a comment and contains config :any_app, Oban
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

    # PhoenixKit relies on the host's vendored daisyUI being reasonably modern
    # (modal scrollbar-gutter handling; see PhoenixKit.Install.DaisyUI). The
    # host owns that file — we only warn, never touch it.
    #
    # The heads-up band (a fresh phx.new app is in it) prints once per
    # {kit, daisyUI} version pair, remembered in .phoenix_kit.exs; not
    # remembered on a dry run, which writes nothing.
    defp warn_if_daisyui_outdated(igniter) do
      case DaisyUI.notice_once(not IgniterHelpers.dry_run?(igniter)) do
        nil -> igniter
        warning -> Igniter.add_warning(igniter, warning)
      end
    end

    # Advance heads-up that the user dashboard (/dashboard) is deprecated.
    #
    # Gated on the flag: it now defaults to `false`, so a fresh install has no
    # user dashboard and warning about one would be noise about a feature the
    # host does not have. Only a host that explicitly wrote
    # `user_dashboard_enabled: true` hears about it.
    defp warn_user_dashboard_deprecated(igniter) do
      if PhoenixKit.Config.user_dashboard_enabled?() do
        Igniter.add_warning(igniter, Deprecations.user_dashboard_warning())
      else
        igniter
      end
    end

    # Add completion notice with essential next steps (reduced duplication)
    defp add_completion_notice(igniter, opts) do
      prefix_note =
        case opts[:prefix] do
          prefix when is_binary(prefix) and prefix != "public" ->
            """
              • Prefixed install: the schema prefix compiles into PhoenixKit's
                Ecto schemas. The next mix compile / ecto.migrate / phx.server
                picks it up automatically; a build compiled before this config
                change fails loudly at boot (compile-env check) rather than
                silently querying public.
            """

          _ ->
            ""
        end

      # Igniter renders every notice as a "* " bullet, so a leading blank line
      # prints a bare "*" and pushes the body to the next line. Trim.
      notice =
        """
        ✅ PhoenixKit ready! Next:
          • mix ecto.migrate (only if you skipped the migration prompt above)
          • mix phx.server
          • mix phoenix_kit.create_owner you@example.com (the first Owner; in dev on
            localhost, registering at <url_prefix>/users/register also makes it)
          • mix phoenix_kit.doctor
        #{prefix_note}
        """
        |> String.trim()

      Igniter.add_notice(igniter, notice)
    end
  end
else
  # Igniter is optional (see mix.exs), so this task cannot be defined here.
  # A guard with no `else` would make it vanish and Mix would report only
  # "could not be found" — naming neither PhoenixKit nor the missing dep.
  defmodule Mix.Tasks.PhoenixKit.Install do
    @moduledoc """
    Placeholder for `mix phoenix_kit.install`, which needs the optional :igniter
    dependency. Running it explains how to add igniter; see
    `PhoenixKit.Install.MissingIgniter` for why the dep is optional.
    """

    use PhoenixKit.Install.MissingIgniter, task: "phoenix_kit.install"
  end
end
