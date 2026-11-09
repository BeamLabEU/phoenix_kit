defmodule PhoenixKit.Users.Role do
  @moduledoc """
  Role schema for PhoenixKit authorization system.

  This schema defines user roles that can be assigned to users for authorization purposes.

  ## Fields

  - `name`: Role name (unique, required for identification)
  - `description`: Human-readable description of the role
  - `data`: Label and description per language; shown through `Roles.display_name/2`
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
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Utils.Multilang

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t(),
          description: String.t() | nil,
          is_system_role: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @roles %{
    owner: "Owner",
    admin: "Admin",
    user: "User"
  }

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_user_roles" do
    field :name, :string
    field :description, :string
    # Label and description per language (`PhoenixKit.Utils.Multilang`). `name` above
    # stays the key code and settings match on; see `Roles.display_name/2`.
    field :data, :map, default: %{}
    # The primary-language label, for the form's primary tab. Never persisted.
    field :label, :string, virtual: true
    field :is_system_role, :boolean, default: false
    # Operator-defined order (V190): decides the default role of a new session
    # and the order the role switcher lists roles in. See
    # `PhoenixKit.Users.ActiveRole`.
    field :position, :integer, default: 0

    has_many :role_assignments, PhoenixKit.Users.RoleAssignment,
      foreign_key: :role_uuid,
      references: :uuid

    many_to_many :users, PhoenixKit.Users.Auth.User,
      join_through: PhoenixKit.Users.RoleAssignment,
      join_keys: [role_uuid: :uuid, user_uuid: :uuid]

    timestamps(type: :utc_datetime)
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
    |> cast(attrs, [:name, :description, :is_system_role, :position, :data])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 50)
    |> validate_length(:description, max: 500)
    |> validate_data_shape()
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
  @doc """
  Changeset for editing an existing role. `name` is a fixed key: code and settings
  match on it (the `new_user_default_role` setting, a host's `%{name: "Buyer"}`), so a
  changed one is an error. A different label belongs in `data`.
  """
  def update_changeset(%__MODULE__{} = role, attrs) do
    role
    |> cast(attrs, [:name, :label, :description, :position, :data])
    |> validate_length(:label, max: 50)
    |> validate_length(:description, max: 500)
    |> validate_data_shape()
    |> validate_name_unchanged()
    |> sync_label()
  end

  # With translations off the form has no `data`: the label folds in under the primary
  # language. When `data` is supplied it is the truth: the form already merged it.
  defp sync_label(%Ecto.Changeset{valid?: true, params: %{"label" => _} = params} = changeset)
       when not is_map_key(params, "data") do
    existing = get_field(changeset, :data) || %{}
    primary = existing["_primary_language"] || Multilang.primary_language()

    merged =
      Map.put(Multilang.get_primary_data(existing), "_label", get_field(changeset, :label) || "")

    put_change(changeset, :data, Multilang.put_language_data(existing, primary, merged))
  end

  defp sync_label(changeset), do: changeset

  defp validate_name_unchanged(changeset) do
    if Map.has_key?(changeset.changes, :name),
      do: add_error(changeset, :name, "cannot be changed"),
      else: changeset
  end

  # `data` is free-form once cast, and a string or list there would crash every reader.
  defp validate_data_shape(changeset) do
    if Multilang.valid_text_data?(get_field(changeset, :data)),
      do: changeset,
      else: add_error(changeset, :data, "is invalid")
  end

  defp validate_system_role_protection(changeset) do
    if changeset.data.is_system_role &&
         get_change(changeset, :is_system_role) == false do
      add_error(changeset, :is_system_role, "system roles cannot be modified")
    else
      changeset
    end
  end
end
