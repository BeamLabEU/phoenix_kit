# OAuth & Magic Link Setup

PhoenixKit ships optional authentication modules that integrate with the core user system. This
guide captures the configuration steps that used to live in `CLAUDE.md`.

## OAuth Authentication (V16+)

PhoenixKit uses **runtime configuration** to manage OAuth credentials via the database.
This approach provides dynamic updates without server restarts and secure credential storage.

### Quick Start (Recommended Method)

1. **Install PhoenixKit and run migrations:**

   ```bash
   mix phoenix_kit.install
   mix ecto.migrate
   ```

2. **Configure OAuth via Admin UI:**

   Navigate to `http://localhost:4000/phoenix_kit/admin/settings` and:
   - Enable "OAuth Authentication" (master switch)
   - Select providers to enable (Google, GitHub, Apple, Facebook)
   - Enter OAuth credentials for each provider
   - Save changes - **configuration applies immediately without restart**

3. **That's it!** OAuth login buttons appear automatically on `/users/log_in`

### How Runtime Configuration Works

PhoenixKit loads OAuth credentials from the database during application startup:

1. **OAuthConfigLoader** starts as part of `PhoenixKit.Supervisor`
2. Reads credentials from `phoenix_kit_settings` table
3. Configures Ueberauth dynamically via `Application.put_env/3`
4. Updates configuration when credentials change via admin UI

**Benefits:**
- ✅ No server restart required for credential changes
- ✅ Credentials stored securely in database, not in code
- ✅ Per-provider enable/disable controls
- ✅ Built-in admin UI for credential management
- ✅ No manual `config.exs` editing required

### Alternative: Static Configuration (Legacy)

If you prefer environment variables or need static configuration, you can configure
providers in `config/config.exs`:

> ⚠️ **Note:** This approach requires server restart for credential changes and cannot
> be managed via the admin UI. Use runtime configuration (above) unless you have
> specific requirements for static config.

```elixir
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, []},
    apple: {Ueberauth.Strategy.Apple, []},
    github: {Ueberauth.Strategy.Github, []}
  ]

config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
  client_id: System.get_env("APPLE_CLIENT_ID"),
  team_id: System.get_env("APPLE_TEAM_ID"),
  key_id: System.get_env("APPLE_KEY_ID"),
  private_key: System.get_env("APPLE_PRIVATE_KEY")

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET")
```

Then provide credentials via environment variables:

```bash
export GOOGLE_CLIENT_ID="your-google-client-id"
export GOOGLE_CLIENT_SECRET="your-google-client-secret"
export APPLE_CLIENT_ID="com.yourapp.service"
export APPLE_TEAM_ID="your-apple-team-id"
export APPLE_KEY_ID="your-apple-key-id"
export APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n..."
export GITHUB_CLIENT_ID="your-github-client-id"
export GITHUB_CLIENT_SECRET="your-github-client-secret"
```

### OAuth Features

- Runtime enable/disable via settings (`oauth_enabled`)
- Google, Apple, GitHub, and Facebook sign-in out of the box
- Automatic account linking by email
- Provider management per user with audit trail
- Routes exposed at `{prefix}/users/auth/:provider`
- Referral code passthrough (`?referral_code=ABC123`)
- Buttons automatically hide when OAuth is disabled
- Built-in setup instructions in admin UI

### Reverse Proxy Configuration

When deploying behind a reverse proxy (nginx/apache) that terminates SSL, PhoenixKit automatically
detects HTTPS via `X-Forwarded-Proto` header. Configure your proxy:

**Nginx:**

```nginx
location / {
    proxy_pass http://localhost:4000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;  # Required for OAuth
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

**Apache:**

```apache
<VirtualHost *:443>
    ProxyPass / http://localhost:4000/
    ProxyPassReverse / http://localhost:4000/
    RequestHeader set X-Forwarded-Proto "https"
</VirtualHost>
```

**Manual override (if needed):**

```elixir
# config/runtime.exs
config :phoenix_kit,
  oauth_base_url: System.get_env("OAUTH_BASE_URL") || "https://example.com"
```

## Magic Link Registration (V16+)

Magic Link registration provides a two-step passwordless onboarding flow.

1. Configure the expiry window in `config/config.exs`:

   ```elixir
   config :phoenix_kit,
     magic_link_for_login_expiry_minutes: 15,
     magic_link_for_registration_expiry_minutes: 30
   ```

2. Ensure email delivery is configured (see `lib/phoenix_kit_web/live/modules/emails/README.md`).

### Magic Link Features

- Two-phase registration with email verification
- Referral code support end-to-end
- Completion routes at `{prefix}/users/register/complete/:token`
- Fully integrated with PhoenixKit's authentication contexts
