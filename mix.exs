defmodule PhoenixKit.MixProject do
  use Mix.Project

  @version "1.7.208"
  @description "A foundation for building Elixir Phoenix apps — SaaS, social networks, ERP systems, marketplaces, and more"
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

      # Testing — Elixir 1.19's `mix test` uses these filters to pick
      # which files to load as tests. Without them, `test/support/*.ex`
      # files are flagged as orphaned and never run through the test
      # loader, which leaves `test_helper.exs` looking up modules that
      # were compiled but not loaded.
      test_load_filters: [~r/_test\.exs$/],
      test_ignore_filters: [~r{^test/support/}],
      test_coverage: [tool: ExCoveralls],

      # Aliases for development
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "test.setup": :test,
        "test.reset": :test
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
      extra_applications: [:logger, :ecto, :postgrex, :crypto, :gettext],
      mod: {PhoenixKit.Application, []}
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
      {:postgrex, "~> 0.22"},

      # Phoenix web layer
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.1"},

      # Web functionality
      {:gettext, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:esbuild, "~> 0.8", only: :dev},
      {:tailwind, "~> 0.5", only: :dev},
      {:phoenix_live_reload, "~> 1.6.1", only: :dev},

      # Authentication
      {:bcrypt_elixir, "~> 3.0"},
      {:swoosh, "~> 1.20"},
      {:gen_smtp, "~> 1.2"},

      # OAuth authentication
      #
      # No ueberauth_apple: last released 2023 (unmaintained), and its
      # httpoison "~> 1.0 or ~> 2.0" pin was the thing blocking hackney from
      # moving past 1.25.0 (4 unpatched CVEs, 1 HIGH — fixed only in 4.0.1+).
      # Apple Sign-In can come back via a maintained fork later; see
      # CHANGELOG for the removal note.
      {:oauth2, "~> 2.0"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"},
      {:ueberauth_github, "~> 0.8"},
      {:ueberauth_facebook, "~> 0.10"},

      # hackney 4.x, clearing 4 unpatched CVEs on the 1.25.0 line (1 HIGH).
      # No override needed anymore (Hex refuses to publish a package
      # depending on one, which blocked every release since 1.7.188):
      # ex_aws_sqs's `hackney ~> 1.9` pin — the only remaining conflicting
      # requirement — is gone along with the package itself, replaced
      # above by beamlab_ex_aws_sqs. No direct httpoison dependency
      # either — the ueberauth_apple pin that justified it is gone, and
      # nothing else in the tree or in phoenix_kit's own code calls
      # HTTPoison.
      {:hackney, "~> 4.0"},

      # Development and testing
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:usage_rules, "~> 1.2", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},

      # Content editor
      {:leaf, "~> 0.3"},

      # Markdown → HTML (comrak). Declared here in core so every module shares
      # one resolved version instead of each pulling its own and risking
      # mismatches. Modules (e.g. phoenix_kit_comments) call MDEx directly and
      # rely on it being provided transitively through phoenix_kit.
      {:mdex, "~> 0.13"},
      # mdex_native builds from source (instead of downloading a precompiled
      # NIF) when MDEX_NATIVE_BUILD=1 is set in the environment; that path
      # requires rustler itself, not just rustler_precompiled.
      {:rustler, ">= 0.0.0", optional: true},

      # Pan-zoom image viewer + annotation overlay. Fresco 0.5 dropped
      # OpenSeadragon and replaced the wrapped-OSD viewer with a
      # hand-rolled CSS-transform engine; it also added <Fresco.canvas>
      # (the layered scene with `extensions.etcher` for annotation data).
      # Fresco 0.6 extracted `<Fresco.scroll_strip>` to a separate
      # `fresco_strip` package — PhoenixKit doesn't use scroll_strip
      # so no companion dep needed.
      # Etcher 0.3 dropped its Ecto storage adapter and now persists
      # annotations inside the canvas's extensions map — single bulk
      # `etcher:annotations-changed` event, client-side UUIDv7. Etcher
      # 0.5 added the public `revealShape` Promise + `shapeAt`
      # hit-test API (deep-link / custom tap-zone integrations);
      # PhoenixKit doesn't call those yet so the bump is pure
      # additive. JS hooks ship in each lib's `priv/static/`; parent
      # apps either import them directly in `app.js` or rely on the
      # lazy-load wrappers in phoenix_kit.js (jsdelivr-pinned to the
      # matching version).
      # Tessera 0.3 was rewritten for Fresco's engine — a peer layer (like
      # Etcher) that swaps raster resolutions on zoom and streams DZI tiles
      # of the original for deep zoom on >4K images (no OpenSeadragon). The
      # tile overlay rides Fresco's stage transform so it stays glued to the
      # image. JS hooks lazy-load from jsdelivr pinned to the matching tag.
      {:fresco, "~> 0.10"},
      {:tessera, "~> 0.3"},
      {:etcher, "~> 0.9"},

      # QR device-handoff login ("scan to sign in" on the login page).
      {:keyfob, "~> 0.1"},

      # Cloud provider regions
      {:aws_regions, "~> 0.1.0"},
      {:backblaze_regions, "~> 0.1.0"},
      {:tigris_regions, "~> 0.1.0"},

      # Utilities
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:nimble_csv, "~> 1.2"},
      {:uuidv7, "~> 1.0"},
      {:oban, "~> 2.20"},

      # Rate limiting (ETS backend is built into Hammer 6.x)
      {:hammer, "~> 7.1"},

      # DB Sync - WebSocket client for cross-site data sync
      {:websockex, "~> 0.5.1"},

      # AWS integration for emails
      {:sweet_xml, "~> 0.7"},
      {:ex_aws, "~> 2.4"},
      # Fork of the archived ex_aws_sqs, published as beamlab_ex_aws_sqs —
      # same public API (ExAws.SQS), switched to the SQS JSON protocol.
      # Existed to unblock the hackney 4.x upgrade below: upstream
      # ex_aws_sqs pins `hackney ~> 1.9`, which can't coexist with `~> 4.0`
      # (and Hex refuses to publish a package depending on one that does,
      # via override: true). This fork declares no hackney dependency at
      # all — see its README for the full migration notes (response
      # bodies are now raw JSON maps, e.g. `%{"QueueUrl" => ...}`, not
      # `%{body: %{queue_url: ...}}`).
      # v5.0.0 renamed the compiled OTP app back to `:ex_aws_sqs` (only the
      # Hex package name is `beamlab_ex_aws_sqs`), making it a proper
      # drop-in for anything depending on `:ex_aws_sqs` directly — hence the
      # `hex:` override below instead of `{:beamlab_ex_aws_sqs, "~> 5.0"}`.
      {:ex_aws_sqs, "~> 5.0", hex: :beamlab_ex_aws_sqs},
      {:ex_aws_sns, "~> 2.3"},
      {:ex_aws_sts, "~> 2.3"},
      {:ex_aws_s3, "~> 2.4"},
      {:ex_aws_ec2, "~> 2.0"},
      {:saxy, "~> 1.5"},
      {:finch, "~> 0.18"},

      # HTTP client for payment providers
      {:req, "~> 0.5"},

      # Code generation and project patching
      # Note: Available in all environments for library code, but typically
      # only needed in :dev when used as a dependency in parent projects
      {:igniter, "~> 0.7"},

      # Language and country data
      {:beamlab_countries, "~> 1.0"}
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
        "guides/integration.md",
        "guides/oauth-and-magic-link-setup.md",
        "guides/aws-email-setup.md",
        "guides/making-pages-live.md",
        "guides/phk-publishing-format.md",
        "guides/auth-header-integration.md",
        "guides/draggable-list-component.md",
        "guides/README.md",
        "guides/custom-admin-pages.md",
        "guides/per-module-i18n.md",
        "lib/phoenix_kit/dashboard/ADMIN_README.md"
      ],
      groups_for_extras: [
        Guides: ~r/(guides\/.*|ADMIN_README)/
      ],
      groups_for_modules: [],
      # CHANGELOG is a historical record — entries cite functions/
      # modules that may have since been renamed, made private, or
      # extracted to another package (e.g. external Ecto modules
      # referenced by code spans). Don't fail the docs build over
      # stale historical references; module-level docs still get
      # full reference checking.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  # Development aliases
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],

      # Test database management
      "test.setup": ["ecto.create --quiet", "ecto.migrate --quiet"],
      "test.reset": ["ecto.drop --quiet", "test.setup"],

      # Code quality
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --warnings-as-errors --all-warnings",
        "deps.unlock --check-unused",
        "quality.ci"
      ],

      # Release gate — run before `mix hex.publish`. Catches release-metadata
      # drift and packaging mistakes that precommit/quality.ci structurally
      # cannot. Deliberately DB-free (no `mix test` here — CI owns that).
      prerelease: [
        "deps.get --check-locked",
        "deps.unlock --check-unused",
        "cmd MIX_ENV=prod mix compile --force --warnings-as-errors",
        "quality.ci",
        "deps.audit",
        "hex.audit",
        "docs",
        "hex.build",
        "phoenix_kit.release_check"
      ]
    ]
  end
end
