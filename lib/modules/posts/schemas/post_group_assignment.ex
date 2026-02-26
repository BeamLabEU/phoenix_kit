defmodule PhoenixKit.Modules.Posts.PostGroupAssignment do
  @moduledoc """
  Junction schema for post-group assignments.

  Many-to-many relationship between posts and groups. A post can be in multiple groups,
  and a group can contain multiple posts. Position allows manual ordering within each group.

  ## Fields

  - `post_id` - Reference to the post
  - `group_id` - Reference to the group
  - `position` - Display order within the group (0, 1, 2, etc.)

  ## Examples

      # First post in group
      %PostGroupAssignment{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        group_id: "018e3c4a-1234-5678-abcd-ef1234567890",
        position: 0
      }

      # Second post in group
      %PostGroupAssignment{
        post_id: "018e3c4a-5678-1234-abcd-ef1234567890",
        group_id: "018e3c4a-1234-5678-abcd-ef1234567890",
        position: 1
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{
          post_uuid: UUIDv7.t(),
          group_uuid: UUIDv7.t(),
          position: integer(),
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          group: PhoenixKit.Modules.Posts.PostGroup.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_post_group_assignments" do
    field :position, :integer, default: 0

    belongs_to :post, PhoenixKit.Modules.Posts.Post,
      foreign_key: :post_uuid,
      references: :uuid,
      type: UUIDv7,
      primary_key: true

    belongs_to :group, PhoenixKit.Modules.Posts.PostGroup,
      foreign_key: :group_uuid,
      references: :uuid,
      type: UUIDv7,
      primary_key: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a post-group assignment.

  ## Required Fields

  - `post_id` - Reference to post
  - `group_id` - Reference to group

  ## Validation Rules

  - Position must be >= 0
  - Unique constraint on (post_id, group_id) - post can't be in same group twice
  """
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:post_uuid, :group_uuid, :position])
    |> validate_required([:post_uuid, :group_uuid])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:post_uuid)
    |> foreign_key_constraint(:group_uuid)
    |> unique_constraint([:post_uuid, :group_uuid],
      name: :phoenix_kit_post_group_assignments_post_id_group_id_index,
      message: "post already in this group"
    )
  end
end
