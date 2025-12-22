defmodule PhoenixKit.Modules.Connections.BlockHistory do
  @moduledoc """
  Schema for block activity history.

  Records all block/unblock events for auditing and activity feeds.
  The main `Block` table stores only current state (active blocks),
  while this table preserves the complete history of actions.

  ## Actions

  - `"block"` - User blocked another user
  - `"unblock"` - User unblocked another user
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :id

  schema "phoenix_kit_user_blocks_history" do
    belongs_to :blocker, PhoenixKit.Users.Auth.User, type: :integer
    belongs_to :blocked, PhoenixKit.Users.Auth.User, type: :integer

    field :action, :string
    field :reason, :string
    field :inserted_at, :naive_datetime
  end

  @actions ~w(block unblock)

  @doc """
  Creates a changeset for a block history record.
  """
  def changeset(history, attrs) do
    history
    |> cast(attrs, [:blocker_id, :blocked_id, :action, :reason])
    |> validate_required([:blocker_id, :blocked_id, :action])
    |> validate_inclusion(:action, @actions)
    |> put_timestamp()
    |> foreign_key_constraint(:blocker_id)
    |> foreign_key_constraint(:blocked_id)
  end

  defp put_timestamp(changeset) do
    put_change(
      changeset,
      :inserted_at,
      NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    )
  end
end
