import Config

# Configure PhoenixKit application
config :phoenix_kit,
  ecto_repos: [],
  # Required for standalone development - ensures Storage.root_path() resolves correctly
  parent_app_name: :phoenix_kit,
  parent_module: PhoenixKit,
  url_prefix: "/phoenix_kit",
  comment_resource_handlers: %{
    "post" => PhoenixKit.Modules.Posts
  }

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

# Note: Hammer rate limiting configuration is automatically added to parent
# applications via mix phoenix_kit.install/update tasks
# For standalone development, configure Hammer here:
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}

# Configure Ueberauth (minimal configuration for compilation)
# Applications using PhoenixKit should configure their own providers
config :ueberauth, Ueberauth, providers: %{}

# Configure Oban (if using job processing)
config :phoenix_kit, Oban,
  repo: PhoenixKit.Repo,
  queues: [default: 10, emails: 50, file_processing: 20, posts: 10],
  plugins: [
    # Keep completed/cancelled/discarded jobs for 30 days for dashboard visibility
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker},
       sitemap: 5,
       sqs_polling: 1,
       sync: 5,
       shop_imports: 2
     ]}
  ]

# Configure Logger metadata
config :logger, :console,
  metadata: [
    :group_slug,
    :identifier,
    :reason,
    :language,
    :user_agent,
    :path,
    :group,
    :pattern,
    :content_size,
    :error
  ]

config :esbuild, :version, "0.25.0"
config :tailwind, :version, "4.1.12"

# For development/testing with real SMTP (when available)
# config :phoenix_kit, PhoenixKit.Mailer,
#   adapter: Swoosh.Adapters.SMTP,
#   relay: "smtp.gmail.com",
#   port: 587,
#   username: System.get_env("SMTP_USERNAME"),
#   password: System.get_env("SMTP_PASSWORD"),
#   tls: :if_available,
#   retries: 1

# Import environment-specific config
# This allows config/test.exs to override settings for test environment
if File.exists?("#{__DIR__}/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
