defmodule PhoenixKit.Modules.Connections.FollowHistory do
  @moduledoc """
  Schema for follow activity history.

  Records all follow/unfollow events for auditing and activity feeds.
  The main `Follow` table stores only current state (active follows),
  while this table preserves the complete history of actions.

  ## Actions

  - `"follow"` - User followed another user
  - `"unfollow"` - User unfollowed another user
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_user_follows_history" do
    belongs_to :follower, PhoenixKit.Users.Auth.User,
      foreign_key: :follower_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :followed, PhoenixKit.Users.Auth.User,
      foreign_key: :followed_uuid,
      references: :uuid,
      type: UUIDv7

    field :follower_id, :integer
    field :followed_id, :integer

    field :action, :string
    field :inserted_at, :utc_datetime
  end

  @actions ~w(follow unfollow)

  @doc """
  Creates a changeset for a follow history record.
  """
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:follower_uuid, :followed_uuid, :follower_id, :followed_id, :action])
    |> validate_required([:follower_uuid, :followed_uuid, :action])
    |> validate_inclusion(:action, @actions)
    |> put_timestamp()
    |> foreign_key_constraint(:follower_uuid)
    |> foreign_key_constraint(:followed_uuid)
  end

  defp put_timestamp(changeset) do
    put_change(
      changeset,
      :inserted_at,
      UtilsDate.utc_now()
    )
  end
end
