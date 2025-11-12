import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Load environment variables from .env files in dev/test
# Production should use system environment variables directly
if config_env() in [:dev, :test] do
  Dotenvy.source!([
    ".env." <> Atom.to_string(config_env()),
    ".env",
    System.get_env()
  ])
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/alive start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if Dotenvy.env!("PHX_SERVER", :boolean, false) do
  config :alive, AliveWeb.Endpoint, server: true
end

# Development configuration
if config_env() == :dev do
  config :alive, Alive.Repo,
    username: Dotenvy.env!("DB_USERNAME", :string, "postgres"),
    password: Dotenvy.env!("DB_PASSWORD", :string, "postgres"),
    hostname: Dotenvy.env!("DB_HOSTNAME", :string, "localhost"),
    database: Dotenvy.env!("DB_DATABASE", :string, "alive_dev"),
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: Dotenvy.env!("DB_POOL_SIZE", :integer, 10)

  config :alive, AliveWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: Dotenvy.env!("PORT", :integer, 4000)],
    check_origin: false,
    code_reloader: true,
    debug_errors: true,
    secret_key_base: Dotenvy.env!("SECRET_KEY_BASE", :string!),
    watchers: [
      esbuild: {Esbuild, :install_and_run, [:alive, ~w(--sourcemap=inline --watch)]},
      tailwind: {Tailwind, :install_and_run, [:alive, ~w(--watch)]}
    ]

  config :alive, AliveWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"priv/gettext/.*(po)$",
        ~r"lib/alive_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$"
      ]
    ]

  config :alive, dev_routes: true
  config :logger, :default_formatter, format: "[$level] $message\n"
  config :phoenix, :stacktrace_depth, 20
  config :phoenix, :plug_init_mode, :runtime

  config :phoenix_live_view,
    debug_heex_annotations: true,
    debug_attributes: true,
    enable_expensive_runtime_checks: true

  config :swoosh, :api_client, false
end

# Test configuration
if config_env() == :test do
  config :phoenix_kit, repo: Alive.Repo

  config :alive, Alive.Repo,
    username: Dotenvy.env!("DB_USERNAME", :string, "postgres"),
    password: Dotenvy.env!("DB_PASSWORD", :string, "postgres"),
    hostname: Dotenvy.env!("DB_HOSTNAME", :string, "localhost"),
    database:
      Dotenvy.env!("DB_DATABASE", :string, "alive_test") <>
        (System.get_env("MIX_TEST_PARTITION") || ""),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2

  config :alive, AliveWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: Dotenvy.env!("PORT", :integer, 4002)],
    secret_key_base: Dotenvy.env!("SECRET_KEY_BASE", :string!),
    server: false

  config :alive, Alive.Mailer, adapter: Swoosh.Adapters.Test
  config :swoosh, :api_client, false
  config :logger, level: :warning
  config :phoenix, :plug_init_mode, :runtime

  config :phoenix_live_view,
    enable_expensive_runtime_checks: true
end

# Production configuration
if config_env() == :prod do
  database_url = Dotenvy.env!("DATABASE_URL", :string!)

  maybe_ipv6 = if Dotenvy.env!("ECTO_IPV6", :boolean, false), do: [:inet6], else: []

  config :alive, Alive.Repo,
    # ssl: true,
    url: database_url,
    pool_size: Dotenvy.env!("POOL_SIZE", :integer, 10),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base = Dotenvy.env!("SECRET_KEY_BASE", :string!)

  host = Dotenvy.env!("PHX_HOST", :string, "example.com")
  port = Dotenvy.env!("PORT", :integer, 4000)

  config :alive, :dns_cluster_query, Dotenvy.env!("DNS_CLUSTER_QUERY", :string?)

  config :alive, AliveWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :alive, AliveWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :alive, AliveWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :alive, Alive.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
