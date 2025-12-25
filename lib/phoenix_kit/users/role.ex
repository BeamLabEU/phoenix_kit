defmodule PhoenixKit.Users.Role do
  @moduledoc """
  Role schema for PhoenixKit authorization system.

  This schema defines user roles that can be assigned to users for authorization purposes.

  ## Fields

  - `name`: Role name (unique, required for identification)
  - `description`: Human-readable description of the role
  - `is_system_role`: Whether this is a system-defined role that shouldn't be deleted

  ## System Roles

  PhoenixKit includes three built-in system roles:

  - **Owner**: System owner with full access (assigned to first user automatically)
  - **Admin**: Administrator with elevated privileges
  - **User**: Standard user with basic access (default for new users)

  ## Security Features

  - System roles cannot be deleted
  - Role names are unique
  - Automatic assignment of User role to new registrations
  - Automatic assignment of Owner role to first user
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          uuid: Ecto.UUID.t() | nil,
          name: String.t(),
          description: String.t() | nil,
          is_system_role: boolean(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @roles %{
    owner: "Owner",
    admin: "Admin",
    user: "User"
  }

  schema "phoenix_kit_user_roles" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :description, :string
    field :is_system_role, :boolean, default: false

    has_many :role_assignments, PhoenixKit.Users.RoleAssignment
    many_to_many :users, PhoenixKit.Users.Auth.User, join_through: PhoenixKit.Users.RoleAssignment

    timestamps()
  end

  @doc """
  A role changeset for creating and updating roles.

  ## Parameters

  - `role`: The role struct to modify
  - `attrs`: Attributes to update

  ## Examples

      iex> changeset(%Role{}, %{name: "Manager", description: "Department manager"})
      %Ecto.Changeset{valid?: true}

      iex> changeset(%Role{}, %{name: ""})
      %Ecto.Changeset{valid?: false}
  """
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description, :is_system_role])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 50)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name)
    |> validate_system_role_protection()
  end

  @doc """
  Returns the map of system role names.

  ## Examples

      iex> system_roles()
      %{owner: "Owner", admin: "Admin", user: "User"}
  """
  def system_roles do
    @roles
  end

  @doc """
  Checks if a role name is a system role.

  ## Examples
      iex> system_role?(system_roles().owner)
      true

      iex> system_role?("Owner")
      true

      iex> system_role?("Manager")
      false
  """
  def system_role?(role_name) when is_binary(role_name) do
    role_name in Map.values(system_roles())
  end

  # Protect system roles from being modified
  defp validate_system_role_protection(changeset) do
    if get_field(changeset, :is_system_role) &&
         get_change(changeset, :is_system_role) == false do
      add_error(changeset, :is_system_role, "system roles cannot be modified")
    else
      changeset
    end
  end
end
