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

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :id

  schema "phoenix_kit_user_follows_history" do
    belongs_to :follower, PhoenixKit.Users.Auth.User, type: :integer
    belongs_to :followed, PhoenixKit.Users.Auth.User, type: :integer

    field :action, :string
    field :inserted_at, :naive_datetime
  end

  @actions ~w(follow unfollow)

  @doc """
  Creates a changeset for a follow history record.
  """
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:follower_id, :followed_id, :action])
    |> validate_required([:follower_id, :followed_id, :action])
    |> validate_inclusion(:action, @actions)
    |> put_timestamp()
    |> foreign_key_constraint(:follower_id)
    |> foreign_key_constraint(:followed_id)
  end

  defp put_timestamp(changeset) do
    put_change(
      changeset,
      :inserted_at,
      NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    )
  end
end
