import Config

# Configure PhoenixKit application
config :phoenix_kit,
  ecto_repos: []

# Configure test mailer
config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Local

# Configure Ueberauth (minimal configuration for compilation)
# Applications using PhoenixKit should configure their own providers
config :ueberauth, Ueberauth, providers: []

# Configure Logger metadata
config :logger, :console,
  metadata: [
    :blog_slug,
    :identifier,
    :reason,
    :language,
    :user_agent,
    :path,
    :blog,
    :pattern,
    :content_size
  ]

# For development/testing with real SMTP (when available)
# config :phoenix_kit, PhoenixKit.Mailer,
#   adapter: Swoosh.Adapters.SMTP,
#   relay: "smtp.gmail.com",
#   port: 587,
#   username: System.get_env("SMTP_USERNAME"),
#   password: System.get_env("SMTP_PASSWORD"),
#   tls: :if_available,
#   retries: 1
