defmodule PhoenixKit.Modules.Posts.PostGroup do
  @moduledoc """
  Schema for user-created post groups (Pinterest-style boards).

  Users create groups/collections to organize their posts by theme, project, or topic.
  Groups are user-specific - each user has their own set of groups.

  ## Fields

  - `user_id` - Owner of the group
  - `name` - Group name (e.g., "Travel Photos", "Work Projects")
  - `slug` - URL-safe slug (e.g., "travel-photos")
  - `description` - Optional group description
  - `cover_image_id` - Optional cover image (reference to file)
  - `post_count` - Denormalized counter (updated via context)
  - `is_public` - Whether group is visible to others
  - `position` - Manual ordering of user's groups

  ## Examples

      # Public travel group
      %PostGroup{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 42,
        name: "Travel Adventures",
        slug: "travel-adventures",
        description: "My favorite travel moments",
        cover_image_id: "018e3c4a-1234-5678-abcd-ef1234567890",
        post_count: 23,
        is_public: true,
        position: 1
      }

      # Private work group
      %PostGroup{
        user_id: 42,
        name: "Client Projects",
        slug: "client-projects",
        description: nil,
        cover_image_id: nil,
        post_count: 0,
        is_public: false,
        position: 2
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          user_id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          name: String.t(),
          slug: String.t(),
          description: String.t() | nil,
          cover_image_uuid: UUIDv7.t() | nil,
          post_count: integer(),
          is_public: boolean(),
          position: integer(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t(),
          cover_image: PhoenixKit.Modules.Storage.File.t() | Ecto.Association.NotLoaded.t() | nil,
          posts: [PhoenixKit.Modules.Posts.Post.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_post_groups" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :post_count, :integer, default: 0
    field :is_public, :boolean, default: false
    field :position, :integer, default: 0

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer

    belongs_to :cover_image, PhoenixKit.Modules.Storage.File,
      foreign_key: :cover_image_uuid,
      references: :uuid,
      type: UUIDv7

    many_to_many :posts, PhoenixKit.Modules.Posts.Post,
      join_through: PhoenixKit.Modules.Posts.PostGroupAssignment,
      join_keys: [group_uuid: :uuid, post_uuid: :uuid]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a group.

  ## Required Fields

  - `user_id` - Owner of the group
  - `name` - Group name
  - `slug` - URL-safe slug (auto-generated from name if not provided)

  ## Validation Rules

  - Name must not be empty (max 100 chars)
  - Slug must be unique per user
  - Slug auto-generated from name if not provided
  - Position must be >= 0
  - Post count cannot be negative
  """
  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :user_id,
      :user_uuid,
      :name,
      :slug,
      :description,
      :cover_image_uuid,
      :is_public,
      :position,
      :post_count
    ])
    |> validate_required([:user_uuid, :name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 1000)
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must be lowercase letters, numbers, and hyphens only"
    )
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:post_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:cover_image_uuid)
    |> unique_constraint([:user_id, :slug],
      name: :phoenix_kit_post_groups_user_id_slug_index,
      message: "you already have a group with this slug"
    )
  end

  @doc """
  Check if group is public.
  """
  def public?(%__MODULE__{is_public: true}), do: true
  def public?(_), do: false

  @doc """
  Check if user owns the group.
  """
  def user_owns?(%__MODULE__{user_id: user_id}, user_id), do: true
  def user_owns?(_, _), do: false

  # Private Functions

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        name = get_field(changeset, :name)

        if name do
          slug = slugify(name)
          put_change(changeset, :slug, slug)
        else
          changeset
        end

      _slug ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end
end
