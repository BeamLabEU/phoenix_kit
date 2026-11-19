defmodule PhoenixKit.API.OAuth.RedirectUri do
  @moduledoc """
  The rules for the places an authorization code may be sent: what a client may register.

  A registered URI is `https`, or `http` to the loopback (`127.0.0.1`, `[::1]` or
  `localhost`); it has a host, no userinfo, no fragment and no wildcard. Custom schemes
  (`app://`) are not supported.
  """

  @max_length 2048

  @doc "The longest URI accepted."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Whether `uri` may be registered: a string no longer than `max_length/0` that parses to an
  `https` URI, or an `http` one to a loopback host, with a host, no userinfo, no fragment, no
  wildcard (`*`) and no control character, and a port in 1..65535 when one is written.
  """
  @spec valid?(term()) :: boolean()
  def valid?(uri), do: match?({:ok, _parts}, parse(uri))

  defp parse(uri) when is_binary(uri) and byte_size(uri) <= @max_length do
    with true <- String.printable?(uri) and not String.contains?(uri, ["*", " ", "\\"]),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = parsed} <-
           URI.new(uri),
         scheme when scheme in ["http", "https"] <- scheme && String.downcase(scheme),
         true <- is_binary(host) and host != "",
         true <- usable_port?(uri, parsed),
         host = String.downcase(host),
         true <- scheme == "https" or loopback_host?(host) do
      {:ok,
       %{
         scheme: scheme,
         host: host,
         port: parsed.port,
         path: parsed.path || "",
         query: parsed.query
       }}
    else
      _ -> :error
    end
  end

  defp parse(_uri), do: :error

  # No port (the scheme's own) or one in 1..65535; a bare `:` after the host is no port either.
  defp usable_port?(uri, %URI{port: port}),
    do: port in 1..65_535 and not Regex.match?(~r{//[^/?#]*:(?:[/?#]|$)}, uri)

  defp loopback_host?(host), do: host in ["127.0.0.1", "::1", "[::1]", "localhost"]
end
