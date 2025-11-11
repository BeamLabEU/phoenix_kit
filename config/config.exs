import Config

# Configure PhoenixKit application
config :phoenix_kit,
  ecto_repos: []

# Configure password requirements (optional - these are the defaults)
# Uncomment and modify to enforce specific password strength requirements
# config :phoenix_kit, :password_requirements,
#   min_length: 8,            # Minimum password length (default: 8)
#   max_length: 72,           # Maximum password length (default: 72, bcrypt limit)
#   require_uppercase: false, # Require at least one uppercase letter (default: false)
#   require_lowercase: false, # Require at least one lowercase letter (default: false)
#   require_digit: false,     # Require at least one digit (default: false)
#   require_special: false    # Require at least one special character (!?@#$%^&*_) (default: false)

# Configure test mailer
config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Local

# Configure rate limiting with Hammer
config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       # Cleanup expired rate limit buckets every 60 seconds
       expiry_ms: 60_000,
       # Cleanup interval (1 minute)
       cleanup_interval_ms: 60_000
     ]}

# Configure rate limits for authentication endpoints
# These are sensible defaults - adjust based on your application's needs
config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  # Login: 5 attempts per minute per email
  login_limit: 5,
  login_window_ms: 60_000,
  # Magic link: 3 requests per 5 minutes per email
  magic_link_limit: 3,
  magic_link_window_ms: 300_000,
  # Password reset: 3 requests per 5 minutes per email
  password_reset_limit: 3,
  password_reset_window_ms: 300_000,
  # Registration: 3 attempts per hour per email
  registration_limit: 3,
  registration_window_ms: 3_600_000,
  # Registration IP: 10 attempts per hour per IP
  registration_ip_limit: 10,
  registration_ip_window_ms: 3_600_000

# Configure Ueberauth (minimal configuration for compilation)
# Applications using PhoenixKit should configure their own providers
config :ueberauth, Ueberauth, providers: []

# Configure Oban (if using job processing)
config :phoenix_kit, Oban,
  repo: PhoenixKit.Repo,
  queues: [default: 10, emails: 50, file_processing: 20],
  plugins: [Oban.Plugins.Pruner, {Oban.Plugins.Cron, crontab: []}]

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
