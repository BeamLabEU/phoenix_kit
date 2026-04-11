defmodule PhoenixKit.Users.OrganizationInvitation do
  @moduledoc """
  Schema for organization invitations.

  Represents an invitation sent by an organization admin to a person (by email).
  The raw token is never stored — only the SHA-256 hash, following the UserToken pattern.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_organization_invitations" do
    field :email, :string

    field :status, Ecto.Enum,
      values: [:pending, :accepted, :declined, :cancelled],
      default: :pending

    field :token, :binary
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime

    belongs_to :organization, User,
      foreign_key: :organization_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :invited_by, User,
      foreign_key: :invited_by_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new invitation."
  def create_changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :organization_uuid, :invited_by_uuid, :token, :expires_at])
    |> validate_required([:email, :organization_uuid, :token, :expires_at])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:token)
  end

  @doc "Changeset for accepting an invitation."
  def accept_changeset(invitation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(invitation, status: :accepted, accepted_at: now)
  end

  @doc "Changeset for declining an invitation."
  def decline_changeset(invitation) do
    change(invitation, status: :declined)
  end

  @doc "Changeset for cancelling an invitation. Only :pending invitations can be cancelled."
  def cancel_changeset(invitation) do
    if invitation.status == :pending do
      change(invitation, status: :cancelled)
    else
      invitation
      |> change()
      |> add_error(:status, "can only cancel pending invitations")
    end
  end
end
