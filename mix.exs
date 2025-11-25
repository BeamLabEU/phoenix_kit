defmodule PhoenixKit.MixProject do
  use Mix.Project

  @version "1.6.10"
  @description "PhoenixKit is a starter kit for building modern web applications with Elixir and Phoenix"
  @source_url "https://github.com/BeamLabEU/phoenix_kit"

  def project do
    [
      app: :phoenix_kit,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex package configuration
      package: package(),

      # Documentation
      docs: docs(),

      # Testing
      test_coverage: [tool: ExCoveralls],

      # Aliases for development
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],

      # Dialyzer configuration
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs",
        # Exclude test files from Dialyzer analysis
        list_unused_filters: true
      ],

      # Aliases for development
      aliases: aliases()
    ]
  end

  # Library configuration - no OTP application
  # The parent Phoenix application will handle supervision
  def application do
    [
      extra_applications: [:logger, :ecto, :postgrex, :crypto, :gettext]
    ]
  end

  # Specifies which paths to compile per environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Dependencies - minimal and focused on library functionality
  defp deps do
    [
      # Database
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.21.1"},

      # Phoenix web layer
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.1.12"},

      # Web functionality
      {:gettext, "~> 1.0"},
      {:plug_cowboy, "~> 2.5"},
      {:esbuild, "~> 0.8", only: :dev},
      {:tailwind, "~> 0.4.0", only: :dev},
      {:phoenix_live_reload, "~> 1.6.1", only: :dev},

      # Authentication
      {:bcrypt_elixir, "~> 3.0"},
      {:swoosh, "~> 1.19.5"},
      {:gen_smtp, "~> 1.2"},

      # OAuth authentication
      {:oauth2, "~> 2.0"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"},
      {:ueberauth_apple, "~> 0.1"},
      {:ueberauth_github, "~> 0.8"},
      {:ueberauth_facebook, "~> 0.10"},

      # Development and testing
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:usage_rules, "~> 0.1", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.6", only: [:dev, :test], runtime: false},
      {:floki, ">= 0.30.0", only: :test},
      {:hackney, "~> 1.9"},

      # Utilities
      {:jason, "~> 1.4"},
      {:earmark, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:uuidv7, "~> 1.0"},
      {:oban, "~> 2.20"},

      # Rate limiting (ETS backend is built into Hammer 6.x)
      {:hammer, "~> 7.1"},

      # AWS integration for emails
      {:sweet_xml, "~> 0.7"},
      {:ex_aws, "~> 2.4"},
      {:ex_aws_sqs, "~> 3.4"},
      {:ex_aws_sns, "~> 2.3"},
      {:ex_aws_sts, "~> 2.3"},
      {:ex_aws_s3, "~> 2.4"},
      {:ex_aws_ec2, "~> 2.0"},
      {:saxy, "~> 1.5"},
      {:finch, "~> 0.18"},

      # Code generation and project patching
      # Note: Available in all environments for library code, but typically
      # only needed in :dev when used as a dependency in parent projects
      {:igniter, "~> 0.7"}
    ]
  end

  # Package configuration for Hex.pm
  defp package do
    [
      name: "phoenix_kit",
      maintainers: ["BeamLab EU"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  # Documentation configuration
  defp docs do
    [
      name: "PhoenixKit",
      source_ref: "v#{@version}",
      source_url: @source_url,
      main: "PhoenixKit",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/oauth_and_magic_link_setup.md",
        "guides/aws_email_setup.md",
        "guides/making-pages-live.md",
        "guides/phk_blogging_format.md",
        "guides/AUTH_HEADER_INTEGRATION.md",
        "guides/README.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: []
    ]
  end

  # Development aliases
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],

      # Code quality
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
