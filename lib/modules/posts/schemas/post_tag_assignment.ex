defmodule PhoenixKit.Modules.Posts.PostTagAssignment do
  @moduledoc """
  Junction schema for post-tag assignments.

  Many-to-many relationship between posts and tags. A post can have multiple tags,
  and a tag can be assigned to multiple posts.

  ## Fields

  - `post_id` - Reference to the post
  - `tag_id` - Reference to the tag

  ## Examples

      # Assign tag to post
      %PostTagAssignment{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        tag_id: "018e3c4a-1234-5678-abcd-ef1234567890"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{
          post_uuid: UUIDv7.t(),
          tag_uuid: UUIDv7.t(),
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          tag: PhoenixKit.Modules.Posts.PostTag.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_post_tag_assignments" do
    belongs_to :post, PhoenixKit.Modules.Posts.Post,
      foreign_key: :post_uuid,
      references: :uuid,
      type: UUIDv7,
      primary_key: true

    belongs_to :tag, PhoenixKit.Modules.Posts.PostTag,
      foreign_key: :tag_uuid,
      references: :uuid,
      type: UUIDv7,
      primary_key: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a post-tag assignment.

  ## Required Fields

  - `post_id` - Reference to post
  - `tag_id` - Reference to tag

  ## Validation Rules

  - Unique constraint on (post_id, tag_id) - no duplicate tags on same post
  """
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:post_uuid, :tag_uuid])
    |> validate_required([:post_uuid, :tag_uuid])
    |> foreign_key_constraint(:post_uuid)
    |> foreign_key_constraint(:tag_uuid)
    |> unique_constraint([:post_uuid, :tag_uuid],
      name: :phoenix_kit_post_tag_assignments_post_id_tag_id_index,
      message: "tag already assigned to this post"
    )
  end
end
