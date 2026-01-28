defmodule PhoenixKit.Modules.Shop.Services.ImageDownloader do
  @moduledoc """
  Service for downloading images from external URLs and storing them in the Storage module.

  Handles HTTP download with proper error handling, content type detection,
  and integration with PhoenixKit.Modules.Storage for persistent storage.

  ## Usage

      # Download and store a single image
      {:ok, file_id} = ImageDownloader.download_and_store(url, user_id)

      # Download with options
      {:ok, file_id} = ImageDownloader.download_and_store(url, user_id, timeout: 30_000)

      # Batch download multiple images
      results = ImageDownloader.download_batch(urls, user_id)
      # => [{url, {:ok, file_id}}, {url, {:error, reason}}, ...]

  """

  require Logger

  alias PhoenixKit.Modules.Storage

  @default_timeout 30_000
  # 50 MB max
  @max_file_size 50 * 1024 * 1024
  @allowed_content_types ~w(image/jpeg image/png image/gif image/webp image/svg+xml)

  @doc """
  Downloads an image from a URL to a temporary file.

  Returns `{:ok, temp_path, content_type, size}` on success.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)

  ## Examples

      iex> download_image("https://example.com/image.jpg")
      {:ok, "/tmp/phx_img_abc123", "image/jpeg", 12345}

      iex> download_image("https://example.com/404.jpg")
      {:error, :not_found}

  """
  @spec download_image(String.t(), keyword()) ::
          {:ok, String.t(), String.t(), non_neg_integer()} | {:error, atom() | String.t()}
  def download_image(url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, url} <- validate_url(url),
         {:ok, response} <- do_http_request(url, timeout),
         {:ok, content_type} <- extract_content_type(response),
         :ok <- validate_content_type(content_type),
         :ok <- validate_size(response.body),
         {:ok, temp_path} <- write_temp_file(response.body, content_type) do
      {:ok, temp_path, content_type, byte_size(response.body)}
    end
  end

  @doc """
  Downloads an image from a URL and stores it in the Storage module.

  Returns `{:ok, file_id}` where file_id is a UUID that can be used to reference
  the stored file.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)
    * `:metadata` - Additional metadata to store with the file

  ## Examples

      iex> download_and_store("https://cdn.shopify.com/image.jpg", user_id)
      {:ok, "018f1234-5678-7890-abcd-ef1234567890"}

      iex> download_and_store("https://example.com/404.jpg", user_id)
      {:error, :not_found}

  """
  @spec download_and_store(String.t(), String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, atom() | String.t()}
  def download_and_store(url, user_id, opts \\ []) when is_binary(url) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, temp_path, content_type, size} <- download_image(url, opts) do
      # Check for global deduplication by file hash AND original filename
      file_checksum = calculate_file_hash(temp_path)
      filename = extract_filename_from_url(url, content_type)

      case find_existing_file(file_checksum, filename) do
        %{id: existing_id} = _existing_file ->
          # File with same content and name already exists - reuse it
          Logger.info(
            "[ImageDownloader] Reusing existing file #{existing_id} for URL #{url} (checksum: #{file_checksum}, filename: #{filename})"
          )

          cleanup_temp_file(temp_path)
          {:ok, existing_id}

        nil ->
          # No existing file matches - store new file
          Logger.info(
            "[ImageDownloader] Storing new file from URL #{url}, temp_path=#{temp_path}, size=#{size}"
          )

          # Verify temp file still exists before storing
          if File.exists?(temp_path) do
            result =
              Storage.store_file(temp_path,
                filename: filename,
                content_type: content_type,
                size_bytes: size,
                user_id: user_id,
                metadata: Map.merge(metadata, %{"source_url" => url})
              )

            Logger.info("[ImageDownloader] Storage result: #{inspect(result)}")

            # Clean up temp file
            cleanup_temp_file(temp_path)

            case result do
              {:ok, file} ->
                Logger.info("[ImageDownloader] Successfully stored file with ID: #{file.id}")
                {:ok, file.id}

              {:error, reason} ->
                Logger.error("[ImageDownloader] Storage failed: #{inspect(reason)}")
                {:error, reason}
            end
          else
            Logger.error("[ImageDownloader] Temp file disappeared before storage: #{temp_path}")
            {:error, :temp_file_missing}
          end
      end
    end
  end

  # Find existing file by checksum AND original filename
  defp find_existing_file(file_checksum, filename) do
    import Ecto.Query

    repo = PhoenixKit.Config.get_repo()

    query =
      from(f in PhoenixKit.Modules.Storage.File,
        where: f.file_checksum == ^file_checksum and f.original_file_name == ^filename,
        limit: 1
      )

    repo.one(query)
  end

  # Calculate SHA256 hash of file content
  defp calculate_file_hash(file_path) do
    Elixir.File.stream!(file_path, 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Downloads and stores multiple images in batch.

  Returns a list of tuples `{url, result}` where result is either
  `{:ok, file_id}` or `{:error, reason}`.

  ## Options

    * `:timeout` - HTTP request timeout for each image (default: 30_000)
    * `:concurrency` - Number of concurrent downloads (default: 5)
    * `:on_progress` - Callback function called after each download: `fn(url, result, index, total) -> :ok end`

  ## Examples

      iex> download_batch(["url1", "url2", "url3"], user_id)
      [{"url1", {:ok, "uuid-1"}}, {"url2", {:ok, "uuid-2"}}, {"url3", {:error, :timeout}}]

  """
  @spec download_batch([String.t()], String.t() | integer(), keyword()) ::
          [{String.t(), {:ok, String.t()} | {:error, atom() | String.t()}}]
  def download_batch(urls, user_id, opts \\ []) when is_list(urls) do
    concurrency = Keyword.get(opts, :concurrency, 5)
    on_progress = Keyword.get(opts, :on_progress)
    total = length(urls)

    # Create indexed list to preserve URL even on task crash
    indexed_urls = Enum.with_index(urls, 1)

    indexed_urls
    |> Task.async_stream(
      fn {url, index} ->
        result = download_and_store(url, user_id, opts)

        if on_progress do
          on_progress.(url, result, index, total)
        end

        {index, url, result}
      end,
      max_concurrency: concurrency,
      timeout: Keyword.get(opts, :timeout, @default_timeout) + 5_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(indexed_urls)
    |> Enum.map(fn
      {{:ok, {_index, url, result}}, _original} ->
        {url, result}

      {{:exit, reason}, {url, _index}} ->
        # Recover URL from original indexed list when task exits
        Logger.warning("Task exited for URL #{url}: #{inspect(reason)}")
        {url, {:error, {:task_exit, reason}}}
    end)
  end

  @doc """
  Validates URLs are accessible before batch download.

  Performs HEAD requests to verify URLs are accessible and return valid
  image content types. Returns a tuple of `{valid_urls, invalid_urls}`.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 5_000)
    * `:concurrency` - Number of concurrent validations (default: 10)

  ## Examples

      iex> validate_urls(["https://example.com/image.jpg", "https://example.com/404.jpg"])
      {["https://example.com/image.jpg"], ["https://example.com/404.jpg"]}

  """
  @spec validate_urls([String.t()], keyword()) :: {[String.t()], [String.t()]}
  def validate_urls(urls, opts \\ []) when is_list(urls) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    concurrency = Keyword.get(opts, :concurrency, 10)

    results =
      urls
      |> Task.async_stream(
        fn url -> {url, valid_image_url?(url, timeout)} end,
        max_concurrency: concurrency,
        timeout: timeout + 2_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {url, true}} -> {:valid, url}
        {:ok, {url, false}} -> {:invalid, url}
        {:exit, _reason} -> {:timeout, nil}
      end)
      |> Enum.reject(fn {_status, url} -> is_nil(url) end)

    valid = for {:valid, url} <- results, do: url
    invalid = for {:invalid, url} <- results, do: url

    {valid, invalid}
  end

  @doc """
  Checks if a URL points to a valid image that can be downloaded.

  Performs a HEAD request to verify the URL is accessible and returns
  an image content type.

  ## Examples

      iex> valid_image_url?("https://example.com/image.jpg")
      true

      iex> valid_image_url?("https://example.com/document.pdf")
      false

  """
  @spec valid_image_url?(String.t()) :: boolean()
  def valid_image_url?(url) when is_binary(url) do
    valid_image_url?(url, 5_000)
  end

  @spec valid_image_url?(String.t(), non_neg_integer()) :: boolean()
  defp valid_image_url?(url, timeout) when is_binary(url) do
    case validate_url(url) do
      {:ok, url} ->
        case Req.head(url, receive_timeout: timeout) do
          {:ok, %{status: status, headers: headers}} when status in 200..299 ->
            content_type = get_header_value(headers, "content-type")
            validate_content_type(content_type) == :ok

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # Private functions

  defp validate_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_scheme}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :invalid_host}

      true ->
        # Upgrade HTTP to HTTPS for security
        url =
          if uri.scheme == "http",
            do: String.replace_prefix(url, "http://", "https://"),
            else: url

        {:ok, url}
    end
  end

  defp do_http_request(url, timeout) do
    opts = [
      receive_timeout: timeout,
      max_redirects: 5,
      headers: [
        {"user-agent", "PhoenixKit/1.0 (Image Downloader)"},
        {"accept", "image/*"}
      ]
    ]

    case Req.get(url, opts) do
      {:ok, %{status: 200} = response} ->
        {:ok, response}

      {:ok, %{status: 301}} ->
        {:error, :redirect_loop}

      {:ok, %{status: 302}} ->
        {:error, :redirect_loop}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, :server_error}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp extract_content_type(%{headers: headers}) do
    case get_header_value(headers, "content-type") do
      nil ->
        {:error, :missing_content_type}

      content_type ->
        # Extract just the MIME type, ignoring charset or other parameters
        mime_type =
          content_type
          |> String.split(";")
          |> List.first()
          |> String.trim()
          |> String.downcase()

        {:ok, mime_type}
    end
  end

  defp get_header_value(headers, key) do
    key_lower = String.downcase(key)

    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == key_lower end)
    |> case do
      {_, value} when is_list(value) -> List.first(value)
      {_, value} -> value
      nil -> nil
    end
  end

  defp validate_content_type(content_type) when content_type in @allowed_content_types, do: :ok

  defp validate_content_type(content_type) do
    Logger.warning("Invalid content type for image download: #{content_type}")
    {:error, {:invalid_content_type, content_type}}
  end

  defp validate_size(body) when byte_size(body) <= @max_file_size, do: :ok

  defp validate_size(body) do
    size_mb = Float.round(byte_size(body) / 1024 / 1024, 2)

    {:error,
     {:file_too_large, "#{size_mb} MB exceeds limit of #{@max_file_size / 1024 / 1024} MB"}}
  end

  defp write_temp_file(body, content_type) do
    ext = content_type_to_extension(content_type)
    temp_path = generate_temp_path(ext)

    case File.write(temp_path, body) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp generate_temp_path(ext) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "phx_img_#{random}.#{ext}")
  end

  defp extract_filename_from_url(url, content_type) do
    uri = URI.parse(url)

    # Try to get filename from path
    base_name =
      case uri.path do
        nil ->
          "image"

        path ->
          path
          |> Path.basename()
          |> String.split("?")
          |> List.first()
          |> case do
            "" -> "image"
            name -> Path.rootname(name)
          end
      end

    # Ensure proper extension
    ext = content_type_to_extension(content_type)
    "#{base_name}.#{ext}"
  end

  defp content_type_to_extension(content_type) do
    case content_type do
      "image/jpeg" -> "jpg"
      "image/png" -> "png"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      "image/svg+xml" -> "svg"
      _ -> "jpg"
    end
  end

  defp cleanup_temp_file(temp_path) do
    case File.rm(temp_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to cleanup temp file #{temp_path}: #{inspect(reason)}")
        :ok
    end
  end
end
