defmodule PhoenixKit.Users.Invitations do
  @moduledoc """
  Context for organization invitation lifecycle management.

  Handles creating, listing, accepting, declining, and cancelling invitations.

  ## Token Security

  Follows the UserToken pattern:
  - Raw token (32 bytes) is generated with `:crypto.strong_rand_bytes/1`
  - SHA-256 hash is stored in the database
  - URL-safe Base64 encoded raw token is sent via email or flash

  ## Flow

  1. Admin calls `create_invitation/3` — invitation is created, encoded_token returned
  2. For existing users: banner shown via `list_pending_for_email/1` + InvitationHook
  3. For new users: invitation email with registration link containing encoded_token
  4. User accepts via `accept_invitation_by_uuid/2` or declines via `decline_invitation_by_uuid/2`
  """

  import Ecto.Query

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.ManagedOrganizations.Invitations, as: ManagerInvitations
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @invitation_validity_days 7

  @doc """
  Creates an invitation for the given email to join or manage the organization.

  `kind: :member` (the default) takes the inviting User. `kind: :manager`
  takes a ManagedOrganizations.Actor from the trusted signed browser session;
  it resolves the inviting person itself and rechecks the live grant/admin.
  Manager responses and duplicate responses are presented generically by the UI.

  Returns `{:ok, invitation, encoded_token}` on success.
  The `encoded_token` must be sent to the invitee (via email for new users,
  or the UI banner handles lookup by invitation uuid for existing users).

  ## Validation

  - Cannot invite a user already belonging to an organization
  - Cannot create a duplicate pending invitation from the same org for the same email
  """
  def create_invitation(organization, email, invited_by, opts \\ [])

  def create_invitation(%User{} = organization, email, actor, opts)
      when is_binary(email) do
    case Keyword.get(opts, :kind, :member) do
      :manager ->
        ManagerInvitations.create(organization.uuid, email, actor)

      :member ->
        create_member_invitation(organization, email, invited_by_user(actor))

      _ ->
        {:error, :invalid_kind}
    end
  end

  defp invited_by_user(%User{} = user), do: user
  defp invited_by_user(_), do: nil

  defp create_member_invitation(organization, email, %User{} = invited_by) do
    with :ok <- validate_invitation_allowed(organization, email) do
      raw_token = :crypto.strong_rand_bytes(32)
      hashed_token = :crypto.hash(:sha256, raw_token)
      encoded_token = Base.url_encode64(raw_token, padding: false)

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(@invitation_validity_days * 24 * 3600, :second)
        |> DateTime.truncate(:second)

      attrs = %{
        organization_uuid: organization.uuid,
        email: email,
        invited_by_uuid: invited_by.uuid,
        token: hashed_token,
        expires_at: expires_at
      }

      changeset = OrganizationInvitation.create_changeset(%OrganizationInvitation{}, attrs)
      repo = RepoHelper.repo()

      case repo.insert(changeset) do
        {:ok, invitation} ->
          maybe_send_invitation_email(invitation, organization, encoded_token)
          {:ok, invitation, encoded_token}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp create_member_invitation(_, _, _), do: {:error, :forbidden}

  @doc """
  Lists member invitations (or `kind: :manager`), ordered by most recent first.
  """
  def list_invitations(organization_uuid, opts \\ []) do
    kind = Keyword.get(opts, :kind, :member)
    repo = RepoHelper.repo()

    from(i in OrganizationInvitation,
      where: i.organization_uuid == ^organization_uuid and i.kind == ^kind,
      order_by: [desc: i.inserted_at]
    )
    |> repo.all()
  end

  @doc """
  Lists pending, non-expired invitations for a given email.
  Preloads the `:organization` association for display in banners.
  """
  def list_pending_for_email(email) when is_binary(email) do
    repo = RepoHelper.repo()
    now = DateTime.utc_now()

    from(i in OrganizationInvitation,
      where:
        i.email == ^email and
          i.status == :pending and
          i.expires_at > ^now,
      preload: [:organization]
    )
    |> repo.all()
  end

  @doc """
  Looks up a pending, non-expired invitation by encoded token.
  Used during registration to show org name and store the token.

  Returns `{:ok, invitation}` or `{:error, :not_found | :invalid_token}`.
  """
  def get_by_token(encoded_token) when is_binary(encoded_token) do
    case Base.url_decode64(encoded_token, padding: false) do
      {:ok, raw_token} ->
        hashed_token = :crypto.hash(:sha256, raw_token)
        repo = RepoHelper.repo()
        now = DateTime.utc_now()

        result =
          from(i in OrganizationInvitation,
            where:
              i.token == ^hashed_token and
                i.status == :pending and
                i.expires_at > ^now,
            preload: [:organization]
          )
          |> repo.one()

        case result do
          nil -> {:error, :not_found}
          invitation -> {:ok, invitation}
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Accepts an invitation by UUID in a single transaction.

  Sets invitation status to `:accepted` and links the user to the organization.
  Returns `{:ok, {invitation, user}}` on success.

  ## Errors

  - `{:error, :not_found}` — invitation not found
  - `{:error, :not_pending}` — invitation is not in :pending status
  - `{:error, :not_invitee}` — invitation was addressed to a different email
  - `{:error, :expired}` — invitation has expired
  - `{:error, reason}` — database or validation error
  """
  def accept_invitation_by_uuid(invitation_uuid, %User{} = user) do
    if UUIDUtils.valid?(invitation_uuid),
      do: accept_valid_invitation(invitation_uuid, user),
      else: {:error, :not_found}
  end

  defp accept_valid_invitation(invitation_uuid, user) do
    repo = RepoHelper.repo()

    invitation = repo.get(OrganizationInvitation, invitation_uuid)

    cond do
      is_nil(invitation) ->
        {:error, :not_found}

      invitation.kind == :manager ->
        ManagerInvitations.accept(invitation, user)

      invitation.status != :pending ->
        {:error, :not_pending}

      # Invitations are email-bound. The uuid arrives from a client event, so
      # without this any signed-in user who learns one could join (or, below,
      # decline) somebody else's invitation.
      not invitee?(invitation, user) ->
        {:error, :not_invitee}

      DateTime.compare(DateTime.utc_now(), invitation.expires_at) == :gt ->
        {:error, :expired}

      true ->
        with :ok <- record_admission(user) do
          repo.transaction(fn -> do_accept_invitation(repo, invitation, user) end)
        end
    end
  end

  # Being invited is itself admission under invite-only, and the gate reads
  # *pending* invitations — so accepting one removes the very thing that was
  # admitting this user.
  #
  # Two things have to be true, and doing only the first is not enough: the mark
  # is written BEFORE the invitation is consumed, AND a failed mark aborts the
  # acceptance. Marking first but accepting anyway still strands the invitee —
  # invitation gone, mark absent, nothing left that can satisfy the gate.
  #
  # Only enforced while invite-only is actually on. Failing an organization
  # invitation because a referral bookkeeping write hiccuped, on an install with
  # no referral gate at all, would be absurd. `mark_satisfied/2` is idempotent,
  # so writing it early costs nothing when the acceptance then fails on its own.
  @doc false
  def record_admission(user) do
    case Referrals.mark_satisfied(user, "invitation") do
      {:ok, _user} ->
        :ok

      {:error, reason} ->
        if Referrals.access_required?() do
          {:error, {:could_not_record_admission, reason}}
        else
          :ok
        end
    end
  end

  defp do_accept_invitation(repo, invitation, user) do
    case invitation |> OrganizationInvitation.accept_changeset() |> repo.update() do
      {:ok, updated_inv} ->
        case Auth.set_organization(user, invitation.organization_uuid) do
          {:ok, updated_user} -> {updated_inv, updated_user}
          {:error, reason} -> repo.rollback(reason)
        end

      {:error, changeset} ->
        repo.rollback(changeset)
    end
  end

  @doc """
  Declines an invitation by UUID on behalf of the invitee.

  Only pending invitations addressed to `user`'s email can be declined.
  """
  def decline_invitation_by_uuid(invitation_uuid, %User{} = user) do
    if UUIDUtils.valid?(invitation_uuid),
      do: decline_valid_invitation(invitation_uuid, user),
      else: {:error, :not_found}
  end

  defp decline_valid_invitation(invitation_uuid, user) do
    repo = RepoHelper.repo()

    case repo.get(OrganizationInvitation, invitation_uuid) do
      nil ->
        {:error, :not_found}

      %OrganizationInvitation{kind: :manager} = invitation ->
        ManagerInvitations.decline(invitation, user)

      %OrganizationInvitation{status: :pending} = invitation ->
        if invitee?(invitation, user) do
          invitation
          |> OrganizationInvitation.decline_changeset()
          |> repo.update()
        else
          {:error, :not_invitee}
        end

      %OrganizationInvitation{} ->
        {:error, :not_pending}
    end
  end

  @doc """
  True when `user`'s email is the one the invitation was sent to
  (case-insensitive).
  """
  def invitee?(%OrganizationInvitation{email: email}, %User{email: user_email})
      when is_binary(email) and is_binary(user_email) do
    String.downcase(String.trim(email)) == String.downcase(String.trim(user_email))
  end

  def invitee?(_, _), do: false

  @doc """
  Legacy trusted-system cancellation of member invitations only.

  Browser callers use `cancel_invitation/3`, which scopes the row and rechecks
  their live authority. This arity refuses manager invitations.

  Only `:pending` invitations can be cancelled.
  """
  def cancel_invitation(invitation_uuid) do
    repo = RepoHelper.repo()

    case repo.get(OrganizationInvitation, invitation_uuid) do
      nil ->
        {:error, :not_found}

      %{kind: :manager} ->
        {:error, :forbidden}

      %{status: :pending} = invitation ->
        invitation
        |> OrganizationInvitation.cancel_changeset()
        |> repo.update()

      _other ->
        {:error, :not_pending}
    end
  end

  @doc "Cancels an invitation only within the organization and a live authorized browser."
  def cancel_invitation(actor, organization_uuid, invitation_uuid),
    do:
      ManagerInvitations.cancel(
        actor,
        organization_uuid,
        invitation_uuid
      )

  # Private Helpers

  defp validate_invitation_allowed(organization, email) do
    if organization.email == email do
      {:error, :self_invite}
    else
      repo = RepoHelper.repo()

      case repo.get_by(User, email: email) do
        %User{organization_uuid: org_uuid} when not is_nil(org_uuid) ->
          {:error, dgettext("phoenix_kit", "This user already belongs to an organization")}

        _ ->
          existing =
            from(i in OrganizationInvitation,
              where:
                i.organization_uuid == ^organization.uuid and
                  i.email == ^email and i.kind == :member and
                  i.status == :pending
            )
            |> repo.one()

          if existing do
            {:error,
             dgettext("phoenix_kit", "A pending invitation already exists for this email")}
          else
            :ok
          end
      end
    end
  end

  defp maybe_send_invitation_email(invitation, organization, encoded_token) do
    repo = RepoHelper.repo()

    case repo.get_by(User, email: invitation.email) do
      nil ->
        url = Routes.url("/users/register?invitation=#{encoded_token}")

        UserNotifier.deliver_organization_invitation(
          invitation.email,
          organization.organization_name,
          url
        )

      _existing_user ->
        # Existing user sees the banner via InvitationHook
        :ok
    end
  end
end
