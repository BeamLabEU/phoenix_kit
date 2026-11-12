defmodule PhoenixKit.Modules.Storage.Provider do
  @moduledoc """
  Behavior for storage providers.

  Each storage provider (local, S3, B2, R2) must implement this behavior
  to provide file storage and retrieval capabilities.
  """

  @doc """
  Stores a file in the storage provider.

  ## Parameters

  - `bucket` - The bucket configuration
  - `source_path` - Path to the source file on local filesystem
  - `destination_path` - Relative path where to store the file
  - `opts` - Additional options

  ## Returns

  - `{:ok, url}` - File stored successfully, returns public URL
  - `{:error, reason}` - Failed to store file
  """
  @callback store_file(
              bucket :: PhoenixKit.Modules.Storage.Bucket.t(),
              source_path :: String.t(),
              destination_path :: String.t(),
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Retrieves a file from the storage provider.

  ## Parameters

  - `bucket` - The bucket configuration
  - `file_path` - Path to the file in storage
  - `destination_path` - Local path where to save the file

  ## Returns

  - `{:ok, file_path}` - File retrieved successfully
  - `{:error, reason}` - Failed to retrieve file
  """
  @callback retrieve_file(
              bucket :: PhoenixKit.Modules.Storage.Bucket.t(),
              file_path :: String.t(),
              destination_path :: String.t()
            ) :: :ok | {:error, term()}

  @doc """
  Deletes a file from the storage provider.

  ## Parameters

  - `bucket` - The bucket configuration
  - `file_path` - Path to the file in storage

  ## Returns

  - `:ok` - File deleted successfully
  - `{:error, reason}` - Failed to delete file
  """
  @callback delete_file(bucket :: PhoenixKit.Modules.Storage.Bucket.t(), file_path :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Checks if a file exists in the storage provider.

  ## Parameters

  - `bucket` - The bucket configuration
  - `file_path` - Path to the file in storage

  ## Returns

  - `true` if file exists, `false` otherwise
  """
  @callback file_exists?(bucket :: PhoenixKit.Modules.Storage.Bucket.t(), file_path :: String.t()) ::
              boolean()

  @doc """
  Gets a public URL for a file in the storage provider.

  ## Parameters

  - `bucket` - The bucket configuration
  - `file_path` - Path to the file in storage

  ## Returns

  - Public URL string or `nil` if not applicable
  """
  @callback public_url(bucket :: PhoenixKit.Modules.Storage.Bucket.t(), file_path :: String.t()) ::
              String.t() | nil

  @doc """
  Tests the connection to the storage provider.

  ## Parameters

  - `bucket` - The bucket configuration

  ## Returns

  - `:ok` - Connection successful
  - `{:error, reason}` - Connection failed
  """
  @callback test_connection(bucket :: PhoenixKit.Modules.Storage.Bucket.t()) ::
              :ok | {:error, term()}

  @doc """
  A short-lived URL that downloads `file_path` straight from the bucket,
  answered with the response headers given in `opts` instead of the
  object's stored ones — so a file the app would never show in place (an
  uploaded HTML page, an SVG) downloads from the bucket rather than
  rendering on the bucket's origin.

  ## Options

  - `:disposition` - the `Content-Disposition` the bucket must answer with
  - `:content_type` - the `Content-Type` the bucket must answer with
  - `:expires_in` - seconds the URL stays valid

  ## Returns

  - `{:ok, url}` - a signed URL
  - `{:error, reason}` - no URL could be signed; the caller proxies instead

  Optional: a provider without it is proxied for such files.
  """
  @callback signed_download_url(
              bucket :: PhoenixKit.Modules.Storage.Bucket.t(),
              file_path :: String.t(),
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Reads the bytes `first..last` (inclusive) of a stored file, without fetching the
  rest. The app answers a request for part of a file it proxies (a browser playing
  a video asks for parts) with one such read, instead of downloading the whole file
  for every part.

  ## Returns

  - `{:ok, binary}` - exactly `last - first + 1` bytes
  - `{:error, reason}` - not read; the caller falls back to `retrieve_file/3`

  Optional: a provider without it is proxied whole.
  """
  @callback read_range(
              bucket :: PhoenixKit.Modules.Storage.Bucket.t(),
              file_path :: String.t(),
              first :: non_neg_integer(),
              last :: non_neg_integer()
            ) :: {:ok, binary()} | {:error, term()}

  @optional_callbacks signed_download_url: 3, read_range: 4
end
