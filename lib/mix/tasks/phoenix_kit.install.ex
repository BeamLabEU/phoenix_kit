if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.PhoenixKit.Install do
    @moduledoc """
    Igniter installer for PhoenixKit.

    This task automatically installs PhoenixKit into a Phoenix application by:
    1. Auto-detecting and configuring Ecto repo
    2. Setting up mailer configuration for development and production
    3. Modifying the router to include PhoenixKit routes

    ## Usage

    ```bash
    mix phoenix_kit.install
    ```

    With custom options:

    ```bash
    mix phoenix_kit.install --repo MyApp.Repo --router-path lib/my_app_web/router.ex
    ```

    ## Options

    * `--repo` - Specify Ecto repo module (auto-detected if not provided)
    * `--router-path` - Specify custom path to router.ex file
    * `--prefix` - Specify PostgreSQL schema prefix (defaults to "public")
    * `--create-schema` - Create schema if using custom prefix (default: true for non-public prefixes)

    ## Auto-detection

    The installer will automatically:
    - Detect Ecto repo from `:ecto_repos` config or common naming patterns (MyApp.Repo)
    - Find main router using Phoenix conventions (MyAppWeb.Router)
    - Configure Swoosh.Adapters.Local for development in config/dev.exs
    - Provide production mailer setup instructions

    ## Note about warnings

    You may see a compiler warning about "unused import PhoenixKitWeb.Integration".
    This is normal behavior for Elixir macros and can be safely ignored.
    The `phoenix_kit_routes()` macro is properly used and will expand correctly.
    """

    @shortdoc "Install PhoenixKit into a Phoenix application"

    use Igniter.Mix.Task

    alias PhoenixKit.Install.{
      ApplicationSupervisor,
      AssetRebuild,
      BasicConfiguration,
      BrowserPipelineIntegration,
      CssIntegration,
      DemoFiles,
      LayoutConfig,
      MailerConfig,
      MigrationStrategy,
      OAuthConfig,
      RateLimiterConfig,
      RepoDetection,
      RouterIntegration
    }

    alias PhoenixKit.Utils.Routes

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :phoenix_kit,
        example: "mix phoenix_kit.install --repo MyApp.Repo --prefix auth",
        positional: [],
        schema: [
          router_path: :string,
          repo: :string,
          prefix: :string,
          create_schema: :boolean,
          skip_assets: :boolean
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
      opts = igniter.args.options

      igniter
      |> BasicConfiguration.add_basic_config()
      |> RepoDetection.add_phoenix_kit_configuration(opts[:repo])
      |> MailerConfig.add_mailer_configuration()
      |> RateLimiterConfig.add_rate_limiter_configuration()
      |> OAuthConfig.add_oauth_configuration()
      |> ApplicationSupervisor.add_supervisor()
      |> LayoutConfig.add_layout_integration_configuration()
      |> CssIntegration.add_automatic_css_integration()
      |> DemoFiles.copy_test_demo_files()
      |> RouterIntegration.add_router_integration(opts[:router_path])
      |> BrowserPipelineIntegration.add_integration_to_browser_pipeline()
      |> MigrationStrategy.create_phoenix_kit_migration_only(opts)
      |> add_completion_notice()
    end

    # Override run/1 to handle post-igniter interactive migration
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
              router_path: :string,
              repo: :string,
              prefix: :string,
              create_schema: :boolean,
              skip_assets: :boolean
            ],
            aliases: [
              r: :router_path,
              repo: :repo,
              p: :prefix
            ]
          )

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
            # Second pass: Configuration exists, safe to start app and complete installation
            # Run standard igniter process
            result = super(argv)

            # After igniter is done, handle interactive migration
            MigrationStrategy.handle_interactive_migration_after_config(elem(opts, 1))

            # Always rebuild assets unless explicitly skipped
            unless Keyword.get(elem(opts, 1), :skip_assets, false) do
              AssetRebuild.check_and_rebuild(verbose: true)
            end

            result
        end
      end
    end

    # Display comprehensive help information
    defp show_help do
      Mix.shell().info("""

      mix phoenix_kit.install - Install PhoenixKit into a Phoenix application

      USAGE
        mix phoenix_kit.install [OPTIONS]

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

        --create-schema         Create schema if using custom prefix
                                Default: true for non-public prefixes

                                        Adds 35+ themes support with theme controller
                                Default: false

        --skip-assets           Skip automatic asset rebuild check
                                Default: false

        -h, --help              Show this help message

      EXAMPLES
        # Basic installation with auto-detection (uses default "public" schema)
        mix phoenix_kit.install

        # Install with specific repository
        mix phoenix_kit.install --repo MyApp.Repo

        # Install with custom PostgreSQL schema prefix for table isolation
        mix phoenix_kit.install --prefix "auth" --create-schema


        # Install with custom router path
        mix phoenix_kit.install --router-path lib/my_app_web/router.ex

        # Install with all options
        mix phoenix_kit.install --repo MyApp.Repo --prefix "auth"

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
        # Routes: /phoenix_kit/users/register, /phoenix_kit/admin/dashboard

        # Custom prefix
        config :phoenix_kit, url_prefix: "/auth"
        # Routes: /auth/users/register, /auth/admin/dashboard

        # No prefix (root-level routes)
        config :phoenix_kit, url_prefix: ""
        # Routes: /users/register, /admin/dashboard

      AFTER INSTALLATION
        1. Run database migrations:
           mix ecto.migrate

        2. Start your Phoenix server:
           mix phx.server

        3. Visit registration page:
           http://localhost:4000/phoenix_kit/users/register

        4. Test authentication:
           /test-current-user - Check current user
           /test-ensure-auth  - Test authentication requirement

      NOTES
        • You may see "unused import PhoenixKitWeb.Integration" warning
          This is normal for Elixir macros and can be safely ignored
        • The phoenix_kit_routes() macro expands correctly at compile time

      DOCUMENTATION
        For more information, visit:
        https://hexdocs.pm/phoenix_kit
      """)
    end

    # Display message about missing configuration
    defp show_missing_config_message(argv) do
      Mix.shell().info("""

      ⚠️  Required configuration is missing from config/config.exs

      PhoenixKit requires configuration for:
      - Ueberauth (OAuth authentication)
      - Hammer (rate limiting)

      This configuration will be added now.

      After this completes, please run the install command again:
        mix phoenix_kit.install #{Enum.join(argv, " ")}
      """)
    end

    # Display message after configuration is added
    defp show_config_added_message(argv) do
      Mix.shell().info("""

      ✅ Configuration added successfully!

      Next step: Run the install command again to complete the installation:
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

          # Incorrect Ueberauth configuration (providers: [] instead of providers: %{})
          String.contains?(content, "config :ueberauth, Ueberauth") &&
              Regex.match?(~r/providers:\s*\[\s*\]/, content) ->
            :missing

          # Missing Hammer configuration (check for active, non-commented config)
          !has_active_hammer_config?(lines) ->
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

    # Add completion notice with essential next steps (reduced duplication)
    defp add_completion_notice(igniter) do
      notice = """

      ✅ PhoenixKit ready! Next:
        • mix ecto.migrate
        • mix phx.server
        • Visit #{Routes.path("/users/register")}
        • Test: /test-current-user, /test-ensure-auth
      """

      Igniter.add_notice(igniter, notice)
    end
  end

  # Fallback module for when Igniter is not available
else
  defmodule Mix.Tasks.PhoenixKit.Install do
    @moduledoc """
    PhoenixKit installation task.

    This task requires the Igniter library to be available. Please add it to your mix.exs:

        {:igniter, "~> 0.7"}

    Then run: mix deps.get
    """

    @shortdoc "Install PhoenixKit (requires Igniter)"

    use Mix.Task

    def run(_args) do
      Mix.shell().error("""

      ❌ PhoenixKit installation requires the Igniter library.

      Please add Igniter to your mix.exs dependencies:

          def deps do
            [
              {:igniter, "~> 0.7"}
              # ... your other dependencies
            ]
          end

      Then run:
        mix deps.get
        mix phoenix_kit.install

      For more information, visit: https://hex.pm/packages/igniter
      """)
    end
  end
end
