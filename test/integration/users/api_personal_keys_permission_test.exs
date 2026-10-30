defmodule PhoenixKit.Integration.Users.ApiPersonalKeysPermissionTest do
  @moduledoc """
  Upgrading core must not hand `api_personal_keys` to existing Admin roles, and holding it
  must not open what `api` opens.
  """
  # async: false - the boot sweep writes settings flags and role rows shared by every test.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  @key "api_personal_keys"

  defp role_uuid(name), do: Enum.find(Roles.list_roles(), &(&1.name == name)).uuid

  test "the boot sweep leaves it off the Admin role" do
    assert :ok = Permissions.auto_grant_new_keys_to_admin()

    permissions = Permissions.get_permissions_for_role(role_uuid("Admin"))
    refute @key in permissions
    assert "integrations_system" in permissions
  end

  test "an explicit grant is accepted, survives the sweep and does not imply api" do
    {:ok, role} = Roles.create_role(%{name: "PersonalKeys#{System.unique_integer([:positive])}"})
    assert {:ok, %{module_key: @key}} = Permissions.grant_permission(role.uuid, @key)

    assert :ok = Permissions.auto_grant_new_keys_to_admin()
    assert Permissions.get_permissions_for_role(role.uuid) == [@key]

    email = "pk_perm_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    {:ok, _} = Roles.assign_role(user, role.name)
    scope = Scope.for_user(Repo.get!(Auth.User, user.uuid), narrow: false)

    assert Scope.can?(scope, @key)
    refute Scope.can?(scope, "api")
  end

  test "the Owner holds it" do
    owner = Auth.get_user_by_email("seed-owner@phoenixkit.test")
    assert owner |> Scope.for_user(narrow: false) |> Scope.can?(@key)
  end
end
