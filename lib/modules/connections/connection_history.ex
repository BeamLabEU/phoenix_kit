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

  - `user_a_uuid` / `user_b_uuid` - The two users involved (stored with lower UUID first for consistency)
  - `actor_uuid` - The user who performed this action
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_user_connections_history" do
    belongs_to :user_a, PhoenixKit.Users.Auth.User,
      foreign_key: :user_a_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :user_b, PhoenixKit.Users.Auth.User,
      foreign_key: :user_b_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :actor, PhoenixKit.Users.Auth.User,
      foreign_key: :actor_uuid,
      references: :uuid,
      type: UUIDv7

    field :action, :string
    field :inserted_at, :utc_datetime
  end

  @actions ~w(requested accepted rejected removed)

  @doc """
  Creates a changeset for a connection history record.

  The user_a_uuid and user_b_uuid are automatically normalized so that
  the lower UUID is always stored as user_a_uuid for consistent querying.
  """
  def changeset(history, attrs) do
    attrs = normalize_user_ids(attrs)

    history
    |> cast(attrs, [
      :user_a_uuid,
      :user_b_uuid,
      :actor_uuid,
      :action
    ])
    |> validate_required([:user_a_uuid, :user_b_uuid, :actor_uuid, :action])
    |> validate_inclusion(:action, @actions)
    |> put_timestamp()
    |> foreign_key_constraint(:user_a_uuid)
    |> foreign_key_constraint(:user_b_uuid)
    |> foreign_key_constraint(:actor_uuid)
  end

  # Normalize user UUIDs so user_a_uuid < user_b_uuid for consistent storage
  defp normalize_user_ids(%{user_a_uuid: a_uuid, user_b_uuid: b_uuid} = attrs)
       when is_binary(a_uuid) and is_binary(b_uuid) and a_uuid > b_uuid do
    %{attrs | user_a_uuid: b_uuid, user_b_uuid: a_uuid}
  end

  defp normalize_user_ids(attrs), do: attrs

  defp put_timestamp(changeset) do
    put_change(
      changeset,
      :inserted_at,
      UtilsDate.utc_now()
    )
  end
end
