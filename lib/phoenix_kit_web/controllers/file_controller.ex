defmodule PhoenixKitWeb.FileController do
  @moduledoc """
  File serving controller with signed URL support.

  Handles secure file retrieval with token-based authentication and cache headers.
  """
  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Manager, ProcessFileJob, URLSigner}
  alias PhoenixKit.Utils.Routes

  @doc """
  Serve a file variant by ID with signed URL token.

  ## Request

      GET /file/:file_uuid/:variant/:token

  ## Parameters

  - `file_uuid`: UUID of the file
  - `variant`: Variant name (e.g., "original", "thumbnail", "medium")
  - `token`: Signed token for authentication

  ## Response

  Success (200):
  - File streamed to client with appropriate headers:
    - `Cache-Control: public, max-age=31536000, immutable` (1 year)
    - `ETag: "md5-hash"`
    - `Content-Type: <mime-type>`
    - `Content-Disposition: inline; filename="..."`

  Not Modified (304):
  - Returned when request includes `If-None-Match` matching the file ETag

  Error (401):
      "Invalid or expired token"

  Error (404):
      "File or variant not found"
  """
  def show(conn, %{"file_uuid" => file_uuid, "variant" => variant, "token" => token}) do
    with {:ok, file} <- get_file(file_uuid),
         :ok <- verify_token(file_uuid, variant, token),
         {:ok, instance} <- get_file_instance(file_uuid, variant),
         result <- get_file_access(instance) do
      case result do
        {:local, file_path} ->
          serve_file(conn, file, instance, file_path)

        {:redirect, url} ->
          redirect(conn, external: url)

        {:proxy, file_name} ->
          proxy_remote_file(conn, file, instance, file_name)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> text("File or variant not found")

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> text("Error retrieving file: #{inspect(reason)}")
      end
    else
      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> text("Invalid or expired token")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("File or variant not found")
    end
  end

  @doc """
  Get file information without serving the file.

  ## Request

      GET /api/files/:file_uuid/info

  ## Response

  Success (200):
      {
        "file_uuid": "uuid",
        "original_filename": "photo.jpg",
        "mime_type": "image/jpeg",
        "file_type": "image",
        "size": 1234567,
        "status": "active",
        "variants": [
          {
            "variant_name": "original",
            "mime_type": "image/jpeg",
            "size": 1234567,
            "width": 1920,
            "height": 1080,
            "url": "/file/uuid/original/token"
          }
        ]
      }
  """
  def info(conn, %{"file_uuid" => file_uuid}) do
    case get_file(file_uuid) do
      {:ok, file} ->
        instances = Storage.list_file_instances(file_uuid)

        variant_urls =
          Enum.map(instances, fn instance ->
            token = URLSigner.generate_token(file_uuid, instance.variant_name)
            file_path = "/file/#{file_uuid}/#{instance.variant_name}/#{token}"
            url = Routes.path(file_path)

            %{
              variant_name: instance.variant_name,
              mime_type: instance.mime_type,
              size: instance.size,
              width: instance.width,
              height: instance.height,
              url: url
            }
          end)

        json(conn, %{
          file_uuid: file.uuid,
          original_filename: file.original_file_name,
          mime_type: file.mime_type,
          file_type: file.file_type,
          size: file.size,
          status: file.status,
          variants: variant_urls
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "FILE_NOT_FOUND", message: "File not found"})
    end
  end

  defp get_file(file_uuid) do
    case Storage.get_file(file_uuid) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  defp get_file_instance(file_uuid, variant) do
    case Storage.get_file_instance_by_name(file_uuid, variant) do
      nil ->
        # Variant doesn't exist, try to get the original to queue generation
        case Storage.get_file_instance_by_name(file_uuid, "original") do
          nil ->
            {:error, :not_found}

          original_instance ->
            # Queue the variant for generation if not already requested
            queue_missing_variant(file_uuid, variant, original_instance)
            # Return the original for now
            {:ok, original_instance}
        end

      instance ->
        {:ok, instance}
    end
  end

  defp queue_missing_variant(file_uuid, _variant, original_instance) do
    # Queue background job to generate the missing variant
    Task.start(fn ->
      case Storage.get_file(file_uuid) do
        nil ->
          :error

        file ->
          %{
            file_uuid: file_uuid,
            user_uuid: file.user_uuid,
            filename: original_instance.file_name
          }
          |> ProcessFileJob.new()
          |> Oban.insert()
      end
    end)
  end

  defp verify_token(file_uuid, variant, token) do
    if URLSigner.verify_token(file_uuid, variant, token) do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  # Get file access info with retry logic for bucket cache race conditions
  # Returns {:local, path} | {:redirect, url} | {:proxy, file_name} | {:error, reason}
  defp get_file_access(instance) do
    get_file_access_with_retry(instance, 5)
  end

  defp get_file_access_with_retry(instance, retries) do
    case Manager.get_file_access(instance.file_name) do
      {:local, _} = result ->
        result

      {:redirect, _} = result ->
        result

      {:proxy, _} = result ->
        result

      {:error, :not_found} when retries > 1 ->
        # Race condition during bucket cache init - retry with delay
        Logger.debug(
          "[FileController] File not found, retrying (#{retries - 1} left): #{instance.file_name}"
        )

        Process.sleep(100)
        get_file_access_with_retry(instance, retries - 1)

      error ->
        error
    end
  end

  # Serve a local file with proper headers
  defp serve_file(conn, file, instance, file_path) do
    etag = ~s("#{instance.checksum}")

    if etag in Plug.Conn.get_req_header(conn, "if-none-match") do
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(304, "")
    else
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("etag", etag)
      |> put_resp_header(
        "content-disposition",
        ~s(inline; filename="#{file.original_file_name}")
      )
      |> put_resp_content_type(instance.mime_type)
      |> send_file(200, file_path)
    end
  end

  # Proxy a remote file through the server (for private buckets)
  defp proxy_remote_file(conn, file, instance, file_name) do
    temp_path =
      Path.join(System.tmp_dir!(), "phoenix_kit_#{instance.uuid}_#{:rand.uniform(1_000_000)}")

    case Manager.retrieve_file(file_name, destination_path: temp_path) do
      {:ok, _} ->
        conn = serve_file(conn, file, instance, temp_path)
        File.rm(temp_path)
        conn

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("File or variant not found")
    end
  end
end
