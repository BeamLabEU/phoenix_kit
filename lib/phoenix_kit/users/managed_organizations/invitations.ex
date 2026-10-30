defmodule PhoenixKit.Users.ManagedOrganizations.Invitations do
  @moduledoc false

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.Invitations, as: UserInvitations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.ManagedOrganizations.Locks
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  def create(organization_uuid, email, actor) when is_binary(email) do
    result =
      Revocation.transaction(fn ->
        org = Locks.organization!(organization_uuid)
        Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
        authority = actor |> Actor.authorize(org.uuid) |> Locks.value!()
        require_managed!(org)

        RateLimiter.check_manager_invitation_rate_limit(authority.person_uuid, org.uuid)
        |> Locks.value!()

        email = email |> String.trim() |> String.downcase()
        changeset = invitation_changeset(org, email, authority.person_uuid)
        unless changeset.valid?, do: RepoHelper.repo().rollback(changeset)

        case pending(org.uuid, email) do
          %OrganizationInvitation{} = existing -> {existing, nil, org}
          nil -> insert(changeset, org)
        end
      end)

    case result do
      {:ok, {invitation, token, org}} ->
        if token, do: send_mail(invitation, org, token)
        {:ok, invitation, token}

      error ->
        error
    end
  end

  def create(_, _, _), do: {:error, :forbidden}

  def accept(%OrganizationInvitation{} = initial, %User{} = caller) do
    if caller.acting_user_uuid || caller.managed_by_members do
      {:error, :manager_must_be_active_person}
    else
      Revocation.transaction(fn ->
        Locks.person!(caller.uuid)
        org = Locks.organization!(initial.organization_uuid)
        Locks.users!([caller.uuid])

        person =
          RepoHelper.repo().get(User, caller.uuid) ||
            RepoHelper.repo().rollback(:manager_must_be_active_person)

        invitation = lock_invitation(initial.uuid, org.uuid)
        validate_accept!(invitation, person)
        require_managed!(org)
        UserInvitations.record_admission(person) |> Locks.value!()

        authority = %{
          kind: :manager,
          actor_uuid: org.uuid,
          person_uuid: person.uuid,
          granted_by_uuid: invitation.invited_by_uuid
        }

        OrganizationManagers.insert_locked(org, person.uuid, authority)

        updated =
          invitation
          |> OrganizationInvitation.accept_changeset()
          |> RepoHelper.repo().update()
          |> Locks.value!()

        {updated, person}
      end)
    end
  end

  def decline(initial, caller) do
    Revocation.transaction(fn ->
      Locks.person!(caller.uuid)
      Locks.organization!(initial.organization_uuid)
      Locks.users!([caller.uuid])

      person =
        RepoHelper.repo().get(User, caller.uuid) || RepoHelper.repo().rollback(:not_invitee)

      invitation = lock_invitation(initial.uuid, initial.organization_uuid)

      unless invitation && UserInvitations.invitee?(invitation, person),
        do: RepoHelper.repo().rollback(:not_invitee)

      unless invitation.status == :pending, do: RepoHelper.repo().rollback(:not_pending)

      invitation
      |> OrganizationInvitation.decline_changeset()
      |> RepoHelper.repo().update()
      |> Locks.value!()
    end)
  end

  def cancel(actor, organization_uuid, invitation_uuid) do
    if UUIDUtils.valid?(invitation_uuid),
      do: cancel_valid(actor, organization_uuid, invitation_uuid),
      else: {:error, :not_found}
  end

  defp cancel_valid(actor, organization_uuid, invitation_uuid) do
    Revocation.transaction(fn ->
      org = Locks.organization!(organization_uuid)
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      actor |> Actor.authorize(org.uuid) |> Locks.value!()
      invitation = lock_invitation(invitation_uuid, org.uuid)
      unless invitation, do: RepoHelper.repo().rollback(:not_found)
      unless invitation.status == :pending, do: RepoHelper.repo().rollback(:not_pending)

      invitation
      |> OrganizationInvitation.cancel_changeset()
      |> RepoHelper.repo().update()
      |> Locks.value!()
    end)
  end

  defp invitation_changeset(org, email, person_uuid) do
    OrganizationInvitation.create_changeset(%OrganizationInvitation{}, %{
      organization_uuid: org.uuid,
      email: email,
      kind: :manager,
      invited_by_uuid: person_uuid,
      token: :crypto.strong_rand_bytes(32),
      expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
    })
  end

  defp pending(org, email) do
    query =
      from(i in OrganizationInvitation,
        where:
          i.organization_uuid == ^org and i.email == ^email and i.kind == :manager and
            i.status == :pending
      )

    now = DateTime.utc_now()

    RepoHelper.repo().update_all(from(i in query, where: i.expires_at <= ^now),
      set: [status: :cancelled]
    )

    RepoHelper.repo().one(from(i in query, where: i.expires_at > ^now))
  end

  defp insert(changeset, org) do
    raw = :crypto.strong_rand_bytes(32)

    invitation =
      changeset
      |> Ecto.Changeset.put_change(:token, :crypto.hash(:sha256, raw))
      |> RepoHelper.repo().insert()
      |> Locks.value!()

    {invitation, Base.url_encode64(raw, padding: false), org}
  end

  defp lock_invitation(uuid, org) do
    RepoHelper.repo().one(
      from(i in OrganizationInvitation,
        where: i.uuid == ^uuid and i.organization_uuid == ^org,
        lock: "FOR UPDATE"
      )
    )
  end

  defp validate_accept!(nil, _person), do: RepoHelper.repo().rollback(:not_found)

  defp validate_accept!(invitation, person) do
    cond do
      invitation.kind != :manager ->
        RepoHelper.repo().rollback(:not_found)

      invitation.status != :pending ->
        RepoHelper.repo().rollback(:not_pending)

      not UserInvitations.invitee?(invitation, person) ->
        RepoHelper.repo().rollback(:not_invitee)

      DateTime.compare(invitation.expires_at, DateTime.utc_now()) != :gt ->
        RepoHelper.repo().rollback(:expired)

      not match?(
        %User{
          account_type: "person",
          api_only: false,
          is_active: true,
          managed_by_members: false
        },
        person
      ) ->
        RepoHelper.repo().rollback(:manager_must_be_active_person)

      is_nil(person.confirmed_at) and
          Settings.get_boolean_setting("require_email_confirmation", true) ->
        RepoHelper.repo().rollback(:unconfirmed)

      true ->
        :ok
    end
  end

  defp require_managed!(%User{managed_by_members: true, is_active: true}), do: :ok
  defp require_managed!(_), do: RepoHelper.repo().rollback(:organization_not_active_managed)

  defp send_mail(invitation, org, token) do
    path =
      if Auth.get_user_by_email(invitation.email),
        do: "/users/log-in",
        else: "/users/register?invitation=#{token}"

    UserNotifier.deliver_manager_invitation(
      invitation.email,
      User.display_name(org),
      Routes.url(path)
    )
  end
end
