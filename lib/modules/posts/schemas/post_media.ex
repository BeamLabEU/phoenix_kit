defmodule PhoenixKit.Modules.Posts.PostMedia do
  @moduledoc """
  Junction schema for post media attachments.

  Links posts to uploaded files (images/videos) with ordering and captions.
  Enables ordered image galleries in posts with per-image captions.

  ## Fields

  - `post_id` - Reference to the post
  - `file_id` - Reference to the uploaded file (PhoenixKit.Storage.File)
  - `position` - Display order (1, 2, 3, etc.)
  - `caption` - Optional caption/alt text for the image

  ## Examples

      # First image in post
      %PostMedia{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        file_id: "018e3c4a-1234-5678-abcd-ef1234567890",
        position: 1,
        caption: "Beautiful sunset at the beach"
      }

      # Second image
      %PostMedia{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        file_id: "018e3c4a-5678-1234-abcd-ef1234567890",
        position: 2,
        caption: nil
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          post_uuid: UUIDv7.t(),
          file_uuid: UUIDv7.t(),
          position: integer(),
          caption: String.t() | nil,
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          file: PhoenixKit.Modules.Storage.File.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_post_media" do
    field :position, :integer
    field :caption, :string

    belongs_to :post, PhoenixKit.Modules.Posts.Post, foreign_key: :post_uuid, references: :uuid
    belongs_to :file, PhoenixKit.Modules.Storage.File, foreign_key: :file_uuid, references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating post media.

  ## Required Fields

  - `post_id` - Reference to post
  - `file_id` - Reference to file
  - `position` - Display order (must be positive)

  ## Validation Rules

  - Position must be greater than 0
  - Unique constraint on (post_id, position) - enforced at database level
  """
  def changeset(media, attrs) do
    media
    |> cast(attrs, [:post_uuid, :file_uuid, :position, :caption])
    |> validate_required([:post_uuid, :file_uuid, :position])
    |> validate_number(:position, greater_than: 0)
    |> foreign_key_constraint(:post_uuid)
    |> foreign_key_constraint(:file_uuid)
    |> unique_constraint([:post_uuid, :position],
      name: :phoenix_kit_post_media_post_uuid_position_index,
      message: "position already taken for this post"
    )
  end
end
