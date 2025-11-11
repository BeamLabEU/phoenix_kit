defmodule PhoenixKit.Utils.Geolocation do
  @moduledoc """
  IP Geolocation utilities for PhoenixKit.

  Provides functionality to extract IP addresses from Phoenix LiveView sockets
  and look up geographical location data using free IP geolocation APIs.

  ## Features

  - Extract IP addresses from Phoenix LiveView sockets
  - Primary API: IP-API.com (45 requests/minute)
  - Fallback API: ipapi.co (1000 requests/day)
  - Graceful error handling with fallback to IP-only tracking
  - Privacy-first design (disabled by default)

  ## Usage

      # Extract IP from socket
      ip_address = PhoenixKit.Utils.Geolocation.extract_ip_from_socket(socket)

      # Lookup location data
      case PhoenixKit.Utils.Geolocation.lookup_location(ip_address) do
        {:ok, location} ->
          # Process location data
        {:error, reason} ->
          # Handle error, fall back to IP-only
      end
  """

  require Logger

  alias PhoenixKit.Utils.IpAddress

  @doc """
  Extracts IP address from a Phoenix LiveView socket.

  ## Examples

      iex> extract_ip_from_socket(socket)
      "192.168.1.1"

      iex> extract_ip_from_socket(socket_with_no_peer_data)
      "unknown"
  """
  def extract_ip_from_socket(socket) do
    IpAddress.extract_from_socket(socket)
  end

  @doc """
  Looks up geographical location data for an IP address.

  Uses IP-API.com as primary service (45 requests/minute) with ipapi.co
  as fallback (1000 requests/day).

  ## Examples

      iex> lookup_location("8.8.8.8")
      {:ok, %{
        "country" => "United States",
        "region" => "California",
        "city" => "Mountain View"
      }}

      iex> lookup_location("invalid-ip")
      {:error, "Invalid IP address"}
  """
  def lookup_location(ip_address) when is_binary(ip_address) do
    case String.trim(ip_address) do
      "" -> {:error, "Empty IP address"}
      "unknown" -> {:error, "Unknown IP address"}
      "127.0.0.1" -> {:error, "Localhost IP address"}
      "::1" -> {:error, "Localhost IPv6 address"}
      valid_ip -> perform_lookup(valid_ip)
    end
  end

  def lookup_location(_), do: {:error, "Invalid IP address format"}

  # Private functions

  defp perform_lookup(ip_address) do
    case lookup_with_ip_api(ip_address) do
      {:ok, location} ->
        {:ok, location}

      {:error, reason} ->
        Logger.warning("IP-API.com lookup failed: #{reason}, trying fallback")
        lookup_with_ipapi_co(ip_address)
    end
  end

  defp lookup_with_ip_api(ip_address) do
    url = "http://ip-api.com/json/#{ip_address}?fields=status,message,country,regionName,city"

    case make_http_request(url) do
      {:ok, %{"status" => "success"} = data} ->
        location = %{
          "country" => data["country"],
          "region" => data["regionName"],
          "city" => data["city"]
        }

        {:ok, location}

      {:ok, %{"status" => "fail", "message" => message}} ->
        {:error, "IP-API.com error: #{message}"}

      {:ok, _} ->
        {:error, "Invalid response from IP-API.com"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{reason}"}
    end
  end

  defp lookup_with_ipapi_co(ip_address) do
    url = "https://ipapi.co/#{ip_address}/json/"

    case make_http_request(url) do
      {:ok, %{"error" => true, "reason" => reason}} ->
        {:error, "ipapi.co error: #{reason}"}

      {:ok, data} when is_map(data) ->
        location = %{
          "country" => data["country_name"],
          "region" => data["region"],
          "city" => data["city"]
        }

        {:ok, location}

      {:error, reason} ->
        {:error, "HTTP request failed: #{reason}"}
    end
  end

  defp make_http_request(url) do
    case Finch.build(:get, url)
         |> Finch.request(PhoenixKit.Finch, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Invalid JSON response"}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, "Request exception: #{Exception.message(error)}"}
  end
end
