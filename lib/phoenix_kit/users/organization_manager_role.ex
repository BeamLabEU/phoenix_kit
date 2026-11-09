defmodule PhoenixKit.Users.OrganizationManagerRole do
  @moduledoc """
  One role on an acting link whose `all_roles` is false.

  Only references: the role's name and permissions stay on the role. `assigned_by`
  and `inserted_at` say who gave this role to this link and when, so changing a link
  touches only the rows that differ. `role_uuid` is `ON DELETE RESTRICT`: a role on a
  link is in use.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Role

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_organization_manager_roles" do
    belongs_to :organization_manager, OrganizationManager,
      foreign_key: :organization_manager_uuid,
      references: :uuid

    belongs_to :role, Role, foreign_key: :role_uuid, references: :uuid
    belongs_to :assigned_by, User, foreign_key: :assigned_by_uuid, references: :uuid

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
