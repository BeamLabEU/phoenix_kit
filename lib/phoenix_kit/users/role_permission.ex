defmodule PhoenixKit.Users.RolePermission do
  @moduledoc """
  Schema for module-level permissions assigned to roles.

  Each row grants a specific role access to one admin section or feature module.
  Row present = granted, absent = denied. Owner role bypasses this entirely in code.

  ## Fields

  - `role_id` - FK to phoenix_kit_user_roles
  - `module_key` - Identifies the admin section or feature module (e.g., "billing", "users")
  - `granted_by` - FK to phoenix_kit_users (audit: who granted this permission)
  - `inserted_at` - When the permission was granted
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          id: integer() | nil,
          role_id: integer(),
          role_uuid: UUIDv7.t() | nil,
          module_key: String.t(),
          granted_by: integer() | nil,
          granted_by_uuid: UUIDv7.t() | nil,
          inserted_at: NaiveDateTime.t() | nil
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_role_permissions" do
    field :id, :integer, read_after_writes: true
    field :module_key, :string
    field :granted_by, :integer
    field :granted_by_uuid, UUIDv7

    field :role_id, :integer
    belongs_to :role, Role, foreign_key: :role_uuid, references: :uuid, type: UUIDv7

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a role permission.
  """
  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:role_id, :role_uuid, :module_key, :granted_by, :granted_by_uuid])
    |> validate_required([:role_uuid, :module_key])
    |> validate_inclusion(:module_key, Permissions.all_module_keys())
    |> unique_constraint([:role_uuid, :module_key],
      name: :phoenix_kit_role_permissions_role_uuid_module_key_idx,
      message: "permission already granted"
    )
    |> foreign_key_constraint(:role_uuid)
  end
end
