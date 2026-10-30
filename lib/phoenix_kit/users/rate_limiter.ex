defmodule PhoenixKit.Users.RateLimiter.Backend do
  @moduledoc """
  Hammer 7.x backend for rate limiting.
  """
  use Hammer, backend: :ets
end

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
        registration_ip_window_ms: 3600_000, # 1 hour window
        # The three mail-sending endpoints (magic_link, password_reset,
        # confirmation_resend) each take three buckets: per address, per IP,
        # and one site-wide cap on how many the install will send at all.
        password_reset_ip_limit: 10,
        password_reset_ip_window_ms: 300_000,
        password_reset_global_limit: 100,      # nil switches the cap off
        password_reset_global_window_ms: 3600_000

  ## Security Features

  - **Login buckets count FAILURES only**: `check_login_rate_limit/2` takes a
    slot atomically BEFORE the password is verified, and
    `record_successful_login/2` hands it back. Taking it up front is what
    bounds a parallel burst — a read-then-count-later check lets every request
    in the burst see an empty bucket. Handing it back is what keeps ordinary
    sign-ins from locking an account out.
  - **Email-based rate limiting**: Prevents targeted attacks on specific accounts
  - **IP-based rate limiting**: Prevents distributed attacks from single sources
    (an IPv6 address counts by its `/64` — see `PhoenixKit.Utils.IpAddress.network/1`)
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

  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKit.Utils.IpAddress

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
    # Confirmation resend: 3 requests per 5 minutes per email
    confirmation_resend_limit: 3,
    confirmation_resend_window_ms: 300_000,
    # Per-IP companions for the three endpoints above. Each one SENDS MAIL on
    # an unauthenticated request, and an address bucket alone cannot see a
    # spray: ten thousand addresses, one hit each, no bucket ever fires.
    # Comfortably above what one person behind a shared NAT would ever need —
    # their own address bucket caps them at 3 — and far below what makes
    # mailbox flooding, sender-reputation damage or quota exhaustion worthwhile.
    magic_link_ip_limit: 10,
    magic_link_ip_window_ms: 300_000,
    password_reset_ip_limit: 10,
    password_reset_ip_window_ms: 300_000,
    confirmation_resend_ip_limit: 10,
    confirmation_resend_ip_window_ms: 300_000,
    # Site-wide backstop for the same three endpoints: the total number of these
    # emails the install will send in an hour, no matter who asks or from where.
    # The address and IP buckets both assume the attacker is concentrated; a
    # botnet with a fresh address and a fresh IP per request defeats both, and
    # only this one bounds the mail bill.
    #
    # Deliberately generous, because a site-wide cap is the one limit an
    # attacker can turn against everybody else: every request it refuses is a
    # real user who cannot reset their password. Treat it as a circuit breaker
    # sized so normal traffic never approaches it — if it trips, either the
    # install is under attack or the number is wrong, and both want an operator
    # looking. Set to `nil` to switch off.
    #
    # RAISE IT before anything that sends a crowd to the forgot-password form
    # at once — a forced credential rotation, a migration off another auth
    # provider. That is the one legitimate way to hit this, and hitting it
    # means the people you just told to reset their password cannot.
    #
    # Counts accepted REQUESTS, not delivered mail: a request for an address
    # that turns out not to exist still spends one. The IP bucket above is what
    # keeps that cheap to abuse — draining this costs an attacker a fresh IP
    # every ten tries. Per node, like every bucket here (see the Hammer/Redis
    # note in the moduledoc), so a multi-node install caps per node.
    magic_link_global_limit: 300,
    magic_link_global_window_ms: 3_600_000,
    password_reset_global_limit: 300,
    password_reset_global_window_ms: 3_600_000,
    confirmation_resend_global_limit: 300,
    confirmation_resend_global_window_ms: 3_600_000,
    # Registration: 3 attempts per hour per email
    registration_limit: 3,
    registration_window_ms: 3_600_000,
    # Registration IP: 10 attempts per hour per IP
    registration_ip_limit: 10,
    registration_ip_window_ms: 3_600_000,
    # QR login request creation: 10 per minute per IP (pre-auth, no email to key on)
    qr_login_limit: 10,
    qr_login_window_ms: 60_000,
    manager_invitation_limit: 10,
    manager_invitation_window_ms: 60_000,
    organization_enter_limit: 30,
    organization_enter_window_ms: 60_000,
    # File upload: 30 per minute per account. The endpoint requires auth, so an
    # account is always available to key on; this bounds storage/queue abuse by
    # an authenticated user without impeding a normal media-browser session.
    upload_limit: 30,
    upload_window_ms: 60_000,
    # Referral code validation: 20 per minute per IP. Pre-auth and IP-only —
    # there is no account to key on, and the point is to stop an anonymous
    # visitor searching the code space. Generous enough that a real person
    # correcting a typo never notices.
    referral_validation_limit: 20,
    referral_validation_window_ms: 60_000,
    # Invite-only code redemption: 10 per 10 minutes per ACCOUNT. Tighter than
    # validation because this screen is post-login, so a fresh account is a
    # fresh IP-keyed bucket — the account limit is the one that actually bounds
    # how much of the code space a determined attacker can sweep.
    referral_redemption_limit: 10,
    referral_redemption_window_ms: 600_000,
    # Access requests from redacted mentions: 10 per 10 minutes per ACCOUNT.
    # The partial unique index already stops repeat asks for the *same*
    # resource; this caps how many distinct invented uuids one client can
    # spam into the activity feed / admin queue.
    access_request_limit: 10,
    access_request_window_ms: 600_000
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

    limit = Keyword.get(config, :login_limit)
    window = Keyword.get(config, :login_window_ms)

    # HIT, never peek: the slot is taken atomically, before the password is
    # verified. A peek here with the count added only after the (slow) verify
    # let a parallel burst through whole — every request read an empty bucket.
    # A successful sign-in hands its slot back (`record_successful_login/2`),
    # so only failures stay counted.
    #
    # IP first: a request refused for its network must not also spend a slot
    # in the bucket of whatever address it named, or one blocked client could
    # lock out any account it likes.
    with :ok <- hit_login_ip(ip_address, window, limit) do
      case check_rate_limit("auth:login:email:#{email}", window, limit) do
        :ok ->
          :ok

        {:error, :rate_limit_exceeded} = error ->
          log_rate_limit_violation("login", "email:#{email}", limit, window)
          error
      end
    end
  end

  defp hit_login_ip(nil, _window, _limit), do: :ok

  defp hit_login_ip(ip_address, window, limit) do
    ip = IpAddress.network(ip_address)
    # Allow slightly higher limit for IP (to avoid false positives in shared networks)
    ip_limit = limit * 3

    case check_rate_limit("auth:login:ip:#{ip}", window, ip_limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("login", "ip:#{ip}", ip_limit, window)
        error
    end
  end

  @doc """
  Hands back the slot `check_login_rate_limit/2` took, after the password
  turned out to be correct.

  The check has to count the attempt before the outcome is known — that is
  what makes it atomic — so a success gives its slot back here. Without this,
  five ordinary sign-ins inside the window would lock the account out of the
  sixth.

  Call it on the success branch only, with the same arguments the check got.
  A correct password — even for a deactivated account — is not a brute-force
  attempt.
  """
  @spec record_successful_login(String.t(), String.t() | nil) :: :ok
  def record_successful_login(email, ip_address \\ nil) when is_binary(email) do
    window = Keyword.get(get_config(), :login_window_ms)

    release_slot("auth:login:email:#{normalize_email(email)}", window)
    if ip_address, do: release_slot("auth:login:ip:#{IpAddress.network(ip_address)}", window)

    :ok
  end

  # One atomic decrement with a floor of zero. Hammer's `inc/3` is specified
  # for positive increments only, so the counter is reached the way Hammer's
  # own fixed-window algorithm reaches it (`Hammer.ETS.update_counter/4`, the
  # `{key, window}` row of the backend's table). The floor matters: a check
  # made just before the window rolled would otherwise open the new window at
  # -1 and grant it an extra attempt.
  #
  # Never raises into a sign-in that just succeeded. If a Hammer upgrade moves
  # that layout the slot simply is not handed back — the old "successful
  # logins are counted" behaviour, which `rate_limiter_test.exs` fails on.
  defp release_slot(key, window) do
    now = Hammer.ETS.now()
    bucket = div(now, window)

    Hammer.ETS.update_counter(Backend, {key, bucket}, {2, -1, 0, 0}, (bucket + 1) * window)
    :ok
  rescue
    error ->
      Logger.warning("PhoenixKit.RateLimiter: could not release a login slot: #{inspect(error)}")
      :ok
  end

  @doc false
  @deprecated "check_login_rate_limit/2 now counts the attempt itself; call record_successful_login/2 on success instead"
  @spec record_failed_login(String.t(), String.t() | nil) :: :ok
  def record_failed_login(email, _ip_address \\ nil) when is_binary(email), do: :ok

  @doc """
  Checks whether file uploads are within rate limit, keyed on the uploading
  account. `POST /api/upload` requires authentication (see
  `PhoenixKitWeb.UploadController.resolve_upload_user/2`), so there is always an
  account to key on; this bounds storage-exhaustion and Oban-queue abuse by an
  authenticated user.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_upload_rate_limit(user_uuid)
      :ok
  """
  def check_upload_rate_limit(user_uuid) when is_binary(user_uuid) do
    config = get_config()

    key = "storage:upload:#{user_uuid}"
    limit = Keyword.get(config, :upload_limit)
    window = Keyword.get(config, :upload_window_ms)

    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("upload", user_uuid, limit, window)
        error
    end
  end

  @doc """
  Checks if magic link generation is within rate limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limit_exceeded}` if the limit is exceeded.

  Guarded by all three buckets — address, IP and site-wide. See
  `check_mail_endpoint/3` for why the order they are charged in matters.
  Pass the caller's IP whenever one is known; omitting it leaves only the
  address and site-wide buckets, which cannot see a spray.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_magic_link_rate_limit("user@example.com", "192.168.1.1")
      :ok

      # After 3 requests in 5 minutes:
      iex> PhoenixKit.Users.RateLimiter.check_magic_link_rate_limit("user@example.com", "192.168.1.1")
      {:error, :rate_limit_exceeded}
  """
  def check_magic_link_rate_limit(email, ip_address \\ nil) when is_binary(email) do
    check_mail_endpoint("magic_link", email, ip_address)
  end

  @doc """
  Checks if confirmation-email resends are within rate limit.

  The resend form is public and unauthenticated: each accepted request inserts
  a token and sends mail, so without a limit it is both a targeted mail-flood
  vector and — because only existing unconfirmed accounts do that work — a
  measurable oracle for which addresses are registered but unconfirmed.

  Guarded by all three buckets — address, IP and site-wide. See
  `check_mail_endpoint/3`.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_confirmation_resend_rate_limit("user@example.com", "192.168.1.1")
      :ok
  """
  def check_confirmation_resend_rate_limit(email, ip_address \\ nil) when is_binary(email) do
    check_mail_endpoint("confirmation_resend", email, ip_address)
  end

  @doc """
  Checks if password reset requests are within rate limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limit_exceeded}` if the limit is exceeded.

  Password reset requests have moderate rate limits to prevent mass reset attacks
  while still allowing legitimate users to recover their accounts.

  Guarded by all three buckets — address, IP and site-wide. See
  `check_mail_endpoint/3`.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_password_reset_rate_limit("user@example.com", "192.168.1.1")
      :ok

      # After 3 requests in 5 minutes:
      iex> PhoenixKit.Users.RateLimiter.check_password_reset_rate_limit("user@example.com", "192.168.1.1")
      {:error, :rate_limit_exceeded}
  """
  def check_password_reset_rate_limit(email, ip_address \\ nil) when is_binary(email) do
    check_mail_endpoint("password_reset", email, ip_address)
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
          ip = IpAddress.network(ip_address)
          ip_key = "auth:registration:ip:#{ip}"
          ip_limit = Keyword.get(config, :registration_ip_limit)
          ip_window = Keyword.get(config, :registration_ip_window_ms)

          case check_rate_limit(ip_key, ip_window, ip_limit) do
            :ok ->
              :ok

            {:error, :rate_limit_exceeded} = error ->
              log_rate_limit_violation("registration", "ip:#{ip}", ip_limit, ip_window)
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
  Checks if QR device-handoff login request creation is within rate limit.

  Returns `:ok` if the request is allowed, or `{:error, :rate_limit_exceeded}` if the limit is
  exceeded. IP-only (the desktop page is pre-auth, so there's no email to key on) — this guards
  against an anonymous visitor repeatedly minting `keyfob` requests (each one a live ETS entry)
  by hammering the public `/users/qr-login` page.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_qr_login_rate_limit("192.168.1.1")
      :ok
  """
  def check_qr_login_rate_limit(ip_address) when is_binary(ip_address) do
    config = get_config()

    ip = IpAddress.network(ip_address)
    key = "auth:qr_login:ip:#{ip}"
    limit = Keyword.get(config, :qr_login_limit)
    window = Keyword.get(config, :qr_login_window_ms)

    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("qr_login", "ip:#{ip}", limit, window)
        error
    end
  end

  @doc """
  Checks if referral code validation attempts are within rate limit.

  Returns `:ok` if the attempt is allowed, or `{:error, :rate_limit_exceeded}` if
  the limit is exceeded. IP-only: the registration form is pre-auth, so there is
  no account to key on.

  This is what makes a referral code hard to guess. `Auth.register_user/2`'s
  limiter sits behind referral validation, so a wrong code short-circuits before
  reaching it — leaving code checking unthrottled unless it is limited here.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_referral_validation_rate_limit("192.168.1.1")
      :ok
  """
  def check_referral_validation_rate_limit(ip_address) when is_binary(ip_address) do
    config = get_config()

    ip = IpAddress.network(ip_address)
    key = "auth:referral_validation:ip:#{ip}"
    limit = Keyword.get(config, :referral_validation_limit)
    window = Keyword.get(config, :referral_validation_window_ms)

    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("referral_validation", "ip:#{ip}", limit, window)
        error
    end
  end

  # No IP available (an embedded mount, or a socket without peer data). Allowing
  # is deliberate: the alternative is locking out legitimate registrations on
  # hosts that do not thread peer data through, and the submit path still runs
  # `Auth.register_user/2`'s own limiter.
  def check_referral_validation_rate_limit(_), do: :ok

  @doc """
  Checks if a logged-in account's referral-code redemption attempts are within
  limit.

  Keyed on the account, not the IP: the invite-only screen sits *behind* login,
  so an attacker who can mint accounts gets a fresh IP-keyed bucket with every
  one. Without a per-account limit the screen is the same guessing oracle the
  registration form was, only cheaper to farm.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_referral_redemption_rate_limit("0193a5e4-0000-7000-8000-000000000001")
      :ok
  """
  def check_referral_redemption_rate_limit(user_uuid) when is_binary(user_uuid) do
    config = get_config()

    key = "auth:referral_redemption:user:#{user_uuid}"
    limit = Keyword.get(config, :referral_redemption_limit)
    window = Keyword.get(config, :referral_redemption_window_ms)

    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("referral_redemption", "user:#{user_uuid}", limit, window)
        error
    end
  end

  def check_referral_redemption_rate_limit(_), do: :ok

  @doc """
  Checks if a logged-in account's mention access-request submissions are
  within limit.

  Keyed on the account: the request path is post-login, and the partial
  unique index only bounds repeats for one resource. Without a per-account
  limit a client can invent distinct uuids and fill the activity feed one
  row at a time.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.check_access_request_rate_limit("0193a5e4-0000-7000-8000-000000000001")
      :ok
  """
  def check_access_request_rate_limit(user_uuid) when is_binary(user_uuid) do
    config = get_config()

    key = "mentions:access_request:user:#{user_uuid}"
    limit = Keyword.get(config, :access_request_limit)
    window = Keyword.get(config, :access_request_window_ms)

    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation("access_request", "user:#{user_uuid}", limit, window)
        error
    end
  end

  def check_access_request_rate_limit(_), do: :ok

  @doc "Limits manager invites, including duplicates, per acting person and organization."
  def check_manager_invitation_rate_limit(person_uuid, organization_uuid) do
    config = get_config()

    check_rate_limit(
      "organization:invite:#{person_uuid}:#{organization_uuid}",
      config[:manager_invitation_window_ms],
      config[:manager_invitation_limit]
    )
  end

  @doc "Limits all organization-entry attempts, including no-ops, per root account."
  def check_organization_enter_rate_limit(user_uuid) do
    config = get_config()

    check_rate_limit(
      "organization:enter:#{user_uuid}",
      config[:organization_enter_window_ms],
      config[:organization_enter_limit]
    )
  end

  @doc """
  Resets rate limit for a specific action and identifier.

  **DEPRECATED:** Hammer 7.x removed `delete_buckets` with no replacement.
  This function now returns an error as Backend.set/3 requires positive integers (cannot set to 0).

  Rate limits will naturally expire after their configured window period.

  ## Migration

  - **For testing**: Use `Application.put_env` to disable rate limiting
  - **For admin intervention**: Wait for the time window to expire
  - **For immediate reset**: Restart the application (clears ETS tables)

  See: https://hexdocs.pm/hammer/upgrade-v7.html

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.reset_rate_limit(:login, "email:user@example.com")
      {:error, :not_supported}
  """
  @deprecated "Hammer 7.x removed delete_buckets. Rate limits expire after their time window."
  def reset_rate_limit(_action, _identifier) do
    Logger.warning(
      "PhoenixKit.RateLimiter.reset_rate_limit/2 is deprecated. " <>
        "Rate limits expire automatically after their configured time window."
    )

    {:error, :not_supported}
  end

  @doc """
  Gets the remaining attempts for a specific action and identifier.

  Returns the number of attempts remaining before rate limit is exceeded.

  For login and registration actions, returns the email-based limit.
  For magic_link and password_reset, returns the limit for the email.

  Note: With Hammer 7.x, this uses the get/2 function to retrieve the current count.

  ## Examples

      iex> PhoenixKit.Users.RateLimiter.get_remaining_attempts(:login, "user@example.com")
      5

      iex> PhoenixKit.Users.RateLimiter.get_remaining_attempts(:magic_link, "user@example.com")
      3
  """
  def get_remaining_attempts(action, identifier) when is_atom(action) and is_binary(identifier) do
    identifier =
      if action in [:magic_link, :password_reset] do
        normalize_email(identifier)
      else
        # For login and registration, assume email identifier and add prefix
        "email:#{normalize_email(identifier)}"
      end

    config = get_config()
    key = "auth:#{action}:#{identifier}"

    {limit, window} =
      case action do
        :login ->
          {Keyword.get(config, :login_limit), Keyword.get(config, :login_window_ms)}

        :magic_link ->
          {Keyword.get(config, :magic_link_limit), Keyword.get(config, :magic_link_window_ms)}

        :password_reset ->
          {Keyword.get(config, :password_reset_limit),
           Keyword.get(config, :password_reset_window_ms)}

        :registration ->
          {Keyword.get(config, :registration_limit), Keyword.get(config, :registration_window_ms)}
      end

    # Hammer 7.x: Use get/2 to retrieve the current count
    # Backend.get/2 returns an integer directly (current count)
    count = Backend.get(key, window)
    max(0, limit - count)
  end

  # Private functions

  # The three public endpoints that SEND MAIL on an unauthenticated request,
  # each guarded by the same three buckets, charged narrowest first:
  #
  #   1. the address — stops one victim being hammered;
  #   2. the IP — stops a spray, where ten thousand addresses each take a single
  #      hit and no address bucket ever fires;
  #   3. the install — the total this site will send in an hour, whoever asks.
  #      A botnet with a fresh address and a fresh IP per request walks through
  #      the first two; only this one bounds the mail bill.
  #
  # ORDER IS LOAD-BEARING, and specifically the global bucket goes LAST, charged
  # only by a request the narrower two already allowed. A bucket counts the hit
  # whether or not anything else refused, so charging the site-wide one up front
  # would let an attacker hammering a SINGLE address — already refused, sending
  # nothing — drain the allowance for everybody else. Charged last it counts
  # mail this install would actually send, which is the thing being rationed,
  # and draining it costs an attacker a fresh address AND a fresh IP per hit.
  defp check_mail_endpoint(action, email, ip_address) do
    config = get_config()
    email = normalize_email(email)

    with :ok <-
           charge(
             "auth:#{action}:#{email}",
             Keyword.get(config, :"#{action}_window_ms"),
             Keyword.get(config, :"#{action}_limit"),
             action,
             email
           ),
         :ok <-
           charge_ip(
             action,
             ip_address,
             Keyword.get(config, :"#{action}_ip_window_ms"),
             Keyword.get(config, :"#{action}_ip_limit")
           ) do
      charge_global(
        action,
        Keyword.get(config, :"#{action}_global_window_ms"),
        Keyword.get(config, :"#{action}_global_limit")
      )
    end
  end

  defp charge(key, window, limit, action, identifier) do
    case check_rate_limit(key, window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        log_rate_limit_violation(action, identifier, limit, window)
        error
    end
  end

  # No address to key on — the endpoint still has its own bucket, and its
  # global one. Refusing instead would lock out every visitor on a host whose
  # endpoint does not thread peer data through to the socket, which is the same
  # call `check_login_rate_limit/2` makes.
  defp charge_ip(_action, ip, _window, _limit) when ip in [nil, "", "unknown"], do: :ok

  defp charge_ip(action, ip_address, window, limit) do
    ip = IpAddress.network(ip_address)
    charge("auth:#{action}:ip:#{ip}", window, limit, action, "ip:#{ip}")
  end

  defp charge_global(_action, _window, limit) when limit in [nil, false], do: :ok

  defp charge_global(action, window, limit) do
    case check_rate_limit("auth:#{action}:global", window, limit) do
      :ok ->
        :ok

      {:error, :rate_limit_exceeded} = error ->
        # Louder than the others on purpose: this one refuses everybody, so it
        # is either an attack in progress or a limit set too low, and an
        # operator needs to know which.
        Logger.error(
          "PhoenixKit.RateLimiter: SITE-WIDE limit reached for #{action} — " <>
            "#{limit} in #{format_window(window)}. Every #{action} request is now " <>
            "refused for all users until the window rolls. Investigate, or raise " <>
            ":#{action}_global_limit."
        )

        error
    end
  end

  defp check_rate_limit(key, window_ms, limit) do
    # Hammer 7.x: Backend.hit/3 returns {:allow, count} or {:deny, retry_after}
    case Backend.hit(key, window_ms, limit) do
      {:allow, _count} ->
        :ok

      {:deny, _retry_after_ms} ->
        {:error, :rate_limit_exceeded}
    end
  end

  defp normalize_email(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  def get_config do
    PhoenixKit.Config.get(__MODULE__, [])
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
