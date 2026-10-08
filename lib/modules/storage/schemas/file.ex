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
  - `trashed` - File is in trash, pending restoration or permanent deletion

  ## Fields

  - `original_file_name` - User's original filename
  - `file_name` - System filename (uuid_v7-original.ext)
  - `mime_type` - MIME type (image/jpeg, video/mp4, etc.)
  - `file_type` - High-level type (image, video, document, archive)
  - `ext` - File extension (jpg, mp4, pdf, etc.)
  - `file_checksum` - SHA256 hash of file content for integrity verification
  - `user_file_checksum` - SHA256 hash of (user_uuid + file_checksum) for per-user deduplication
  - `size` - File size in bytes
  - `width` - Image/video width in pixels (nullable)
  - `height` - Image/video height in pixels (nullable)
  - `aspect_ratio` - `width / height`, kept by Postgres (V212; read-only, nil
    without a usable size). The wide/tall filters read it:
    `PhoenixKit.Modules.Storage.Shape`
  - `duration` - Video duration in seconds (nullable)
  - `status` - Processing status
  - `metadata` - JSONB with EXIF, codec info, etc.
  - `taken_at`, `taken_on`, `taken_at_offset`, `taken_at_source` - When the
    photo or video was taken (V200); see `PhoenixKit.Modules.Storage.CaptureDate`
  - `data` - JSONB with the title, alt text and description per language
    (V199). Read and written through `PhoenixKit.Modules.Storage.FileDetails`
  - `user_uuid` - Owner of the file

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
        user_uuid: "018e3c4a-1234-5678-abcd-ef1234567890"
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
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Storage.CaptureDate

  @primary_key {:uuid, UUIDv7, autogenerate: true}
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
          aspect_ratio: float() | nil,
          duration: integer() | nil,
          status: String.t(),
          trashed_at: DateTime.t() | nil,
          metadata: map() | nil,
          data: map(),
          taken_at: DateTime.t() | nil,
          taken_on: Date.t() | nil,
          taken_at_offset: integer() | nil,
          taken_at_source: String.t() | nil,
          system_managed: boolean(),
          user_uuid: UUIDv7.t() | nil,
          folder_uuid: UUIDv7.t() | nil,
          parent_file_uuid: UUIDv7.t() | nil,
          library_uuid: UUIDv7.t() | nil,
          placed_profile_uuid: UUIDv7.t() | nil,
          placed_revision: integer() | nil,
          placed_variant_set_uuid: UUIDv7.t() | nil,
          placed_variant_revision: integer() | nil,
          reconcile_attempted_at: NaiveDateTime.t() | nil,
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          parent_file: t() | Ecto.Association.NotLoaded.t() | nil,
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
    # width / height, computed by Postgres (V212): never written, so it is not in
    # any changeset; read back after an insert or update.
    field :aspect_ratio, :float, read_after_writes: true
    field :duration, :integer
    field :status, :string, default: "processing"
    field :trashed_at, :utc_datetime
    field :metadata, :map

    # When the photo or video was taken (V200). `taken_on` is the LOCAL date,
    # which is what a library groups by; `taken_at` is UTC. Written only
    # through `CaptureDate.replace?/2`'s guard — see
    # `PhoenixKit.Modules.Storage.CaptureDate` for the sources and why a
    # date is never downgraded.
    field :taken_at, :utc_datetime
    field :taken_on, :date
    field :taken_at_offset, :integer
    field :taken_at_source, :string

    # The title, alt text and description per language (V199) —
    # `%{"en-US" => %{"title" => …, "alt" => …}, "et" => %{…}}`. Owned by
    # `PhoenixKit.Modules.Storage.FileDetails`; read it through that.
    field :data, :map, default: %{}

    # `true` for internally-generated media (e.g. Tessera DZI tile pyramids
    # and their per-tile chunks). System-managed rows are excluded from the
    # MediaBrowser's user-facing listings and skipped by the variant
    # generator.
    field :system_managed, :boolean, default: false

    # Image editing (V195; `PhoenixKit.Modules.Storage.ImageEditing`). An
    # edited image keeps this uuid and its original instance holds the edited
    # bytes; `edits` is always applied to the unedited original, which lives
    # on as the system-managed child named by `original_file_uuid`.
    # `edit_state` "pending" or "failed" makes the file serve a placeholder.
    field :edits, :map
    field :edit_revision, :integer, default: 0
    field :edit_state, :string

    belongs_to :original_file, __MODULE__,
      foreign_key: :original_file_uuid,
      references: :uuid,
      type: UUIDv7

    # On a "save as copy" result: the file it was edited from.
    belongs_to :edited_from, __MODULE__,
      foreign_key: :edited_from_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :folder, PhoenixKit.Modules.Storage.Folder,
      foreign_key: :folder_uuid,
      references: :uuid,
      type: UUIDv7

    # For system-managed children (e.g. tile chunks), points at the source
    # File the chunk was derived from. Cascade-deletes via the DB FK
    # `ON DELETE :delete_all`, so removing a source image clears its tiles.
    belongs_to :parent_file, __MODULE__,
      foreign_key: :parent_file_uuid,
      references: :uuid,
      type: UUIDv7

    # The library the file belongs to (V202). The column defaults to Media, so
    # a writer that names no library lands there; `read_after_writes` reads
    # the default back into the returned struct.
    field :library_uuid, UUIDv7, read_after_writes: true

    belongs_to :library, PhoenixKit.Modules.Storage.Library,
      foreign_key: :library_uuid,
      references: :uuid,
      type: UUIDv7,
      define_field: false

    # What placed the file's bytes and made its variants (V205): a storage
    # profile and a variant set, each at a revision. NULL means the Default
    # at revision 1, which is what every file stored before V205 is. The
    # reconciler brings a file whose stamps differ from its library's up to
    # date and stamps it (`Storage.Profiles`, `Storage.VariantSets`).
    field :placed_profile_uuid, UUIDv7
    field :placed_revision, :integer
    field :placed_variant_set_uuid, UUIDv7
    field :placed_variant_revision, :integer
    # When the reconciler last tried the file and could not finish (it
    # waits before trying it again).
    field :reconcile_attempted_at, :naive_datetime

    has_many :instances, PhoenixKit.Modules.Storage.FileInstance, foreign_key: :file_uuid
    has_many :folder_links, PhoenixKit.Modules.Storage.FolderLink, foreign_key: :file_uuid

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
  - `user_uuid`

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
      :trashed_at,
      :metadata,
      :taken_at,
      :taken_on,
      :taken_at_offset,
      :taken_at_source,
      :system_managed,
      :user_uuid,
      :folder_uuid,
      :parent_file_uuid,
      :library_uuid
    ])
    |> validate_required([
      :original_file_name,
      :file_name,
      :mime_type,
      :file_type,
      :ext,
      :file_checksum,
      :user_file_checksum,
      :size
    ])
    |> validate_inclusion(:file_type, [
      "image",
      "video",
      "audio",
      "document",
      "archive",
      "other",
      "tile"
    ])
    |> validate_inclusion(:status, ["processing", "active", "failed", "trashed"])
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:duration, greater_than: 0)
    |> validate_inclusion(:taken_at_source, CaptureDate.sources())
    |> validate_system_managed_invariants()
    |> foreign_key_constraint(:user_uuid, name: :fk_files_user_uuid)
    |> foreign_key_constraint(:folder_uuid)
    |> foreign_key_constraint(:parent_file_uuid)
    |> foreign_key_constraint(:library_uuid, name: :phoenix_kit_files_library_uuid_fkey)
    # V113's `phoenix_kit_files_system_dedup_index` keeps concurrent
    # lazy-generators for the same Tessera tile from inserting duplicate
    # rows. Naming the constraint here lets `Storage.store_system_file/3`
    # detect the race via the changeset error and re-fetch the winning
    # row instead of bubbling a Postgrex unique-violation.
    |> unique_constraint([:parent_file_uuid, :file_name],
      name: :phoenix_kit_files_system_dedup_index
    )
  end

  @doc """
  Changeset for a file's translatable details: nothing but `metadata` and
  `data`, as `PhoenixKit.Modules.Storage.FileDetails.file_attrs/4` builds
  them. Use `PhoenixKit.Modules.Storage.update_file_details/3`, which holds
  the row while it merges.
  """
  def details_changeset(file, attrs) do
    cast(file, attrs, [:metadata, :data])
  end

  # User-uploaded files require `user_uuid` (existing invariant). System-
  # managed files (tile chunks) don't have a user owner — they live under
  # a parent File and inherit lifecycle from it.
  defp validate_system_managed_invariants(changeset) do
    case get_field(changeset, :system_managed) do
      true ->
        validate_required(changeset, [:parent_file_uuid])

      _ ->
        validate_required(changeset, [:user_uuid])
    end
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
