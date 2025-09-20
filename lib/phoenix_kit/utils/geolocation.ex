defmodule PhoenixKit.Utils.Geolocation do
  @moduledoc """
  IP Geolocation service for PhoenixKit user registration analytics.

  This module provides IP geolocation lookup functionality using free public APIs
  to determine the geographic location of user registrations for analytics purposes.

  ## Supported Services

  - **IP-API.com** (Primary) - 45 requests/minute, no API key required
  - **ipapi.co** (Fallback) - 1000 requests/day, no signup required

  ## Features

  - Automatic fallback between services
  - IP extraction from Phoenix LiveView sockets
  - Graceful error handling with sensible defaults
  - Support for IPv4 and IPv6 addresses
  - Privacy-conscious (no data retention by service)

  ## Usage

      # Extract IP from LiveView socket
      ip_address = PhoenixKit.Utils.Geolocation.extract_ip_from_socket(socket)

      # Get geolocation data
      case PhoenixKit.Utils.Geolocation.lookup_location(ip_address) do
        {:ok, location} ->
          # %{ip: "1.2.3.4", country: "US", region: "California", city: "San Francisco"}
        {:error, reason} ->
          # Handle gracefully - save user without geolocation data
      end

  ## Rate Limits

  - IP-API.com: 45 requests per minute (primary service)
  - ipapi.co: 1000 requests per day (fallback service)

  For production applications with higher volume, consider upgrading to paid tiers
  or implementing local MMDB database lookups.
  """

  require Logger

  @type location_data :: %{
          ip: String.t(),
          country: String.t() | nil,
          region: String.t() | nil,
          city: String.t() | nil
        }

  @type lookup_result :: {:ok, location_data()} | {:error, String.t()}

  # Configuration
  @primary_service_url "http://ip-api.com/json/"
  @fallback_service_url "https://ipapi.co/"
  @request_timeout 5000
  @user_agent "PhoenixKit/1.0 (Registration Analytics)"

  @doc """
  Extracts the real IP address from a Phoenix LiveView socket.

  Handles various proxy configurations and connection info formats to extract
  the client's actual IP address.

  ## Examples

      iex> PhoenixKit.Utils.Geolocation.extract_ip_from_socket(socket)
      "192.168.1.100"

      iex> PhoenixKit.Utils.Geolocation.extract_ip_from_socket(socket_with_proxy)
      "203.0.113.1"
  """
  @spec extract_ip_from_socket(Phoenix.LiveView.Socket.t()) :: String.t()
  def extract_ip_from_socket(socket) do
    # Try to get the real IP from various sources
    case get_connect_info(socket, :peer_data) do
      %{address: {a, b, c, d}}
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) ->
        "#{a}.#{b}.#{c}.#{d}"

      %{address: {a, b, c, d, e, f, g, h}} ->
        # IPv6 address
        parts =
          [a, b, c, d, e, f, g, h]
          |> Enum.map(&Integer.to_string(&1, 16))
          |> Enum.join(":")

        parts

      %{address: address} when is_binary(address) ->
        address

      _ ->
        # Check for forwarded headers (X-Forwarded-For, X-Real-IP)
        case get_connect_info(socket, :x_headers) do
          headers when is_list(headers) ->
            extract_forwarded_ip(headers)

          _ ->
            "unknown"
        end
    end
  end

  @doc """
  Performs IP geolocation lookup using available free services.

  Attempts to lookup location data using the primary service (IP-API.com) first,
  then falls back to secondary service (ipapi.co) if the primary fails.

  ## Parameters

  - `ip_address` - The IP address to lookup (IPv4 or IPv6)

  ## Returns

  - `{:ok, location_data}` - Successfully retrieved location data
  - `{:error, reason}` - Failed to retrieve location data

  ## Examples

      iex> PhoenixKit.Utils.Geolocation.lookup_location("8.8.8.8")
      {:ok, %{ip: "8.8.8.8", country: "US", region: "California", city: "Mountain View"}}

      iex> PhoenixKit.Utils.Geolocation.lookup_location("invalid-ip")
      {:error, "Invalid IP address format"}
  """
  @spec lookup_location(String.t()) :: lookup_result()
  def lookup_location(ip_address) when is_binary(ip_address) do
    case validate_ip_address(ip_address) do
      {:ok, validated_ip} ->
        # Try primary service first
        case lookup_with_ip_api(validated_ip) do
          {:ok, data} ->
            {:ok, data}

          {:error, _reason} ->
            # Fallback to secondary service
            Logger.info(
              "PhoenixKit.Geolocation: Primary service failed, trying fallback for IP #{validated_ip}"
            )

            lookup_with_ipapi_co(validated_ip)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def lookup_location(_), do: {:error, "Invalid IP address format"}

  @doc """
  Performs a bulk IP geolocation lookup for multiple addresses.

  Useful for batch processing of user registrations or analytics.

  ## Parameters

  - `ip_addresses` - List of IP addresses to lookup
  - `options` - Keyword list of options (currently unused, for future expansion)

  ## Returns

  A list of results in the same order as input IPs.

  ## Examples

      iex> PhoenixKit.Utils.Geolocation.bulk_lookup(["8.8.8.8", "1.1.1.1"])
      [
        {:ok, %{ip: "8.8.8.8", country: "US", region: "California", city: "Mountain View"}},
        {:ok, %{ip: "1.1.1.1", country: "AU", region: "Queensland", city: "South Brisbane"}}
      ]
  """
  @spec bulk_lookup([String.t()], keyword()) :: [lookup_result()]
  def bulk_lookup(ip_addresses, _options \\ []) when is_list(ip_addresses) do
    ip_addresses
    |> Enum.map(&lookup_location/1)
  end

  # Private helper functions

  defp get_connect_info(socket, key) do
    Phoenix.LiveView.get_connect_info(socket, key)
  rescue
    _ -> nil
  end

  defp extract_forwarded_ip(headers) do
    # Look for X-Forwarded-For or X-Real-IP headers
    case find_forwarded_header(headers) do
      nil -> "unknown"
      ip when is_binary(ip) -> String.trim(ip)
    end
  end

  defp find_forwarded_header(headers) do
    headers
    |> Enum.find_value(fn
      {"x-forwarded-for", value} ->
        # X-Forwarded-For can contain multiple IPs, take the first one
        value |> String.split(",") |> List.first() |> String.trim()

      {"x-real-ip", value} ->
        String.trim(value)

      _ ->
        nil
    end)
  end

  defp validate_ip_address(ip_address) do
    case :inet.parse_address(String.to_charlist(ip_address)) do
      {:ok, _parsed} -> {:ok, ip_address}
      {:error, _} -> {:error, "Invalid IP address format"}
    end
  end

  defp lookup_with_ip_api(ip_address) do
    url =
      @primary_service_url <>
        ip_address <> "?fields=status,message,country,regionName,city,lat,lon,query"

    case make_http_request(url) do
      {:ok, %{"status" => "success"} = response} ->
        {:ok,
         %{
           ip: response["query"] || ip_address,
           country: response["country"],
           region: response["regionName"],
           city: response["city"]
         }}

      {:ok, %{"status" => "fail", "message" => message}} ->
        {:error, "IP-API error: #{message}"}

      {:error, reason} ->
        {:error, "IP-API request failed: #{reason}"}
    end
  end

  defp lookup_with_ipapi_co(ip_address) do
    url = @fallback_service_url <> ip_address <> "/json/"

    case make_http_request(url) do
      {:ok, %{"error" => true, "reason" => reason}} ->
        {:error, "ipapi.co error: #{reason}"}

      {:ok, response} when is_map(response) ->
        {:ok,
         %{
           ip: response["ip"] || ip_address,
           country: response["country_name"],
           region: response["region"],
           city: response["city"]
         }}

      {:error, reason} ->
        {:error, "ipapi.co request failed: #{reason}"}
    end
  end

  defp make_http_request(url) do
    headers = [
      {"user-agent", @user_agent},
      {"accept", "application/json"}
    ]

    request = Finch.build(:get, url, headers)

    case Finch.request(request, Swoosh.Finch, receive_timeout: @request_timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Invalid JSON response"}
        end

      {:ok, %Finch.Response{status: status_code}} ->
        {:error, "HTTP #{status_code}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {:error, "Request exception: #{Exception.message(exception)}"}
  end

  @doc """
  Checks if an IP address is private/internal.

  Returns true for private IP ranges (RFC 1918) and other non-routable addresses.
  Useful for skipping geolocation lookups for internal/development traffic.

  ## Examples

      iex> PhoenixKit.Utils.Geolocation.private_ip?("192.168.1.1")
      true

      iex> PhoenixKit.Utils.Geolocation.private_ip?("8.8.8.8")
      false
  """
  @spec private_ip?(String.t()) :: boolean()
  def private_ip?(ip_address) when is_binary(ip_address) do
    case :inet.parse_address(String.to_charlist(ip_address)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {192, 168, _, _}} -> true
      # Loopback
      {:ok, {127, _, _, _}} -> true
      # Link-local
      {:ok, {169, 254, _, _}} -> true
      {:ok, _} -> false
      {:error, _} -> false
    end
  end

  def private_ip?(_), do: false
end
