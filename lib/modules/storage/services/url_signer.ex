defmodule PhoenixKit.Modules.Storage.URLSigner do
  # NOTE: Temporarily supporting the Publishing component system until the storage/media team ships their replacement.
  import Bitwise
  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @moduledoc """
  Token-based URL signing for secure file serving.

  Generates and verifies secure tokens that prevent file enumeration attacks.
  Each file instance receives a unique 4-character token based on MD5 hashing.

  ## Token Generation

  Token = first 4 chars of MD5(file_uuid:instance_name + secret_key_base)

  This ensures:
  - Prevents file enumeration (can't guess URLs)
  - Each instance has unique token
  - Token changes if secret changes
  - Secure comparison prevents timing attacks
  - No user-guessable patterns

  ## Examples

      iex> file_uuid = "018e3c4a-9f6b-7890-abcd-ef1234567890"
      iex> PhoenixKit.Modules.Storage.URLSigner.signed_url(file_uuid, "thumbnail")
      "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"

      iex> PhoenixKit.Modules.Storage.URLSigner.verify_token(file_uuid, "thumbnail", "a3f2")
      true

      iex> PhoenixKit.Modules.Storage.URLSigner.verify_token(file_uuid, "thumbnail", "xxxx")
      false
  """

  @doc """
  Checks a file-serving URL minted by `signed_url/3` — the parsing and the
  token rule the file route itself applies — and returns what it points at.

  Accepts a full URL or a path, with or without the kit's URL prefix and a
  locale segment: `".../file/<uuid>/<variant>/<token>?v=<version>"`.

  Returns `{:ok, %{uuid: uuid, variant: variant, version: version | nil}}`,
  or `{:error, reason}` with `:malformed` (not a file URL), `:not_found`
  (no such file, a system-managed one, or a trashed one), `:invalid_token`
  or `:expired_token` (a private file's time-window token that has run out).

  **`{:ok, _}` means well-formed and signed by this app, not authorized.** A
  public file's token is short and permanent — it stops URL guessing, it
  does not grant access. Check the viewer's rights to the file separately
  before acting on it. Needs the database: whether a file is private is a
  property of its library.

  Only the path is checked — `/file/<uuid>/<variant>/<token>` — never the
  scheme or host, so `https://anywhere.example/file/…` verifies too. Act on
  the returned uuid (rebuild the URL from it); never fetch or render the
  string you were handed.

  ## Options

    * `:allow_trashed` — also accept a trashed file (default `false`).
  """
  @spec verify_url(String.t(), keyword()) ::
          {:ok, %{uuid: String.t(), variant: String.t(), version: String.t() | nil}}
          | {:error, :malformed | :not_found | :invalid_token | :expired_token}
  def verify_url(url, opts \\ [])

  def verify_url(url, opts) when is_binary(url) do
    %URI{path: path, query: query} = URI.parse(url)

    with ["file", raw_uuid, variant, token] <- path |> to_string() |> file_segments(),
         {:ok, uuid} <- cast_uuid(raw_uuid),
         {:ok, file} <- servable_file(uuid, opts),
         :ok <- verify_file_token(file, variant, token) do
      {:ok, %{uuid: uuid, variant: variant, version: query_version(query)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :malformed}
    end
  end

  def verify_url(_url, _opts), do: {:error, :malformed}

  @doc """
  The token rule the file route applies: a file in a private library takes
  only a time-window token (its permanent one is refused); every other
  file only its permanent token.
  """
  @spec verify_file_token(map(), String.t(), String.t()) ::
          :ok | {:error, :invalid_token | :expired_token}
  def verify_file_token(file, variant, token) do
    if Libraries.private_file?(file) do
      case verify_private_token(file.uuid, variant, token) do
        :ok -> :ok
        :expired -> {:error, :expired_token}
        :invalid -> {:error, :invalid_token}
      end
    else
      if verify_token(file.uuid, variant, token),
        do: :ok,
        else: {:error, :invalid_token}
    end
  end

  # The last four path segments of a file URL, whatever prefix or locale
  # segment comes before them.
  defp file_segments(path) do
    segments = String.split(path, "/", trim: true)

    case Enum.drop(segments, max(length(segments) - 4, 0)) do
      ["file", _uuid, _variant, _token] = tail -> tail
      _ -> :malformed
    end
  end

  defp cast_uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :malformed
    end
  end

  defp servable_file(uuid, opts) do
    case Storage.get_file(uuid) do
      nil ->
        {:error, :not_found}

      %{system_managed: true} ->
        {:error, :not_found}

      %{status: "trashed"} = file ->
        if opts[:allow_trashed], do: {:ok, file}, else: {:error, :not_found}

      file ->
        {:ok, file}
    end
  end

  defp query_version(nil), do: nil
  defp query_version(query), do: query |> URI.decode_query() |> Map.get("v")

  @doc """
  Generate a signed URL for a file instance.

  ## Arguments

  - `file_uuid` (binary) - File UUID v7
  - `instance_name` (binary) - Variant name (e.g., "thumbnail", "medium", "large")

  ## Returns

  A relative URL path with prefix: `{url_prefix}/file/{file_uuid}/{instance_name}/{token}`

  ## Options

  - `:version` - the served instance (or its checksum): see `version/1`
  - `:locale` - passed to `Routes.path/2` (default `:none`)
  - `:private` - `true` for a file in a private library
    (`PhoenixKit.Modules.Storage.Libraries.private?/1`): the URL carries a
    time-window token instead of the permanent one, and stops working when
    its window ends. The file route refuses a private file's permanent
    token. Mint these only after checking that the viewer may see the file
    (`Storage.authorized_url/4` does both).

  ## Examples

      iex> PhoenixKit.Modules.Storage.URLSigner.signed_url("018e3c4a-9f6b-7890", "thumbnail")
      "/phoenix_kit/file/018e3c4a-9f6b-7890/thumbnail/abc1"  # With default prefix
  """
  def signed_url(file_uuid, instance_name, opts \\ [])
      when is_binary(file_uuid) and is_binary(instance_name) do
    token = url_token(file_uuid, instance_name, opts)
    file_path = "/file/#{file_uuid}/#{instance_name}/#{token}"
    locale_option = Keyword.get(opts, :locale, :none)
    path = Routes.path(file_path, locale: locale_option)

    case version(Keyword.get(opts, :version)) do
      nil -> path
      v -> path <> "?v=" <> v
    end
  end

  @doc """
  The content version a file URL carries: the first 16 hex characters of the
  served instance's checksum (pass the instance or the checksum).

  A URL with a version is content-addressed: `FileController` serves it with
  a year-long `immutable` lifetime only while it names the bytes the variant
  holds now, and redirects to the current version otherwise — so a cached
  copy can never be different bytes (an edited or redacted image). Build URLs
  with `signed_url(uuid, variant, version: instance)` wherever the instance
  is at hand; an unversioned URL still works and is revalidated.
  """
  @spec version(term()) :: String.t() | nil
  def version(%{checksum: checksum}), do: version(checksum)

  def version(checksum) when is_binary(checksum) and byte_size(checksum) >= 16,
    do: checksum |> binary_part(0, 16) |> String.downcase()

  def version(_), do: nil

  # A private library's file gets a time-window token; everything else keeps
  # the permanent one.
  defp url_token(file_uuid, instance_name, opts) do
    if Keyword.get(opts, :private, false),
      do: private_token(file_uuid, instance_name, window_end(System.os_time(:second))),
      else: generate_token(file_uuid, instance_name)
  end

  # ============================================================================
  # Time-window tokens, for files in a private library (V203)
  # ============================================================================
  #
  # `w<expiry in base 36>-<HMAC>`: an HMAC-SHA256 (keyed from
  # `secret_key_base`) over the file uuid, the variant and the expiry. The
  # expiry is rounded UP to a fixed window (`private_url_window_seconds/0`),
  # so within one window the same image has the same URL and browser caches
  # keep working; and it is taken at least a quarter of a window ahead, so a
  # URL is never handed out with only minutes left. A legacy token is four
  # hex digits and never starts with `w`.

  @doc """
  Whether `token` has the time-window shape (it may still be wrong or
  expired: see `verify_private_token/4`).
  """
  @spec private_token?(term()) :: boolean()
  def private_token?("w" <> rest), do: String.contains?(rest, "-")
  def private_token?(_token), do: false

  @doc """
  The time-window token for a file instance, expiring at `expires_at` (unix
  seconds). Without a `secret_key_base` there is nothing to key it with, and
  the token is one no check accepts.
  """
  @spec private_token(String.t(), String.t(), integer()) :: String.t()
  def private_token(file_uuid, instance_name, expires_at) when is_integer(expires_at) do
    case private_mac(file_uuid, instance_name, expires_at) do
      nil -> "w0-"
      mac -> "w" <> Integer.to_string(expires_at, 36) <> "-" <> mac
    end
  end

  @doc """
  Checks a time-window token: `:ok`, `:expired` (a real token whose window
  has passed), or `:invalid`.
  """
  @spec verify_private_token(String.t(), String.t(), String.t(), integer()) ::
          :ok | :expired | :invalid
  def verify_private_token(file_uuid, instance_name, token, now \\ System.os_time(:second))

  def verify_private_token(file_uuid, instance_name, "w" <> rest, now)
      when is_binary(file_uuid) and is_binary(instance_name) do
    with [encoded, mac] <- String.split(rest, "-", parts: 2),
         {expires_at, ""} <- Integer.parse(encoded, 36),
         expected when is_binary(expected) <- private_mac(file_uuid, instance_name, expires_at),
         true <- Plug.Crypto.secure_compare(expected, mac) do
      if expires_at > now, do: :ok, else: :expired
    else
      _ -> :invalid
    end
  end

  def verify_private_token(_file_uuid, _instance_name, _token, _now), do: :invalid

  @doc """
  How long one private URL window is, in seconds: the
  `storage_private_url_window_hours` setting (default 12, at least 1).
  """
  @spec private_url_window_seconds() :: pos_integer()
  def private_url_window_seconds do
    hours = Settings.get_integer_setting("storage_private_url_window_hours", 12)
    max(hours, 1) * 3600
  end

  @doc """
  The expiry a URL minted at `now` gets: `now` plus at least a quarter of a
  window, rounded up to the end of that window.
  """
  @spec window_end(integer(), pos_integer()) :: integer()
  def window_end(now, window \\ private_url_window_seconds()) do
    (div(now + div(window, 4), window) + 1) * window
  end

  # Audience transitions rotate only this library's time-window links. Without this,
  # a URL issued behind the sign-in gate would become an anonymous bearer URL after
  # making that library private. Old libraries keep their existing signatures.
  defp access_revision_suffix(file_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    with {:ok, uuid} <- Ecto.UUID.cast(file_uuid),
         true <- not is_nil(Process.whereis(repo)),
         revision when is_binary(revision) <-
           repo.one(
             from f in Storage.File,
               join: l in PhoenixKit.Modules.Storage.Library,
               on: l.uuid == f.library_uuid,
               where: f.uuid == ^uuid,
               select: fragment("?->>'access_revision'", l.settings)
           ) do
      ":" <> revision
    else
      _ -> ""
    end
  end

  defp private_mac(file_uuid, instance_name, expires_at) do
    case get_secret_key_base() do
      secret when is_binary(secret) and secret != "" ->
        :hmac
        |> :crypto.mac(
          :sha256,
          secret,
          "phoenix_kit_file:#{file_uuid}:#{instance_name}:#{expires_at}" <>
            access_revision_suffix(file_uuid)
        )
        |> binary_part(0, 16)
        |> Base.url_encode64(padding: false)

      _ ->
        nil
    end
  end

  @doc """
  Verify a token is valid for the given file and instance.

  ## Arguments

  - `file_uuid` (binary) - File UUID v7
  - `instance_name` (binary) - Variant name
  - `token` (binary) - 4-character token from URL

  ## Returns

  Boolean indicating if token is valid.

  ## Examples

      iex> file_uuid = "018e3c4a-9f6b-7890"
      iex> token = PhoenixKit.Modules.Storage.URLSigner.generate_token(file_uuid, "thumbnail")
      iex> PhoenixKit.Modules.Storage.URLSigner.verify_token(file_uuid, "thumbnail", token)
      true

      iex> PhoenixKit.Modules.Storage.URLSigner.verify_token(file_uuid, "thumbnail", "xxxx")
      false
  """
  def verify_token(file_uuid, instance_name, token)
      when is_binary(file_uuid) and is_binary(instance_name) and is_binary(token) do
    expected_token = generate_token(file_uuid, instance_name)
    # Use constant-time comparison to prevent timing attacks
    secure_compare(expected_token, token)
  end

  @doc """
  Generate the 4-character token for a file instance.

  Used internally by signed_url/2 and verify_token/4.

  ## Arguments

  - `file_uuid` (binary) - File UUID v7
  - `instance_name` (binary) - Variant name

  ## Returns

  A 4-character hex string token.

  ## Examples

      iex> PhoenixKit.Modules.Storage.URLSigner.generate_token("018e3c4a", "thumbnail")
      "abc1"
  """
  def generate_token(file_uuid, instance_name)
      when is_binary(file_uuid) and is_binary(instance_name) do
    data = "#{file_uuid}:#{instance_name}"

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

  @doc """
  Conditionally adds a `"dzi"` deep-zoom manifest URL to a `urls` map.

  Returns the map unchanged unless the file is an image **and** the variant
  set of its library makes tiles (V205; `tiles:` says so for a caller that
  already knows, such as a grid that looked up a whole page at once with
  `VariantSets.tiles_among/1`). The signed manifest URL
  (`/tiles/<token>/<file_uuid>-<version>.dzi`) is what Tessera fetches to
  stream tiles; the token and the version live in the path (not a query
  string) so they survive Tessera's manifest → tile URL derivation.

  Pass `version:` — the file's original instance, or its checksum — so the
  tiles are cached for good and an edit moves them to new URLs. Without it
  the legacy unversioned manifest (`<file_uuid>.dzi`) is emitted, which the
  server resolves to the current version and never lets a cache keep.

  This is the single source of truth for the `"dzi"` URL — every viewer that
  builds a file `urls` map (media browser, detail page, lightbox) pipes
  through it so the deep-zoom layer is wired consistently.
  """
  def put_dzi_url(urls, file_uuid, mime_type, opts \\ [])

  def put_dzi_url(urls, file_uuid, mime_type, opts)
      when is_map(urls) and is_binary(file_uuid) do
    if is_binary(mime_type) and String.starts_with?(mime_type, "image/") and
         Keyword.get_lazy(opts, :tiles, fn -> VariantSets.tiles_for?(file_uuid) end) do
      token = url_token(file_uuid, "dzi", opts)

      stem =
        case version(Keyword.get(opts, :version)) do
          nil -> file_uuid
          v -> "#{file_uuid}-#{v}"
        end

      # `locale: :none` — the /tiles routes live in the non-localized scope
      # (same as /file/... variant URLs); a locale prefix would 404.
      Map.put(urls, "dzi", Routes.path("/tiles/#{token}/#{stem}.dzi", locale: :none))
    else
      urls
    end
  end

  def put_dzi_url(urls, _file_uuid, _mime_type, _opts), do: urls

  defp get_secret_key_base do
    # Try to get secret_key_base from configured sources in order
    # 1. Explicitly configured on :phoenix_kit
    # 2. From the configured endpoint
    # 3. Return nil if not found (will use data without secret)
    Config.get(:secret_key_base, nil) ||
      get_parent_endpoint_secret()
  end

  defp get_parent_endpoint_secret do
    case Config.get_parent_endpoint() do
      {:ok, endpoint} ->
        if function_exported?(endpoint, :config, 1) do
          endpoint.config(:secret_key_base)
        else
          nil
        end

      _ ->
        nil
    end
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
