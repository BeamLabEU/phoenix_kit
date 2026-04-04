defmodule PhoenixKit.Modules.Storage.Providers.S3 do
  @moduledoc """
  AWS S3 storage provider.

  Stores files in Amazon S3 buckets using the ExAWS library.
  Supports all S3-compatible services (like Backblaze B2, Cloudflare R2, Tigris).
  """

  require Logger

  @behaviour PhoenixKit.Modules.Storage.Provider

  @impl true
  def store_file(bucket, source_path, destination_path, opts \\ []) do
    content_type = Keyword.get(opts, :content_type)

    case File.read(source_path) do
      {:ok, file_content} ->
        put_opts =
          [{:acl, Keyword.get(opts, :acl, "private")}] ++
            if(content_type, do: [{:content_type, content_type}], else: [])

        case ExAws.S3.put_object(bucket.bucket_name, destination_path, file_content, put_opts)
             |> ExAws.request(aws_config(bucket)) do
          {:ok, _result} ->
            url = public_url(bucket, destination_path)
            {:ok, url}

          {:error, reason} ->
            Logger.error("S3 upload failed for #{bucket.name}: #{inspect(reason)}")
            {:error, "Failed to upload to S3: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("S3 upload: cannot read source file #{source_path}: #{inspect(reason)}")
        {:error, "Cannot read source file: #{inspect(reason)}"}
    end
  rescue
    error ->
      Logger.error("S3 upload exception for #{bucket.name}: #{Exception.message(error)}")
      {:error, "Error storing file to S3: #{inspect(error)}"}
  end

  @impl true
  def retrieve_file(bucket, file_path, destination_path) do
    destination_dir = Path.dirname(destination_path)
    File.mkdir_p!(destination_dir)

    case ExAws.S3.download_file(bucket.bucket_name, file_path, destination_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to download from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error retrieving file from S3: #{inspect(error)}"}
  end

  @impl true
  def delete_file(bucket, file_path) do
    case ExAws.S3.delete_object(bucket.bucket_name, file_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to delete from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error deleting file from S3: #{inspect(error)}"}
  end

  @impl true
  def file_exists?(bucket, file_path) do
    case ExAws.S3.head_object(bucket.bucket_name, file_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> true
      {:error, {:http_error, 404, _}} -> false
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  end

  @impl true
  def public_url(bucket, file_path) do
    if bucket.cdn_url do
      "#{bucket.cdn_url}/#{file_path}"
    else
      region = bucket.region || "us-east-1"
      "https://#{bucket.bucket_name}.s3.#{region}.amazonaws.com/#{file_path}"
    end
  end

  @impl true
  def test_connection(bucket) do
    case ExAws.S3.list_objects(bucket.bucket_name, max_keys: 1)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, {:http_error, 403, _}} -> {:error, "Access denied - check permissions"}
      {:error, {:http_error, 404, _}} -> {:error, "Bucket not found"}
      {:error, reason} -> {:error, "S3 connection test failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error testing S3 connection: #{inspect(error)}"}
  end

  # Build per-request ExAws config from bucket credentials.
  # Passed to ExAws.request/2 instead of using global Application.put_env.
  defp aws_config(bucket) do
    config = [
      access_key_id: bucket.access_key_id,
      secret_access_key: bucket.secret_access_key,
      region: bucket.region || "us-east-1"
    ]

    if bucket.endpoint do
      config ++ [host: bucket.endpoint, scheme: "https://"]
    else
      config
    end
  end
end
