defmodule PhoenixKit.Users.ManagedOrganizationLifecycleTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Notifications
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthProvider
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKitWeb.Endpoint

  @password "BrandNewPassword123!"

  setup do
    {actor, admin} = F.admin_actor()
    %{actor: actor, admin: admin}
  end

  test "dedicated creation has one explicit User role, admission and no login credentials", %{
    actor: actor,
    admin: admin
  } do
    manager = F.person()

    assert {:ok, org} =
             ManagedOrganizations.create(
               actor,
               %{
                 organization_name: "New Co",
                 contact_email: " SHARED@example.com ",
                 email: "injected@example.com",
                 password: @password,
                 account_type: "person",
                 is_active: false,
                 custom_fields: %{"injected" => true}
               },
               manager.uuid
             )

    assert org.account_type == "organization"
    assert org.managed_by_members and org.is_active
    assert org.email == "org-#{org.uuid}@organization.invalid"
    assert org.contact_email == "shared@example.com"
    assert org.created_by_uuid == admin.uuid
    assert org.confirmed_at
    assert is_binary(org.hashed_password)
    assert Referrals.marked_satisfied?(org)
    refute org.custom_fields["injected"]
    assert Roles.get_user_roles(org) == ["User"]
    refute User.valid_password?(org, @password)
    assert Repo.get_by!(OrganizationManager, organization_uuid: org.uuid, user_uuid: manager.uuid)
    assert Repo.get!(User, manager.uuid).organization_uuid == nil
    refute_received {:email, _}
  end

  test "invalid names, contacts or first managers roll back every inserted row", %{actor: actor} do
    manager = F.person()
    baseline = Repo.aggregate(User, :count)

    assert {:error, %Ecto.Changeset{}} =
             ManagedOrganizations.create(actor, %{organization_name: ""}, manager.uuid)

    assert {:error, %Ecto.Changeset{}} =
             ManagedOrganizations.create(
               actor,
               %{organization_name: "Co", contact_email: "x@organization.invalid"},
               manager.uuid
             )

    for invalid <- [F.person(%{is_active: false}), F.person(%{api_only: true}), F.organization()] do
      count = Repo.aggregate(User, :count)

      assert {:error, :manager_must_be_active_person} =
               ManagedOrganizations.create(actor, %{organization_name: "Co"}, invalid.uuid)

      assert Repo.aggregate(User, :count) == count
    end

    assert {:error, :invalid_reference} =
             ManagedOrganizations.create(actor, %{organization_name: "Co"}, nil)

    assert Repo.aggregate(User, :count) == baseline + 3
  end

  test "a borrowed admin, a bare User/Scope and a revoked admin session cannot create", %{
    actor: actor,
    admin: admin
  } do
    root = F.person()
    {root_token, _} = F.session(root)
    {admin_token, _} = F.session(admin)

    {:ok, borrowed} =
      Actor.from_session(%{
        "user_token" => admin_token,
        "pk_session_accounts" => [root_token, admin_token]
      })

    for invalid <- [borrowed, admin, Scope.for_user(admin), nil] do
      assert {:error, :forbidden} =
               ManagedOrganizations.create(invalid, %{organization_name: "No"}, root.uuid)
    end

    {row, _} = actor.current
    token = Repo.get!(UserToken, row).token
    Auth.delete_user_session_token(token)

    assert {:error, :forbidden} =
             ManagedOrganizations.create(actor, %{organization_name: "No"}, root.uuid)
  end

  test "conversion drains all credentials, preserves contact and leaves employment alone", %{
    actor: actor
  } do
    org = independent()
    manager = F.person()
    credentials = credentials(org)
    {token, _} = F.session(org)
    Endpoint.subscribe(Sessions.live_socket_id(token))

    assert {:ok, managed} = ManagedOrganizations.convert_to_managed(actor, org.uuid, manager.uuid)
    assert managed.contact_email == org.email
    assert managed.confirmed_at
    assert managed.google_email == nil
    assert Referrals.marked_satisfied?(managed)
    refute managed.hashed_password == org.hashed_password
    refute Auth.get_user_by_session_token(token)
    refute Repo.exists?(from(t in UserToken, where: t.user_uuid == ^org.uuid))
    refute Repo.get(OAuthProvider, credentials.provider.uuid)
    assert Repo.get!(Key, credentials.key.uuid).revoked_at
    assert_disconnect(token)
    assert Repo.get!(User, manager.uuid).organization_uuid == nil

    other = independent(%{contact_email: "kept@example.com"})
    assert {:ok, kept} = ManagedOrganizations.convert_to_managed(actor, other.uuid, manager.uuid)
    assert kept.contact_email == "kept@example.com"
  end

  test "conversion refuses staff and API/wildcard roles rather than silently stripping them", %{
    actor: actor
  } do
    manager = F.person()

    for role_name <- ["Owner", "Admin"] do
      org = independent()
      role = Roles.get_role_by_name(role_name)

      %RoleAssignment{}
      |> RoleAssignment.changeset(%{user_uuid: org.uuid, role_uuid: role.uuid})
      |> Repo.insert!()

      assert {:error, :managed_organization_role_not_allowed} =
               ManagedOrganizations.convert_to_managed(actor, org.uuid, manager.uuid)

      refute Repo.get!(User, org.uuid).managed_by_members
    end

    for key <- ["api", "*"] do
      org = independent()
      {:ok, role} = Roles.create_role(%{name: "Forbidden #{System.unique_integer([:positive])}"})
      {:ok, _} = Permissions.grant_permission(role.uuid, key)
      {:ok, _} = Roles.assign_role(org, role.name)

      assert {:error, :managed_organization_role_not_allowed} =
               ManagedOrganizations.convert_to_managed(actor, org.uuid, manager.uuid)
    end
  end

  test "stale credential/profile forms cannot overwrite policy after conversion", %{actor: actor} do
    stale = independent()

    assert {:ok, org} =
             ManagedOrganizations.convert_to_managed(actor, stale.uuid, F.person().uuid)

    assert {:error, %Ecto.Changeset{}} =
             Auth.update_user_password(stale, "ValidPassword123!", %{password: @password})

    assert {:error, %Ecto.Changeset{}} =
             Auth.admin_update_user_password(stale, %{password: @password})

    assert {:error, %Ecto.Changeset{}} = Auth.reset_user_password(stale, %{password: @password})

    assert {:error, %Ecto.Changeset{}} =
             Auth.update_user_profile(stale, %{
               email: "stolen@example.com",
               google_email: "stolen@example.com"
             })

    fresh = Repo.get!(User, org.uuid)
    assert fresh.email == org.email
    assert fresh.hashed_password == org.hashed_password
    assert fresh.google_email == nil
    assert {:ok, _} = Auth.update_user_profile(org, %{organization_name: "Renamed"})

    assert {:error, :managed_organization_requires_conversion} =
             Auth.change_account_type(stale, %{account_type: "person"})
  end

  test "stale OAuth links and API creator scopes cannot mint credentials after conversion", %{
    actor: actor
  } do
    stale = independent()
    manager = F.person()

    scope = %Scope{
      user: stale,
      authenticated?: true,
      cached_roles: ["Owner"],
      cached_permissions: MapSet.new(["api"])
    }

    data = %{provider: "google", provider_uid: UUIDv7.generate(), email: stale.email}
    assert {:ok, _} = ManagedOrganizations.convert_to_managed(actor, stale.uuid, manager.uuid)
    assert {:error, :managed_organization} = OAuth.link_oauth_provider(stale, data)
    assert {:error, :forbidden} = Keys.create_key(stale, scope, %{name: "No"})

    assert {:error, :owner_inactive} =
             Keys.create_personal_key(
               scope,
               %{name: "No", expires_at: DateTime.add(DateTime.utc_now(), 3600)},
               impersonated: false
             )

    assert {:ok, _} =
             ManagedOrganizations.convert_to_independent(actor, stale.uuid, %{
               email: "fresh-#{UUIDv7.generate()}@example.com",
               password: @password
             })

    assert {:error, :account_changed} = OAuth.link_oauth_provider(stale, data)
  end

  test "password mutations return current account fields while preserving session role provenance" do
    person = F.person()
    role = Roles.get_role_by_name("User")
    {token, _} = F.session(person, %{active_role_uuid: role.uuid})
    stale = Auth.get_user_by_session_token(token)

    person
    |> Ecto.Changeset.change(first_name: "Current", confirmed_at: nil, is_active: false)
    |> Repo.update!()

    assert {:ok, updated} = Auth.reset_user_password(stale, %{password: @password})
    assert updated.first_name == "Current"
    assert updated.confirmed_at == nil
    refute updated.is_active
    assert updated.active_role_uuid == role.uuid
  end

  test "rolling back conversion restores credentials and never disconnects", %{actor: actor} do
    org = independent()
    manager = F.person()
    {token, _} = F.session(org)
    Endpoint.subscribe(Sessions.live_socket_id(token))

    assert {:error, :undone} =
             Revocation.transaction(fn ->
               assert {:ok, _} =
                        ManagedOrganizations.convert_to_managed(actor, org.uuid, manager.uuid)

               Repo.rollback(:undone)
             end)

    assert Repo.get!(User, org.uuid).hashed_password == org.hashed_password
    refute Repo.get!(User, org.uuid).managed_by_members
    assert Auth.get_user_by_session_token(token)
    refute Repo.get_by(OrganizationManager, organization_uuid: org.uuid)
    topic = Sessions.live_socket_id(token)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 30
  end

  test "conversion back cannot reactivate a forbidden direct staff assignment", %{actor: actor} do
    org = F.organization()
    owner = Roles.get_role_by_name("Owner")

    %RoleAssignment{}
    |> RoleAssignment.changeset(%{user_uuid: org.uuid, role_uuid: owner.uuid})
    |> Repo.insert!()

    assert {:error, :managed_organization_role_not_allowed} =
             ManagedOrganizations.convert_to_independent(actor, org.uuid, %{
               email: "back-#{UUIDv7.generate()}@example.com",
               password: @password
             })

    assert Repo.get!(User, org.uuid).managed_by_members
  end

  test "conversion back requires fresh unique email and password before deleting anything", %{
    actor: actor
  } do
    s = F.acting_session()

    assert {:error, %Ecto.Changeset{}} =
             ManagedOrganizations.convert_to_independent(actor, s.organization.uuid, %{
               email: s.person.email,
               password: "short"
             })

    assert Repo.get(OrganizationManager, s.manager.uuid)
    assert Auth.get_user_by_session_token(s.token)

    assert {:error, %Ecto.Changeset{}} =
             ManagedOrganizations.convert_to_independent(actor, s.organization.uuid, %{})
  end

  test "conversion back kills acting sessions and grants, cancels only pending manager invitations",
       %{actor: actor} do
    s = F.acting_session()
    credentials = credentials(s.organization)
    pending_manager = invitation(s.organization, :manager)
    pending_member = invitation(s.organization, :member)
    accepted = invitation(s.organization, :manager, :accepted)
    Endpoint.subscribe(Sessions.live_socket_id(s.token))
    email = "independent-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, org} =
             ManagedOrganizations.convert_to_independent(actor, s.organization.uuid, %{
               email: email,
               password: @password,
               password_confirmation: @password
             })

    refute org.managed_by_members
    assert org.email == email
    assert org.confirmed_at == nil
    assert User.valid_password?(org, @password)
    refute User.valid_password?(org, "ValidPassword123!")
    refute Repo.get(OrganizationManager, s.manager.uuid)
    refute Auth.get_user_by_session_token(s.token)
    assert Auth.get_user_by_session_token(s.root_token)
    assert_disconnect(s.token)
    assert Repo.get!(OrganizationInvitation, pending_manager.uuid).status == :cancelled
    assert Repo.get!(OrganizationInvitation, pending_member.uuid).status == :pending
    assert Repo.get!(OrganizationInvitation, accepted.uuid).status == :accepted
    assert Repo.get!(Key, credentials.key.uuid).revoked_at
    refute Repo.get(OAuthProvider, credentials.provider.uuid)
    assert org.google_email == nil
  end

  test "grant add/remove are idempotent and log only actual changes", %{actor: actor} do
    org = F.organization()
    manager = F.person()
    F.manager(org, F.person())
    assert {:ok, grant} = OrganizationManagers.add(actor, org.uuid, manager.uuid)
    assert {:ok, ^grant} = OrganizationManagers.add(actor, org.uuid, manager.uuid)
    assert {:ok, :ok} = OrganizationManagers.remove(actor, org.uuid, manager.uuid)
    assert {:ok, :ok} = OrganizationManagers.remove(actor, org.uuid, manager.uuid)

    entries =
      Repo.all(from(e in Entry, where: e.resource_uuid == ^org.uuid, order_by: e.inserted_at))

    assert Enum.sort(Enum.map(entries, & &1.action)) == [
             "organization.manager_added",
             "organization.manager_removed"
           ]

    {notifications, _} = Notifications.list_for_user(manager.uuid)
    assert length(notifications) == 2

    assert Enum.any?(
             notifications,
             &(Notifications.Render.render(&1, "en").text =~ "can now act for Acme")
           )
  end

  test "acting managers may remove another manager but cannot add by person search", %{
    actor: admin_actor
  } do
    s = F.acting_session()
    actor = F.acting_actor(s)
    other = F.person()
    {:ok, _} = OrganizationManagers.add(admin_actor, s.organization.uuid, other.uuid)

    assert {:error, :forbidden} =
             OrganizationManagers.add(actor, s.organization.uuid, F.person().uuid)

    assert {:error, :forbidden} =
             ManagedOrganizations.convert_to_independent(actor, s.organization.uuid, %{
               email: "new@example.com",
               password: @password
             })

    assert {:error, :forbidden} =
             OrganizationManagers.remove(actor, F.organization().uuid, other.uuid)

    assert {:ok, :ok} = OrganizationManagers.remove(actor, s.organization.uuid, other.uuid)

    entry =
      Repo.one!(
        from(e in Entry,
          where:
            e.action == "organization.manager_removed" and e.resource_uuid == ^s.organization.uuid
        )
      )

    assert entry.actor_uuid == s.organization.uuid
    assert entry.metadata["acting_user_uuid"] == s.person.uuid
  end

  test "last active manager is protected in removal, status and deletion", %{
    actor: actor,
    admin: admin
  } do
    s = F.acting_session()

    assert {:error, :cannot_remove_last_active_manager} =
             OrganizationManagers.remove(actor, s.organization.uuid, s.person.uuid)

    assert {:error, :cannot_remove_last_active_manager} =
             OrganizationManagers.remove(F.acting_actor(s), s.organization.uuid, s.person.uuid,
               allow_managerless: true
             )

    assert {:error, :cannot_remove_last_active_manager} =
             Auth.update_user_status(s.person, %{is_active: false})

    assert {:error, :cannot_remove_last_active_manager} =
             Auth.update_user_status(s.person, %{"is_active" => "false"})

    assert {:error, :cannot_remove_last_active_manager} =
             Auth.delete_user(s.person, %{current_user: admin})

    assert Repo.get!(User, s.person.uuid).is_active
    assert Auth.get_user_by_session_token(s.token)
  end

  test "an explicit live own-admin session can leave an organization managerless", %{
    actor: actor,
    admin: admin
  } do
    s = F.acting_session()

    assert {:error, :forbidden} =
             Auth.update_user_status(s.person, %{is_active: false}, allow_managerless: true)

    assert {:ok, _} =
             Auth.update_user_status(s.person, %{is_active: false},
               actor: admin,
               manager_actor: actor,
               allow_managerless: true
             )

    refute Auth.get_user_by_session_token(s.token)
    assert {:ok, :ok} = OrganizationManagers.remove(actor, s.organization.uuid, s.person.uuid)
  end

  test "other active managers permit person deletion; inactive managers do not", %{admin: admin} do
    s = F.acting_session()
    inactive = F.person()
    F.manager(s.organization, inactive)
    inactive |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

    assert {:error, :cannot_remove_last_active_manager} =
             Auth.delete_user(s.person, %{current_user: admin})

    F.manager(s.organization, F.person())
    assert {:ok, _} = Auth.delete_user(s.person, %{current_user: admin})
    refute Repo.get(User, s.person.uuid)

    assert Repo.exists?(
             from(e in Entry,
               where:
                 e.action == "organization.manager_removed" and
                   e.resource_uuid == ^s.organization.uuid
             )
           )
  end

  test "last-manager deletion override requires the matching own-admin credential", %{
    actor: actor,
    admin: admin
  } do
    s = F.acting_session()

    assert {:error, :cannot_remove_last_active_manager} =
             Auth.delete_user(s.person, %{
               current_user: admin,
               allow_managerless: "false",
               manager_actor: actor
             })

    assert {:error, :forbidden} =
             Auth.delete_user(s.person, %{current_user: admin, allow_managerless: true})

    assert {:ok, _} =
             Auth.delete_user(s.person, %{
               current_user: admin,
               allow_managerless: true,
               manager_actor: actor
             })

    refute Repo.get(User, s.person.uuid)
    refute Repo.get(OrganizationManager, s.manager.uuid)
  end

  test "manager-grant eligibility is rechecked and type changes require removing grants", %{
    actor: actor
  } do
    org = F.organization()
    person = F.person()
    assert {:ok, _} = OrganizationManagers.add(actor, org.uuid, person.uuid)

    assert {:error, :organization_manager_must_be_person} =
             Auth.change_account_type(person, %{
               account_type: "organization",
               organization_name: "No"
             })

    assert {:error, :manager_must_be_active_person} =
             OrganizationManagers.add(actor, org.uuid, F.person(%{api_only: true}).uuid)
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

  defp credentials(org) do
    F.email_token(org, "reset_password")

    provider =
      %OAuthProvider{}
      |> OAuthProvider.changeset(%{
        user_uuid: org.uuid,
        provider: "google",
        provider_uid: UUIDv7.generate()
      })
      |> Repo.insert!()

    key =
      %Key{}
      |> Ecto.Changeset.change(%{
        user_uuid: org.uuid,
        prefix: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
        secret_hash: :crypto.strong_rand_bytes(32),
        name: "Old key"
      })
      |> Repo.insert!()

    %{provider: provider, key: key}
  end

  defp invitation(org, kind, status \\ :pending) do
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

  defp assert_disconnect(token) do
    topic = Sessions.live_socket_id(token)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end
end
