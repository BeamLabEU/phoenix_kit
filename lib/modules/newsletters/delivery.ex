defmodule PhoenixKit.Modules.Newsletters.Delivery do
  @moduledoc """
  Ecto schema for per-recipient delivery tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["pending", "sent", "delivered", "opened", "bounced", "failed"]

  schema "phoenix_kit_newsletters_deliveries" do
    field :status, :string, default: "pending"
    field :sent_at, :utc_datetime
    field :delivered_at, :utc_datetime
    field :opened_at, :utc_datetime
    field :error, :string
    field :message_id, :string
    field :broadcast_uuid, UUIDv7
    field :user_uuid, UUIDv7

    belongs_to :broadcast, PhoenixKit.Modules.Newsletters.Broadcast,
      foreign_key: :broadcast_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :broadcast_uuid,
      :user_uuid,
      :status,
      :sent_at,
      :delivered_at,
      :opened_at,
      :error,
      :message_id
    ])
    |> validate_required([:broadcast_uuid, :user_uuid])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:message_id)
  end

  def valid_statuses, do: @valid_statuses
end
