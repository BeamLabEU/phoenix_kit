defmodule PhoenixKit.Modules.Storage.Bucket do
  @moduledoc """
  Schema for storage provider configurations.

  Buckets represent storage locations where files can be stored. They can be:
  - **Local** filesystem storage
  - **AWS S3** buckets
  - **Backblaze B2** buckets
  - **Cloudflare R2** buckets

  ## Priority System

  - `priority = 0` (default): Random selection, prefer most empty drive
  - `priority > 0`: Specific priority (1 = highest, 2 = second, etc.)

  ## Fields

  - `name` - Display name for the bucket
  - `provider` - Storage provider: "local", "s3", "b2", "r2"
  - `region` - AWS region or equivalent (nullable)
  - `endpoint` - Custom S3-compatible endpoint (nullable)
  - `bucket_name` - S3 bucket name (nullable)
  - `access_key_id` - Encrypted credentials (nullable)
  - `secret_access_key` - Encrypted credentials (nullable)
  - `cdn_url` - CDN endpoint for file serving (nullable)
  - `access_type` - How files are served: "public", "private", "signed" (default: "public")
  - `enabled` - Whether bucket is active
  - `priority` - Selection priority (0 = random/emptiest)
  - `max_size_mb` - Maximum storage capacity in MB (nullable = unlimited)

  ## Access Types

  - `public` - Redirect to public URL (default, fastest, uses CDN)
  - `private` - Proxy files through server (for ACL-protected buckets)
  - `signed` - Use presigned URLs (future implementation)

  ## Examples

      # Local storage bucket
      %Bucket{
        name: "Local SSD",
        provider: "local",
        enabled: true,
        priority: 0,
        max_size_mb: 512_000  # 500 GB
      }

      # AWS S3 bucket
      %Bucket{
        name: "Production S3",
        provider: "s3",
        region: "us-east-1",
        bucket_name: "my-app-files",
        access_key_id: "AKIA...",
        secret_access_key: "...",
        cdn_url: "https://cdn.example.com",
        enabled: true,
        priority: 1  # Highest priority
      }

      # Backblaze B2 bucket
      %Bucket{
        name: "Backup B2",
        provider: "b2",
        endpoint: "s3.us-west-002.backblazeb2.com",
        bucket_name: "my-backup-bucket",
        access_key_id: "...",
        secret_access_key: "...",
        enabled: true,
        priority: 2
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t(),
          provider: String.t(),
          region: String.t() | nil,
          endpoint: String.t() | nil,
          bucket_name: String.t() | nil,
          access_key_id: String.t() | nil,
          secret_access_key: String.t() | nil,
          cdn_url: String.t() | nil,
          access_type: String.t(),
          enabled: boolean(),
          priority: integer(),
          max_size_mb: integer() | nil,
          file_locations:
            [PhoenixKit.Modules.Storage.FileLocation.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_buckets" do
    field :name, :string
    field :provider, :string
    field :region, :string
    field :endpoint, :string
    field :bucket_name, :string
    field :access_key_id, :string
    field :secret_access_key, :string
    field :cdn_url, :string
    field :access_type, :string, default: "public"
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0
    field :max_size_mb, :integer

    has_many :file_locations, PhoenixKit.Modules.Storage.FileLocation, foreign_key: :bucket_id

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating or updating a bucket.

  ## Required Fields

  - `name`
  - `provider` (must be one of: "local", "s3", "b2", "r2")

  ## Validation Rules

  - Provider must be valid
  - Priority must be >= 0
  - Quality must be between 1-100 (if provided)
  - S3/B2/R2 buckets require credentials
  """
  def changeset(bucket, attrs) do
    bucket
    |> cast(attrs, [
      :name,
      :provider,
      :region,
      :endpoint,
      :bucket_name,
      :access_key_id,
      :secret_access_key,
      :cdn_url,
      :access_type,
      :enabled,
      :priority,
      :max_size_mb
    ])
    |> validate_required([:name, :provider])
    |> validate_inclusion(:provider, ["local", "s3", "b2", "r2"])
    |> validate_inclusion(:access_type, ["public", "private", "signed"])
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:max_size_mb, greater_than: 0)
    |> validate_cloud_credentials()
  end

  defp validate_cloud_credentials(changeset) do
    provider = get_field(changeset, :provider)

    if provider in ["s3", "b2", "r2"] do
      changeset
      |> validate_required([:bucket_name, :access_key_id, :secret_access_key])
    else
      changeset
    end
  end

  @doc """
  Returns whether this bucket is a local storage bucket.
  """
  def local?(%__MODULE__{provider: "local"}), do: true
  def local?(_), do: false

  @doc """
  Returns whether this bucket is a cloud storage bucket (S3, B2, R2).
  """
  def cloud?(%__MODULE__{provider: provider}) when provider in ["s3", "b2", "r2"], do: true
  def cloud?(_), do: false
end
