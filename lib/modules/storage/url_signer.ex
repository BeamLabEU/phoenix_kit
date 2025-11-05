defmodule PhoenixKit.Storage.URLSigner do
  @moduledoc """
  Token generation and verification for secure file URLs.

  Generates short tokens (4 characters) to prevent file enumeration attacks.
  Each file instance has a unique token based on its ID and variant name.

  ## URL Format

      https://site.com/file/{file_id}/{instance_name}/{token}

  ## Example

      # Generate signed URL
      URLSigner.signed_url("018e3c4a-9f6b-7890-abcd-ef1234567890", "thumbnail")
      # => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"

      # Verify token
      URLSigner.verify_token("018e3c4a-9f6b-7890-abcd-ef1234567890", "thumbnail", "a3f2")
      # => true

  ## Security

  - Prevents enumeration: Can't guess valid URLs without knowing the secret
  - Unique per instance: Different variants have different tokens
  - Secure comparison: Prevents timing attacks
  - Rotates with secret: Tokens change if secret_key_base changes

  ## Token Generation

  Token = first 4 chars of MD5(file_id:instance_name + secret_key_base)

      data = "018e3c4a-9f6b-7890-abcd-ef1234567890:thumbnail"
      secret = Application.get_env(:phoenix_kit, :secret_key_base)
      token = :crypto.hash(:md5, data <> secret)
              |> Base.encode16(case: :lower)
              |> String.slice(0..3)
      # => "a3f2"
  """

  @doc """
  Generates a token for a file instance.

  ## Parameters

  - `file_id` - UUIDv7 of the file
  - `instance_name` - Variant name (original, thumbnail, medium, etc.)

  ## Examples

      iex> URLSigner.generate_token("018e3c4a-9f6b-7890-abcd-ef1234567890", "thumbnail")
      "a3f2"

      iex> URLSigner.generate_token("018e3c4a-9f6b-7890-abcd-ef1234567890", "medium")
      "b7e5"
  """
  def generate_token(file_id, instance_name)
      when is_binary(file_id) and is_binary(instance_name) do
    secret = get_secret_key_base()
    data = "#{file_id}:#{instance_name}"

    :crypto.hash(:md5, data <> secret)
    |> Base.encode16(case: :lower)
    |> String.slice(0..3)
  end

  @doc """
  Verifies a token for a file instance.

  Uses secure comparison to prevent timing attacks.

  ## Parameters

  - `file_id` - UUIDv7 of the file
  - `instance_name` - Variant name
  - `token` - Token to verify (4 characters)

  ## Examples

      iex> URLSigner.verify_token("018e3c4a-...", "thumbnail", "a3f2")
      true

      iex> URLSigner.verify_token("018e3c4a-...", "thumbnail", "wrong")
      false
  """
  def verify_token(file_id, instance_name, token)
      when is_binary(file_id) and is_binary(instance_name) and is_binary(token) do
    expected = generate_token(file_id, instance_name)
    Plug.Crypto.secure_compare(token, expected)
  end

  @doc """
  Generates a signed URL for a file instance.

  ## Parameters

  - `file_id` - UUIDv7 of the file
  - `instance_name` - Variant name

  ## Examples

      iex> URLSigner.signed_url("018e3c4a-9f6b-7890-abcd-ef1234567890", "thumbnail")
      "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"

      iex> URLSigner.signed_url("018e3c4a-9f6b-7890-abcd-ef1234567890", "medium")
      "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/medium/b7e5"
  """
  def signed_url(file_id, instance_name)
      when is_binary(file_id) and is_binary(instance_name) do
    token = generate_token(file_id, instance_name)
    "/file/#{file_id}/#{instance_name}/#{token}"
  end

  @doc """
  Generates a full signed URL with host.

  ## Parameters

  - `file_id` - UUIDv7 of the file
  - `instance_name` - Variant name
  - `host` - Base URL (e.g., "https://example.com")

  ## Examples

      iex> URLSigner.signed_url_with_host("018e3c4a-...", "thumbnail", "https://example.com")
      "https://example.com/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"
  """
  def signed_url_with_host(file_id, instance_name, host)
      when is_binary(file_id) and is_binary(instance_name) and is_binary(host) do
    path = signed_url(file_id, instance_name)
    host = String.trim_trailing(host, "/")
    "#{host}#{path}"
  end

  # Private helper to get secret_key_base

  defp get_secret_key_base do
    Application.get_env(:phoenix_kit, :secret_key_base) ||
      raise """
      PhoenixKit secret_key_base not configured!

      Add to your config/config.exs:

          config :phoenix_kit,
            secret_key_base: "your-secret-key-base"

      Or set it dynamically from your app's endpoint secret.
      """
  end
end
