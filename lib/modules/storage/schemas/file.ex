defmodule PhoenixKit.Modules.Storage.File do
  @moduledoc """
  Schema for original file uploads.

  Represents the original uploaded file with metadata. Each file can have multiple
  instances (variants) like thumbnails, resizes, or video quality variants.

  ## File Types

  - **image** - JPEG, PNG, WebP, GIF, HEIC (scalable)
  - **video** - MP4, WebM, MOV, AVI, MKV (scalable)
  - **document** - PDF, DOC, DOCX, TXT, MD (non-scalable)
  - **archive** - ZIP, RAR, 7Z, TAR, GZ (non-scalable)

  ## Status Flow

  - `processing` - File is being processed (variants being generated)
  - `active` - File is ready and available
  - `failed` - Processing failed

  ## Fields

  - `original_file_name` - User's original filename
  - `file_name` - System filename (uuid_v7-original.ext)
  - `mime_type` - MIME type (image/jpeg, video/mp4, etc.)
  - `file_type` - High-level type (image, video, document, archive)
  - `ext` - File extension (jpg, mp4, pdf, etc.)
  - `file_checksum` - SHA256 hash of file content for integrity verification
  - `user_file_checksum` - SHA256 hash of (user_id + file_checksum) for per-user deduplication
  - `size` - File size in bytes
  - `width` - Image/video width in pixels (nullable)
  - `height` - Image/video height in pixels (nullable)
  - `duration` - Video duration in seconds (nullable)
  - `status` - Processing status
  - `metadata` - JSONB with EXIF, codec info, etc.
  - `user_id` - Owner of the file

  ## Examples

      # Image file
      %File{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        original_file_name: "profile.jpg",
        file_name: "018e3c4a-9f6b-7890-original.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "abc123def456...",
        user_file_checksum: "xyz789ghi012...",
        size: 524_288,  # 512 KB
        width: 2000,
        height: 2000,
        status: "active",
        metadata: %{"camera" => "Canon EOS"},
        user_id: "..."
      }

      # Video file
      %File{
        original_file_name: "intro.mp4",
        file_name: "018e3c4a-9f6b-7890-original.mp4",
        mime_type: "video/mp4",
        file_type: "video",
        ext: "mp4",
        file_checksum: "def456ghi789...",
        user_file_checksum: "mno345pqr678...",
        size: 10_485_760,  # 10 MB
        width: 1920,
        height: 1080,
        duration: 30,  # 30 seconds
        status: "processing",
        metadata: %{"codec" => "h264"}
      }

      # Document file
      %File{
        original_file_name: "report.pdf",
        file_name: "018e3c4a-9f6b-7890-original.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "ghi789jkl012...",
        user_file_checksum: "stu901vwx234...",
        size: 2_097_152,  # 2 MB
        status: "active"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          original_file_name: String.t(),
          file_name: String.t(),
          file_path: String.t() | nil,
          mime_type: String.t(),
          file_type: String.t(),
          ext: String.t(),
          file_checksum: String.t(),
          user_file_checksum: String.t(),
          size: integer(),
          width: integer() | nil,
          height: integer() | nil,
          duration: integer() | nil,
          status: String.t(),
          metadata: map() | nil,
          user_uuid: UUIDv7.t(),
          user_id: integer() | nil,
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          instances:
            [PhoenixKit.Modules.Storage.FileInstance.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_files" do
    field :original_file_name, :string
    field :file_name, :string
    field :file_path, :string
    field :mime_type, :string
    field :file_type, :string
    field :ext, :string
    field :file_checksum, :string
    field :user_file_checksum, :string
    field :size, :integer
    field :width, :integer
    field :height, :integer
    field :duration, :integer
    field :status, :string, default: "processing"
    field :metadata, :map

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer
    has_many :instances, PhoenixKit.Modules.Storage.FileInstance, foreign_key: :file_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a file.

  ## Required Fields

  - `original_file_name`
  - `file_name`
  - `mime_type`
  - `file_type` (must be: "image", "video", "document", "archive")
  - `ext`
  - `file_checksum`
  - `user_file_checksum`
  - `size`
  - `user_id`

  ## Validation Rules

  - File type must be valid
  - Status must be valid (processing, active, failed)
  - Size must be positive
  - Width/height must be positive (if provided)
  - Duration must be positive (if provided)
  """
  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :original_file_name,
      :file_name,
      :file_path,
      :mime_type,
      :file_type,
      :ext,
      :file_checksum,
      :user_file_checksum,
      :size,
      :width,
      :height,
      :duration,
      :status,
      :metadata,
      :user_id,
      :user_uuid
    ])
    |> validate_required([
      :original_file_name,
      :file_name,
      :mime_type,
      :file_type,
      :ext,
      :file_checksum,
      :user_file_checksum,
      :size,
      :user_uuid
    ])
    |> validate_inclusion(:file_type, ["image", "video", "document", "archive"])
    |> validate_inclusion(:status, ["processing", "active", "failed"])
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:duration, greater_than: 0)
    |> foreign_key_constraint(:user_uuid)
  end

  @doc """
  Returns whether this file type supports variant generation (scalable).
  """
  def scalable?(%__MODULE__{file_type: file_type}) when file_type in ["image", "video"],
    do: true

  def scalable?(_), do: false

  @doc """
  Returns whether this file is an image.
  """
  def image?(%__MODULE__{file_type: "image"}), do: true
  def image?(_), do: false

  @doc """
  Returns whether this file is a video.
  """
  def video?(%__MODULE__{file_type: "video"}), do: true
  def video?(_), do: false

  @doc """
  Returns whether this file is a document.
  """
  def document?(%__MODULE__{file_type: "document"}), do: true
  def document?(_), do: false

  @doc """
  Returns whether this file is an archive.
  """
  def archive?(%__MODULE__{file_type: "archive"}), do: true
  def archive?(_), do: false
end
