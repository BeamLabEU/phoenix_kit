defmodule PhoenixKit.Modules.Newsletters.ListMember do
  @moduledoc """
  Ecto schema for newsletter list membership.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["active", "unsubscribed"]

  schema "phoenix_kit_newsletters_list_members" do
    field :status, :string, default: "active"
    field :subscribed_at, :utc_datetime
    field :unsubscribed_at, :utc_datetime
    field :user_uuid, UUIDv7
    field :list_uuid, UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :list, PhoenixKit.Modules.Newsletters.List,
      foreign_key: :list_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    # No timestamps — uses subscribed_at/unsubscribed_at instead
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:user_uuid, :list_uuid, :status, :subscribed_at, :unsubscribed_at])
    |> validate_required([:user_uuid, :list_uuid])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:user_uuid, :list_uuid])
    |> maybe_set_subscribed_at()
  end

  defp maybe_set_subscribed_at(changeset) do
    case get_field(changeset, :subscribed_at) do
      nil -> put_change(changeset, :subscribed_at, PhoenixKit.Utils.Date.utc_now())
      _ -> changeset
    end
  end
end
