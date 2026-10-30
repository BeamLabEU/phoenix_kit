defmodule PhoenixKit.Users.ManagedOrganizationPolicyTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Notifications.Channels.Email
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles

  test "account mail and notifications deliver to contact email and skip a missing address" do
    org = Fixtures.organization()
    assert {:ok, _} = UserNotifier.deliver_welcome(org)
    assert_received {:email, email}
    assert email.to == [{"", org.contact_email}]
    refute email.text_body =~ org.email

    envelope = %{recipient_uuid: org.uuid, title: "Notice", text: "An update", url: nil}
    assert :ok = Email.deliver(envelope, %{})
    assert_received {:email, email}
    assert email.to == [{"", org.contact_email}]

    org = org |> Ecto.Changeset.change(contact_email: nil) |> Repo.update!()
    assert {:ok, _} = UserNotifier.deliver_welcome(org)
    assert {:error, {:permanent, :no_recipient_email}} = Email.deliver(envelope, %{})
    refute_received {:email, _}
  end

  test "reserved placeholder domains cannot be registered or used as a contact address" do
    for domain <- ["organization.invalid", "service.invalid", "Sub.INVALID"] do
      changeset =
        User.registration_changeset(%User{}, %{email: "test@#{domain}"},
          validate_email: false,
          hash_password: false
        )

      assert "must use a deliverable email domain" in errors_on(changeset).email

      assert %{contact_email: [_]} =
               errors_on(
                 User.contact_email_changeset(%User{}, %{contact_email: "test@#{domain}"})
               )
    end

    assert User.contact_email_changeset(%User{}, %{contact_email: "shared@example.com"}).valid?
    assert User.delivery_email(%User{managed_by_members: true}) == nil
    assert User.delivery_email(Fixtures.person()) =~ "@example.com"
  end

  test "grant eligibility and account-type changes enforce person-only managers" do
    org = Fixtures.organization()
    person = Fixtures.person()
    Fixtures.manager(org, person)

    assert {:error, :organization_manager_must_be_person} =
             Auth.change_account_type(person, %{
               account_type: "organization",
               organization_name: "Other"
             })

    for invalid <- [
          Fixtures.organization(),
          Fixtures.person(%{api_only: true}),
          Fixtures.person(%{is_active: false})
        ] do
      changeset =
        OrganizationManager.changeset(%OrganizationManager{}, %{
          organization_uuid: org.uuid,
          user_uuid: invalid.uuid
        })

      assert %{user_uuid: [_]} = errors_on(changeset)
    end
  end

  test "role assignment refuses staff roles, wildcard and API even with a stale user struct" do
    org = Fixtures.organization()
    stale = %{org | managed_by_members: false}
    assert {:error, :managed_organization_role_not_allowed} = Roles.assign_role(stale, "Admin")

    for key <- ["*", "api"] do
      {:ok, role} =
        Roles.create_role(%{name: "Blocked #{key} #{System.unique_integer([:positive])}"})

      {:ok, _} = Permissions.grant_permission(role.uuid, key)

      assert {:error, :managed_organization_role_not_allowed} =
               Roles.assign_role(stale, role.name)
    end
  end

  test "scope ceiling survives direct staff assignments and later permission changes" do
    org = Fixtures.organization()
    {:ok, role} = Roles.create_role(%{name: "Company #{System.unique_integer([:positive])}"})
    {:ok, _} = Roles.assign_role(org, role.name)
    for key <- ["*", "api", "users"], do: Permissions.grant_permission(role.uuid, key)

    for name <- ["Owner", "Admin"] do
      role = Roles.get_role_by_name(name)

      %RoleAssignment{}
      |> RoleAssignment.changeset(%{user_uuid: org.uuid, role_uuid: role.uuid})
      |> Repo.insert!()
    end

    for opts <- [[], [narrow: false]] do
      scope = Scope.for_user(org, opts)
      refute Scope.owner?(scope)
      refute Scope.has_role?(scope, "Admin")
      refute Scope.superadmin?(scope)
      refute Scope.can?(scope, "api")
      assert Scope.can?(scope, "users")

      # Role authority reads the real role rows, not the ceilinged scope.
      refute Roles.can_manage_role?(scope, "Admin")
    end

    refute Roles.can_manage_role?(org, "Admin")
  end

  test "the ceiling also covers sub-keys of api" do
    assert Scope.managed_ceiling_key?("api.keys")
    assert Scope.managed_ceiling_key?("api_personal_keys")
    refute Scope.managed_ceiling_key?("apiary")
    refute Scope.managed_ceiling_key?("users")
  end

  test "member and manager invitations coexist and duplicate pending kinds are changeset errors" do
    org = Fixtures.organization()

    attrs = %{
      organization_uuid: org.uuid,
      email: "invited@example.com",
      token: :crypto.strong_rand_bytes(32),
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    }

    member =
      %OrganizationInvitation{}
      |> OrganizationInvitation.create_changeset(attrs)
      |> Repo.insert!()

    assert member.kind == :member
    manager_attrs = Map.merge(attrs, %{kind: :manager, token: :crypto.strong_rand_bytes(32)})

    assert {:ok, %{kind: :manager}} =
             %OrganizationInvitation{}
             |> OrganizationInvitation.create_changeset(manager_attrs)
             |> Repo.insert()

    assert {:error, changeset} =
             %OrganizationInvitation{}
             |> OrganizationInvitation.create_changeset(%{
               manager_attrs
               | token: :crypto.strong_rand_bytes(32)
             })
             |> Repo.insert()

    assert changeset.errors[:organization_uuid]
  end
end
