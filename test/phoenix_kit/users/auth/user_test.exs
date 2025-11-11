defmodule PhoenixKit.Users.Auth.UserTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.User

  @moduledoc """
  Unit tests for PhoenixKit User schema.

  These tests verify user validations, changesets, and business logic
  without requiring database access.
  """

  describe "registration_changeset/2" do
    @valid_attrs %{
      email: "user@example.com",
      password: "valid_password_123"
    }

    test "validates required email field" do
      changeset = User.registration_changeset(%User{}, %{password: "password123"})
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates required password field" do
      changeset = User.registration_changeset(%User{}, %{email: "user@example.com"})
      assert %{password: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email format" do
      invalid_emails = [
        "notanemail",
        "missing@domain",
        "@nodomain.com",
        "spaces in@email.com",
        "double@@domain.com"
      ]

      for invalid_email <- invalid_emails do
        changeset = User.registration_changeset(%User{}, %{
          email: invalid_email,
          password: "valid_password"
        })

        assert %{email: _errors} = errors_on(changeset)
      end
    end

    test "validates password length minimum" do
      changeset = User.registration_changeset(%User{}, %{
        email: "user@example.com",
        password: "short"
      })

      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)
    end

    test "validates password length maximum" do
      long_password = String.duplicate("a", 73)

      changeset = User.registration_changeset(%User{}, %{
        email: "user@example.com",
        password: long_password
      })

      assert %{password: ["should be at most 72 character(s)"]} = errors_on(changeset)
    end

    test "accepts valid attributes" do
      changeset = User.registration_changeset(%User{}, @valid_attrs)
      assert changeset.valid?
    end

    test "hashes password when hash_password option is true" do
      changeset = User.registration_changeset(%User{}, @valid_attrs, hash_password: true)

      assert changeset.valid?
      assert changeset.changes.hashed_password
      assert is_binary(changeset.changes.hashed_password)
      refute Map.has_key?(changeset.changes, :password)
    end

    test "does not hash password when hash_password option is false" do
      changeset = User.registration_changeset(%User{}, @valid_attrs, hash_password: false)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :hashed_password)
      assert changeset.changes.password == "valid_password_123"
    end

    test "validates email length maximum (160 characters)" do
      long_email = String.duplicate("a", 150) <> "@example.com"

      changeset = User.registration_changeset(%User{}, %{
        email: long_email,
        password: "valid_password"
      })

      assert %{email: ["should be at most 160 character(s)"]} = errors_on(changeset)
    end

    test "accepts optional first_name and last_name" do
      attrs = Map.merge(@valid_attrs, %{
        first_name: "John",
        last_name: "Doe"
      })

      changeset = User.registration_changeset(%User{}, attrs)
      assert changeset.valid?
      assert changeset.changes.first_name == "John"
      assert changeset.changes.last_name == "Doe"
    end

    test "validates first_name and last_name length" do
      long_name = String.duplicate("a", 101)

      changeset = User.registration_changeset(%User{}, Map.merge(@valid_attrs, %{
        first_name: long_name,
        last_name: long_name
      }))

      errors = errors_on(changeset)
      assert %{first_name: ["should be at most 100 character(s)"]} = errors
      assert %{last_name: ["should be at most 100 character(s)"]} = errors
    end
  end

  describe "email_changeset/2" do
    test "requires email to change" do
      user = %User{email: "old@example.com"}
      changeset = User.email_changeset(user, %{})

      assert %{email: ["did not change"]} = errors_on(changeset)
    end

    test "validates new email format" do
      user = %User{email: "old@example.com"}
      changeset = User.email_changeset(user, %{email: "invalid-email"})

      assert %{email: _errors} = errors_on(changeset)
    end
  end

  describe "password_changeset/2" do
    test "validates password confirmation" do
      changeset = User.password_changeset(%User{}, %{
        password: "new_password_123",
        password_confirmation: "different_password"
      })

      assert %{password_confirmation: ["does not match password"]} = errors_on(changeset)
    end

    test "accepts matching password confirmation" do
      changeset = User.password_changeset(%User{}, %{
        password: "new_password_123",
        password_confirmation: "new_password_123"
      })

      assert changeset.valid?
    end
  end

  describe "full_name/1" do
    test "returns full name when both first and last name present" do
      user = %User{first_name: "John", last_name: "Doe"}
      assert User.full_name(user) == "John Doe"
    end

    test "returns first name only when last name is nil" do
      user = %User{first_name: "John", last_name: nil}
      assert User.full_name(user) == "John"
    end

    test "returns last name only when first name is nil" do
      user = %User{first_name: nil, last_name: "Doe"}
      assert User.full_name(user) == "Doe"
    end

    test "returns nil when both names are nil" do
      user = %User{first_name: nil, last_name: nil}
      assert User.full_name(user) == nil
    end

    test "trims whitespace from names" do
      user = %User{first_name: "  John  ", last_name: "  Doe  "}
      assert User.full_name(user) == "John  Doe"
    end
  end

  describe "generate_username_from_email/1" do
    test "generates username from email" do
      assert User.generate_username_from_email("john.doe@example.com") == "john_doe"
    end

    test "handles email with dots" do
      assert User.generate_username_from_email("user.name@example.com") == "user_name"
    end

    test "converts to lowercase" do
      assert User.generate_username_from_email("John.Doe@example.com") == "john_doe"
    end

    test "handles simple email" do
      assert User.generate_username_from_email("user@example.com") == "user"
    end

    test "returns nil for invalid input" do
      assert User.generate_username_from_email(nil) == nil
      assert User.generate_username_from_email("") == nil
    end

    test "ensures minimum length of 3 characters" do
      username = User.generate_username_from_email("ab@example.com")
      assert String.length(username) >= 3
    end
  end

  describe "valid_password?/2" do
    test "returns false for nil user" do
      refute User.valid_password?(nil, "password")
    end

    test "returns false for empty password" do
      user = %User{hashed_password: Bcrypt.hash_pwd_salt("password")}
      refute User.valid_password?(user, "")
    end
  end

  # Helper function to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
