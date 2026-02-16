defmodule PhoenixKit.Users.RolePermissionTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission

  setup do
    Permissions.clear_custom_keys()
    :ok
  end

  defp valid_uuid, do: UUIDv7.generate()

  # --- changeset/2 ---

  describe "changeset/2 with valid data" do
    test "accepts valid role_uuid and module_key" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: valid_uuid(),
          module_key: "dashboard"
        })

      assert changeset.valid?
    end

    test "accepts all core section keys" do
      uuid = valid_uuid()

      for key <- Permissions.core_section_keys() do
        changeset =
          RolePermission.changeset(%RolePermission{}, %{
            role_uuid: uuid,
            module_key: key
          })

        assert changeset.valid?, "Expected #{key} to be valid"
      end
    end

    test "accepts all feature module keys" do
      uuid = valid_uuid()

      for key <- Permissions.feature_module_keys() do
        changeset =
          RolePermission.changeset(%RolePermission{}, %{
            role_uuid: uuid,
            module_key: key
          })

        assert changeset.valid?, "Expected #{key} to be valid"
      end
    end

    test "accepts optional granted_by fields" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: valid_uuid(),
          module_key: "users",
          granted_by: 42,
          granted_by_uuid: valid_uuid()
        })

      assert changeset.valid?
    end
  end

  describe "changeset/2 with invalid data" do
    test "requires role_uuid" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          module_key: "dashboard"
        })

      refute changeset.valid?
      assert has_error?(changeset, :role_uuid)
    end

    test "requires module_key" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: valid_uuid()
        })

      refute changeset.valid?
      assert has_error?(changeset, :module_key)
    end

    test "rejects invalid module_key" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: valid_uuid(),
          module_key: "nonexistent_module"
        })

      refute changeset.valid?
      assert has_error?(changeset, :module_key)
    end

    test "rejects empty module_key" do
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: valid_uuid(),
          module_key: ""
        })

      refute changeset.valid?
    end
  end

  describe "changeset/2 module_key validation covers all keys" do
    test "validates against the exact set of all_module_keys" do
      valid_keys = MapSet.new(Permissions.all_module_keys())
      uuid = valid_uuid()

      # A known valid key should pass
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: uuid,
          module_key: "dashboard"
        })

      assert changeset.valid?
      assert MapSet.member?(valid_keys, "dashboard")

      # A made-up key should fail
      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_uuid: uuid,
          module_key: "totally_fake"
        })

      refute changeset.valid?
      refute MapSet.member?(valid_keys, "totally_fake")
    end
  end

  # --- Helpers ---

  defp has_error?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end
end
