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

  @hash_algorithm :sha256

  @doc """
  Creates a session fingerprint from a Plug.Conn connection.

  Returns a map with `:ip_address` and `:user_agent_hash` keys.

  ## Examples

      iex> create_fingerprint(conn)
      %{ip_address: "192.168.1.1", user_agent_hash: "a1b2c3d4..."}

  """
  def create_fingerprint(conn) do
    %{
      ip_address: get_ip_address(conn),
      user_agent_hash: hash_user_agent(conn)
    }
  end

  @doc """
  Extracts the IP address from a connection.

  Handles proxied connections by checking X-Forwarded-For and X-Real-IP headers,
  falling back to the direct connection IP.

  ## Examples

      iex> get_ip_address(conn)
      "192.168.1.1"

  """
  def get_ip_address(conn) do
    # Check for proxied IP addresses first
    cond do
      # X-Forwarded-For header (may contain multiple IPs, take the first)
      forwarded_for = get_header(conn, "x-forwarded-for") ->
        forwarded_for
        |> String.split(",")
        |> List.first()
        |> String.trim()

      # X-Real-IP header
      real_ip = get_header(conn, "x-real-ip") ->
        String.trim(real_ip)

      # Direct connection IP
      true ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
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
  def verify_fingerprint(conn, stored_ip, stored_ua_hash) do
    # Backward compatibility: if no fingerprint was stored, allow access
    if is_nil(stored_ip) and is_nil(stored_ua_hash) do
      :ok
    else
      current_ip = get_ip_address(conn)
      current_ua_hash = hash_user_agent(conn)

      ip_matches? = is_nil(stored_ip) or stored_ip == current_ip
      ua_matches? = is_nil(stored_ua_hash) or stored_ua_hash == current_ua_hash

      case {ip_matches?, ua_matches?} do
        {true, true} ->
          :ok

        {false, true} ->
          Logger.warning("""
          PhoenixKit: Session IP mismatch detected
            Stored IP: #{stored_ip}
            Current IP: #{current_ip}
            User Agent matches: yes
          """)

          {:warning, :ip_mismatch}

        {true, false} ->
          Logger.warning("""
          PhoenixKit: Session User-Agent mismatch detected
            IP matches: yes
            User Agent changed
          """)

          {:warning, :user_agent_mismatch}

        {false, false} ->
          Logger.error("""
          PhoenixKit: Session fingerprint mismatch - possible hijacking attempt
            Stored IP: #{stored_ip}
            Current IP: #{current_ip}
            User Agent also changed
          """)

          {:error, :fingerprint_mismatch}
      end
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
