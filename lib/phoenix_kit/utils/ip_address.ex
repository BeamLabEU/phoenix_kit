defmodule PhoenixKit.Utils.IpAddress do
  @moduledoc """
  Utilities for extracting and formatting IP addresses.

  Supports both IPv4 and IPv6 addresses with proper error handling.
  Prevents Protocol.UndefinedError when working with IPv6 tuples.

  ## Usage

  Extract from LiveView socket:
      ip = PhoenixKit.Utils.IpAddress.extract_from_socket(socket)

  Extract from Plug.Conn:
      ip = PhoenixKit.Utils.IpAddress.extract_from_conn(conn)

  Extract from peer_data directly:
      ip = PhoenixKit.Utils.IpAddress.extract_ip_address(%{address: {192, 168, 1, 1}})

  ## Examples

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(%{address: {192, 168, 1, 1}})
      "192.168.1.1"

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(%{address: {8193, 3512, 1, 0, 0, 0, 0, 1}})
      "8193:3512:1:0:0:0:0:1"

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(nil)
      "unknown"

      iex> PhoenixKit.Utils.IpAddress.extract_ip_address(%{})
      "unknown"
  """

  @doc """
  Extracts IP address from peer_data map.

  Handles both IPv4 (4-tuple) and IPv6 (8-tuple) addresses.
  Returns "unknown" for nil, invalid, or missing data.

  ## Parameters

  - `peer_data`: Map with `:address` key containing IP tuple, or nil

  ## Returns

  - IPv4 as "a.b.c.d" string
  - IPv6 as "a:b:c:d:e:f:g:h" string
  - "unknown" for invalid or missing data
  """
  def extract_ip_address(nil), do: "unknown"

  def extract_ip_address(%{address: {a, b, c, d}})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  def extract_ip_address(%{address: {a, b, c, d, e, f, g, h}})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
             is_integer(e) and is_integer(f) and is_integer(g) and is_integer(h) do
    "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  end

  def extract_ip_address(_), do: "unknown"

  @doc """
  Extracts IP address from Plug.Conn using get_peer_data.

  Convenience function that extracts peer_data and formats the IP.

  ## Parameters

  - `conn`: Plug.Conn struct

  ## Returns

  - IP address string or "unknown"
  """
  def extract_from_conn(conn) do
    conn
    |> Plug.Conn.get_peer_data()
    |> extract_ip_address()
  end

  @doc """
  Extracts IP address from Phoenix.LiveView socket using get_connect_info.

  Convenience function that extracts peer_data from socket and formats the IP.

  ## Parameters

  - `socket`: Phoenix.LiveView.Socket struct

  ## Returns

  - IP address string or "unknown"
  """
  def extract_from_socket(socket) do
    socket
    |> Phoenix.LiveView.get_connect_info(:peer_data)
    |> extract_ip_address()
  end
end
