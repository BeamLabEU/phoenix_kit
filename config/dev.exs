import Config

# Configure your database
config :phoenix_kit, PhoenixKit.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: System.get_env("PGDATABASE") || "phoenix_kit_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Wire repos for PhoenixKit
config :phoenix_kit, ecto_repos: [PhoenixKit.Repo]
config :phoenix_kit, repo: PhoenixKit.Repo

# Configure PhoenixKit application settings
config :phoenix_kit,
  from_email: "noreply@example.com",
  from_name: "PhoenixKit Dev"

# Configure the endpoint
config :phoenix_kit, PhoenixKitWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "7Q2rUNupr3PuVzAP2uunpDRl84K0zTOrHMdr2rScUWuDSpO1vvzOyOxApy/3JSwZ",
  render_errors: [
    formats: [html: PhoenixKitWeb.ErrorHTML, json: PhoenixKitWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PhoenixKit.PubSub,
  live_view: [signing_salt: "vV7t8l8S"]

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development.
config :phoenix_kit, :stacktrace_depth, 20

# Initialize swoosh api client but don't send emails
config :swoosh, :api_client, false
