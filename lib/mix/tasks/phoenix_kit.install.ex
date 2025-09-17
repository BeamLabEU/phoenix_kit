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
    * `--theme-enabled` - Enable modern daisyUI 5 + Tailwind CSS 4 theme system with 35+ themes

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
      AssetRebuild,
      CssIntegration,
      DemoFiles,
      LayoutConfig,
      MailerConfig,
      MigrationStrategy,
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
          theme_enabled: :boolean,
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
      |> RepoDetection.add_phoenix_kit_configuration(opts[:repo])
      |> MailerConfig.add_mailer_configuration()
      |> LayoutConfig.add_layout_integration_configuration()
      |> CssIntegration.add_automatic_css_integration()
      |> DemoFiles.copy_test_demo_files()
      |> RouterIntegration.add_router_integration(opts[:router_path])
      |> MigrationStrategy.create_phoenix_kit_migration_only(opts)
      |> add_completion_notice()
    end

    # Override run/1 to handle post-igniter interactive migration
    def run(argv) do
      # Store options in process dictionary for later use
      opts =
        OptionParser.parse(argv,
          switches: [
            router_path: :string,
            repo: :string,
            prefix: :string,
            create_schema: :boolean,
            theme_enabled: :boolean,
            skip_assets: :boolean
          ],
          aliases: [
            r: :router_path,
            repo: :repo,
            p: :prefix
          ]
        )

      Process.put(:phoenix_kit_install_opts, elem(opts, 1))

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

        {:igniter, "~> 0.6.27"}

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
              {:igniter, "~> 0.6.27"}
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
