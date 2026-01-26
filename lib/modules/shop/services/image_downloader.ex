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
      filename = extract_filename_from_url(url, content_type)

      result =
        Storage.store_file(temp_path,
          filename: filename,
          content_type: content_type,
          size_bytes: size,
          user_id: user_id,
          metadata: Map.merge(metadata, %{"source_url" => url})
        )

      # Clean up temp file
      File.rm(temp_path)

      case result do
        {:ok, file} -> {:ok, file.id}
        {:error, reason} -> {:error, reason}
      end
    end
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

    urls
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {url, index} ->
        result = download_and_store(url, user_id, opts)

        if on_progress do
          on_progress.(url, result, index, total)
        end

        {url, result}
      end,
      max_concurrency: concurrency,
      timeout: Keyword.get(opts, :timeout, @default_timeout) + 5_000
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {nil, {:error, {:task_exit, reason}}}
    end)
    |> Enum.reject(fn {url, _} -> is_nil(url) end)
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
    case validate_url(url) do
      {:ok, url} ->
        case Req.head(url, receive_timeout: 5_000) do
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
end
