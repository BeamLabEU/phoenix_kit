defmodule PhoenixKit.Test.SoftAuthenticator do
  @moduledoc """
  A passkey authenticator in software, for tests: a real P-256 key, real CBOR, real
  signatures. It answers `PhoenixKit.Users.Passkeys.registration_options/1` and
  `authentication_options/0` the way a browser would, base64url-encoded, so the tests
  exercise `Wax`'s actual verification and not a stub.

      auth = SoftAuthenticator.new()
      {challenge, options} = Passkeys.registration_options(user)
      params = SoftAuthenticator.attest(auth, options)
      {:ok, passkey} = Passkeys.register(user, challenge, params, opts)

      {challenge, options} = Passkeys.authentication_options()
      params = SoftAuthenticator.assert(auth, options, user.uuid)
      {:ok, user} = Passkeys.authenticate(challenge, params)

  Options of both answers bend one thing to test a refusal: `:origin`, `:rp_id`,
  `:type`, `:challenge`, `:user_verified` (default `true`), `:sign_count`.
  """

  alias PhoenixKit.Users.Passkeys

  defstruct [:credential_id, :private_key, :x, :y, sign_count: 0]

  @type t :: %__MODULE__{}

  @doc "A new authenticator holding one passkey."
  @spec new() :: t()
  def new do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
      :crypto.generate_key(:ecdh, :secp256r1)

    %__MODULE__{
      credential_id: :crypto.strong_rand_bytes(16),
      private_key: private_key,
      x: x,
      y: y
    }
  end

  @doc "The answer of `navigator.credentials.create` to `options` (a registration)."
  @spec attest(t(), map(), keyword()) :: map()
  def attest(%__MODULE__{} = auth, options, opts \\ []) do
    rp_id = Keyword.get(opts, :rp_id, options["rp"]["id"])
    client_data = client_data(Keyword.get(opts, :type, "webauthn.create"), options, opts)

    cose_key =
      %{
        1 => 2,
        3 => -7,
        -1 => 1,
        -2 => %CBOR.Tag{tag: :bytes, value: auth.x},
        -3 => %CBOR.Tag{tag: :bytes, value: auth.y}
      }
      |> CBOR.encode()

    attested =
      <<0::128, byte_size(auth.credential_id)::16>> <> auth.credential_id <> cose_key

    auth_data =
      authenticator_data(rp_id, flags(opts, 0x40), Keyword.get(opts, :sign_count, 0)) <>
        attested

    attestation =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    %{
      "rawId" => encode(auth.credential_id),
      "attestationObject" => encode(attestation),
      "clientDataJSON" => encode(client_data),
      "transports" => ["internal", "hybrid"],
      "userAgent" =>
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Chrome/131.0"
    }
  end

  @doc """
  The answer of `navigator.credentials.get` to `options` (a sign-in) by the passkey of
  the user `user_uuid`.
  """
  @spec assert(t(), map(), String.t(), keyword()) :: map()
  def assert(%__MODULE__{} = auth, options, user_uuid, opts \\ []) do
    rp_id = Keyword.get(opts, :rp_id, options["rpId"])
    client_data = client_data(Keyword.get(opts, :type, "webauthn.get"), options, opts)
    auth_data = authenticator_data(rp_id, flags(opts, 0), Keyword.get(opts, :sign_count, 0))

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data),
        [auth.private_key, :secp256r1]
      )

    %{
      "rawId" => encode(auth.credential_id),
      "authenticatorData" => encode(auth_data),
      "clientDataJSON" => encode(client_data),
      "signature" => encode(signature),
      "userHandle" => encode(Keyword.get(opts, :user_handle, Passkeys.user_handle(user_uuid)))
    }
  end

  defp client_data(type, options, opts) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Keyword.get(opts, :challenge, options["challenge"]),
      "origin" => Keyword.get(opts, :origin, Passkeys.relying_party().origin),
      "crossOrigin" => false
    })
  end

  # user present, user verified (unless opted out), backup eligible and backed up.
  defp flags(opts, extra) do
    verified = if Keyword.get(opts, :user_verified, true), do: 0x04, else: 0
    0x01 + verified + 0x08 + 0x10 + extra
  end

  defp authenticator_data(rp_id, flags, sign_count) do
    :crypto.hash(:sha256, rp_id) <> <<flags::8, sign_count::32>>
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
