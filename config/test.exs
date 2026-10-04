import Config

# Configure test environment for PhoenixKit
# This file is imported by config.exs when Mix.env() == :test

# Configure test database - embedded test repo for library-level integration tests
config :phoenix_kit, ecto_repos: [PhoenixKit.Test.Repo]

# `PGDATABASE`/`PGPOOL` let you point the suite at a database you already have
# instead of one this role is allowed to CREATE — without them the only way to
# run the integration half is a Postgres account with CREATEDB, which is
# exactly what a shared or managed instance withholds. Defaults are unchanged,
# so `mix test` against a local Postgres behaves as before.
#
# Read through these two helpers rather than `System.get_env/2`, which falls
# back only when the variable is UNSET: a set-but-empty `PGPOOL=` (trivial to
# produce from a shell, or from `PGPOOL:` with no value in YAML) yields "" and
# would abort config loading with an ArgumentError that never names the
# variable.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit, PhoenixKit.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool,
  priv: "test/support/postgres"

# Wire repo for library code that calls PhoenixKit.Config.get(:repo)
config :phoenix_kit, repo: PhoenixKit.Test.Repo

# Configure test mailer - use Local adapter for test environment
config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Test

# Disable Swoosh API client as it is only required for production adapters
config :swoosh, :api_client, false

# Configure Hammer rate limiting for tests
# Use test-friendly limits that match test expectations
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  login_limit: 5,
  login_window_ms: 60_000,
  magic_link_limit: 3,
  magic_link_window_ms: 300_000,
  password_reset_limit: 3,
  password_reset_window_ms: 300_000,
  registration_limit: 3,
  registration_window_ms: 3_600_000,
  registration_ip_limit: 10,
  registration_ip_window_ms: 3_600_000,
  # The site-wide caps are off here. They are one counter shared by the whole
  # run — every test that touches a mail endpoint spends from it, so leaving
  # them on would couple unrelated test files to each other and fail whichever
  # one happened to run 300th. The tests that cover the caps switch them on
  # for themselves.
  magic_link_global_limit: nil,
  password_reset_global_limit: nil,
  confirmation_resend_global_limit: nil

# Configure session fingerprinting for tests
config :phoenix_kit,
  session_fingerprint_enabled: true,
  session_fingerprint_strict: false

# Configure logger for tests
config :logger, level: :warning

# Configure endpoint for LiveView tests (server: false — no HTTP server, just session signing)
# `render_errors` points at `PhoenixKitWeb.ErrorHTML` (the actual error
# module — the lib has it, prod is fine, but Phoenix's default fallback
# is `<EndpointBase>ErrorView` which doesn't exist here). Without this,
# any 500-class crash inside a LiveView mount surfaces as
# `** (ArgumentError) no "500" html template defined for PhoenixKitWeb.ErrorView`
# instead of the real underlying error, making test failures unactionable.
config :phoenix_kit, PhoenixKitWeb.Endpoint,
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_kit_tests_only",
  server: false,
  # Point at the PubSub instance `test_helper.exs` already starts (before the
  # endpoint), so `endpoint.broadcast/3` works here. Without it every
  # force-logout logged "Failed to broadcast disconnect: no :pubsub_server
  # configured" — noise that also meant no test could observe a disconnect,
  # which is how a broken endpoint resolver survived in the first place.
  pubsub_server: :phoenix_kit_internal_pubsub,
  live_view: [signing_salt: "phoenix_kit_test_live_view_salt_64bytes"],
  render_errors: [
    formats: [html: PhoenixKitWeb.ErrorHTML],
    layout: false
  ]

# Job kinds that exist only for the suite (`test/support/job_test_kinds.ex`).
config :phoenix_kit,
  job_kinds: [
    PhoenixKit.Test.JobKinds.Counter,
    PhoenixKit.Test.JobKinds.Restarting,
    PhoenixKit.Test.JobKinds.Guarded,
    PhoenixKit.Test.JobKinds.Short
  ]
