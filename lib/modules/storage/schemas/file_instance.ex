defmodule PhoenixKit.Modules.Storage.FileInstance do
  @moduledoc """
  Schema for file variants (thumbnails, resizes, video qualities).

  Each file can have multiple instances representing different versions:
  - **original** - The unchanged uploaded file
  - **thumbnail** - Small preview (150x150)
  - **small** - Small variant (300x300)
  - **medium** - Medium variant (800x600)
  - **large** - Large variant (1920x1080)
  - **360p** - Video quality variant (640x360)
  - **720p** - Video quality variant (1280x720)
  - **1080p** - Video quality variant (1920x1080)
  - **video_thumbnail** - Thumbnail extracted from video (640x360)

  All instances are stored next to the original file in the same directory.

  ## Processing Status

  - `pending` - Instance not yet processed
  - `processing` - Currently being generated
  - `completed` - Successfully generated
  - `failed` - Generation failed

  ## Fields

  - `variant_name` - Name of the variant (original, thumbnail, medium, etc.)
  - `file_name` - System filename (uuid_v7-variant.ext)
  - `mime_type` - MIME type of this variant
  - `ext` - File extension
  - `checksum` - Hash for integrity verification
  - `size` - Variant file size in bytes
  - `width` - Width in pixels (nullable)
  - `height` - Height in pixels (nullable)
  - `processing_status` - Current processing state
  - `file_id` - Parent file reference

  ## Examples

      # Original instance
      %FileInstance{
        variant_name: "original",
        file_name: "018e3c4a-9f6b-7890-original.jpg",
        mime_type: "image/jpeg",
        ext: "jpg",
        checksum: "abc123...",
        size: 524_288,
        width: 2000,
        height: 2000,
        processing_status: "completed",
        file_id: "018e3c4a-9f6b-7890-abcd-ef1234567890"
      }

      # Thumbnail instance
      %FileInstance{
        variant_name: "thumbnail",
        file_name: "018e3c4a-9f6b-7890-thumbnail.jpg",
        mime_type: "image/jpeg",
        ext: "jpg",
        checksum: "def456...",
        size: 8_192,  # 8 KB
        width: 150,
        height: 150,
        processing_status: "completed",
        file_id: "018e3c4a-9f6b-7890-abcd-ef1234567890"
      }

      # Video quality variant
      %FileInstance{
        variant_name: "720p",
        file_name: "018e3c4a-9f6b-7890-720p.mp4",
        mime_type: "video/mp4",
        ext: "mp4",
        size: 5_242_880,  # 5 MB
        width: 1280,
        height: 720,
        processing_status: "processing"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          variant_name: String.t(),
          file_name: String.t(),
          mime_type: String.t(),
          ext: String.t(),
          checksum: String.t(),
          size: integer(),
          width: integer() | nil,
          height: integer() | nil,
          processing_status: String.t(),
          file_id: UUIDv7.t() | nil,
          file: PhoenixKit.Modules.Storage.File.t() | Ecto.Association.NotLoaded.t(),
          locations:
            [PhoenixKit.Modules.Storage.FileLocation.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_file_instances" do
    field :variant_name, :string
    field :file_name, :string
    field :mime_type, :string
    field :ext, :string
    field :checksum, :string
    field :size, :integer
    field :width, :integer
    field :height, :integer
    field :processing_status, :string, default: "pending"

    belongs_to :file, PhoenixKit.Modules.Storage.File, references: :uuid
    has_many :locations, PhoenixKit.Modules.Storage.FileLocation, foreign_key: :file_instance_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a file instance.

  ## Required Fields

  - `variant_name`
  - `file_name`
  - `mime_type`
  - `ext`
  - `checksum`
  - `size`
  - `file_id`

  ## Validation Rules

  - Processing status must be valid (pending, processing, completed, failed)
  - Size must be positive
  - Width/height must be positive (if provided)
  - Unique variant_name per file
  """
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :variant_name,
      :file_name,
      :mime_type,
      :ext,
      :checksum,
      :size,
      :width,
      :height,
      :processing_status,
      :file_id
    ])
    |> validate_required([
      :variant_name,
      :file_name,
      :mime_type,
      :ext,
      :checksum,
      :size,
      :file_id
    ])
    |> validate_inclusion(:processing_status, ["pending", "processing", "completed", "failed"])
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> unique_constraint([:file_id, :variant_name],
      name: :phoenix_kit_file_instances_file_id_variant_name_index
    )
    |> foreign_key_constraint(:file_id)
  end

  @doc """
  Returns whether this is the original file instance.
  """
  def original?(%__MODULE__{variant_name: "original"}), do: true
  def original?(_), do: false

  @doc """
  Returns whether this instance has been successfully processed.
  """
  def completed?(%__MODULE__{processing_status: "completed"}), do: true
  def completed?(_), do: false

  @doc """
  Returns whether this instance failed processing.
  """
  def failed?(%__MODULE__{processing_status: "failed"}), do: true
  def failed?(_), do: false

  @doc """
  Returns whether this instance is currently being processed.
  """
  def processing?(%__MODULE__{processing_status: "processing"}), do: true
  def processing?(_), do: false

  @doc """
  Returns whether this instance is pending processing.
  """
  def pending?(%__MODULE__{processing_status: "pending"}), do: true
  def pending?(_), do: false
end
