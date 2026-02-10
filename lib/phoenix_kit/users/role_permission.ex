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
          id: integer() | nil,
          uuid: Ecto.UUID.t() | nil,
          role_id: integer(),
          module_key: String.t(),
          granted_by: integer() | nil,
          inserted_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_role_permissions" do
    field :uuid, Ecto.UUID, read_after_writes: true
    field :module_key, :string
    field :granted_by, :integer

    belongs_to :role, Role

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a role permission.
  """
  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:role_id, :module_key, :granted_by])
    |> validate_required([:role_id, :module_key])
    |> validate_inclusion(:module_key, Permissions.all_module_keys())
    |> unique_constraint([:role_id, :module_key],
      name: :uq_role_permissions_role_module,
      message: "permission already granted"
    )
    |> foreign_key_constraint(:role_id)
  end
end
