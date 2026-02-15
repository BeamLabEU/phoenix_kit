defmodule PhoenixKit.Modules.Posts.PostMention do
  @moduledoc """
  Schema for post mentions (tagged users).

  Tags users related to a post - either as contributors who helped create it,
  or mentions of people featured in the content.

  ## Mention Types

  - `contributor` - User helped create/contribute to the post
  - `mention` - User is mentioned/tagged in the post

  ## Fields

  - `post_id` - Reference to the post
  - `user_id` - Reference to the mentioned user
  - `mention_type` - contributor/mention

  ## Examples

      # Contributor mention
      %PostMention{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 42,
        mention_type: "contributor"
      }

      # Regular mention
      %PostMention{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 15,
        mention_type: "mention"
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          id: UUIDv7.t() | nil,
          post_id: UUIDv7.t(),
          user_id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          mention_type: String.t(),
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_post_mentions" do
    field :mention_type, :string, default: "mention"

    belongs_to :post, PhoenixKit.Modules.Posts.Post, type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating or updating a mention.

  ## Required Fields

  - `post_id` - Reference to post
  - `user_id` - Reference to mentioned user
  - `mention_type` - Must be: "contributor" or "mention"

  ## Validation Rules

  - Mention type must be valid (contributor/mention)
  - Unique constraint on (post_id, user_id) - one mention per user per post
  """
  def changeset(mention, attrs) do
    mention
    |> cast(attrs, [:post_id, :user_id, :user_uuid, :mention_type])
    |> validate_required([:post_id, :user_uuid, :mention_type])
    |> validate_inclusion(:mention_type, ["contributor", "mention"])
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:post_id, :user_id],
      name: :phoenix_kit_post_mentions_post_id_user_id_index,
      message: "user already mentioned in this post"
    )
  end

  @doc """
  Check if mention is a contributor.
  """
  def contributor?(%__MODULE__{mention_type: "contributor"}), do: true
  def contributor?(_), do: false
end
