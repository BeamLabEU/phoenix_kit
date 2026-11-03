defmodule PhoenixKit.Users.HostManagedOrganizationsTest do
  # Settings are global state, so this file does not run async.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Notifications
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions.Revocation

  @password "BrandNewPassword123!"

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    on_exit(fn -> Settings.update_setting("enable_organization_accounts", "false") end)
    %{created_by: F.person()}
  end

  describe "host_create/3" do
    test "makes a managed organization with a service address, grant and a logged origin", %{
      created_by: created_by
    } do
      manager = F.person()

      assert {:ok, org} =
               ManagedOrganizations.host_create(
                 %{
                   organization_name: "Host Co",
                   contact_email: " SHARED@example.com ",
                   email: "injected@example.com",
                   password: @password,
                   account_type: "person",
                   is_active: false
                 },
                 manager.uuid,
                 created_by
               )

      assert org.account_type == "organization"
      assert org.managed_by_members and org.is_active
      assert org.email == "org-#{org.uuid}@organization.invalid"
      assert org.contact_email == "shared@example.com"
      assert org.created_by_uuid == created_by.uuid
      assert Referrals.marked_satisfied?(org)
      assert Roles.get_user_roles(org) == ["User"]
      refute User.valid_password?(org, @password)

      grant =
        Repo.get_by!(OrganizationManager, organization_uuid: org.uuid, user_uuid: manager.uuid)

      assert grant.granted_by_uuid == created_by.uuid

      entry =
        Repo.one!(
          from(e in Entry,
            where: e.action == "organization.manager_added" and e.resource_uuid == ^org.uuid
          )
        )

      assert entry.actor_uuid == created_by.uuid
      assert entry.target_uuid == manager.uuid
      assert entry.metadata["via"] == "host"

      {notifications, _} = Notifications.list_for_user(manager.uuid)

      assert Enum.any?(
               notifications,
               &(Notifications.Render.render(&1, "en").text =~ "can now act for Host Co")
             )
    end

    test "a manager the core refuses, or a bad organization, rolls back every row", %{
      created_by: created_by
    } do
      manager = F.person()
      baseline = Repo.aggregate(User, :count)

      assert {:error, %Ecto.Changeset{}} =
               ManagedOrganizations.host_create(
                 %{organization_name: ""},
                 manager.uuid,
                 created_by
               )

      assert {:error, %Ecto.Changeset{}} =
               ManagedOrganizations.host_create(
                 %{organization_name: "Co", contact_email: "x@organization.invalid"},
                 manager.uuid,
                 created_by
               )

      for invalid <- [
            F.person(%{is_active: false}),
            F.person(%{api_only: true}),
            F.organization()
          ] do
        count = Repo.aggregate(User, :count)

        assert {:error, :manager_must_be_active_person} =
                 ManagedOrganizations.host_create(
                   %{organization_name: "Co"},
                   invalid.uuid,
                   created_by
                 )

        assert Repo.aggregate(User, :count) == count
      end

      assert {:error, :invalid_reference} =
               ManagedOrganizations.host_create(%{organization_name: "Co"}, nil, created_by)

      assert Repo.aggregate(User, :count) == baseline + 3
    end
  end

  describe "created_by" do
    test "an unfit created_by is :forbidden on every host function and nothing is written" do
      org = F.organization()
      manager = F.person()
      other = F.person()
      F.manager(org, manager)
      independent = independent()

      unfit = [
        F.person(%{is_active: false}),
        F.person(%{api_only: true}),
        F.organization(),
        independent(),
        %User{uuid: UUIDv7.generate()},
        %User{uuid: nil},
        %User{uuid: "not-a-uuid"},
        nil,
        :nobody,
        %{uuid: UUIDv7.generate()}
      ]

      users = Repo.aggregate(User, :count)
      grants = Repo.aggregate(OrganizationManager, :count)

      for created_by <- unfit do
        assert {:error, :forbidden} =
                 ManagedOrganizations.host_create(
                   %{organization_name: "No"},
                   manager.uuid,
                   created_by
                 )

        assert {:error, :forbidden} =
                 ManagedOrganizations.host_convert_to_managed(
                   independent.uuid,
                   manager.uuid,
                   created_by
                 )

        assert {:error, :forbidden} =
                 ManagedOrganizations.host_convert_to_managed(
                   independent.uuid,
                   fn -> {:ok, manager.uuid} end,
                   created_by
                 )

        assert {:error, :forbidden} =
                 ManagedOrganizations.host_convert_to_independent(
                   org.uuid,
                   %{email: "n@example.com", password: @password},
                   created_by
                 )

        assert {:error, :forbidden} =
                 OrganizationManagers.host_add(org.uuid, other.uuid, created_by)

        assert {:error, :forbidden} =
                 OrganizationManagers.host_remove(org.uuid, manager.uuid, created_by)

        assert {:error, :forbidden} =
                 OrganizationManagers.host_update_contact(
                   org.uuid,
                   %{contact_email: "n@example.com"},
                   created_by
                 )
      end

      assert Repo.aggregate(User, :count) == users
      assert Repo.aggregate(OrganizationManager, :count) == grants
      assert Repo.get!(User, org.uuid).contact_email == "shared@example.com"
      refute Repo.get!(User, independent.uuid).managed_by_members
    end

    test "a created_by deactivated after the struct was loaded is refused", %{
      created_by: created_by
    } do
      created_by |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert {:error, :forbidden} =
               ManagedOrganizations.host_create(
                 %{organization_name: "No"},
                 F.person().uuid,
                 created_by
               )
    end
  end

  describe "enable_organization_accounts" do
    test "off: create, convert to managed and add are refused, the way back is not", %{
      created_by: created_by
    } do
      org = F.organization()
      manager = F.person()
      F.manager(org, F.person())
      F.manager(org, manager)
      independent = independent()
      Settings.update_setting("enable_organization_accounts", "false")

      assert {:error, :organization_accounts_disabled} =
               ManagedOrganizations.host_create(
                 %{organization_name: "No"},
                 manager.uuid,
                 created_by
               )

      assert {:error, :organization_accounts_disabled} =
               ManagedOrganizations.host_convert_to_managed(
                 independent.uuid,
                 manager.uuid,
                 created_by
               )

      assert {:error, :organization_accounts_disabled} =
               ManagedOrganizations.host_convert_to_managed(
                 independent.uuid,
                 fn -> flunk("the function must not run") end,
                 created_by
               )

      assert {:error, :organization_accounts_disabled} =
               OrganizationManagers.host_add(org.uuid, F.person().uuid, created_by)

      refute Repo.get!(User, independent.uuid).managed_by_members

      assert {:ok, :ok} = OrganizationManagers.host_remove(org.uuid, manager.uuid, created_by)

      assert {:ok, _} =
               OrganizationManagers.host_update_contact(
                 org.uuid,
                 %{contact_email: "still@example.com"},
                 created_by
               )

      assert {:ok, %User{managed_by_members: false}} =
               ManagedOrganizations.host_convert_to_independent(
                 org.uuid,
                 %{email: "out-#{UUIDv7.generate()}@example.com", password: @password},
                 created_by
               )
    end
  end

  describe "host_convert_to_managed/3" do
    test "with a uuid it behaves like the administrator conversion", %{created_by: created_by} do
      org = independent(%{contact_email: nil})
      manager = F.person()
      {token, _} = F.session(org)

      assert {:ok, managed} =
               ManagedOrganizations.host_convert_to_managed(org.uuid, manager.uuid, created_by)

      assert managed.managed_by_members
      assert managed.email == "org-#{org.uuid}@organization.invalid"
      assert managed.contact_email == org.email
      assert managed.google_email == nil
      assert Referrals.marked_satisfied?(managed)
      refute Auth.get_user_by_session_token(token)
      refute Repo.exists?(from(t in UserToken, where: t.user_uuid == ^org.uuid))

      assert Repo.get_by!(OrganizationManager,
               organization_uuid: org.uuid,
               user_uuid: manager.uuid
             )

      assert_logged("organization.manager_added", org, created_by)
    end

    test "a managed, inactive or staff organization is refused", %{created_by: created_by} do
      manager = F.person()

      assert {:error, :organization_policy_mismatch} =
               ManagedOrganizations.host_convert_to_managed(
                 F.organization().uuid,
                 manager.uuid,
                 created_by
               )

      inactive = independent(%{is_active: false})

      assert {:error, :organization_policy_mismatch} =
               ManagedOrganizations.host_convert_to_managed(
                 inactive.uuid,
                 manager.uuid,
                 created_by
               )

      staff = independent()
      {:ok, _} = Roles.assign_role(staff, "Admin")

      assert {:error, :managed_organization_role_not_allowed} =
               ManagedOrganizations.host_convert_to_managed(staff.uuid, manager.uuid, created_by)

      assert {:error, :invalid_reference} =
               ManagedOrganizations.host_convert_to_managed(staff.uuid, nil, created_by)
    end

    test "the function creates the person who owns the organization's old email", %{
      created_by: created_by
    } do
      org = independent(%{email: "same-#{System.unique_integer([:positive])}@example.com"})
      parent = self()

      fun = fn ->
        # The organization has already given the address up.
        send(parent, {:org_email, Repo.get!(User, org.uuid).email})
        new_person(org.email)
      end

      assert {:ok, managed} =
               ManagedOrganizations.host_convert_to_managed(org.uuid, fun, created_by)

      assert_received {:org_email, service_email}
      assert service_email == "org-#{org.uuid}@organization.invalid"
      assert managed.contact_email == org.email
      person = Repo.get_by!(User, email: org.email)
      assert person.account_type == "person"

      assert Repo.get_by!(OrganizationManager,
               organization_uuid: org.uuid,
               user_uuid: person.uuid
             )

      assert_logged("organization.manager_added", org, created_by)
    end

    test "a new person is accepted whatever the session time zone is", %{
      created_by: created_by
    } do
      for zone <- ["America/New_York", "Asia/Tokyo"] do
        org = independent()

        assert {:ok, %User{managed_by_members: true}} =
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL TIME ZONE '#{zone}'")

                   case ManagedOrganizations.host_convert_to_managed(
                          org.uuid,
                          fn ->
                            new_person("tz-#{System.unique_integer([:positive])}@example.com")
                          end,
                          created_by
                        ) do
                     {:ok, managed} -> managed
                     {:error, reason} -> Repo.rollback(reason)
                   end
                 end)
      end
    end

    test "a person the host inserted earlier in the same transaction is not new", %{
      created_by: created_by
    } do
      org = independent()

      assert {:error, :invalid_first_manager} =
               Repo.transaction(fn ->
                 {:ok, person_uuid} =
                   new_person("earlier-#{System.unique_integer([:positive])}@example.com")

                 case ManagedOrganizations.host_convert_to_managed(
                        org.uuid,
                        fn -> {:ok, person_uuid} end,
                        created_by
                      ) do
                   {:ok, managed} -> managed
                   {:error, reason} -> Repo.rollback(reason)
                 end
               end)

      assert_untouched(org)
    end

    test "a function that opens a savepoint of its own fails the check", %{
      created_by: created_by
    } do
      org = independent()

      fun = fn ->
        Repo.query!("SAVEPOINT first_manager")
        result = new_person(org.email)
        Repo.query!("RELEASE SAVEPOINT first_manager")
        result
      end

      assert {:error, :invalid_first_manager} =
               ManagedOrganizations.host_convert_to_managed(org.uuid, fun, created_by)

      assert_untouched(org)
    end

    test "the function takes the new person's lock after the organization's", %{
      created_by: created_by
    } do
      org = independent()
      person_uuid = UUIDv7.generate()

      fun = fn ->
        refute advisory_lock_held?(person_uuid)
        new_person(org.email, person_uuid)
      end

      assert {:ok, _} = ManagedOrganizations.host_convert_to_managed(org.uuid, fun, created_by)
      # taken after the function, and kept until the outermost transaction ends
      assert advisory_lock_held?(person_uuid)
    end

    test "an existing person returned by the function is :invalid_first_manager", %{
      created_by: created_by
    } do
      org = independent()
      existing = F.person()

      assert {:error, :invalid_first_manager} =
               ManagedOrganizations.host_convert_to_managed(
                 org.uuid,
                 fn -> {:ok, existing.uuid} end,
                 created_by
               )

      assert_untouched(org)
    end

    test "a pre-existing person the function merely changes is still not new", %{
      created_by: created_by
    } do
      org = independent()
      existing = F.person()
      old = DateTime.add(DateTime.utc_now(), -3600) |> DateTime.truncate(:second)
      existing |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

      fun = fn ->
        existing |> Ecto.Changeset.change(first_name: "Touched") |> Repo.update!()
        {:ok, existing.uuid}
      end

      assert {:error, :invalid_first_manager} =
               ManagedOrganizations.host_convert_to_managed(org.uuid, fun, created_by)

      assert_untouched(org)
      refute Repo.get!(User, existing.uuid).first_name == "Touched"
    end

    test "other results of the function are :invalid_first_manager", %{created_by: created_by} do
      org = independent()

      for result <- [:ok, nil, {:ok, nil}, {:ok, "nope"}, {:ok, UUIDv7.generate()}] do
        assert {:error, :invalid_first_manager} =
                 ManagedOrganizations.host_convert_to_managed(
                   org.uuid,
                   fn -> result end,
                   created_by
                 )
      end

      assert_untouched(org)
    end

    test "the function's error comes back as it is and undoes the conversion", %{
      created_by: created_by
    } do
      org = independent()
      {token, _} = F.session(org)

      changeset =
        %User{}
        |> Ecto.Changeset.cast(%{email: "bad"}, [:email])
        |> Ecto.Changeset.add_error(:email, "is invalid")

      assert {:error, %Ecto.Changeset{} = returned} =
               ManagedOrganizations.host_convert_to_managed(
                 org.uuid,
                 fn -> {:error, changeset} end,
                 created_by
               )

      assert returned.errors == changeset.errors

      assert {:error, :my_reason} =
               ManagedOrganizations.host_convert_to_managed(
                 org.uuid,
                 fn -> {:error, :my_reason} end,
                 created_by
               )

      assert_untouched(org)
      assert Auth.get_user_by_session_token(token)
    end

    test "the person the function creates is validated like any first manager", %{
      created_by: created_by
    } do
      org = independent()

      assert {:error, :manager_must_be_active_person} =
               ManagedOrganizations.host_convert_to_managed(
                 org.uuid,
                 fn -> new_person(org.email, UUIDv7.generate(), %{is_active: false}) end,
                 created_by
               )

      assert_untouched(org)
    end
  end

  describe "host_convert_to_independent/3" do
    test "sets the new email, drops managers and cancels manager invitations", %{
      created_by: created_by
    } do
      s = F.acting_session()
      pending = invitation(s.organization, :manager, :pending)
      accepted = invitation(s.organization, :manager, :accepted)
      email = "independent-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, org} =
               ManagedOrganizations.host_convert_to_independent(
                 s.organization.uuid,
                 %{email: email, password: @password, password_confirmation: @password},
                 created_by
               )

      refute org.managed_by_members
      assert org.email == email
      assert org.confirmed_at == nil
      assert User.valid_password?(org, @password)
      refute Repo.get(OrganizationManager, s.manager.uuid)
      refute Auth.get_user_by_session_token(s.token)
      assert Auth.get_user_by_session_token(s.root_token)
      assert Repo.get!(OrganizationInvitation, pending.uuid).status == :cancelled
      assert Repo.get!(OrganizationInvitation, accepted.uuid).status == :accepted
      assert_logged("organization.manager_removed", s.organization, created_by)
    end

    test "bad credentials or an organization that is not managed change nothing", %{
      created_by: created_by
    } do
      s = F.acting_session()

      assert {:error, %Ecto.Changeset{}} =
               ManagedOrganizations.host_convert_to_independent(
                 s.organization.uuid,
                 %{email: s.person.email, password: "short"},
                 created_by
               )

      assert Repo.get(OrganizationManager, s.manager.uuid)
      assert Auth.get_user_by_session_token(s.token)

      assert {:error, :organization_policy_mismatch} =
               ManagedOrganizations.host_convert_to_independent(
                 independent().uuid,
                 %{email: "n@example.com", password: @password},
                 created_by
               )

      assert {:error, :organization_not_found} =
               ManagedOrganizations.host_convert_to_independent(
                 created_by.uuid,
                 %{email: "n@example.com", password: @password},
                 created_by
               )
    end
  end

  describe "OrganizationManagers.host_add/3, host_remove/3, host_update_contact/3" do
    test "add and remove are idempotent and log the host as the origin", %{created_by: created_by} do
      org = F.organization()
      manager = F.person()
      F.manager(org, F.person())

      assert {:ok, grant} = OrganizationManagers.host_add(org.uuid, manager.uuid, created_by)
      assert grant.granted_by_uuid == created_by.uuid
      assert {:ok, ^grant} = OrganizationManagers.host_add(org.uuid, manager.uuid, created_by)
      assert {:ok, :ok} = OrganizationManagers.host_remove(org.uuid, manager.uuid, created_by)
      assert {:ok, :ok} = OrganizationManagers.host_remove(org.uuid, manager.uuid, created_by)

      assert_logged("organization.manager_added", org, created_by, 1)
      assert_logged("organization.manager_removed", org, created_by, 1)
      {notifications, _} = Notifications.list_for_user(manager.uuid)
      assert length(notifications) == 2
    end

    test "created_by may be the manager itself: no notification, no self-deadlock", %{
      created_by: created_by
    } do
      org = F.organization()
      F.manager(org, F.person())

      assert {:ok, grant} = OrganizationManagers.host_add(org.uuid, created_by.uuid, created_by)
      assert grant.user_uuid == created_by.uuid and grant.granted_by_uuid == created_by.uuid
      assert {:ok, :ok} = OrganizationManagers.host_remove(org.uuid, created_by.uuid, created_by)

      converted = independent()

      assert {:ok, %User{managed_by_members: true}} =
               ManagedOrganizations.host_convert_to_managed(
                 converted.uuid,
                 created_by.uuid,
                 created_by
               )

      assert {:ok, %User{managed_by_members: true} = created} =
               ManagedOrganizations.host_create(
                 %{organization_name: "Self Co"},
                 created_by.uuid,
                 created_by
               )

      assert Repo.get_by!(OrganizationManager,
               organization_uuid: created.uuid,
               user_uuid: created_by.uuid
             )

      assert_logged("organization.manager_added", org, created_by, 1)
      assert_logged("organization.manager_removed", org, created_by, 1)
      assert {[], _} = Notifications.list_for_user(created_by.uuid)
    end

    test "add refuses an unfit person, an organization that is not managed and a missing one", %{
      created_by: created_by
    } do
      org = F.organization()

      assert {:error, :manager_must_be_active_person} =
               OrganizationManagers.host_add(
                 org.uuid,
                 F.person(%{api_only: true}).uuid,
                 created_by
               )

      assert {:error, :manager_must_be_active_person} =
               OrganizationManagers.host_add(
                 org.uuid,
                 F.person(%{is_active: false}).uuid,
                 created_by
               )

      assert {:error, :organization_not_active_managed} =
               OrganizationManagers.host_add(independent().uuid, F.person().uuid, created_by)

      assert {:error, :organization_not_found} =
               OrganizationManagers.host_add(UUIDv7.generate(), F.person().uuid, created_by)

      assert {:error, :invalid_reference} =
               OrganizationManagers.host_add(org.uuid, "nope", created_by)
    end

    test "the last active manager cannot be removed, even by a host", %{created_by: created_by} do
      org = F.organization()
      only = F.person()
      F.manager(org, only)

      assert {:error, :cannot_remove_last_active_manager} =
               OrganizationManagers.host_remove(org.uuid, only.uuid, created_by)

      assert Repo.get_by(OrganizationManager, organization_uuid: org.uuid, user_uuid: only.uuid)

      inactive = F.person()
      F.manager(org, inactive)
      inactive |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert {:error, :cannot_remove_last_active_manager} =
               OrganizationManagers.host_remove(org.uuid, only.uuid, created_by)

      F.manager(org, F.person())
      assert {:ok, :ok} = OrganizationManagers.host_remove(org.uuid, only.uuid, created_by)
    end

    test "remove refuses an organization that is not managed", %{created_by: created_by} do
      assert {:error, :organization_not_found} =
               OrganizationManagers.host_remove(
                 UUIDv7.generate(),
                 F.person().uuid,
                 created_by
               )

      assert {:error, :organization_not_managed} =
               OrganizationManagers.host_remove(independent().uuid, F.person().uuid, created_by)
    end

    test "update_contact changes only the contact email of a managed organization", %{
      created_by: created_by
    } do
      org = F.organization()

      assert {:ok, updated} =
               OrganizationManagers.host_update_contact(
                 org.uuid,
                 %{contact_email: " New@Example.com ", email: "injected@example.com"},
                 created_by
               )

      assert updated.contact_email == "new@example.com"
      assert updated.email == org.email

      assert {:error, %Ecto.Changeset{}} =
               OrganizationManagers.host_update_contact(
                 org.uuid,
                 %{contact_email: "x@organization.invalid"},
                 created_by
               )

      assert {:error, :organization_not_managed} =
               OrganizationManagers.host_update_contact(
                 independent().uuid,
                 %{contact_email: "n@example.com"},
                 created_by
               )

      assert Repo.get!(User, org.uuid).contact_email == "new@example.com"
    end
  end

  describe "inside an outer transaction" do
    test "a rolled-back outer transaction takes the whole creation with it", %{
      created_by: created_by
    } do
      manager = F.person()
      baseline = Repo.aggregate(User, :count)
      grants = Repo.aggregate(OrganizationManager, :count)

      assert {:error, :undone} =
               Revocation.transaction(fn ->
                 assert {:ok, _} =
                          ManagedOrganizations.host_create(
                            %{organization_name: "Undone"},
                            manager.uuid,
                            created_by
                          )

                 Repo.rollback(:undone)
               end)

      assert Repo.aggregate(User, :count) == baseline
      assert Repo.aggregate(OrganizationManager, :count) == grants
    end

    test "a core error rolls the host's own writes back", %{created_by: created_by} do
      org = F.organization()
      F.manager(org, created_by)
      F.manager(org, F.person())
      marker = "marker-#{System.unique_integer([:positive])}"

      assert {:error, :manager_must_be_active_person} =
               Repo.transaction(fn ->
                 created_by |> Ecto.Changeset.change(first_name: marker) |> Repo.update!()

                 OrganizationManagers.host_add(
                   org.uuid,
                   F.person(%{api_only: true}).uuid,
                   created_by
                 )
                 |> case do
                   {:error, reason} -> Repo.rollback(reason)
                   other -> other
                 end
               end)

      refute Repo.get!(User, created_by.uuid).first_name == marker
    end

    test "a failing conversion inside an outer transaction restores credentials", %{
      created_by: created_by
    } do
      org = independent()
      existing = F.person()
      {token, _} = F.session(org)

      assert {:error, :invalid_first_manager} =
               Repo.transaction(fn ->
                 case ManagedOrganizations.host_convert_to_managed(
                        org.uuid,
                        fn -> {:ok, existing.uuid} end,
                        created_by
                      ) do
                   {:error, reason} -> Repo.rollback(reason)
                   {:ok, _} -> :unexpected
                 end
               end)

      assert_untouched(org)
      assert Auth.get_user_by_session_token(token)
    end
  end

  defp independent(attrs \\ %{}) do
    F.person(
      Map.merge(
        %{
          account_type: "organization",
          organization_name: "Independent",
          google_email: "google@example.com"
        },
        attrs
      )
    )
  end

  defp new_person(email, uuid \\ UUIDv7.generate(), attrs \\ %{}) do
    person =
      %User{uuid: uuid}
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            email: email,
            hashed_password: Bcrypt.hash_pwd_salt("ValidPassword123!"),
            confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )
      |> Repo.insert!()

    {:ok, person.uuid}
  end

  defp invitation(org, kind, status) do
    %OrganizationInvitation{}
    |> Ecto.Changeset.change(%{
      organization_uuid: org.uuid,
      kind: kind,
      status: status,
      email: "invite-#{UUIDv7.generate()}@example.com",
      token: :crypto.strong_rand_bytes(32),
      expires_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(3600)
    })
    |> Repo.insert!()
  end

  defp assert_untouched(org) do
    current = Repo.get!(User, org.uuid)
    refute current.managed_by_members
    assert current.email == org.email
    assert current.hashed_password == org.hashed_password
    refute Repo.exists?(from(m in OrganizationManager, where: m.organization_uuid == ^org.uuid))
  end

  defp assert_logged(action, org, created_by, count \\ nil) do
    entries =
      Repo.all(from(e in Entry, where: e.action == ^action and e.resource_uuid == ^org.uuid))

    assert entries != []
    if count, do: assert(length(entries) == count)

    for entry <- entries do
      assert entry.actor_uuid == created_by.uuid
      assert entry.metadata["via"] == "host"
    end
  end

  defp advisory_lock_held?(person_uuid) do
    key = "phoenix_kit:organization_manager:#{person_uuid}"

    %{rows: [[held]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_locks
          WHERE locktype = 'advisory' AND pid = pg_backend_pid()
            AND classid::bigint = (hashtext($1)::bigint >> 32) & 4294967295
            AND objid::bigint = hashtext($1)::bigint & 4294967295
        )
        """,
        [key]
      )

    held
  end
end
