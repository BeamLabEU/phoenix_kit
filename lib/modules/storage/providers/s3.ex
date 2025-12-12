defmodule PhoenixKit.Modules.Storage.Providers.S3 do
  @moduledoc """
  AWS S3 storage provider.

  Stores files in Amazon S3 buckets using the ExAWS library.
  Supports all S3-compatible services (like DigitalOcean Spaces, MinIO, etc.).
  """

  @behaviour PhoenixKit.Modules.Storage.Provider

  @impl true
  def store_file(bucket, source_path, destination_path, opts \\ []) do
    # Configure ExAWS with bucket credentials
    configure_aws(bucket)

    # Upload the file
    upload_opts = [
      acl: Keyword.get(opts, :acl, "private"),
      content_type: Keyword.get(opts, :content_type)
    ]

    case ExAws.S3.upload(source_path, bucket.bucket_name, destination_path, upload_opts)
         |> ExAws.request() do
      {:ok, _result} ->
        url = public_url(bucket, destination_path)
        {:ok, url}

      {:error, reason} ->
        {:error, "Failed to upload to S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error storing file to S3: #{inspect(error)}"}
  end

  @impl true
  def retrieve_file(bucket, file_path, destination_path) do
    configure_aws(bucket)

    # Ensure destination directory exists
    destination_dir = Path.dirname(destination_path)
    File.mkdir_p!(destination_dir)

    # Download the file
    case ExAws.S3.download_file(bucket.bucket_name, file_path, destination_path)
         |> ExAws.request() do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to download from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error retrieving file from S3: #{inspect(error)}"}
  end

  @impl true
  def delete_file(bucket, file_path) do
    configure_aws(bucket)

    case ExAws.S3.delete_object(bucket.bucket_name, file_path) |> ExAws.request() do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to delete from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error deleting file from S3: #{inspect(error)}"}
  end

  @impl true
  def file_exists?(bucket, file_path) do
    configure_aws(bucket)

    case ExAws.S3.head_object(bucket.bucket_name, file_path) |> ExAws.request() do
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
      # Use CDN URL if configured
      "#{bucket.cdn_url}/#{file_path}"
    else
      # Use direct S3 URL
      region = bucket.region || "us-east-1"
      "https://#{bucket.bucket_name}.s3.#{region}.amazonaws.com/#{file_path}"
    end
  end

  @impl true
  def test_connection(bucket) do
    configure_aws(bucket)

    # Test by listing bucket (this requires ListBucket permission)
    case ExAws.S3.list_objects(bucket.bucket_name, max_keys: 1) |> ExAws.request() do
      {:ok, _result} -> :ok
      {:error, {:http_error, 403, _}} -> {:error, "Access denied - check permissions"}
      {:error, {:http_error, 404, _}} -> {:error, "Bucket not found"}
      {:error, reason} -> {:error, "S3 connection test failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error testing S3 connection: #{inspect(error)}"}
  end

  # Configure ExAWS with bucket-specific credentials
  defp configure_aws(bucket) do
    config = %{
      access_key_id: bucket.access_key_id,
      secret_access_key: bucket.secret_access_key,
      region: bucket.region || "us-east-1"
    }

    # Add custom endpoint if specified (for S3-compatible services)
    config =
      if bucket.endpoint do
        Map.put(config, :host, bucket.endpoint)
        |> Map.put(:scheme, "https://")
      else
        config
      end

    Application.put_env(:ex_aws, :s3, config)
  end
end
