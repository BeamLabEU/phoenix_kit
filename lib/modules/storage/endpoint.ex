defmodule PhoenixKit.Modules.Storage.Endpoint do
  @moduledoc """
  The one reading of an S3-compatible endpoint, and the one guard on where the
  server may connect to.

  Three places name an endpoint: a bucket (`Providers.S3`), an
  `object_storage` Integrations connection (`Integrations.Validators`), and the
  bucket form. They must all read the same string the same way, or the server
  would connect to a different host than the one that was validated.

  ## Parsing

  `parse/1` accepts a bare host (`s3.us-west-002.backblazeb2.com`), host:port,
  or an `http`/`https` URL with no path (`http://minio.local:9000`); the scheme
  defaults to https. Refused rather than read as plain AWS: any other scheme, a
  path (a gateway prefix would be dropped silently), a query, and an IPv6 zone
  id (`%eth0`).

  ## Guarding

  The server connects to whatever endpoint it is given, so a user-supplied one
  is a request-forgery primitive. `check/3` classifies the addresses behind an
  endpoint by policy:

    * `:system` — set by an admin. Loopback and private ranges are allowed (a
      MinIO on the same network is a normal setup); what no storage endpoint
      can be is unspecified, link-local (where cloud metadata lives), multicast
      or reserved space, so those are refused.
    * `:personal` — set by an ordinary user. https only, and additionally no
      loopback, private, carrier-grade-NAT or unique-local address.

  A hostname is resolved and **every** address it yields is checked, so a name
  with one public and one private record is refused. The check sees DNS as of
  the moment it runs; it is not a connect-time pin, so a name that changes its
  answer between the check and the request is not caught. Callers run it at
  save and test time, and again each time a personal endpoint is used.
  """

  import Bitwise

  @type parsed :: %{scheme: String.t(), host: String.t(), port: pos_integer()}
  @type policy :: :system | :personal
  @type reason ::
          :invalid_endpoint
          | :insecure_scheme
          | :blocked_address
          | :blocked_host

  # Names that mean "the metadata service" without resolving to it from here.
  @blocked_hosts ["metadata.google.internal", "metadata", "instance-data"]

  @doc """
  An endpoint string, parsed: `%{scheme:, host:, port:}`; `nil` when none is
  set (plain AWS); `{:error, :invalid_endpoint}` when one is set but cannot be
  used.
  """
  @spec parse(term()) :: parsed() | nil | {:error, :invalid_endpoint}
  def parse(endpoint) when is_binary(endpoint) do
    case String.trim(endpoint) do
      "" -> nil
      trimmed -> parse_trimmed(trimmed)
    end
  end

  def parse(_endpoint), do: nil

  @doc """
  A URL's audit representation, with credentials, query and fragment withheld.
  Absolute local paths stay paths unless `local_path: false` (for CDN URLs).
  """
  @spec audit_value(String.t() | nil, keyword()) :: String.t() | nil
  def audit_value(value, opts \\ [])

  def audit_value(value, opts) when is_binary(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    cond do
      uri.host ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      String.starts_with?(value, "/") and Keyword.get(opts, :local_path, true) ->
        value

      String.starts_with?(value, "/") ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      true ->
        # Scheme-less endpoints are supported, too; keep their representation.
        uri = URI.parse("https://" <> value)

        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
        |> String.trim_leading("https://")
    end
  end

  def audit_value(value, _opts), do: value

  defp parse_trimmed(trimmed) do
    with_scheme =
      if trimmed =~ ~r{\A[a-zA-Z][a-zA-Z0-9+.-]*://}, do: trimmed, else: "https://" <> trimmed

    case URI.parse(with_scheme) do
      %URI{scheme: scheme, host: host, port: port, path: path, query: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        if String.contains?(trimmed, "%"),
          do: {:error, :invalid_endpoint},
          else: %{scheme: scheme, host: host, port: port}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  @doc """
  Whether the server may connect to `endpoint` (a string or the result of
  `parse/1`) under `policy`.

  `nil` (no endpoint, plain AWS) is always allowed. Options:

    * `:resolve` — look a hostname up and check every address it yields
      (default `false`; a literal IP is always checked). Off on hot paths,
      on wherever an endpoint is saved, tested, or used for a personal bucket.
    * `:resolver` — `(charlist, :inet | :inet6 -> {:ok, [ip]} | {:error, _})`,
      injectable for tests. Defaults to `:inet.getaddrs/2`.
  """
  @spec check(term(), policy(), keyword()) :: :ok | {:error, reason()}
  def check(endpoint, policy, opts \\ [])

  def check(endpoint, policy, opts) when is_binary(endpoint),
    do: check(parse(endpoint), policy, opts)

  def check(nil, _policy, _opts), do: :ok
  def check({:error, _reason} = error, _policy, _opts), do: error

  def check(%{scheme: scheme, host: host}, policy, opts) when policy in [:system, :personal] do
    cond do
      policy == :personal and scheme != "https" -> {:error, :insecure_scheme}
      String.downcase(host) in @blocked_hosts -> {:error, :blocked_host}
      true -> check_addresses(host, policy, opts)
    end
  end

  defp check_addresses(host, policy, opts) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> check_ip(ip, policy)
      {:error, _} -> check_resolved(host, policy, opts)
    end
  end

  defp check_resolved(host, policy, opts) do
    if Keyword.get(opts, :resolve, false) do
      resolver = Keyword.get(opts, :resolver, &:inet.getaddrs/2)
      name = String.to_charlist(host)

      # A name that does not resolve is not refused here: the request that
      # follows fails with "could not reach", which is the truthful message.
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case resolver.(name, family) do
          {:ok, ips} -> ips
          {:error, _reason} -> []
        end
      end)
      |> Enum.find_value(:ok, fn ip ->
        case check_ip(ip, policy) do
          :ok -> nil
          error -> error
        end
      end)
    else
      :ok
    end
  end

  defp check_ip(ip, policy) do
    case classify(ip) do
      class when class in [:unspecified, :link_local, :multicast, :reserved] ->
        {:error, :blocked_address}

      class when class in [:loopback, :private, :shared, :unique_local] ->
        if policy == :personal, do: {:error, :blocked_address}, else: :ok

      :public ->
        :ok
    end
  end

  @doc """
  The class of an address: `:public`, or what makes it not one
  (`:unspecified`, `:loopback`, `:private`, `:shared`, `:link_local`,
  `:unique_local`, `:multicast`, `:reserved`). An IPv4 address wrapped in IPv6
  (`::ffff:a.b.c.d`, NAT64 `64:ff9b::/96`) is classified as the IPv4 address.
  """
  @spec classify(:inet.ip_address()) :: atom()
  def classify({0, _, _, _}), do: :unspecified
  def classify({127, _, _, _}), do: :loopback
  def classify({10, _, _, _}), do: :private
  def classify({172, b, _, _}) when b in 16..31, do: :private
  def classify({192, 168, _, _}), do: :private
  def classify({169, 254, _, _}), do: :link_local
  def classify({100, b, _, _}) when b in 64..127, do: :shared
  def classify({192, 0, 0, _}), do: :reserved
  def classify({198, b, _, _}) when b in 18..19, do: :reserved
  def classify({a, _, _, _}) when a in 224..239, do: :multicast
  def classify({a, _, _, _}) when a >= 240, do: :reserved
  def classify({_, _, _, _}), do: :public

  def classify({0, 0, 0, 0, 0, 0, 0, 0}), do: :unspecified
  def classify({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback
  def classify({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: classify(embedded_v4(hi, lo))
  def classify({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: classify(embedded_v4(hi, lo))
  def classify({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: :unique_local
  def classify({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: :link_local
  def classify({first, _, _, _, _, _, _, _}) when (first &&& 0xFF00) == 0xFF00, do: :multicast
  def classify({_, _, _, _, _, _, _, _}), do: :public

  defp embedded_v4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  @doc "An operator-facing sentence for a `check/3` or `parse/1` error."
  @spec error_message(reason()) :: String.t()
  def error_message(:invalid_endpoint),
    do: "must be a host, host:port, or an http(s) URL with no path"

  def error_message(:insecure_scheme), do: "must use https"

  def error_message(reason) when reason in [:blocked_address, :blocked_host],
    do: "must not point at a local, private or metadata address"
end
