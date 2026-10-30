defmodule PhoenixKit.Users.ManagerInvitationsTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Users.Sessions

  setup do
    s = F.acting_session()
    {admin_actor, admin} = F.admin_actor()
    %{s: s, actor: F.acting_actor(s), admin_actor: admin_actor, admin: admin}
  end

  test "a manager invites an employed person and acceptance grants access without changing employment",
       %{s: s, actor: actor} do
    employer = F.organization()
    person = F.person(%{organization_uuid: employer.uuid})

    assert {:ok, invitation, token} =
             Invitations.create_invitation(s.organization, String.upcase(person.email), actor,
               kind: :manager
             )

    assert invitation.email == person.email
    assert invitation.kind == :manager
    assert invitation.invited_by_uuid == s.person.uuid
    assert {:ok, %{uuid: uuid}} = Invitations.get_by_token(token)
    assert uuid == invitation.uuid

    assert {:ok, {accepted, updated}} =
             Invitations.accept_invitation_by_uuid(invitation.uuid, person)

    assert accepted.status == :accepted
    assert updated.organization_uuid == employer.uuid

    grant =
      Repo.get_by!(OrganizationManager,
        organization_uuid: s.organization.uuid,
        user_uuid: person.uuid
      )

    assert grant.granted_by_uuid == s.person.uuid

    entry =
      Repo.one!(
        from(e in Entry,
          where: e.action == "organization.manager_added" and e.target_uuid == ^person.uuid
        )
      )

    assert entry.actor_uuid == s.organization.uuid
    assert entry.metadata["acting_user_uuid"] == person.uuid
  end

  test "member and manager invitations are distinct and legacy lists stay member-only", %{
    s: s,
    actor: actor,
    admin: admin
  } do
    person = F.person()
    assert {:ok, member, _} = Invitations.create_invitation(s.organization, person.email, admin)

    assert {:ok, manager, _} =
             Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

    assert member.kind == :member and manager.kind == :manager
    assert [^member] = Invitations.list_invitations(s.organization.uuid)
    assert [^manager] = Invitations.list_invitations(s.organization.uuid, kind: :manager)
    assert length(Invitations.list_pending_for_email(person.email)) == 2
  end

  test "new accounts, existing people and existing managers get the same success shape", %{
    s: s,
    actor: actor
  } do
    for email <- ["new-#{UUIDv7.generate()}@example.com", F.person().email, s.person.email] do
      assert {:ok, %OrganizationInvitation{kind: :manager}, token} =
               Invitations.create_invitation(s.organization, email, actor, kind: :manager)

      assert is_binary(token)

      assert {:ok, %OrganizationInvitation{kind: :manager}, nil} =
               Invitations.create_invitation(s.organization, email, actor, kind: :manager)
    end
  end

  test "expired pending invitations can be sent again", %{s: s, actor: actor} do
    email = F.person().email
    {:ok, old, _} = Invitations.create_invitation(s.organization, email, actor, kind: :manager)

    Repo.update!(
      Ecto.Changeset.change(old,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.truncate(:second)
      )
    )

    assert {:ok, new, token} =
             Invitations.create_invitation(s.organization, email, actor, kind: :manager)

    assert is_binary(token) and new.uuid != old.uuid
    assert Repo.get!(OrganizationInvitation, old.uuid).status == :cancelled
  end

  test "invalid and placeholder addresses are refused", %{s: s, actor: actor} do
    for email <- ["bad", "org@organization.invalid", "key@service.invalid"] do
      assert {:error, %Ecto.Changeset{}} =
               Invitations.create_invitation(s.organization, email, actor, kind: :manager)
    end
  end

  test "bare User, bare Scope and another organization's manager cannot invite", %{
    s: s,
    actor: actor
  } do
    beta = F.organization()

    for bad <- [s.person, Scope.for_user(s.person), nil] do
      assert {:error, :forbidden} =
               Invitations.create_invitation(s.organization, "new@example.com", bad,
                 kind: :manager
               )
    end

    assert {:error, :forbidden} =
             Invitations.create_invitation(beta, "new@example.com", actor, kind: :manager)
  end

  test "root-session revocation invalidates an invitation writer", %{s: s, actor: actor} do
    assert 1 = Sessions.revoke_user_sessions(s.person)

    assert {:error, :forbidden} =
             Invitations.create_invitation(s.organization, "new@example.com", actor,
               kind: :manager
             )
  end

  test "admin invitation and cancellation work only in their own live account", %{
    s: s,
    admin_actor: actor,
    admin: admin
  } do
    assert {:ok, invitation, _} =
             Invitations.create_invitation(s.organization, "new@example.com", actor,
               kind: :manager
             )

    assert invitation.invited_by_uuid == admin.uuid

    assert {:ok, %{status: :cancelled}} =
             Invitations.cancel_invitation(actor, s.organization.uuid, invitation.uuid)
  end

  test "cancellation is scoped and rechecks the grant; old unscoped API refuses manager invitations",
       %{s: s, actor: actor, admin_actor: admin} do
    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, "new@example.com", actor, kind: :manager)

    beta = F.organization()
    assert {:error, :not_found} = Invitations.cancel_invitation(admin, beta.uuid, invitation.uuid)
    assert {:error, :forbidden} = Invitations.cancel_invitation(invitation.uuid)

    assert {:error, :not_found} =
             Invitations.cancel_invitation(actor, s.organization.uuid, "forged")

    {:ok, :ok} =
      OrganizationManagers.remove(admin, s.organization.uuid, s.person.uuid,
        allow_managerless: true
      )

    assert {:error, :forbidden} =
             Invitations.cancel_invitation(actor, s.organization.uuid, invitation.uuid)

    assert Repo.get!(OrganizationInvitation, invitation.uuid).status == :pending
  end

  test "conversion back cancels manager invitations and acceptance cannot restore a grant", %{
    s: s,
    actor: actor,
    admin_actor: admin
  } do
    person = F.person()

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

    assert {:ok, _} =
             ManagedOrganizations.convert_to_independent(admin, s.organization.uuid, %{
               email: "independent-#{UUIDv7.generate()}@example.com",
               password: "NewPassword123!"
             })

    assert {:error, :not_pending} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

    refute Repo.exists?(
             from(m in OrganizationManager, where: m.organization_uuid == ^s.organization.uuid)
           )
  end

  test "acceptance rechecks person state and email instead of stale form data", %{
    s: s,
    actor: actor
  } do
    for attrs <- [
          %{api_only: true},
          %{is_active: false},
          %{account_type: "organization"},
          %{email: "changed-#{UUIDv7.generate()}@example.com"}
        ] do
      person = F.person()

      {:ok, invitation, _} =
        Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

      Repo.update!(Ecto.Changeset.change(person, attrs))
      assert {:error, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)
      assert Repo.get!(OrganizationInvitation, invitation.uuid).status == :pending

      refute Repo.get_by(OrganizationManager,
               organization_uuid: s.organization.uuid,
               user_uuid: person.uuid
             )
    end
  end

  test "an acting caller and wrong invitee cannot accept", %{s: s, actor: actor} do
    person = F.person()

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

    assert {:error, :not_invitee} =
             Invitations.accept_invitation_by_uuid(invitation.uuid, s.person)

    assert {:error, :manager_must_be_active_person} =
             Invitations.accept_invitation_by_uuid(invitation.uuid, %{
               person
               | acting_user_uuid: s.person.uuid
             })
  end

  test "inactive organizations refuse acceptance without consuming the invitation", %{
    s: s,
    actor: actor
  } do
    person = F.person()

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

    Repo.update!(Ecto.Changeset.change(s.organization, is_active: false))

    assert {:error, :organization_not_active_managed} =
             Invitations.accept_invitation_by_uuid(invitation.uuid, person)

    assert Repo.get!(OrganizationInvitation, invitation.uuid).status == :pending
  end

  test "acceptance records invite-only admission before consuming the invitation", %{
    s: s,
    actor: actor
  } do
    Settings.update_setting("referral_codes_required", "true")
    person = F.person()

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

    assert {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)
    assert Referrals.marked_satisfied?(Auth.get_user!(person.uuid))
    assert Referrals.access_satisfied?(Auth.get_user!(person.uuid))
  end

  test "manager invite rate limit counts duplicate attempts", %{s: s, actor: actor} do
    for _ <- 1..10 do
      assert {:ok, _, _} =
               Invitations.create_invitation(s.organization, "duplicate@example.com", actor,
                 kind: :manager
               )
    end

    assert {:error, :rate_limit_exceeded} =
             Invitations.create_invitation(s.organization, "unknown@example.com", actor,
               kind: :manager
             )
  end

  test "managed organizations cannot be unconfirmed, including stale independent forms", %{s: s} do
    assert {:error, :managed_organization} =
             Auth.admin_unconfirm_user(%{s.organization | managed_by_members: false})

    assert Repo.get!(User, s.organization.uuid).confirmed_at
  end

  test "a manager cannot search people or convert; contact editing and details are scoped", %{
    s: s,
    actor: actor
  } do
    assert {:ok, %{grants: [_]}} = OrganizationManagers.details(actor, s.organization.uuid)
    assert {:error, :forbidden} = OrganizationManagers.search(actor, s.organization.uuid, "")

    assert {:error, :forbidden} =
             ManagedOrganizations.convert_to_independent(actor, s.organization.uuid, %{})

    assert {:ok, org} =
             OrganizationManagers.update_contact(actor, s.organization.uuid, %{
               contact_email: "new@example.com",
               email: "injected@example.com"
             })

    assert org.contact_email == "new@example.com"
    assert org.email == s.organization.email
    beta = F.organization()

    assert {:error, :forbidden} =
             OrganizationManagers.update_contact(actor, beta.uuid, %{
               contact_email: "bad@example.com"
             })
  end

  test "manager mail always sends and selects the invitee's sign-in or registration URL", %{
    s: s,
    actor: actor
  } do
    existing = F.person()

    {:ok, _, _} =
      Invitations.create_invitation(s.organization, existing.email, actor, kind: :manager)

    assert_received {:email, existing_mail}
    assert existing_mail.subject =~ "manage"
    assert existing_mail.text_body =~ "/users/log-in"
    refute existing_mail.text_body =~ "/users/register"
    email = "new-mail-#{UUIDv7.generate()}@example.com"
    {:ok, _, _} = Invitations.create_invitation(s.organization, email, actor, kind: :manager)
    assert_received {:email, new_mail}
    assert new_mail.text_body =~ "/users/register?invitation="
  end

  test "manager decline serializes its status and never creates a grant", %{s: s, actor: actor} do
    person = F.person()

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

    assert {:ok, %{status: :declined}} =
             Invitations.decline_invitation_by_uuid(invitation.uuid, person)

    assert {:error, :not_pending} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

    refute Repo.get_by(OrganizationManager,
             organization_uuid: s.organization.uuid,
             user_uuid: person.uuid
           )
  end

  test "session references used by manager controls never log raw tokens", %{s: s} do
    secret = String.duplicate("manager-session-secret-", 3)
    Repo.update!(Ecto.Changeset.change(s.root, token: secret))

    log =
      PhoenixKit.DataCase.capture_debug_log(fn ->
        assert Auth.get_user_by_session_token(secret)
        assert Auth.get_session_token_record(secret)
        assert {:ok, _} = Actor.from_session(%{"user_token" => secret})
        Repo.query!("SELECT 1")
      end)

    assert log =~ "SELECT 1"
    refute log =~ secret
  end
end
