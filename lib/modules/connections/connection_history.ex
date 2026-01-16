defmodule PhoenixKit.Modules.Connections.ConnectionHistory do
  @moduledoc """
  Schema for connection activity history.

  Records all connection-related events for auditing and activity feeds.
  The main `Connection` table stores only current state per user pair,
  while this table preserves the complete history of actions.

  ## Actions

  - `"requested"` - User requested a connection
  - `"accepted"` - User accepted a connection request
  - `"rejected"` - User rejected a connection request
  - `"removed"` - User removed an existing connection

  ## Fields

  - `user_a_id` / `user_b_id` - The two users involved (always stored with lower ID first for consistency)
  - `actor_id` - The user who performed this action
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :id

  schema "phoenix_kit_user_connections_history" do
    belongs_to :user_a, PhoenixKit.Users.Auth.User, type: :integer
    belongs_to :user_b, PhoenixKit.Users.Auth.User, type: :integer
    belongs_to :actor, PhoenixKit.Users.Auth.User, type: :integer

    field :action, :string
    field :inserted_at, :naive_datetime
  end

  @actions ~w(requested accepted rejected removed)

  @doc """
  Creates a changeset for a connection history record.

  The user_a_id and user_b_id are automatically normalized so that
  the lower ID is always stored as user_a_id for consistent querying.
  """
  def changeset(history, attrs) do
    attrs = normalize_user_ids(attrs)

    history
    |> cast(attrs, [:user_a_id, :user_b_id, :actor_id, :action])
    |> validate_required([:user_a_id, :user_b_id, :actor_id, :action])
    |> validate_inclusion(:action, @actions)
    |> put_timestamp()
    |> foreign_key_constraint(:user_a_id)
    |> foreign_key_constraint(:user_b_id)
    |> foreign_key_constraint(:actor_id)
  end

  # Normalize user IDs so user_a_id < user_b_id for consistent storage
  defp normalize_user_ids(%{user_a_id: a, user_b_id: b} = attrs) when a > b do
    %{attrs | user_a_id: b, user_b_id: a}
  end

  defp normalize_user_ids(attrs), do: attrs

  defp put_timestamp(changeset) do
    put_change(
      changeset,
      :inserted_at,
      NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    )
  end
end
