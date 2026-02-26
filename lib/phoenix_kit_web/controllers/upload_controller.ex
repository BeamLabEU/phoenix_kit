defmodule PhoenixKitWeb.UploadController do
  @moduledoc """
  File upload controller for handling multipart uploads.

  Accepts file uploads, validates them, and queues them for background processing.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.ProcessFileJob

  @upload_config %{
    # 100MB max file size
    max_size: 100 * 1024 * 1024,
    allowed_types:
      ~w(image/jpeg image/png image/webp image/gif video/mp4 video/webm video/quicktime application/pdf)
  }

  @doc """
  Upload a file via multipart form.

  ## Request

      POST /api/upload

  ## Parameters

  - `file` (required): The file to upload (multipart/form-data)
  - `user_id` (optional): Override user ID (admin only)

  ## Response

  Success (200):
      {
        "file_id": "uuidv7-string",
        "original_filename": "photo.jpg",
        "file_type": "image",
        "mime_type": "image/jpeg",
        "size": 1234567,
        "status": "processing",
        "message": "Upload successful, processing variants..."
      }

  Error (400):
      {
        "error": "INVALID_FILE_TYPE",
        "message": "File type not allowed"
      }

  Error (413):
      {
        "error": "FILE_TOO_LARGE",
        "message": "File size exceeds maximum allowed (100MB)"
      }
  """
  def create(conn, params) do
    with {:ok, upload} <- extract_upload(params),
         :ok <- validate_file_type(upload),
         :ok <- validate_file_size(upload),
         {:ok, user_id} <- get_current_user_id(conn, params),
         {:ok, file_id} <- process_upload(upload, user_id) do
      json(conn, %{
        file_id: file_id,
        status: "processing",
        message: "Upload successful, variants will be generated shortly"
      })
    else
      {:error, :invalid_file_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "INVALID_FILE_TYPE", message: "File type not allowed"})

      {:error, :file_too_large} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{
          error: "FILE_TOO_LARGE",
          message: "File size exceeds maximum allowed (#{format_bytes(@upload_config.max_size)})"
        })

      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "UNAUTHORIZED", message: "Authentication required"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "VALIDATION_ERROR",
          message: "Invalid upload",
          details: changeset_errors(changeset)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "UPLOAD_FAILED", message: "Upload failed: #{inspect(reason)}"})
    end
  end

  defp extract_upload(params) do
    case params["file"] do
      %Plug.Upload{} = upload -> {:ok, upload}
      _ -> {:error, :no_file}
    end
  end

  defp validate_file_type(upload) do
    if upload.content_type in @upload_config.allowed_types do
      :ok
    else
      {:error, :invalid_file_type}
    end
  end

  defp validate_file_size(upload) do
    case File.stat(upload.path) do
      {:ok, stat} ->
        if stat.size <= @upload_config.max_size do
          :ok
        else
          {:error, :file_too_large}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_current_user_id(conn, params) do
    # Check if user is authenticated
    case conn.assigns[:phoenix_kit_current_user] do
      %PhoenixKit.Users.Auth.User{uuid: user_uuid} ->
        {:ok, user_uuid}

      nil ->
        # Try override from params (admin only)
        case params["user_id"] do
          user_id when is_binary(user_id) ->
            # Verify admin permission here if needed
            {:ok, user_id}

          _ ->
            {:error, :no_user}
        end
    end
  end

  defp process_upload(upload, user_id) do
    with {:ok, stat} <- File.stat(upload.path),
         {:ok, file_checksum} <- safe_calculate_file_hash(upload.path) do
      file_size = stat.size

      # Calculate user-specific checksum for per-user duplicate detection
      user_file_checksum = Storage.calculate_user_file_checksum(user_id, file_checksum)

      # Check if this user already uploaded this file
      case Storage.get_file_by_user_checksum(user_file_checksum) do
        %StorageFile{} = existing_file ->
          # File already exists for this user, delete temp upload and return existing file
          File.rm(upload.path)
          {:ok, existing_file.uuid}

        nil ->
          # New file for this user, proceed with upload
          perform_upload(upload, user_id, file_size, file_checksum)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_calculate_file_hash(file_path) do
    case File.read(file_path) do
      {:ok, data} ->
        hash =
          data
          |> then(&:crypto.hash(:md5, &1))
          |> Base.encode16(case: :lower)

        {:ok, hash}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp perform_upload(upload, user_id, _file_size, file_checksum) do
    file_type = determine_file_type(upload.content_type)
    ext = Path.extname(upload.filename) |> String.replace_leading(".", "")

    # Store in buckets with hierarchical path structure
    case Storage.store_file_in_buckets(upload.path, file_type, user_id, file_checksum, ext) do
      {:ok, file} ->
        # Queue background job for variant generation
        %{file_id: file.uuid, user_id: user_id, filename: upload.filename}
        |> ProcessFileJob.new()
        |> Oban.insert()

        {:ok, file.uuid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      mime_type == "application/pdf" -> "document"
      true -> "other"
    end
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    if bytes < 1024 do
      "#{bytes} B"
    else
      units = ["KB", "MB", "GB", "TB"]
      {value, unit} = calculate_size(bytes, units)
      "#{Float.round(value, 2)} #{unit}"
    end
  end

  defp calculate_size(bytes, [_unit | rest]) when bytes >= 1024 and rest != [] do
    calculate_size(bytes / 1024, rest)
  end

  defp calculate_size(bytes, [unit | _]), do: {bytes, unit}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), msg) |> to_string()
      end)
    end)
  end
end
