defmodule PhoenixKit.Integration.Users.ProfileTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles

  defp unique_email, do: "profile_#{System.unique_integer([:positive])}@example.com"

  defp create_user(overrides \\ %{}) do
    attrs = Map.merge(%{email: unique_email(), password: "ValidPassword123!"}, overrides)
    {:ok, user} = Auth.register_user(attrs)
    user
  end

  describe "update_user_profile/2" do
    test "updates first and last name" do
      user = create_user()

      {:ok, updated} = Auth.update_user_profile(user, %{first_name: "Jane", last_name: "Doe"})

      assert updated.first_name == "Jane"
      assert updated.last_name == "Doe"
    end

    test "updates username" do
      user = create_user()

      {:ok, updated} = Auth.update_user_profile(user, %{username: "newusername"})
      assert updated.username == "newusername"
    end

    test "enforces unique username" do
      user1 = create_user(%{username: "taken"})
      user2 = create_user()

      {:error, changeset} = Auth.update_user_profile(user2, %{username: user1.username})
      assert errors_on(changeset).username != []
    end

    test "persists changes to database" do
      user = create_user()
      {:ok, _} = Auth.update_user_profile(user, %{first_name: "Persisted"})

      reloaded = Auth.get_user(user.uuid)
      assert reloaded.first_name == "Persisted"
    end

    test "updates timezone" do
      user = create_user()

      {:ok, updated} = Auth.update_user_profile(user, %{user_timezone: "-5"})
      assert updated.user_timezone == "-5"
    end

    test "empty attrs does not error" do
      user = create_user(%{first_name: "Original"})

      {:ok, updated} = Auth.update_user_profile(user, %{})
      assert updated.first_name == "Original"
    end
  end

  describe "update_user_custom_fields/2" do
    test "stores arbitrary custom fields" do
      user = create_user()

      {:ok, updated} =
        Auth.update_user_custom_fields(user, %{"company" => "Acme", "department" => "Engineering"})

      assert updated.custom_fields["company"] == "Acme"
      assert updated.custom_fields["department"] == "Engineering"
    end

    test "replaces entirely, not deep merge" do
      user = create_user()

      {:ok, updated1} = Auth.update_user_custom_fields(user, %{"key1" => "val1"})
      assert updated1.custom_fields["key1"] == "val1"

      {:ok, updated2} = Auth.update_user_custom_fields(updated1, %{"key2" => "val2"})
      assert updated2.custom_fields["key2"] == "val2"
      # Previous key replaced (not merged)
      refute Map.has_key?(updated2.custom_fields, "key1")
    end

    test "empty map clears custom fields" do
      user = create_user()

      {:ok, with_fields} = Auth.update_user_custom_fields(user, %{"color" => "blue"})
      assert with_fields.custom_fields["color"] == "blue"

      {:ok, cleared} = Auth.update_user_custom_fields(with_fields, %{})
      assert cleared.custom_fields == %{}
    end

    test "stores nested values" do
      user = create_user()

      {:ok, updated} =
        Auth.update_user_custom_fields(user, %{
          "preferences" => %{"theme" => "dark", "lang" => "en"}
        })

      assert updated.custom_fields["preferences"]["theme"] == "dark"
    end
  end

  describe "update_user_fields/2" do
    test "splits schema fields and custom fields" do
      user = create_user()

      {:ok, updated} =
        Auth.update_user_fields(user, %{
          "first_name" => "John",
          "last_name" => "Smith",
          "favorite_color" => "blue"
        })

      assert updated.first_name == "John"
      assert updated.last_name == "Smith"
      assert updated.custom_fields["favorite_color"] == "blue"
    end

    test "handles only schema fields" do
      user = create_user()

      {:ok, updated} = Auth.update_user_fields(user, %{"first_name" => "OnlySchema"})

      assert updated.first_name == "OnlySchema"
    end

    test "handles only custom fields" do
      user = create_user(%{first_name: "Keep"})

      {:ok, updated} = Auth.update_user_fields(user, %{"custom_key" => "custom_val"})

      assert updated.first_name == "Keep"
      assert updated.custom_fields["custom_key"] == "custom_val"
    end
  end

  describe "update_user_status/2" do
    test "activates a deactivated user" do
      # Create two users so Owner protection doesn't apply
      owner = create_user()
      user = create_user()

      {:ok, deactivated} = Auth.update_user_status(user, %{is_active: false})
      assert deactivated.is_active == false

      {:ok, activated} = Auth.update_user_status(deactivated, %{is_active: true})
      assert activated.is_active == true

      # Clean up: ensure owner exists to avoid interference
      assert Roles.user_has_role?(owner, "Owner")
    end

    test "deactivates a non-owner user" do
      _owner = create_user()
      user = create_user()

      {:ok, deactivated} = Auth.update_user_status(user, %{is_active: false})
      assert deactivated.is_active == false
    end

    test "cannot deactivate last Owner" do
      owner = create_user()
      assert Roles.user_has_role?(owner, "Owner")

      assert {:error, :cannot_deactivate_last_owner} =
               Auth.update_user_status(owner, %{is_active: false})
    end
  end

  describe "ensure_active_user/1" do
    test "returns active user" do
      user = create_user()
      assert Auth.ensure_active_user(user)
    end

    test "returns nil for inactive user" do
      _owner = create_user()
      user = create_user()

      {:ok, deactivated} = Auth.update_user_status(user, %{is_active: false})

      assert is_nil(Auth.ensure_active_user(deactivated))
    end

    test "returns nil for nil input" do
      assert is_nil(Auth.ensure_active_user(nil))
    end
  end

  describe "get_users_by_ids/1" do
    test "returns multiple users" do
      user1 = create_user()
      user2 = create_user()

      found = Auth.get_users_by_ids([user1.uuid, user2.uuid])
      uuids = Enum.map(found, & &1.uuid)

      assert user1.uuid in uuids
      assert user2.uuid in uuids
    end

    test "returns empty list for no matches" do
      assert Auth.get_users_by_ids([UUIDv7.generate()]) == []
    end
  end
end
