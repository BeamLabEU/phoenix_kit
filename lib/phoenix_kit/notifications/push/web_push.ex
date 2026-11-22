defmodule PhoenixKit.Notifications.Push.WebPush do
  @moduledoc """
  The Web Push protocol, with nothing but `:crypto`: the site's VAPID key
  (RFC 8292), the payload encryption (RFC 8291, `aes128gcm`), and one send to
  a push service (RFC 8030).

  ## The VAPID key

  One P-256 key pair per site, made the first time it is needed and kept in
  settings (`push_vapid_key`), the private half encrypted with
  `PhoenixKit.Integrations.Encryption`. Every node reads the same one. A
  browser's subscription is bound to the public key it was made with, so the
  key is never rotated as routine: changing it is a break-glass step (keep
  the old key to send to old subscriptions, which re-subscribe on their next
  visit; `vapid_key_id` on each installation says which key it holds).

  ## Where it sends

  A subscription's endpoint is an address this server POSTs to, so it is
  checked before it is stored and again before every send (`endpoint_ok?/1`):
  HTTPS, a host of a known push service (`@push_hosts`, plus
  `config :phoenix_kit, :push_service_hosts`), and no address the host
  resolves to may be private or reserved. No redirects, short timeouts.
  """

  require Logger

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Mailer
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Utils.PublicAddress
  alias PhoenixKit.Utils.Routes

  @key_setting "push_vapid_key"

  # The push services of the browsers people use: Chrome/Edge/Brave/Opera
  # (FCM), Firefox (Mozilla autopush), Safari (Apple), legacy Edge (WNS).
  @push_hosts [
    "fcm.googleapis.com",
    "android.googleapis.com",
    "updates.push.services.mozilla.com",
    {:suffix, ".push.services.mozilla.com"},
    "web.push.apple.com",
    {:suffix, ".push.apple.com"},
    {:suffix, ".notify.windows.com"}
  ]

  # RFC 8291's record size, and the plaintext budget of one record of the
  # 4,096-byte message: 4,096 - 86 (header) - 16 (tag) - 1 (delimiter).
  @record_size 4_096
  @max_plaintext 3_993

  @doc "The maximum payload, in bytes, before encryption."
  def max_plaintext, do: @max_plaintext

  # ── The VAPID key ─────────────────────────────────────────────────────

  @doc """
  The site's VAPID key: `%{id, public, private}` (raw bytes; `public` is the
  65-byte uncompressed point). Made and stored on first use.
  """
  @spec vapid_key() :: {:ok, map()} | {:error, term()}
  def vapid_key do
    case RepoHelper.repo().get_by(Setting, key: @key_setting) do
      nil -> initialize_vapid_key()
      %Setting{value: empty} when empty in [nil, ""] -> initialize_vapid_key()
      setting -> decode_vapid_key(setting)
    end
  end

  defp initialize_vapid_key do
    repo = RepoHelper.repo()

    repo.transact(fn ->
      repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@key_setting])

      case repo.get_by(Setting, key: @key_setting) do
        nil ->
          create_vapid_key(%Setting{})

        %Setting{value: empty, value_json: nil} = row when empty in [nil, ""] ->
          create_vapid_key(row)

        row ->
          decode_vapid_key(row)
      end
    end)
  end

  defp decode_vapid_key(%Setting{value: value}) do
    with true <- Encryption.encrypted?(value),
         {:ok, json} <- Encryption.decrypt_value(value),
         {:ok, %{"id" => id, "public" => pub, "private" => priv}} <- Jason.decode(json),
         {:ok, <<4, _::binary-size(64)>> = pub} <- Base.url_decode64(pub, padding: false),
         {:ok, <<_::256>> = priv} <- Base.url_decode64(priv, padding: false) do
      {:ok, %{id: id, public: pub, private: priv}}
    else
      _ -> {:error, :unreadable_vapid_key}
    end
  end

  @doc "The public key as a browser takes it (`applicationServerKey`): unpadded base64url."
  @spec public_key_b64() :: String.t() | nil
  def public_key_b64 do
    case vapid_key() do
      {:ok, %{public: pub}} -> Base.url_encode64(pub, padding: false)
      _ -> nil
    end
  end

  @doc "The id of the current key."
  @spec vapid_key_id() :: String.t() | nil
  def vapid_key_id do
    case vapid_key() do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp create_vapid_key(row) do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    priv = pad(priv, 32)
    id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    value = %{
      "id" => id,
      "public" => Base.url_encode64(pub, padding: false),
      "private" => Base.url_encode64(priv, padding: false),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    changeset =
      Setting.changeset(row, %{
        key: @key_setting,
        value: Jason.encode!(value),
        module: "notifications"
      })

    with true <-
           Encryption.encrypted?(Ecto.Changeset.get_field(changeset, :value)) ||
             {:error, :encryption_unavailable},
         {:ok, stored} <- RepoHelper.repo().insert_or_update(changeset, log: false) do
      decode_vapid_key(stored)
    end
  end

  # ── VAPID (RFC 8292) ──────────────────────────────────────────────────

  @doc """
  The `Authorization` header for a send to `endpoint`: `vapid t=<JWT>,
  k=<public key>`, the JWT's audience being the endpoint's origin, valid for
  12 hours.
  """
  @spec authorization(String.t(), map(), String.t()) :: String.t()
  def authorization(endpoint, %{public: pub, private: priv}, subject) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    # An origin's host is lowercase (RFC 6454), and a strict service compares.
    host = String.downcase(host)

    aud =
      if port in [nil, 443] and scheme == "https",
        do: "https://#{host}",
        else: "#{scheme}://#{host}:#{port}"

    header = b64(Jason.encode!(%{typ: "JWT", alg: "ES256"}))

    claims =
      b64(Jason.encode!(%{aud: aud, exp: System.system_time(:second) + 12 * 3600, sub: subject}))

    input = header <> "." <> claims
    der = :crypto.sign(:ecdsa, :sha256, input, [priv, :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    signature = pad(:binary.encode_unsigned(r), 32) <> pad(:binary.encode_unsigned(s), 32)

    "vapid t=#{input}.#{b64(signature)}, k=#{b64(pub)}"
  end

  # ── Encryption (RFC 8291) ─────────────────────────────────────────────

  @doc """
  Encrypts `plaintext` for a subscription (`p256dh` and `auth`, base64url) as
  one `aes128gcm` record. `opts` take `:salt` and `:server_key` (`{public,
  private}`) only for the RFC's test vector.
  """
  @spec encrypt(binary(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def encrypt(plaintext, p256dh, auth, opts \\ []) when is_binary(plaintext) do
    with :ok <- fits(plaintext),
         {:ok, ua_public} <- decode_key(p256dh, 65),
         {:ok, auth_secret} <- decode_key(auth, 16) do
      {as_public, as_private} =
        Keyword.get_lazy(opts, :server_key, fn -> :crypto.generate_key(:ecdh, :prime256v1) end)

      salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)
      shared = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)

      key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
      prk_key = hmac(auth_secret, shared)
      ikm = binary_part(hmac(prk_key, key_info <> <<1>>), 0, 32)

      prk = hmac(salt, ikm)
      cek = binary_part(hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
      nonce = binary_part(hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, "", true)

      header = salt <> <<@record_size::32, byte_size(as_public)::8>> <> as_public
      {:ok, header <> ciphertext <> tag}
    end
  rescue
    error -> {:error, {:encrypt, error.__struct__}}
  end

  defp fits(plaintext) do
    if byte_size(plaintext) <= @max_plaintext, do: :ok, else: {:error, :payload_too_large}
  end

  defp decode_key(value, size) when is_binary(value) do
    case Base.url_decode64(String.trim_trailing(value, "="), padding: false) do
      {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
      _ -> {:error, :bad_subscription_key}
    end
  end

  defp decode_key(_value, _size), do: {:error, :bad_subscription_key}

  # ── Where it sends ────────────────────────────────────────────────────

  @doc """
  Whether a subscription endpoint may be sent to: HTTPS, the host of a known
  push service, and no address it resolves to private or reserved.
  `resolve: false` skips the DNS step (the subscribe form checks the shape;
  every send resolves).
  """
  @spec endpoint_ok?(String.t(), keyword()) :: boolean()
  def endpoint_ok?(endpoint, opts \\ [])

  def endpoint_ok?(endpoint, opts) when is_binary(endpoint) and byte_size(endpoint) <= 2_048 do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        known_host?(String.downcase(host)) and
          (not resolve?(opts) or public_host?(host))

      _ ->
        false
    end
  end

  def endpoint_ok?(_endpoint, _opts), do: false

  # `resolve: false` (the subscribe form's shape check), or
  # `config :phoenix_kit, :push_resolve_endpoints, false` (a test suite with
  # no DNS) skips the lookup. On by default.
  defp resolve?(opts) do
    Keyword.get(opts, :resolve, true) and
      Application.get_env(:phoenix_kit, :push_resolve_endpoints, true) != false
  end

  defp known_host?(host) do
    hosts = @push_hosts ++ Application.get_env(:phoenix_kit, :push_service_hosts, [])

    Enum.any?(hosts, fn
      {:suffix, suffix} -> String.ends_with?(host, suffix)
      exact when is_binary(exact) -> host == String.downcase(exact)
      _ -> false
    end)
  end

  defp public_host?(host) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, list} <- [:inet.getaddrs(String.to_charlist(host), family)],
          address <- list,
          do: address

    addresses != [] and Enum.all?(addresses, &PublicAddress.public?/1)
  rescue
    _ -> false
  end

  # ── Sending (RFC 8030) ────────────────────────────────────────────────

  @doc """
  Sends one encrypted payload to one subscription. Options: `:ttl` (seconds),
  `:urgency` (`"very-low" | "low" | "normal" | "high"`), `:topic` (≤ 32
  URL-safe characters: a newer message with the same topic replaces one the
  service still holds).

  `:ok`, `{:gone, status}` (404/410: the subscription is dead), `{:retry,
  ms | nil}` (429/5xx/network) or `{:error, reason}` (anything else, e.g. a
  key mismatch: 401/403).
  """
  @spec send(map(), binary(), keyword()) ::
          :ok | {:gone, integer()} | {:retry, integer() | nil} | {:error, term()}
  def send(%{endpoint: endpoint, p256dh: p256dh, auth: auth}, payload, opts \\ []) do
    with true <- endpoint_ok?(endpoint) || {:error, :endpoint_refused},
         {:ok, key} <- vapid_key(),
         {:ok, body} <- encrypt(payload, p256dh, auth) do
      headers = request_headers(endpoint, key, opts)

      request =
        [url: endpoint, body: body, headers: headers]
        |> Keyword.merge(
          request_options(Application.get_env(:phoenix_kit, :push_req_options, []))
        )

      request |> Req.post() |> result()
    end
  end

  @doc false
  # Host options (`config :phoenix_kit, :push_req_options`, the test plug
  # among them) may set timeouts and adapters. They may not turn redirects
  # or Req's retries back on: a redirect would POST the encrypted body to
  # whatever a push service answers with, past `endpoint_ok?/1`.
  def request_options(extra) when is_list(extra) do
    [receive_timeout: 10_000, connect_options: [timeout: 5_000]]
    |> Keyword.merge(extra)
    |> Keyword.merge(retry: false, redirect: false)
  end

  @doc false
  # The headers of a send. (A test reads them here: Req's test adapter takes
  # `content-encoding` for compression it should undo and drops it, which a
  # real request never does.)
  def request_headers(endpoint, key, opts) do
    [
      {"authorization", authorization(endpoint, key, subject())},
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", to_string(Keyword.get(opts, :ttl, 7 * 24 * 3600))},
      {"urgency", Keyword.get(opts, :urgency, "normal")}
    ] ++ topic(opts[:topic])
  end

  defp topic(nil), do: []

  defp topic(topic) when is_binary(topic) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,32}\z/, topic), do: [{"topic", topic}], else: []
  end

  defp result({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp result({:ok, %{status: status}}) when status in [404, 410], do: {:gone, status}

  defp result({:ok, %{status: status} = response}) when status == 429 or status >= 500,
    do: {:retry, retry_after(response)}

  defp result({:ok, %{status: status}}), do: {:error, {:status, status}}
  defp result({:error, _exception}), do: {:retry, nil}

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} <- Integer.parse(value) do
      seconds * 1_000
    else
      _ -> nil
    end
  end

  # The VAPID `sub`: who to contact about this sender.
  defp subject do
    case Mailer.get_from_email() do
      email when is_binary(email) and email != "" -> "mailto:" <> email
      _ -> Routes.base_url()
    end
  rescue
    _ -> Routes.base_url()
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp b64(data), do: Base.url_encode64(data, padding: false)

  defp pad(bytes, size) when byte_size(bytes) >= size,
    do: binary_part(bytes, byte_size(bytes) - size, size)

  defp pad(bytes, size), do: :binary.copy(<<0>>, size - byte_size(bytes)) <> bytes
end
