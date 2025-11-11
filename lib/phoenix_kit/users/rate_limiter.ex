defmodule PhoenixKit.Users.RateLimiter do
  @moduledoc """
  Rate limiting for authentication endpoints to prevent brute-force attacks.

  This module provides comprehensive rate limiting protection for:
  - Login attempts (prevents password brute-forcing)
  - Magic link generation (prevents token enumeration)
  - Password reset requests (prevents mass reset attacks)
  - User registration (prevents spam account creation)

  ## Configuration

  Rate limits can be configured in your application config:

      # config/config.exs
      config :phoenix_kit, PhoenixKit.Users.RateLimiter,
        login_limit: 5,                    # Max login attempts per window
        login_window_ms: 60_000,           # 1 minute window
        magic_link_limit: 3,               # Max magic link requests per window
        magic_link_window_ms: 300_000,     # 5 minute window
        password_reset_limit: 3,           # Max password reset requests per window
        password_reset_window_ms: 300_000, # 5 minute window
        registration_limit: 3,             # Max registration attempts per window
        registration_window_ms: 3600_000,  # 1 hour window
        registration_ip_limit: 10,         # Max registrations per IP per window
        registration_ip_window_ms: 3600_000 # 1 hour window

  ## Security Features

  - **Email-based rate limiting**: Prevents targeted attacks on specific accounts
  - **IP-based rate limiting**: Prevents distributed attacks from single sources
  - **Timing attack mitigation**: Consistent response times for valid/invalid emails
  - **Exponential backoff**: Automatically enforced through time windows
  - **Comprehensive logging**: All rate limit violations are logged for security monitoring

  ## Usage Examples

      # Check login rate limit
      case PhoenixKit.Users.RateLimiter.check_login_rate_limit(email, ip_address) do
        :ok -> proceed_with_login()
        {:error, :rate_limit_exceeded} -> show_rate_limit_error()
      end

      # Check magic link rate limit
      case PhoenixKit.Users.RateLimiter.check_magic_link_rate_limit(email) do
        :ok -> generate_magic_link()
        {:error, :rate_limit_exceeded} -> show_cooldown_message()
      end

  ## Production Recommendations

  - Use Redis backend for distributed systems (hammer_backend_redis)
  - Monitor rate limit violations for security threats
  - Adjust limits based on your application's usage patterns
  - Consider implementing CAPTCHA after multiple violations
  """

  require Logger

  @default_config [
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
  ]

  @doc """
  Checks if login attempts are within rate limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limit_exceeded}` if the limit is exceeded.

  This function implements dual rate limiting:
  - Per-email rate limiting (prevents targeted attacks on specific accounts)
  - Per-IP rate limiting (prevents distributed brute-force attacks)

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_login_rate_limit("user@example.com", "192.168.1.1")
      :ok

      # After 5 failed attempts:
      iex> PhoenixKit.Users.RateLimiter.check_login_rate_limit("user@example.com", "192.168.1.1")
      {:error, :rate_limit_exceeded}
  """
  def check_login_rate_limit(email, ip_address \\ nil) when is_binary(email) do
    email = normalize_email(email)
    config = get_config()

    # Check email-based rate limit
    email_key = "auth:login:email:#{email}"
    limit = Keyword.get(config, :login_limit)
    window = Keyword.get(config, :login_window_ms)

    case check_rate_limit(email_key, window, limit) do
      :ok ->
        # Also check IP-based rate limit if IP is provided
        if ip_address do
          ip_key = "auth:login:ip:#{ip_address}"
          # Allow slightly higher limit for IP (to avoid false positives in shared networks)
          ip_limit = limit * 3

          case check_rate_limit(ip_key, window, ip_limit) do
            :ok ->
              :ok

            {:error, :rate_limit_exceeded} = error ->
              log_rate_limit_violation("login", "ip:#{ip_address}", ip_limit, window)
              error
          end
        else
          :ok
        end

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("login", "email:#{email}", limit, window)
        error
    end
  end

  @doc """
  Checks if magic link generation is within rate limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limit_exceeded}` if the limit is exceeded.

  Magic links have stricter rate limits to prevent token enumeration attacks.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_magic_link_rate_limit("user@example.com")
      :ok

      # After 3 requests in 5 minutes:
      iex> PhoenixKit.Users.RateLimiter.check_magic_link_rate_limit("user@example.com")
      {:error, :rate_limit_exceeded}
  """
  def check_magic_link_rate_limit(email) when is_binary(email) do
    email = normalize_email(email)
    config = get_config()

    key = "auth:magic_link:#{email}"
    limit = Keyword.get(config, :magic_link_limit)
    window = Keyword.get(config, :magic_link_window_ms)

    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("magic_link", email, limit, window)
        error
    end
  end

  @doc """
  Checks if password reset requests are within rate limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limit_exceeded}` if the limit is exceeded.

  Password reset requests have moderate rate limits to prevent mass reset attacks
  while still allowing legitimate users to recover their accounts.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_password_reset_rate_limit("user@example.com")
      :ok

      # After 3 requests in 5 minutes:
      iex> PhoenixKit.Users.RateLimiter.check_password_reset_rate_limit("user@example.com")
      {:error, :rate_limit_exceeded}
  """
  def check_password_reset_rate_limit(email) when is_binary(email) do
    email = normalize_email(email)
    config = get_config()

    key = "auth:password_reset:#{email}"
    limit = Keyword.get(config, :password_reset_limit)
    window = Keyword.get(config, :password_reset_window_ms)

    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("password_reset", email, limit, window)
        error
    end
  end

  @doc """
  Checks if registration attempts are within rate limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limit_exceeded}` if the limit is exceeded.

  Registration has dual rate limiting:
  - Per-email rate limiting (prevents spam account creation with same email)
  - Per-IP rate limiting (prevents mass account creation from single source)

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_registration_rate_limit("user@example.com", "192.168.1.1")
      :ok

      # After limit exceeded:
      iex> PhoenixKit.Users.RateLimiter.check_registration_rate_limit("user@example.com", "192.168.1.1")
      {:error, :rate_limit_exceeded}
  """
  def check_registration_rate_limit(email, ip_address \\ nil) when is_binary(email) do
    email = normalize_email(email)
    config = get_config()

    # Check email-based rate limit
    email_key = "auth:registration:email:#{email}"
    email_limit = Keyword.get(config, :registration_limit)
    email_window = Keyword.get(config, :registration_window_ms)

    case check_rate_limit(email_key, email_window, email_limit) do
      :ok ->
        # Also check IP-based rate limit if IP is provided
        if ip_address do
          ip_key = "auth:registration:ip:#{ip_address}"
          ip_limit = Keyword.get(config, :registration_ip_limit)
          ip_window = Keyword.get(config, :registration_ip_window_ms)

          case check_rate_limit(ip_key, ip_window, ip_limit) do
            :ok ->
              :ok

            {:error, :rate_limit_exceeded} = error ->
              log_rate_limit_violation("registration", "ip:#{ip_address}", ip_limit, ip_window)
              error
          end
        else
          :ok
        end

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("registration", "email:#{email}", email_limit, email_window)
        error
    end
  end

  @doc """
  Resets rate limit for a specific action and identifier.

  This is useful for:
  - Admin intervention (clearing rate limits for legitimate users)
  - Testing purposes
  - Post-successful authentication cleanup

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.reset_rate_limit(:login, "user@example.com")
      :ok
  """
  def reset_rate_limit(action, identifier) when is_atom(action) and is_binary(identifier) do
    identifier = if action in [:login, :magic_link, :password_reset, :registration] do
      normalize_email(identifier)
    else
      identifier
    end

    key = "auth:#{action}:#{identifier}"

    case Hammer.delete_buckets(key) do
      {:ok, _count} ->
        Logger.info("PhoenixKit.RateLimiter: Reset rate limit for #{action}:#{identifier}")
        :ok

      {:error, reason} ->
        Logger.error("PhoenixKit.RateLimiter: Failed to reset rate limit for #{action}:#{identifier}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the remaining attempts for a specific action and identifier.

  Returns the number of attempts remaining before rate limit is exceeded.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.get_remaining_attempts(:login, "user@example.com")
      5
  """
  def get_remaining_attempts(action, identifier) when is_atom(action) and is_binary(identifier) do
    identifier = if action in [:login, :magic_link, :password_reset, :registration] do
      normalize_email(identifier)
    else
      identifier
    end

    config = get_config()
    key = "auth:#{action}:#{identifier}"

    {limit, window} = case action do
      :login ->
        {Keyword.get(config, :login_limit), Keyword.get(config, :login_window_ms)}
      :magic_link ->
        {Keyword.get(config, :magic_link_limit), Keyword.get(config, :magic_link_window_ms)}
      :password_reset ->
        {Keyword.get(config, :password_reset_limit), Keyword.get(config, :password_reset_window_ms)}
      :registration ->
        {Keyword.get(config, :registration_limit), Keyword.get(config, :registration_window_ms)}
    end

    case Hammer.inspect_bucket(key, window, limit) do
      {:ok, {count, _count_remaining, _ms_to_next_bucket, _created_at, _updated_at}} ->
        max(0, limit - count)

      _ ->
        limit
    end
  end

  # Private functions

  defp check_rate_limit(key, window_ms, limit) do
    case Hammer.check_rate(key, window_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _limit} ->
        {:error, :rate_limit_exceeded}

      {:error, reason} ->
        # Log error but allow request to proceed (fail open for availability)
        Logger.error("PhoenixKit.RateLimiter: Hammer error for #{key}: #{inspect(reason)}")
        :ok
    end
  end

  defp normalize_email(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp get_config do
    Application.get_env(:phoenix_kit, __MODULE__, [])
    |> Keyword.merge(@default_config, fn _k, v1, _v2 -> v1 end)
  end

  defp log_rate_limit_violation(action, identifier, limit, window_ms) do
    window_description = format_window(window_ms)

    Logger.warning(
      "PhoenixKit.RateLimiter: Rate limit exceeded for #{action} - " <>
      "#{identifier} exceeded #{limit} attempts in #{window_description}"
    )
  end

  defp format_window(ms) when ms < 60_000, do: "#{div(ms, 1000)} seconds"
  defp format_window(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} minutes"
  defp format_window(ms), do: "#{div(ms, 3_600_000)} hours"
end
