defmodule PhoenixKit.MixProject do
  use Mix.Project

  @version "2.22.23"
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
  # Resolves a dep from Hex by default, or from a local checkout when <APP>_PATH is
  # exported — e.g. LOCALE_SLUG_PATH=../../../Elixir/locale_slug. Unset means the
  # published pin, so `mix hex.publish` and CI are unaffected. Never commit a
  # hand-edited path: tuple; it ships a broken package.
  defp local_dep(app, requirement) do
    case System.get_env(String.upcase(Atom.to_string(app)) <> "_PATH") do
      nil -> {app, requirement}
      path -> {app, path: path, override: true}
    end
  end

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

      # Message template rendering: resolves a named template across the host's
      # override files and the locale chain, then substitutes {{variables}}.
      # A leaf by construction — no runtime deps of its own — which is what lets
      # core depend on it rather than feature-detecting it through a behaviour.
      local_dep(:phoenix_kit_templates, "~> 0.1.0"),

      # Slugs. Locale-aware because ö must expand to "oe" in German and fold to "o"
      # in Estonian, and core's hand-rolled table could not express the difference —
      # it produced "gro-e-fu-ball" for "Größe Fußball" and an EMPTY slug for any
      # Cyrillic-only title. Pure Elixir, no dependencies of its own.
      #
      # local_dep/2 keeps the Hex pin by default so published builds and CI are
      # unchanged, and swaps in a path dep when LOCALE_SLUG_PATH is exported —
      # matching the PHOENIX_LIVE_GANTT_PATH / PHOENIX_KIT_PATH convention.
      #
      # Pinned three-segment (`~> 0.2.0`, not `~> 0.2`). The looser form admits
      # every 0.x, and a 0.x package promises nothing about its API — but the
      # real exposure here is not the API, it is the OUTPUT. A revised
      # romanization table changes the slug a host derives from the same title,
      # and slugs are persisted in URLs and compared for uniqueness, so a
      # `mix deps.update` would rewrite content by way of a dependency bump.
      # Adopting a new minor is a deliberate PhoenixKit release with a CHANGELOG
      # line, not a side effect — which is what moving 0.1.0 → 0.2.0 is here.
      #
      # 0.2.0 changes CYRILLIC output only; German, Estonian, Greek and
      # `script: :native` are byte-identical. It is adopted because 0.1.0 was
      # broken for Cyrillic beyond Russian: with core's `fallback: :empty`,
      # `slugify("Київ", locale: "uk")` and `slugify("България", locale: "bg")`
      # both returned `""` — passing the CORRECT locale reproduced the empty-slug
      # bug this dependency exists to fix, and an empty slug reads to callers as
      # "not generated yet", so they regenerate forever. Stored slugs are not
      # rewritten; only newly generated ones change.
      local_dep(:locale_slug, "~> 0.2.0"),
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

      # Content editor. Core declares it for the whole tree — phoenix_kit_comments
      # renders the composer but inherits the dep from here, so this requirement
      # governs every host.
      #
      # NOT `~> 0.3`: that spanned 0.3 → 0.9, and for a 0.x package where each
      # minor is effectively a major it claimed a support window core cannot
      # back.
      #
      # Every alternative carries a PATCH segment on purpose. `~> 0.5` is
      # `>= 0.5.0 and < 1.0.0` — one such alternative swallows the whole 0.x
      # line and makes every later `or ~> 0.6 or ~> 0.7 or ~> 0.8` inert, so
      # the enumeration reads as a curated window while admitting leaf 0.9 and
      # everything after it. That matters here more than for an ordinary dep:
      # `priv/static/assets/phoenix_kit.js` serves the browser half from an
      # exact jsDelivr tag, so an open ceiling lets a host float the Elixir
      # half past a frozen bundle — the silent cross-version editor exactly
      # that pin exists to prevent. `~> 0.8.0` is `>= 0.8.0 and < 0.9.0`, so
      # the next leaf minor needs the same three-file PR that moved this one.
      # `leaf_bundle_pin_test.exs` holds the ceiling to the pinned minor.
      {:leaf, "~> 0.4.1 or ~> 0.5.0 or ~> 0.6.0 or ~> 0.7.0 or ~> 0.8.0"},

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
      #
      # Ceilings carry a patch segment for the same reason :leaf's do (see
      # the comment there): each of these serves its browser half from an
      # exact jsDelivr tag in phoenix_kit.js, and a patch-less `~> 0.N`
      # reads as "the 0.N line" while meaning `< 1.0.0` — an open ceiling
      # that lets a host float the Elixir half past the frozen bundle the
      # day the next minor ships. `vendored_cdn_pins_test.exs` holds each
      # ceiling to the pinned minor; the next minor of any of them needs
      # the same requirement + lock + CDN-pin move :leaf gets.
      {:fresco, "~> 0.10.0 or ~> 0.11.0"},
      {:tessera, "~> 0.3.0"},
      {:etcher, "~> 0.9.0 or ~> 0.10.0 or ~> 0.11.0 or ~> 0.12.0 or ~> 0.13.0"},

      # QR device-handoff login ("scan to sign in" on the login page).
      #
      # 0.1.1, not a bare `~> 0.1`: before it, a store that wasn't running
      # made the store's reads raise and its GenServer-backed calls exit
      # rather than returning the `:error` the behaviour declares. The
      # completion controller's `with` matches return values, so `consume/2`
      # exiting meant a 500 on the finish URL where "this link is invalid or
      # has expired" was both the honest answer and the same outcome.
      {:keyfob, "~> 0.1.1"},

      # Cloud provider regions
      {:aws_regions, "~> 0.1.0"},
      {:backblaze_regions, "~> 0.1.0"},
      {:tigris_regions, "~> 0.1.0"},

      # Utilities
      # Timezone database. Elixir ships UTC-only, so DateTime.shift_zone/3 needs
      # one of these to resolve an IANA id like "Europe/Warsaw". `tz` over
      # `tzdata` on purpose: tzdata fetches releases over HTTP at runtime by
      # default, and a library should not hand every host app an outbound call
      # it did not ask for. `tz` compiles the data in; it refreshes when this
      # dep is upgraded.
      {:tz, "~> 0.28"},
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

      # Code generation and project patching — powers `mix phoenix_kit.install`
      # and `mix phoenix_kit.update`.
      #
      # MUST stay `optional: true`. A stock `mix phx.new` app declares
      # `{:igniter, "~> 0.6", only: [:dev, :test]}`; a non-optional dep here
      # resolves to all environments, and Mix refuses to converge the two:
      #
      #     Dependencies have diverged:
      #     * igniter (Hex package) — the :only option for dependency igniter
      #
      # which made `mix igniter.install phoenix_kit` fail on every freshly
      # generated Phoenix project. Optional means the host's own declaration
      # wins. Every task that needs igniter is already wrapped in
      # `if Code.ensure_loaded?(Igniter.Mix.Task)`, so a host without it simply
      # doesn't get those tasks rather than failing to compile.
      {:igniter, "~> 0.7", optional: true},

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
      # NOTE: `mix test` is deliberately NOT here — see AGENTS.md "CI/CD".
      # Adding it was tried and reverted: the suite is not
      # green from a clean checkout (Settings reads hit the DB on a cache
      # miss, so ~5 "unit" tests fail with no database at all; with one,
      # unbounded concurrency exhausts the pool). A gate that is always red
      # gets ignored, which is worse than an honest gap. Run the suite
      # explicitly — `mix test` — and see AGENTS.md for pointing it at a
      # database you already have.
      precommit: [
        "compile --warnings-as-errors --all-warnings",
        "deps.unlock --check-unused",
        "quality.ci",
        "test.js"
      ],

      # Pure logic inside the shipped hook bundle (test/js, node --test). Skips
      # itself when node isn't installed rather than failing a contributor's
      # precommit over an optional tool.
      "test.js": &run_js_tests/1,

      # Release gate — run before `mix hex.publish`. Catches release-metadata
      # drift and packaging mistakes that precommit/quality.ci structurally
      # cannot. Deliberately DB-free — running `mix test` is a separate
      # manual step, see AGENTS.md "CI/CD".
      prerelease: [
        "deps.get --check-locked",
        "deps.unlock --check-unused",
        # `env` prefix, not a bare assignment: `mix cmd` shells out through
        # System.cmd/3, which execs the first word directly — "MIX_ENV=prod" is
        # not an executable, so this step raised :enoent and the whole gate
        # aborted before reaching deps.audit/hex.audit/docs/hex.build/
        # release_check. Found 2026-08-09, the first time the gate was run to
        # completion.
        "cmd env MIX_ENV=prod mix compile --force --warnings-as-errors",
        "quality.ci",
        "deps.audit",
        # Both hex.* steps run in a subprocess: after the dialyzer step has
        # run in this VM, Hex-archive tasks stop resolving ("The task
        # "hex.audit" could not be found") while project-dep tasks
        # (deps.audit, docs, release_check) still do. Bisected 2026-08-09:
        # `mix do format --check-formatted + credo --strict + hex.audit`
        # passes, `mix do quality.ci + hex.audit` fails — the added step is
        # dialyzer. A fresh VM per hex.* step is immune.
        "cmd mix hex.audit",
        "docs",
        "cmd mix hex.build",
        "phoenix_kit.release_check"
      ]
    ]
  end

  # `node --test test/js` over the pure helpers exported from the hook bundle.
  # Node is optional tooling here, so a machine without it skips rather than
  # fails — the Elixir suite is still the gate.
  defp run_js_tests(_args) do
    # `node --test` with no file arguments walks the CWD looking for anything
    # test-shaped, so an empty glob must skip rather than hand node the whole
    # repo (deps/ and _build/ included).
    files = Path.wildcard("test/js/*.test.cjs")

    cond do
      files == [] ->
        Mix.shell().info("[skip] no test/js/*.test.cjs files")

      System.find_executable("node") == nil ->
        Mix.shell().info("[skip] node not found — skipping test/js")

      true ->
        {output, status} = System.cmd("node", ["--test" | files], stderr_to_stdout: true)
        IO.puts(output)
        if status != 0, do: Mix.raise("JS tests failed")
    end
  end
end
