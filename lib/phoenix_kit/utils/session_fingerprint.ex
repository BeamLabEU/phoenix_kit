defmodule PhoenixKit.Utils.SessionFingerprint do
  @moduledoc """
  Session fingerprinting utilities for preventing session hijacking.

  This module provides functions to create and verify session fingerprints based on
  IP address and user agent data. These fingerprints help detect when a session token
  is being used from a different location or device than where it was created.

  ## Security Considerations

  - IP addresses can change (mobile users, VPNs, etc.), so strict enforcement may
    impact legitimate users
  - User agents can be spoofed, but provide an additional layer of verification
  - This is defense-in-depth: fingerprinting complements, not replaces, other security measures

  ## Configuration

  You can configure the strictness level in your application config:

      config :phoenix_kit,
        session_fingerprint_enabled: true,
        session_fingerprint_strict: false  # true = force re-auth, false = log warnings

  ## Examples

      # Create a fingerprint from a connection
      fingerprint = SessionFingerprint.create_fingerprint(conn)

      # Verify a fingerprint
      case SessionFingerprint.verify_fingerprint(conn, stored_ip, stored_ua_hash) do
        :ok -> # Fingerprint matches
        {:warning, :ip_mismatch} -> # IP changed, but might be legitimate
        {:warning, :user_agent_mismatch} -> # User agent changed
        {:error, :fingerprint_mismatch} -> # Both changed, likely hijacked
      end

  """

  require Logger

  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.PublicAddress

  @hash_algorithm :sha256

  @enforce_keys [:ip_address, :user_agent_hash]
  defstruct [:ip_address, :user_agent_hash]

  @type t :: %__MODULE__{
          ip_address: String.t(),
          user_agent_hash: String.t()
        }

  @doc """
  Creates a session fingerprint from a Plug.Conn connection.

  Returns a `%SessionFingerprint{}` struct with `:ip_address` and `:user_agent_hash` fields.

  ## Examples

      iex> create_fingerprint(conn)
      %SessionFingerprint{ip_address: "192.168.1.1", user_agent_hash: "a1b2c3d4..."}

  """
  def create_fingerprint(conn) do
    %__MODULE__{
      ip_address: get_ip_address(conn),
      user_agent_hash: hash_user_agent(conn)
    }
  end

  @doc """
  Extracts the IP address from a connection.

  Delegates to `PhoenixKit.Utils.IpAddress.extract_from_conn/1`: a forwarded
  header is trusted only when `conn.remote_ip` is itself a loopback or
  private address (a proxy on the same box or network), and only the LAST
  `x-forwarded-for` entry — the one a proxy appends, not the one a client
  sent — is used. The previous implementation trusted `x-forwarded-for`
  unconditionally and took the FIRST entry, so anyone could spoof this
  fingerprint's IP (and therefore the "new device" / session-hijack checks
  built on it) with a plain client-supplied header, proxy or no proxy.

  ## Examples

      iex> get_ip_address(conn)
      "192.168.1.1"

  """
  def get_ip_address(conn) do
    IpAddress.extract_from_conn(conn)
  rescue
    _ ->
      # Fallback to "unknown" if IP extraction fails
      "unknown"
  end

  @doc """
  Extracts and hashes the user agent from a connection.

  Returns a SHA256 hash of the user agent string for privacy and storage efficiency.

  ## Examples

      iex> hash_user_agent(conn)
      "a1b2c3d4e5f6..."

  """
  def hash_user_agent(conn) do
    user_agent = get_header(conn, "user-agent") || "unknown"

    :crypto.hash(@hash_algorithm, user_agent)
    |> Base.encode16(case: :lower)
  end

  # The level follows what actually happens to the request, which is the whole
  # point of this logging pass: "possible hijacking attempt" logged at :error
  # and then served anyway is what teaches people that :error means nothing
  # here. Strict mode refuses EVERY mismatch — `PhoenixKitWeb.Users.Auth`
  # answers both `{:warning, _}` and `{:error, _}` with
  # `not strict_mode?()` — so under strict mode every one of these lines
  # describes a request that was denied, and gets :error. Otherwise the
  # request is served and the line takes the level its own severity earns.
  defp log_mismatch(message, allowed_level) do
    if strict_mode?() do
      Logger.error(message <> " — access denied (strict mode)")
    else
      Logger.log(allowed_level, message <> " — allowed (strict mode off)")
    end
  end

  @doc """
  Verifies a session fingerprint against the current connection.

  Returns:
  - `:ok` if fingerprint matches
  - `{:warning, :ip_mismatch}` if only IP changed
  - `{:warning, :user_agent_mismatch}` if only user agent changed
  - `{:error, :fingerprint_mismatch}` if both changed
  - `:ok` if stored fingerprint is nil (backward compatibility)

  ## Examples

      iex> verify_fingerprint(conn, "192.168.1.1", "abc123")
      :ok

      iex> verify_fingerprint(conn, "10.0.0.1", "abc123")
      {:warning, :ip_mismatch}

  """
  def verify_fingerprint(conn, stored_ip, stored_ua_hash, opts \\ []) do
    # Backward compatibility: if no fingerprint was stored, allow access
    if is_nil(stored_ip) and is_nil(stored_ua_hash) do
      :ok
    else
      current_ip = get_ip_address(conn)
      current_ua_hash = hash_user_agent(conn)

      # By network, not address: an IPv6 client rotates its temporary
      # address inside its /64 daily, which is the same connection.
      ip_matches? =
        is_nil(stored_ip) or IpAddress.network(stored_ip) == IpAddress.network(current_ip)

      ua_matches? = is_nil(stored_ua_hash) or stored_ua_hash == current_ua_hash

      # Correlation, so a line names WHICH session it is about. Without it a
      # log full of these says only that something, somewhere, changed — and
      # the raw token must never be written down, so a truncated hash it is.
      session = Keyword.get(opts, :session, "unknown")

      case {ip_matches?, ua_matches?} do
        {true, true} ->
          :ok

        {false, true} ->
          log_mismatch(
            "PhoenixKit: session #{session} changed IP (#{stored_ip} -> #{current_ip}), " <>
              "same browser",
            :warning
          )

          {:warning, :ip_mismatch}

        {true, false} ->
          # Info, not warning. Browsers rewrite their user agent on every
          # update — roughly monthly, for every user — so this fires in
          # numbers no one can read, for a thing that is almost never an
          # attack and never acted on. At warning level it was the bulk of a
          # 765-line log, which is how the lines that DO matter got lost.
          log_mismatch("PhoenixKit: session #{session} changed user agent, same IP", :info)

          {:warning, :user_agent_mismatch}

        {false, false} ->
          log_mismatch(
            "PhoenixKit: session #{session} changed BOTH IP (#{stored_ip} -> #{current_ip}) " <>
              "and user agent",
            :warning
          )

          {:error, :fingerprint_mismatch}
      end
    end
  end

  @doc """
  The visitor's address to move a session to when the one it was stored
  with was a reverse proxy's — or nil when the stored address stands.

  Before core could read the visitor's address through a proxy that writes
  `ip:port` (Caddy's `{remote}`), a session signed in behind one stored the
  proxy's own loopback or private address. Read correctly now, every
  request of such a session would be a changed IP: a warning each time, a
  sign-out under strict mode. A stored loopback/private address and a
  public current one, from the same browser, is that session — it moves to
  the current address once and is checked as usual from then on. A
  different browser is not moved: whoever holds the token must not get to
  rebind it from somewhere else.
  """
  @spec proxy_rebind_address(Plug.Conn.t(), String.t() | nil, String.t() | nil) ::
          String.t() | nil
  def proxy_rebind_address(conn, stored_ip, stored_ua_hash) do
    current_ip = get_ip_address(conn)

    if IpAddress.local_address?(stored_ip) and PublicAddress.public?(current_ip) and
         stored_ua_hash in [nil, hash_user_agent(conn)] do
      current_ip
    end
  end

  @doc """
  Checks if session fingerprinting is enabled in the application config.

  ## Examples

      iex> fingerprinting_enabled?()
      true

  """
  def fingerprinting_enabled? do
    PhoenixKit.Config.get_boolean(:session_fingerprint_enabled, true)
  end

  @doc """
  Checks if strict fingerprint verification is enabled.

  When strict mode is enabled, fingerprint mismatches will force re-authentication.
  When disabled, mismatches only log warnings.

  ## Examples

      iex> strict_mode?()
      false

  """
  def strict_mode? do
    PhoenixKit.Config.get_boolean(:session_fingerprint_strict, false)
  end

  # Private helper to get a header value from connection
  defp get_header(conn, header_name) do
    case Plug.Conn.get_req_header(conn, header_name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
