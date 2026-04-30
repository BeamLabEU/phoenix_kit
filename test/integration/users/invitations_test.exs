defmodule PhoenixKit.Integration.Users.InvitationsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.OrganizationInvitation

  defp unique_email, do: "inv_#{System.unique_integer([:positive])}@example.com"

  defp create_person(overrides \\ %{}) do
    attrs = Map.merge(%{email: unique_email(), password: "ValidPassword123!"}, overrides)
    {:ok, user} = Auth.register_user(attrs)
    user
  end

  defp create_org(name \\ "Acme Corp") do
    {:ok, base} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})

    {:ok, org} =
      Auth.change_account_type(base, %{account_type: "organization", organization_name: name})

    org
  end

  defp create_admin, do: create_person()

  # --- create_invitation/3 ---

  describe "create_invitation/3" do
    test "creates invitation for existing person without org" do
      org = create_org()
      person = create_person()
      admin = create_admin()

      assert {:ok, invitation, encoded_token} =
               Invitations.create_invitation(org, person.email, admin)

      assert invitation.status == :pending
      assert invitation.email == person.email
      assert invitation.organization_uuid == org.uuid
      assert is_binary(encoded_token)
    end

    test "creates invitation for new (non-existent) email" do
      org = create_org()
      admin = create_admin()
      new_email = unique_email()

      assert {:ok, invitation, _token} = Invitations.create_invitation(org, new_email, admin)
      assert invitation.email == new_email
      assert invitation.status == :pending
    end

    test "returns error when user already belongs to an organization" do
      org1 = create_org("Org1")
      org2 = create_org("Org2")
      person = create_person()
      {:ok, _} = Auth.set_organization(person, org1.uuid)
      admin = create_admin()

      assert {:error, _reason} = Invitations.create_invitation(org2, person.email, admin)
    end

    test "returns error for duplicate pending invitation from same org" do
      org = create_org()
      admin = create_admin()
      email = unique_email()
      {:ok, _, _} = Invitations.create_invitation(org, email, admin)

      assert {:error, _reason} = Invitations.create_invitation(org, email, admin)
    end

    test "stores token as SHA-256 hash (32 bytes)" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _encoded} = Invitations.create_invitation(org, person.email, admin)
      assert byte_size(invitation.token) == 32
    end

    test "sets expires_at to approximately 7 days from now" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      diff_seconds = DateTime.diff(invitation.expires_at, DateTime.utc_now())
      # Between 6 days and 8 days
      assert diff_seconds > 6 * 24 * 3600
      assert diff_seconds < 8 * 24 * 3600
    end

    test "raw token hashing round-trip — stored hash matches rehash" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, encoded_token} = Invitations.create_invitation(org, person.email, admin)
      {:ok, raw_bytes} = Base.url_decode64(encoded_token, padding: false)
      expected_hash = :crypto.hash(:sha256, raw_bytes)
      assert invitation.token == expected_hash
    end
  end

  # --- accept_invitation_by_uuid/2 ---

  describe "accept_invitation_by_uuid/2" do
    test "sets organization_uuid on user" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _encoded_token} = Invitations.create_invitation(org, person.email, admin)

      assert {:ok, {_inv, updated_user}} =
               Invitations.accept_invitation_by_uuid(invitation.uuid, person)

      assert updated_user.organization_uuid == org.uuid
    end

    test "marks invitation as accepted with accepted_at set" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

      inv = Repo.get!(OrganizationInvitation, invitation.uuid)
      assert inv.status == :accepted
      refute is_nil(inv.accepted_at)
    end

    test "returns error for expired invitation" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)

      invitation
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second))
      |> Repo.update!()

      assert {:error, :expired} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)
    end

    test "returns error for already accepted invitation" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

      assert {:error, :not_pending} =
               Invitations.accept_invitation_by_uuid(invitation.uuid, person)
    end

    test "returns error for non-existent invitation uuid" do
      person = create_person()

      assert {:error, :not_found} =
               Invitations.accept_invitation_by_uuid(UUIDv7.generate(), person)
    end
  end

  # --- decline_invitation_by_uuid/1 ---

  describe "decline_invitation_by_uuid/1" do
    test "marks invitation as declined" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)

      assert {:ok, declined} = Invitations.decline_invitation_by_uuid(invitation.uuid)
      assert declined.status == :declined
    end

    test "does not set organization_uuid on user" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.decline_invitation_by_uuid(invitation.uuid)

      updated = Auth.get_user(person.uuid)
      assert is_nil(updated.organization_uuid)
    end

    test "returns error for already-accepted invitation" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

      assert {:error, :not_pending} = Invitations.decline_invitation_by_uuid(invitation.uuid)
    end

    test "returns error for non-existent invitation uuid" do
      assert {:error, :not_found} = Invitations.decline_invitation_by_uuid(UUIDv7.generate())
    end
  end

  # --- cancel_invitation/1 ---

  describe "cancel_invitation/1" do
    test "cancels a pending invitation" do
      org = create_org()
      admin = create_admin()
      email = unique_email()
      {:ok, invitation, _token} = Invitations.create_invitation(org, email, admin)

      assert {:ok, cancelled} = Invitations.cancel_invitation(invitation.uuid)
      assert cancelled.status == :cancelled
    end

    test "returns error when invitation is not pending" do
      # `cancel_invitation/1` returns `{:error, :not_pending}` (atom, see
      # @doc at lib/phoenix_kit/users/invitations.ex:154) when the invitation
      # has already been accepted/cancelled — not a changeset.
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

      assert {:error, :not_pending} = Invitations.cancel_invitation(invitation.uuid)
    end

    test "returns error for non-existent invitation uuid" do
      assert {:error, :not_found} = Invitations.cancel_invitation(UUIDv7.generate())
    end
  end

  # --- list_pending_for_email/1 ---

  describe "list_pending_for_email/1" do
    test "returns pending invitations for email" do
      org1 = create_org("Org1")
      org2 = create_org("Org2")
      admin = create_admin()
      email = unique_email()
      {:ok, _, _} = Invitations.create_invitation(org1, email, admin)
      {:ok, _, _} = Invitations.create_invitation(org2, email, admin)
      pending = Invitations.list_pending_for_email(email)
      assert length(pending) == 2
    end

    test "excludes accepted invitations" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

      pending = Invitations.list_pending_for_email(person.email)
      assert pending == []
    end

    test "excludes declined invitations" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.decline_invitation_by_uuid(invitation.uuid)

      pending = Invitations.list_pending_for_email(person.email)
      assert pending == []
    end

    test "excludes cancelled invitations" do
      org = create_org()
      admin = create_admin()
      email = unique_email()
      {:ok, invitation, _} = Invitations.create_invitation(org, email, admin)
      {:ok, _} = Invitations.cancel_invitation(invitation.uuid)

      pending = Invitations.list_pending_for_email(email)
      assert pending == []
    end

    test "excludes expired invitations" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, _} = Invitations.create_invitation(org, person.email, admin)

      invitation
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second))
      |> Repo.update!()

      pending = Invitations.list_pending_for_email(person.email)
      assert pending == []
    end

    test "preloads organization association" do
      org = create_org("Preview Corp")
      admin = create_admin()
      email = unique_email()
      {:ok, _, _} = Invitations.create_invitation(org, email, admin)

      [inv] = Invitations.list_pending_for_email(email)
      assert inv.organization.organization_name == "Preview Corp"
    end

    test "returns empty list for email with no invitations" do
      assert Invitations.list_pending_for_email(
               "nobody_#{System.unique_integer([:positive])}@example.com"
             ) ==
               []
    end
  end

  # --- get_by_token/1 ---

  describe "get_by_token/1" do
    test "finds invitation by valid encoded token" do
      org = create_org()
      admin = create_admin()
      email = unique_email()
      {:ok, invitation, encoded_token} = Invitations.create_invitation(org, email, admin)

      assert {:ok, found} = Invitations.get_by_token(encoded_token)
      assert found.uuid == invitation.uuid
    end

    test "returns error for unknown token" do
      fake = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      assert {:error, _} = Invitations.get_by_token(fake)
    end

    test "returns error for expired token" do
      org = create_org()
      admin = create_admin()
      email = unique_email()
      {:ok, invitation, encoded_token} = Invitations.create_invitation(org, email, admin)

      invitation
      |> Ecto.Changeset.change(expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second))
      |> Repo.update!()

      assert {:error, _} = Invitations.get_by_token(encoded_token)
    end

    test "returns error for accepted invitation token" do
      org = create_org()
      person = create_person()
      admin = create_admin()
      {:ok, invitation, encoded_token} = Invitations.create_invitation(org, person.email, admin)
      {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, person)

      assert {:error, _} = Invitations.get_by_token(encoded_token)
    end

    test "returns error for invalid base64 token" do
      assert {:error, _} = Invitations.get_by_token("not-valid-base64!!!")
    end

    test "raw token hashing round-trip — stored hash matches rehash" do
      org = create_org()
      admin = create_admin()
      email = unique_email()
      {:ok, invitation, encoded_token} = Invitations.create_invitation(org, email, admin)
      {:ok, raw_bytes} = Base.url_decode64(encoded_token, padding: false)
      expected_hash = :crypto.hash(:sha256, raw_bytes)
      assert invitation.token == expected_hash
    end
  end

  # --- multiple organization invitations ---

  describe "multiple organization invitations" do
    test "different orgs can each have pending invite for same email" do
      org1 = create_org("Org1")
      org2 = create_org("Org2")
      admin = create_admin()
      email = unique_email()

      assert {:ok, _, _} = Invitations.create_invitation(org1, email, admin)
      assert {:ok, _, _} = Invitations.create_invitation(org2, email, admin)
    end

    test "same org cannot have 2 pending invites for same email" do
      org = create_org()
      admin = create_admin()
      email = unique_email()

      {:ok, _, _} = Invitations.create_invitation(org, email, admin)
      assert {:error, _} = Invitations.create_invitation(org, email, admin)
    end
  end
end
