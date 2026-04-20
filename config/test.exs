import Config

# Configure test environment for PhoenixKit
# This file is imported by config.exs when Mix.env() == :test

# Configure test database - embedded test repo for library-level integration tests
config :phoenix_kit, ecto_repos: [PhoenixKit.Test.Repo]

config :phoenix_kit, PhoenixKit.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
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
  registration_ip_window_ms: 3_600_000

# Configure session fingerprinting for tests
config :phoenix_kit,
  session_fingerprint_enabled: true,
  session_fingerprint_strict: false

# Configure logger for tests
config :logger, level: :warning

# Configure endpoint for LiveView tests (server: false — no HTTP server, just session signing)
config :phoenix_kit, PhoenixKitWeb.Endpoint,
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_kit_tests_only",
  server: false

# Suppress esbuild/tailwind warnings in tests (library doesn't include these apps)
config :esbuild, :version, nil
config :tailwind, :version, nil
