defmodule PhoenixKit.Users.RoleAssignment do
  @moduledoc """
  Role assignment schema for PhoenixKit authorization system.

  This schema represents the many-to-many relationship between users and roles,
  with additional metadata about when and by whom the role was assigned.

  ## Fields

  - `user_uuid`: UUID reference to the user who has the role
  - `role_uuid`: UUID reference to the role being assigned
  - `assigned_by_uuid`: UUID reference to the user who assigned this role (can be nil for system assignments)
  - `assigned_at`: Timestamp when the role was assigned

  ## Features

  - Tracks role assignment history
  - Supports bulk role management
  - Audit trail for security purposes
  - Direct deletion for role removal
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          id: integer() | nil,
          user_uuid: UUIDv7.t() | nil,
          role_uuid: UUIDv7.t() | nil,
          assigned_by_uuid: UUIDv7.t() | nil,
          assigned_at: DateTime.t(),
          inserted_at: DateTime.t()
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_user_role_assignments" do
    field :id, :integer, read_after_writes: true

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :role, PhoenixKit.Users.Role,
      foreign_key: :role_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :assigned_by_user, PhoenixKit.Users.Auth.User,
      foreign_key: :assigned_by_uuid,
      references: :uuid,
      type: UUIDv7

    field :assigned_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  A role assignment changeset for creating role assignments.

  ## Parameters

  - `role_assignment`: The role assignment struct to modify
  - `attrs`: Attributes to update

  ## Examples

      iex> changeset(%RoleAssignment{}, %{user_uuid: "...", role_uuid: "..."})
      %Ecto.Changeset{valid?: true}

      iex> changeset(%RoleAssignment{}, %{})
      %Ecto.Changeset{valid?: false}
  """
  def changeset(role_assignment, attrs) do
    role_assignment
    |> cast(attrs, [
      :user_uuid,
      :role_uuid,
      :assigned_by_uuid,
      :assigned_at
    ])
    |> validate_required([:user_uuid, :role_uuid])
    |> put_assigned_at()
    |> unique_constraint([:user_uuid, :role_uuid],
      name: :phoenix_kit_role_assignments_user_uuid_role_uuid_idx,
      message: "user already has this role"
    )
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:role_uuid)
    |> foreign_key_constraint(:assigned_by_uuid)
  end

  # Set assigned_at to current time if not provided
  defp put_assigned_at(changeset) do
    case get_field(changeset, :assigned_at) do
      nil ->
        put_change(
          changeset,
          :assigned_at,
          DateTime.utc_now()
        )

      _ ->
        changeset
    end
  end
end
