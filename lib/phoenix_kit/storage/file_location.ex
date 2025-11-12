defmodule PhoenixKit.Storage.FileLocation do
  @moduledoc """
  Schema for physical storage locations (redundancy tracking).

  Tracks where each file instance is physically stored. Each instance can have
  multiple locations for redundancy (1-5 copies across different buckets).

  ## Redundancy Example

  If `storage_redundancy_copies = 2`, each file instance will have 2 location records:

      # Location 1: Backblaze B2
      %FileLocation{
        path: "/uploads/018e3c4a-9f6b-7890-thumbnail.jpg",
        status: "active",
        priority: 0,
        file_instance_id: "...",
        bucket_id: "b2_bucket_id"
      }

      # Location 2: Cloudflare R2
      %FileLocation{
        path: "/uploads/018e3c4a-9f6b-7890-thumbnail.jpg",
        status: "active",
        priority: 0,
        file_instance_id: "...",
        bucket_id: "r2_bucket_id"
      }

  ## Status Flow

  - `active` - File is available at this location
  - `syncing` - File is being uploaded/copied
  - `failed` - Upload or sync failed
  - `deleted` - File has been removed from this location

  ## Fields

  - `path` - Full path within the bucket
  - `status` - Current state of this location
  - `priority` - Retrieval priority (0 = lowest, higher = preferred)
  - `last_verified_at` - Last health check timestamp
  - `file_instance_id` - Which instance this location stores
  - `bucket_id` - Which bucket this file is stored in

  ## Examples

      # Active location on local storage
      %FileLocation{
        path: "/var/uploads/018e3c4a-9f6b-7890-large.jpg",
        status: "active",
        priority: 0,
        last_verified_at: ~N[2025-10-28 10:00:00],
        file_instance_id: "...",
        bucket_id: "local_bucket_id"
      }

      # Syncing to cloud backup
      %FileLocation{
        path: "/uploads/018e3c4a-9f6b-7890-large.jpg",
        status: "syncing",
        priority: 0,
        file_instance_id: "...",
        bucket_id: "s3_bucket_id"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          path: String.t(),
          status: String.t(),
          priority: integer(),
          last_verified_at: NaiveDateTime.t() | nil,
          file_instance_id: UUIDv7.t() | nil,
          bucket_id: UUIDv7.t() | nil,
          file_instance: PhoenixKit.Storage.FileInstance.t() | Ecto.Association.NotLoaded.t(),
          bucket: PhoenixKit.Storage.Bucket.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_file_locations" do
    field :path, :string
    field :status, :string, default: "active"
    field :priority, :integer, default: 0
    field :last_verified_at, :naive_datetime

    belongs_to :file_instance, PhoenixKit.Storage.FileInstance
    belongs_to :bucket, PhoenixKit.Storage.Bucket

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating or updating a file location.

  ## Required Fields

  - `path`
  - `file_instance_id`
  - `bucket_id`

  ## Validation Rules

  - Status must be valid (active, syncing, failed, deleted)
  - Priority must be >= 0
  """
  def changeset(location, attrs) do
    location
    |> cast(attrs, [
      :path,
      :status,
      :priority,
      :last_verified_at,
      :file_instance_id,
      :bucket_id
    ])
    |> validate_required([:path, :file_instance_id, :bucket_id])
    |> validate_inclusion(:status, ["active", "syncing", "failed", "deleted"])
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:file_instance_id)
    |> foreign_key_constraint(:bucket_id)
  end

  @doc """
  Returns whether this location is active and available.
  """
  def active?(%__MODULE__{status: "active"}), do: true
  def active?(_), do: false

  @doc """
  Returns whether this location is currently syncing.
  """
  def syncing?(%__MODULE__{status: "syncing"}), do: true
  def syncing?(_), do: false

  @doc """
  Returns whether this location has failed.
  """
  def failed?(%__MODULE__{status: "failed"}), do: true
  def failed?(_), do: false

  @doc """
  Returns whether this location has been deleted.
  """
  def deleted?(%__MODULE__{status: "deleted"}), do: true
  def deleted?(_), do: false
end
