defmodule PhoenixKit.Modules.Posts.PostView do
  @moduledoc """
  Schema for post view tracking (analytics).

  Tracks when posts are viewed for analytics purposes. Supports session-based
  deduplication to avoid counting multiple views from the same visitor.

  ## Fields

  - `post_id` - Reference to the viewed post
  - `user_id` - Reference to the viewer (nullable for guests)
  - `ip_address` - Hashed IP for privacy
  - `user_agent_hash` - Hashed browser fingerprint
  - `session_id` - Session identifier for deduplication
  - `viewed_at` - Timestamp of view

  ## Examples

      # Logged-in user view
      %PostView{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: 42,
        ip_address: "hashed_ip",
        user_agent_hash: "hashed_ua",
        session_id: "session_abc123",
        viewed_at: ~U[2025-01-01 12:00:00Z]
      }

      # Guest view
      %PostView{
        post_id: "018e3c4a-9f6b-7890-abcd-ef1234567890",
        user_id: nil,
        ip_address: "hashed_ip",
        user_agent_hash: "hashed_ua",
        session_id: "session_xyz789",
        viewed_at: ~U[2025-01-01 13:30:00Z]
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
          ip_address: String.t() | nil,
          user_agent_hash: String.t() | nil,
          session_id: String.t() | nil,
          viewed_at: DateTime.t(),
          post: PhoenixKit.Modules.Posts.Post.t() | Ecto.Association.NotLoaded.t(),
          user: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_post_views" do
    field :ip_address, :string
    field :user_agent_hash, :string
    field :session_id, :string
    field :viewed_at, :utc_datetime_usec

    belongs_to :post, PhoenixKit.Modules.Posts.Post, type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_id, :integer

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating a post view record.

  ## Required Fields

  - `post_id` - Reference to post
  - `viewed_at` - Timestamp of view

  ## Validation Rules

  - viewed_at must not be in the future
  """
  def changeset(view, attrs) do
    view
    |> cast(attrs, [
      :post_id,
      :user_id,
      :user_uuid,
      :ip_address,
      :user_agent_hash,
      :session_id,
      :viewed_at
    ])
    |> validate_required([:post_id, :viewed_at])
    |> validate_viewed_at_not_future()
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:user_uuid)
  end

  @doc """
  Hash an IP address for privacy.
  """
  def hash_ip(ip_address) when is_binary(ip_address) do
    :crypto.hash(:sha256, ip_address) |> Base.encode16(case: :lower)
  end

  @doc """
  Hash a user agent for privacy.
  """
  def hash_user_agent(user_agent) when is_binary(user_agent) do
    :crypto.hash(:sha256, user_agent) |> Base.encode16(case: :lower)
  end

  # Private Functions

  defp validate_viewed_at_not_future(changeset) do
    viewed_at = get_field(changeset, :viewed_at)

    if viewed_at && DateTime.compare(viewed_at, DateTime.utc_now()) == :gt do
      add_error(changeset, :viewed_at, "cannot be in the future")
    else
      changeset
    end
  end
end
