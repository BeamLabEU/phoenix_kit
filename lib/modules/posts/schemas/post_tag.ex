defmodule PhoenixKit.Modules.Posts.PostTag do
  @moduledoc """
  Schema for post tags (hashtags).

  Hashtag system for post categorization with auto-slugification and usage tracking.
  Tags are shared across all posts (not user-specific).

  ## Fields

  - `name` - Display name (e.g., "Web Development")
  - `slug` - URL-safe slug (e.g., "web-development")
  - `usage_count` - How many posts use this tag (denormalized counter)

  ## Examples

      # Tag with multiple uses
      %PostTag{
        id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        name: "Web Development",
        slug: "web-development",
        usage_count: 142
      }

      # New tag
      %PostTag{
        name: "Elixir",
        slug: "elixir",
        usage_count: 0
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t(),
          slug: String.t(),
          usage_count: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_post_tags" do
    field :name, :string
    field :slug, :string
    field :usage_count, :integer, default: 0

    many_to_many :posts, PhoenixKit.Modules.Posts.Post,
      join_through: PhoenixKit.Modules.Posts.PostTagAssignment,
      join_keys: [tag_id: :uuid, post_id: :uuid]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a tag.

  ## Required Fields

  - `name` - Tag display name
  - `slug` - URL-safe slug (auto-generated from name if not provided)

  ## Validation Rules

  - Name must not be empty
  - Slug must be unique across all tags
  - Slug auto-generated from name if not provided
  - Usage count cannot be negative
  """
  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :slug, :usage_count])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must be lowercase letters, numbers, and hyphens only"
    )
    |> validate_number(:usage_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:slug, name: :phoenix_kit_post_tags_slug_index)
  end

  @doc """
  Increment usage counter.
  """
  def increment_usage(%__MODULE__{usage_count: count} = tag) do
    %{tag | usage_count: count + 1}
  end

  @doc """
  Decrement usage counter.
  """
  def decrement_usage(%__MODULE__{usage_count: count} = tag) when count > 0 do
    %{tag | usage_count: count - 1}
  end

  def decrement_usage(tag), do: tag

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
