defmodule PhoenixKit.Posts.PostTagAssignment do
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
          post_id: UUIDv7.t(),
          tag_id: UUIDv7.t(),
          post: PhoenixKit.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          tag: PhoenixKit.Posts.PostTag.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_post_tag_assignments" do
    belongs_to :post, PhoenixKit.Posts.Post, type: UUIDv7, primary_key: true
    belongs_to :tag, PhoenixKit.Posts.PostTag, type: UUIDv7, primary_key: true

    timestamps(type: :naive_datetime)
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
    |> cast(attrs, [:post_id, :tag_id])
    |> validate_required([:post_id, :tag_id])
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:tag_id)
    |> unique_constraint([:post_id, :tag_id],
      name: :phoenix_kit_post_tag_assignments_post_id_tag_id_index,
      message: "tag already assigned to this post"
    )
  end
end
