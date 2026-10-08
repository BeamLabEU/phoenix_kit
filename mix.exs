defmodule PhoenixKit.MixProject do
  use Mix.Project

  @version "2.57.0"
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
      #
      # 0.2.2 is the floor: email bodies in Markdown and layout groups need the
      # `markdown` and `layout` parts, the preview needs `Overrides.locate/4` and
      # `Templates.sources/3`, and a subject must arrive as one line. (0.2.1
      # was the first to find the `_layout`/`_header`/`_footer` names.)
      local_dep(:phoenix_kit_templates, "~> 0.2.2"),

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
      {:phoenix_live_reload, "~> 1.7", only: :dev},

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

      # libvips bindings (precompiled libvips, nothing to install). Optional: core
      # uses it only to find where the subject of a photo is, for renditions that
      # crop around it (`Storage.FocalPoint`); without it they crop at the center.
      # A host that wants the detection adds `{:vix, "~> 0.42"}` itself.
      {:vix, "~> 0.42", optional: true},

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
      #
      # :etcher's FLOOR is load-bearing too, not just its ceiling: core's own
      # markup passes `panel_offset` (0.13.2) and `connectors={:off}`
      # (0.12.2), phoenix_kit.js bridges `etcher:tooltip-action` (0.13.0),
      # and the media viewer's toolbar offers the `:highlighter` and `:arrow`
      # tools (0.14.0). 0.15 is where a thickness stopped meaning document
      # pixels and started meaning a weight against the canvas, so an older
      # Etcher renders a host's saved line params at a different weight on
      # every image — a floor, not a preference. 0.16 adds `tooltip_dock`,
      # which the media viewer passes as `:panel` to move a shape's actions
      # off the picture and into the style panel: on an older Etcher that
      # attr does not exist, so the tooltips land back over the drawing.
      # 0.17 is where the server-side renderer caught up with the canvas:
      # `Etcher.Raster` bakes a dimension's heads, every kind's label (sized
      # against `:canvas_width` / `:canvas_height`, which `AnnotationThumbnail`
      # passes and 0.16 ignores) and `style.fill`. On 0.16 a baked thumbnail
      # is a board of anonymous hollow shapes with a bare line where a
      # measurement should be — a floor, because core passes those opts and
      # relies on what they do. An older Etcher compiles
      # with an undeclared-attr warning and silently drops them — and a host
      # whose lock already holds an older etcher keeps it through
      # `mix deps.update phoenix_kit` if the floor still admits it. Raise the
      # floor whenever core starts consuming a newer Etcher API.
      #
      # 0.18 is live drawing — `onDrawing` / `applyDrawing` /
      # `applyDrawingEnd`, so a peer watches a stroke appear rather than
      # waiting for it — and the phone round: two fingers pan and pinch
      # whatever tool is in hand, a slow stroke no longer raises the iOS
      # selection bar, a tap places its dot, a new text box takes the caret
      # (and no longer zooms the page out of reach), and the style panel
      # stops vanishing behind the grabber a board opens with. Core does not
      # call the new API — `phoenix_kit_boards` does — but the bundle this
      # file pins is the one every host's browser loads, so the pin moves
      # with the package. The two-finger work needs fresco ≥ 0.13.1, which
      # counts a claimed finger so the second one has something to pinch
      # against; older fresco simply keeps the old single-pointer reading.
      #
      # 0.19 is a floor because the media viewer's toolbar now lists the
      # `:textbox` tool (a fixed box the text wraps and sizes inside). An
      # older Etcher has no TOOL_DEFS entry for the key, filters it out of
      # the toolbar without a warning, and the tool the host offered is
      # simply not there. It also brings same-tool editing — the shapes a
      # tool draws stay grabbable while it is armed — which the viewer's
      # eye/pencil flows assume.
      #
      # Etcher 0.14's out-of-bounds pan/zoom features engage on fresco
      # ≥ 0.12 (isInfiniteCanvas / getZoomFloor on the outer handles) and
      # quietly stand down on older — hence the new fresco alternative.
      #
      # 0.13 reads a wheel event as the three gestures it can be — a notch
      # zooms, two fingers on a trackpad move the view, a pinch zooms —
      # and, the part that makes it a floor for anyone on a laptop, it
      # converts deltas that arrive in LINES (plenty of mice, and Firefox)
      # into the pixels every rate is priced in. On 0.12 that hardware
      # bought 0.9% of zoom a notch instead of 20%, and moved the picture
      # six pixels when it panned — a viewer that reads as broken rather
      # than as slow. Older fresco is still admitted for hosts that pin
      # one; they keep the old reading.
      {:fresco, "~> 0.10.0 or ~> 0.11.0 or ~> 0.12.0 or ~> 0.13.0"},
      {:tessera, "~> 0.3.0"},
      {:etcher, "~> 0.19.0"},

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
      # Direct HTTP for Storage.RemoteFetch: it must connect to the address it
      # checked (Mint's :hostname), which a pooled client cannot promise.
      {:mint, "~> 1.6"},

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
      files: ~w(lib priv mix.exs README.md LICENSE CHANGELOG.md),
      # `files` takes whatever is on disk under priv/, gitignored or not, and
      # the sitemap generator writes into priv/static — so a checkout whose
      # test suite had run shipped the domain-mode test's
      # priv/static/sitemaps/domains/site.example.com/sitemap.xml in 2.34.0,
      # and a fresh install served it at /sitemap.xml until regenerated.
      # Generated sitemaps and uploaded media are runtime state, never package
      # content. Storage tests write into priv/media too; gitignore does not
      # keep those files out of a Hex package.
      exclude_patterns: [
        ~r"^priv/static/sitemap\.xml$",
        ~r"^priv/static/sitemaps/",
        ~r"^priv/media(?:/|$)"
      ]
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
        "guides/locale-routing.md",
        "guides/per-module-i18n.md",
        "guides/email-templates.md",
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
      #
      # `test.compile` below is not that step reappearing under a new name —
      # it compiles the test tree and runs zero tests, so none of the three
      # reasons above apply: no DB read, no pool, and it cannot go red from
      # environment (only from a genuine compile error in test/).
      precommit: [
        "compile --warnings-as-errors --all-warnings",
        "deps.unlock --check-unused",
        "test.compile",
        "quality.ci",
        "test.js"
      ],

      # Nothing above ever COMPILES test/**/*_test.exs: `format` and `credo`
      # only parse them, and `compile`/`dialyzer` see elixirc_paths(:test),
      # which covers test/support (plain .ex, picked up by the ordinary
      # compiler) but not the *_test.exs files themselves — ExUnit is the
      # only thing that ever compiles .exs test files, only when `mix test`
      # requires them. So a test file that is valid syntax but fails to
      # compile (e.g. two identical `describe` blocks — ExUnit rejects a
      # duplicate describe name with ArgumentError at defmodule-time, before
      # any test runs) was invisible to every existing gate step. Warnings
      # from those files are printed, not fatal — same as under `mix test`.
      # This compiles every test/**/*_test.exs directly, deliberately WITHOUT
      # test_helper.exs — no ExUnit.start, no DB probe, no migration — so it
      # cannot inherit the DB-availability problems `mix test` itself has
      # (see NOTE above). It needs MIX_ENV=test for elixirc_paths' test/support
      # half, which the surrounding precommit run doesn't set — env is fixed
      # for the whole aliased run once the VM boots (same reason `prerelease`
      # below shells out for its own MIX_ENV=prod step) — so this shells out
      # too, via System.cmd's `env:` option rather than `mix cmd`'s
      # shell-string form: no shell involved, so the embedded script needs no
      # quoting.
      "test.compile": &compile_test_tree/1,

      # Pure logic inside the shipped hook bundle (test/js, node --test). Skips
      # itself when node isn't installed rather than failing a contributor's
      # precommit over an optional tool.
      "test.js": &run_js_tests/1,

      # Removes accumulated `mix hex.build` / `mix hex.publish` tarballs.
      # Runs as the last prerelease step; run it by hand after a bare
      # `mix hex.publish`, which also leaves one behind.
      "package.clean": &clean_package_artifacts/1,

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
        "phoenix_kit.release_check",
        # `hex.build` writes <app>-<version>.tar into the project root and
        # never cleans up, so every release since Jun 2026 left one behind —
        # 64 tarballs / 199 MB by Sep 2026. The gate only needs hex.build to
        # PROVE the package assembles; the artifact itself is disposable
        # (`hex.publish` builds its own). Clean last so a failed step leaves
        # the tarball around to inspect.
        "package.clean"
      ]
    ]
  end

  # Compiles every test/**/*_test.exs in a MIX_ENV=test subprocess — see the
  # "test.compile" alias comment above for why this exists and why it's a
  # subprocess. `Kernel.ParallelCompiler.compile/1` has no bang variant: it
  # returns `{:error, ...}` on a bad file rather than raising, so the halt
  # below is load-bearing, not decoration.
  @compile_test_tree_script ~S"""
  files = Path.wildcard("test/**/*_test.exs")

  case Kernel.ParallelCompiler.compile(files, return_diagnostics: true) do
    {:ok, _modules, _warnings} ->
      :ok

    {:error, errors, _warnings} ->
      # One diagnostic per error, several per broken file: count the files.
      files = errors |> Enum.map(&Map.get(&1, :file)) |> Enum.uniq() |> length()
      IO.puts(:stderr, "\n#{files} test file(s) failed to compile.")
      System.halt(1)
  end
  """

  defp compile_test_tree(_args) do
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", @compile_test_tree_script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    IO.puts(output)
    if status != 0, do: Mix.raise("test suite failed to compile")
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

  # Deletes Hex package tarballs from the project root. Globs on the app name
  # rather than the current @version so tarballs left by EARLIER versions get
  # swept too — that accumulation is the whole reason this exists.
  defp clean_package_artifacts(_args) do
    app = to_string(Mix.Project.config()[:app])

    case Path.wildcard("#{app}-*.tar") do
      [] ->
        Mix.shell().info("[package.clean] no tarballs to remove")

      files ->
        bytes = files |> Enum.map(fn f -> File.stat!(f).size end) |> Enum.sum()
        Enum.each(files, &File.rm!/1)

        Mix.shell().info(
          "[package.clean] removed #{length(files)} tarball(s), " <>
            "#{Float.round(bytes / 1_048_576, 1)} MB"
        )
    end
  end
end
