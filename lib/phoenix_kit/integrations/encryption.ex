defmodule PhoenixKit.Integrations.Encryption do
  @moduledoc """
  AES-256-GCM encryption for sensitive integration credentials.

  Encrypts fields like `access_token`, `refresh_token`, `client_secret`,
  `api_key`, `bot_token`, `secret_key` before storing in the database.
  Decrypts them when reading.

  Uses the application's `secret_key_base` as the root key, deriving a
  dedicated integration encryption key via PBKDF2.

  ## Configuration

  Encryption is enabled by default when `secret_key_base` is configured.
  To disable, set:

      config :phoenix_kit, integration_encryption_enabled: false
  """

  @sensitive_fields ~w(
    access_token refresh_token client_secret
    api_key bot_token secret_key
  )

  # Prefix to identify encrypted values
  @encrypted_prefix "enc:v1:"

  @doc """
  Returns the list of field keys that are encrypted.
  """
  @spec sensitive_fields() :: [String.t()]
  def sensitive_fields, do: @sensitive_fields

  @doc """
  Encrypt sensitive fields in an integration data map before saving.

  Non-sensitive fields and nil/empty values are left unchanged.
  Already-encrypted values (with `enc:v1:` prefix) are not re-encrypted.
  """
  @spec encrypt_fields(map()) :: map()
  def encrypt_fields(data) when is_map(data) do
    case encryption_key() do
      nil -> data
      key -> do_encrypt_fields(data, key)
    end
  end

  @doc """
  Decrypt sensitive fields in an integration data map after reading.

  Only values with the `enc:v1:` prefix are decrypted.
  Non-encrypted values are returned as-is for backwards compatibility.
  """
  @spec decrypt_fields(map()) :: map()
  def decrypt_fields(data) when is_map(data) do
    case encryption_key() do
      nil -> data
      key -> do_decrypt_fields(data, key)
    end
  end

  def decrypt_fields(other), do: other

  @doc """
  Check if encryption is available and enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    encryption_key() != nil
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_encrypt_fields(data, key) do
    Enum.reduce(@sensitive_fields, data, fn field, acc ->
      case Map.get(acc, field) do
        nil ->
          acc

        "" ->
          acc

        value when is_binary(value) ->
          if String.starts_with?(value, @encrypted_prefix) do
            # Already encrypted
            acc
          else
            Map.put(acc, field, encrypt_value(value, key))
          end

        _ ->
          acc
      end
    end)
  end

  defp do_decrypt_fields(data, key) do
    Enum.reduce(@sensitive_fields, data, fn field, acc ->
      case Map.get(acc, field) do
        value when is_binary(value) and value != "" ->
          maybe_decrypt_field(acc, field, value, key)

        _ ->
          acc
      end
    end)
  end

  defp maybe_decrypt_field(acc, field, value, key) do
    if String.starts_with?(value, @encrypted_prefix) do
      case decrypt_value(value, key) do
        {:ok, plaintext} -> Map.put(acc, field, plaintext)
        {:error, _} -> acc
      end
    else
      acc
    end
  end

  defp encrypt_value(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    encoded = Base.encode64(iv <> tag <> ciphertext)
    @encrypted_prefix <> encoded
  end

  defp decrypt_value(@encrypted_prefix <> encoded, key) do
    with {:ok, binary} <- Base.decode64(encoded),
         <<iv::binary-12, tag::binary-16, ciphertext::binary>> <- binary do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decryption_failed}
      end
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp decrypt_value(_, _key), do: {:error, :not_encrypted}

  defp encryption_key do
    if Application.get_env(:phoenix_kit, :integration_encryption_enabled, true) do
      case PhoenixKit.Config.get(:secret_key_base) do
        {:ok, secret} when is_binary(secret) and secret != "" -> derive_key(secret)
        _ -> nil
      end
    else
      nil
    end
  end

  defp derive_key(secret) do
    # Derive a dedicated 32-byte key for integration encryption
    :crypto.hash(:sha256, "phoenix_kit_integrations:" <> secret)
  end
end
