defmodule PhoenixKit.Users.OrganizationManager do
  @moduledoc """
  A person's grant to act for a managed organization.

  This relationship is independent of `User.organization_uuid` (employment).
  Creating and removing grants belongs to the organization context, which
  must authorize the caller and serialize changes on the organization row.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_organization_managers" do
    belongs_to :organization, User, foreign_key: :organization_uuid, references: :uuid
    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid
    belongs_to :granted_by, User, foreign_key: :granted_by_uuid, references: :uuid
    timestamps(type: :utc_datetime)
  end

  @doc "Validates the grant's identity; the context checks account eligibility and authority."
  def changeset(manager, attrs) do
    manager
    |> cast(attrs, [:organization_uuid, :user_uuid, :granted_by_uuid])
    |> validate_required([:organization_uuid, :user_uuid])
    |> validate_change(:user_uuid, &validate_person/2)
    |> validate_change(:organization_uuid, &validate_organization/2)
    |> foreign_key_constraint(:organization_uuid)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:granted_by_uuid)
    |> check_constraint(:user_uuid, name: :phoenix_kit_organization_managers_not_self_check)
    |> unique_constraint([:organization_uuid, :user_uuid],
      name: :phoenix_kit_organization_managers_org_user_index
    )
  end

  defp validate_person(field, uuid) do
    case RepoHelper.repo().get(User, uuid) do
      %User{account_type: "person", api_only: false, is_active: true} -> []
      _ -> [{field, "must be an active person account"}]
    end
  end

  defp validate_organization(field, uuid) do
    case RepoHelper.repo().get(User, uuid) do
      %User{account_type: "organization", managed_by_members: true, is_active: true} -> []
      _ -> [{field, "must be an active managed organization"}]
    end
  end
end
