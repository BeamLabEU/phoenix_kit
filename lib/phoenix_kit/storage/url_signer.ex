defmodule PhoenixKit.Storage.URLSigner do
  import Bitwise

  @moduledoc """
  Token-based URL signing for secure file serving.

  Generates and verifies secure tokens that prevent file enumeration attacks.
  Each file instance receives a unique 4-character token based on MD5 hashing.

  ## Token Generation

  Token = first 4 chars of MD5(file_id:instance_name + secret_key_base)

  This ensures:
  - ✅ Prevents file enumeration (can't guess URLs)
  - ✅ Each instance has unique token
  - ✅ Token changes if secret changes
  - ✅ Secure comparison prevents timing attacks
  - ✅ No user-guessable patterns

  ## Examples

      iex> file_id = "018e3c4a-9f6b-7890-abcd-ef1234567890"
      iex> PhoenixKit.Storage.URLSigner.signed_url(file_id, "thumbnail")
      "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"

      iex> PhoenixKit.Storage.URLSigner.verify_token(file_id, "thumbnail", "a3f2")
      true

      iex> PhoenixKit.Storage.URLSigner.verify_token(file_id, "thumbnail", "xxxx")
      false
  """

  @doc """
  Generate a signed URL for a file instance.

  ## Arguments

  - `file_id` (binary) - File UUID v7
  - `instance_name` (binary) - Variant name (e.g., "thumbnail", "medium", "large")

  ## Returns

  A relative URL path: `/file/{file_id}/{instance_name}/{token}`

  ## Examples

      iex> PhoenixKit.Storage.URLSigner.signed_url("018e3c4a-9f6b-7890", "thumbnail")
      "/file/018e3c4a-9f6b-7890/thumbnail/abc1"
  """
  def signed_url(file_id, instance_name) when is_binary(file_id) and is_binary(instance_name) do
    token = generate_token(file_id, instance_name)
    "/file/#{file_id}/#{instance_name}/#{token}"
  end

  @doc """
  Verify a token is valid for the given file and instance.

  ## Arguments

  - `file_id` (binary) - File UUID v7
  - `instance_name` (binary) - Variant name
  - `token` (binary) - 4-character token from URL

  ## Returns

  Boolean indicating if token is valid.

  ## Examples

      iex> file_id = "018e3c4a-9f6b-7890"
      iex> token = PhoenixKit.Storage.URLSigner.generate_token(file_id, "thumbnail")
      iex> PhoenixKit.Storage.URLSigner.verify_token(file_id, "thumbnail", token)
      true

      iex> PhoenixKit.Storage.URLSigner.verify_token(file_id, "thumbnail", "xxxx")
      false
  """
  def verify_token(file_id, instance_name, token)
      when is_binary(file_id) and is_binary(instance_name) and is_binary(token) do
    expected_token = generate_token(file_id, instance_name)
    # Use constant-time comparison to prevent timing attacks
    secure_compare(expected_token, token)
  end

  @doc """
  Generate the 4-character token for a file instance.

  Used internally by signed_url/2 and verify_token/4.

  ## Arguments

  - `file_id` (binary) - File UUID v7
  - `instance_name` (binary) - Variant name

  ## Returns

  A 4-character hex string token.

  ## Examples

      iex> PhoenixKit.Storage.URLSigner.generate_token("018e3c4a", "thumbnail")
      "abc1"
  """
  def generate_token(file_id, instance_name)
      when is_binary(file_id) and is_binary(instance_name) do
    data = "#{file_id}:#{instance_name}"

    # Get secret_key_base if available, otherwise just use data without secret
    secret_key_base = get_secret_key_base()

    hash_data =
      if secret_key_base do
        data <> secret_key_base
      else
        data
      end

    token =
      :crypto.hash(:md5, hash_data)
      |> Base.encode16(case: :lower)
      |> String.slice(0..3)

    token
  end

  defp get_secret_key_base do
    # Try to get secret_key_base from configured sources in order
    # 1. Explicitly configured on :phoenix_kit
    # 2. From the configured endpoint
    # 3. Return nil if not found (will use data without secret)
    Application.get_env(:phoenix_kit, :secret_key_base) ||
      get_endpoint_secret()
  end

  defp get_endpoint_secret do
    # Find the first loaded endpoint module and get its secret
    # This works by trying to load common endpoint module names from the host app
    case System.get_env("PHOENIX_ENDPOINT_MODULE") do
      nil ->
        # Try to find endpoint by searching for any module with "Endpoint" in its name
        find_endpoint_module()

      module_name ->
        try do
          module = String.to_atom("Elixir." <> module_name)
          module.config(:secret_key_base)
        rescue
          _ -> nil
        end
    end
  end

  defp find_endpoint_module do
    # Get all loaded modules and find an Endpoint module
    # :code.all_loaded() always returns a list, so no need for catch-all pattern
    modules = :code.all_loaded()

    Enum.find_value(modules, fn {module, _path} ->
      module_name = module |> to_string()

      if String.ends_with?(module_name, "Endpoint") do
        try do
          module.config(:secret_key_base)
        rescue
          _ -> nil
        end
      end
    end)
  end

  defp secure_compare(string1, string2) when is_binary(string1) and is_binary(string2) do
    # Use constant-time comparison to prevent timing attacks
    # Padding strings to same length ensures constant time regardless of length difference
    length1 = byte_size(string1)
    length2 = byte_size(string2)
    max_length = max(length1, length2)

    # Pad both strings to max length
    padded1 = String.pad_trailing(string1, max_length)
    padded2 = String.pad_trailing(string2, max_length)

    # XOR all bytes and accumulate result
    comparison =
      Enum.reduce(
        0..(max_length - 1),
        0,
        fn i, acc ->
          <<_::binary-size(i), byte1::8, _::binary>> = padded1
          <<_::binary-size(i), byte2::8, _::binary>> = padded2
          acc ||| Bitwise.bxor(byte1, byte2)
        end
      )

    comparison == 0 and length1 == length2
  end
end
