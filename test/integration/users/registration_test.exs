defmodule PhoenixKit.Integration.Users.RegistrationTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles

  defp unique_email, do: "user_#{System.unique_integer([:positive])}@example.com"

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(%{email: unique_email(), password: "ValidPassword123!"}, overrides)
  end

  describe "register_user/2" do
    test "creates user with valid attributes" do
      {:ok, user} = Auth.register_user(valid_attrs())

      assert user.uuid
      assert user.email
      assert user.hashed_password
      assert user.is_active == true
      assert is_nil(user.confirmed_at)
    end

    test "first registered user gets Owner role" do
      {:ok, user} = Auth.register_user(valid_attrs())

      assert Roles.user_has_role?(user, "Owner")
    end

    test "second registered user gets User role" do
      {:ok, _first} = Auth.register_user(valid_attrs())
      {:ok, second} = Auth.register_user(valid_attrs())

      assert Roles.user_has_role?(second, "User")
      refute Roles.user_has_role?(second, "Owner")
    end

    test "hashes password and does not store plaintext" do
      password = "ValidPassword123!"
      {:ok, user} = Auth.register_user(valid_attrs(%{password: password}))

      assert user.hashed_password != password
      assert is_nil(user.password)
    end

    test "enforces unique email" do
      attrs = valid_attrs()
      {:ok, _} = Auth.register_user(attrs)
      {:error, changeset} = Auth.register_user(attrs)

      assert "has already been taken" in errors_on(changeset).email
    end

    test "validates email format" do
      {:error, changeset} = Auth.register_user(valid_attrs(%{email: "not-an-email"}))

      assert errors_on(changeset).email != []
    end

    test "validates password length" do
      {:error, changeset} = Auth.register_user(valid_attrs(%{password: "short"}))

      assert errors_on(changeset).password != []
    end

    test "rejects missing email" do
      {:error, changeset} = Auth.register_user(%{password: "ValidPassword123!"})

      assert errors_on(changeset).email != []
    end

    test "rejects missing password" do
      {:error, changeset} = Auth.register_user(%{email: unique_email()})

      assert errors_on(changeset).password != []
    end

    test "stores optional fields" do
      attrs = valid_attrs(%{first_name: "Jane", last_name: "Doe", username: "janedoe"})
      {:ok, user} = Auth.register_user(attrs)

      assert user.first_name == "Jane"
      assert user.last_name == "Doe"
      assert user.username == "janedoe"
    end
  end

  describe "get_user_by_email/1" do
    test "returns user for existing email" do
      {:ok, user} = Auth.register_user(valid_attrs())

      found = Auth.get_user_by_email(user.email)
      assert found.uuid == user.uuid
    end

    test "returns nil for nonexistent email" do
      assert is_nil(Auth.get_user_by_email("nonexistent@example.com"))
    end
  end

  describe "get_user/1" do
    test "returns user by uuid" do
      {:ok, user} = Auth.register_user(valid_attrs())

      found = Auth.get_user(user.uuid)
      assert found.uuid == user.uuid
      assert found.email == user.email
    end

    test "returns nil for nonexistent uuid" do
      assert is_nil(Auth.get_user(UUIDv7.generate()))
    end
  end

  describe "get_user!/1" do
    test "returns user by uuid" do
      {:ok, user} = Auth.register_user(valid_attrs())

      found = Auth.get_user!(user.uuid)
      assert found.uuid == user.uuid
    end

    test "raises for nonexistent uuid" do
      assert_raise Ecto.NoResultsError, fn ->
        Auth.get_user!(UUIDv7.generate())
      end
    end
  end

  describe "get_first_user/0" do
    test "returns earliest registered user" do
      {:ok, first} = Auth.register_user(valid_attrs())
      {:ok, _second} = Auth.register_user(valid_attrs())

      assert Auth.get_first_user().uuid == first.uuid
    end
  end

  describe "get_user_by_username/1" do
    test "returns user for existing username" do
      {:ok, user} = Auth.register_user(valid_attrs(%{username: "testuser_lookup"}))

      found = Auth.get_user_by_username("testuser_lookup")
      assert found.uuid == user.uuid
    end

    test "returns nil for nonexistent username" do
      assert is_nil(Auth.get_user_by_username("nonexistent_user_xyz"))
    end

    test "username lookup is exact match" do
      {:ok, _user} = Auth.register_user(valid_attrs(%{username: "exactmatch"}))

      # Different case should not match (username stored as-is)
      assert is_nil(Auth.get_user_by_username("EXACTMATCH"))
    end
  end

  describe "get_user_by_email_or_username/1" do
    test "detects email by @ sign and looks up by email" do
      {:ok, user} = Auth.register_user(valid_attrs(%{username: "emailoruser"}))

      found = Auth.get_user_by_email_or_username(user.email)
      assert found.uuid == user.uuid
    end

    test "treats input without @ as username" do
      {:ok, user} = Auth.register_user(valid_attrs(%{username: "myusername"}))

      found = Auth.get_user_by_email_or_username("myusername")
      assert found.uuid == user.uuid
    end

    test "returns nil for nonexistent email" do
      assert is_nil(Auth.get_user_by_email_or_username("nobody@nowhere.com"))
    end

    test "returns nil for nonexistent username" do
      assert is_nil(Auth.get_user_by_email_or_username("ghost_user"))
    end
  end

  describe "get_first_admin/0" do
    test "returns the first Owner user" do
      {:ok, owner} = Auth.register_user(valid_attrs())
      {:ok, _user} = Auth.register_user(valid_attrs())

      admin = Auth.get_first_admin()
      assert admin.uuid == owner.uuid
    end
  end

  describe "get_first_admin_uuid/0" do
    test "returns uuid of the first Owner user" do
      {:ok, owner} = Auth.register_user(valid_attrs())

      assert Auth.get_first_admin_uuid() == owner.uuid
    end
  end

  describe "get_first_user_uuid/0" do
    test "returns uuid of the first registered user" do
      {:ok, first} = Auth.register_user(valid_attrs())
      {:ok, _second} = Auth.register_user(valid_attrs())

      assert Auth.get_first_user_uuid() == first.uuid
    end
  end

  describe "create_guest_user/1" do
    test "creates new guest user with no existing email" do
      email = unique_email()

      assert {:ok, guest} =
               Auth.create_guest_user(%{email: email, first_name: "Guest", last_name: "User"})

      assert guest.email == email
      assert guest.first_name == "Guest"
      assert guest.last_name == "User"
      assert Roles.user_has_role?(guest, "User")
    end

    test "returns error for confirmed email" do
      {:ok, user} = Auth.register_user(valid_attrs())
      {:ok, _confirmed} = Auth.admin_confirm_user(user)

      assert {:error, :email_exists_confirmed} =
               Auth.create_guest_user(%{email: user.email, first_name: "Test"})
    end

    test "returns error with existing user for unconfirmed email" do
      # First user gets Owner (auto-confirmed), so create a second user
      {:ok, _owner} = Auth.register_user(valid_attrs())
      {:ok, user} = Auth.register_user(valid_attrs())
      # Second user is unconfirmed
      assert is_nil(user.confirmed_at)

      assert {:error, :email_exists_unconfirmed, existing} =
               Auth.create_guest_user(%{email: user.email, first_name: "Updated"})

      assert existing.uuid == user.uuid
    end
  end
end
