defmodule PhoenixKit.Users.LoginAlerts do
  @moduledoc """
  New-login security alerts ("we noticed a new login to your account").

  On every login (`PhoenixKitWeb.Users.Auth.log_in_user/3`), the request's
  `(network, user_agent_hash)` pair is checked against
  `PhoenixKit.Users.Auth.KnownDevice` rows for that user
  (`PhoenixKit.Utils.IpAddress.network/1`: IPv4 is the address, IPv6 is
  its `/64`). A row is persisted for every new pair either way (still used
  to enrich the self-service "Active Sessions" list with browser/OS/location
  per session — see `PhoenixKit.Users.Sessions.list_user_device_sessions/2`).
  The stored `ip_address` remains the full address (display, geo, audit).
  A `user.new_login_detected` activity entry is always logged too, for the
  audit trail.

  The reader-facing alarms — the email
  (`PhoenixKit.Users.Auth.UserNotifier.deliver_new_login_alert/2`) and the
  in-app notification — are narrower than "unrecognized pair", though. The
  new-device alarm (`new_login_alert_enabled`) is skipped when either:

    * this is the very first `KnownDevice` row the account has ever had
      (see below), or
    * the browser HAS been seen before for this account, regardless of IP
      (see "Recognizing a browser" below) — an IP alone changing is not "a
      new device" from the user's point of view. Most residential/mobile
      connections don't have a static IP, so alerting on IP change alone
      fires on a large fraction of logins from an already-trusted browser
      and trains people to ignore the email — the exact alert-fatigue
      failure this codebase already avoids elsewhere (see
      `PhoenixKit.Utils.SessionFingerprint`, which treats an IP-only
      mismatch as a mere warning, never an alarm).

  The first-device skip exists because registration ends by logging the new
  user in through this exact path (`log_in_user/3`), and an account with no
  device history yet cannot help but treat its own signup as "a new device" —
  without it, every signup on an installation with alerts on immediately
  received a "we noticed a new login" security email about the login it just
  performed to finish registering. The device is still recorded (so the
  *second* login, from anywhere else, correctly reads as new), and the
  activity entry still logs for the audit trail — only the two
  reader-facing alarms are suppressed.

  ## Recognizing a browser

  "Seen before" means either of two things:

    * **the device cookie** (`_phoenix_kit_device`): a random 256-bit value
      this module gives the browser at every sign-in and keeps for 400 days.
      The row stores `device_token_hash`, a SHA-256 of the account's uuid and
      that value, so the same browser reads differently for each account
      (no cross-account correlation from the table) and the raw value never
      reaches the database. It survives browser updates and IP changes, which
      the user-agent hash does not: the hash covers the whole user-agent
      string, version number included, so on its own every browser update
      would read as a new device and alert roughly once a month per browser.
      Someone else's browser never carries it.
    * **the same user-agent hash** as an earlier row, the only signal before
      the cookie existed. It keeps a browser from before V230, or one whose
      cookies were cleared, recognized until it updates; it never loosens
      anything compared to before the cookie.

  Matching on browser/OS family instead ("Chrome on Windows") would also fix
  updates, but it would silence an intruder who happens to use the most
  common browser and OS — the one case the alert is for. Not done on purpose.

  The cookie is unsigned on purpose: a forged value matches no row, and the
  check must not depend on `secret_key_base` being present on the conn.

  ## New country

  A second, independent alarm (`new_country_login_alert_enabled`), skipped
  on the account's first device like the other: the
  new device's country (`country_code`, resolved with its location) is one
  no earlier device of the account was seen in. It fires even when the
  browser is known — a familiar laptop signing in from abroad is the case it
  exists for. It stays quiet while the account has no known country at all
  (rows from before V230, or a lookup that never resolved): that sign-in
  records the baseline instead. A failed lookup never alerts. A VPN exit in
  another country does — there is no telling the two apart from here.

  The recording runs when either alarm is on, so each feeds the other's
  history.

  A recognized `(network, ua)` pair bumps `last_seen_at` without alerting.
  When country alerts are on, a row with no country gets another lookup
  on its first visit since V230 or after a day between visits. This lets
  existing devices establish a country baseline before the person travels.
  IPv4 still creates one row per address, because each address is its own network.

  Sends synchronously (matching every other PhoenixKit auth email —
  confirmation, password reset, magic link — none of which are queued
  through Oban): a "new device" login is inherently rare per user (every
  subsequent login from the same device is silent), so the odd extra
  round-trip on a first-time login doesn't justify background-job
  infrastructure this feature would otherwise be the only user of. A
  send failure is logged and swallowed — it must never block sign-in.
  """

  import Ecto.Query

  require Logger

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Notifications
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.KnownDevice
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Utils.Geolocation
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.SessionFingerprint
  alias PhoenixKit.Utils.UserAgent

  @device_cookie "_phoenix_kit_device"
  # 400 days: the longest a browser keeps a cookie (Chrome caps it there).
  @device_cookie_max_age 60 * 60 * 24 * 400
  @country_retry_seconds 24 * 60 * 60

  @doc """
  Whether sign-ins are being recorded: either alarm is on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: device_alerts_enabled?() or country_alerts_enabled?()

  @doc """
  Whether a sign-in from a new device alerts (setting
  `new_login_alert_enabled`, default `false`).
  """
  @spec device_alerts_enabled?() :: boolean()
  def device_alerts_enabled?, do: Settings.get_boolean_setting("new_login_alert_enabled", false)

  @doc """
  Whether a sign-in from a new country alerts (setting
  `new_country_login_alert_enabled`, default `false`).
  """
  @spec country_alerts_enabled?() :: boolean()
  def country_alerts_enabled?,
    do: Settings.get_boolean_setting("new_country_login_alert_enabled", false)

  @doc """
  Records a login from `conn` for `user`, alerting on a new device or
  country, and returns `conn` with the device cookie set.

  No-ops entirely (no DB write, no email, no cookie) when both alarms are
  off. Never raises — a failure here must never block sign-in; the conn
  comes back unchanged.
  """
  @spec check(map(), Plug.Conn.t()) :: Plug.Conn.t()
  def check(user, conn) do
    if enabled?() do
      token = device_token(conn)
      do_check(user, conn, device_token_hash(user, token))
      put_device_cookie(conn, token)
    else
      conn
    end
  rescue
    error ->
      Logger.warning("[PhoenixKit.LoginAlerts] check failed: #{inspect(error)}")
      conn
  catch
    :exit, _reason ->
      Logger.warning("[PhoenixKit.LoginAlerts] check exited")
      conn
  end

  @doc """
  The name of the device cookie (see the moduledoc).
  """
  @spec device_cookie() :: String.t()
  def device_cookie, do: @device_cookie

  # The browser's device token, or a new one when it carries none (or junk).
  defp device_token(conn) do
    case Plug.Conn.fetch_cookies(conn).req_cookies[@device_cookie] do
      token when is_binary(token) ->
        if token =~ ~r/\A[A-Za-z0-9_-]{43}\z/, do: token, else: new_device_token()

      _ ->
        new_device_token()
    end
  end

  defp new_device_token,
    do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp device_token_hash(user, token) do
    :crypto.hash(:sha256, "#{user.uuid}:#{token}") |> Base.encode16(case: :lower)
  end

  # Refreshed at every sign-in, so a browser in use never loses it.
  defp put_device_cookie(conn, token) do
    Plug.Conn.put_resp_cookie(conn, @device_cookie, token,
      max_age: @device_cookie_max_age,
      same_site: "Lax",
      http_only: true,
      secure: true
    )
  end

  defp do_check(user, conn, device_hash) do
    fingerprint = SessionFingerprint.create_fingerprint(conn)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    repo = RepoHelper.repo()

    case matching_device(repo, user, fingerprint) do
      %KnownDevice{} = device ->
        refresh_device(repo, device, now, device_hash)

      nil ->
        # This (network, ua) pair is new, but the browser itself may not
        # be — an IP alone changing (a new DHCP lease, switching wifi to
        # mobile data, ...) or the browser updating itself is not "a new
        # device" worth alarming the user over. See the moduledoc. All three
        # facts are read BEFORE inserting the row below — once it's inserted
        # this account always has a matching device on file, and every
        # future check would wrongly read as "first device"/"new browser"/
        # "known country" too.
        ua = user_agent_header(conn)
        device = %{browser: UserAgent.browser(ua), os: UserAgent.os(ua)}
        new_browser? = not repo.exists?(same_browser_query(user, fingerprint, device_hash))

        first_device? =
          new_browser? and
            not repo.exists?(from(d in KnownDevice, where: d.user_uuid == ^user.uuid))

        %{location: location, country_code: country_code} = place_for(fingerprint.ip_address)
        new_country? = not first_device? and new_country?(repo, user, country_code)

        attrs =
          Map.merge(device, %{
            user_uuid: user.uuid,
            ip_address: fingerprint.ip_address,
            user_agent_hash: fingerprint.user_agent_hash,
            device_token_hash: device_hash,
            # Resolved once here and persisted (V147, V230) so the Active
            # Sessions list can show it and the next sign-in can compare
            # against it, without re-hitting the geo API.
            location: location,
            country_code: country_code,
            first_seen_at: now,
            last_seen_at: now
          })

        record_new_device(user, attrs, %{
          first_device?: first_device?,
          new_browser?: new_browser?,
          new_country?: new_country?
        })
    end
  end

  defp refresh_device(repo, device, now, device_hash) do
    place =
      if is_nil(device.country_code) and
           (is_nil(device.device_token_hash) or
              DateTime.diff(now, device.last_seen_at) >= @country_retry_seconds) and
           country_alerts_enabled?() do
        place_for(device.ip_address)
      else
        %{location: nil, country_code: nil}
      end

    # Keep the first browser and country recorded for this pair, even when
    # two sign-ins both read the row before either can refresh it.
    from(d in KnownDevice,
      where: d.uuid == ^device.uuid,
      update: [
        set: [
          last_seen_at: fragment("GREATEST(?, ?)", d.last_seen_at, ^now),
          device_token_hash: coalesce(d.device_token_hash, ^device_hash),
          country_code: coalesce(d.country_code, ^place.country_code),
          location: coalesce(d.location, ^place.location)
        ]
      ]
    )
    |> repo.update_all([])

    :ok
  end

  # This browser, by its device cookie or by its exact user agent, at any IP.
  # See "Recognizing a browser" in the moduledoc.
  defp same_browser_query(user, fingerprint, device_hash) do
    from(d in KnownDevice,
      where:
        d.user_uuid == ^user.uuid and
          (d.device_token_hash == ^device_hash or
             d.user_agent_hash == ^fingerprint.user_agent_hash)
    )
  end

  # New only against a known history: an unresolved country never alerts, and
  # an account with no country on file yet (rows from before V230, lookups that
  # never resolved) takes this one as its baseline.
  defp new_country?(_repo, _user, nil), do: false

  defp new_country?(repo, user, country_code) do
    known =
      repo.all(
        from(d in KnownDevice,
          where: d.user_uuid == ^user.uuid and not is_nil(d.country_code),
          distinct: true,
          select: d.country_code
        )
      )

    known != [] and country_code not in known
  end

  # Unique index first. Scan same-UA rows by /64 only when grouping could
  # match a different stored address (IPv4 cannot).
  defp matching_device(repo, user, fingerprint) do
    exact =
      repo.get_by(KnownDevice,
        user_uuid: user.uuid,
        ip_address: fingerprint.ip_address,
        user_agent_hash: fingerprint.user_agent_hash
      )

    exact || network_device(repo, user, fingerprint)
  end

  defp network_device(repo, user, fingerprint) do
    network = IpAddress.network(fingerprint.ip_address)

    if network == fingerprint.ip_address do
      nil
    else
      repo.all(
        from(d in KnownDevice,
          where: d.user_uuid == ^user.uuid and d.user_agent_hash == ^fingerprint.user_agent_hash,
          order_by: [desc: d.last_seen_at]
        )
      )
      |> Enum.find(&(IpAddress.network(&1.ip_address) == network))
    end
  end

  defp record_new_device(user, attrs, facts) do
    repo = RepoHelper.repo()

    %KnownDevice{}
    |> KnownDevice.changeset(attrs)
    |> repo.insert(
      on_conflict: [set: [last_seen_at: attrs.last_seen_at]],
      conflict_target: [:user_uuid, :ip_address, :user_agent_hash]
    )

    log_new_login(user, attrs, facts)

    # Reasons to stay quiet, all explained in the moduledoc: the account's
    # first-ever login (registration's own auto-login) is not a security
    # event, and an IP-only change or a browser update on an
    # already-recognized browser is not "a new device" either — unless it
    # comes from a new country and that alarm is on. Either way only the two
    # reader-facing alarms are skipped — the device row and activity entry
    # above still record it, so a genuinely new browser still reads as new.
    if alarm?(facts) do
      notify_in_app(user, attrs)
      UserNotifier.deliver_new_login_alert(user, attrs)
    end

    :ok
  end

  defp alarm?(%{first_device?: true}), do: false

  defp alarm?(%{new_browser?: new_browser?, new_country?: new_country?}) do
    (new_browser? and device_alerts_enabled?()) or (new_country? and country_alerts_enabled?())
  end

  # In-app notification for the new sign-in. The `user.new_login_detected`
  # activity is self-actor (actor == target), so the activity→notification
  # hook correctly skips it — this is the sanctioned standalone path for an
  # app-driven self-notice, filtered through the recipient's "security"
  # type preference (fail-open). Links to the Active Sessions section.
  defp notify_in_app(user, attrs) do
    if Code.ensure_loaded?(Notifications) do
      Notifications.create(%{
        recipient_uuid: user.uuid,
        type: "security",
        icon: "hero-shield-exclamation",
        link: Routes.user_settings_path(),
        text: new_login_text(attrs)
      })
    end
  rescue
    error ->
      Logger.warning("[PhoenixKit.LoginAlerts] in-app notify failed: #{inspect(error)}")
      :ok
  end

  defp new_login_text(attrs) do
    details =
      [attrs.browser, attrs.os, attrs.location]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(", ")

    case details do
      "" -> gettext("New sign-in to your account.")
      _ -> gettext("New sign-in to your account from %{details}.", details: details)
    end
  end

  defp log_new_login(user, attrs, facts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "user.new_login_detected",
        module: "users",
        mode: "auto",
        actor_uuid: user.uuid,
        target_uuid: user.uuid,
        resource_type: "user",
        resource_uuid: user.uuid,
        metadata: %{
          "actor_role" => "user",
          "ip_address" => attrs.ip_address,
          "browser" => attrs.browser,
          "os" => attrs.os,
          "country_code" => attrs.country_code,
          "first_device" => facts.first_device?,
          "new_browser" => facts.new_browser?,
          "new_country" => facts.new_country?
        }
      })
    end
  rescue
    error ->
      Logger.warning("[PhoenixKit.LoginAlerts] activity log failed: #{inspect(error)}")
  end

  defp user_agent_header(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> nil
    end
  end

  @doc """
  Best-effort "City, Country" string for `ip_address`, or `nil`.

  Never raises; a lookup failure (disabled, rate-limited, invalid IP)
  just means the alert email omits the location line.
  """
  @spec location_for(String.t()) :: String.t() | nil
  def location_for(ip_address), do: place_for(ip_address).location

  @doc """
  Best-effort place for `ip_address`, from one lookup: `location` as in
  `location_for/1`, and `country_code`, the upper-case ISO 3166-1 alpha-2
  code (`nil` when the lookup failed or returned something else).

  Never raises.
  """
  @spec place_for(String.t()) :: %{location: String.t() | nil, country_code: String.t() | nil}
  def place_for(ip_address) do
    case Geolocation.lookup_location(ip_address) do
      {:ok, data} when is_map(data) ->
        %{location: location_text(data), country_code: country_code(data["country_code"])}

      _ ->
        %{location: nil, country_code: nil}
    end
  rescue
    _ -> %{location: nil, country_code: nil}
  catch
    :exit, _ -> %{location: nil, country_code: nil}
  end

  defp location_text(%{"city" => city, "country" => country})
       when is_binary(city) and city != "" and is_binary(country) and country != "",
       do: "#{city}, #{country}"

  defp location_text(%{"country" => country}) when is_binary(country) and country != "",
    do: country

  defp location_text(_), do: nil

  defp country_code(code) when is_binary(code) do
    code = code |> String.trim() |> String.upcase()
    if code =~ ~r/\A[A-Z]{2}\z/, do: code
  end

  defp country_code(_), do: nil
end
