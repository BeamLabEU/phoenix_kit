defmodule PhoenixKit.Users.UserOrgChangesetTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end

  # --- account_type_changeset/2 ---

  describe "account_type_changeset/2" do
    test "valid for person type" do
      changeset = User.account_type_changeset(%User{}, %{account_type: "person"})
      assert changeset.valid?
    end

    test "valid for organization type with name" do
      changeset =
        User.account_type_changeset(%User{}, %{
          account_type: "organization",
          organization_name: "Acme"
        })

      assert changeset.valid?
    end

    test "invalid for unknown account_type" do
      changeset = User.account_type_changeset(%User{}, %{account_type: "company"})
      refute changeset.valid?
      assert errors_on(changeset, :account_type) != []
    end

    test "organization requires organization_name" do
      changeset = User.account_type_changeset(%User{}, %{account_type: "organization"})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :organization_name)
    end

    test "organization_name max length 255" do
      changeset =
        User.account_type_changeset(%User{}, %{
          account_type: "organization",
          organization_name: String.duplicate("a", 256)
        })

      assert errors_on(changeset, :organization_name) != []
    end

    test "organization clears organization_uuid" do
      user = %User{organization_uuid: UUIDv7.generate()}

      changeset =
        User.account_type_changeset(user, %{account_type: "organization", organization_name: "X"})

      assert get_change(changeset, :organization_uuid) == nil
    end

    test "person — self-reference error when uuid == organization_uuid" do
      uuid = UUIDv7.generate()
      user = %User{uuid: uuid}

      changeset =
        User.account_type_changeset(user, %{account_type: "person", organization_uuid: uuid})

      refute changeset.valid?
      assert "cannot reference self" in errors_on(changeset, :organization_uuid)
    end

    test "person — valid when organization_uuid is different" do
      user = %User{uuid: "aaa"}

      changeset =
        User.account_type_changeset(user, %{account_type: "person", organization_uuid: "bbb"})

      assert changeset.valid?
    end

    test "person — valid when organization_uuid is nil" do
      changeset = User.account_type_changeset(%User{}, %{account_type: "person"})
      assert changeset.valid?
    end
  end

  # --- full_name/1 ---

  describe "full_name/1" do
    test "organization with name returns organization_name" do
      user = %User{account_type: "organization", organization_name: "Acme Corp"}
      assert User.full_name(user) == "Acme Corp"
    end

    test "organization without name falls through to person logic" do
      user = %User{
        account_type: "organization",
        organization_name: nil,
        first_name: "John",
        last_name: nil
      }

      assert User.full_name(user) == "John"
    end

    test "organization with empty string name falls through" do
      user = %User{account_type: "organization", organization_name: "", first_name: "John"}
      assert User.full_name(user) == "John"
    end

    test "person with first and last name" do
      user = %User{account_type: "person", first_name: "John", last_name: "Doe"}
      assert User.full_name(user) == "John Doe"
    end

    test "person with only first name" do
      user = %User{account_type: "person", first_name: "John", last_name: nil}
      assert User.full_name(user) == "John"
    end

    test "person with only last name" do
      user = %User{account_type: "person", first_name: nil, last_name: "Doe"}
      assert User.full_name(user) == "Doe"
    end

    test "person with nil names returns nil" do
      user = %User{account_type: "person", first_name: nil, last_name: nil}
      assert is_nil(User.full_name(user))
    end
  end

  # --- registration_changeset/3 — organization fields ---

  describe "registration_changeset/3 — organization fields" do
    test "org registration requires organization_name" do
      changeset =
        User.registration_changeset(
          %User{},
          %{
            email: "org@x.com",
            password: "ValidPassword123!",
            account_type: "organization"
          },
          hash_password: false,
          validate_email: false
        )

      refute changeset.valid?
      assert errors_on(changeset, :organization_name) != []
    end

    test "org registration valid with organization_name" do
      changeset =
        User.registration_changeset(
          %User{},
          %{
            email: "org@x.com",
            password: "ValidPassword123!",
            account_type: "organization",
            organization_name: "Acme"
          },
          hash_password: false,
          validate_email: false
        )

      assert changeset.valid?
    end

    test "person registration unchanged (no org fields required)" do
      changeset =
        User.registration_changeset(
          %User{},
          %{
            email: "person@x.com",
            password: "ValidPassword123!",
            account_type: "person"
          },
          hash_password: false,
          validate_email: false
        )

      assert changeset.valid?
    end

    test "default account_type is person" do
      changeset =
        User.registration_changeset(
          %User{},
          %{
            email: "user@x.com",
            password: "ValidPassword123!"
          },
          hash_password: false,
          validate_email: false
        )

      assert get_field(changeset, :account_type) == "person"
    end
  end

  # --- profile_changeset/3 — organization_name ---

  describe "profile_changeset/3 — organization_name" do
    test "casts organization_name" do
      changeset = User.profile_changeset(%User{}, %{organization_name: "NewName"})
      assert get_change(changeset, :organization_name) == "NewName"
    end

    test "allows nil organization_name" do
      changeset = User.profile_changeset(%User{}, %{organization_name: nil})
      assert changeset.valid?
    end
  end
end
