import Config

# Configure test environment for PhoenixKit
# This file is imported by config.exs when Mix.env() == :test

# Configure test database (when PhoenixKit is used in parent applications)
# Parent apps should configure their own test repo here
# config :phoenix_kit,
#   repo: MyApp.Repo

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

# Future: Configure FakeSettings when publishing tests are implemented
# config :phoenix_kit,
#   publishing_settings_module: PhoenixKit.Test.FakeSettings

# Configure logger for tests
config :logger, level: :warning
